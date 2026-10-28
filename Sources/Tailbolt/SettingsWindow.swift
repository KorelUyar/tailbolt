import AppKit
import Carbon.HIToolbox
import SwiftUI
import TailboltCore

/// Hooks for features that live elsewhere (onboarding, docs). Wired at launch; nil hides the control.
@MainActor
enum SettingsActions {
    /// "Einführung erneut anzeigen" (Allgemein) – e.g. `{ OnboardingWindow.show() }`.
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
        case .general: return "Allgemein"
        case .send: return "Senden"
        case .receive: return "Empfangen"
        case .shortcuts: return "Shortcuts"
        case .info: return "Info"
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
        case .general: return "Start, Töne und Haptik"
        case .send: return "Shelf, Gesten und Übertragung"
        case .receive: return "Speicherort und automatisches Annehmen"
        case .shortcuts: return "Tastenkürzel, Favoriten und Integrationen"
        case .info: return "Version, Tailnet und Geschwindigkeitstest"
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
        w.setAccessibilityLabel("Tailbolt Einstellungen")
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
                    SettingsRowLabel(title: "Beim Anmelden starten", subtitle: "Tailbolt wartet dann im Hintergrund auf Dateien.")
                }
                .onChange(of: launchAtLogin) { _, v in settings.launchAtLogin = v }
                .help("Tailbolt beim Anmelden automatisch starten")
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

            Section("Rückmeldungen") {
                Toggle(isOn: $settings.soundsEnabled) {
                    SettingsRowLabel(title: "Töne", subtitle: "Ein leiser Klang bei einer Anfrage und wenn etwas angekommen ist.")
                }
                .help("Töne beim Empfangen und nach dem Senden")
                Toggle(isOn: $settings.hapticsEnabled) {
                    SettingsRowLabel(title: "Haptisches Feedback", subtitle: "Ein kurzer Trackpad-Klick beim Ablegen auf ein Gerät und beim Abschluss.")
                }
                .help("Haptik auf dem Trackpad (Force Touch)")
            }

            Section("Einführung") {
                LabeledContent {
                    Button("Erneut anzeigen…") { SettingsActions.openOnboarding?() }
                        .help("Die kurze Tour noch einmal ansehen")
                        .disabled(SettingsActions.openOnboarding == nil)
                } label: {
                    SettingsRowLabel(title: "Die kurze Tour", subtitle: "Shelf, Schütteln, Tastenkürzel und Empfangen in einer Minute.")
                }
            }

            if let folder = relocationFolder {
                Section("Ablageort") {
                    LabeledContent {
                        Button("Nach Programme verschieben…") { relocate() }
                            .help("Tailbolt in den Ordner «Programme» verschieben und neu starten")
                    } label: {
                        SettingsRowLabel(title: "Tailbolt liegt in «\(folder)»",
                                         subtitle: "Im Ordner «Programme» bleibt es am gleichen Ort und kann beim Anmelden starten.")
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
                    SettingsRowLabel(title: "Nach erfolgreichem Senden schliessen")
                }
                .help("Das Shelf verschwindet, sobald alles angekommen ist")
            }

            Section {
                Toggle(isOn: $settings.shakeToOpen) {
                    SettingsRowLabel(title: "Schütteln beim Ziehen öffnet das Shelf",
                                     subtitle: "Dateien ziehen und den Cursor kurz hin und her bewegen.")
                }
                .help("Shelf durch Schütteln der Maus beim Ziehen öffnen")
                LabeledContent("Empfindlichkeit") {
                    Picker("Empfindlichkeit", selection: $settings.shakeSensitivity) {
                        ForEach(ShakeSensitivity.allCases) { Text($0.label).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .fixedSize()
                    .help("Wie kräftig geschüttelt werden muss")
                }
                .disabled(!settings.shakeToOpen)
                Toggle(isOn: $settings.shiftDragTrigger) {
                    SettingsRowLabel(title: "⇧ gedrückt halten öffnet das Shelf",
                                     subtitle: "Beim Ziehen eine Viertelsekunde lang – für alle, die lieber nicht schütteln.")
                }
                .help("Shelf durch Halten der Umschalttaste beim Ziehen öffnen")
            } header: {
                Text("Gesten")
            } footer: {
                SettingsFooter("Das Shelf erscheint unter dem Cursor: Dateien darauf fallen lassen oder direkt auf ein Gerät ziehen.")
            }

            Section {
                Toggle(isOn: $settings.lanTurboEnabled) {
                    SettingsRowLabel(title: "LAN-Turbo",
                                     subtitle: "Geräte im selben Netzwerk bekommen zusätzliche direkte Verbindungen am Tunnel vorbei – weiterhin Ende-zu-Ende verschlüsselt.")
                }
                .help("Direkte LAN-Verbindungen neben dem Tailscale-Tunnel nutzen")
                Toggle(isOn: $settings.lz4Enabled) {
                    SettingsRowLabel(title: "LZ4-Kompression",
                                     subtitle: "Verkleinert komprimierbare Dateien unterwegs. Fotos, Videos und Archive bleiben unangetastet.")
                }
                .disabled(!LZ4.available)
                .help(LZ4.available ? "Daten auf dem Weg komprimieren" : "LZ4 ist auf diesem Mac nicht verfügbar")
            } header: {
                Text("Übertragung")
            } footer: {
                if !LZ4.available { SettingsFooter("LZ4 ist auf diesem Mac nicht verfügbar.") }
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
            Section("Speicherort") {
                LabeledContent("Speichern in") {
                    HStack(spacing: 8) {
                        Image(nsImage: NSWorkspace.shared.icon(forFile: settings.downloadDirectory.path))
                            .resizable()
                            .frame(width: 16, height: 16)
                        Text(settings.downloadDirectory.path.replacingOccurrences(of: NSHomeDirectory(), with: "~"))
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .foregroundStyle(.secondary)
                        Button("Ändern…") { chooseFolder() }
                            .help("Anderen Ordner für empfangene Dateien wählen")
                    }
                }
            }

            Section {
                Toggle("Von meinen eigenen Geräten", isOn: $settings.autoAcceptOwnDevices)
                    .help("Was von deinen eigenen Geräten kommt, landet ohne Nachfrage im Ordner")
                Toggle("Von Favoriten", isOn: $settings.autoAcceptFavorites)
                    .help("Geräte mit einem Favoriten-Platz (⌃⌥⌘1 … 9) müssen nicht fragen")
            } header: {
                Text("Automatisch annehmen")
            } footer: {
                SettingsFooter("Alle anderen Anfragen erscheinen als Karte oben rechts – ↩ nimmt an, ⎋ lehnt ab.")
            }

            Section {
                if settings.alwaysAcceptPeerIDs.isEmpty {
                    Text("Noch keine Geräte.")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(settings.alwaysAcceptPeerIDs, id: \.self) { id in
                        alwaysAcceptRow(id)
                    }
                }
            } header: {
                Text("Immer annehmen von")
            } footer: {
                SettingsFooter("⌥-Klick auf «Annehmen» bei einer Anfrage nimmt das Gerät in diese Liste auf.")
            }

            Section("Berechtigung") {
                LabeledContent {
                    Button(networkAsked ? "Angefragt" : "Zugriff erlauben…") {
                        LocalNetworkPermission.prime()
                        networkAsked = true
                    }
                    .disabled(networkAsked)
                    .help("Löst die macOS-Nachfrage für das lokale Netzwerk aus")
                } label: {
                    SettingsRowLabel(title: "Lokales Netzwerk",
                                     subtitle: networkAsked
                                        ? "Fragt macOS nicht, ist der Zugriff bereits geregelt: Systemeinstellungen → Datenschutz & Sicherheit → Lokales Netzwerk."
                                        : "macOS fragt einmal nach. Ohne Erlaubnis läuft alles durch den Tailscale-Tunnel und LAN-Turbo bleibt aus.")
                }
            }
        }
        .formStyle(.grouped)
        .animation(reduceMotion ? nil : .easeOut(duration: 0.2), value: settings.alwaysAcceptPeerIDs)
    }

    private func alwaysAcceptRow(_ id: String) -> some View {
        let device = app.devices.first { $0.id == id }
        let name = device?.name ?? settings.knownDeviceNames[id] ?? "Gerät"
        return HStack(spacing: 10) {
            Image(systemName: device?.symbol ?? "desktopcomputer")
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
                .frame(width: 24, height: 24)
                .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(.quaternary))
            Text(name)
            if device == nil {
                Text("offline")
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
            }
            Spacer()
            Button {
                settings.setAlwaysAccept(id, name: nil, on: false)
            } label: {
                Image(systemName: "minus.circle.fill")
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.borderless)
            .help("\(name) aus der Liste entfernen")
            .accessibilityLabel("\(name) entfernen")
        }
    }

    private func chooseFolder() {
        let p = NSOpenPanel()
        p.canChooseDirectories = true
        p.canChooseFiles = false
        p.canCreateDirectories = true
        p.directoryURL = settings.downloadDirectory
        p.prompt = "Wählen"
        p.message = "Wohin sollen empfangene Dateien?"
        if p.runModal() == .OK, let url = p.url { settings.downloadDirectory = url }
    }
}
