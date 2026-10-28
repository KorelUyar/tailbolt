import AppKit
import Observation
import SwiftUI
import TailboltCore

// MARK: - Hooks

/// Closures other parts of the app plug into the popover and the status-item menu.
@MainActor
enum MenuActions {
    /// Opens the onboarding window – the same hook the settings' "Einführung erneut anzeigen" uses
    /// (`SettingsActions.openOnboarding`), so wiring either name wires both. Until then "Einführung" opens the settings.
    static var openOnboarding: (() -> Void)? {
        get { SettingsActions.openOnboarding }
        set { SettingsActions.openOnboarding = newValue }
    }
}

// MARK: - Status item

@MainActor
final class StatusItemController: NSObject, NSPopoverDelegate {
    private let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    private let popover = NSPopover()
    private var dropView: StatusDropView?
    private var iconTimer: Timer?
    private var iconKey = ""

    override init() {
        super.init()
        if let button = item.button {
            button.image = MenuBarIcon.image(active: false)
            button.target = self
            button.action = #selector(toggle)
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
            button.toolTip = "Tailbolt – Dateien hierher ziehen. Klick: Geräte, ⌘-Klick: Über Tailbolt"
            button.setAccessibilityLabel("Tailbolt")
            let drop = StatusDropView(frame: button.bounds)
            drop.autoresizingMask = [.width, .height]
            drop.onEnter = { [weak self] in self?.showShelfBelowIcon() }
            drop.onDrop = { [weak self] urls in self?.showShelfBelowIcon(files: urls) }
            button.addSubview(drop)
            dropView = drop
        }
        popover.behavior = .transient
        popover.animates = true
        popover.delegate = self
        popover.contentViewController = NSHostingController(rootView: MenuView(close: { [weak self] in self?.popover.performClose(nil) }))

        DragState.shared.start()   // the halo wants drag state even when the shake trigger is off
        let t = Timer(timeInterval: 0.15, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refreshIcon() }
        }
        RunLoop.main.add(t, forMode: .common)
        iconTimer = t
    }

    // MARK: icon

    /// Idle: the template glyph. Transferring: a thin progress arc around it (still a template, so the menu bar
    /// tints it). File drag anywhere: a soft accent halo behind the glyph – drawn in colour, so the image stops
    /// being a template and paints the glyph in the menu bar's own label colour.
    private func refreshIcon() {
        guard let button = item.button else { return }
        let app = AppModel.shared
        let active = app.activeTransfers
        let moving = active.filter { ($0.state == .transferring || $0.state == .finishing) && $0.taildrop == nil && $0.totalBytes > 0 }
        var fraction: Double?
        if !moving.isEmpty {
            let total = moving.reduce(Int64(0)) { $0 + $1.totalBytes }
            let done = moving.reduce(Int64(0)) { $0 + ($1.state == .finishing ? $1.totalBytes : $1.bytes) }
            fraction = total > 0 ? Double(done) / Double(total) : 0
        }
        let pending = fraction == nil && !active.isEmpty      // offer out, Taildrop, preparing
        let dragging = DragState.shared.isDraggingFiles
        let dark = button.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        // The halo breathes (1.6 s cycle) unless the user asked for less motion; quantised so it redraws 8× per cycle.
        let phase = dragging && !Motion.reduced ? Int(Date().timeIntervalSinceReferenceDate / 1.6 * 8) % 8 : 2
        let key = "\(fraction.map { Int($0 * 50) } ?? -1)|\(pending)|\(dragging)|\(dark)|\(phase)"
        guard key != iconKey else { return }
        iconKey = key
        let halo: CGFloat? = dragging ? 0.16 + 0.08 * (0.5 + 0.5 * sin(Double(phase) / 8 * 2 * .pi)) : nil
        button.image = Self.composeIcon(fraction: fraction, pending: pending, halo: halo, dark: dark)
        if let fraction {
            button.setAccessibilityValue("Übertragung \(Int(fraction * 100)) %")
        } else {
            button.setAccessibilityValue(pending ? "Übertragung wartet" : nil)
        }
    }

    static func composeIcon(fraction: Double?, pending: Bool, halo: CGFloat?, dark: Bool) -> NSImage? {
        guard let glyph = MenuBarIcon.image(active: pending && fraction == nil) else { return nil }
        guard fraction != nil || halo != nil else { return glyph }
        let size = NSSize(width: 22, height: 22)
        let image = NSImage(size: size, flipped: false) { rect in
            let c = NSPoint(x: rect.midX, y: rect.midY)
            let g = MenuBarIcon.pointSize
            let glyphRect = NSRect(x: c.x - g.width / 2, y: c.y - g.height / 2, width: g.width, height: g.height)
            let ink: NSColor = dark ? .white : .black
            glyph.draw(in: glyphRect, from: .zero, operation: .sourceOver, fraction: 1)
            if let halo {
                // Not a template any more: paint the glyph the way the menu bar would, then slip the halo underneath.
                ink.set()
                glyphRect.fill(using: .sourceAtop)
                let accent = NSColor.controlAccentColor
                NSGraphicsContext.current?.compositingOperation = .destinationOver
                accent.withAlphaComponent(halo).setFill()
                NSBezierPath(ovalIn: rect.insetBy(dx: 0.5, dy: 0.5)).fill()
                NSGraphicsContext.current?.compositingOperation = .sourceOver
                accent.withAlphaComponent(min(1, halo * 2.4)).setStroke()
                let ring = NSBezierPath(ovalIn: rect.insetBy(dx: 1, dy: 1))
                ring.lineWidth = 1
                ring.stroke()
            }
            if let fraction {
                let radius: CGFloat = 10
                let track = NSBezierPath(ovalIn: NSRect(x: c.x - radius, y: c.y - radius, width: 2 * radius, height: 2 * radius))
                track.lineWidth = 1.5
                (halo != nil ? ink : NSColor.black).withAlphaComponent(0.22).setStroke()
                track.stroke()
                let arc = NSBezierPath()
                arc.appendArc(withCenter: c, radius: radius, startAngle: 90, endAngle: 90 - 360 * max(0.03, min(1, fraction)), clockwise: true)
                arc.lineWidth = 1.5
                arc.lineCapStyle = .round
                (halo != nil ? NSColor.controlAccentColor : NSColor.black).setStroke()
                arc.stroke()
            }
            return true
        }
        image.isTemplate = halo == nil
        image.accessibilityDescription = "Tailbolt"
        return image
    }

    // MARK: actions

    private var iconPoint: NSPoint? {
        guard let button = item.button, let window = button.window else { return nil }
        let rect = window.convertToScreen(button.convert(button.bounds, to: nil))
        return NSPoint(x: rect.midX, y: rect.minY)
    }

    private func showShelfBelowIcon(files: [URL] = [], keyboard: Bool = false) {
        if popover.isShown { popover.performClose(nil) }
        ShelfController.shared.show(at: iconPoint, files: files, anchorTop: true, keyboard: keyboard)
    }

    @objc private func toggle() {
        let event = NSApp.currentEvent
        if event?.type == .rightMouseUp {
            showContextMenu()
            return
        }
        if event?.modifierFlags.contains(.command) == true {
            showAbout()
            return
        }
        if popover.isShown {
            popover.performClose(nil)
        } else {
            showPopover()
        }
    }

    func showPopover() {
        guard let button = item.button, !popover.isShown else { return }
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        popover.contentViewController?.view.window?.makeKey()
    }

    /// ⌘-click: the Info tab (icon, version, tailnet, speed test) is the About window.
    private func showAbout() {
        if popover.isShown { popover.performClose(nil) }
        SettingsWindow.show(tab: .info)
    }

    private func showContextMenu() {
        let menu = NSMenu()
        menu.addItem(withTitle: "Shelf öffnen", action: #selector(openShelf), keyEquivalent: "").target = self
        if let last = AppModel.shared.lastPayload, !last.existingURLs.isEmpty {
            menu.addItem(withTitle: "Erneut an \(last.deviceName) senden", action: #selector(resendLast), keyEquivalent: "").target = self
        }
        menu.addItem(withTitle: "Empfangene Dateien", action: #selector(openDownloads), keyEquivalent: "").target = self
        menu.addItem(.separator())
        menu.addItem(withTitle: "Einführung", action: #selector(openOnboarding), keyEquivalent: "").target = self
        menu.addItem(withTitle: "Einstellungen…", action: #selector(openSettings), keyEquivalent: ",").target = self
        menu.addItem(.separator())
        menu.addItem(withTitle: "Tailbolt beenden", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        item.menu = menu
        item.button?.performClick(nil)
        item.menu = nil
    }

    @objc private func openShelf() { showShelfBelowIcon(keyboard: true) }
    @objc private func openSettings() { SettingsWindow.show() }
    @objc private func resendLast() { AppModel.shared.resendLast() }
    @objc private func openDownloads() { NSWorkspace.shared.open(Settings.shared.downloadDirectory) }
    @objc private func openOnboarding() { MenuActions.openOnboarding.map { $0() } ?? SettingsWindow.show() }

    func popoverWillShow(_ notification: Notification) { AppModel.shared.visibleSurfaces += 1 }
    func popoverDidClose(_ notification: Notification) { AppModel.shared.visibleSurfaces -= 1 }
}

/// Transparent overlay on the status button that turns it into a drop target.
final class StatusDropView: NSView {
    var onEnter: (() -> Void)?
    var onDrop: (([URL]) -> Void)?

    override init(frame: NSRect) {
        super.init(frame: frame)
        registerForDraggedTypes([.fileURL])
    }

    required init?(coder: NSCoder) { fatalError() }

    // Clicks belong to the status button underneath.
    override func mouseDown(with event: NSEvent) { superview?.mouseDown(with: event) }
    override func rightMouseDown(with event: NSEvent) { superview?.rightMouseDown(with: event) }
    override func mouseUp(with event: NSEvent) { superview?.mouseUp(with: event) }
    override func rightMouseUp(with event: NSEvent) { superview?.rightMouseUp(with: event) }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        onEnter?()
        return .copy
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        let urls = sender.draggingPasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
        onDrop?(urls)
        return !urls.isEmpty
    }
}

// MARK: - Shared bits

/// Capsules on a transfer row / card: "LAN-Turbo ⚡︎" while (or after) the LAN fast path carried bytes, and the
/// LZ4 saving once it is worth a word – the same `PathCapsule` the device bubbles use.
struct TransferCapsules: View {
    let item: TransferItem

    var body: some View {
        if item.usesLAN || item.everUsedLAN {
            PathCapsule(label: "LAN-Turbo", tint: .accentColor, bolt: true)
                .help("LAN-Turbo: läuft direkt über das lokale Netzwerk, parallel zum Tailscale-Tunnel – schnellster Weg.")
                .accessibilityLabel("über LAN-Turbo")
        }
        if let pct = Self.lz4Percent(item) {
            Text("LZ4 −\(pct) %")
                .font(.system(size: 10, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .help("LZ4-Kompression hat \(pct) % der Bytes auf der Leitung gespart")
        }
    }

    /// Savings in percent once LZ4 saved more than 5 % of the payload so far, else nil.
    static func lz4Percent(_ item: TransferItem) -> Int? {
        guard item.bytes > 0, item.bytesSaved > 0, Double(item.bytesSaved) > Double(item.bytes) * 0.05 else { return nil }
        return Int((Double(item.bytesSaved) / Double(item.bytes) * 100).rounded())
    }
}

enum DurationFormat {
    /// "8,1 s", "42 s", "1:12 min", "1:02 h" – in the user's locale.
    static func seconds(_ s: Double) -> String {
        if s >= 3600 {
            let h = Int(s) / 3600, m = Int(s) % 3600 / 60
            return String(format: "%d:%02d h", h, m)
        }
        if s >= 60 {
            let m = Int(s) / 60, r = Int(s) % 60
            return String(format: "%d:%02d min", m, r)
        }
        let f = NumberFormatter()
        f.locale = .current
        f.maximumFractionDigits = s < 10 ? 1 : 0
        f.minimumFractionDigits = 0
        return (f.string(from: NSNumber(value: s)) ?? "\(Int(s))") + " s"
    }

    /// "gerade eben", "vor 3 Min." …
    static func ago(_ date: Date) -> String {
        let s = Date().timeIntervalSince(date)
        if s < 60 { return "gerade eben" }
        let f = RelativeDateTimeFormatter()
        f.locale = Locale(identifier: "de_CH")
        f.unitsStyle = .abbreviated
        return f.localizedString(for: date, relativeTo: Date())
    }
}

/// Footer buttons: borderless, hover capsule, same look whether or not the popover is key.
private struct FooterButtonStyle: ButtonStyle {
    @State private var hover = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12))
            .foregroundStyle(configuration.isPressed ? Color.primary.opacity(0.6) : Color.primary.opacity(0.85))
            .padding(.horizontal, 7)
            .padding(.vertical, 4)
            .background(Capsule().fill(Color.primary.opacity(hover ? 0.07 : 0)))
            .contentShape(Capsule())
            .onHover { hover = $0 }
            .animation(.easeOut(duration: 0.12), value: hover)
    }
}

// MARK: - Popover

struct MenuView: View {
    var close: () -> Void
    @State private var app = AppModel.shared
    @State private var settings = Settings.shared

    private let columns = Array(repeating: GridItem(.fixed(84), spacing: 2), count: 4)

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
                .padding(.horizontal, 14)
                .padding(.top, 12)
                .padding(.bottom, 8)

            TimelineView(.periodic(from: .now, by: 1)) { _ in
                VStack(alignment: .leading, spacing: 0) {
                    if let last = app.lastPayload, !last.existingURLs.isEmpty {
                        sectionLabel("Zuletzt")
                        LastPayloadRow(payload: last, close: close)
                            .padding(.horizontal, 8)
                            .padding(.bottom, 4)
                    }
                    deviceGrid
                }
            }

            if !app.transfers.isEmpty {
                Divider().padding(.horizontal, 14).padding(.top, 8)
                transferList
            }

            Divider().padding(.horizontal, 14)
            footer
                .padding(.horizontal, 8)
                .padding(.vertical, 6)
        }
        .frame(width: 360)
    }

    // MARK: header

    private var header: some View {
        HStack(alignment: .center, spacing: 9) {
            AppIconView(size: 32)
                .padding(.leading, -3)
            VStack(alignment: .leading, spacing: 1) {
                Text("Tailbolt").font(.system(size: 13, weight: .semibold))
                HStack(spacing: 5) {
                    Circle().fill(statusColor).frame(width: 6, height: 6)
                        .overlay(Circle().strokeBorder(statusColor.opacity(0.35), lineWidth: 2).frame(width: 10, height: 10))
                    Text(statusText).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                }
                .help(statusHelp)
            }
            Spacer(minLength: 6)
            if app.isRefreshing {
                HStack(spacing: 5) {
                    ProgressView().controlSize(.mini)
                    Text("Suche…").font(.system(size: 11)).foregroundStyle(.secondary)
                }
                .transition(.opacity)
                .accessibilityLabel("Sucht Geräte")
            } else {
                Button { app.refresh() } label: {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.secondary)
                        .frame(width: 22, height: 22)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Geräte neu suchen")
                .accessibilityLabel("Geräte neu suchen")
                .transition(.opacity)
            }
        }
        .animation(.easeOut(duration: 0.15), value: app.isRefreshing)
    }

    private var statusColor: Color {
        if app.serverError != nil || app.status == nil && app.hasRefreshed { return .red }
        return app.status?.running == true ? .green : .orange
    }

    private var statusText: String {
        if let e = app.serverError { return "Empfang nicht möglich: \(e)" }
        if app.tailscaleMissing { return "Tailscale nicht installiert" }
        guard let s = app.status else { return app.hasRefreshed ? "Tailscale nicht erreichbar" : "Verbinde…" }
        if !s.running { return "Tailscale ist gestoppt" }
        if let net = s.tailnetName, !net.isEmpty { return "\(s.selfName) · \(net)" }
        return "\(s.selfName) · bereit zum Empfangen"
    }

    private var statusHelp: String {
        if app.serverError != nil { return "Der Empfänger konnte Port \(Tailbolt.defaultPort) nicht öffnen." }
        return "Empfängt auf Port \(Tailbolt.defaultPort) – nur von Geräten im Tailnet"
    }

    // MARK: devices

    private func sectionLabel(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 14)
            .padding(.top, 6)
            .padding(.bottom, 3)
            .accessibilityAddTraits(.isHeader)
    }

    @ViewBuilder
    private var deviceGrid: some View {
        if app.devices.isEmpty {
            emptyState
        } else {
            let mine = app.devices.filter(\.peer.isMine)
            let others = app.devices.filter { !$0.peer.isMine }
            if mine.isEmpty || others.isEmpty {
                sectionLabel("Geräte")
                grid(app.devices)
            } else {
                sectionLabel("Meine Geräte")
                grid(mine)
                sectionLabel("Andere")
                grid(others)
            }
        }
    }

    private func grid(_ devices: [Device]) -> some View {
        // One long name makes the whole section reserve two name lines, so the rows stay aligned.
        let nameLines = DeviceBubble.nameLines(for: devices)
        return LazyVGrid(columns: columns, alignment: .center, spacing: 6) {
            ForEach(devices) { device in
                deviceCell(device, nameLines: nameLines)
            }
        }
        .padding(.horizontal, 8)
        .padding(.bottom, 4)
        .animation(Motion.spring(0.3, 0.75), value: devices.map(\.id))
    }

    private func deviceCell(_ device: Device, nameLines: Int) -> some View {
        DeviceBubble(device: device, transfer: latestTransfer(to: device),
                     keyHint: settings.favoriteSlot(of: device.id).flatMap { settings.shortcuts[.favorite($0)]?.display },
                     nameLines: nameLines,
                     onDropFiles: { urls in app.send(urls, to: device) },
                     onTap: {
                         close()
                         pickFiles { app.send($0, to: device) }
                     })
            .transition(Motion.reduced ? .opacity : .scale(scale: 0.6).combined(with: .opacity))
    }

    private var emptyState: some View {
        VStack(spacing: 6) {
            if !app.hasRefreshed {
                ProgressView().controlSize(.small)
                Text("Suche Geräte im Tailnet…")
            } else if app.tailscaleMissing || app.status == nil {
                Image(systemName: "network.slash").font(.system(size: 22, weight: .light))
                Text("Tailscale ist nicht verbunden")
            } else {
                Image(systemName: "dot.radiowaves.left.and.right").font(.system(size: 22, weight: .light))
                Text("Keine Geräte mit Tailbolt online")
                Text("Auf anderen Geräten im Tailnet Tailbolt starten – sie erscheinen dann automatisch hier.")
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
                    .multilineTextAlignment(.center)
            }
        }
        .font(.system(size: 11))
        .foregroundStyle(.secondary)
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 28)
        .padding(.vertical, 18)
    }

    private func latestTransfer(to device: Device) -> TransferItem? {
        app.transfers.first { $0.direction == .outgoing && $0.deviceID == device.id }
    }

    // MARK: transfers

    private var transferList: some View {
        let active = app.transfers.filter(\.isActive)
        let history = app.transfers.filter { !$0.isActive }
        return VStack(alignment: .leading, spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 2) {
                    if !active.isEmpty {
                        sectionLabel("Aktiv").padding(.horizontal, -6)
                        ForEach(active) { TransferRow(item: $0) }
                    }
                    if !history.isEmpty {
                        sectionLabel("Verlauf").padding(.horizontal, -6)
                        ForEach(history.prefix(10)) { TransferRow(item: $0) }
                    }
                }
                .padding(.horizontal, 6)
                .padding(.bottom, 4)
            }
            .frame(maxHeight: 236)
            .fixedSize(horizontal: false, vertical: true)
            if !history.isEmpty {
                HStack {
                    Spacer()
                    Button("Verlauf löschen") {
                        withAnimation(Motion.ease(0.2)) { app.transfers.removeAll { !$0.isActive } }
                    }
                    .buttonStyle(.plain)
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .help("Abgeschlossene Übertragungen aus der Liste entfernen")
                }
                .padding(.horizontal, 14)
                .padding(.bottom, 7)
            }
        }
    }

    // MARK: footer

    private var footer: some View {
        HStack(spacing: 2) {
            Button {
                close()
                ShelfController.shared.show(at: nil, keyboard: true)
            } label: {
                Label("Shelf", systemImage: "tray")
            }
            .help("Shelf öffnen (\(settings.shortcuts[.openShelf]?.display ?? "Tastenkürzel") oder Maus beim Ziehen schütteln)")
            Button {
                close()
                NSWorkspace.shared.open(settings.downloadDirectory)
            } label: {
                Label("Empfangen", systemImage: "folder")
            }
            .help("Empfangene Dateien im Finder öffnen (\(settings.downloadDirectory.lastPathComponent))")
            Button {
                close()
                if let open = MenuActions.openOnboarding { open() } else { SettingsWindow.show() }
            } label: {
                Label("Einführung", systemImage: "sparkles")
            }
            .help("Zeigt die Einführung noch einmal")
            Spacer(minLength: 0)
            Button {
                close()
                SettingsWindow.show()
            } label: {
                Image(systemName: "gearshape").frame(width: 16)
            }
            .help("Einstellungen (⌘,)")
            .accessibilityLabel("Einstellungen")
            Button {
                NSApp.terminate(nil)
            } label: {
                Image(systemName: "power").frame(width: 16)
            }
            .help("Tailbolt beenden")
            .accessibilityLabel("Tailbolt beenden")
        }
        .buttonStyle(FooterButtonStyle())
    }
}

/// "Zuletzt": what went out last, where to and when – one click sends it again, the thumbnail drags back out.
struct LastPayloadRow: View {
    let payload: LastPayload
    var close: () -> Void
    @State private var app = AppModel.shared
    @State private var hover = false

    private var urls: [URL] { payload.existingURLs }

    var body: some View {
        HStack(spacing: 10) {
            ZStack {
                ForEach(Array(urls.prefix(2).enumerated().reversed()), id: \.element) { i, url in
                    FileThumb(url: url, size: 30)
                        .rotationEffect(.degrees(urls.count == 1 ? 0 : Double(i) * 8 - 4))
                        .offset(x: CGFloat(i) * 3, y: CGFloat(i) * -1)
                }
            }
            .frame(width: 34, height: 34)
            .overlay(FileDragSource(urls: urls))
            .help("Herausziehen, um die Dateien woanders abzulegen")
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 12, weight: .medium))
                    .lineLimit(1)
                    .truncationMode(.middle)
                // "an goto · gerade eben"; a long device name drops the time rather than cutting the name.
                Text(TransferRow.join(["an \(payload.deviceName)", DurationFormat.ago(payload.at)], budget: 30))
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            Spacer(minLength: 4)
            Button {
                app.resendLast()
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "arrow.counterclockwise").font(.system(size: 9, weight: .bold))
                    Text("Erneut senden")
                }
            }
            .buttonStyle(PanelButtonStyle())
            .disabled(online == nil)
            .opacity(online == nil ? 0.55 : 1)
            .help(online == nil ? "\(payload.deviceName) ist gerade nicht online" : "Dieselben Dateien noch einmal an \(payload.deviceName) senden")
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.primary.opacity(hover ? 0.07 : 0.045)))
        .onHover { hover = $0 }
        .animation(.easeOut(duration: 0.12), value: hover)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Zuletzt gesendet: \(title) an \(payload.deviceName), \(DurationFormat.ago(payload.at))")
    }

    private var online: Device? { app.devices.first { $0.id == payload.deviceID } }

    private var title: String {
        guard let first = urls.first else { return "" }
        return urls.count == 1 ? first.lastPathComponent : "\(first.lastPathComponent) und \(urls.count - 1) weitere"
    }
}

struct TransferRow: View {
    let item: TransferItem
    @State private var hover = false
    @State private var app = AppModel.shared

    var body: some View {
        HStack(spacing: 10) {
            ZStack(alignment: .bottomTrailing) {
                Image(systemName: item.peerSymbol)
                    .font(.system(size: 15))
                    .foregroundStyle(.secondary)
                    .frame(width: 30, height: 30)
                    .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(.quaternary))
                Image(systemName: item.direction == .outgoing ? "arrow.up.circle.fill" : "arrow.down.circle.fill")
                    .font(.system(size: 12))
                    .symbolRenderingMode(.palette)
                    .foregroundStyle(.white, item.direction == .outgoing ? Color.accentColor : .green)
                    .offset(x: 4, y: 4)
            }
            .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 5) {
                    Text(item.title)
                        .font(.system(size: 12, weight: .medium))
                        .lineLimit(1)
                        .truncationMode(.middle)
                    TransferCapsules(item: item)
                }
                Text(detail)
                    .font(.system(size: 10))
                    .foregroundStyle(stateColor)
                    .lineLimit(1)
                if item.state == .transferring || item.state == .finishing {
                    Bar(value: item.taildrop != nil ? nil : item.fraction)
                        .padding(.top, 2)
                }
            }
            Spacer(minLength: 0)
            actions
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(hover ? Color.primary.opacity(0.06) : .clear))
        .onHover { hover = $0 }
        .animation(.easeOut(duration: 0.12), value: hover)
        .contentShape(Rectangle())
        .onTapGesture(count: 2) {
            if !item.savedURLs.isEmpty { NSWorkspace.shared.activateFileViewerSelecting(item.savedURLs) }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(item.direction == .outgoing ? "Gesendet" : "Empfangen"): \(item.title), \(detail)")
    }

    private var who: String { (item.direction == .outgoing ? "an " : "von ") + item.peerName }

    /// "an goto · 40 % · 112 MB/s · noch 22 s" while moving, "an goto · 4,2 GB in 8,1 s · 520 MB/s" when done.
    /// Trailing parts are dropped whole when a long device name would otherwise cut a number in half.
    private var detail: String {
        switch item.state {
        case .transferring where item.taildrop == nil:
            var parts = [who, "\(Int(item.fraction * 100)) %"]
            if item.speed > 0 {
                parts.append(ByteFormat.speed(item.speed))
                let remaining = Double(item.totalBytes - item.bytes) / item.speed
                if remaining > 1 { parts.append(TransferItem.eta(remaining)) }
            }
            return Self.join(parts, budget: 48)
        case .finished:
            var parts = [who, ByteFormat.string(item.totalBytes)]
            if let d = item.durationSeconds, let v = item.averageSpeed {
                parts[1] += " in \(DurationFormat.seconds(d))"
                parts.append(ByteFormat.speed(v))
            }
            return Self.join(parts, budget: 48)
        default:
            return "\(who) · \(item.statusText)"
        }
    }

    /// Joins `parts` with " · " and stops before the first part that would push the line past `budget` characters.
    static func join(_ parts: [String], budget: Int) -> String {
        var s = parts[0]
        for p in parts.dropFirst() {
            let next = s + " · " + p
            if next.count > budget && !s.isEmpty && s != parts[0] { break }
            s = next
        }
        return s
    }

    @ViewBuilder
    private var actions: some View {
        if item.isActive && !item.awaitingDecision {
            Button { item.cancel() } label: {
                Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .help("Abbrechen")
            .accessibilityLabel("Abbrechen")
            .opacity(hover ? 1 : 0.6)
        } else if !item.isActive {
            HStack(spacing: 6) {
                if item.direction == .outgoing, !item.sourceURLs.isEmpty, let device = app.devices.first(where: { $0.id == item.deviceID }) {
                    Button { app.send(item.sourceURLs, to: device) } label: {
                        Image(systemName: "arrow.counterclockwise.circle.fill").foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .help("Erneut an \(device.name) senden")
                    .accessibilityLabel("Erneut senden")
                }
                if !item.savedURLs.isEmpty {
                    Button { NSWorkspace.shared.activateFileViewerSelecting(item.savedURLs) } label: {
                        Image(systemName: "magnifyingglass.circle.fill").foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .help("Im Finder zeigen")
                    .accessibilityLabel("Im Finder zeigen")
                }
                Button {
                    withAnimation(Motion.ease(0.2)) { app.transfers.removeAll { $0.id == item.id } }
                } label: {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help("Aus dem Verlauf entfernen")
                .accessibilityLabel("Aus dem Verlauf entfernen")
            }
            .opacity(hover ? 1 : 0)
        }
    }

    private var stateColor: Color {
        switch item.state {
        case .failed, .declined: return .red
        default: return .secondary
        }
    }
}
