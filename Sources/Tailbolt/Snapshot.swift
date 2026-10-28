import AppKit
import SwiftUI
import TailboltCore

/// Dev aid: `Tailbolt --snapshot <dir> [files…]` renders the main surfaces to PNGs (light + dark, 2x) and quits.
@MainActor
enum Snapshot {
    /// Retina output; the point sizes stay the real ones.
    static let scale: CGFloat = 2

    static func run(dir: URL, files: [URL]) {
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        // The Finder Quick Action bundle, for inspection (plutil -lint) – nothing is installed.
        try? QuickActionInstaller.write(to: dir.appendingPathComponent("\(QuickActionInstaller.name).workflow"))
        let app = AppModel.shared
        if ProcessInfo.processInfo.environment["TAILBOLT_DEMO"] == "1" { app.useDemoTailnet() } else { app.debugMarkPeersAvailable() }
        let devices = app.devices

        // Shelf with a transfer running to the first device; the same send is the popover's "Recent" row.
        let shelf = ShelfModel()
        shelf.files = files
        shelf.note = String(localized: "Cut for Friday – music still missing")
        if let d = devices.first {
            let t = TransferItem(direction: .outgoing, deviceID: d.id, peerName: d.name, peerSymbol: d.symbol, names: ["Video.mov"])
            t.totalBytes = 4_200_000_000; t.bytes = 1_700_000_000; t.state = .transferring; t.speed = 112_000_000
            shelf.sent[d.id] = t
            app.transfers.append(t)
            if !files.isEmpty { app.debugSetLastPayload(files, to: d) }
        }
        let waiting = TransferItem(direction: .incoming, deviceID: nil, peerName: "Noah’s MacBook Pro", peerSymbol: "laptopcomputer",
                                   names: ["Project Export", "notes.pdf", "logo.png"])
        waiting.totalBytes = 2_400_000_000; waiting.state = .waiting; waiting.awaitingDecision = true
        waiting.note = String(localized: "Here’s the export for Monday’s pitch. The logo is the new one, please check it 🙏")
        let running = TransferItem(direction: .incoming, deviceID: nil, peerName: "Sara’s MacBook Pro", peerSymbol: "laptopcomputer",
                                   names: ["Vacation 2026"])
        running.totalBytes = 18_000_000_000; running.bytes = 6_300_000_000; running.state = .transferring; running.speed = 240_000_000
        running.lanStreams = 4; running.everUsedLAN = true
        let done = TransferItem(direction: .incoming, deviceID: nil, peerName: "home-server", peerSymbol: "server.rack", names: ["backup.tar.zst"])
        done.totalBytes = 900_000_000; done.bytes = done.totalBytes; done.state = .finished
        done.startedTransferringAt = Date().addingTimeInterval(-1.9); done.finishedAt = Date()
        done.savedURLs = [URL(fileURLWithPath: "/tmp/x")]
        app.transfers.append(contentsOf: [waiting, running, done])

        // Shelf under keyboard control: ⌘ held (keycaps), second device selected, first flashing.
        let keyShelf = ShelfModel()
        keyShelf.files = files
        keyShelf.showKeycaps = true
        if devices.count > 1 { keyShelf.selectedID = devices[1].id }

        // Shelf beats: a send that just finished (green summary, checkmark), one that was declined (red), two
        // devices ⌘-selected (pill on the divider). The timestamps are refreshed right before each render.
        let beats = ShelfModel()
        beats.files = files
        var finished: TransferItem?
        var declined: TransferItem?
        if devices.count > 0 {
            let d = devices[0]
            let t = TransferItem(direction: .outgoing, deviceID: d.id, peerName: d.name, peerSymbol: d.symbol, names: ["Video.mov"])
            t.totalBytes = 2_400_000_000; t.bytes = t.totalBytes; t.state = .finished
            beats.sent[d.id] = t
            finished = t
        }
        if devices.count > 1 {
            let d = devices[1]
            let t = TransferItem(direction: .outgoing, deviceID: d.id, peerName: d.name, peerSymbol: d.symbol, names: ["Video.mov"])
            t.state = .declined(nil)
            beats.sent[d.id] = t
            declined = t
        }
        if devices.count > 1 { beats.multiSelection = Set(devices[1...min(2, devices.count - 1)].map(\.id)) }

        // LAN-Turbo streams and LZ4 saving on the first device.
        let turbo = ShelfModel()
        turbo.files = files
        if let d = devices.first {
            let t = TransferItem(direction: .outgoing, deviceID: d.id, peerName: d.name, peerSymbol: d.symbol, names: ["Project"])
            t.totalBytes = 4_200_000_000; t.bytes = 2_000_000_000; t.state = .transferring; t.speed = 312_000_000
            t.lanStreams = 4; t.bytesSaved = 1_240_000_000
            turbo.sent[d.id] = t
        }

        // The relay advice line (the panel grows by 32 pt) only ever goes with a send that has no LAN streams.
        // It gets its own model: a second active bubble next to the turbo one would make two wide bubbles
        // (2 × 156 pt) overflow the 320 pt strip and push its status line into the edge fade.
        let relay = ShelfModel()
        relay.files = files
        if let d = devices.first {
            let t = TransferItem(direction: .outgoing, deviceID: d.id, peerName: d.name, peerSymbol: d.symbol, names: ["Project"])
            t.totalBytes = 4_200_000_000; t.bytes = 500_000_000; t.state = .transferring; t.speed = 6_000_000
            t.hint = String(localized: "Running through a relay server (UDP blocked?) – much slower than direct.")
            relay.sent[d.id] = t
        }

        // Received thumbnails (bottom-right, screenshot-style) for the files given on the command line.
        if !files.isEmpty { ReceivedThumbController.shared.debugAdd(urls: files, from: "home-server") }

        // Settings state for the demo – everything below is restored before exit (snapshots must not change settings).
        let settings = Settings.shared
        let savedFavorites = settings.favoriteDeviceIDs
        let savedAlwaysAccept = settings.alwaysAcceptPeerIDs
        let savedNames = settings.knownDeviceNames
        if let d = devices.first { settings.setFavorite(id: d.id, name: d.name, slot: 1) }
        let demoPeers = Array(devices.prefix(2))
        settings.alwaysAcceptPeerIDs = demoPeers.map(\.id) + ["snapshot-offline-peer"]
        settings.knownDeviceNames["snapshot-offline-peer"] = "Noah’s MacBook Pro"
        SettingsPreview.relocationFolder = "Downloads"
        SettingsPreview.bench = BenchModel.demo(BenchModel.Result(bytes: OutgoingTransfer.benchSize, seconds: 0.31, usedLAN: true))
        if SettingsActions.openOnboarding == nil { SettingsActions.openOnboarding = {} }   // render the button as wired

        // HUD toast in its three phases – built from the same keys as the real toasts, so they localize alike.
        let noah = "Noah’s MacBook Pro"
        let itemCount = 3, percent = 41, favoriteSlot = 3
        let what = String(localized: "\(itemCount) items")
        let sending = ToastModel()
        sending.set(tone: .progress, symbol: "arrow.up.right", title: "→ \(noah)",
                    detail: String(localized: "Sending \(what) · \(percent) %") + " · \(ByteFormat.speed(112_000_000))", fraction: 0.41)
        let sent = ToastModel()
        sent.set(tone: .success, symbol: "checkmark.circle.fill", title: String(localized: "Sent to \(noah)"), detail: ByteFormat.string(4_200_000_000))
        let declinedToast = ToastModel()
        declinedToast.set(tone: .error, symbol: "xmark.circle.fill", title: String(localized: "Declined"), detail: String(localized: "by \(noah)"))
        let hint = ToastModel()
        hint.set(tone: .info, symbol: "star", title: String(localized: "Favorite \(favoriteSlot) isn’t set – right-click a device"))

        for dark in [false, true] {
            let suffix = dark ? "dark" : "light"
            render(ShelfView(model: shelf, onClose: {}), to: dir.appendingPathComponent("shelf-\(suffix).png"), dark: dark)
            render(ShelfView(model: ShelfModel(), onClose: {}), to: dir.appendingPathComponent("shelf-empty-\(suffix).png"), dark: dark)
            render(ShelfView(model: keyShelf, onClose: {}), to: dir.appendingPathComponent("shelf-keys-\(suffix).png"), dark: dark)
            // "2.4 GB in 8.1 s" shows for 6 s after the end, "Declined" for 8 s – restart the clocks for this render.
            finished?.startedTransferringAt = Date().addingTimeInterval(-8.1); finished?.finishedAt = Date()
            declined?.finishedAt = Date()
            render(ShelfView(model: beats, onClose: {}), to: dir.appendingPathComponent("shelf-beats-\(suffix).png"), dark: dark)
            render(ShelfView(model: turbo, onClose: {}), to: dir.appendingPathComponent("shelf-turbo-\(suffix).png"), dark: dark)
            render(ShelfView(model: relay, onClose: {}), to: dir.appendingPathComponent("shelf-relay-\(suffix).png"), dark: dark)
            if !files.isEmpty {
                render(ShelfView(model: shelf, onClose: {}, expandedList: true), to: dir.appendingPathComponent("shelf-list-\(suffix).png"), dark: dark)
            }
            render(MenuView(close: {}).background(VisualEffect()), to: dir.appendingPathComponent("menu-\(suffix).png"), dark: dark)
            render(VStack(spacing: 8) { IncomingCard(item: waiting); IncomingCard(item: running); IncomingCard(item: done) }.padding(10),
                   to: dir.appendingPathComponent("incoming-\(suffix).png"), dark: dark)
            if !files.isEmpty {
                render(ReceivedThumbStack(), to: dir.appendingPathComponent("received-\(suffix).png"), dark: dark)
            }
            render(VStack(spacing: 12) { ToastView(model: sending); ToastView(model: sent); ToastView(model: declinedToast); ToastView(model: hint) }.padding(10),
                   to: dir.appendingPathComponent("toast-\(suffix).png"), dark: dark)

            // The settings window as a whole – title bar, preference toolbar and pane – one PNG per tab.
            let appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
            for tab in SettingsTab.allCases {
                let controller = SettingsWindow.makeController(tab: tab, appearance: appearance) { root in
                    AnyView(root.toggleStyle(ActiveSwitchStyle()))
                }
                renderWindow(controller.window, to: dir.appendingPathComponent("settings-\(tab.rawValue)-\(suffix).png"), dark: dark)
            }
        }
        renderOnboarding(dir: dir)
        settings.favoriteDeviceIDs = savedFavorites
        settings.alwaysAcceptPeerIDs = savedAlwaysAccept
        settings.knownDeviceNames = savedNames
        exit(0)
    }

    /// Every onboarding page, light + dark, with the demo clock frozen at a representative moment.
    private static func renderOnboarding(dir: URL) {
        let pages: [(OnboardingPage, TimeInterval, String)] = [
            (.welcome, 2.6, "0-welcome"), (.tailscale, 2.4, "0b-tailscale"), (.send, 2.8, "1-send-a"), (.send, 4.4, "1-send-b"),
            (.devices, 1.7, "2-devices"), (.receive, 3.6, "3-receive"), (.shortcuts, 1.5, "4-shortcuts-a"), (.shortcuts, 5.1, "4-shortcuts-b"),
            (.ready, 1.6, "5-ready"),
        ]
        OnboardingMocks.prepareFiles()
        for (page, t, name) in pages {
            let state = OnboardingState()
            state.frozenTime = t
            state.tailscaleNeedsSetup = page == .tailscale
            state.page = page
            state.visited = Set(OnboardingPage.allCases.filter { $0.rawValue <= page.rawValue })
            for dark in [false, true] {
                render(OnboardingView(state: state), to: dir.appendingPathComponent("onboarding-\(name)-\(dark ? "dark" : "light").png"),
                       dark: dark, chrome: false)
            }
        }
    }

    private static func gradient(dark: Bool) -> NSGradient? {
        dark ? NSGradient(starting: NSColor(white: 0.16, alpha: 1), ending: NSColor(red: 0.1, green: 0.12, blue: 0.2, alpha: 1))
             : NSGradient(starting: NSColor(red: 0.85, green: 0.88, blue: 0.95, alpha: 1), ending: NSColor(red: 0.95, green: 0.9, blue: 0.86, alpha: 1))
    }

    /// Draws `view` into a fresh bitmap at `scale` – the off-screen window itself is 1x.
    private static func bitmap(of view: NSView) -> NSBitmapImageRep? {
        let b = view.bounds
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(b.width * scale), pixelsHigh: Int(b.height * scale),
                                         bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                         colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else { return nil }
        rep.size = b.size
        view.cacheDisplay(in: b, to: rep)
        return rep
    }

    /// `chrome: false` drops the padding/gradient backdrop (whole-window renders such as the onboarding pages).
    private static func render<V: View>(_ view: V, to url: URL, dark: Bool, chrome: Bool = true) {
        let root = view
            .padding(chrome ? 24 : 0)
            .background(LinearGradient(colors: dark ? [Color(white: 0.16), Color(red: 0.1, green: 0.12, blue: 0.2)]
                                                    : [Color(red: 0.85, green: 0.88, blue: 0.95), Color(red: 0.95, green: 0.9, blue: 0.86)],
                                       startPoint: .topLeading, endPoint: .bottomTrailing)
                        .opacity(chrome ? 1 : 0))
        let host = NSHostingView(rootView: root)
        host.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        NSApp.appearance = host.appearance   // AppKit controls inside (tab bar, pop-ups) follow the app appearance
        let size = host.fittingSize
        let window = NSWindow(contentRect: NSRect(origin: NSPoint(x: -4000, y: -4000), size: size), styleMask: .borderless,
                              backing: .buffered, defer: false)
        window.appearance = host.appearance
        window.contentView = host
        window.orderFrontRegardless()
        host.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(1.2))   // let AsyncImage/thumbnails/animations settle
        if let rep = bitmap(of: host) {
            try? rep.representation(using: .png, properties: [:])?.write(to: url)
        }
        window.orderOut(nil)
    }

    /// Captures a whole titled window (frame view = title bar + toolbar + content) and composes it like a
    /// macOS window screenshot: rounded corners and a soft shadow on the usual gradient.
    private static func renderWindow(_ window: NSWindow, to url: URL, dark: Bool) {
        NSApp.appearance = window.appearance
        window.setFrameOrigin(NSPoint(x: -4000, y: -4000))
        window.orderFrontRegardless()
        window.contentView?.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(1.0))
        defer { window.orderOut(nil) }
        guard let frame = window.contentView?.superview, let rep = bitmap(of: frame) else { return }
        let shot = NSImage(size: frame.bounds.size)
        shot.addRepresentation(rep)

        let pad: CGFloat = 40
        let radius: CGFloat = 12
        let size = NSSize(width: frame.bounds.width + pad * 2, height: frame.bounds.height + pad * 2)
        guard let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size.width * scale), pixelsHigh: Int(size.height * scale),
                                            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else { return }
        bitmap.size = size
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
        gradient(dark: dark)?.draw(in: NSRect(origin: .zero, size: size), angle: -45)
        let rect = NSRect(x: pad, y: pad, width: frame.bounds.width, height: frame.bounds.height)
        let shape = NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius)
        NSGraphicsContext.saveGraphicsState()
        let shadow = NSShadow()
        shadow.shadowBlurRadius = 24
        shadow.shadowOffset = NSSize(width: 0, height: -12)
        shadow.shadowColor = NSColor.black.withAlphaComponent(dark ? 0.6 : 0.32)
        shadow.set()
        (dark ? NSColor(white: 0.2, alpha: 1) : NSColor.white).setFill()
        shape.fill()
        NSGraphicsContext.restoreGraphicsState()
        NSGraphicsContext.saveGraphicsState()
        shape.addClip()
        shot.draw(in: rect)
        NSGraphicsContext.restoreGraphicsState()
        NSGraphicsContext.restoreGraphicsState()
        try? bitmap.representation(using: .png, properties: [:])?.write(to: url)
    }
}

/// `--snapshot` runs as an inactive accessory app, where NSSwitch paints every toggle grey. This replica
/// draws the key-window look (accent track, white knob) so the PNGs show what the user actually sees.
struct ActiveSwitchStyle: ToggleStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 8) {
            configuration.label
            Spacer(minLength: 8)
            ZStack(alignment: configuration.isOn ? .trailing : .leading) {
                Capsule()
                    .fill(configuration.isOn ? Color.accentColor : Color.primary.opacity(0.18))
                    .overlay(Capsule().strokeBorder(Color.primary.opacity(0.08), lineWidth: 0.5))
                Circle()
                    .fill(.white)
                    .shadow(color: .black.opacity(0.25), radius: 1, y: 0.5)
                    .padding(1.5)
            }
            .frame(width: 32, height: 18)
            .opacity(configuration.isOn ? 1 : 0.9)
        }
        .contentShape(Rectangle())
        .onTapGesture { configuration.isOn.toggle() }
    }
}

extension AppModel {
    /// Pretends every online computer/phone in the tailnet runs Tailbolt (for snapshots only).
    func debugMarkPeersAvailable() {
        guard let status else { return }
        for p in status.peers where p.online && ["macOS", "iOS", "windows", "linux"].contains(p.os) {
            debugSeen(p)
        }
    }
}
