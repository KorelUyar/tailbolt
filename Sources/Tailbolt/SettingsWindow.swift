import AppKit
import Carbon.HIToolbox
import SwiftUI
import TailboltCore

/// Hooks for features that live elsewhere (onboarding, docs). Wired at launch; nil hides the control.
@MainActor
enum SettingsActions {
    /// "Show Again…" (General) – e.g. `{ OnboardingWindow.show() }`.
    static var openOnboarding: (() -> Void)?
    /// "README" link in the Info tab; nil hides it.
    static var readmeURL: URL?
}

/// Knobs for `--snapshot` so every state of the settings can be rendered without touching user data.
@MainActor
enum SettingsPreview {
    /// Shows the "Nach Programme verschieben" row as if the app ran from this folder.
    static var relocationFolder: String?
    /// Bench model the Info tab picks up instead of a fresh one.
    static var bench: BenchModel?
}

enum SettingsTab: String, CaseIterable, Identifiable {
    case general, send, receive, shortcuts, info

    var id: String { rawValue }

    var title: String {
        switch self {
        case .general: return String(localized: "General")
        case .send: return String(localized: "Send")
        case .receive: return String(localized: "Receive")
        case .shortcuts: return String(localized: "Shortcuts")
        case .info: return String(localized: "About")
        }
    }

    var symbol: String {
        switch self {
        case .general: return "gearshape"
        case .send: return "paperplane"
        case .receive: return "tray.and.arrow.down"
        case .shortcuts: return "keyboard"
        case .info: return "info.circle"
        }
    }

    var toolTip: String {
        switch self {
        case .general: return String(localized: "Launch, sounds and haptics")
        case .send: return String(localized: "Shelf, gestures and transfer")
        case .receive: return String(localized: "Location and auto-accept")
        case .shortcuts: return String(localized: "Keyboard shortcuts, favorites and integrations")
        case .info: return String(localized: "Version, tailnet and speed test")
        }
    }

    fileprivate var itemID: NSToolbarItem.Identifier { NSToolbarItem.Identifier(rawValue) }
}

/// The settings window: a native preferences window (toolbar tabs with SF Symbols, `.preference` toolbar
/// style) whose height follows the selected pane like System Settings. One instance, retained, ordered out
/// on close.
@MainActor
enum SettingsWindow {
    static let width: CGFloat = 520
    /// Panes taller than this (Shortcuts) scroll inside the window.
    static let maxContentHeight: CGFloat = 640
    private static var controller: SettingsWindowController?

    static func show(tab: SettingsTab = .general) {
        let c = controller ?? SettingsWindowController(tab: tab)
        controller = c
        let wasVisible = c.window.isVisible
        // Re-selecting the visible tab would rebuild the pane and drop its local state (a running speed test, …).
        if !wasVisible || tab != c.tab { c.select(tab, animated: wasVisible) }
        if !wasVisible { c.window.center() }
        NSApp.activate(ignoringOtherApps: true)
        c.window.makeKeyAndOrderFront(nil)
    }

    /// A fully built, unshown window for `tab` (used by `--snapshot`). `decorate` wraps the SwiftUI root.
    /// Keep the controller alive while the window is in use – the toolbar only holds it weakly.
    static func makeController(tab: SettingsTab, appearance: NSAppearance? = nil,
                               decorate: ((AnyView) -> AnyView)? = nil) -> SettingsWindowController {
        SettingsWindowController(tab: tab, decorate: decorate, appearance: appearance)
    }
}

@MainActor
final class SettingsWindowController: NSObject, NSToolbarDelegate {
    let window: NSWindow
    private(set) var tab: SettingsTab
    private let hosting: NSHostingView<SettingsPane>
    private let decorate: ((AnyView) -> AnyView)?
    private var closeObserver: NSObjectProtocol?
    private var keyMonitor: Any?

    init(tab: SettingsTab, decorate: ((AnyView) -> AnyView)? = nil, appearance: NSAppearance? = nil) {
        self.tab = tab
        self.decorate = decorate
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: SettingsWindow.width, height: 400),
                         styleMask: [.titled, .closable, .miniaturizable], backing: .buffered, defer: false)
        w.isReleasedWhenClosed = false
        w.appearance = appearance
        w.title = tab.title
        w.tabbingMode = .disallowed
        w.collectionBehavior = [.moveToActiveSpace]
        w.setAccessibilityLabel(String(localized: "Tailbolt Settings"))
        hosting = NSHostingView(rootView: SettingsPane(tab: tab, decorate: decorate))
        hosting.sizingOptions = []   // the window owns its size; tall panes scroll
        w.contentView = hosting
        window = w
        super.init()

        let toolbar = NSToolbar(identifier: "settings")
        toolbar.delegate = self
        toolbar.displayMode = .iconAndLabel
        toolbar.allowsUserCustomization = false
        toolbar.selectedItemIdentifier = tab.itemID
        w.toolbar = toolbar
        w.toolbarStyle = .preference
        fit(animated: false)

        // The window is retained and only ordered out on close, so SwiftUI's onDisappear never fires for
        // its content: a shortcut recording still listening would keep eating every key in the app.
        closeObserver = NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: w, queue: .main) { _ in
            MainActor.assumeIsolated { HotKeyCenter.shared.cancelRecording() }
        }
        // An accessory app has no main menu, so ⌘W needs a hand.
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            let handled = MainActor.assumeIsolated { () -> Bool in
                guard let self, self.window.isKeyWindow, !HotKeyCenter.shared.isPaused,
                      event.modifierFlags.intersection(KeyCombo.modifierMask) == [.command],
                      Int(event.keyCode) == kVK_ANSI_W else { return false }
                self.window.performClose(nil)
                return true
            }
            return handled ? nil : event
        }
    }

    func select(_ tab: SettingsTab, animated: Bool) {
        self.tab = tab
        window.toolbar?.selectedItemIdentifier = tab.itemID
        window.title = tab.title
        hosting.rootView = SettingsPane(tab: tab, decorate: decorate)
        hosting.layoutSubtreeIfNeeded()
        fit(animated: animated)
    }

    /// Resizes the window to the pane's ideal height, keeping the title bar where it is. The live hosting
    /// view has sizing switched off (the window dictates its size), so the ideal height comes from a scratch
    /// hosting view of the same pane.
    private func fit(animated: Bool) {
        let probe = NSHostingView(rootView: SettingsPane(tab: tab, decorate: decorate))
        probe.appearance = window.appearance
        let ideal = probe.fittingSize.height
        let height = min(max(ideal, 180), SettingsWindow.maxContentHeight)
        var frame = window.frameRect(forContentRect: NSRect(x: 0, y: 0, width: SettingsWindow.width, height: height))
        frame.origin.x = window.frame.minX
        frame.origin.y = window.frame.maxY - frame.height
        let animate = animated && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        window.setFrame(frame, display: true, animate: animate)
    }

    // MARK: NSToolbarDelegate

    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] { SettingsTab.allCases.map(\.itemID) }
    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] { SettingsTab.allCases.map(\.itemID) }
    func toolbarSelectableItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] { SettingsTab.allCases.map(\.itemID) }

    func toolbar(_ toolbar: NSToolbar, itemForItemIdentifier id: NSToolbarItem.Identifier, willBeInsertedIntoToolbar: Bool) -> NSToolbarItem? {
        guard let tab = SettingsTab(rawValue: id.rawValue) else { return nil }
        let item = NSToolbarItem(itemIdentifier: id)
        item.label = tab.title
        item.paletteLabel = tab.title
        item.toolTip = tab.toolTip
        item.image = NSImage(systemSymbolName: tab.symbol, accessibilityDescription: tab.title)
        item.target = self
        item.action = #selector(toolbarItemSelected(_:))
        return item
    }

    @objc private func toolbarItemSelected(_ sender: NSToolbarItem) {
        guard let tab = SettingsTab(rawValue: sender.itemIdentifier.rawValue), tab != self.tab else { return }
        select(tab, animated: true)
    }
}

/// The content below the toolbar for one tab.
struct SettingsPane: View {
    let tab: SettingsTab
    var decorate: ((AnyView) -> AnyView)? = nil

    var body: some View {
        let base = AnyView(content.frame(width: SettingsWindow.width))
        return decorate?(base) ?? base
    }

    @ViewBuilder
    private var content: some View {
        switch tab {
        case .general: GeneralSettingsView()
        case .send: SendSettingsView()
        case .receive: ReceiveSettingsView()
        case .shortcuts: ShortcutsSettingsView()
        case .info: AboutView()
        }
    }
}

/// Section footer the way System Settings sets it: small, secondary, leading-aligned. (SwiftUI's grouped
/// Form on macOS renders footers as trailing-aligned body text.)
struct SettingsFooter: View {
    let text: String

    init(_ text: String) { self.text = text }

    var body: some View {
        Text(text)
            .font(.system(size: 11))
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.leading)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// Title + one-line explanation, the System Settings row pattern.
struct SettingsRowLabel: View {
    let title: String
    var subtitle: String? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
            if let subtitle {
                Text(subtitle)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .accessibilityElement(children: .combine)
    }
}

// MARK: - Allgemein

struct GeneralSettingsView: View {
    @State private var settings = Settings.shared
    @State private var launchAtLogin = Settings.shared.launchAtLogin
    @State private var language = AppLanguage.current

    var body: some View {
        Form {
            Section {
                Toggle(isOn: $launchAtLogin) {
                    SettingsRowLabel(title: String(localized: "Launch at login"), subtitle: String(localized: "Tailbolt then waits for files in the background."))
                }
                .onChange(of: launchAtLogin) { _, v in settings.launchAtLogin = v }
                .help("Start Tailbolt automatically when you log in")
            }

            Section {
                Picker(selection: $language) {
                    ForEach(AppLanguage.allCases) { Text(verbatim: $0.nativeName).tag($0) }
                } label: {
                    SettingsRowLabel(title: String(localized: "Language"),
                                     subtitle: String(localized: "English is the default. Applies after a restart."))
                }
                .onChange(of: language) { _, v in AppLanguage.select(v) }
                .help(String(localized: "Language of the Tailbolt interface"))
                if language != AppLanguage.launched {
                    LabeledContent {
                        Button(String(localized: "Restart Now")) { AppLanguage.relaunch() }
                    } label: {
                        SettingsRowLabel(title: String(localized: "Restart Tailbolt to switch the language."))
                    }
                }
            }

            Section("Feedback") {
                Toggle(isOn: $settings.soundsEnabled) {
                    SettingsRowLabel(title: String(localized: "Sounds"), subtitle: String(localized: "A soft sound for a request and when something has arrived."))
                }
                .help("Sounds when receiving and after sending")
                Toggle(isOn: $settings.hapticsEnabled) {
                    SettingsRowLabel(title: String(localized: "Haptic feedback"), subtitle: String(localized: "A short trackpad click when you drop onto a device and when it’s done."))
                }
                .help("Haptics on the trackpad (Force Touch)")
            }

            Section("Tour") {
                LabeledContent {
                    Button("Show Again…") { SettingsActions.openOnboarding?() }
                        .help("Watch the short tour again")
                        .disabled(SettingsActions.openOnboarding == nil)
                } label: {
                    SettingsRowLabel(title: String(localized: "The short tour"), subtitle: String(localized: "Shelf, shake, keyboard shortcuts and receiving in one minute."))
                }
            }

            if let folder = relocationFolder {
                Section("App location") {
                    LabeledContent {
                        Button("Move to Applications…") { relocate() }
                            .help("Move Tailbolt to the “Applications” folder and relaunch it")
                    } label: {
                        SettingsRowLabel(title: String(localized: "Tailbolt is in “\(folder)”"),
                                         subtitle: String(localized: "In the “Applications” folder it stays in one place and can launch at login."))
                    }
                }
            }
        }
        .formStyle(.grouped)
    }

    /// Name of the folder the bundle runs from, when that is not an Applications folder (dev builds: never).
    private var relocationFolder: String? {
        if let forced = SettingsPreview.relocationFolder { return forced }
        let bundle = Bundle.main.bundleURL.standardizedFileURL
        let path = bundle.path
        guard bundle.pathExtension == "app",
              !path.hasPrefix("/Applications/"),
              !path.hasPrefix(NSHomeDirectory() + "/Applications/"),
              !path.contains("/.build/"), !path.contains("/dist/") else { return nil }
        return bundle.deletingLastPathComponent().lastPathComponent
    }

    private func relocate() {
        UserDefaults.standard.removeObject(forKey: "skipRelocation")   // the user asked for it explicitly
        _ = Relocation.offerIfNeeded()
    }
}

// MARK: - Senden

struct SendSettingsView: View {
    @State private var settings = Settings.shared

    var body: some View {
        Form {
            Section("Shelf") {
                Toggle(isOn: $settings.closeShelfAfterSend) {
                    SettingsRowLabel(title: String(localized: "Close after sending successfully"))
                }
                .help("The shelf disappears as soon as everything has arrived")
            }

            Section {
                Toggle(isOn: $settings.shakeToOpen) {
                    SettingsRowLabel(title: String(localized: "Shake while dragging to open the shelf"),
                                     subtitle: String(localized: "Drag files and quickly move the pointer back and forth."))
                }
                .help("Open the shelf by shaking the mouse while dragging")
                LabeledContent("Sensitivity") {
                    Picker("Sensitivity", selection: $settings.shakeSensitivity) {
                        ForEach(ShakeSensitivity.allCases) { Text($0.label).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .fixedSize()
                    .help("How hard you need to shake")
                }
                .disabled(!settings.shakeToOpen)
                Toggle(isOn: $settings.shiftDragTrigger) {
                    SettingsRowLabel(title: String(localized: "Hold ⇧ to open the shelf"),
                                     subtitle: String(localized: "For a quarter of a second while dragging – for anyone who’d rather not shake."))
                }
                .help("Open the shelf by holding Shift while dragging")
            } header: {
                Text("Gestures")
            } footer: {
                SettingsFooter(String(localized: "The shelf appears under the pointer: drop files onto it or drag them straight onto a device."))
            }

            Section {
                Toggle(isOn: $settings.lanTurboEnabled) {
                    SettingsRowLabel(title: String(localized: "LAN Turbo"),
                                     subtitle: String(localized: "Devices on the same network get extra direct connections that bypass the tunnel – still end-to-end encrypted."))
                }
                .help("Use direct LAN connections alongside the Tailscale tunnel")
                Toggle(isOn: $settings.lz4Enabled) {
                    SettingsRowLabel(title: String(localized: "LZ4 compression"),
                                     subtitle: String(localized: "Shrinks compressible files in transit. Photos, videos and archives are left untouched."))
                }
                .disabled(!LZ4.available)
                .help(LZ4.available ? String(localized: "Compress data in transit") : String(localized: "LZ4 isn’t available on this Mac"))
            } header: {
                Text("Transfer")
            } footer: {
                if !LZ4.available { SettingsFooter(String(localized: "LZ4 isn’t available on this Mac.")) }
            }
        }
        .formStyle(.grouped)
        .onChange(of: settings.shakeToOpen) { _, _ in AppDelegate.shared?.applyTriggers() }
        .onChange(of: settings.shiftDragTrigger) { _, _ in AppDelegate.shared?.applyTriggers() }
        .onChange(of: settings.shakeSensitivity) { _, _ in AppDelegate.shared?.applyTriggers() }
    }
}

// MARK: - Empfangen

struct ReceiveSettingsView: View {
    @State private var settings = Settings.shared
    @State private var app = AppModel.shared
    @State private var networkAsked = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Form {
            Section("Location") {
                LabeledContent("Save to") {
                    HStack(spacing: 8) {
                        Image(nsImage: NSWorkspace.shared.icon(forFile: settings.downloadDirectory.path))
                            .resizable()
                            .frame(width: 16, height: 16)
                        Text(settings.downloadDirectory.path.replacingOccurrences(of: NSHomeDirectory(), with: "~"))
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .foregroundStyle(.secondary)
                        Button("Change…") { chooseFolder() }
                            .help("Choose a different folder for received files")
                    }
                }
            }

            Section {
                Toggle("From my own devices", isOn: $settings.autoAcceptOwnDevices)
                    .help("Anything from your own devices goes straight into the folder without asking")
                Toggle("From favorites", isOn: $settings.autoAcceptFavorites)
                    .help("Devices with a favorite slot (⌃⌥⌘1 … 9) don’t need to ask")
            } header: {
                Text("Accept automatically")
            } footer: {
                SettingsFooter(String(localized: "All other requests appear as a card in the top-right corner – ↩ accepts, ⎋ declines."))
            }

            Section {
                if settings.alwaysAcceptPeerIDs.isEmpty {
                    Text("No devices yet.")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(settings.alwaysAcceptPeerIDs, id: \.self) { id in
                        alwaysAcceptRow(id)
                    }
                }
            } header: {
                Text("Always accept from")
            } footer: {
                SettingsFooter(String(localized: "Right-click someone’s device and choose “Auto-Accept with Each Other…” – once they allow it, files between you arrive without asking, both ways. ⌥-click “Accept” on a request adds just their device here."))
            }

            Section("Permission") {
                LabeledContent {
                    Button(networkAsked ? String(localized: "Requested") : String(localized: "Allow Access…")) {
                        LocalNetworkPermission.prime()
                        networkAsked = true
                    }
                    .disabled(networkAsked)
                    .help("Shows the macOS prompt for local network access")
                } label: {
                    SettingsRowLabel(title: String(localized: "Local Network"),
                                     subtitle: networkAsked
                                        ? String(localized: "If macOS doesn’t ask, access is already settled: System Settings → Privacy & Security → Local Network.")
                                        : String(localized: "macOS asks once. Without permission, everything goes through the Tailscale tunnel and LAN Turbo stays off."))
                }
            }
        }
        .formStyle(.grouped)
        .animation(reduceMotion ? nil : .easeOut(duration: 0.2), value: settings.alwaysAcceptPeerIDs)
    }

    private func alwaysAcceptRow(_ id: String) -> some View {
        let device = app.devices.first { $0.id == id }
        let name = device?.name ?? settings.knownDeviceNames[id] ?? String(localized: "Device")
        return HStack(spacing: 10) {
            DeviceThumb(art: device?.art ?? DeviceArt.make(os: "macOS", name: name, model: nil), size: 24)
            Text(name)
            if settings.isPaired(id) {
                PathCapsule(label: String(localized: "Both ways"), tint: .green)
                    .help("Paired: \(name) also accepts your files without asking")
            }
            if device == nil {
                Text("offline")
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
            }
            Spacer()
            Button {
                app.unpair(deviceID: id)
            } label: {
                Image(systemName: "minus.circle.fill")
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.borderless)
            .help("Remove \(name) from the list")
            .accessibilityLabel("Remove \(name)")
        }
    }

    private func chooseFolder() {
        let p = NSOpenPanel()
        p.canChooseDirectories = true
        p.canChooseFiles = false
        p.canCreateDirectories = true
        p.directoryURL = settings.downloadDirectory
        p.prompt = String(localized: "Choose")
        p.message = String(localized: "Where should received files go?")
        if p.runModal() == .OK, let url = p.url { settings.downloadDirectory = url }
    }
}
