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

// MARK: - Copy (English source; German lives in de.lproj/Localizable.strings)

enum OnboardingStrings {
    static let welcomeTitle = String(localized: "Welcome to Tailbolt")
    static let welcomeBody = String(localized: "AirDrop for your whole tailnet. Files and folders of any size – to any device, including other people’s.")
    static func welcomeStatusOK(_ tailnet: String, _ me: String) -> String { String(localized: "Connected to \(tailnet) as \(me)") }
    static let welcomeStatusStopped = String(localized: "Tailscale is running but not connected")
    static let welcomeStatusMissing = String(localized: "Tailscale not found")
    static let welcomeStatusChecking = String(localized: "Looking for Tailscale…")
    static let welcomeCTA = String(localized: "Get Started")

    static let tailscaleTitle = String(localized: "Tailbolt needs Tailscale")
    static let tailscaleBodyMissing = String(localized: "Tailbolt sends files through your tailnet – encrypted and direct. Install Tailscale, sign in, and Tailbolt finds your devices on its own.")
    static let tailscaleBodyStopped = String(localized: "Tailscale is installed but not connected. Open Tailscale and sign in – this page updates automatically.")
    static let tailscaleDownload = String(localized: "Download Tailscale")
    static let tailscaleOpen = String(localized: "Open Tailscale")
    static let tailscaleNote = String(localized: "Tailbolt works with both the App Store version of Tailscale and the standalone version.")
    static let tailscaleConnectedTitle = String(localized: "Connected")
    static func tailscaleConnectedBody(_ me: String, _ tailnet: String) -> String { String(localized: "You’re signed in as \(me) on the \(tailnet) tailnet.") }

    static let sendTitle = String(localized: "Shake. Drop. Done.")
    static let sendBody = String(localized: "Drag files out of the Finder and give the pointer a quick shake – the Shelf appears right where you are. Drop the files on a device, or park them on the Shelf until you’re ready.")
    static let sendNote = String(localized: "Works in any app, not just the Finder.")
    static let sendTry = String(localized: "Try it: drag me and shake")
    static let sendTryDone = String(localized: "Nice – that’s your Shelf.")
    static let sendTryHint = String(localized: "You can close it now. Let’s keep going.")

    static let devicesTitle = String(localized: "Every device in your tailnet. Not just yours.")
    static let devicesBody = String(localized: "Tailbolt shows every device in your tailnet that’s running Tailbolt – including your colleagues’. Your own devices without Tailbolt, like your iPhone, are reached via Taildrop.")
    static let devicesInvite = String(localized: "Copy Invite Link")
    static let devicesInviteDone = String(localized: "Copied")
    static let devicesNote = String(localized: "Tailbolt needs to be running on the other device.")
    static func devicesOnline(_ n: Int) -> String {
        n == 1 ? String(localized: "1 device with Tailbolt online now") : String(localized: "\(n) devices with Tailbolt online now")
    }
    static let devicesOnlineNone = String(localized: "No devices with Tailbolt online yet – pass the link on.")
    static let calloutOther = (String(localized: "Someone else’s device"), String(localized: "Avatar = Tailscale profile picture"))
    static let calloutTaildrop = (String(localized: "Your device without Tailbolt"), String(localized: "sent via Taildrop"))
    static let calloutMine = (String(localized: "Your own devices are gray"), String(localized: "accepted automatically"))

    static let receiveTitle = String(localized: "Receive without a second thought.")
    static let receiveBody = String(localized: "When someone sends you something, a card appears in the top-right corner: Accept or Decline. Tailbolt accepts automatically from your own devices. Everything lands in Downloads – folders stay folders, dates and permissions are preserved.")
    static let receiveAutoAccept = String(localized: "Accept automatically from my own devices")
    static let receiveSaveIn = String(localized: "Save to")
    static let receiveChange = String(localized: "Change…")
    static let receiveDemoBadge = String(localized: "Accepted automatically")

    static let shortcutsTitle = String(localized: "Always within reach.")
    static let shortcutsBody = String(localized: "Open the Shelf or send right away – a small HUD confirms.")
    static let shortcutHotkey = String(localized: "Open the Shelf with the Finder selection")
    static let shortcutClipboard = String(localized: "Send the clipboard")
    static let shortcutLast = String(localized: "Send to the last device")
    static let shortcutFavorite = String(localized: "Send to favorite 1 to 9")
    static let shortcutShake = String(localized: "Shake the pointer while dragging")
    static let shortcutShare = String(localized: "Finder → Share → Tailbolt")
    static let shortcutsChangeable = String(localized: "Change shortcuts and favorites anytime in Settings.")

    static let readyTitle = String(localized: "Ready to bolt.")
    static let readyBody = String(localized: "Tailbolt now lives in the menu bar. Two more things and you’re good to go.")
    static let readyLogin = (String(localized: "Launch at login"), String(localized: "So you can receive files anytime"))
    static let readyQuickAction = (String(localized: "Quick Action in the Finder"), String(localized: "“Send with Tailbolt” in the right-click menu"))
    static let readyInstall = String(localized: "Install")
    static let readyInstalled = String(localized: "Installed")
    static let readySoon = String(localized: "Available after launch")
    static let readyNote = String(localized: "You can change all of this later in Settings – that’s also where you’ll find this tour again.")
    static func readyLiveCaption(_ n: Int, _ me: String) -> String {
        (n == 1 ? String(localized: "1 device ready") : String(localized: "\(n) devices ready")) + " · " + String(localized: "You’re \(me)")
    }
    static let readyLiveNone = String(localized: "No one online yet")

    static let navSkip = String(localized: "Skip")
    static let navBack = String(localized: "Back")
    static let navNext = String(localized: "Continue")
    static let navDone = String(localized: "Done")
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
                .accessibilityLabel("Page \(i + 1) of \(count)")
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

/// Keycap-styled chip with a symbol, for non-keyboard triggers ("Shake", "Share"). `text` must already be localized.
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
                    Text(verbatim: "Downloads").font(.system(size: 12, weight: .medium))
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
                Text(verbatim: "14:32").font(.system(size: 12, weight: .medium)).monospacedDigit()
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
        case .waiting: return String(localized: "Waiting…")
        case .progress(let f): return "\(Int((f * 100).rounded())) %"
        case .sent: return String(localized: "Sent")
        case .idle:
            if device.viaTaildrop { return "Taildrop" }
            return device.ownerName ?? (device.peer.isMine ? String(localized: "My device") : "")
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
                        Text("Drop files here").font(.system(size: 12, weight: .medium))
                        Text("or drag them straight onto a device").font(.system(size: 10)).foregroundStyle(.tertiary)
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
                    Text("Decline").frame(maxWidth: .infinity).modifier(DemoPanelButton())
                    Text("Accept").frame(maxWidth: .infinity).modifier(DemoPanelButton(prominent: true, pressed: pressed))
                }
            case .progress(let f, let status):
                VStack(alignment: .leading, spacing: 5) {
                    Bar(value: f)
                    HStack {
                        Text(status).font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(1)
                        Spacer()
                        Text("Cancel").font(.system(size: 10)).foregroundStyle(Color.accentColor)
                    }
                }
            case .finished(let isFolder):
                HStack(spacing: 8) {
                    Label("Show in Finder", systemImage: "folder").frame(maxWidth: .infinity).modifier(DemoPanelButton())
                    if !isFolder {
                        Label("Open", systemImage: "arrow.up.forward.app").frame(maxWidth: .infinity).modifier(DemoPanelButton())
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
        case .decision: return String(localized: "wants to send “\(what)” · \(size)")
        case .progress: return String(localized: "is sending “\(what)”")
        case .finished: return String(localized: "“\(what)” saved to Downloads")
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
