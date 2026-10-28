import Foundation
import Observation
import ServiceManagement

/// Three steps for the shake gesture (Einstellungen → Senden): how far the cursor has to travel between
/// direction changes and how many reversals count as a shake.
enum ShakeSensitivity: Int, CaseIterable, Identifiable {
    case gentle = 0, normal = 1, strong = 2

    var id: Int { rawValue }

    var label: String {
        switch self {
        case .gentle: return "Sanft"
        case .normal: return "Normal"
        case .strong: return "Kräftig"
        }
    }

    /// Minimum horizontal travel (points) between two reversals.
    var minTravel: CGFloat {
        switch self {
        case .gentle: return 18
        case .normal: return 28
        case .strong: return 40
        }
    }

    /// Direction reversals within the detection window that trigger the shelf.
    var reversalsNeeded: Int {
        switch self {
        case .gentle: return 2
        case .normal: return 3
        case .strong: return 4
        }
    }
}

@MainActor @Observable
final class Settings {
    static let shared = Settings()
    private let d = UserDefaults.standard

    var downloadDirectory: URL {
        didSet { d.set(downloadDirectory.path, forKey: "downloadDirectory") }
    }
    var autoAcceptOwnDevices: Bool {
        didSet { d.set(autoAcceptOwnDevices, forKey: "autoAcceptOwnDevices") }
    }
    var shakeToOpen: Bool {
        didSet { d.set(shakeToOpen, forKey: "shakeToOpen") }
    }
    /// Master switch for all global shortcuts.
    var hotKeyEnabled: Bool {
        didSet { d.set(hotKeyEnabled, forKey: "hotKeyEnabled") }
    }
    var closeShelfAfterSend: Bool {
        didSet { d.set(closeShelfAfterSend, forKey: "closeShelfAfterSend") }
    }
    var recentDeviceIDs: [String] {
        didSet { d.set(recentDeviceIDs, forKey: "recentDeviceIDs") }
    }
    /// HUD capsule for the zero-UI sends (hotkey → last device / favorite).
    var hudEnabled: Bool {
        didSet { d.set(hudEnabled, forKey: "hudEnabled") }
    }
    /// Missing action = shortcut switched off.
    var shortcuts: [ShortcutAction: KeyCombo] {
        didSet { saveShortcuts() }
    }
    /// Nine slots for ⌃⌥⌘1 … 9.
    var favoriteDeviceIDs: [String?] {
        didSet { d.set(favoriteDeviceIDs.map { $0 ?? "" }, forKey: "favoriteDeviceIDs") }
    }
    var lastDeviceID: String? {
        didSet { d.set(lastDeviceID, forKey: "lastDeviceID") }
    }
    /// Names of devices we sent to or favorited, so offline favorites still have a label.
    var knownDeviceNames: [String: String] {
        didSet { d.set(knownDeviceNames, forKey: "knownDeviceNames") }
    }
    /// Completion "Tink" / incoming "Glass".
    var soundsEnabled: Bool {
        didSet { d.set(soundsEnabled, forKey: "soundsEnabled") }
    }
    /// Trackpad haptics on drag-enter, drop, completion and the shake gesture.
    var hapticsEnabled: Bool {
        didSet { d.set(hapticsEnabled, forKey: "hapticsEnabled") }
    }
    /// How hard you have to shake the cursor while dragging files.
    var shakeSensitivity: ShakeSensitivity {
        didSet { d.set(shakeSensitivity.rawValue, forKey: "shakeSensitivity") }
    }
    /// Alternative to shaking: hold ⇧ for 250 ms while dragging files → shelf under the cursor.
    var shiftDragTrigger: Bool {
        didSet { d.set(shiftDragTrigger, forKey: "shiftDragTrigger") }
    }
    /// Direct LAN streams next to the tunnel (TailboltServer.lanFastPathEnabled + sender-side peerLANHint).
    var lanTurboEnabled: Bool {
        didSet { d.set(lanTurboEnabled, forKey: "lanTurboEnabled") }
    }
    /// Adaptive LZ4 on the wire.
    var lz4Enabled: Bool {
        didSet { d.set(lz4Enabled, forKey: "lz4Enabled") }
    }
    /// Offers from favorite devices are accepted without asking.
    var autoAcceptFavorites: Bool {
        didSet { d.set(autoAcceptFavorites, forKey: "autoAcceptFavorites") }
    }
    /// Peers (tailnet ids) whose offers are always accepted ("Immer von <Name> annehmen").
    var alwaysAcceptPeerIDs: [String] {
        didSet { d.set(alwaysAcceptPeerIDs, forKey: "alwaysAcceptPeerIDs") }
    }

    var launchAtLogin: Bool {
        get { SMAppService.mainApp.status == .enabled }
        set {
            do {
                if newValue { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            } catch {
                NSLog("Tailbolt: launch at login failed: \(error)")
            }
        }
    }

    private init() {
        d.register(defaults: [
            "autoAcceptOwnDevices": true,
            "shakeToOpen": true,
            "hotKeyEnabled": true,
            "closeShelfAfterSend": true,
            "hudEnabled": true,
            "soundsEnabled": true,
            "hapticsEnabled": true,
            "shakeSensitivity": ShakeSensitivity.normal.rawValue,
            "shiftDragTrigger": false,
            "lanTurboEnabled": true,
            "lz4Enabled": true,
            "autoAcceptFavorites": true,
        ])
        let downloads = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Downloads")
        downloadDirectory = d.string(forKey: "downloadDirectory").map { URL(fileURLWithPath: $0) } ?? downloads
        autoAcceptOwnDevices = d.bool(forKey: "autoAcceptOwnDevices")
        shakeToOpen = d.bool(forKey: "shakeToOpen")
        hotKeyEnabled = d.bool(forKey: "hotKeyEnabled")
        closeShelfAfterSend = d.bool(forKey: "closeShelfAfterSend")
        recentDeviceIDs = d.stringArray(forKey: "recentDeviceIDs") ?? []
        hudEnabled = d.bool(forKey: "hudEnabled")
        shortcuts = Self.loadShortcuts(d) ?? ShortcutAction.defaults
        let favorites = (d.stringArray(forKey: "favoriteDeviceIDs") ?? []).map { $0.isEmpty ? nil : $0 }
        favoriteDeviceIDs = Array(favorites.prefix(9)) + Array<String?>(repeating: nil, count: max(0, 9 - favorites.count))
        lastDeviceID = d.string(forKey: "lastDeviceID")
        knownDeviceNames = d.dictionary(forKey: "knownDeviceNames") as? [String: String] ?? [:]
        soundsEnabled = d.bool(forKey: "soundsEnabled")
        hapticsEnabled = d.bool(forKey: "hapticsEnabled")
        shakeSensitivity = ShakeSensitivity(rawValue: d.integer(forKey: "shakeSensitivity")) ?? .normal
        shiftDragTrigger = d.bool(forKey: "shiftDragTrigger")
        lanTurboEnabled = d.bool(forKey: "lanTurboEnabled")
        lz4Enabled = d.bool(forKey: "lz4Enabled")
        autoAcceptFavorites = d.bool(forKey: "autoAcceptFavorites")
        alwaysAcceptPeerIDs = d.stringArray(forKey: "alwaysAcceptPeerIDs") ?? []
    }

    // MARK: always accept

    func alwaysAccepts(_ deviceID: String) -> Bool {
        alwaysAcceptPeerIDs.contains(deviceID)
    }

    /// Adds/removes a peer from the always-accept list; the name is remembered so the settings list can show it offline.
    func setAlwaysAccept(_ deviceID: String, name: String?, on: Bool) {
        var ids = alwaysAcceptPeerIDs.filter { $0 != deviceID }
        if on {
            ids.append(deviceID)
            if let name { knownDeviceNames[deviceID] = name }
        }
        alwaysAcceptPeerIDs = ids
    }

    func noteUsed(_ deviceID: String, name: String? = nil) {
        recentDeviceIDs = [deviceID] + recentDeviceIDs.filter { $0 != deviceID }.prefix(15)
        lastDeviceID = deviceID
        if let name { knownDeviceNames[deviceID] = name }
    }

    // MARK: favorites

    func favoriteSlot(of deviceID: String) -> Int? {
        favoriteDeviceIDs.firstIndex { $0 == deviceID }.map { $0 + 1 }
    }

    /// Assigns `deviceID` to `slot` (1…9); nil clears the slot. A device lives in at most one slot.
    func setFavorite(id deviceID: String?, name: String?, slot: Int) {
        guard (1...9).contains(slot) else { return }
        var slots = favoriteDeviceIDs
        if let deviceID {
            for i in slots.indices where slots[i] == deviceID { slots[i] = nil }
            if let name { knownDeviceNames[deviceID] = name }
        }
        slots[slot - 1] = deviceID
        favoriteDeviceIDs = slots
    }

    // MARK: shortcuts

    func resetShortcuts() {
        shortcuts = ShortcutAction.defaults
    }

    private func saveShortcuts() {
        let raw = Dictionary(uniqueKeysWithValues: shortcuts.map { ($0.key.rawValue, $0.value) })
        if let data = try? JSONEncoder().encode(raw) { d.set(data, forKey: "shortcuts") }
    }

    private static func loadShortcuts(_ d: UserDefaults) -> [ShortcutAction: KeyCombo]? {
        guard let data = d.data(forKey: "shortcuts"),
              let raw = try? JSONDecoder().decode([String: KeyCombo].self, from: data) else { return nil }
        var out: [ShortcutAction: KeyCombo] = [:]
        for (key, combo) in raw {
            if let action = ShortcutAction(rawValue: key) { out[action] = combo }
        }
        return out
    }
}
