import AppKit
import Carbon.HIToolbox
import SwiftUI

/// System-Settings-style shortcut field: click → "Press keys…", press a combo, done. ⎋ cancels,
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
                .help("Remove keyboard shortcut")
                .opacity(combo != nil && !recording ? 1 : 0)
                .disabled(combo == nil || recording)
            }
            if let message {
                Text(message)
                    .font(.system(size: 10))
                    .foregroundStyle(.red)
                    .transition(.opacity)
            } else if hotKeys.failed.contains(action) {
                Text("Not allowed by the system")
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
            .help(recording ? String(localized: "Press keys – ⎋ cancels") : String(localized: "Click to record a keyboard shortcut"))
            .animation(.easeOut(duration: 0.12), value: recording)
    }

    private var label: String {
        if recording { return held.isEmpty ? String(localized: "Press keys…") : KeyCombo.symbols(for: held) }
        return combo?.display ?? String(localized: "Record")
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
                Toggle("Enable global keyboard shortcuts", isOn: $settings.hotKeyEnabled)
                Toggle("Show a brief overlay when sending directly", isOn: $settings.hudEnabled)
            } header: {
                Text("Keyboard shortcuts")
            } footer: {
                SettingsFooter(String(localized: "Sending directly takes the files in the open shelf, otherwise the Finder selection. The clipboard (files, images, text) goes to the shelf first – ↩ sends it. Content marked as confidential (password managers) is never sent."))
            }

            Section("Actions") {
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
                Text("Favorites")
            } footer: {
                SettingsFooter(String(localized: "Right-clicking a device in the shelf or menu also sets a favorite. In the shelf, the number keys 1–9 send to the nth device."))
            }

            Section {
                Toggle(isOn: Binding(get: { quickActionInstalled }, set: { setQuickAction($0) })) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Quick Action in Finder")
                        Text("Right-click files → Quick Actions → “Send with Tailbolt”")
                            .font(.system(size: 11)).foregroundStyle(.secondary)
                    }
                }
                Toggle(isOn: Binding(get: { cliInstalled }, set: { setCLI($0) })) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("“tailbolt” command in Terminal")
                        Text("Links /usr/local/bin/tailbolt to the app (may ask for the admin password)")
                            .font(.system(size: 11)).foregroundStyle(.secondary)
                    }
                }
                if let integrationError {
                    Label(integrationError, systemImage: "exclamationmark.triangle")
                        .font(.system(size: 11)).foregroundStyle(.red)
                }
            } header: {
                Text("Integrations")
            }

            // Gestures (shake, hold ⇧) live in Einstellungen → Senden.

            Section {
                HStack {
                    Spacer()
                    Button("Reset Keyboard Shortcuts") { settings.resetShortcuts() }
                        .help("Reset all keyboard shortcuts to ⌃⌥⌘B, ⌃⌥⌘V, ⌃⌥⌘L and ⌃⌥⌘1 … 9")
                }
            }
        }
        .formStyle(.grouped)
    }

    private func favoriteRow(_ slot: Int) -> some View {
        let current = settings.favoriteDeviceIDs[slot - 1]
        let online = app.devices.first { $0.id == current }
        return HStack(spacing: 10) {
            Text("Favorite \(slot)")
                .frame(width: 72, alignment: .leading)
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
                    Text("\(settings.knownDeviceNames[current] ?? String(localized: "Device")) (offline)").tag(current)
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
