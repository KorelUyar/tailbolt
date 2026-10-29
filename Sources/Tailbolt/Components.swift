import AppKit
import ImageIO
import QuickLookThumbnailing
import SwiftUI
import TailboltCore
import UniformTypeIdentifiers

struct VisualEffect: NSViewRepresentable {
    var material: NSVisualEffectView.Material = .popover
    var blending: NSVisualEffectView.BlendingMode = .behindWindow

    func makeNSView(context: Context) -> NSVisualEffectView {
        let v = NSVisualEffectView()
        v.material = material
        v.blendingMode = blending
        v.state = .active
        return v
    }

    func updateNSView(_ v: NSVisualEffectView, context: Context) {
        v.material = material
        v.blendingMode = blending
    }
}

/// Panel surface: Liquid Glass on macOS 26+, the classic vibrancy material before. Continuous corners (or a
/// capsule for the HUD toast), 0.5 pt hairline; the panel itself supplies the shadow.
/// The glass is a background layer, not a container: content drawn inside a glass container gets vibrancy
/// (greens, reds and `.quaternary` fills flatten to white/black), so it stays a sibling and keeps its colours.
/// A faint neutral tint keeps text legible over busy desktops without losing the lensing.
struct GlassSurface<S: InsettableShape>: ViewModifier {
    var shape: S
    var material: NSVisualEffectView.Material = .popover
    @Environment(\.colorScheme) private var scheme

    func body(content: Content) -> some View {
        if #available(macOS 26, *) {
            content
                .background {
                    // A dark tint renders as an opaque light slab on macOS 26, so dark mode uses plain glass.
                    if scheme == .dark {
                        Color.clear.glassEffect(.regular, in: shape)
                    } else {
                        Color.clear.glassEffect(.regular.tint(Color.white.opacity(0.42)), in: shape)
                    }
                }
                .clipShape(shape)
                .overlay(shape.strokeBorder(.white.opacity(scheme == .dark ? 0.10 : 0.45), lineWidth: 0.5))
        } else {
            content
                .background(VisualEffect(material: material))
                .clipShape(shape)
                .overlay(shape.strokeBorder(.white.opacity(0.12), lineWidth: 0.5))
        }
    }
}

extension View {
    func glassSurface(cornerRadius: CGFloat = 20, material: NSVisualEffectView.Material = .popover) -> some View {
        modifier(GlassSurface(shape: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous), material: material))
    }

    /// The same surface as a pill (HUD toast).
    func glassCapsule(material: NSVisualEffectView.Material = .popover) -> some View {
        modifier(GlassSurface(shape: Capsule(), material: material))
    }
}

/// Animations that collapse to a short ease when "Reduce Motion" is on.
enum Motion {
    static var reduced: Bool { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }

    static func spring(_ response: Double, _ damping: Double) -> Animation {
        reduced ? .easeOut(duration: 0.2) : .spring(response: response, dampingFraction: damping)
    }

    static func ease(_ duration: Double) -> Animation {
        .easeOut(duration: reduced ? min(duration, 0.2) : duration)
    }
}

/// Trackpad haptics, all behind Settings.hapticsEnabled. Silent on machines without a Force Touch trackpad.
@MainActor
enum Haptics {
    /// A drag entered a target (device bubble, stack zone).
    static func alignment() { perform(.alignment) }
    /// Drop and completion.
    static func levelChange() { perform(.levelChange) }
    /// Gesture recognised (shake, ⇧-hold).
    static func generic() { perform(.generic) }

    private static func perform(_ pattern: NSHapticFeedbackManager.FeedbackPattern) {
        guard Settings.shared.hapticsEnabled else { return }
        NSHapticFeedbackManager.defaultPerformer.perform(pattern, performanceTime: .now)
    }
}

/// System sounds behind Settings.soundsEnabled.
@MainActor
enum Sounds {
    /// Soft "Tink" when a transfer finished.
    static func completion() { play("Tink") }
    /// "Glass" for an incoming offer (AppModel should call this instead of NSSound directly).
    static func incoming() { play("Glass") }

    private static func play(_ name: String) {
        guard Settings.shared.soundsEnabled else { return }
        NSSound(named: name)?.play()
    }
}

/// Feedback beats that several surfaces may observe (shelf bubble, menu grid, HUD): each fires once per transfer.
@MainActor
enum Feedback {
    private static var finishedIDs = Set<UUID>()

    static func transferFinished(_ item: TransferItem) {
        guard item.state == .finished, finishedIDs.insert(item.id).inserted else { return }
        if finishedIDs.count > 500 { finishedIDs = [item.id] }
        Sounds.completion()
        Haptics.levelChange()
    }
}

/// Stable, pleasant gradient per owner so devices of the same person share a color.
enum Palette {
    static let gradients: [[Color]] = [
        [Color(red: 0.36, green: 0.62, blue: 1.0), Color(red: 0.2, green: 0.38, blue: 0.95)],
        [Color(red: 0.98, green: 0.55, blue: 0.35), Color(red: 0.93, green: 0.33, blue: 0.38)],
        [Color(red: 0.45, green: 0.82, blue: 0.55), Color(red: 0.16, green: 0.62, blue: 0.48)],
        [Color(red: 0.78, green: 0.52, blue: 0.98), Color(red: 0.52, green: 0.32, blue: 0.92)],
        [Color(red: 1.0, green: 0.76, blue: 0.3), Color(red: 0.96, green: 0.52, blue: 0.16)],
        [Color(red: 0.4, green: 0.84, blue: 0.92), Color(red: 0.16, green: 0.56, blue: 0.82)],
    ]
    /// Own devices: a cool graphite plate, so the silver product pictures stand out.
    static let mine = [Color(red: 0.55, green: 0.59, blue: 0.66), Color(red: 0.30, green: 0.33, blue: 0.39)]

    static func gradient(for device: Device) -> [Color] {
        if device.peer.isMine { return mine }
        let key = device.peer.user?.loginName ?? device.id
        let h = key.unicodeScalars.reduce(UInt32(5381)) { ($0 &* 33) &+ $1.value }
        return gradients[Int(h % UInt32(gradients.count))]
    }
}

struct DeviceAvatar: View {
    let device: Device
    var size: CGFloat = 60

    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            Group {
                if !device.peer.isMine, let pic = device.peer.user?.profilePicURL {
                    AsyncImage(url: pic) { image in
                        image.resizable().scaledToFill()
                    } placeholder: {
                        symbolCircle
                    }
                } else {
                    symbolCircle
                }
            }
            .frame(width: size, height: size)
            .clipShape(Circle())
            .overlay(Circle().strokeBorder(.white.opacity(0.18), lineWidth: 0.5))

            if device.viaTaildrop {
                badge(symbol: "arrow.down.circle.fill", color: .secondary)
            } else if !device.peer.isMine && device.peer.user?.profilePicURL != nil {
                badge(symbol: device.symbol, color: .primary)
            }
        }
    }

    private var symbolCircle: some View {
        DevicePlate(art: device.art, colors: Palette.gradient(for: device), size: size)
    }

    private func badge(symbol: String, color: Color) -> some View {
        Image(systemName: symbol)
            .font(.system(size: size * 0.2, weight: .semibold))
            .foregroundStyle(color)
            .frame(width: size * 0.38, height: size * 0.38)
            .background(Circle().fill(.regularMaterial))
            .overlay(Circle().strokeBorder(.separator, lineWidth: 0.5))
            .offset(x: 3, y: 3)
    }
}

/// This Mac, for the radar empty state: own profile picture when Tailscale knows one, else a grey symbol circle.
struct SelfAvatar: View {
    var size: CGFloat = 40
    @State private var app = AppModel.shared

    var body: some View {
        Group {
            if let pic = app.status?.selfUser?.profilePicURL {
                AsyncImage(url: pic) { image in
                    image.resizable().scaledToFill()
                } placeholder: {
                    symbolCircle
                }
            } else {
                symbolCircle
            }
        }
        .frame(width: size, height: size)
        .clipShape(Circle())
        .overlay(Circle().strokeBorder(.white.opacity(0.22), lineWidth: 0.5))
        .shadow(color: .black.opacity(0.12), radius: 3, y: 1)
        .accessibilityLabel("This device: \(app.myName)")
    }

    private var symbolCircle: some View {
        DevicePlate(art: .thisMac, colors: Palette.mine, size: size)
    }
}

struct ProgressRing: View {
    let fraction: Double
    var indeterminate = false
    var lineWidth: CGFloat = 3.5
    var tint: Color = .accentColor
    @State private var spin = false

    var body: some View {
        ZStack {
            Circle().stroke(Color.primary.opacity(0.12), lineWidth: lineWidth)
            Circle()
                .trim(from: 0, to: indeterminate ? 0.25 : max(0.02, fraction))
                .stroke(tint, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                .rotationEffect(.degrees(indeterminate ? (spin ? 270 : -90) : -90))
                .animation(indeterminate ? .linear(duration: 1).repeatForever(autoreverses: false) : .easeOut(duration: 0.25),
                           value: indeterminate ? spin : (fraction > 0))
                .animation(.easeOut(duration: 0.2), value: fraction)
                .animation(.easeOut(duration: 0.3), value: tint)
        }
        .onAppear { spin = true }
    }
}

/// Small capsule under a device name: "LAN-Turbo ⚡︎", "Direkt (LAN)", "Relay", … Caption 2 (10 pt) is the floor
/// for any text in the app – smaller type turns to mush on a 1x display.
struct PathCapsule: View {
    let label: String
    var tint: Color = .secondary
    var bolt = false

    var body: some View {
        HStack(spacing: 2) {
            Text(label)
            if bolt { Image(systemName: "bolt.fill").font(.system(size: 9, weight: .bold)) }
        }
        .font(.system(size: 10, weight: .semibold, design: .rounded))
        .foregroundStyle(tint)
        .lineLimit(1)
        .padding(.horizontal, 5)
        .padding(.vertical, 1.5)
        .background(Capsule().fill(tint.opacity(0.13)))
        .overlay(Capsule().strokeBorder(tint.opacity(0.28), lineWidth: 0.5))
        // Never "LAN-Tur…": a row that runs out of space truncates the text next to it, not the badge.
        .fixedSize()
    }
}

/// How traffic reaches a device, as shown in the capsule: label, colour and the tooltip sentence.
@MainActor
struct PathBadge {
    let label: String
    let tint: Color
    let bolt: Bool
    let explanation: String

    static func make(device: Device, transfer: TransferItem?) -> PathBadge? {
        if let t = transfer, t.isActive, t.usesLAN {
            return PathBadge(label: String(localized: "LAN Turbo"), tint: .accentColor, bolt: true,
                             explanation: String(localized: "LAN Turbo: runs directly over the local network, alongside the Tailscale tunnel – the fastest path."))
        }
        switch device.peer.path {
        case .lan: return PathBadge(label: String(localized: "Direct (LAN)"), tint: .secondary, bolt: false,
                                    explanation: String(localized: "Direct connection on the local network."))
        case .direct: return PathBadge(label: String(localized: "Direct"), tint: .secondary, bolt: false,
                                       explanation: String(localized: "Direct WireGuard connection, no relay."))
        case .peerRelay: return PathBadge(label: String(localized: "Peer Relay"), tint: .secondary, bolt: false,
                                          explanation: String(localized: "Runs through another device on your tailnet (peer relay)."))
        case .relay: return PathBadge(label: String(localized: "Relay"), tint: .orange, bolt: false,
                                      explanation: String(localized: "Runs through a Tailscale relay server (DERP) – much slower than direct. Usually UDP is blocked."))
        case .unknown: return nil
        }
    }
}

/// AirDrop-style target: avatar, name, live status, path capsule. Accepts dropped files, spring-loads a
/// send while a drag hovers for 0.8 s, ⌘-click toggles the multi-recipient selection.
/// Right-click assigns a favorite slot (⌃⌥⌘1 … 9).
struct DeviceBubble: View {
    let device: Device
    let transfer: TransferItem?
    /// Keyboard navigation in the shelf: selection ring, short pulse, "1" keycap hint while ⌘ is held.
    var highlighted = false
    var flash = false
    var keycap: String? = nil
    /// Multi-recipient selection badge (⌘-click).
    var selected = false
    /// Shelf: grows to `wideWidth` while a transfer runs so "48 % · 312 MB/s · noch 1:12 min" fits.
    var wideWhenActive = false
    /// VoiceOver: "Senden: ⌘2".
    var keyHint: String? = nil
    /// Lines reserved for the name (`nameLines(for:)` of the whole row): every bubble in a row reserves the same,
    /// so avatars, subtitles and capsules stay aligned when one name ("MacBook Pro von Sara") wraps.
    var nameLines = 2
    var onDropFiles: ([URL]) -> Void
    var onTap: () -> Void
    var onCommandTap: (() -> Void)? = nil

    @State private var targeted = false
    @State private var hover = false
    @State private var dropPulse = false
    @State private var springFill: CGFloat = 0
    @State private var springWork: DispatchWorkItem?
    @State private var springSent = false
    @State private var declineTick = 0
    @State private var settings = Settings.shared
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    static let baseWidth: CGFloat = 84
    static let wideWidth: CGFloat = 156
    private let size: CGFloat = 58
    private static let nameFont = NSFont.systemFont(ofSize: 11, weight: .medium)

    /// 2 when one of these names does not fit the single name line of a base-width bubble, else 1. Measured with
    /// the same font SwiftUI lays out (2 pt margin for rounding); a name that still wraps only gets an ellipsis.
    static func nameLines(for devices: [Device]) -> Int {
        let limit = baseWidth - 4 - 2
        return devices.contains { ($0.name as NSString).size(withAttributes: [.font: nameFont]).width > limit } ? 2 : 1
    }

    private var showsStats: Bool {
        guard let t = transfer else { return false }
        if t.isActive { return true }
        switch t.state {
        case .finished: return recent(t, 6)
        case .declined, .failed: return recent(t, 8)
        default: return false
        }
    }

    private var width: CGFloat { wideWhenActive && showsStats ? Self.wideWidth : Self.baseWidth }
    private var justFinished: Bool { transfer.map { $0.state == .finished && recent($0, 6) } ?? false }
    private var showsRing: Bool {
        guard let t = transfer else { return false }
        return (t.isActive && t.state != .preparing) || justFinished
    }

    var body: some View {
        VStack(spacing: 4) {
            avatarZone
                .frame(width: size + 14, height: size + 14)
                .keyframeAnimator(initialValue: CGFloat(0), trigger: declineTick) { content, x in
                    content.offset(x: x)
                } keyframes: { _ in
                    KeyframeTrack {
                        CubicKeyframe(-4, duration: 0.05)
                        CubicKeyframe(4, duration: 0.05)
                        CubicKeyframe(-4, duration: 0.05)
                        CubicKeyframe(4, duration: 0.05)
                        CubicKeyframe(-3, duration: 0.05)
                        CubicKeyframe(0, duration: 0.07)
                    }
                }

            // Fixed height for the whole row (`nameLines`), not the name's own: see `nameLines(for:)`.
            Text(device.name)
                .font(.system(size: 11, weight: .medium))
                .lineLimit(2)
                .multilineTextAlignment(.center)
                .frame(width: width - 4, height: nameLines == 2 ? 28 : 14, alignment: .top)
            if let keycap {
                Text(keycap)
                    .font(.system(size: 10, weight: .semibold, design: .rounded))
                    .foregroundStyle(.secondary)
                    .frame(width: 16, height: 13)
                    .background(RoundedRectangle(cornerRadius: 3, style: .continuous).fill(.quaternary))
                    .overlay(RoundedRectangle(cornerRadius: 3, style: .continuous).strokeBorder(.separator, lineWidth: 0.5))
                    .frame(width: width - 4, height: 13)
                    .transition(.opacity)
            } else {
                Text(subtitle)
                    .font(.system(size: 10))
                    .monospacedDigit()
                    .foregroundStyle(subtitleColor)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .frame(width: width, height: 13)
                    .contentTransition(.numericText())
            }
            capsules
                .frame(width: width - 4, height: 16)
        }
        .frame(width: width)
        .contentShape(Rectangle())
        .animation(Motion.spring(0.28, 0.7), value: targeted)
        .animation(Motion.spring(0.25, 0.6), value: flash)
        .animation(Motion.spring(0.35, 0.8), value: width)
        .animation(Motion.ease(0.15), value: hover)
        .animation(Motion.ease(0.12), value: highlighted)
        .animation(Motion.ease(0.1), value: keycap)
        .animation(Motion.spring(0.25, 0.6), value: selected)
        .animation(Motion.spring(0.2, 0.6), value: justFinished)
        .onHover { hover = $0 }
        .onTapGesture {
            if NSEvent.modifierFlags.contains(.command), let onCommandTap {
                onCommandTap()
            } else {
                onTap()
            }
        }
        .onDrop(of: [.fileURL], isTargeted: $targeted) { providers in
            // Spring-loaded send already went out while hovering: the drop is the same intent, not a second one.
            if springSent { return true }
            Haptics.levelChange()
            FileDrop.load(providers) { onDropFiles($0) }
            return true
        }
        .onChange(of: targeted) { _, on in
            if on {
                Haptics.alignment()
                beginSpringLoad()
            } else {
                endSpringLoad()
            }
        }
        .onChange(of: transfer?.id) { _, id in
            if id != nil { pulse() }
        }
        .onChange(of: transfer?.state) { _, state in
            guard let state else { return }
            switch state {
            case .finished:
                if let transfer { Feedback.transferFinished(transfer) }
            case .declined, .failed:
                if !reduceMotion { declineTick += 1 }
            default: break
            }
        }
        .contextMenu { favoriteMenu }
        .help(tooltip)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityText)
        .accessibilityValue(subtitle)
        .accessibilityAddTraits(.isButton)
        .accessibilityHint(selected ? String(localized: "⌘-click to remove from the selection") : String(localized: "Sends the files on the shelf to this device. ⌘-click selects several devices."))
    }

    // MARK: pieces

    private var avatarScale: CGFloat {
        if targeted { return 1.12 }
        if dropPulse || flash { return 1.14 }
        return hover ? 1.04 : 1
    }

    @ViewBuilder
    private var avatarZone: some View {
        ZStack {
            if highlighted {
                Circle().strokeBorder(Color.accentColor.opacity(0.9), lineWidth: 2)
                    .frame(width: size + 10, height: size + 10)
                    .shadow(color: Color.accentColor.opacity(0.35), radius: 4)
                    .transition(.opacity)
            }
            DeviceAvatar(device: device, size: size)
                .scaleEffect(avatarScale)
            // Sits on the avatar edge; while the progress ring owns that edge the badge steps aside instead of
            // cutting a notch into the ring track.
            if let slot = settings.favoriteSlot(of: device.id), !showsRing {
                Text("\(slot)")
                    .font(.system(size: 8.5, weight: .bold, design: .rounded))
                    .foregroundStyle(.white)
                    .frame(width: 15, height: 15)
                    .background(Circle().fill(Color.accentColor))
                    .overlay(Circle().strokeBorder(.white.opacity(0.9), lineWidth: 1.2))
                    .offset(x: -size / 2 + 3, y: -size / 2 + 3)
                    .transition(.opacity)
                    .help("Favorite \(slot)")
            }
            if settings.isPaired(device.id), !showsRing {
                Image(systemName: "bolt.fill")
                    .font(.system(size: 7.5, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(width: 15, height: 15)
                    .background(Circle().fill(Color.green))
                    .overlay(Circle().strokeBorder(.white.opacity(0.9), lineWidth: 1.2))
                    .offset(x: -size / 2 + 3, y: size / 2 - 3)
                    .transition(.opacity)
                    .help("Auto-accept with each other is on")
            }
            if let t = transfer, showsRing {
                ProgressRing(fraction: t.fraction,
                             indeterminate: t.state == .waiting || t.taildrop != nil,
                             tint: t.state == .finished ? .green : .accentColor)
                    .frame(width: size + 9, height: size + 9)
                    .transition(.opacity)
            }
            if justFinished {
                Image(systemName: "checkmark.circle.fill")
                    .symbolRenderingMode(.palette)
                    .foregroundStyle(.white, .green)
                    .font(.system(size: 22))
                    .background(Circle().fill(.white).padding(3))
                    .offset(x: size / 2 - 6, y: -size / 2 + 6)
                    .transition(.scale(scale: 0.4).combined(with: .opacity))
            } else if selected {
                Image(systemName: "checkmark.circle.fill")
                    .symbolRenderingMode(.palette)
                    .foregroundStyle(.white, Color.accentColor)
                    .font(.system(size: 20))
                    .background(Circle().fill(.white).padding(3))
                    .offset(x: size / 2 - 6, y: -size / 2 + 6)
                    .transition(.scale(scale: 0.4).combined(with: .opacity))
            }
            if targeted {
                Circle().strokeBorder(Color.accentColor, lineWidth: 3)
                    .frame(width: size + 12, height: size + 12)
                // Spring-loaded send: thin countdown ring; when it closes the send starts without a drop.
                Circle()
                    .trim(from: 0, to: springFill)
                    .stroke(Color.accentColor.opacity(0.9), style: StrokeStyle(lineWidth: 1.5, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                    .frame(width: size + 19, height: size + 19)
            }
        }
    }

    @ViewBuilder
    private var capsules: some View {
        HStack(spacing: 4) {
            if let badge = PathBadge.make(device: device, transfer: transfer) {
                PathCapsule(label: badge.label, tint: badge.tint, bolt: badge.bolt)
                    .transition(.scale(scale: 0.8).combined(with: .opacity))
            }
            if let lz4 = lz4Label {
                Text(lz4)
                    .font(.system(size: 10, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .transition(.opacity)
            }
        }
        .animation(Motion.ease(0.2), value: lz4Label)
        .animation(Motion.ease(0.2), value: PathBadge.make(device: device, transfer: transfer)?.label)
    }

    /// "LZ4 −62 %" once compression saved more than 5 % of the payload.
    private var lz4Label: String? {
        guard let t = transfer, t.isActive || justFinished, t.bytes > 0, t.bytesSaved > 0,
              Double(t.bytesSaved) > Double(t.bytes) * 0.05 else { return nil }
        let pct = Int((Double(t.bytesSaved) / Double(t.bytes) * 100).rounded())
        return "LZ4 −\(pct) %"
    }

    @ViewBuilder
    private var favoriteMenu: some View {
        let current = settings.favoriteSlot(of: device.id)
        Menu("Set as Favorite") {
            ForEach(1...9, id: \.self) { slot in
                Toggle(isOn: Binding(
                    get: { current == slot },
                    set: { on in settings.setFavorite(id: on ? device.id : nil, name: device.name, slot: slot) }
                )) {
                    Text(String(localized: "Favorite \(slot)") + (settings.shortcuts[.favorite(slot)].map { "   \($0.display)" } ?? ""))
                }
            }
        }
        if let current {
            Button("Remove Favorite \(current)") { settings.setFavorite(id: nil, name: nil, slot: current) }
        }
        Divider()
        Button("Choose Files and Send…") {
            pickFiles(noteFor: device) { AppModel.shared.send($0, to: device, note: $1) }
        }
        if !device.peer.isMine && !device.viaTaildrop {
            Divider()
            if settings.isPaired(device.id) {
                Button("Turn Off Auto-Accept with \(device.name)") { AppModel.shared.unpair(deviceID: device.id) }
            } else if AppModel.shared.pairingInFlight.contains(device.id) {
                Button("Waiting for \(device.name)…") {}.disabled(true)
            } else if device.canPair {
                Button("Auto-Accept with Each Other…") { AppModel.shared.requestPairing(with: device) }
            } else {
                Button("Auto-Accept needs Tailbolt 2.3 on \(device.name)") {}.disabled(true)
            }
        }
    }

    // MARK: beats

    /// Drop / send start: 1.0 → 1.14 in 0.12 s ease-out, then a spring back to 1.
    private func pulse() {
        guard !reduceMotion else { return }
        withAnimation(.easeOut(duration: 0.12)) { dropPulse = true }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) {
            withAnimation(.spring(response: 0.35, dampingFraction: 0.65)) { dropPulse = false }
        }
    }

    private func beginSpringLoad() {
        springSent = false
        springWork?.cancel()
        springFill = 0
        withAnimation(.linear(duration: 0.8)) { springFill = 1 }
        let work = DispatchWorkItem {
            guard targeted, !springSent, transfer?.isActive != true else { return }
            let urls = NSPasteboard(name: .drag).readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
            guard !urls.isEmpty else { return }
            springSent = true
            Haptics.levelChange()
            onDropFiles(urls)
        }
        springWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8, execute: work)
    }

    private func endSpringLoad() {
        springWork?.cancel()
        springWork = nil
        withAnimation(.easeOut(duration: 0.15)) { springFill = 0 }
        springSent = false
    }

    // MARK: text

    private func recent(_ t: TransferItem, _ seconds: TimeInterval) -> Bool {
        Date().timeIntervalSince(t.finishedAt ?? t.createdAt) < seconds
    }

    /// Live transfer status while it is worth showing; nil once the result has faded out.
    private var status: (text: String, color: Color)? {
        guard let t = transfer else { return nil }
        switch t.state {
        case .preparing: return (String(localized: "Preparing…"), .accentColor)
        case .waiting: return (String(localized: "Waiting…"), .accentColor)
        case .transferring:
            if t.taildrop != nil { return (String(localized: "Sending…"), .accentColor) }
            // Narrow no-break spaces (U+202F) before % and around the dot: Swiss typography, and it fits 84 pt.
            let sep = "\u{202F}·\u{202F}"
            var s = "\(Int(t.fraction * 100))\u{202F}%"
            if t.speed > 0 {
                s += sep + ByteFormat.speed(t.speed)
                let remaining = Double(t.totalBytes - t.bytes) / t.speed
                if wideWhenActive, remaining >= 1 { s += sep + TransferItem.eta(remaining) }
            }
            return (s, .accentColor)
        case .finishing: return (String(localized: "Finishing…"), .accentColor)
        case .finished: return recent(t, 6) ? (Self.finishedSummary(t), .green) : nil
        case .declined: return recent(t, 8) ? (String(localized: "Declined"), .red) : nil
        case .failed: return recent(t, 8) ? (String(localized: "Failed"), .red) : nil
        case .cancelled: return nil
        }
    }

    private var subtitle: String {
        if let status { return status.text }
        if device.viaTaildrop { return "Taildrop" }
        return device.ownerName ?? (device.peer.isMine ? String(localized: "My device") : "")
    }

    private var subtitleColor: Color { status?.color ?? .secondary }

    /// "0:04", "12:30", "1:02:03".
    static func clock(_ seconds: Double) -> String {
        let s = Int(seconds.rounded())
        if s >= 3600 { return String(format: "%d:%02d:%02d", s / 3600, s / 60 % 60, s % 60) }
        return String(format: "%d:%02d", s / 60, s % 60)
    }

    /// "2,4 GB in 8,1 s" (locale decimal separator).
    static func finishedSummary(_ t: TransferItem) -> String {
        let end = t.finishedAt ?? Date()
        let start = t.startedTransferringAt ?? t.createdAt
        let d = max(0.1, end.timeIntervalSince(start))
        let size = ByteFormat.string(t.totalBytes)
        if d < 10 {
            let f = NumberFormatter()
            f.minimumFractionDigits = 1
            f.maximumFractionDigits = 1
            return "\(size) in \(f.string(from: NSNumber(value: d)) ?? String(format: "%.1f", d)) s"
        }
        if d < 60 { return "\(size) in \(Int(d.rounded())) s" }
        return "\(size) in \(clock(d)) min"
    }

    private var tooltip: String {
        var lines = [device.viaTaildrop ? String(localized: "\(device.name) – via Taildrop (Tailbolt not installed)") : device.name]
        if let owner = device.ownerName { lines[0] += " · \(owner)" }
        if let badge = PathBadge.make(device: device, transfer: transfer) { lines.append(badge.explanation) }
        if let lz4 = lz4Label { lines.append(String(localized: "\(lz4): what LZ4 compression is saving right now.")) }
        if let keyHint { lines.append(String(localized: "Send: \(keyHint)")) }
        if settings.isPaired(device.id) { lines.append(String(localized: "Auto-accept with each other is on")) }
        if let v = device.tailboltVersion, Updater.isNewer(Tailbolt.appVersion, than: v) {
            lines.append(String(localized: "Runs Tailbolt \(v) – an update brings notes and auto-accept"))
        }
        return lines.joined(separator: "\n")
    }

    private var accessibilityText: String {
        var parts = [device.name, "online"]
        if let owner = device.ownerName { parts.append(String(localized: "owned by \(owner)")) }
        if device.viaTaildrop { parts.append("via Taildrop") }
        if let badge = PathBadge.make(device: device, transfer: transfer) { parts.append(badge.label) }
        if let slot = settings.favoriteSlot(of: device.id) { parts.append(String(localized: "Favorite \(slot)")) }
        if selected { parts.append(String(localized: "selected")) }
        if let keyHint { parts.append(String(localized: "Send: \(keyHint)")) }
        return parts.joined(separator: ", ")
    }
}

/// Accent-filled bar that stays colored in non-key panels (system ProgressView turns gray there).
struct Bar: View {
    let value: Double?
    @State private var pulse = false

    var body: some View {
        GeometryReader { g in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.primary.opacity(0.1))
                if let value {
                    Capsule().fill(Color.accentColor)
                        .frame(width: max(4, g.size.width * min(1, value)))
                        .animation(.easeOut(duration: 0.2), value: value)
                } else {
                    Capsule().fill(Color.accentColor.opacity(pulse ? 0.9 : 0.35))
                        .animation(.easeInOut(duration: 0.8).repeatForever(), value: pulse)
                        .onAppear { pulse = true }
                }
            }
        }
        .frame(height: 4)
    }
}

/// Buttons that look the same whether or not the (non-activating) panel is key.
struct PanelButtonStyle: ButtonStyle {
    var prominent = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12, weight: prominent ? .semibold : .regular))
            .foregroundStyle(prominent ? Color.white : Color.primary)
            .padding(.vertical, 6)
            .padding(.horizontal, 10)
            .background(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(prominent ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(Color.primary.opacity(0.09)))
            )
            .opacity(configuration.isPressed ? 0.75 : 1)
            .contentShape(Rectangle())
    }
}

enum FileDrop {
    /// Loads file URLs from drag providers and calls back once on the main thread.
    static func load(_ providers: [NSItemProvider], _ done: @escaping @MainActor ([URL]) -> Void) {
        let group = DispatchGroup()
        let lock = NSLock()
        var urls: [(Int, URL)] = []
        for (i, p) in providers.enumerated() where p.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
            group.enter()
            _ = p.loadObject(ofClass: URL.self) { url, _ in
                if let url { lock.lock(); urls.append((i, url)); lock.unlock() }
                group.leave()
            }
        }
        group.notify(queue: .main) {
            let sorted = urls.sorted { $0.0 < $1.0 }.map(\.1)
            if !sorted.isEmpty { MainActor.assumeIsolated { done(sorted) } }
        }
    }
}

/// QuickLook thumbnails with icon fallback, cached per path at the largest pixel size asked for so far: the same
/// file shows at 30 pt (Zuletzt row), 68 pt (received) and 78 pt (shelf stack), and a rendition made for a bigger
/// slot serves the smaller ones while a smaller one is regenerated rather than upscaled. Plain images additionally
/// get a fast CGImageSource thumbnail right away (QuickLook can be slow or unavailable outside an app bundle).
@MainActor
final class Thumbnails {
    static let shared = Thumbnails()
    private var cache: [URL: (image: NSImage, pixels: Int)] = [:]

    func image(for url: URL, size: CGFloat, update: @escaping (NSImage) -> Void) -> NSImage {
        let scale = NSScreen.main?.backingScaleFactor ?? 2
        let pixels = Int(size * scale)
        if let hit = cache[url], hit.pixels >= pixels { return hit.image }
        if Self.isImage(url) {
            DispatchQueue.global(qos: .userInitiated).async {
                guard let img = Self.imageThumbnail(url, pixels: pixels) else { return }
                Self.deliver { update(self.store(img, for: url, pixels: pixels, preferred: false)) }
            }
        }
        let req = QLThumbnailGenerator.Request(fileAt: url, size: CGSize(width: size, height: size),
                                               scale: scale, representationTypes: .thumbnail)
        QLThumbnailGenerator.shared.generateBestRepresentation(for: req) { rep, _ in
            guard let rep else { return }
            Self.deliver { update(self.store(rep.nsImage, for: url, pixels: pixels, preferred: true)) }
        }
        return cache[url]?.image ?? NSWorkspace.shared.icon(forFile: url.path)
    }

    /// Caches `image` unless a bigger rendition is already there (or an equal one, when this is only the quick
    /// CGImageSource stand-in – QuickLook's `preferred` result wins ties) and returns what the view should show.
    private func store(_ image: NSImage, for url: URL, pixels: Int, preferred: Bool) -> NSImage {
        if let hit = cache[url], hit.pixels > pixels || (hit.pixels == pixels && !preferred) { return hit.image }
        cache[url] = (image, pixels)
        return image
    }

    /// Hands a result to the main thread through the run loop rather than the main dispatch queue, so it also
    /// arrives inside nested run loops (`--snapshot` spins one from within a dispatch block, which would starve
    /// `DispatchQueue.main.async` until exit).
    private nonisolated static func deliver(_ work: @escaping @MainActor () -> Void) {
        RunLoop.main.perform { MainActor.assumeIsolated { work() } }
    }

    private nonisolated static func isImage(_ url: URL) -> Bool {
        UTType(filenameExtension: url.pathExtension)?.conforms(to: .image) == true
    }

    private nonisolated static func imageThumbnail(_ url: URL, pixels: Int) -> NSImage? {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        let opts: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceThumbnailMaxPixelSize: pixels,
            kCGImageSourceCreateThumbnailWithTransform: true,
        ]
        guard let cg = CGImageSourceCreateThumbnailAtIndex(src, 0, opts as CFDictionary) else { return nil }
        return NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
    }
}

struct FileThumb: View {
    let url: URL
    var size: CGFloat = 84
    @State private var image: NSImage?

    var body: some View {
        Image(nsImage: image ?? NSWorkspace.shared.icon(forFile: url.path))
            .resizable()
            .scaledToFit()
            .frame(width: size, height: size)
            .shadow(color: .black.opacity(0.18), radius: 3, y: 2)
            .onAppear {
                image = Thumbnails.shared.image(for: url, size: size) { image = $0 }
            }
    }
}
