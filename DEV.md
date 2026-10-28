# Tailbolt — developer notes

## Build / run / test (no Xcode needed)

```sh
scripts/build-app.sh              # universal (arm64 + x86_64) release build → dist/Tailbolt.app + dist/Tailbolt.zip
                                  # TAILBOLT_ARCHS=arm64 for a quicker single-arch build
scripts/build-app.sh --install    # + copy to /Applications and relaunch
SDKROOT=/Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk swift build -c release   # just compile
.build/release/tailbolt-cli peers | send <host[:port]> <paths…> | serve [--port N] [--dir D]
dist/Tailbolt.app/Contents/MacOS/Tailbolt --snapshot <dir> [files…]   # renders UI surfaces + onboarding pages to PNGs (light+dark)
# TAILBOLT_DEMO=1 in front swaps the real tailnet for example devices – use it for anything published (docs/screenshots).
.build/release/Tailbolt --onboarding-preview [dir]   # just the setup assistant (no server/hotkeys); with <dir>: walks all pages by key, PNG each
.build/release/Tailbolt --onboarding | --no-onboarding   # force / suppress the first-run assistant
```

- Always build with the **26.5 SDK** (`SDKROOT`); the 27 SDK needs Xcode's SwiftUI macro plugin.
- End-to-end test on one machine: `tailbolt-cli serve --port 48500 --dir /tmp/recv &` then
  `tailbolt-cli send 127.0.0.1:48500 <files>`; compare with `diff -r` / `cmp`.
  The running app on this Mac can be targeted via its tailscale IP (`tailbolt-cli send <own-tailscale-ip> …`).
- The Tailscale CLI (`/Applications/Tailscale.app/Contents/MacOS/Tailscale`) must be run with
  `TAILSCALE_BE_CLI=1` (see `Tailnet.cliProcess`) or it tries to launch the GUI.

## Layout

| Target | Files | Role |
|---|---|---|
| `TailboltCore` (library, platform-neutral: Foundation + POSIX) | `Socket.swift` TCP wrappers, listener, tailnet-address check · `Wire.swift` framing, messages, chunk plan, probe · `Manifest.swift` source tree walk · `Transfer.swift` shared state/progress · `Sender.swift` `OutgoingTransfer` · `Receiver.swift` `TailboltServer`, `IncomingTransfer` · `Tailnet.swift` `tailscale status` parsing, Taildrop fallback | engine, reusable for Linux/Windows/iOS |
| `Tailbolt` (app) | `main.swift` AppDelegate, trigger wiring (`applyTriggers`), URL scheme, `open` handler · `AppModel.swift` discovery, device list, `TransferItem` view-models (speed/ETA, LAN/LZ4 stats, hints), `send`/`sendDirect`/accept, `lastPayload` + `resendLast`, always-accept · `Settings.swift` UserDefaults-backed `@Observable` (shortcuts JSON, favorites, last device, HUD, sounds/haptics, `ShakeSensitivity`, hold-⇧, LAN-Turbo, LZ4, auto-accept favorites, `alwaysAcceptPeerIDs`) · `Shortcuts.swift` `KeyCombo` (glyphs, Carbon conversion, validity), `ShortcutAction` (defaults), `HotKeyCenter` (Carbon global hotkeys, re-registers on settings change, recorder session, dispatch), `ClipboardPackager` (concealed check, export + release) · `Toast.swift` HUD capsule (`ToastController`, `ToastView`) for the zero-UI sends · `Integrations.swift` `QuickActionInstaller` (Automator workflow bundle in ~/Library/Services), `CLIInstaller` (/usr/local/bin/tailbolt) · `ShortcutsSettings.swift` `ShortcutRecorderView`, `ShortcutsSettingsView` · `Shelf.swift` Dropover-style floating shelf (`ShelfController`, `ShelfView`: radar empty state, hover file list, fly-in/finish/decline beats, ⌘-click multi-recipient, drag-out, keyboard navigation 1–9/←→/↩/⎋/⌘A/⌘O/⌘⌫) · `MenuBar.swift` `MenuActions` hook, status item (progress arc, drag halo, drop target, ⌘-click → Info tab), popover `MenuView` (Zuletzt row, Meine Geräte/Andere, Aktiv/Verlauf), `TransferRow`, `TransferCapsules` · `IncomingPanel.swift` top-right cards (⏎/⌘⏎/⌥⏎/⎋ while key, never activating), `ReceivedThumbController` screenshot-style thumbnails bottom-right · `Components.swift` `GlassSurface` (Liquid Glass / material), `Motion` (Reduce Motion), `Haptics`, `Sounds`, `Feedback`, avatars, `ProgressRing`, `PathCapsule`/`PathBadge`, `DeviceBubble` (stats subtitle, spring-loaded send, favorite menu, keycaps), `Thumbnails`/`FileThumb`, `Bar`, `PanelButtonStyle`, `FileDrop` · `Triggers.swift` `DragState` (system-wide file-drag state, hold-⇧ trigger), `ShakeDetector`, Finder selection, Services provider · `SettingsWindow.swift` native preference window (toolbar tabs Allgemein / Senden / Empfangen / Shortcuts / Info, height follows the pane), `SettingsActions`/`SettingsPreview` hooks, `SettingsFooter`/`SettingsRowLabel` · `About.swift` `AppIconImage`/`AppIconView`, `BenchModel` (speed test), `AboutView` (Info tab) · `Snapshot.swift` dev renderer (2x PNGs: shelf + empty/keys/beats/turbo/relay/list, menu, incoming, received, toast, settings-*) | macOS UI |
| `tailbolt-cli` | `main.swift` | headless peers/send/serve |
| `ShareExtension/` | compiled by the build script into `PlugIns/TailboltShare.appex`; forwards to `tailbolt://send?path=…` | Finder "Teilen" |
| `Resources/Info.plist`, `scripts/make-icon.swift` | bundle metadata, icon renderer | |

## Conventions

- UI copy: **English in the source** (the base language and the default, whatever the system language), curly
  quotes “…”. German lives in `Resources/de.lproj/Localizable.strings`, keyed by the English string: Swiss spelling
  ("ss", never "ß"), informal "du", guillemets «…». Every new user-visible string needs a German line there.
  - Literals in `Text`/`Button`/`Toggle`/`Label`/`Section`/`.help` are looked up automatically; everything else that
    reaches the screen goes through `String(localized: "…")` (custom views with `String` parameters, menu items,
    toasts, errors, ternaries). Interpolations become printf specifiers in the key: `String` → `%@`, `Int` → `%lld`,
    `Double` → `%lf`; a literal `%` next to them is `%%`.
  - Check German with `Tailbolt -AppleLanguages '(de)' -NSShowNonLocalizedStrings YES --snapshot <dir>`:
    any key missing from the table renders in CAPITALS.
  - The language choice (Settings → General) is `AppLanguage` in `Language.swift`; it writes the app's
    `AppleLanguages` at launch, and switching asks for a restart. The Finder Quick Action is named after the
    language too ("Send with Tailbolt" / "Mit Tailbolt senden"), the Services menu via `ServicesMenu.strings`.
- Code, comments, commits: English.
- UI state lives in `@MainActor @Observable` classes; engine callbacks (`onStateChange`) arrive on background
  threads → hop with `DispatchQueue.main.async`.
- Panels are `NSPanel` subclasses with `.nonactivatingPanel` so they never steal focus from the app you're in;
  use `PanelButtonStyle`/`Bar` instead of system buttons/progress inside them (system controls go gray when not key).
  The shelf becomes key via `panel.makeKey()` (never `NSApp.activate`) when opened by hotkey/menu so digits and
  arrows work; local `NSEvent` monitors only act while `panel.isKeyWindow`. The HUD panel can never become key.
  The incoming panel takes the keyboard once per new offer (never again from its timer – one stray keystroke hands
  it back for good) and never while another Tailbolt window is key.
- Global hotkeys are Carbon `RegisterEventHotKey` (no Accessibility prompt). `HotKeyCenter` watches
  `Settings.shortcuts` via `withObservationTracking` and re-registers. It also owns the recorder session
  (`beginRecording` / `cancelRecording`, `isPaused` is derived from it): the local monitor swallows every key,
  so `SettingsWindow` cancels on `willCloseNotification` and the app on quit – SwiftUI's `onDisappear` never
  fires for a retained window that is only ordered out.
- Local key monitors ignore `event.isARepeat`; a held ↩ would otherwise start one transfer per auto-repeat.
- Direct send never ships clipboard content without a look: `ClipboardPackager` refuses concealed pasteboards
  (`org.nspasteboard.*`), clipboard payloads go through the shelf (armed on the target, ↩ sends), and exports are
  deleted via `ClipboardPackager.release` once no shelf holds them and no transfer (`TransferItem.sourceURLs`)
  reads them. `FinderSelection.current()` returns nil when Finder cannot be asked (Automation denied) – do not
  fall through to the clipboard in that case.
- Snapshot (`--snapshot`) must not change user state: it restores the favorites / always-accept list it sets for the
  demo. It is scheduled with a `Timer`, never `DispatchQueue.main`: it spins nested run loops and the main dispatch
  queue is not re-entrant (thumbnails and `AsyncImage` would starve). PNGs are 2x; `Thumbnails` delivers results
  via `RunLoop.main.perform` for the same reason.
- Hooks for features that live elsewhere: `SettingsActions.openOnboarding` (= `MenuActions.openOnboarding`; nil
  disables "Einführung erneut anzeigen", the popover/menu fall back to the settings), `SettingsActions.readmeURL`
  (nil hides the link). Einstellungen → Senden drive the engine via `AppModel`: LAN-Turbo →
  `TailboltServer.lanFastPathEnabled` + `peerLANHint`, LZ4 → `OutgoingTransfer.compressionEnabled` +
  `TailboltServer.compressionEnabled` (synced on every tick).
- Feedback beats (`Feedback.transferFinished`: Tink + haptic) fire once per transfer id, so every surface may call it.
- `AppModel.visibleSurfaces` counts open UI surfaces → faster discovery polling while something is visible.
- Keep the wire protocol documented in `PROTOCOL.md`; bump `Tailbolt.protocolVersion` on incompatible changes.
