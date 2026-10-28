import AppKit
import Carbon.HIToolbox
import Observation
import SwiftUI
import TailboltCore

@MainActor @Observable
final class ShelfModel {
    var files: [URL] = [] {
        // Exported clipboard files are deleted as soon as the shelf lets go of them (and no transfer reads them).
        didSet { ClipboardPackager.release(oldValue.filter { !files.contains($0) }) }
    }
    /// Latest transfer started from this shelf, per device.
    var sent: [String: TransferItem] = [:]
    /// Keyboard navigation: ring on this device, short pulse on a digit press, "1 2 3" hints while ⌘ is held.
    var selectedID: String?
    var flashID: String?
    var showKeycaps = false
    /// Multi-recipient selection (⌘-click on bubbles); ↩ or the pill sends to all of them.
    var multiSelection: Set<String> = []
    /// The stack flying into a bubble right now (send-start animation).
    var fly: Fly?
    /// Message for the recipient's request card; goes with every send from this shelf.
    var note = ""
    /// The note field has keyboard focus (⇥ focuses it, ↩ / ⎋ leave it). Mirrors the view's `@FocusState`.
    var noteFocused = false

    struct Fly: Identifiable {
        let id = UUID()
        let deviceID: String
        let url: URL
    }

    var totalSize: Int64 {
        files.reduce(0) { $0 + Self.size(of: $1) }
    }

    func add(_ urls: [URL]) {
        for u in urls where !files.contains(u) { files.append(u) }
    }

    func remove(_ url: URL) {
        files.removeAll { $0 == url }
    }

    func send(to device: Device, urls: [URL]? = nil) {
        let list = urls ?? files
        guard !list.isEmpty else { return }
        sent[device.id] = AppModel.shared.send(list, to: device, note: note)
        multiSelection.remove(device.id)
        if !Motion.reduced, let first = list.first {
            let fly = Fly(deviceID: device.id, url: first)
            self.fly = fly
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
                if self?.fly?.id == fly.id { self?.fly = nil }
            }
        }
    }

    static func size(of url: URL) -> Int64 {
        let v = try? url.resourceValues(forKeys: [.isDirectoryKey, .fileSizeKey])
        if v?.isDirectory != true { return Int64(v?.fileSize ?? 0) }
        var total: Int64 = 0
        if let e = FileManager.default.enumerator(at: url, includingPropertiesForKeys: [.fileSizeKey]) {
            for case let child as URL in e {
                total += Int64((try? child.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0)
                if total > 1 << 50 { break }
            }
        }
        return total
    }
}

final class ShelfPanel: NSPanel {
    override var canBecomeKey: Bool { true }
}

@MainActor
final class ShelfController {
    static let shared = ShelfController()

    private var panel: ShelfPanel?
    private(set) var model = ShelfModel()
    private var closeWork: DispatchWorkItem?
    /// Set while `close()` fades the panel out. `show()` during that fade clears it, which tells the fade's
    /// completion handler to leave panel and model alone – otherwise files dropped in those 140 ms would land
    /// in a model that is about to be discarded.
    private var closeToken: UUID?
    private var keyMonitor: Any?
    private var flagsMonitor: Any?

    var isVisible: Bool { panel?.isVisible == true }

    /// Shows the shelf centered on a screen point (cursor for shake, under the icon for the menu bar).
    /// `keyboard` (hotkey, menu, Quick Action – never mid-drag) makes the panel key so digits/arrows/↩ work;
    /// the panel is non-activating, so the app in front keeps its focus ring and menu bar.
    func show(at point: NSPoint? = nil, files: [URL] = [], anchorTop: Bool = false, keyboard: Bool = false) {
        closeWork?.cancel()
        if !files.isEmpty { model.add(files) }
        let panel = self.panel ?? makePanel()
        self.panel = panel

        let size = panel.frame.size
        let p = point ?? NSEvent.mouseLocation
        let screen = NSScreen.screens.first { NSMouseInRect(p, $0.frame, false) } ?? NSScreen.main!
        var origin = anchorTop ? NSPoint(x: p.x - size.width / 2, y: p.y - size.height - 6)
                               : NSPoint(x: p.x - size.width / 2, y: p.y - size.height / 2)
        let vf = screen.visibleFrame.insetBy(dx: 8, dy: 8)
        origin.x = min(max(origin.x, vf.minX), vf.maxX - size.width)
        origin.y = min(max(origin.y, vf.minY), vf.maxY - size.height)

        if closeToken != nil {
            // Caught mid fade-out: keep the panel, its model (with the files just added) and the surface count,
            // just bring it back. A new animation on the same key replaces the running fade.
            closeToken = nil
            AppModel.shared.visibleSurfaces += 1
            if point != nil { panel.setFrameOrigin(origin) }
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = Motion.reduced ? 0.1 : 0.16
                panel.animator().alphaValue = 1
            }
        } else if !panel.isVisible {
            AppModel.shared.visibleSurfaces += 1
            panel.setFrameOrigin(origin)
            panel.alphaValue = 0
            panel.orderFrontRegardless()
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = Motion.reduced ? 0.1 : 0.16
                panel.animator().alphaValue = 1
            }
        } else if point != nil {
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = Motion.reduced ? 0.1 : 0.18
                panel.animator().setFrameOrigin(origin)
            }
        }
        if keyboard { panel.makeKey() }
        installMonitors()
    }

    func close() {
        closeWork?.cancel()
        removeMonitors()
        guard let panel, panel.isVisible, closeToken == nil else { return }
        let token = UUID()
        closeToken = token
        AppModel.shared.visibleSurfaces -= 1
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.14
            panel.animator().alphaValue = 0
        }, completionHandler: {
            MainActor.assumeIsolated {
                guard self.closeToken == token else { return }   // show() caught the panel mid-fade
                self.closeToken = nil
                panel.orderOut(nil)
                let old = self.model
                self.model = ShelfModel()
                panel.contentView = self.hosting()
                self.contentHeightChanged(ShelfView.height(hint: false), animated: false)
                ClipboardPackager.release(old.files)
            }
        })
    }

    /// Called whenever a shelf transfer ends; closes the shelf once everything went out fine.
    func transferEnded() {
        guard Settings.shared.closeShelfAfterSend, isVisible else { return }
        let items = Array(model.sent.values)
        guard !items.isEmpty, items.allSatisfy({ $0.state.isTerminal }), items.allSatisfy({ $0.state == .finished }) else { return }
        let work = DispatchWorkItem { [weak self] in
            guard let self, let panel = self.panel else { return }
            if NSMouseInRect(NSEvent.mouseLocation, panel.frame, false) {
                self.transferEnded()   // user is still there — try again later
                return
            }
            self.close()
        }
        closeWork?.cancel()
        closeWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.2, execute: work)
    }

    /// The view grew or shrank (hint line, multi-recipient pill): follow with the panel. The top edge stays where
    /// it is, unless `keepBottom` – the pill row is inserted above the devices, which must not move under the
    /// cursor that just ⌘-clicked one of them. Either way the panel stays on its screen.
    func contentHeightChanged(_ height: CGFloat, animated: Bool = true, keepBottom: Bool = false) {
        guard let panel, panel.frame.height != height else { return }
        var frame = panel.frame
        if !keepBottom { frame.origin.y += frame.height - height }
        frame.size.height = height
        if let screen = panel.screen ?? NSScreen.main {
            let vf = screen.visibleFrame.insetBy(dx: 8, dy: 8)
            frame.origin.y = min(max(frame.origin.y, vf.minY), vf.maxY - height)
        }
        if animated && panel.isVisible && !Motion.reduced {
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.2
                ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
                panel.animator().setFrame(frame, display: true)
            }
        } else {
            panel.setFrame(frame, display: true)
        }
    }

    // MARK: keyboard

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
                let show = event.modifierFlags.contains(.command) && self.panel?.isKeyWindow == true
                if self.model.showKeycaps != show { self.model.showKeycaps = show }
            }
            return event
        }
    }

    private func removeMonitors() {
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        if let flagsMonitor { NSEvent.removeMonitor(flagsMonitor) }
        keyMonitor = nil
        flagsMonitor = nil
        model.showKeycaps = false
    }

    /// 1–9 send to the n-th device, ← → move the ring, ↩ sends to it (or to the ⌘-click selection), ⎋ clears the
    /// selection / closes, ⌘A selects every device, ⌘O adds files, ⌘⌫ empties the shelf.
    /// Everything else is swallowed while the shelf is key (no beeps, nothing leaks to the app behind).
    /// Returns true when the event was consumed.
    private func handleKey(_ event: NSEvent) -> Bool {
        guard let panel, panel.isVisible, panel.isKeyWindow else { return false }
        // A held key auto-repeats: one press is one action, never one transfer per repeat.
        let flags = event.modifierFlags.intersection(KeyCombo.modifierMask)
        // Typing a note: every key belongs to the text field, except ⎋ which leaves it (↩ is the field's onSubmit).
        if model.noteFocused {
            if Int(event.keyCode) == kVK_Escape {
                model.noteFocused = false
                return true
            }
            return false
        }
        guard !event.isARepeat else { return true }
        let devices = AppModel.shared.devices
        switch Int(event.keyCode) {
        case kVK_Escape:
            if !model.multiSelection.isEmpty {
                withAnimation(Motion.ease(0.15)) { model.multiSelection.removeAll() }
            } else {
                close()
            }
        case kVK_LeftArrow where flags.isEmpty:
            moveSelection(by: -1, in: devices)
        case kVK_RightArrow where flags.isEmpty:
            moveSelection(by: 1, in: devices)
        case kVK_Return, kVK_ANSI_KeypadEnter:
            if !model.multiSelection.isEmpty {
                sendToSelection()
            } else if let id = model.selectedID, let device = devices.first(where: { $0.id == id }) {
                sendByKey(to: device)
            } else if let first = devices.first {
                model.selectedID = first.id
            }
        case kVK_Tab where !model.files.isEmpty:
            model.noteFocused = true
        case kVK_ANSI_A where flags == [.command]:
            withAnimation(Motion.spring(0.25, 0.7)) { model.multiSelection = Set(devices.map(\.id)) }
        case kVK_ANSI_O where flags == [.command]:
            pickFiles { [weak self] in self?.model.add($0) }
        case kVK_Delete where flags == [.command]:
            withAnimation { model.files.removeAll() }
        default:
            if flags.isSubset(of: [.command]), let s = event.charactersIgnoringModifiers, let n = Int(s),
               (1...9).contains(n), n <= devices.count {
                sendByKey(to: devices[n - 1])
            }
        }
        return true
    }

    private func moveSelection(by delta: Int, in devices: [Device]) {
        guard !devices.isEmpty else { return }
        let current = model.selectedID.flatMap { id in devices.firstIndex { $0.id == id } }
        let next = current.map { min(max($0 + delta, 0), devices.count - 1) } ?? (delta > 0 ? 0 : devices.count - 1)
        model.selectedID = devices[next].id
    }

    private func sendByKey(to device: Device) {
        model.selectedID = device.id
        model.flashID = device.id
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { [weak self] in
            if self?.model.flashID == device.id { self?.model.flashID = nil }
        }
        // Still on its way from this shelf: a second press only pulses the bubble instead of sending twice.
        guard model.sent[device.id]?.isActive != true else { return }
        if model.files.isEmpty {
            pickFiles { [weak self] urls in
                self?.model.add(urls)
                self?.model.send(to: device)
            }
        } else {
            model.send(to: device)
        }
    }

    /// Sends the stack to every ⌘-selected device (asks for files first when the shelf is empty).
    func sendToSelection() {
        let targets = AppModel.shared.devices.filter { model.multiSelection.contains($0.id) }
        guard !targets.isEmpty else { return }
        let go = { [weak self] in
            guard let self else { return }
            for device in targets where self.model.sent[device.id]?.isActive != true {
                self.model.send(to: device)
            }
            withAnimation(Motion.ease(0.15)) { self.model.multiSelection.removeAll() }
        }
        if model.files.isEmpty {
            pickFiles { [weak self] urls in
                self?.model.add(urls)
                go()
            }
        } else {
            go()
        }
    }

    private func makePanel() -> ShelfPanel {
        let p = ShelfPanel(contentRect: NSRect(x: 0, y: 0, width: ShelfView.width, height: ShelfView.height(hint: false)),
                           styleMask: [.borderless, .nonactivatingPanel, .fullSizeContentView],
                           backing: .buffered, defer: false)
        p.isFloatingPanel = true
        p.level = .floating
        p.hidesOnDeactivate = false
        p.isMovableByWindowBackground = true
        p.backgroundColor = .clear
        p.isOpaque = false
        p.hasShadow = true
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        p.contentView = hosting()
        return p
    }

    private func hosting() -> NSView {
        let v = NSHostingView(rootView: ShelfView(model: model, onClose: { [weak self] in self?.close() }))
        v.sizingOptions = []
        return v
    }
}

/// Positions of the stack and the bubbles, for the "stack flies into the bubble" beat.
struct ShelfAnchors: PreferenceKey {
    static let defaultValue: [String: Anchor<CGRect>] = [:]
    static func reduce(value: inout [String: Anchor<CGRect>], nextValue: () -> [String: Anchor<CGRect>]) {
        value.merge(nextValue()) { $1 }
    }
}

struct ShelfView: View {
    @Bindable var model: ShelfModel
    var onClose: () -> Void
    @State private var app = AppModel.shared
    @State private var drag = DragState.shared
    @State private var stackTargeted = false
    @State private var listExpanded = false
    @State private var hoverWork: DispatchWorkItem?
    @FocusState private var noteFocused: Bool

    static let width: CGFloat = 320
    /// Header 28 + stack 140 + divider + devices 159 (two-line names, keycap and path capsule still clear the edge).
    /// The multi-recipient pill gets its own 36 pt row above the devices, the relay hint a 32 pt line below them,
    /// the note field (only while files are parked) 36 pt under the stack.
    static func height(hint: Bool, pill: Bool = false, note: Bool = false) -> CGFloat {
        328 + (pill ? 36 : 0) + (hint ? 32 : 0) + (note ? 36 : 0)
    }

    /// `expandedList` starts with the file list open instead of the thumbnail stack (used by --snapshot).
    init(model: ShelfModel, onClose: @escaping () -> Void, expandedList: Bool = false) {
        self.model = model
        self.onClose = onClose
        _listExpanded = State(initialValue: expandedList)
    }

    /// Relay / "Tailscale is slow" advice for a transfer running from this shelf.
    private var activeHint: String? {
        model.sent.values.first { $0.isActive && $0.hint != nil }?.hint
    }

    var body: some View {
        let hint = activeHint
        let pill = !model.multiSelection.isEmpty
        let note = !model.files.isEmpty
        VStack(spacing: 0) {
            header
            stack
                .frame(height: 140)
                .anchorPreference(key: ShelfAnchors.self, value: .bounds) { ["stack": $0] }
            if note {
                noteField
                    .frame(height: 36, alignment: .top)
                    .transition(.opacity)
            }
            Divider().opacity(0.6).padding(.horizontal, 14)
            if pill {
                // Its own row (not an overlay on the divider): the stack summary and the hover list stay clear of it.
                // Bottom-aligned so the gaps to the divider above and the avatars below come out about even.
                multiSendPill
                    .frame(height: 36, alignment: .bottom)
            }
            devices
                .frame(height: 159)
            if let hint {
                hintLine(hint)
                    .frame(height: 32)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .frame(width: Self.width, height: Self.height(hint: hint != nil, pill: pill, note: note))
        .glassSurface(cornerRadius: 20)
        .overlayPreferenceValue(ShelfAnchors.self) { anchors in
            GeometryReader { g in
                if let fly = model.fly, let from = anchors["stack"], let to = anchors["bubble:\(fly.deviceID)"] {
                    FlyingStack(url: fly.url, from: g[from], to: g[to]).id(fly.id)
                }
            }
            .allowsHitTesting(false)
        }
        .animation(Motion.spring(0.3, 0.8), value: hint)
        .animation(Motion.spring(0.3, 0.75), value: model.multiSelection.isEmpty)
        .animation(Motion.spring(0.3, 0.8), value: note)
        .onChange(of: hint != nil) { _, has in
            ShelfController.shared.contentHeightChanged(Self.height(hint: has, pill: pill, note: note))
        }
        .onChange(of: pill) { _, has in
            ShelfController.shared.contentHeightChanged(Self.height(hint: hint != nil, pill: has, note: note), keepBottom: true)
        }
        .onChange(of: note) { _, has in
            ShelfController.shared.contentHeightChanged(Self.height(hint: hint != nil, pill: pill, note: has))
        }
        .onChange(of: model.noteFocused) { _, v in if noteFocused != v { noteFocused = v } }
        .onChange(of: noteFocused) { _, v in if model.noteFocused != v { model.noteFocused = v } }
        .onChange(of: model.sent.values.map(\.state)) { _, _ in
            ShelfController.shared.transferEnded()
        }
    }

    // MARK: header

    private var header: some View {
        HStack {
            Button(action: onClose) {
                Image(systemName: "xmark")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(.secondary)
                    .frame(width: 18, height: 18)
                    .background(Circle().fill(.quaternary))
            }
            .buttonStyle(.plain)
            .help("Close (⎋)")
            .accessibilityLabel("Close")
            Spacer()
            Text("Tailbolt")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.secondary)
            Spacer()
            Menu {
                Button("Add Files…") { pickFiles { model.add($0) } }
                if !model.files.isEmpty {
                    Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting(model.files) }
                    Button("Clear Shelf") { withAnimation { model.files.removeAll() } }
                }
                if app.devices.count > 1 {
                    Divider()
                    Button("Select All Devices") {
                        withAnimation(Motion.spring(0.25, 0.7)) { model.multiSelection = Set(app.devices.map(\.id)) }
                    }
                }
            } label: {
                Image(systemName: "ellipsis")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(.secondary)
                    .frame(width: 18, height: 18)
                    .background(Circle().fill(.quaternary))
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("More")
            .accessibilityLabel("More")
        }
        .padding(.horizontal, 12)
        .padding(.top, 10)
    }

    // MARK: note

    /// "Add a note…" – what the recipient reads on the request card before accepting.
    private var noteField: some View {
        let active = noteFocused || !model.note.isEmpty
        return HStack(spacing: 7) {
            Image(systemName: active ? "text.bubble.fill" : "text.bubble")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(active ? Color.accentColor : Color.secondary)
                .accessibilityHidden(true)
            TextField("Add a note…", text: $model.note)
                .textFieldStyle(.plain)
                .font(.system(size: 12))
                .focused($noteFocused)
                .onSubmit { noteFocused = false }
                .onChange(of: model.note) { _, v in
                    if v.count > Tailbolt.maxNoteLength { model.note = String(v.prefix(Tailbolt.maxNoteLength)) }
                }
                .accessibilityLabel("Note for the recipient")
            if !model.note.isEmpty {
                Button {
                    model.note = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 11))
                        .foregroundStyle(.tertiary)
                }
                .buttonStyle(.plain)
                .help("Remove note")
                .accessibilityLabel("Remove note")
            } else if !noteFocused {
                KeyHintCap(glyph: "⇥")
            }
        }
        .padding(.horizontal, 10)
        .frame(height: 28)
        .background(RoundedRectangle(cornerRadius: 9, style: .continuous)
            .fill(Color.primary.opacity(noteFocused ? 0.075 : 0.045)))
        .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous)
            .strokeBorder(noteFocused ? Color.accentColor.opacity(0.55) : Color.clear, lineWidth: 1))
        .padding(.horizontal, 16)
        .animation(Motion.ease(0.12), value: noteFocused)
        .help("A short message the recipient sees before accepting. ⇥ to type, ↩ when done.")
    }

    // MARK: stack

    @ViewBuilder
    private var stack: some View {
        ZStack {
            if model.files.isEmpty {
                if stackTargeted || drag.isDraggingFiles {
                    dropZone
                        .transition(.opacity.combined(with: .scale(scale: 0.96)))
                } else {
                    emptyState
                        .transition(.opacity)
                }
            } else if listExpanded && !stackTargeted {
                fileList
                    .transition(.opacity.combined(with: .scale(scale: 0.97)))
            } else {
                thumbStack
                    .transition(.scale(scale: 0.85).combined(with: .opacity))
            }
        }
        .animation(Motion.spring(0.32, 0.78), value: listExpanded)
        .animation(Motion.spring(0.3, 0.75), value: model.files)
        .animation(Motion.ease(0.12), value: stackTargeted)
        .animation(Motion.ease(0.15), value: drag.isDraggingFiles)
        .contentShape(Rectangle())
        .onHover { inside in
            hoverWork?.cancel()
            if inside {
                let work = DispatchWorkItem { listExpanded = true }
                hoverWork = work
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.35, execute: work)
            } else {
                listExpanded = false
            }
        }
        .onDrop(of: [.fileURL], isTargeted: $stackTargeted) { providers in
            Haptics.levelChange()
            FileDrop.load(providers) { model.add($0) }
            return true
        }
        .onChange(of: stackTargeted) { _, on in
            if on { Haptics.alignment() }
        }
    }

    /// AirDrop-style radar: this Mac in the middle, rings expanding while discovery runs.
    private var emptyState: some View {
        VStack(spacing: 2) {
            Radar()
                .frame(height: 92)
            Text("Drop files here")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.secondary)
            Text(app.devices.isEmpty ? String(localized: "Searching for devices on your tailnet…")
                                      : String(localized: "or drag them straight onto a device"))
                .font(.system(size: 10))
                .foregroundStyle(.tertiary)
        }
        .padding(.top, 6)
        .padding(.bottom, 8)
        .frame(maxWidth: .infinity)
        .contentShape(Rectangle())
        .onTapGesture { pickFiles { model.add($0) } }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Shelf. Drop files here or click to choose files.")
        .accessibilityAddTraits(.isButton)
    }

    private var dropZone: some View {
        RoundedRectangle(cornerRadius: 14, style: .continuous)
            .strokeBorder(style: StrokeStyle(lineWidth: 1.5, dash: [6, 5]))
            .foregroundStyle(stackTargeted ? Color.accentColor : Color.secondary.opacity(0.4))
            .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(stackTargeted ? Color.accentColor.opacity(0.08) : .clear))
            .overlay(
                VStack(spacing: 6) {
                    Image(systemName: "tray.and.arrow.down")
                        .font(.system(size: 26, weight: .light))
                    Text("Drop files here")
                        .font(.system(size: 12, weight: .medium))
                    Text("or drag them straight onto a device")
                        .font(.system(size: 10))
                        .foregroundStyle(.tertiary)
                }
                .foregroundStyle(stackTargeted ? Color.accentColor : .secondary)
            )
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
    }

    private var thumbStack: some View {
        VStack(spacing: 6) {
            ZStack {
                // Fanned like a hand of cards so the second and third item still show behind a full-bleed photo.
                ForEach(Array(model.files.prefix(3).enumerated().reversed()), id: \.element) { i, url in
                    FileThumb(url: url, size: 78)
                        .rotationEffect(.degrees(model.files.count == 1 ? 0 : Double(i) * 8 - 5))
                        .offset(x: CGFloat(i) * 14, y: CGFloat(i) * -3)
                }
                if model.files.count > 3 {
                    Text("+\(model.files.count - 3)")
                        .font(.system(size: 9, weight: .bold, design: .rounded))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 2)
                        .background(Capsule().fill(Color.accentColor))
                        .offset(x: 50, y: -36)
                }
            }
            .frame(height: 92)
            .overlay(FileDragSource(urls: model.files))
            .scaleEffect(stackTargeted ? 1.06 : 1)
            .help("Drag out to drop the files elsewhere · Double-click to open")

            Text(summary)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .padding(.horizontal, 20)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Shelf: \(summary). Drag out to drop the files elsewhere.")
    }

    /// Hover over the stack: compact list with name, size and × per file. Rows drag single files out,
    /// the summary row drags the whole stack.
    private var fileList: some View {
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                Image(systemName: "square.stack.3d.up.fill")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                Text(summary)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Spacer()
            }
            .frame(height: 20)
            .padding(.horizontal, 6)
            .overlay(FileDragSource(urls: model.files))
            .help("Drag out all files")

            ScrollView(showsIndicators: false) {
                VStack(spacing: 0) {
                    ForEach(model.files, id: \.self) { url in
                        FileRow(url: url, size: ShelfModel.size(of: url), onRemove: {
                            withAnimation(Motion.spring(0.3, 0.75)) { model.remove(url) }
                        })
                    }
                }
            }
            .frame(maxHeight: 104)
        }
        .padding(.horizontal, 12)
        .padding(.top, 6)
        .padding(.bottom, 10)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    private var summary: String {
        let size = ByteFormat.string(model.totalSize)
        if model.files.count == 1 { return "\(model.files[0].lastPathComponent) · \(size)" }
        return String(localized: "\(model.files.count) items · \(size)")
    }

    // MARK: devices

    private var multiSendPill: some View {
        let n = model.multiSelection.count
        return Button {
            ShelfController.shared.sendToSelection()
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "paperplane.fill").font(.system(size: 9, weight: .semibold))
                Text(n == 1 ? String(localized: "Send to 1 Device") : String(localized: "Send to \(n) Devices"))
                Text("↩")
                    .font(.system(size: 10, weight: .semibold, design: .rounded))
                    .frame(width: 15, height: 14)
                    .background(RoundedRectangle(cornerRadius: 3, style: .continuous).fill(.white.opacity(0.22)))
            }
        }
        .buttonStyle(PanelButtonStyle(prominent: true))
        .shadow(color: Color.accentColor.opacity(0.35), radius: 6, y: 2)
        .help("Sends the shelf to all selected devices (↩) · ⎋ clears the selection")
        .transition(.scale(scale: 0.8).combined(with: .opacity))
    }

    @ViewBuilder
    private var devices: some View {
        if app.devices.isEmpty {
            VStack(spacing: 6) {
                if !app.hasRefreshed {
                    ProgressView().controlSize(.small)
                    Text("Searching for devices on your tailnet…")
                } else if app.tailscaleMissing || app.status == nil {
                    Image(systemName: "network.slash").font(.system(size: 20))
                    Text("Tailscale isn’t connected")
                } else {
                    Image(systemName: "dot.radiowaves.left.and.right").font(.system(size: 20))
                    Text("No devices with Tailbolt found")
                    Text("Tailbolt needs to be running on the other device")
                        .font(.system(size: 10)).foregroundStyle(.tertiary)
                }
            }
            .font(.system(size: 11))
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            TimelineView(.periodic(from: .now, by: 1)) { _ in
                let nameLines = DeviceBubble.nameLines(for: app.devices)
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(alignment: .top, spacing: 2) {
                        ForEach(Array(app.devices.enumerated()), id: \.element.id) { index, device in
                            bubble(device, index: index, nameLines: nameLines)
                                .anchorPreference(key: ShelfAnchors.self, value: .bounds) { ["bubble:\(device.id)": $0] }
                                // Pop in with the row's spring; a device that went offline fades and shrinks in
                                // 0.25 s, with no bounce on the way out.
                                .transition(.asymmetric(
                                    insertion: .scale(scale: 0.6).combined(with: .opacity),
                                    removal: .scale(scale: 0.6).combined(with: .opacity).animation(Motion.ease(0.25))))
                        }
                    }
                    .padding(.horizontal, 10)
                    .padding(.top, 10)
                    .animation(Motion.spring(0.4, 0.7), value: app.devices.map(\.id))
                }
                .frame(maxWidth: .infinity, alignment: app.devices.count <= 3 ? .center : .leading)
                .mask(edgeFade)   // bubbles scrolled past the panel edge fade out instead of being cut
            }
        }
    }

    /// Soft 14 pt fade on both sides of the device strip; only overflowing bubbles ever reach it.
    private var edgeFade: some View {
        HStack(spacing: 0) {
            LinearGradient(colors: [.clear, .black], startPoint: .leading, endPoint: .trailing).frame(width: 14)
            Color.black
            LinearGradient(colors: [.black, .clear], startPoint: .leading, endPoint: .trailing).frame(width: 14)
        }
    }

    private func bubble(_ device: Device, index: Int, nameLines: Int) -> some View {
        DeviceBubble(device: device, transfer: model.sent[device.id],
                     highlighted: model.selectedID == device.id,
                     flash: model.flashID == device.id,
                     keycap: model.showKeycaps && index < 9 ? "\(index + 1)" : nil,
                     selected: model.multiSelection.contains(device.id),
                     wideWhenActive: true,
                     keyHint: index < 9 ? "⌘\(index + 1)" : nil,
                     nameLines: nameLines,
                     onDropFiles: { urls in
                         model.add(urls)
                         model.send(to: device, urls: urls)
                     },
                     onTap: {
                         model.selectedID = device.id
                         if model.files.isEmpty {
                             pickFiles { urls in
                                 model.add(urls)
                                 model.send(to: device)
                             }
                         } else {
                             model.send(to: device)
                         }
                     },
                     onCommandTap: {
                         model.selectedID = device.id
                         withAnimation(Motion.spring(0.25, 0.6)) {
                             if model.multiSelection.contains(device.id) {
                                 model.multiSelection.remove(device.id)
                             } else {
                                 model.multiSelection.insert(device.id)
                             }
                         }
                     })
    }

    private func hintLine(_ text: String) -> some View {
        HStack(alignment: .top, spacing: 5) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(.orange)
                .padding(.top, 1)
            Text(text)
                .font(.system(size: 10.5))
                .foregroundStyle(.secondary)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 14)
        .padding(.bottom, 6)
        .frame(maxWidth: .infinity)
        .accessibilityLabel("Note: \(text)")
    }
}

/// Three rings growing 1.0 → 2.6× over 2.4 s, staggered by 0.8 s, around this Mac. Static under Reduce Motion.
struct Radar: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30, paused: reduceMotion)) { ctx in
            let t = ctx.date.timeIntervalSinceReferenceDate
            ZStack {
                ForEach(0..<3, id: \.self) { i in
                    let phase = reduceMotion ? 0.25 + Double(i) * 0.25
                                             : (t / 2.4 + Double(i) / 3).truncatingRemainder(dividingBy: 1)
                    Circle()
                        .strokeBorder(Color.accentColor.opacity(0.38 * (1 - phase)), lineWidth: 1.5)
                        .frame(width: 40, height: 40)
                        .scaleEffect(1 + 1.6 * phase)
                }
                SelfAvatar(size: 40)
            }
        }
        .accessibilityHidden(true)
    }
}

/// One line of the expanded stack list.
struct FileRow: View {
    let url: URL
    let size: Int64
    var onRemove: () -> Void
    @State private var hover = false

    var body: some View {
        HStack(spacing: 6) {
            HStack(spacing: 7) {
                Image(nsImage: NSWorkspace.shared.icon(forFile: url.path))
                    .resizable()
                    .frame(width: 16, height: 16)
                Text(url.lastPathComponent)
                    .font(.system(size: 11))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 4)
                Text(ByteFormat.string(size))
                    .font(.system(size: 10))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
            .contentShape(Rectangle())
            .overlay(FileDragSource(urls: [url]))
            Button(action: onRemove) {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .opacity(hover ? 1 : 0.35)
            }
            .buttonStyle(.plain)
            .help("Remove from Shelf")
            .accessibilityLabel("Remove \(url.lastPathComponent)")
        }
        .padding(.horizontal, 6)
        .frame(height: 21)
        .background(RoundedRectangle(cornerRadius: 5, style: .continuous).fill(hover ? Color.primary.opacity(0.06) : .clear))
        .onHover { hover = $0 }
        .help("\(url.lastPathComponent) · \(ByteFormat.string(size)) · drag out or double-click to open")
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(url.lastPathComponent), \(ByteFormat.string(size))")
    }
}

/// The first thumbnail of the stack flying into a device bubble (0.35 s, shrinking to 24 pt, fading at the end).
struct FlyingStack: View {
    let url: URL
    let from: CGRect
    let to: CGRect
    @State private var flown = false
    @State private var faded = false

    var body: some View {
        FileThumb(url: url, size: flown ? 24 : 78)
            .opacity(faded ? 0 : 1)
            .position(x: flown ? to.midX : from.midX, y: flown ? to.midY : from.midY - 10)
            .onAppear {
                withAnimation(.easeIn(duration: 0.35)) { flown = true }
                withAnimation(.easeOut(duration: 0.1).delay(0.27)) { faded = true }
            }
    }
}

@MainActor
func pickFiles(_ done: @escaping ([URL]) -> Void) {
    let p = NSOpenPanel()
    p.allowsMultipleSelection = true
    p.canChooseDirectories = true
    p.canChooseFiles = true
    p.prompt = String(localized: "Select")
    p.message = String(localized: "What would you like to send?")
    NSApp.activate(ignoringOtherApps: true)
    p.begin { r in
        if r == .OK { done(p.urls) }
    }
}

/// Lets the user drag the shelf's files back out (to Finder, Mail, …) like Dropover.
struct FileDragSource: NSViewRepresentable {
    let urls: [URL]

    func makeNSView(context: Context) -> DragView { DragView() }
    func updateNSView(_ v: DragView, context: Context) { v.urls = urls }

    final class DragView: NSView, NSDraggingSource {
        var urls: [URL] = []
        private var downEvent: NSEvent?

        override func mouseDown(with event: NSEvent) { downEvent = event }

        override func mouseDragged(with event: NSEvent) {
            guard let down = downEvent, !urls.isEmpty else { return }
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
            if event.clickCount == 2, let first = urls.first {
                NSWorkspace.shared.open(first)
            }
            downEvent = nil
        }

        func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
            context == .outsideApplication ? [.copy, .link, .generic] : []
        }

        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    }
}
