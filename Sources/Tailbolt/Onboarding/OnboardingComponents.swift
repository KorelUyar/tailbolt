import AppKit
import SwiftUI
import TailboltCore

// MARK: - Tokens

enum OnboardingTokens {
    static let brand = [Color(red: 0.22, green: 0.74, blue: 0.98),   // same stops as the app icon
                        Color(red: 0.30, green: 0.36, blue: 0.96),
                        Color(red: 0.45, green: 0.22, blue: 0.88)]
    static let brandGradient = LinearGradient(colors: brand, startPoint: .topLeading, endPoint: .bottomTrailing)
    static let stageLight = [Color(red: 0.85, green: 0.88, blue: 0.95), Color(red: 0.95, green: 0.90, blue: 0.86)]
    static let stageDark = [Color(white: 0.16), Color(red: 0.10, green: 0.12, blue: 0.20)]
    static let keycapCorner: CGFloat = 6
    static let keycapHeight: CGFloat = 24
    static let windowWidth: CGFloat = 720
    static let windowHeight: CGFloat = 600
    static let footerHeight: CGFloat = 64
    static let textWidth: CGFloat = 480
}

// MARK: - Copy (Swiss German, informal)

enum OnboardingStrings {
    static let welcomeTitle = "Willkommen bei Tailbolt"
    static let welcomeBody = "AirDrop für dein ganzes Tailnet. Dateien und Ordner in jeder Grösse – an jedes Gerät, auch an die von anderen."
    static func welcomeStatusOK(_ tailnet: String, _ me: String) -> String { "Verbunden mit \(tailnet) als \(me)" }
    static let welcomeStatusStopped = "Tailscale läuft, aber nicht verbunden"
    static let welcomeStatusMissing = "Tailscale nicht gefunden"
    static let welcomeStatusChecking = "Suche Tailscale…"
    static let welcomeCTA = "Los geht's"

    static let tailscaleTitle = "Tailbolt braucht Tailscale"
    static let tailscaleBodyMissing = "Tailbolt schickt Dateien durch dein Tailnet – verschlüsselt und direkt. Installiere Tailscale, melde dich an, und Tailbolt findet deine Geräte von selbst."
    static let tailscaleBodyStopped = "Tailscale ist installiert, aber nicht verbunden. Öffne Tailscale und melde dich an – diese Seite aktualisiert sich automatisch."
    static let tailscaleDownload = "Tailscale laden"
    static let tailscaleOpen = "Tailscale öffnen"
    static let tailscaleNote = "Tailbolt funktioniert mit der Tailscale-App aus dem App Store und mit der Standalone-Version."
    static let tailscaleConnectedTitle = "Verbunden"
    static func tailscaleConnectedBody(_ me: String, _ tailnet: String) -> String { "Du bist als \(me) im Tailnet \(tailnet)." }

    static let sendTitle = "Schütteln. Ablegen. Weg."
    static let sendBody = "Zieh Dateien aus dem Finder und schüttle den Cursor kurz hin und her – das Shelf erscheint genau dort, wo du bist. Lass die Dateien auf ein Gerät fallen oder parkiere sie im Shelf, bis du so weit bist."
    static let sendNote = "Funktioniert in jeder App, nicht nur im Finder."
    static let sendTry = "Zum Ausprobieren: zieh mich und schüttle"
    static let sendTryDone = "Geschafft – das ist dein Shelf."
    static let sendTryHint = "Du kannst es schliessen, wir machen weiter."

    static let devicesTitle = "Alle Geräte im Tailnet. Nicht nur deine."
    static let devicesBody = "Tailbolt zeigt jedes Gerät in deinem Tailnet, auf dem Tailbolt läuft – auch die von Kolleginnen und Kollegen. Deine eigenen Geräte ohne Tailbolt, zum Beispiel dein iPhone, erreichst du über Taildrop."
    static let devicesInvite = "Einladungslink kopieren"
    static let devicesInviteDone = "Kopiert"
    static let devicesNote = "Tailbolt muss auf dem anderen Gerät laufen."
    static func devicesOnline(_ n: Int) -> String { n == 1 ? "1 Gerät mit Tailbolt gerade online" : "\(n) Geräte mit Tailbolt gerade online" }
    static let devicesOnlineNone = "Noch kein Gerät mit Tailbolt online – schick den Link weiter."
    static let calloutOther = ("Gerät einer anderen Person", "Avatar = Tailscale-Profilbild")
    static let calloutTaildrop = ("Eigenes Gerät ohne Tailbolt", "wird via Taildrop geschickt")
    static let calloutMine = ("Eigene Geräte sind grau", "Annahme automatisch")

    static let receiveTitle = "Empfangen, ohne nachzudenken."
    static let receiveBody = "Schickt dir jemand etwas, erscheint oben rechts eine Karte: Annehmen oder Ablehnen. Von deinen eigenen Geräten nimmt Tailbolt automatisch an. Alles landet in Downloads – Ordner bleiben Ordner, Datum und Rechte bleiben erhalten."
    static let receiveAutoAccept = "Von meinen eigenen Geräten automatisch annehmen"
    static let receiveSaveIn = "Speichern in"
    static let receiveChange = "Ändern…"
    static let receiveDemoBadge = "Automatisch angenommen"

    static let shortcutsTitle = "Immer einen Griff entfernt."
    static let shortcutsBody = "Shelf öffnen oder direkt senden – ein kleines HUD bestätigt."
    static let shortcutHotkey = "Shelf mit der Finder-Auswahl öffnen"
    static let shortcutClipboard = "Zwischenablage senden"
    static let shortcutLast = "An das letzte Gerät senden"
    static let shortcutFavorite = "An Favorit 1 bis 9 senden"
    static let shortcutShake = "Beim Ziehen den Cursor schütteln"
    static let shortcutShare = "Finder → Teilen → Tailbolt"
    static let shortcutsChangeable = "Kürzel und Favoriten änderbar in den Einstellungen."

    static let readyTitle = "Bereit zum Beamen."
    static let readyBody = "Tailbolt läuft jetzt in der Menüleiste. Zwei Dinge noch, dann bist du startklar."
    static let readyLogin = ("Beim Anmelden starten", "Damit du jederzeit empfangen kannst")
    static let readyQuickAction = ("Schnellaktion im Finder", "«Mit Tailbolt senden» im Rechtsklick-Menü")
    static let readyInstall = "Installieren"
    static let readyInstalled = "Installiert"
    static let readySoon = "Nach dem Start verfügbar"
    static let readyNote = "Alles später änderbar in den Einstellungen. Diese Einführung findest du dort jederzeit wieder."
    static func readyLiveCaption(_ n: Int, _ me: String) -> String { (n == 1 ? "1 Gerät bereit" : "\(n) Geräte bereit") + " · Du bist \(me)" }
    static let readyLiveNone = "Noch niemand online"

    static let navSkip = "Überspringen"
    static let navBack = "Zurück"
    static let navNext = "Weiter"
    static let navDone = "Fertig"
}

// MARK: - Easing helpers (pure functions of the demo clock)

enum Curve { case linear, easeIn, easeOut, easeInOut, spring }

/// Normalised progress of `t` through [a, b], shaped by `curve`. Outside the range it clamps to 0/1.
func prog(_ t: TimeInterval, _ a: TimeInterval, _ b: TimeInterval, _ curve: Curve = .easeInOut) -> Double {
    guard b > a else { return t >= a ? 1 : 0 }
    let x = min(1, max(0, (t - a) / (b - a)))
    switch curve {
    case .linear: return x
    case .easeIn: return x * x
    case .easeOut: return 1 - (1 - x) * (1 - x)
    case .easeInOut: return x < 0.5 ? 2 * x * x : 1 - pow(-2 * x + 2, 2) / 2
    case .spring:
        let s = 1.45
        let y = x - 1
        return 1 + y * y * ((s + 1) * y + s)
    }
}

/// `from` → `to` interpolation driven by `prog`.
func lerp(_ p: Double, _ from: Double, _ to: Double) -> Double { from + (to - from) * p }

/// 1 while t in [a, b), else 0 — with short fades at both ends.
func window(_ t: TimeInterval, _ a: TimeInterval, _ b: TimeInterval, fade: TimeInterval = 0.2) -> Double {
    if t < a || t >= b { return 0 }
    return min(prog(t, a, a + fade, .easeOut), 1 - prog(t, b - fade, b, .easeIn))
}

/// Single pulse 1→peak→1 over [a, a+d].
func pulse(_ t: TimeInterval, at a: TimeInterval, duration d: TimeInterval, peak: Double) -> Double {
    guard t >= a, t < a + d else { return 1 }
    let x = (t - a) / d
    return 1 + (peak - 1) * sin(x * .pi)
}

// MARK: - Small components

struct PageDots: View {
    let count: Int
    let current: Int
    var canJump: (Int) -> Bool = { _ in true }
    var onJump: (Int) -> Void = { _ in }

    var body: some View {
        HStack(spacing: 8) {
            ForEach(0..<count, id: \.self) { i in
                Button { onJump(i) } label: {
                    Group {
                        if i == current {
                            Capsule().fill(OnboardingTokens.brandGradient).frame(width: 18, height: 6)
                        } else {
                            Circle().fill(Color.primary.opacity(0.22)).frame(width: 6, height: 6)
                        }
                    }
                    .frame(height: 12)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(!canJump(i))
                .accessibilityLabel("Seite \(i + 1) von \(count)")
            }
        }
        .animation(.spring(response: 0.35, dampingFraction: 0.8), value: current)
    }
}

struct Keycap: View {
    let text: String
    var size: CGFloat = OnboardingTokens.keycapHeight
    var pressed = false
    @Environment(\.colorScheme) private var scheme
    @Environment(\.colorSchemeContrast) private var contrast

    private var corner: CGFloat { size >= 40 ? 12 : OnboardingTokens.keycapCorner }

    var body: some View {
        Text(text)
            .font(.system(size: size >= 40 ? 24 : 13, weight: .medium).monospacedDigit())
            .foregroundStyle(.primary)
            .lineLimit(1)
            .fixedSize()
            .padding(.horizontal, size >= 40 ? 0 : 7)
            .frame(minWidth: size, minHeight: size)
            .frame(width: size >= 40 ? size : nil, height: size)
            .background(
                RoundedRectangle(cornerRadius: corner, style: .continuous)
                    .fill(scheme == .dark ? Color.white.opacity(pressed ? 0.18 : 0.09) : Color.primary.opacity(pressed ? 0.12 : 0.06))
            )
            .overlay(
                RoundedRectangle(cornerRadius: corner, style: .continuous)
                    .strokeBorder(contrast == .increased ? AnyShapeStyle(Color.primary.opacity(0.4)) : AnyShapeStyle(.separator), lineWidth: 0.5)
            )
            .overlay(alignment: .top) {
                if scheme == .light {
                    RoundedRectangle(cornerRadius: corner, style: .continuous)
                        .strokeBorder(.white.opacity(0.6), lineWidth: 0.5)
                        .mask(Rectangle().frame(height: 4).frame(maxHeight: .infinity, alignment: .top))
                }
            }
            .shadow(color: .black.opacity(0.12), radius: pressed ? 0 : 0.5, y: pressed ? 0 : 1)
            .offset(y: pressed ? 1 : 0)
    }
}

/// Row of keycaps ("⌃ ⌥ ⌘ B"). Named `…View` because `KeyCombo` is the shortcut value type in Shortcuts.swift.
struct KeyComboView: View {
    let keys: [String]
    var size: CGFloat = OnboardingTokens.keycapHeight
    var spacing: CGFloat = 4
    var pressed: Set<Int> = []

    init(_ keys: [String], size: CGFloat = OnboardingTokens.keycapHeight, spacing: CGFloat = 4, pressed: Set<Int> = []) {
        self.keys = keys; self.size = size; self.spacing = spacing; self.pressed = pressed
    }

    var body: some View {
        HStack(spacing: spacing) {
            ForEach(Array(keys.enumerated()), id: \.offset) { i, k in
                Keycap(text: k, size: size, pressed: pressed.contains(i))
            }
        }
    }
}

/// Keycap-styled chip with a symbol, for non-keyboard triggers ("Schütteln", "Teilen").
struct Chip: View {
    let text: String
    var symbol: String?
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        HStack(spacing: 4) {
            if let symbol { Image(systemName: symbol).font(.system(size: 11, weight: .medium)) }
            Text(text).font(.system(size: 12, weight: .medium)).lineLimit(1)
        }
        .fixedSize()
        .foregroundStyle(.primary)
        .frame(height: OnboardingTokens.keycapHeight)
        .padding(.horizontal, 8)
        .background(RoundedRectangle(cornerRadius: 6, style: .continuous)
            .fill(scheme == .dark ? Color.white.opacity(0.09) : Color.primary.opacity(0.06)))
        .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous).strokeBorder(.separator, lineWidth: 0.5))
        .shadow(color: .black.opacity(0.12), radius: 0.5, y: 1)
    }
}

/// Circle with a white SF Symbol — the device glyphs of the radar/live stages.
struct DeviceGlyph: View {
    let symbol: String
    let colors: [Color]
    var size: CGFloat = 44

    var body: some View {
        Circle()
            .fill(LinearGradient(colors: colors, startPoint: .top, endPoint: .bottom))
            .overlay(Circle().strokeBorder(.white.opacity(0.18), lineWidth: 0.5))
            .overlay(Image(systemName: symbol)
                .font(.system(size: size * 0.41, weight: .regular))
                .foregroundStyle(.white)
                .shadow(color: .black.opacity(0.15), radius: 1, y: 1))
            .frame(width: size, height: size)
            .shadow(color: .black.opacity(0.18), radius: 4, y: 2)
    }
}

struct MockPointer: View {
    var dragging: AnyView? = nil

    var body: some View {
        ZStack(alignment: .topLeading) {
            if let dragging {
                dragging
                    .opacity(0.9)
                    .rotationEffect(.degrees(-3))
                    .offset(x: 16, y: 18)
            }
            Image(systemName: "cursorarrow")
                .font(.system(size: 22, weight: .medium))
                .symbolRenderingMode(.palette)
                .foregroundStyle(.white, .black)
                .shadow(color: .black.opacity(0.35), radius: 1.5, y: 1)
        }
        .frame(width: 24, height: 24, alignment: .topLeading)
    }
}

/// A 56 pt file "thumbnail" for drag demos — a film card for videos, a folder tile for folders,
/// else the real Finder icon.
struct DemoThumb: View {
    enum Kind { case video, folder, file(URL) }
    let kind: Kind
    var size: CGFloat = 56

    var body: some View {
        Group {
            switch kind {
            case .video:
                RoundedRectangle(cornerRadius: size * 0.16, style: .continuous)
                    .fill(LinearGradient(colors: [Color(white: 0.22), Color(white: 0.1)], startPoint: .top, endPoint: .bottom))
                    .overlay(Image(systemName: "film").font(.system(size: size * 0.46, weight: .regular)).foregroundStyle(.white.opacity(0.9)))
                    .overlay(RoundedRectangle(cornerRadius: size * 0.16, style: .continuous).strokeBorder(.white.opacity(0.15), lineWidth: 0.5))
            case .folder:
                Image(nsImage: NSWorkspace.shared.icon(for: .folder)).resizable().interpolation(.high)
            case .file(let url):
                Image(nsImage: NSWorkspace.shared.icon(forFile: url.path)).resizable().interpolation(.high)
            }
        }
        .frame(width: size, height: size)
        .shadow(color: .black.opacity(0.25), radius: 6, y: 4)
    }
}

struct MockFinder: View {
    struct Row { let icon: String; let name: String; let detail: String? }
    let rows: [Row]
    var selected: Int?
    var pressed = false
    var hideThumbOfSelected = false

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                HStack(spacing: 6) {
                    Circle().fill(Color(red: 1, green: 0.37, blue: 0.34))
                    Circle().fill(Color(red: 1, green: 0.74, blue: 0.18))
                    Circle().fill(Color(red: 0.15, green: 0.78, blue: 0.25))
                }
                .frame(width: 42, height: 10)
                Spacer()
                HStack(spacing: 5) {
                    Image(systemName: "folder.fill").font(.system(size: 11)).foregroundStyle(Color.accentColor)
                    Text("Downloads").font(.system(size: 12, weight: .medium))
                }
                Spacer()
                Color.clear.frame(width: 42, height: 10)
            }
            .padding(.horizontal, 12)
            .frame(height: 36)
            Divider().opacity(0.6)
            VStack(spacing: 0) {
                ForEach(Array(rows.enumerated()), id: \.offset) { i, row in
                    HStack(spacing: 8) {
                        Image(systemName: row.icon)
                            .font(.system(size: 13))
                            .foregroundStyle(i == selected ? Color.accentColor : Color.secondary)
                            .frame(width: 18)
                            .opacity(hideThumbOfSelected && i == selected ? 0.35 : 1)
                        Text(row.name).font(.system(size: 12)).lineLimit(1)
                        Spacer()
                        if let d = row.detail { Text(d).font(.system(size: 11)).foregroundStyle(.secondary) }
                    }
                    .padding(.horizontal, 10)
                    .frame(height: 26)
                    .background(
                        RoundedRectangle(cornerRadius: 5, style: .continuous)
                            .fill(i == selected ? Color.accentColor.opacity(pressed ? 0.3 : 0.18) : .clear)
                            .padding(.horizontal, 6)
                    )
                }
                Spacer(minLength: 0)
            }
            .padding(.top, 6)
        }
        .frame(width: 300, height: 220)
        .background(.regularMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(.separator, lineWidth: 0.5))
        .shadow(color: .black.opacity(0.18), radius: 14, y: 8)
    }
}

/// The fake menu bar across the top of a stage, with Tailbolt's status item and a clock.
struct MenuBarStrip: View {
    var active = false
    var highlighted = false
    var iconX: CGFloat = 620
    var width: CGFloat = OnboardingTokens.windowWidth

    var body: some View {
        ZStack(alignment: .topLeading) {
            Rectangle().fill(.bar)
            Rectangle().fill(Color.primary.opacity(0.08)).frame(height: 0.5).offset(y: 23.5)
            HStack(spacing: 12) {
                Image(systemName: "wifi").font(.system(size: 13, weight: .medium))
                Image(systemName: "battery.75percent").font(.system(size: 13))
                Text("14:32").font(.system(size: 12, weight: .medium)).monospacedDigit()
            }
            .foregroundStyle(.primary.opacity(0.85))
            .frame(height: 24)
            .position(x: width - 70, y: 12)
            Image(systemName: active ? "arrow.up.arrow.down.circle.fill" : "dot.radiowaves.up.forward")
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(.primary.opacity(0.9))
                .frame(width: 26, height: 22)
                .background(RoundedRectangle(cornerRadius: 5, style: .continuous).fill(highlighted ? Color.primary.opacity(0.14) : .clear))
                .position(x: iconX, y: 12)
        }
        .frame(width: width, height: 24)
    }
}

/// Connection pill under the welcome body.
struct StatusPill: View {
    let color: Color
    let text: String

    var body: some View {
        HStack(spacing: 6) {
            Circle().fill(color).frame(width: 6, height: 6)
            Text(text).font(.system(size: 11, weight: .medium)).lineLimit(1)
        }
        .foregroundStyle(.primary)
        .padding(.horizontal, 10)
        .frame(height: 24)
        .background(Capsule().fill(.quaternary))
        .animation(.easeInOut(duration: 0.2), value: text)
    }
}

/// What's-New style row: tinted symbol, title, optional subtitle, trailing control.
struct SetupRow<Trailing: View>: View {
    let symbol: String
    let title: String
    var subtitle: String?
    @ViewBuilder var trailing: () -> Trailing

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: symbol)
                .font(.system(size: 20, weight: .medium))
                .foregroundStyle(OnboardingTokens.brandGradient)
                .frame(width: 30)
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(.system(size: 13, weight: .semibold)).lineLimit(1)
                if let subtitle { Text(subtitle).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1) }
            }
            Spacer(minLength: 8)
            trailing()
        }
        .padding(.horizontal, 14)
        .frame(height: 44)
    }
}

// MARK: - Demo replicas of the live surfaces
// Pure, value-driven copies of ShelfView / DeviceBubble / IncomingCard (same metrics and materials)
// so beat timelines can set every state explicitly — including ones the real views keep private.

struct DemoBubble: View {
    enum Status: Equatable { case idle, waiting, progress(Double), sent }
    let device: Device
    var targeted = false
    var status: Status = .idle
    var checkVisible = true
    var dim = false
    private let size: CGFloat = 58

    static let width: CGFloat = 84
    static let height: CGFloat = 72 + 5 + 13 + 5 + 12

    var body: some View {
        VStack(spacing: 5) {
            ZStack {
                DeviceAvatar(device: device, size: size)
                    .scaleEffect(targeted ? 1.12 : 1)
                switch status {
                case .waiting:
                    ProgressRing(fraction: 0, indeterminate: true).frame(width: size + 9, height: size + 9)
                case .progress(let f):
                    Circle().stroke(Color.primary.opacity(0.12), lineWidth: 3.5).frame(width: size + 9, height: size + 9)
                    Circle().trim(from: 0, to: max(0.02, f))
                        .stroke(Color.accentColor, style: StrokeStyle(lineWidth: 3.5, lineCap: .round))
                        .rotationEffect(.degrees(-90))
                        .frame(width: size + 9, height: size + 9)
                case .sent where checkVisible:
                    Image(systemName: "checkmark.circle.fill")
                        .symbolRenderingMode(.palette)
                        .foregroundStyle(.white, .green)
                        .font(.system(size: 22))
                        .background(Circle().fill(.white).padding(3))
                        .offset(x: size / 2 - 6, y: -size / 2 + 6)
                default: EmptyView()
                }
                if targeted {
                    Circle().strokeBorder(Color.accentColor, lineWidth: 3).frame(width: size + 12, height: size + 12)
                }
            }
            .frame(width: size + 14, height: size + 14)
            Text(device.name)
                .font(.system(size: 11, weight: .medium))
                .lineLimit(1)
                .frame(width: Self.width)
            Text(subtitle)
                .font(.system(size: 10))
                .foregroundStyle(subtitleColor)
                .lineLimit(1)
                .frame(width: Self.width)
        }
        .opacity(dim ? 0.6 : 1)
        .animation(.spring(response: 0.28, dampingFraction: 0.7), value: targeted)
    }

    private var subtitle: String {
        switch status {
        case .waiting: return "Warten…"
        case .progress(let f): return "\(Int((f * 100).rounded())) %"
        case .sent: return "Gesendet"
        case .idle:
            if device.viaTaildrop { return "Taildrop" }
            return device.ownerName ?? (device.peer.isMine ? "Mein Gerät" : "")
        }
    }

    private var subtitleColor: Color {
        switch status {
        case .waiting, .progress: return .accentColor
        default: return .secondary
        }
    }
}

struct DemoShelf: View {
    let devices: [Device]
    var files: [URL] = []
    var summary: String?
    var stackTargeted = false
    var targetedIndex: Int?
    var statuses: [DemoBubble.Status] = []

    static let size = CGSize(width: 320, height: 318)
    static let headerHeight: CGFloat = 28
    static let stackHeight: CGFloat = 140
    static let devicesTop: CGFloat = 28 + 140 + 1 + 10

    /// Centre of avatar `i` in shelf coordinates (unscaled).
    static func avatarCenter(_ i: Int, of count: Int) -> CGPoint {
        let total = CGFloat(count) * DemoBubble.width + CGFloat(count - 1) * 2
        let x = (size.width - total) / 2 + CGFloat(i) * (DemoBubble.width + 2) + DemoBubble.width / 2
        return CGPoint(x: x, y: devicesTop + 36)
    }

    /// Centre of the stack / drop zone.
    static var stackCenter: CGPoint { CGPoint(x: size.width / 2, y: headerHeight + stackHeight / 2) }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Image(systemName: "xmark").font(.system(size: 9, weight: .bold)).foregroundStyle(.secondary)
                    .frame(width: 18, height: 18).background(Circle().fill(.quaternary))
                Spacer()
                Text("Tailbolt").font(.system(size: 12, weight: .semibold)).foregroundStyle(.secondary)
                Spacer()
                Image(systemName: "ellipsis").font(.system(size: 10, weight: .bold)).foregroundStyle(.secondary)
                    .frame(width: 18, height: 18).background(Circle().fill(.quaternary))
            }
            .padding(.horizontal, 12)
            .padding(.top, 10)
            stack.frame(height: Self.stackHeight)
            Divider().opacity(0.6).padding(.horizontal, 14)
            HStack(alignment: .top, spacing: 2) {
                ForEach(Array(devices.enumerated()), id: \.element.id) { i, d in
                    DemoBubble(device: d, targeted: targetedIndex == i, status: i < statuses.count ? statuses[i] : .idle)
                }
            }
            .padding(.top, 10)
            .frame(maxWidth: .infinity)
            .frame(height: 128, alignment: .top)
        }
        .frame(width: Self.size.width, height: Self.size.height)
        .background(VisualEffect(material: .popover))
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).strokeBorder(.white.opacity(0.12), lineWidth: 0.5))
        .shadow(color: .black.opacity(0.28), radius: 18, y: 10)
    }

    @ViewBuilder
    private var stack: some View {
        if files.isEmpty {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(style: StrokeStyle(lineWidth: 1.5, dash: [6, 5]))
                .foregroundStyle(stackTargeted ? Color.accentColor : Color.secondary.opacity(0.4))
                .background(RoundedRectangle(cornerRadius: 14).fill(stackTargeted ? Color.accentColor.opacity(0.08) : .clear))
                .overlay(
                    VStack(spacing: 6) {
                        Image(systemName: "tray.and.arrow.down").font(.system(size: 26, weight: .light))
                        Text("Dateien hier ablegen").font(.system(size: 12, weight: .medium))
                        Text("oder direkt auf ein Gerät ziehen").font(.system(size: 10)).foregroundStyle(.tertiary)
                    }
                    .foregroundStyle(stackTargeted ? Color.accentColor : .secondary)
                )
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
        } else {
            VStack(spacing: 6) {
                ZStack {
                    ForEach(Array(files.prefix(3).enumerated().reversed()), id: \.element) { i, url in
                        FileThumb(url: url, size: 78)
                            .rotationEffect(.degrees(files.count == 1 ? 0 : Double(i) * 7 - 4))
                            .offset(x: CGFloat(i) * 9, y: CGFloat(i) * -2)
                    }
                }
                .frame(height: 92)
                Text(summary ?? "")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .padding(.horizontal, 20)
            }
        }
    }
}

struct DemoIncomingCard: View {
    enum Mode: Equatable { case decision(pressed: Bool), progress(Double, String), finished(isFolder: Bool) }
    let peerName: String
    let peerSymbol: String
    let what: String
    let size: String
    var mode: Mode
    var mine = false
    var badge: String?

    static let width: CGFloat = 352

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: peerSymbol)
                    .font(.system(size: 20))
                    .foregroundStyle(.white)
                    .frame(width: 42, height: 42)
                    .background(Circle().fill(LinearGradient(colors: mine ? Palette.mine : Palette.gradients[0], startPoint: .top, endPoint: .bottom)))
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(peerName).font(.system(size: 13, weight: .semibold)).lineLimit(1)
                        if let badge {
                            Text(badge).font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(1)
                        }
                    }
                    Text(headline).font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(2)
                }
                Spacer(minLength: 0)
            }
            switch mode {
            case .decision(let pressed):
                HStack(spacing: 8) {
                    Text("Ablehnen").frame(maxWidth: .infinity).modifier(DemoPanelButton())
                    Text("Annehmen").frame(maxWidth: .infinity).modifier(DemoPanelButton(prominent: true, pressed: pressed))
                }
            case .progress(let f, let status):
                VStack(alignment: .leading, spacing: 5) {
                    Bar(value: f)
                    HStack {
                        Text(status).font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(1)
                        Spacer()
                        Text("Abbrechen").font(.system(size: 10)).foregroundStyle(Color.accentColor)
                    }
                }
            case .finished(let isFolder):
                HStack(spacing: 8) {
                    Label("Im Finder zeigen", systemImage: "folder").frame(maxWidth: .infinity).modifier(DemoPanelButton())
                    if !isFolder {
                        Label("Öffnen", systemImage: "arrow.up.forward.app").frame(maxWidth: .infinity).modifier(DemoPanelButton())
                    }
                }
            }
        }
        .padding(14)
        .frame(width: Self.width, alignment: .leading)
        .background(VisualEffect(material: .hudWindow))
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(.white.opacity(0.14), lineWidth: 0.5))
        .shadow(color: .black.opacity(0.22), radius: 8, y: 3)
    }

    private var headline: String {
        switch mode {
        case .decision: return "möchte «\(what)» senden · \(size)"
        case .progress: return "sendet «\(what)»"
        case .finished: return "«\(what)» gespeichert in Downloads"
        }
    }
}

/// Same look as `PanelButtonStyle`, for static (non-interactive) demo buttons.
struct DemoPanelButton: ViewModifier {
    var prominent = false
    var pressed = false

    func body(content: Content) -> some View {
        content
            .font(.system(size: 12, weight: prominent ? .semibold : .regular))
            .foregroundStyle(prominent ? Color.white : Color.primary)
            .padding(.vertical, 6)
            .padding(.horizontal, 10)
            .background(RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(prominent ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(Color.primary.opacity(0.09))))
            .opacity(pressed ? 0.75 : 1)
    }
}

/// Drag source for the try-it card: hands the file to any drop target (also inside Tailbolt).
struct DemoDragSource: NSViewRepresentable {
    let url: URL

    func makeNSView(context: Context) -> DragView { DragView() }
    func updateNSView(_ v: DragView, context: Context) { v.url = url }

    final class DragView: NSView, NSDraggingSource {
        var url: URL?
        private var downEvent: NSEvent?

        override func mouseDown(with event: NSEvent) { downEvent = event }

        override func mouseDragged(with event: NSEvent) {
            guard let down = downEvent, let url else { return }
            let d = hypot(event.locationInWindow.x - down.locationInWindow.x, event.locationInWindow.y - down.locationInWindow.y)
            guard d > 3 else { return }
            downEvent = nil
            let local = convert(event.locationInWindow, from: nil)
            let item = NSDraggingItem(pasteboardWriter: url as NSURL)
            item.setDraggingFrame(NSRect(x: local.x - 32, y: local.y - 32, width: 64, height: 64),
                                  contents: NSWorkspace.shared.icon(forFile: url.path))
            beginDraggingSession(with: [item], event: event, source: self)
        }

        override func mouseUp(with event: NSEvent) { downEvent = nil }

        func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
            [.copy, .generic]
        }

        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    }
}
