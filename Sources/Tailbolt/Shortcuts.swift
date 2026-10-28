import AppKit
import Carbon.HIToolbox
import Observation

// MARK: - KeyCombo

/// A keyboard shortcut: virtual key code + ⌃⌥⇧⌘. Persisted as JSON in Settings.
struct KeyCombo: Codable, Hashable {
    var keyCode: UInt16
    /// `NSEvent.ModifierFlags` raw value, limited to ⌃⌥⇧⌘.
    var modifiers: UInt

    static let modifierMask: NSEvent.ModifierFlags = [.control, .option, .shift, .command]

    init(keyCode: UInt16, modifiers: NSEvent.ModifierFlags) {
        self.keyCode = keyCode
        self.modifiers = modifiers.intersection(Self.modifierMask).rawValue
    }

    init(keyCode: Int, modifiers: NSEvent.ModifierFlags) {
        self.init(keyCode: UInt16(keyCode), modifiers: modifiers)
    }

    /// From a Carbon hotkey registration (`cmdKey | optionKey | …`).
    init(carbonKeyCode: UInt32, carbonModifiers: UInt32) {
        var f: NSEvent.ModifierFlags = []
        if carbonModifiers & UInt32(cmdKey) != 0 { f.insert(.command) }
        if carbonModifiers & UInt32(optionKey) != 0 { f.insert(.option) }
        if carbonModifiers & UInt32(controlKey) != 0 { f.insert(.control) }
        if carbonModifiers & UInt32(shiftKey) != 0 { f.insert(.shift) }
        self.init(keyCode: UInt16(carbonKeyCode), modifiers: f)
    }

    /// nil for anything that is not a real key press (a modifier key on its own).
    init?(event: NSEvent) {
        guard event.type == .keyDown, !Self.modifierKeyCodes.contains(Int(event.keyCode)) else { return nil }
        self.init(keyCode: event.keyCode, modifiers: event.modifierFlags)
    }

    var flags: NSEvent.ModifierFlags { NSEvent.ModifierFlags(rawValue: modifiers) }

    /// Global hotkeys need ⌘, ⌃ or ⌥ so plain typing can never trigger them.
    var isValid: Bool {
        !flags.intersection([.command, .control, .option]).isEmpty && !Self.modifierKeyCodes.contains(Int(keyCode))
    }

    /// Combos every Mac app relies on; grabbing them system-wide would break the whole system.
    var isReserved: Bool {
        let k = Int(keyCode)
        if flags == [.command] { return [kVK_ANSI_Q, kVK_ANSI_W, kVK_ANSI_H, kVK_ANSI_M, kVK_Tab, kVK_Space].contains(k) }
        if flags == [.command, .option] && k == kVK_Escape { return true }
        return false
    }

    var carbonModifiers: UInt32 {
        var m: UInt32 = 0
        if flags.contains(.command) { m |= UInt32(cmdKey) }
        if flags.contains(.option) { m |= UInt32(optionKey) }
        if flags.contains(.control) { m |= UInt32(controlKey) }
        if flags.contains(.shift) { m |= UInt32(shiftKey) }
        return m
    }

    /// "⌃⌥⌘B" – modifiers in Apple's canonical order, key as a glyph.
    var display: String { Self.symbols(for: flags) + keyGlyph }

    var keyGlyph: String { Self.glyph(for: keyCode) }

    static func symbols(for flags: NSEvent.ModifierFlags) -> String {
        var s = ""
        if flags.contains(.control) { s += "⌃" }
        if flags.contains(.option) { s += "⌥" }
        if flags.contains(.shift) { s += "⇧" }
        if flags.contains(.command) { s += "⌘" }
        return s
    }

    static func glyph(for keyCode: UInt16) -> String {
        if let g = specialGlyphs[Int(keyCode)] { return g }
        if let c = KeyboardLayout.character(for: keyCode) { return c.uppercased() }
        return "#\(keyCode)"
    }

    private static let modifierKeyCodes = [kVK_Command, kVK_RightCommand, kVK_Shift, kVK_RightShift, kVK_Option, kVK_RightOption,
                                           kVK_Control, kVK_RightControl, kVK_CapsLock, kVK_Function]

    private static let specialGlyphs: [Int: String] = [
        kVK_Return: "↩", kVK_ANSI_KeypadEnter: "⌤", kVK_Tab: "⇥", kVK_Space: "␣", kVK_Delete: "⌫", kVK_ForwardDelete: "⌦",
        kVK_Escape: "⎋", kVK_LeftArrow: "←", kVK_RightArrow: "→", kVK_UpArrow: "↑", kVK_DownArrow: "↓",
        kVK_Home: "↖", kVK_End: "↘", kVK_PageUp: "⇞", kVK_PageDown: "⇟", kVK_Help: "?", kVK_ANSI_KeypadClear: "⌧",
        kVK_F1: "F1", kVK_F2: "F2", kVK_F3: "F3", kVK_F4: "F4", kVK_F5: "F5", kVK_F6: "F6", kVK_F7: "F7", kVK_F8: "F8",
        kVK_F9: "F9", kVK_F10: "F10", kVK_F11: "F11", kVK_F12: "F12", kVK_F13: "F13", kVK_F14: "F14", kVK_F15: "F15",
        kVK_F16: "F16", kVK_F17: "F17", kVK_F18: "F18", kVK_F19: "F19", kVK_F20: "F20",
    ]
}

/// Translates virtual key codes with the keyboard layout that is active right now (Swiss layouts swap Z/Y etc.).
enum KeyboardLayout {
    static func character(for keyCode: UInt16) -> String? {
        guard let source = TISCopyCurrentASCIICapableKeyboardLayoutInputSource()?.takeRetainedValue(),
              let raw = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData) else { return nil }
        let data = Unmanaged<CFData>.fromOpaque(raw).takeUnretainedValue() as Data
        var deadKeys: UInt32 = 0
        var chars = [UniChar](repeating: 0, count: 4)
        var length = 0
        let status = data.withUnsafeBytes { buf -> OSStatus in
            guard let base = buf.baseAddress else { return -1 }
            return UCKeyTranslate(base.assumingMemoryBound(to: UCKeyboardLayout.self), keyCode, UInt16(kUCKeyActionDisplay), 0,
                                  UInt32(LMGetKbdType()), OptionBits(1 << kUCKeyTranslateNoDeadKeysBit), &deadKeys,
                                  chars.count, &length, &chars)
        }
        guard status == noErr, length > 0 else { return nil }
        let s = String(utf16CodeUnits: chars, count: length).trimmingCharacters(in: .controlCharacters.union(.whitespaces))
        return s.isEmpty ? nil : s
    }
}

// MARK: - Actions

enum ShortcutAction: String, CaseIterable, Codable, Identifiable {
    case openShelf, sendClipboard, sendToLast
    case favorite1, favorite2, favorite3, favorite4, favorite5, favorite6, favorite7, favorite8, favorite9

    var id: String { rawValue }

    /// 1…9 for the favorite actions, nil otherwise.
    var favoriteSlot: Int? { rawValue.hasPrefix("favorite") ? Int(rawValue.dropFirst("favorite".count)) : nil }

    static func favorite(_ slot: Int) -> ShortcutAction { ShortcutAction(rawValue: "favorite\(slot)")! }

    var title: String {
        switch self {
        case .openShelf: return "Shelf öffnen"
        case .sendClipboard: return "Zwischenablage senden"
        case .sendToLast: return "An letztes Gerät senden"
        default: return "An Favorit \(favoriteSlot ?? 0) senden"
        }
    }

    var symbol: String {
        switch self {
        case .openShelf: return "tray"
        case .sendClipboard: return "doc.on.clipboard"
        case .sendToLast: return "arrow.uturn.up"
        default: return "star"
        }
    }

    var defaultCombo: KeyCombo {
        let m: NSEvent.ModifierFlags = [.control, .option, .command]
        switch self {
        case .openShelf: return KeyCombo(keyCode: kVK_ANSI_B, modifiers: m)
        case .sendClipboard: return KeyCombo(keyCode: kVK_ANSI_V, modifiers: m)
        case .sendToLast: return KeyCombo(keyCode: kVK_ANSI_L, modifiers: m)
        default: return KeyCombo(keyCode: Self.digitKeyCodes[(favoriteSlot ?? 1) - 1], modifiers: m)
        }
    }

    static let digitKeyCodes = [kVK_ANSI_1, kVK_ANSI_2, kVK_ANSI_3, kVK_ANSI_4, kVK_ANSI_5, kVK_ANSI_6, kVK_ANSI_7, kVK_ANSI_8, kVK_ANSI_9]

    static var defaults: [ShortcutAction: KeyCombo] {
        Dictionary(uniqueKeysWithValues: allCases.map { ($0, $0.defaultCombo) })
    }
}

// MARK: - HotKeyCenter

/// Registers one Carbon global hotkey per action (no Accessibility permission needed) and dispatches them.
/// Re-registers itself whenever `Settings.shortcuts` / `hotKeyEnabled` change. Also owns the shortcut
/// recorder session, so a recording can never outlive the view that started it.
@MainActor @Observable
final class HotKeyCenter {
    static let shared = HotKeyCenter()

    /// Actions whose combo the system refused (already taken by another app, …).
    private(set) var failed: Set<ShortcutAction> = []

    /// The action whose shortcut is being recorded right now. While set, every global hotkey is unregistered
    /// (so the current combo can be pressed to re-record it) and a local monitor swallows all key events.
    private(set) var recordingAction: ShortcutAction?
    /// Modifiers held during the recording, for the field's live "⌃⌥" preview.
    private(set) var recordingModifiers: NSEvent.ModifierFlags = []
    /// Why the last press was refused ("Bereits belegt: …"), shown under that action's field.
    private(set) var recordingNote: RecordingNote?

    struct RecordingNote {
        let action: ShortcutAction
        let text: String
    }

    @ObservationIgnored private var handler: EventHandlerRef?
    @ObservationIgnored private var registered: [UInt32: (ref: EventHotKeyRef, action: ShortcutAction)] = [:]
    @ObservationIgnored private var nextID: UInt32 = 1
    @ObservationIgnored private var started = false
    @ObservationIgnored private var recordingMonitor: Any?

    /// No global hotkeys while a recording is listening.
    var isPaused: Bool { recordingAction != nil }

    func start() {
        guard !started else { return }
        started = true
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, event, _ in
            var hk = EventHotKeyID()
            GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID), nil,
                              MemoryLayout<EventHotKeyID>.size, nil, &hk)
            MainActor.assumeIsolated { HotKeyCenter.shared.fire(id: hk.id) }
            return noErr
        }, 1, &spec, nil, &handler)
        reload()
        observe()
    }

    func reload() {
        for (_, entry) in registered { UnregisterEventHotKey(entry.ref) }
        registered = [:]
        var failed: Set<ShortcutAction> = []
        if started, !isPaused, Settings.shared.hotKeyEnabled {
            for (action, combo) in Settings.shared.shortcuts where combo.isValid && !combo.isReserved {
                let id = nextID
                nextID += 1
                var ref: EventHotKeyRef?
                let status = RegisterEventHotKey(UInt32(combo.keyCode), combo.carbonModifiers,
                                                 EventHotKeyID(signature: OSType(0x5442_4D21), id: id),   // 'TBM!'
                                                 GetApplicationEventTarget(), 0, &ref)
                if status == noErr, let ref {
                    registered[id] = (ref, action)
                } else {
                    failed.insert(action)
                }
            }
        }
        if failed != self.failed { self.failed = failed }
    }

    private func observe() {
        withObservationTracking {
            _ = Settings.shared.shortcuts
            _ = Settings.shared.hotKeyEnabled
        } onChange: {
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    HotKeyCenter.shared.reload()
                    HotKeyCenter.shared.observe()
                }
            }
        }
    }

    // MARK: recording

    /// Starts listening for `action`'s new combo. Ends with a valid press, ⎋, `cancelRecording()`, the settings
    /// window closing or the app quitting – never silently, because the monitor eats every key in the app.
    func beginRecording(_ action: ShortcutAction) {
        cancelRecording()
        recordingAction = action
        recordingModifiers = []
        recordingNote = nil
        reload()
        recordingMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .flagsChanged]) { [weak self] event in
            MainActor.assumeIsolated {
                guard let self else { return }
                if event.type == .flagsChanged {
                    self.recordingModifiers = event.modifierFlags.intersection(KeyCombo.modifierMask)
                } else {
                    self.record(event)
                }
            }
            return nil   // nothing leaks through while recording
        }
    }

    /// Ends a recording without changing anything; safe to call when nothing is being recorded.
    func cancelRecording() {
        if let recordingMonitor { NSEvent.removeMonitor(recordingMonitor) }
        recordingMonitor = nil
        guard recordingAction != nil else { return }
        recordingAction = nil
        recordingModifiers = []
        reload()
    }

    func clearNote(for action: ShortcutAction) {
        if recordingNote?.action == action { recordingNote = nil }
    }

    private func record(_ event: NSEvent) {
        guard let action = recordingAction else { return }
        if Int(event.keyCode) == kVK_Escape && event.modifierFlags.intersection(KeyCombo.modifierMask).isEmpty {
            cancelRecording()
            return
        }
        guard let c = KeyCombo(event: event) else { return }
        if !c.isValid {
            recordingNote = RecordingNote(action: action, text: "Mit ⌘, ⌃ oder ⌥ kombinieren")
            return
        }
        if c.isReserved {
            recordingNote = RecordingNote(action: action, text: "Vom System belegt")
            return
        }
        if let other = Settings.shared.shortcuts.first(where: { $0.key != action && $0.value == c })?.key {
            recordingNote = RecordingNote(action: action, text: "Bereits belegt: \(other.title)")
            return
        }
        recordingNote = nil
        cancelRecording()
        Settings.shared.shortcuts[action] = c
    }

    // MARK: dispatch

    private func fire(id: UInt32) {
        guard let action = registered[id]?.action else { return }
        perform(action)
    }

    /// Runs an action exactly like its hotkey would (also used by menus).
    func perform(_ action: ShortcutAction) {
        let shelf = ShelfController.shared
        switch action {
        case .openShelf:
            // Mid-drag the shelf is the drop target – never yank it away under the cursor.
            guard NSEvent.pressedMouseButtons & 1 == 0 else { return }
            let selection = FinderSelection.current() ?? []
            if shelf.isVisible && selection.isEmpty {
                shelf.close()
            } else {
                shelf.show(at: nil, files: selection, keyboard: true)
            }

        case .sendClipboard:
            guard !ClipboardPackager.isConcealed else {
                ToastController.shared.flash(Self.concealedHint, symbol: "lock.fill", tone: .error, duration: 3)
                return
            }
            let urls = ClipboardPackager.urls()
            guard !urls.isEmpty else {
                ToastController.shared.flash("Zwischenablage ist leer", symbol: "clipboard", tone: .error)
                return
            }
            shelf.show(at: nil, files: urls, keyboard: true)

        case .sendToLast:
            guard let payload = payload() else { return }
            guard let id = Settings.shared.lastDeviceID else {
                shelf.show(at: nil, files: payload.urls, keyboard: true)
                ToastController.shared.flash("Noch an kein Gerät gesendet – Gerät wählen", symbol: "hand.tap", tone: .info, duration: 3)
                return
            }
            sendDirect(payload, to: id)

        default:
            guard let slot = action.favoriteSlot, let payload = payload() else { return }
            guard let id = Settings.shared.favoriteDeviceIDs[slot - 1] else {
                shelf.show(at: nil, files: payload.urls, keyboard: true)
                ToastController.shared.flash("Favorit \(slot) ist nicht belegt – Rechtsklick auf ein Gerät", symbol: "star", tone: .info, duration: 3)
                return
            }
            sendDirect(payload, to: id)
        }
    }

    private static let concealedHint = "Zwischenablage ist vertraulich – nicht gesendet"

    /// Where a direct send got its files from.
    private enum PayloadSource { case shelf, finder, clipboard }

    private struct Payload {
        let urls: [URL]
        let source: PayloadSource
    }

    /// Zero-UI send: the HUD toast is the only feedback. Falls back to the shelf when the device is not online.
    /// Clipboard content is never shipped unseen – a mis-press must not leak whatever was copied last to another
    /// person's machine – so it goes to the shelf, armed on the target device, and a single ↩ sends it.
    private func sendDirect(_ payload: Payload, to id: String) {
        let shelf = ShelfController.shared
        let device = AppModel.shared.devices.first { $0.id == id }
        let name = device?.name ?? Settings.shared.knownDeviceNames[id] ?? "Das Gerät"
        guard device != nil else {
            shelf.show(at: nil, files: payload.urls, keyboard: true)
            ToastController.shared.flash("\(name) ist nicht online", symbol: "wifi.slash", tone: .error, duration: 3)
            return
        }
        if payload.source == .clipboard {
            shelf.show(at: nil, files: payload.urls, keyboard: true)
            shelf.model.selectedID = id
            ToastController.shared.flash("Zwischenablage im Shelf – ↩ sendet an \(name)", symbol: "doc.on.clipboard", tone: .info, duration: 3)
            return
        }
        if let item = AppModel.shared.sendDirect(payload.urls, to: id), shelf.isVisible {
            shelf.model.sent[id] = item   // keep the bubble's ring in sync
        }
    }

    /// What a direct send takes: the open shelf's files, else the Finder selection (Finder in front), else
    /// whatever the clipboard holds. nil = nothing usable (a hint is shown). A Finder selection that cannot be
    /// read (Automation permission denied) also yields nil: falling through to the clipboard would send the
    /// wrong thing without the user noticing.
    private func payload() -> Payload? {
        let shelf = ShelfController.shared
        if shelf.isVisible, !shelf.model.files.isEmpty { return Payload(urls: shelf.model.files, source: .shelf) }
        guard let selection = FinderSelection.current() else {
            ToastController.shared.flash("Finder-Auswahl nicht lesbar – Automation für Tailbolt in den Systemeinstellungen erlauben",
                                         symbol: "exclamationmark.triangle", tone: .error, duration: 4)
            return nil
        }
        if !selection.isEmpty { return Payload(urls: selection, source: .finder) }
        if ClipboardPackager.isConcealed {
            ToastController.shared.flash(Self.concealedHint, symbol: "lock.fill", tone: .error, duration: 3)
            return nil
        }
        let clip = ClipboardPackager.urls()
        if !clip.isEmpty { return Payload(urls: clip, source: .clipboard) }
        ToastController.shared.flash("Nichts zum Senden – im Finder auswählen oder etwas kopieren", symbol: "doc.on.clipboard", tone: .error, duration: 3)
        return nil
    }
}

// MARK: - Clipboard

/// Turns the general pasteboard into files Tailbolt can send. Files win over everything else; images, rich
/// and plain text are written to a cache folder and deleted again as soon as no shelf or transfer uses them.
@MainActor
enum ClipboardPackager {
    static let directory: URL = {
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Caches")
        return caches.appendingPathComponent("Tailbolt/Clipboard", isDirectory: true)
    }()

    /// Password managers mark secrets (and one-shot content) with these types – see nspasteboard.org.
    /// Such content is never written to disk, let alone sent.
    static let concealedTypes = ["org.nspasteboard.ConcealedType", "org.nspasteboard.TransientType"]
        .map { NSPasteboard.PasteboardType($0) }

    static var isConcealed: Bool {
        let types = NSPasteboard.general.types ?? []
        return concealedTypes.contains { types.contains($0) }
    }

    static func urls() -> [URL] {
        let pb = NSPasteboard.general
        prune()
        guard !isConcealed else { return [] }

        if let files = pb.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] {
            let existing = files.filter { FileManager.default.fileExists(atPath: $0.path) }
            if !existing.isEmpty { return existing }
        }

        let stamp = Self.stamp()
        if let png = pb.data(forType: .png) ?? pb.data(forType: .tiff).flatMap({ NSBitmapImageRep(data: $0)?.representation(using: .png, properties: [:]) }) {
            return write(png, name: "Bild \(stamp).png")
        }
        if let text = pb.string(forType: .string), !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            let isLink = !trimmed.contains(where: \.isWhitespace) && (trimmed.hasPrefix("http://") || trimmed.hasPrefix("https://"))
            return write(Data(text.utf8), name: "\(isLink ? "Link" : "Text") \(stamp).txt")
        }
        if let rtf = pb.data(forType: .rtf) {
            return write(rtf, name: "Text \(stamp).rtf")
        }
        return []
    }

    private static func write(_ data: Data, name: String) -> [URL] {
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let url = directory.appendingPathComponent(name)
            try data.write(to: url, options: .atomic)
            return [url]
        } catch {
            NSLog("Tailbolt: clipboard export failed: \(error)")
            return []
        }
    }

    private static func stamp() -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "de_CH")
        f.dateFormat = "yyyy-MM-dd HH.mm.ss"
        return f.string(from: Date())
    }

    /// Deletes exported clipboard files once nothing shows or sends them any more (shelf closed or emptied,
    /// transfer ended). URLs outside the cache folder are ignored, so callers pass whatever they held.
    static func release(_ urls: [URL]) {
        let exported = urls.filter(isExport)
        guard !exported.isEmpty else { return }
        let referenced = referencedPaths()
        for url in exported where !referenced.contains(url.standardizedFileURL.path) {
            try? FileManager.default.removeItem(at: url)
        }
    }

    /// Safety net for exports `release` never saw (crash, force quit): drops anything older than a day that
    /// no shelf or transfer is using.
    static func prune() {
        let fm = FileManager.default
        guard let items = try? fm.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.contentModificationDateKey]) else { return }
        let cutoff = Date().addingTimeInterval(-86400)
        let referenced = referencedPaths()
        for url in items where !referenced.contains(url.standardizedFileURL.path) {
            let date = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
            if date < cutoff { try? fm.removeItem(at: url) }
        }
    }

    private static func isExport(_ url: URL) -> Bool {
        url.standardizedFileURL.path.hasPrefix(directory.standardizedFileURL.path + "/")
    }

    /// Paths the open shelf holds or an active outgoing transfer is still reading.
    private static func referencedPaths() -> Set<String> {
        let inShelf = ShelfController.shared.model.files
        let inFlight = AppModel.shared.transfers.filter(\.isActive).flatMap(\.sourceURLs)
        return Set((inShelf + inFlight).map { $0.standardizedFileURL.path })
    }
}
