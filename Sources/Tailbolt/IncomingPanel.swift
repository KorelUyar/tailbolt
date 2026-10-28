import AppKit
import Carbon.HIToolbox
import Observation
import SwiftUI
import TailboltCore
import UniformTypeIdentifiers

/// Key only while a card waits for a decision (⏎ / ⎋); never activates the app, never becomes main.
/// The keyboard is taken once per new offer, never re-taken on the timer: one stray keystroke hands it back for good.
final class IncomingPanel: NSPanel {
    var wantsKeyboard = false
    override var canBecomeKey: Bool { wantsKeyboard }
    override var canBecomeMain: Bool { false }
}

/// Transient state the cards read: ⌥ held while the panel is key turns "Annehmen" into "Immer annehmen".
@MainActor @Observable
final class IncomingUIState {
    static let shared = IncomingUIState()
    var optionHeld = false
}

/// AirDrop-style cards in the top-right corner for incoming transfers.
@MainActor
final class IncomingPanelController {
    static let shared = IncomingPanelController()

    private var panel: IncomingPanel?
    private var hosting: NSHostingView<IncomingStack>?
    private var timer: Timer?
    private var keyMonitor: Any?
    private var flagsMonitor: Any?
    private var announced: Set<UUID> = []
    private var handedOff: Set<UUID> = []
    /// Offers that already had their one keyboard grab (or whose grab the user cancelled by typing on).
    private var grabbed: Set<UUID> = []

    /// Cards on screen: offers, running transfers, and terminal ones for a moment – declined/failed for 6 s,
    /// finished just long enough for the bar to fill before the card collapses into the floating thumbnail.
    var visibleItems: [TransferItem] {
        let now = Date()
        return AppModel.shared.transfers.filter { t in
            guard t.direction == .incoming, !t.dismissed else { return false }
            guard let end = t.finishedAt else { return true }
            let linger: TimeInterval = t.state == .finished ? (t.savedURLs.isEmpty ? 2.5 : 0.7) : 6
            return now.timeIntervalSince(end) < linger
        }
    }

    func update() {
        handOffFinished()
        announceOffers()
        let items = visibleItems
        if items.isEmpty {
            keyboard(wanted: false)
            if let panel, panel.isVisible {
                NSAnimationContext.runAnimationGroup({ ctx in
                    ctx.duration = 0.2
                    panel.animator().alphaValue = 0
                }, completionHandler: {
                    MainActor.assumeIsolated {
                        if self.visibleItems.isEmpty { panel.orderOut(nil) }
                    }
                })
            }
            timer?.invalidate()
            timer = nil
            return
        }
        let panel = self.panel ?? makePanel()
        self.panel = panel
        layout()
        if !panel.isVisible || panel.alphaValue < 1 {
            panel.alphaValue = 0
            panel.orderFrontRegardless()
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.2
                panel.animator().alphaValue = 1
            }
        }
        keyboard(wanted: items.contains(where: \.awaitingDecision))
        if timer == nil {
            timer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { _ in
                MainActor.assumeIsolated { self.update() }
            }
        }
    }

    /// ⌥-click / ⌥⏎ on "Annehmen": this peer's offers are accepted without asking from now on.
    func acceptAlways(_ item: TransferItem) {
        if let id = item.deviceID {
            Settings.shared.setAlwaysAccept(id, name: item.peerName, on: true)
            ToastController.shared.flash("Von \(item.peerName) wird ab jetzt immer angenommen", symbol: "checkmark.shield", tone: .info, duration: 3)
        }
        AppModel.shared.accept(item)
        update()
    }

    /// Finished cards become floating thumbnails (bottom-right, like macOS screenshots) after a short beat.
    private func handOffFinished() {
        let transfers = AppModel.shared.transfers
        let now = Date()
        for t in transfers where t.direction == .incoming && t.state == .finished && !t.savedURLs.isEmpty && !handedOff.contains(t.id) {
            guard let end = t.finishedAt, now.timeIntervalSince(end) >= 0.6 else { continue }
            handedOff.insert(t.id)
            t.dismissed = true
            Feedback.transferFinished(t)
            ReceivedThumbController.shared.add(t)
        }
        if handedOff.count > 64 { handedOff = handedOff.filter { id in transfers.contains { $0.id == id } } }
        if grabbed.count > 64 { grabbed = grabbed.filter { id in transfers.contains { $0.id == id } } }
    }

    private func announceOffers() {
        for t in visibleItems where t.awaitingDecision && !announced.contains(t.id) {
            announced.insert(t.id)
            let what = t.names.count == 1 ? "«\(t.names[0])»" : "\(t.names.count) Objekte"
            let text = "\(t.peerName) möchte \(what) senden, \(ByteFormat.string(t.totalBytes)). Annehmen mit Eingabetaste, Ablehnen mit Escape."
            NSAccessibility.post(element: NSApp as Any, notification: .announcementRequested,
                                 userInfo: [.announcement: text, .priority: NSAccessibilityPriorityLevel.high.rawValue])
        }
    }

    // MARK: keyboard

    /// Takes the keyboard exactly once for every new offer. `update()` runs this every 250 ms, so it must not
    /// re-grab: after the user typed on (or clicked into another app) the panel stays quiet until a new card
    /// appears. While the shelf, popover or settings window is key the grab waits – their ↩/⎋ must never accept
    /// or decline an offer.
    private func keyboard(wanted: Bool) {
        guard let panel else { return }
        guard wanted else {
            if panel.wantsKeyboard { releaseKeyboard() }
            return
        }
        let fresh = visibleItems.filter { $0.awaitingDecision && !grabbed.contains($0.id) }
        guard !fresh.isEmpty, !otherWindowIsKey else { return }
        grabbed.formUnion(fresh.map(\.id))
        if !panel.isKeyWindow {
            panel.wantsKeyboard = true
            panel.makeKey()
        }
        installMonitors()
    }

    /// Another Tailbolt window owns the keys (`NSApp.keyWindow` is nil for an accessory app, so ask the windows).
    private var otherWindowIsKey: Bool {
        NSApp.windows.contains { $0 !== panel && $0.isKeyWindow }
    }

    /// Hands the keyboard back to the app in front. A non-activating panel only stops being key when it leaves the
    /// screen for a moment (nothing else in this app could take over); re-ordered in the same run-loop pass → no flicker.
    private func releaseKeyboard() {
        removeMonitors()
        guard let panel else { return }
        panel.wantsKeyboard = false
        if panel.isKeyWindow {
            let alpha = panel.alphaValue
            panel.orderOut(nil)
            panel.alphaValue = alpha
            if !visibleItems.isEmpty { panel.orderFrontRegardless() }
        }
    }

    private func installMonitors() {
        guard keyMonitor == nil else { return }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            let handled = MainActor.assumeIsolated { () -> Bool in
                guard let self else { return false }
                return self.handleKey(event)
            }
            return handled ? nil : event
        }
        flagsMonitor = NSEvent.addLocalMonitorForEvents(matching: .flagsChanged) { [weak self] event in
            MainActor.assumeIsolated {
                guard let self else { return }
                let held = event.modifierFlags.contains(.option) && self.panel?.isKeyWindow == true
                if IncomingUIState.shared.optionHeld != held { IncomingUIState.shared.optionHeld = held }
            }
            return event
        }
    }

    private func removeMonitors() {
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        if let flagsMonitor { NSEvent.removeMonitor(flagsMonitor) }
        keyMonitor = nil
        flagsMonitor = nil
        IncomingUIState.shared.optionHeld = false
    }

    /// ⏎ accepts the oldest waiting offer, ⌘⏎ accepts and reveals the files when done, ⌥⏎ accepts this peer for
    /// good, ⎋ declines. Any other key means the user is typing into their app: the keyboard goes back at once
    /// (that one keystroke is swallowed rather than beeped at) and stays there – every waiting offer is already in
    /// `grabbed`, so the timer will not take it again.
    private func handleKey(_ event: NSEvent) -> Bool {
        guard let panel, panel.isVisible, panel.isKeyWindow else { return false }
        guard !event.isARepeat else { return true }
        guard let item = visibleItems.last(where: \.awaitingDecision) else {
            releaseKeyboard()
            return false
        }
        let flags = event.modifierFlags.intersection(KeyCombo.modifierMask)
        switch Int(event.keyCode) {
        case kVK_Return, kVK_ANSI_KeypadEnter:
            if flags.contains(.option) {
                acceptAlways(item)
            } else {
                if flags.contains(.command) { item.revealWhenFinished = true }
                AppModel.shared.accept(item)
            }
        case kVK_Escape:
            AppModel.shared.decline(item)
        default:
            releaseKeyboard()
            return true
        }
        update()
        return true
    }

    // MARK: panel

    private func layout() {
        guard let panel, let hosting else { return }
        let size = hosting.intrinsicContentSize
        let screen = NSScreen.main ?? NSScreen.screens[0]
        let vf = screen.visibleFrame
        let frame = NSRect(x: vf.maxX - size.width - 10, y: vf.maxY - size.height - 10, width: size.width, height: size.height)
        if panel.frame != frame { panel.setFrame(frame, display: true) }
    }

    private func makePanel() -> IncomingPanel {
        let p = IncomingPanel(contentRect: NSRect(x: 0, y: 0, width: 372, height: 100),
                              styleMask: [.borderless, .nonactivatingPanel, .fullSizeContentView],
                              backing: .buffered, defer: false)
        p.isFloatingPanel = true
        p.level = .statusBar
        p.hidesOnDeactivate = false
        p.backgroundColor = .clear
        p.isOpaque = false
        p.hasShadow = false
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        let h = NSHostingView(rootView: IncomingStack())
        h.sizingOptions = [.intrinsicContentSize]
        p.contentView = h
        hosting = h
        return p
    }
}

// MARK: - Shared bits

/// Key glyph inside a button ("Annehmen ⏎").
struct KeyHintCap: View {
    let glyph: String
    var onAccent = false

    var body: some View {
        Text(glyph)
            .font(.system(size: 10, weight: .semibold, design: .rounded))
            .foregroundStyle(onAccent ? Color.white.opacity(0.92) : Color.secondary)
            .frame(minWidth: 14, minHeight: 14)
            .padding(.horizontal, 2)
            .background(RoundedRectangle(cornerRadius: 3.5, style: .continuous)
                .fill(onAccent ? Color.white.opacity(0.22) : Color.primary.opacity(0.08)))
            .accessibilityHidden(true)
    }
}

/// Up to three file-type icons for the names in an offer, fanned like a stack.
struct FileKindIcons: View {
    let names: [String]
    let isFolder: (String) -> Bool
    var size: CGFloat = 20

    @MainActor private static var cache: [String: NSImage] = [:]

    var body: some View {
        HStack(spacing: -size * 0.3) {
            ForEach(Array(names.prefix(3).enumerated()), id: \.offset) { i, name in
                Image(nsImage: Self.icon(for: name, folder: isFolder(name)))
                    .resizable()
                    .interpolation(.high)
                    .frame(width: size, height: size)
                    .shadow(color: .black.opacity(0.12), radius: 1, y: 0.5)
                    .zIndex(Double(3 - i))
            }
        }
        .accessibilityHidden(true)
    }

    @MainActor
    static func icon(for name: String, folder: Bool) -> NSImage {
        let ext = folder ? "/" : (name as NSString).pathExtension.lowercased()
        if let cached = cache[ext] { return cached }
        let type: UTType = folder ? .folder : (ext.isEmpty ? .data : (UTType(filenameExtension: ext) ?? .data))
        let icon = NSWorkspace.shared.icon(for: type)
        cache[ext] = icon
        return icon
    }
}

// MARK: - Cards

struct IncomingStack: View {
    @State private var app = AppModel.shared

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { _ in
            let items = IncomingPanelController.shared.visibleItems
            VStack(spacing: 8) {
                ForEach(items) { item in
                    IncomingCard(item: item)
                        .transition(.asymmetric(
                            insertion: Motion.reduced ? .opacity : .move(edge: .trailing).combined(with: .opacity),
                            removal: item.state == .finished && !Motion.reduced
                                ? .scale(scale: 0.25, anchor: .bottomTrailing).combined(with: .opacity)
                                : .opacity))
                }
            }
            .padding(10)   // room for the card shadows
            .frame(width: 372)
            .animation(Motion.spring(0.35, 0.8), value: items.map(\.id))
        }
    }
}

struct IncomingCard: View {
    let item: TransferItem
    @State private var hover = false
    @State private var app = AppModel.shared
    @State private var ui = IncomingUIState.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 12) {
                avatar
                VStack(alignment: .leading, spacing: 3) {
                    Text(item.peerName)
                        .font(.system(size: 13, weight: .semibold))
                        .lineLimit(1)
                    HStack(spacing: 4) {
                        if let symbol = stateSymbol {
                            Image(systemName: symbol.0)
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundStyle(symbol.1)
                        }
                        Text(stateLine)
                            .font(.system(size: 12))
                            .foregroundStyle(stateColor)
                            .lineLimit(1)
                            .truncationMode(.tail)
                        // LAN-Turbo / LZ4 sit here, where there is room; the progress line keeps its full ETA.
                        if !item.awaitingDecision { TransferCapsules(item: item) }
                    }
                    HStack(spacing: 7) {
                        FileKindIcons(names: item.names, isFolder: isFolder)
                        Text(itemsLine)
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                    .padding(.top, 2)
                }
                Spacer(minLength: 0)
                if hover && !item.awaitingDecision {
                    Button {
                        item.dismissed = true
                        IncomingPanelController.shared.update()
                    } label: {
                        Image(systemName: "xmark.circle.fill").font(.system(size: 14)).foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .help("Ausblenden")
                    .accessibilityLabel("Ausblenden")
                }
            }

            if item.awaitingDecision {
                decision
            } else if item.isActive {
                progress
            }
        }
        .padding(14)
        .frame(width: 352, alignment: .leading)
        .glassSurface(cornerRadius: 16, material: .hudWindow)
        .shadow(color: .black.opacity(0.2), radius: 9, y: 4)
        .onHover { hover = $0 }
        .animation(.easeOut(duration: 0.12), value: hover)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(accessibilityText)
    }

    // MARK: pieces

    @ViewBuilder
    private var avatar: some View {
        if let device = app.devices.first(where: { $0.id == item.deviceID }) {
            DeviceAvatar(device: device, size: 42)
                .accessibilityHidden(true)
        } else {
            Image(systemName: item.peerSymbol)
                .font(.system(size: 19))
                .foregroundStyle(.white)
                .shadow(color: .black.opacity(0.15), radius: 1, y: 1)
                .frame(width: 42, height: 42)
                .background(Circle().fill(LinearGradient(colors: Palette.gradients[0], startPoint: .top, endPoint: .bottom)))
                .overlay(Circle().strokeBorder(.white.opacity(0.18), lineWidth: 0.5))
                .accessibilityHidden(true)
        }
    }

    private var decision: some View {
        HStack(spacing: 8) {
            Button { app.decline(item) } label: {
                HStack(spacing: 6) {
                    Text("Ablehnen")
                    KeyHintCap(glyph: "⎋")
                }
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(PanelButtonStyle())
            .help("Ablehnen (⎋)")
            Button {
                if NSEvent.modifierFlags.contains(.option) {
                    IncomingPanelController.shared.acceptAlways(item)
                } else {
                    app.accept(item)
                }
            } label: {
                HStack(spacing: 6) {
                    Text(ui.optionHeld ? "Immer annehmen" : "Annehmen")
                    KeyHintCap(glyph: ui.optionHeld ? "⌥⏎" : "⏎", onAccent: true)
                }
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(PanelButtonStyle(prominent: true))
            .help("Annehmen (⏎) · ⌥-Klick: immer von \(item.peerName) annehmen · ⌘⏎: annehmen und im Finder zeigen")
            .accessibilityLabel(ui.optionHeld ? "Immer von \(item.peerName) annehmen" : "Annehmen")
        }
        .animation(.easeOut(duration: 0.12), value: ui.optionHeld)
    }

    private var progress: some View {
        VStack(alignment: .leading, spacing: 6) {
            Bar(value: item.state == .transferring || item.state == .finishing ? item.fraction : nil)
            HStack(spacing: 6) {
                Text(item.statusText)
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Spacer(minLength: 4)
                Button("Abbrechen") { item.cancel() }
                    .buttonStyle(LinkButtonStyle())
                    .help("Übertragung abbrechen")
            }
        }
    }

    // MARK: text

    private var isFolder: (String) -> Bool {
        let folders = Set(item.incoming?.items.filter(\.d).map(\.p) ?? [])
        return { name in
            if folders.contains(name) { return true }
            if item.incoming != nil { return false }
            return (name as NSString).pathExtension.isEmpty   // best guess without a manifest (snapshots)
        }
    }

    /// "eine Datei" / "einen Ordner" / "3 Objekte" – the names themselves sit in the item row below.
    private var countText: String {
        guard item.names.count == 1, let name = item.names.first else { return "\(item.names.count) Objekte" }
        return isFolder(name) ? "einen Ordner" : "eine Datei"
    }

    private var stateLine: String {
        switch item.state {
        case .waiting, .preparing: return "möchte dir \(countText) senden"
        case .transferring, .finishing: return "sendet dir \(countText)"
        case .finished: return "In «\(Settings.shared.downloadDirectory.lastPathComponent)» gespeichert"
        case .declined: return "Abgelehnt"
        case .failed(let r): return "Fehler: \(r)"
        case .cancelled(let r): return r ?? "Abgebrochen"
        }
    }

    private var stateSymbol: (String, Color)? {
        switch item.state {
        case .finished: return ("checkmark.circle.fill", .green)
        case .declined, .failed: return ("xmark.circle.fill", .red)
        case .cancelled: return ("minus.circle.fill", .secondary)
        default: return nil
        }
    }

    private var stateColor: Color {
        switch item.state {
        case .declined, .failed: return .red
        case .finished: return .primary
        default: return .secondary
        }
    }

    /// "Projekt-Export, notes.pdf und 1 weitere · 2,4 GB" – falls back to "Projekt-Export und 2 weitere" when the
    /// names would not fit on the line, measured with the row's font (a mid-word ellipsis reads worse than a count).
    private var itemsLine: String {
        let names = item.names
        let size = item.totalBytes > 0 ? " · \(ByteFormat.string(item.totalBytes))" : ""
        var s: String
        switch names.count {
        case 0: s = "Dateien"
        case 1: s = names[0]
        case 2: s = "\(names[0]), \(names[1])"
        default: s = "\(names[0]), \(names[1]) und \(names.count - 2) weitere"
        }
        if names.count > 1, Self.width(of: s + size) > itemsLineWidth {
            s = "\(names[0]) und \(names.count - 1) weitere"
        }
        return s + size
    }

    private static let itemsFont = NSFont.systemFont(ofSize: 11)

    private static func width(of text: String) -> CGFloat {
        (text as NSString).size(withAttributes: [.font: itemsFont]).width
    }

    /// Room for the names: card 352 − padding 28 − avatar 42 + 12 − fanned icons (20 + 14 per extra one) + 7, and
    /// the hover × (14 + 12) on cards that can show it; 2 pt for rounding.
    private var itemsLineWidth: CGFloat {
        let icons = CGFloat(min(3, max(1, item.names.count)))
        return 352 - 28 - 54 - (20 + (icons - 1) * 14) - 7 - (item.awaitingDecision ? 0 : 26) - 2
    }

    private var accessibilityText: String {
        var s = "\(item.peerName) \(stateLine). \(itemsLine)."
        if item.awaitingDecision { s += " Annehmen mit Eingabetaste, Ablehnen mit Escape." }
        return s
    }
}

/// Text-only button that reads as a link (secondary, primary on hover) and stays usable in non-key panels.
private struct LinkButtonStyle: ButtonStyle {
    @State private var hover = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 10, weight: .medium))
            .foregroundStyle(hover || configuration.isPressed ? Color.primary : Color.secondary)
            .contentShape(Rectangle())
            .onHover { hover = $0 }
    }
}

// MARK: - Received thumbnails

/// macOS-screenshot-style floating thumbnails in the bottom-right corner for files that just arrived: drag them
/// straight into Mail or a Finder window, click to open, right-click for more. They slide out after 8 s unless
/// the pointer rests on them; several arrivals stack vertically.
@MainActor @Observable
final class ReceivedThumbController {
    static let shared = ReceivedThumbController()
    static let lifetime: TimeInterval = 8

    struct Entry: Identifiable, Equatable {
        let id: UUID
        let urls: [URL]
        let peerName: String
        var shownAt: Date
        var hovered = false
    }

    private(set) var entries: [Entry] = []

    @ObservationIgnored private var panel: NSPanel?
    @ObservationIgnored private var hosting: NSHostingView<ReceivedThumbStack>?
    @ObservationIgnored private var timer: Timer?

    func add(_ item: TransferItem) {
        guard !item.savedURLs.isEmpty else { return }
        entries.append(Entry(id: item.id, urls: item.savedURLs, peerName: item.peerName, shownAt: Date()))
        present()
    }

    /// Dev aid (`--snapshot`): shows thumbnails for existing files without a transfer.
    func debugAdd(urls: [URL], from peerName: String) {
        entries.append(Entry(id: UUID(), urls: urls, peerName: peerName, shownAt: Date()))
    }

    func remove(_ id: UUID) {
        guard entries.contains(where: { $0.id == id }) else { return }
        entries.removeAll { $0.id == id }
        if entries.isEmpty {
            hide()
        } else {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in self?.layout() }
        }
    }

    func setHovered(_ id: UUID, _ hovered: Bool) {
        guard let i = entries.firstIndex(where: { $0.id == id }) else { return }
        entries[i].hovered = hovered
        if !hovered { entries[i].shownAt = Date() }   // leaving restarts the clock
    }

    private func present() {
        let panel = self.panel ?? makePanel()
        self.panel = panel
        layout()
        if timer == nil {
            timer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { _ in
                MainActor.assumeIsolated { self.tick() }
            }
        }
        guard !panel.isVisible || panel.alphaValue < 1 else { return }
        var frame = panel.frame
        frame.origin.x += 14
        panel.setFrame(frame, display: false)
        panel.alphaValue = 0
        panel.orderFrontRegardless()
        frame.origin.x -= 14
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = Motion.reduced ? 0.15 : 0.28
            ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
            panel.animator().alphaValue = 1
            panel.animator().setFrame(frame, display: true)
        }
    }

    private func tick() {
        let now = Date()
        let stale = entries.filter { !$0.hovered && now.timeIntervalSince($0.shownAt) > Self.lifetime }
        for e in stale { remove(e.id) }
        if entries.isEmpty {
            timer?.invalidate()
            timer = nil
        }
    }

    private func hide() {
        guard let panel, panel.isVisible else { return }
        var frame = panel.frame
        frame.origin.x += 14
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = Motion.reduced ? 0.15 : 0.25
            ctx.timingFunction = CAMediaTimingFunction(name: .easeIn)
            panel.animator().alphaValue = 0
            panel.animator().setFrame(frame, display: true)
        }, completionHandler: {
            MainActor.assumeIsolated {
                if self.entries.isEmpty { panel.orderOut(nil) }
            }
        })
    }

    private func layout() {
        guard let panel, let hosting else { return }
        hosting.layoutSubtreeIfNeeded()
        let size = hosting.fittingSize
        let screen = NSScreen.main ?? NSScreen.screens[0]
        let vf = screen.visibleFrame
        let frame = NSRect(x: vf.maxX - size.width - 6, y: vf.minY + 6, width: size.width, height: size.height)
        if panel.frame != frame { panel.setFrame(frame, display: true) }
    }

    private func makePanel() -> NSPanel {
        let p = HUDPanel(contentRect: NSRect(x: 0, y: 0, width: 120, height: 120),
                         styleMask: [.borderless, .nonactivatingPanel, .fullSizeContentView],
                         backing: .buffered, defer: false)
        p.isFloatingPanel = true
        p.level = .statusBar
        p.hidesOnDeactivate = false
        p.backgroundColor = .clear
        p.isOpaque = false
        p.hasShadow = false
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        let h = NSHostingView(rootView: ReceivedThumbStack())
        h.sizingOptions = []
        p.contentView = h
        hosting = h
        return p
    }
}

struct ReceivedThumbStack: View {
    @State private var model = ReceivedThumbController.shared

    var body: some View {
        VStack(alignment: .trailing, spacing: 10) {
            ForEach(model.entries) { entry in
                ReceivedThumb(entry: entry)
                    .transition(.asymmetric(
                        insertion: Motion.reduced ? .opacity : .scale(scale: 0.6, anchor: .bottomTrailing).combined(with: .opacity),
                        removal: Motion.reduced ? .opacity : .move(edge: .trailing).combined(with: .opacity)))
            }
        }
        .padding(12)   // shadows
        .animation(Motion.spring(0.35, 0.75), value: model.entries.map(\.id))
    }
}

struct ReceivedThumb: View {
    let entry: ReceivedThumbController.Entry

    var body: some View {
        ZStack(alignment: .topTrailing) {
            ZStack {
                ForEach(Array(entry.urls.prefix(2).enumerated().reversed()), id: \.element) { i, url in
                    FileThumb(url: url, size: 68)
                        .rotationEffect(.degrees(entry.urls.count == 1 ? 0 : Double(i) * 7 - 3))
                        .offset(x: CGFloat(i) * 4, y: CGFloat(i) * -2)
                }
            }
            .frame(width: 96, height: 96)
            .glassSurface(cornerRadius: 18, material: .hudWindow)
            .shadow(color: .black.opacity(0.2), radius: 9, y: 4)
            .overlay(ThumbInteraction(entry: entry))
            if entry.urls.count > 1 {
                Text("\(entry.urls.count)")
                    .font(.system(size: 10, weight: .bold, design: .rounded))
                    .foregroundStyle(.white)
                    .frame(minWidth: 18, minHeight: 18)
                    .padding(.horizontal, 3)
                    .background(Capsule().fill(Color.accentColor))
                    .overlay(Capsule().strokeBorder(.white.opacity(0.9), lineWidth: 1.2))
                    .offset(x: 5, y: -5)
                    .allowsHitTesting(false)
            }
        }
        .help("Von \(entry.peerName) empfangen – Klick öffnet, Ziehen legt ab, Rechtsklick für mehr")
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Empfangen von \(entry.peerName): \(entry.urls.map(\.lastPathComponent).joined(separator: ", "))")
        .accessibilityAddTraits(.isButton)
    }
}

/// Mouse handling for a thumbnail: click opens, drag hands the files to another app (`NSDraggingSource`),
/// right-click shows the menu, hovering pauses the auto-dismiss.
struct ThumbInteraction: NSViewRepresentable {
    let entry: ReceivedThumbController.Entry

    func makeNSView(context: Context) -> ThumbView {
        let v = ThumbView()
        v.entry = entry
        return v
    }

    func updateNSView(_ v: ThumbView, context: Context) { v.entry = entry }

    @MainActor
    final class ThumbView: NSView, NSDraggingSource {
        var entry: ReceivedThumbController.Entry?
        private var downEvent: NSEvent?
        private var tracking: NSTrackingArea?

        override func updateTrackingAreas() {
            super.updateTrackingAreas()
            if let tracking { removeTrackingArea(tracking) }
            let t = NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self)
            addTrackingArea(t)
            tracking = t
        }

        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

        override func mouseEntered(with event: NSEvent) {
            if let id = entry?.id { ReceivedThumbController.shared.setHovered(id, true) }
        }

        override func mouseExited(with event: NSEvent) {
            if let id = entry?.id { ReceivedThumbController.shared.setHovered(id, false) }
        }

        override func mouseDown(with event: NSEvent) { downEvent = event }

        override func mouseDragged(with event: NSEvent) {
            guard let down = downEvent, let urls = entry?.urls, !urls.isEmpty else { return }
            let d = hypot(event.locationInWindow.x - down.locationInWindow.x, event.locationInWindow.y - down.locationInWindow.y)
            guard d > 3 else { return }
            downEvent = nil
            let local = convert(event.locationInWindow, from: nil)
            let items: [NSDraggingItem] = urls.enumerated().map { i, url in
                let item = NSDraggingItem(pasteboardWriter: url as NSURL)
                let icon = NSWorkspace.shared.icon(forFile: url.path)
                item.setDraggingFrame(NSRect(x: local.x - 32 + CGFloat(i * 4), y: local.y - 32 - CGFloat(i * 4), width: 64, height: 64),
                                      contents: icon)
                return item
            }
            beginDraggingSession(with: items, event: event, source: self)
        }

        override func mouseUp(with event: NSEvent) {
            guard downEvent != nil else { return }
            downEvent = nil
            open(nil)
        }

        override func rightMouseDown(with event: NSEvent) {
            let menu = NSMenu()
            menu.addItem(withTitle: "Öffnen", action: #selector(open(_:)), keyEquivalent: "").target = self
            menu.addItem(withTitle: "Im Finder zeigen", action: #selector(reveal(_:)), keyEquivalent: "").target = self
            menu.addItem(.separator())
            menu.addItem(withTitle: "Löschen", action: #selector(trash(_:)), keyEquivalent: "").target = self
            menu.addItem(.separator())
            menu.addItem(withTitle: "Ausblenden", action: #selector(dismiss(_:)), keyEquivalent: "").target = self
            NSMenu.popUpContextMenu(menu, with: event, for: self)
        }

        @objc func open(_ sender: Any?) {
            guard let entry else { return }
            if entry.urls.count == 1 {
                NSWorkspace.shared.open(entry.urls[0])
            } else {
                NSWorkspace.shared.activateFileViewerSelecting(entry.urls)
            }
            ReceivedThumbController.shared.remove(entry.id)
        }

        @objc func reveal(_ sender: Any?) {
            guard let entry else { return }
            NSWorkspace.shared.activateFileViewerSelecting(entry.urls)
            ReceivedThumbController.shared.remove(entry.id)
        }

        @objc func trash(_ sender: Any?) {
            guard let entry else { return }
            NSWorkspace.shared.recycle(entry.urls) { _, _ in }
            ReceivedThumbController.shared.remove(entry.id)
        }

        @objc func dismiss(_ sender: Any?) {
            if let id = entry?.id { ReceivedThumbController.shared.remove(id) }
        }

        func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
            context == .outsideApplication ? [.copy, .move, .link, .generic] : []
        }

        func draggingSession(_ session: NSDraggingSession, endedAt screenPoint: NSPoint, operation: NSDragOperation) {
            // Dropped somewhere: the thumbnail did its job (like the screenshot one).
            if !operation.isEmpty, let id = entry?.id { ReceivedThumbController.shared.remove(id) }
        }
    }
}
