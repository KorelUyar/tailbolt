import AppKit
import Carbon.HIToolbox
import SwiftUI

/// System-Settings-style shortcut field: click → "Tasten drücken…", press a combo, done. ⎋ cancels,
/// the ⌫ button clears (= shortcut off). Refuses modifier-only presses, system combos and conflicts.
/// The recording itself lives in `HotKeyCenter`, so closing the window or quitting always ends it.
struct ShortcutRecorderView: View {
    let action: ShortcutAction

    @State private var settings = Settings.shared
    @State private var hotKeys = HotKeyCenter.shared
    @State private var hover = false

    private var combo: KeyCombo? { settings.shortcuts[action] }
    private var recording: Bool { hotKeys.recordingAction == action }
    private var held: NSEvent.ModifierFlags { recording ? hotKeys.recordingModifiers : [] }
    private var message: String? { hotKeys.recordingNote.flatMap { $0.action == action ? $0.text : nil } }

    var body: some View {
        VStack(alignment: .trailing, spacing: 3) {
            HStack(spacing: 5) {
                field
                Button {
                    if recording { hotKeys.cancelRecording() }
                    settings.shortcuts[action] = nil
                    hotKeys.clearNote(for: action)
                } label: {
                    Image(systemName: "delete.left.fill")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help("Tastenkürzel entfernen")
                .opacity(combo != nil && !recording ? 1 : 0)
                .disabled(combo == nil || recording)
            }
            if let message {
                Text(message)
                    .font(.system(size: 10))
                    .foregroundStyle(.red)
                    .transition(.opacity)
            } else if hotKeys.failed.contains(action) {
                Text("Vom System nicht zugelassen")
                    .font(.system(size: 10))
                    .foregroundStyle(.orange)
            }
        }
        .animation(.easeOut(duration: 0.15), value: message)
        // Fires on a tab switch; a window close does not reach here (retained window) – SettingsWindow covers that.
        .onDisappear { if recording { hotKeys.cancelRecording() } }
    }

    private var field: some View {
        Text(label)
            .font(.system(size: 12, weight: combo == nil && !recording ? .regular : .medium))
            .foregroundStyle(labelColor)
            .frame(minWidth: 96)
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(recording ? Color.accentColor.opacity(0.12) : Color.primary.opacity(hover ? 0.09 : 0.06))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .strokeBorder(recording ? Color.accentColor : Color.primary.opacity(0.12), lineWidth: recording ? 1.5 : 0.5)
            )
            .contentShape(Rectangle())
            .onHover { hover = $0 }
            .onTapGesture { recording ? hotKeys.cancelRecording() : hotKeys.beginRecording(action) }
            .help(recording ? "Tasten drücken – ⎋ bricht ab" : "Klicken, um ein Tastenkürzel aufzunehmen")
            .animation(.easeOut(duration: 0.12), value: recording)
    }

    private var label: String {
        if recording { return held.isEmpty ? "Tasten drücken…" : KeyCombo.symbols(for: held) }
        return combo?.display ?? "Aufnehmen"
    }

    private var labelColor: Color {
        if recording { return held.isEmpty ? .secondary : .accentColor }
        return combo == nil ? .secondary : .primary
    }
}

/// The "Shortcuts" settings tab.
struct ShortcutsSettingsView: View {
    @State private var settings = Settings.shared
    @State private var app = AppModel.shared
    @State private var quickActionInstalled = QuickActionInstaller.isInstalled
    @State private var cliInstalled = CLIInstaller.isInstalled
    @State private var integrationError: String?

    var body: some View {
        Form {
            Section {
                Toggle("Globale Tastenkürzel aktiv", isOn: $settings.hotKeyEnabled)
                Toggle("Kurze Einblendung beim Direktsenden", isOn: $settings.hudEnabled)
            } header: {
                Text("Tastenkürzel")
            } footer: {
                SettingsFooter("Direktsenden nimmt die Dateien im offenen Shelf, sonst die Finder-Auswahl. Die Zwischenablage (Dateien, Bilder, Text) landet zuerst im Shelf – ↩ sendet sie. Als vertraulich markierte Inhalte (Passwort-Manager) werden nie gesendet.")
            }

            Section("Aktionen") {
                ForEach([ShortcutAction.openShelf, .sendClipboard, .sendToLast]) { action in
                    LabeledContent {
                        ShortcutRecorderView(action: action)
                    } label: {
                        Label(action.title, systemImage: action.symbol)
                    }
                }
            }

            Section {
                ForEach(1...9, id: \.self) { slot in favoriteRow(slot) }
            } header: {
                Text("Favoriten")
            } footer: {
                SettingsFooter("Rechtsklick auf ein Gerät im Shelf oder Menü setzt ebenfalls einen Favoriten. Im Shelf senden die Zifferntasten 1–9 an das n-te Gerät.")
            }

            Section {
                Toggle(isOn: Binding(get: { quickActionInstalled }, set: { setQuickAction($0) })) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Schnellaktion im Finder")
                        Text("Rechtsklick auf Dateien → Schnellaktionen → «Mit Tailbolt senden»")
                            .font(.system(size: 11)).foregroundStyle(.secondary)
                    }
                }
                Toggle(isOn: Binding(get: { cliInstalled }, set: { setCLI($0) })) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Befehl «tailbolt» im Terminal")
                        Text("Verknüpft /usr/local/bin/tailbolt mit der App (fragt ggf. nach dem Admin-Passwort)")
                            .font(.system(size: 11)).foregroundStyle(.secondary)
                    }
                }
                if let integrationError {
                    Label(integrationError, systemImage: "exclamationmark.triangle")
                        .font(.system(size: 11)).foregroundStyle(.red)
                }
            } header: {
                Text("Integration")
            }

            // Gestures (shake, hold ⇧) live in Einstellungen → Senden.

            Section {
                HStack {
                    Spacer()
                    Button("Tastenkürzel zurücksetzen") { settings.resetShortcuts() }
                        .help("Alle Tastenkürzel auf ⌃⌥⌘B, ⌃⌥⌘V, ⌃⌥⌘L und ⌃⌥⌘1 … 9 zurücksetzen")
                }
            }
        }
        .formStyle(.grouped)
    }

    private func favoriteRow(_ slot: Int) -> some View {
        let current = settings.favoriteDeviceIDs[slot - 1]
        let online = app.devices.first { $0.id == current }
        return HStack(spacing: 10) {
            Text("Favorit \(slot)")
                .frame(width: 64, alignment: .leading)
            Picker("", selection: Binding(
                get: { current ?? "" },
                set: { id in
                    let device = app.devices.first { $0.id == id }
                    settings.setFavorite(id: id.isEmpty ? nil : id, name: device?.name, slot: slot)
                }
            )) {
                Text("–").tag("")
                ForEach(app.devices) { d in
                    Text(d.name).tag(d.id)
                }
                if let current, online == nil {
                    Text("\(settings.knownDeviceNames[current] ?? "Gerät") (offline)").tag(current)
                }
            }
            .labelsHidden()
            .frame(width: 180)
            Spacer()
            ShortcutRecorderView(action: .favorite(slot))
        }
    }

    private func setQuickAction(_ on: Bool) {
        do {
            if on { try QuickActionInstaller.install() } else { try QuickActionInstaller.uninstall() }
            integrationError = nil
        } catch {
            integrationError = error.localizedDescription
        }
        quickActionInstalled = QuickActionInstaller.isInstalled
    }

    private func setCLI(_ on: Bool) {
        do {
            if on { try CLIInstaller.install() } else { try CLIInstaller.uninstall() }
            integrationError = nil
        } catch {
            integrationError = error.localizedDescription
        }
        cliInstalled = CLIInstaller.isInstalled
    }
}
