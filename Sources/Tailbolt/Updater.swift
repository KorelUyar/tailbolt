import AppKit
import Observation
import TailboltCore

/// Looks for a newer release on GitHub (once a day, or on demand) and installs it in place: download the zip,
/// check it is really Tailbolt and newer, swap the app bundle, relaunch. Peers on old versions were the reason –
/// a 2.0 receiver silently drops notes, so keeping everyone current matters more than it used to.
@MainActor @Observable
final class Updater {
    static let shared = Updater()

    struct Release: Equatable {
        let version: String
        let zip: URL
        let page: URL
    }

    enum InstallState: Equatable {
        case idle
        case downloading
        case installing
        case failed(String)
    }

    /// A release newer than this build, once a check found one.
    private(set) var latest: Release?
    private(set) var isChecking = false
    /// The last check found nothing newer.
    private(set) var upToDate = false
    private(set) var install: InstallState = .idle
    private(set) var lastError: String?

    @ObservationIgnored private var timer: Timer?
    private static let lastCheckKey = "lastUpdateCheck"
    private static let api = URL(string: "https://api.github.com/repos/KorelUyar/tailbolt/releases/latest")!
    static let releasesPage = URL(string: "https://github.com/KorelUyar/tailbolt/releases/latest")!

    /// Only a real app bundle can replace itself (not `swift run`, not the snapshot renderer).
    var canInstall: Bool { Bundle.main.bundleURL.pathExtension == "app" }

    /// Dev aid: `TAILBOLT_UPDATE_SELFTEST=2.0` pretends to be that version, installs the latest release over this
    /// bundle right away and quits instead of relaunching – run it on a copy of the app, never the installed one.
    private static let selfTest = ProcessInfo.processInfo.environment["TAILBOLT_UPDATE_SELFTEST"]
    private nonisolated static var currentVersion: String {
        ProcessInfo.processInfo.environment["TAILBOLT_UPDATE_SELFTEST"] ?? Tailbolt.appVersion
    }

    func start() {
        guard canInstall else { return }
        if Self.selfTest != nil {
            check()
            Task {
                while isChecking { try? await Task.sleep(for: .milliseconds(100)) }
                print("selftest: latest \(latest?.version ?? "none"), error \(lastError ?? "none")")
                guard latest != nil else { exit(3) }
                installLatest()
            }
            return
        }
        let t = Timer(timeInterval: 30 * 60, repeats: true) { _ in
            MainActor.assumeIsolated { Updater.shared.checkIfDue() }
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t
        DispatchQueue.main.asyncAfter(deadline: .now() + 20) { self.checkIfDue() }
    }

    private func checkIfDue() {
        guard Settings.shared.checkForUpdates else { return }
        let last = UserDefaults.standard.double(forKey: Self.lastCheckKey)
        guard Date().timeIntervalSince1970 - last > 20 * 3600 else { return }
        check()
    }

    func check() {
        guard !isChecking else { return }
        isChecking = true
        lastError = nil
        var request = URLRequest(url: Self.api, timeoutInterval: 20)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("Tailbolt/\(Tailbolt.appVersion)", forHTTPHeaderField: "User-Agent")
        Task {
            defer { isChecking = false }
            do {
                let (data, response) = try await URLSession.shared.data(for: request)
                guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw UpdateError.message(String(localized: "GitHub didn’t answer")) }
                let release = try Self.parse(data)
                UserDefaults.standard.set(Date().timeIntervalSince1970, forKey: Self.lastCheckKey)
                if let release, Self.isNewer(release.version, than: Self.currentVersion) {
                    latest = release
                    upToDate = false
                } else {
                    latest = nil
                    upToDate = true
                }
            } catch {
                lastError = (error as? UpdateError)?.text ?? error.localizedDescription
            }
        }
    }

    private static func parse(_ data: Data) throws -> Release? {
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let tag = json["tag_name"] as? String else { return nil }
        let version = tag.hasPrefix("v") ? String(tag.dropFirst()) : tag
        let assets = json["assets"] as? [[String: Any]] ?? []
        guard let zip = assets.first(where: { $0["name"] as? String == "Tailbolt.zip" })?["browser_download_url"] as? String,
              let zipURL = URL(string: zip), zipURL.host?.hasSuffix("github.com") == true else { return nil }
        let page = (json["html_url"] as? String).flatMap(URL.init(string:)) ?? releasesPage
        return Release(version: version, zip: zipURL, page: page)
    }

    /// "2.10" > "2.9", "2.3.0" == "2.3".
    nonisolated static func isNewer(_ a: String, than b: String) -> Bool {
        func parts(_ s: String) -> [Int] { s.split(separator: ".").map { Int($0.filter(\.isNumber)) ?? 0 } }
        var x = parts(a), y = parts(b)
        let n = max(x.count, y.count)
        x += Array(repeating: 0, count: n - x.count)
        y += Array(repeating: 0, count: n - y.count)
        return x.lexicographicallyPrecedes(y) == false && x != y
    }

    /// Dev aid (`--snapshot`): pretend a check found `version`.
    func debugSetLatest(_ version: String?) {
        latest = version.map { Release(version: $0, zip: Self.releasesPage, page: Self.releasesPage) }
    }

    // MARK: install

    func installLatest() {
        guard let release = latest, install != .downloading, install != .installing else { return }
        guard canInstall else { NSWorkspace.shared.open(release.page); return }
        install = .downloading
        Task {
            do {
                let (file, response) = try await URLSession.shared.download(from: release.zip)
                guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw UpdateError.message(String(localized: "Download failed")) }
                install = .installing
                let target = Bundle.main.bundleURL
                try await Task.detached(priority: .userInitiated) { try Self.replace(target, withZip: file, version: release.version) }.value
                Self.relaunch(target)
            } catch {
                install = .failed((error as? UpdateError)?.text ?? error.localizedDescription)
                if Self.selfTest != nil { print("selftest: failed \(install)"); exit(4) }
            }
        }
    }

    enum UpdateError: Error {
        case message(String)
        var text: String { if case .message(let m) = self { return m }; return "" }
    }

    /// Unpacks the zip next to nothing important, checks bundle id, version and signature, then swaps bundles.
    private nonisolated static func replace(_ target: URL, withZip zip: URL, version: String) throws {
        let fm = FileManager.default
        let work = fm.temporaryDirectory.appendingPathComponent("tailbolt-update-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: work, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: work) }
        try run("/usr/bin/ditto", ["-x", "-k", zip.path, work.path])
        let app = work.appendingPathComponent("Tailbolt.app")
        guard let info = NSDictionary(contentsOf: app.appendingPathComponent("Contents/Info.plist")),
              info["CFBundleIdentifier"] as? String == Bundle.main.bundleIdentifier,
              let newVersion = info["CFBundleShortVersionString"] as? String,
              !isNewer(currentVersion, than: newVersion) else {
            throw UpdateError.message(String(localized: "The download isn’t a valid Tailbolt"))
        }
        try run("/usr/bin/codesign", ["--verify", "--deep", "--strict", app.path])
        _ = try? run("/usr/bin/xattr", ["-dr", "com.apple.quarantine", app.path])
        guard fm.isWritableFile(atPath: target.deletingLastPathComponent().path) else {
            throw UpdateError.message(String(localized: "No permission to replace \(target.path) – install the update by hand"))
        }
        _ = try fm.replaceItemAt(target, withItemAt: app)
    }

    @discardableResult
    private nonisolated static func run(_ tool: String, _ args: [String]) throws -> Int32 {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: tool)
        p.arguments = args
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        try p.run()
        p.waitUntilExit()
        guard p.terminationStatus == 0 else {
            let code = String(p.terminationStatus), name = (tool as NSString).lastPathComponent
            throw UpdateError.message(String(localized: "Update failed (\(name) \(code))"))
        }
        return p.terminationStatus
    }

    /// Starts the new bundle once this process is gone (same port, so not before).
    private static func relaunch(_ app: URL) {
        if selfTest != nil { print("selftest: replaced \(app.path)"); exit(0) }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sh")
        p.arguments = ["-c", "while kill -0 \(ProcessInfo.processInfo.processIdentifier) 2>/dev/null; do sleep 0.2; done; /usr/bin/open \"$0\"", app.path]
        try? p.run()
        NSApp.terminate(nil)
    }
}
