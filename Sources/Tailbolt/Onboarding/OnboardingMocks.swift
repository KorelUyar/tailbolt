import AppKit
import SwiftUI
import TailboltCore

/// Demo data shared by all onboarding stages. Devices are real `Device` values (so `DeviceAvatar`,
/// `Palette` etc. render them exactly like the app does); files are real temp files so `FileThumb`
/// and QuickLook work. Sizes shown in labels are fixed strings, never computed.
@MainActor
enum OnboardingMocks {
    // MARK: devices

    static let noah = Device(
        peer: .make(id: "mock-noah", hostName: "Noahs MacBook Pro", dnsName: "noahs-macbook-pro.tail.ts.net",
                    ips: ["100.101.1.1"], os: "macOS",
                    user: .make(id: 11, loginName: "noah@example.com", displayName: "Noah Meier")),
        hello: HelloInfo(name: "Noahs MacBook Pro", os: "macOS", app: Tailbolt.appVersion))

    static let lena = Device(
        peer: .make(id: "mock-lena", hostName: "Lena – Mac Studio", dnsName: "lena-mac-studio.tail.ts.net",
                    ips: ["100.101.1.2"], os: "macOS",
                    user: .make(id: 12, loginName: "lena.keller@example.com", displayName: "Lena Keller")),
        hello: HelloInfo(name: "Lena – Mac Studio", os: "macOS", app: Tailbolt.appVersion))

    static let server = Device(
        peer: .make(id: "mock-server", hostName: "home-server", dnsName: "home-server.tail.ts.net",
                    ips: ["100.101.1.3"], os: "linux", isMine: true),
        hello: HelloInfo(name: "home-server", os: "linux", app: Tailbolt.appVersion))

    static let iphone = Device(
        peer: .make(id: "mock-iphone", hostName: "Mein iPhone", dnsName: "mein-iphone.tail.ts.net",
                    ips: ["100.101.1.4"], os: "iOS", isMine: true, taildropAvailable: true),
        hello: nil)

    static let marco = Device(
        peer: .make(id: "mock-marco", hostName: "Marco (Windows)", dnsName: "marco-windows.tail.ts.net",
                    ips: ["100.101.1.5"], os: "windows",
                    user: .make(id: 13, loginName: "marco.furrer@example.com", displayName: "Marco Furrer")),
        hello: HelloInfo(name: "Marco (Windows)", os: "windows", app: Tailbolt.appVersion))

    /// The three devices shown in the shake demo's shelf.
    static var shelfDevices: [Device] { [noah, lena, server] }

    /// Five bubbles for the devices page, in role order: other, other, mine, Taildrop, other.
    /// Real devices of the same role replace the mocks so people see their actual colleagues.
    static func bubbleDevices() -> [Device] {
        let real = AppModel.shared.devices
        let others = real.filter { !$0.peer.isMine && !$0.viaTaildrop }
        let mine = real.filter { $0.peer.isMine && !$0.viaTaildrop }
        let taildrop = real.first { $0.viaTaildrop }
        return [others.count > 0 ? others[0] : noah,
                others.count > 1 ? others[1] : lena,
                mine.first ?? server,
                taildrop ?? iphone,
                others.count > 2 ? others[2] : marco]
    }

    /// Devices around the icon on the last page: the real ones, or three greyed mocks.
    static func liveDevices() -> (devices: [Device], real: Bool) {
        let real = AppModel.shared.devices.filter { !$0.viaTaildrop }
        if real.isEmpty { return ([noah, lena, server], false) }
        return (Array(real.prefix(6)), true)
    }

    // MARK: files

    static let directory = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("tailbolt-onboarding", isDirectory: true)
    static var video: URL { directory.appendingPathComponent("Ferien-Video.mov") }
    static var folder: URL { directory.appendingPathComponent("Projekt-Export", isDirectory: true) }
    static var notes: URL { directory.appendingPathComponent("notes.pdf") }
    static var logo: URL { directory.appendingPathComponent("logo.png") }
    static var tryIt: URL { directory.appendingPathComponent("Tailbolt-Test.txt") }

    private static var prepared = false

    /// Creates the temp files once per process (cheap; idempotent).
    static func prepareFiles() {
        guard !prepared else { return }
        prepared = true
        let fm = FileManager.default
        try? fm.createDirectory(at: folder, withIntermediateDirectories: true)
        for url in [video, notes] where !fm.fileExists(atPath: url.path) {
            fm.createFile(atPath: url.path, contents: Data())
        }
        for name in ["Skizzen.sketch", "Export.zip", "README.md"] {
            let f = folder.appendingPathComponent(name)
            if !fm.fileExists(atPath: f.path) { fm.createFile(atPath: f.path, contents: Data()) }
        }
        if !fm.fileExists(atPath: tryIt.path) {
            try? "Hallo von Tailbolt\n".data(using: .utf8)?.write(to: tryIt)
        }
        if !fm.fileExists(atPath: logo.path), let png = AppIconRenderer.png(pixels: 256) {
            try? png.write(to: logo)
        }
    }

    static func removeFiles() {
        try? FileManager.default.removeItem(at: directory)
        prepared = false
    }
}

/// Renders the app icon as a bitmap for the onboarding's demo files (`logo.png`). Inside the bundle the real
/// AppIcon.icns is used; a bare binary (snapshots, `swift run`) gets the preview render or a drawn stand-in
/// (indigo squircle + bolt, same palette as `scripts/make-icon.swift`).
enum AppIconRenderer {
    static let stops = [NSColor(red: 0.42, green: 0.22, blue: 0.86, alpha: 1),
                        NSColor(red: 0.30, green: 0.16, blue: 0.70, alpha: 1),
                        NSColor(red: 0.16, green: 0.08, blue: 0.46, alpha: 1)]

    @MainActor
    static func image(pixels px: Int) -> NSImage? {
        if let icns = NSImage(contentsOfFile: Bundle.main.bundlePath + "/Contents/Resources/AppIcon.icns") {
            let out = NSImage(size: NSSize(width: px, height: px))
            out.lockFocus()
            icns.draw(in: NSRect(x: 0, y: 0, width: px, height: px), from: .zero, operation: .sourceOver, fraction: 1)
            out.unlockFocus()
            return out
        }
        if case .preview(let preview) = AppIconImage.shared {
            let out = NSImage(size: NSSize(width: px, height: px))
            out.lockFocus()
            let s = CGFloat(px), side = s * 0.805, inset = (s - side) / 2
            let body = NSRect(x: inset, y: inset, width: side, height: side)
            NSBezierPath(roundedRect: body, xRadius: side * 0.2237, yRadius: side * 0.2237).addClip()
            preview.draw(in: body, from: .zero, operation: .sourceOver, fraction: 1)
            out.unlockFocus()
            return out
        }
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px, bitsPerSample: 8, samplesPerPixel: 4,
                                         hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)
        else { return nil }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        let s = CGFloat(px)
        let inset = s * 100 / 1024
        let body = NSRect(x: inset, y: inset, width: s - inset * 2, height: s - inset * 2)
        let path = NSBezierPath(roundedRect: body, xRadius: body.width * 0.225, yRadius: body.width * 0.225)
        NSGradient(colors: stops)!.draw(in: path, angle: -60)
        NSGraphicsContext.saveGraphicsState()
        path.addClip()
        NSGradient(colors: [NSColor.white.withAlphaComponent(0.22), NSColor.white.withAlphaComponent(0)])!
            .draw(in: NSRect(x: body.minX, y: body.midY, width: body.width, height: body.height / 2), angle: -90)
        NSGraphicsContext.restoreGraphicsState()
        let config = NSImage.SymbolConfiguration(pointSize: s * 0.42, weight: .medium).applying(.init(paletteColors: [.white]))
        if let sym = NSImage(systemSymbolName: "bolt.fill", accessibilityDescription: nil)?.withSymbolConfiguration(config) {
            let size = sym.size
            sym.draw(in: NSRect(x: body.midX - size.width / 2, y: body.midY - size.height / 2, width: size.width, height: size.height))
        }
        NSGraphicsContext.restoreGraphicsState()
        let img = NSImage(size: NSSize(width: px, height: px))
        img.addRepresentation(rep)
        return img
    }

    @MainActor
    static func png(pixels: Int) -> Data? {
        image(pixels: pixels)?.representations.first.flatMap { ($0 as? NSBitmapImageRep)?.representation(using: .png, properties: [:]) }
    }
}
