import AppKit
import SwiftUI
import TailboltCore

/// The app icon for the Info tab. Inside the .app bundle it is the real AppIcon (NSApp); a bare build
/// (`swift build`, `--snapshot`) reads `Resources/icon-preview.png` and crops it to the icon itself.
enum AppIconImage {
    enum Source {
        /// Already an icon: transparent margins, rounded corners baked in.
        case icon(NSImage)
        /// A square crop of the preview render: still needs the rounded-rect mask.
        case preview(NSImage)
    }

    @MainActor static let shared: Source? = load()

    @MainActor private static func load() -> Source? {
        let fm = FileManager.default
        var candidates: [URL] = []
        if let bundled = Bundle.main.url(forResource: "icon-preview", withExtension: "png") { candidates.append(bundled) }
        if Bundle.main.bundleURL.pathExtension != "app", let exe = Bundle.main.executableURL {
            // .build/<config>/Tailbolt → <package>/Resources/icon-preview.png
            candidates.append(exe.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
                .appendingPathComponent("Resources/icon-preview.png"))
        }
        for url in candidates where fm.fileExists(atPath: url.path) {
            if let image = croppedPreview(url) { return .preview(image) }
        }
        if Bundle.main.bundleURL.pathExtension == "app", let icon = NSApp.applicationIconImage { return .icon(icon) }
        return nil
    }

    /// The preview render shows the icon with a shadow on a flat background; this finds the icon's bounding
    /// box (anything that differs clearly from the corner color) and returns that square.
    private static func croppedPreview(_ url: URL) -> NSImage? {
        guard let source = NSImage(contentsOf: url),
              let cg = source.cgImage(forProposedRect: nil, context: nil, hints: nil),
              let data = cg.dataProvider?.data, let base = CFDataGetBytePtr(data) else { return nil }
        let bpp = cg.bitsPerPixel / 8, bpr = cg.bytesPerRow, w = cg.width, h = cg.height
        guard bpp >= 3, w > 8, h > 8 else { return nil }
        func pixel(_ x: Int, _ y: Int) -> (Int, Int, Int) {
            let p = base + y * bpr + x * bpp
            return (Int(p[0]), Int(p[1]), Int(p[2]))
        }
        let bg = pixel(2, 2)
        let step = max(1, w / 320)
        var minX = w, minY = h, maxX = -1, maxY = -1
        var y = 0
        while y < h {
            var x = 0
            while x < w {
                let p = pixel(x, y)
                if max(abs(p.0 - bg.0), abs(p.1 - bg.1), abs(p.2 - bg.2)) > 60 {
                    minX = min(minX, x); maxX = max(maxX, x)
                    minY = min(minY, y); maxY = max(maxY, y)
                }
                x += step
            }
            y += step
        }
        guard maxX > minX, maxY > minY else { return nil }
        let side = max(maxX - minX, maxY - minY) + step
        let rect = CGRect(x: minX, y: minY, width: min(side, w - minX), height: min(side, h - minY))
        guard let crop = cg.cropping(to: rect) else { return nil }
        return NSImage(cgImage: crop, size: NSSize(width: rect.width, height: rect.height))
    }
}

/// Dock-style rendition of the app icon with a soft shadow (`shadow: false` when the caller draws its own –
/// the onboarding stages animate a bigger one).
struct AppIconView: View {
    var size: CGFloat = 96
    var shadow = true

    var body: some View {
        Group {
            switch AppIconImage.shared {
            case .icon(let image):
                Image(nsImage: image)
                    .resizable()
                    .interpolation(.high)
                    .scaledToFit()
                    .frame(width: size, height: size)
            case .preview(let image):
                // Apple's icon grid: the rounded square covers 80.5 % of the canvas, radius 22.37 % of its side.
                let side = size * 0.805
                Image(nsImage: image)
                    .resizable()
                    .interpolation(.high)
                    .scaledToFill()
                    .frame(width: side, height: side)
                    .clipShape(RoundedRectangle(cornerRadius: side * 0.2237, style: .continuous))
                    .frame(width: size, height: size)
            case nil:
                let side = size * 0.805
                RoundedRectangle(cornerRadius: side * 0.2237, style: .continuous)
                    .fill(LinearGradient(colors: [Color(red: 0.42, green: 0.22, blue: 0.86), Color(red: 0.16, green: 0.08, blue: 0.46)],
                                         startPoint: .top, endPoint: .bottom))
                    .overlay(Image(systemName: "bolt.fill").font(.system(size: side * 0.5, weight: .medium)).foregroundStyle(.white))
                    .frame(width: side, height: side)
                    .frame(width: size, height: size)
            }
        }
        .shadow(color: .black.opacity(shadow ? 0.22 : 0), radius: shadow ? size * 0.05 : 0, y: shadow ? size * 0.025 : 0)
        .accessibilityHidden(true)
    }
}

/// Throughput test against one device: streams 128 MB of random data through the real transfer path
/// (tunnel + LAN-Turbo); the receiver throws it away. All engine work stays off the main thread.
@MainActor @Observable
final class BenchModel {
    struct Result {
        let bytes: Int64
        let seconds: Double
        let usedLAN: Bool
        var bytesPerSecond: Double { seconds > 0 ? Double(bytes) / seconds : 0 }
    }

    enum Phase {
        case idle
        case connecting
        case running(fraction: Double, speed: Double)
        case done(Result)
        case failed(String)
    }

    /// One test at a time, app-wide – it keeps running while the user switches tabs or closes the window.
    static let shared = BenchModel()

    var phase: Phase = .idle

    var isRunning: Bool {
        switch phase {
        case .connecting, .running: return true
        default: return false
        }
    }

    @ObservationIgnored private var transfer: OutgoingTransfer?
    @ObservationIgnored private var timer: Timer?
    @ObservationIgnored private var run = UUID()
    @ObservationIgnored private var sawLAN = false
    @ObservationIgnored private var lastSample: (Date, Int64)?
    @ObservationIgnored private var speed: Double = 0
    @ObservationIgnored private var startedAt: Date?

    static func demo(_ result: Result) -> BenchModel {
        let m = BenchModel()
        m.phase = .done(result)
        return m
    }

    func start(device: Device, myName: String) {
        guard !isRunning else { return }
        phase = .connecting
        sawLAN = false
        lastSample = nil
        speed = 0
        startedAt = nil
        let token = UUID()
        run = token
        let host = device.peer.address
        // Same rule as AppModel.send: direct LAN streams only when Einstellungen → Senden allows them.
        let lanHint = Settings.shared.lanTurboEnabled && device.peer.path == .lan ? device.peer.directHost : nil
        Task.detached(priority: .userInitiated) {
            // The initializer fills a 16 MB chunk with random bytes – not something for the main thread.
            let t = OutgoingTransfer(benchHost: host, myName: myName)
            t.peerLANHint = lanHint
            await MainActor.run { self.attach(t, token: token) }
        }
    }

    func cancel() {
        run = UUID()
        transfer?.cancel()
        transfer = nil
        stopTimer()
        phase = .idle
    }

    private func attach(_ t: OutgoingTransfer, token: UUID) {
        guard run == token, isRunning else { return }   // cancelled while the buffer was being prepared
        transfer = t
        t.onStateChange = { [weak self] state in
            DispatchQueue.main.async { self?.stateChanged(state, of: t, token: token) }
        }
        t.start()
        timer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
    }

    private func stateChanged(_ state: TransferState, of t: OutgoingTransfer, token: UUID) {
        guard run == token else { return }
        switch state {
        case .preparing, .waiting:
            phase = .connecting
        case .transferring:
            startedAt = Date()
            phase = .running(fraction: 0, speed: 0)
        case .finishing:
            tick()
        case .finished:
            let elapsed = startedAt.map { Date().timeIntervalSince($0) } ?? 0
            let seconds = t.transferSeconds > 0 ? t.transferSeconds : elapsed
            if t.stats.usesLAN { sawLAN = true }
            phase = .done(Result(bytes: t.totalBytes, seconds: seconds, usedLAN: sawLAN))
            finish()
        case .declined(let reason):
            phase = .failed(reason ?? String(localized: "The device declined the test"))
            finish()
        case .failed(let reason):
            phase = .failed(reason)
            finish()
        case .cancelled(let reason):
            if let reason { phase = .failed(reason) } else { phase = .idle }
            finish()
        }
    }

    private func tick() {
        guard let t = transfer, case .running = phase else { return }
        let now = Date()
        let bytes = t.bytesTransferred
        if t.stats.usesLAN { sawLAN = true }
        if let (at, b) = lastSample {
            let dt = now.timeIntervalSince(at)
            if dt >= 0.3 {
                let inst = Double(bytes - b) / dt
                speed = speed == 0 ? inst : speed * 0.6 + inst * 0.4
                lastSample = (now, bytes)
            }
        } else {
            lastSample = (now, bytes)
        }
        let fraction = t.totalBytes > 0 ? Double(bytes) / Double(t.totalBytes) : 0
        phase = .running(fraction: min(1, fraction), speed: speed)
    }

    private func finish() {
        stopTimer()
        transfer = nil
    }

    private func stopTimer() {
        timer?.invalidate()
        timer = nil
    }
}

/// The Info tab: icon, version, this device's place in the tailnet and the speed test.
struct AboutView: View {
    @State private var app = AppModel.shared
    @State private var settings = Settings.shared
    @State private var bench = SettingsPreview.bench ?? BenchModel.shared
    @State private var target = ""
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    static var versionText: String {
        let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String
        if let build, !build.isEmpty, !build.hasPrefix("__") { return "Version \(Tailbolt.appVersion) (\(build))" }
        return "Version \(Tailbolt.appVersion)"
    }

    private var candidates: [Device] { app.devices.filter { !$0.viaTaildrop } }

    var body: some View {
        VStack(spacing: 0) {
            header
            Form {
                Section("This device") {
                    LabeledContent("Name", value: app.myName)
                    LabeledContent("Tailnet", value: app.status?.tailnetName ?? "–")
                    LabeledContent("Tailscale") {
                        HStack(spacing: 6) {
                            Circle().fill(statusColor).frame(width: 7, height: 7)
                            Text(statusText)
                        }
                        .accessibilityElement(children: .combine)
                    }
                    LabeledContent("Tailscale IP", value: app.status?.selfIPs.first ?? "–")
                    LabeledContent("Receiving", value: "Port \(Tailbolt.defaultPort) (TCP)")
                    LabeledContent("Protocol", value: "Version \(Tailbolt.protocolVersion) · " + (LZ4.available ? "LZ4 · " : "") + String(localized: "LAN Turbo"))
                }

                Section {
                    if candidates.isEmpty {
                        LabeledContent("Device") {
                            Text("No device with Tailbolt online").foregroundStyle(.secondary)
                        }
                    } else {
                        Picker("Device", selection: $target) {
                            ForEach(candidates) { d in
                                Text(d.name).tag(d.id)
                            }
                        }
                        .disabled(bench.isRunning)
                        .help("Device to test against")
                    }
                    HStack(spacing: 12) {
                        benchStatus
                        Spacer(minLength: 12)
                        if bench.isRunning {
                            Button("Cancel") { bench.cancel() }
                        } else {
                            Button("Test") { startBench() }
                                .disabled(candidates.first { $0.id == target } == nil)
                                .help("Send 128 MB to the selected device and measure the speed")
                        }
                    }
                    .animation(reduceMotion ? nil : .easeOut(duration: 0.2), value: bench.isRunning)
                } header: {
                    Text("Speed test")
                } footer: {
                    SettingsFooter(String(localized: "Sends \(ByteFormat.string(OutgoingTransfer.benchSize)) of random data to the device – nothing is saved there. The result shows what the connection can really do: direct or with LAN Turbo, far more than over a relay."))
                }
            }
            .formStyle(.grouped)
        }
        .onAppear { pickDefaultTarget() }
        .onChange(of: app.devices.map(\.id)) { _, _ in pickDefaultTarget() }
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 22) {
            AppIconView(size: 104)
            VStack(alignment: .leading, spacing: 3) {
                Text(verbatim: "Tailbolt")
                    .font(.system(size: 26, weight: .bold))
                Text(Self.versionText)
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
                Text("AirDrop for your whole tailnet.")
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
                    .padding(.top, 6)
                HStack(spacing: 14) {
                    if let url = SettingsActions.readmeURL {
                        Link("README", destination: url)
                            .help(url.absoluteString)
                    }
                    Text(verbatim: "© 2026 Korel Uyar")
                        .foregroundStyle(.tertiary)
                }
                .font(.system(size: 11))
                .padding(.top, 8)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 32)
        .padding(.top, 26)
        .padding(.bottom, 4)
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder
    private var benchStatus: some View {
        switch bench.phase {
        case .idle:
            Text("Not tested yet")
                .foregroundStyle(.secondary)
        case .connecting:
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("Connecting…").foregroundStyle(.secondary)
            }
        case .running(let fraction, let speed):
            VStack(alignment: .leading, spacing: 4) {
                ProgressView(value: fraction)
                    .frame(width: 220)
                    .accessibilityLabel("Test progress")
                Text("\(Int(fraction * 100)) %" + (speed > 0 ? " · \(ByteFormat.speed(speed))" : ""))
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
        case .done(let r):
            HStack(spacing: 8) {
                Text(ByteFormat.speed(r.bytesPerSecond))
                    .font(.system(size: 15, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                PathCapsule(label: r.usedLAN ? String(localized: "LAN Turbo") : String(localized: "Tunnel"), tint: r.usedLAN ? .accentColor : .secondary, bolt: r.usedLAN)
                    .help(r.usedLAN ? String(localized: "Went over direct LAN connections next to the tunnel") : String(localized: "Went only through the Tailscale tunnel"))
                Text("\(ByteFormat.string(r.bytes)) in \(Self.seconds(r.seconds))")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            .accessibilityElement(children: .combine)
        case .failed(let message):
            Label(message, systemImage: "exclamationmark.triangle")
                .font(.system(size: 12))
                .foregroundStyle(.red)
                .lineLimit(2)
        }
    }

    private var statusColor: Color {
        if app.serverError != nil || (app.status == nil && app.hasRefreshed) { return .red }
        return app.status?.running == true ? .green : .orange
    }

    private var statusText: String {
        if let e = app.serverError { return String(localized: "Can’t receive: \(e)") }
        if app.tailscaleMissing { return String(localized: "Not installed") }
        guard let s = app.status else { return app.hasRefreshed ? String(localized: "Unreachable") : String(localized: "Connecting…") }
        return s.running ? String(localized: "Connected") : String(localized: "Stopped")
    }

    private func pickDefaultTarget() {
        let ids = candidates.map(\.id)
        guard !ids.contains(target) else { return }
        if let last = settings.lastDeviceID, ids.contains(last) { target = last } else { target = ids.first ?? "" }
    }

    private func startBench() {
        guard let device = candidates.first(where: { $0.id == target }) else { return }
        bench.start(device: device, myName: app.myName)
    }

    static func seconds(_ s: Double) -> String {
        let f = NumberFormatter()
        f.minimumFractionDigits = s < 10 ? 1 : 0
        f.maximumFractionDigits = s < 10 ? 1 : 0
        return (f.string(from: NSNumber(value: s)) ?? "\(s)") + " s"
    }
}
