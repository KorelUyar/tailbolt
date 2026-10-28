import AppKit
import SwiftUI
import TailboltCore

// Every stage is a pure function of the demo clock: `elapsed` seconds since the page became
// current. Stages wrap it into their own loop, so frozen snapshots (`frozenTime`) render the exact
// same frame the live animation shows at that moment.

/// 720-wide stage container with the desktop gradient. Drives the clock (TimelineView while the
/// window is key; a fixed time for snapshots) and is invisible to hit testing and VoiceOver except
/// for its one-sentence description.
struct StageView<Content: View>: View {
    let height: CGFloat
    let label: String
    @ViewBuilder let content: (TimeInterval) -> Content

    @Environment(OnboardingState.self) private var state
    @Environment(\.colorScheme) private var scheme
    @State private var start = Date()

    var body: some View {
        ZStack {
            LinearGradient(colors: scheme == .dark ? OnboardingTokens.stageDark : OnboardingTokens.stageLight,
                           startPoint: .topLeading, endPoint: .bottomTrailing)
            if let frozen = state.frozenTime {
                content(frozen)
            } else {
                TimelineView(.animation(paused: !state.isRunning)) { ctx in
                    content(max(0, ctx.date.timeIntervalSince(start)))
                }
            }
        }
        .frame(width: OnboardingTokens.windowWidth, height: height)
        .clipped()
        .allowsHitTesting(false)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(label)
        .onAppear { start = Date() }
        .onChange(of: state.isRunning) { _, running in if running { start = Date() } }
    }
}

// MARK: - Page 0: Radar

struct RadarStage: View {
    let elapsed: TimeInterval
    var parallax: CGSize = .zero
    var reduceMotion = false

    static let loop: TimeInterval = 6.0
    private let center = CGPoint(x: 360, y: 170)
    private let angles: [Double] = [-150, -30, 30, 150]              // top-left, top-right, bottom-right, bottom-left
    private let symbols = ["laptopcomputer", "iphone", "macstudio", "pc"]
    private let colors = [Palette.gradients[0], Palette.gradients[1], Palette.gradients[3], Palette.gradients[2]]
    private let beamOrder = [1, 3, 0, 2]                             // which device each beam reaches, in draw order
    private let beamStarts: [TimeInterval] = [1.0, 1.35, 1.70, 2.05]

    private func devicePos(_ i: Int) -> CGPoint {
        let a = angles[i] * .pi / 180
        return CGPoint(x: center.x + 150 * cos(a) + parallax.width * 10 / 6, y: center.y + 150 * sin(a) + parallax.height * 10 / 6)
    }

    var body: some View {
        let firstLoop = elapsed < Self.loop
        let t = elapsed.truncatingRemainder(dividingBy: Self.loop)
        let iconScale = firstLoop ? lerp(prog(t, 0, 0.45, reduceMotion ? .easeOut : .spring), 0.92, 1) : 1
        let iconOpacity = firstLoop ? prog(t, 0, 0.3, .easeOut) : 1
        let beamFade = (1 - 0.65 * prog(t, 4.4, 5.2)) * (1 - prog(t, 5.6, 6.0))
        let iconCenter = CGPoint(x: center.x + parallax.width, y: center.y + parallax.height)

        ZStack {
            // Radar rings
            if !reduceMotion {
                ForEach(0..<2, id: \.self) { k in
                    let phase = (elapsed + Double(k) * 1.2).truncatingRemainder(dividingBy: 2.4)
                    let p = prog(phase, 0, 2.0, .easeOut)
                    Circle()
                        .stroke(Color.primary.opacity(0.18), lineWidth: 1)
                        .frame(width: lerp(p, 140, 380), height: lerp(p, 140, 380))
                        .opacity(phase < 2.0 ? 0.5 * (1 - p) : 0)
                        .position(iconCenter)
                }
            }

            // Beams
            ForEach(0..<4, id: \.self) { k in
                let i = beamOrder[k]
                let from = iconCenter, to = devicePos(i)
                let d = CGPoint(x: to.x - from.x, y: to.y - from.y)
                let len = hypot(d.x, d.y)
                let u = CGPoint(x: d.x / len, y: d.y / len)
                let a = CGPoint(x: from.x + u.x * 70, y: from.y + u.y * 70)
                let b = CGPoint(x: to.x - u.x * 26, y: to.y - u.y * 26)
                let draw = prog(t, beamStarts[k], beamStarts[k] + 0.45, .easeOut)
                Path { p in p.move(to: a); p.addLine(to: b) }
                    .trim(from: 0, to: draw)
                    .stroke(OnboardingTokens.brandGradient, style: StrokeStyle(lineWidth: 2, lineCap: .round))
                    .opacity(beamFade)

                // Travelling documents on beam 1 (k 0) and beam 3 (k 2)
                let travelStart: TimeInterval? = k == 0 ? 2.6 : (k == 2 ? 3.2 : nil)
                if let s = travelStart, t >= s, t < s + 0.6 {
                    let p = prog(t, s, s + 0.6, .easeInOut)
                    Image(systemName: "doc.fill")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.white)
                        .shadow(color: .black.opacity(0.3), radius: 2, y: 1)
                        .position(x: lerp(p, a.x, b.x), y: lerp(p, a.y, b.y))
                }
            }

            // Devices
            ForEach(0..<4, id: \.self) { i in
                let appear = 0.40 + Double(i) * 0.12
                let scale = firstLoop ? lerp(prog(t, appear, appear + 0.4, reduceMotion ? .easeOut : .spring), 0.6, 1) : 1
                let opacity = firstLoop ? prog(t, appear, appear + 0.25, .easeOut) : 1
                let k = beamOrder.firstIndex(of: i) ?? 0
                let arrival = beamStarts[k] + 0.45
                let pulseScale = reduceMotion ? 1 : pulse(t, at: arrival, duration: 0.25, peak: 1.08)
                let badgeStart: TimeInterval? = k == 0 ? 3.2 : (k == 2 ? 3.8 : nil)
                let badgeVisible = badgeStart.map { t >= $0 && t < $0 + 1.2 } ?? false
                ZStack(alignment: .bottomTrailing) {
                    DeviceGlyph(symbol: symbols[i], colors: colors[i])
                    if badgeVisible, let s = badgeStart {
                        Image(systemName: "checkmark.circle.fill")
                            .symbolRenderingMode(.palette)
                            .foregroundStyle(.white, .green)
                            .font(.system(size: 14))
                            .background(Circle().fill(.white).padding(2))
                            .offset(x: 3, y: 3)
                            .scaleEffect(lerp(prog(t, s, s + 0.3, reduceMotion ? .easeOut : .spring), 0.4, 1))
                            .opacity(1 - prog(t, s + 1.0, s + 1.2))
                    }
                }
                .scaleEffect(scale * pulseScale)
                .opacity(opacity)
                .position(devicePos(i))
            }

            AppIconView(size: 128, shadow: false)
                .shadow(color: .black.opacity(0.25), radius: 14, y: 8)
                .scaleEffect(iconScale)
                .opacity(iconOpacity)
                .position(iconCenter)
        }
    }
}

// MARK: - Page 0b: Tailscale

struct TailscaleStage: View {
    let elapsed: TimeInterval
    var connected = false
    var reduceMotion = false

    static let loop: TimeInterval = 4.0
    private let center = CGPoint(x: 360, y: 170)

    var body: some View {
        let t = elapsed.truncatingRemainder(dividingBy: Self.loop)
        let dashedOpacity = connected ? 0 : prog(t, 0.4, 0.7) * (1 - prog(t, 2.0, 2.6)) * (1 - prog(t, 3.4, 3.8))
        let solid = connected ? 1 : prog(t, 2.0, 2.6, .easeInOut) * (1 - prog(t, 3.4, 3.8))
        let rotation = reduceMotion ? 0 : elapsed / 16 * 360

        ZStack {
            Circle()
                .stroke(Color.primary.opacity(0.35), style: StrokeStyle(lineWidth: 1.5, dash: [4, 6]))
                .frame(width: 170, height: 170)
                .rotationEffect(.degrees(rotation))
                .opacity(dashedOpacity)
                .position(center)
            Circle()
                .trim(from: 0, to: solid)
                .stroke(OnboardingTokens.brandGradient, style: StrokeStyle(lineWidth: 1.5, lineCap: .round))
                .rotationEffect(.degrees(-90))
                .frame(width: 170, height: 170)
                .opacity(solid > 0 ? 1 : 0)
                .position(center)

            ForEach(0..<3, id: \.self) { i in
                let a = (Double(i) * 120 - 90) * .pi / 180
                let appear = 1.0 + Double(i) * 0.12
                let p = connected ? 1 : prog(t, appear, appear + 0.3, reduceMotion ? .easeOut : .spring) * (1 - prog(t, 3.4, 3.8))
                DeviceGlyph(symbol: ["laptopcomputer", "iphone", "pc"][i],
                            colors: [Palette.gradients[0], Palette.gradients[1], Palette.gradients[2]][i], size: 36)
                    .scaleEffect(lerp(min(1, p), 0.6, 1))
                    .opacity(min(1, p))
                    .position(x: center.x + 85 * cos(a), y: center.y + 85 * sin(a))
            }

            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .fill(.regularMaterial)
                .overlay(RoundedRectangle(cornerRadius: 22, style: .continuous).strokeBorder(.white.opacity(0.25), lineWidth: 0.5))
                .overlay(Image(systemName: connected ? "checkmark" : "network")
                    .font(.system(size: 44, weight: .medium))
                    .foregroundStyle(OnboardingTokens.brandGradient))
                .frame(width: 96, height: 96)
                .shadow(color: .black.opacity(0.18), radius: 12, y: 6)
                .position(center)
        }
    }
}

// MARK: - Page 1: Shake

struct ShakeStage: View {
    let elapsed: TimeInterval
    var reduceMotion = false

    static let loop: TimeInterval = 7.0
    // 318 × 0.85 = 270 pt tall → bottom edge at 313, inside the 320 pt stage (y 190 clipped the corners).
    private let shelfCenter = CGPoint(x: 430, y: 178)
    private let shelfScale: CGFloat = 0.85
    private let finderOrigin = CGPoint(x: 40, y: 56)

    private var avatar0: CGPoint {
        let local = DemoShelf.avatarCenter(0, of: 3)
        return CGPoint(x: shelfCenter.x + (local.x - DemoShelf.size.width / 2) * shelfScale,
                       y: shelfCenter.y + (local.y - DemoShelf.size.height / 2) * shelfScale)
    }

    private func pointer(_ t: TimeInterval) -> CGPoint {
        let p0 = CGPoint(x: 150, y: 118), p1 = CGPoint(x: 430, y: 176)
        if t < 0.9 { return p0 }
        if t < 1.6 { let p = prog(t, 0.9, 1.6); return CGPoint(x: lerp(p, p0.x, p1.x), y: lerp(p, p0.y, p1.y)) }
        if t < 2.2 {
            let dx = reduceMotion ? 0 : 38 * sin(2 * .pi * (t - 1.6) / 0.4)
            return CGPoint(x: p1.x + dx, y: p1.y)
        }
        if t < 2.6 { return p1 }
        let target = CGPoint(x: avatar0.x - 4, y: avatar0.y - 6)
        if t < 3.3 { let p = prog(t, 2.6, 3.3); return CGPoint(x: lerp(p, p1.x, target.x), y: lerp(p, p1.y, target.y)) }
        return target
    }

    var body: some View {
        let t = elapsed.truncatingRemainder(dividingBy: Self.loop)
        let pointerOpacity = prog(t, 0.4, 0.55) * (1 - prog(t, 6.4, 6.7))
        let dragging = t >= 0.8 && t < 3.65
        let liftScale = lerp(prog(t, 0.8, 0.95, .easeOut), 1, 1.06)
        let dropP = prog(t, 3.4, 3.65, .easeIn)
        let shelfIn = prog(t, 2.25, 2.6, reduceMotion ? .easeOut : .spring)
        let shelfOpacity = prog(t, 2.25, 2.4) * (1 - prog(t, 5.8, 6.05))
        let status: DemoBubble.Status = t < 3.4 ? .idle : (t < 3.6 ? .waiting : (t < 5.0 ? .progress(quantised(t)) : .sent))
        let pos = pointer(t)

        ZStack(alignment: .topLeading) {
            MockFinder(rows: [.init(icon: "film", name: "Ferien-Video.mov", detail: "4.2 GB"),
                              .init(icon: "folder.fill", name: "Projekt-Export", detail: nil),
                              .init(icon: "doc.richtext", name: "notes.pdf", detail: "1.1 MB"),
                              .init(icon: "photo", name: "logo.png", detail: "214 KB")],
                       selected: t < 6.7 ? 0 : nil, pressed: dragging, hideThumbOfSelected: dragging)
                .offset(x: finderOrigin.x, y: finderOrigin.y)

            if shelfOpacity > 0 {
                DemoShelf(devices: OnboardingMocks.shelfDevices, targetedIndex: t >= 3.05 && t < 3.4 ? 0 : nil,
                          statuses: [status, .idle, .idle])
                    .scaleEffect(shelfScale * lerp(shelfIn, 0.9, 1))
                    .opacity(shelfOpacity)
                    .position(shelfCenter)
            }

            // Motion lines / reduce-motion glyph during the shake
            if t >= 1.6 && t < 2.2 {
                if reduceMotion {
                    Image(systemName: "arrow.left.and.right")
                        .font(.system(size: 20, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .scaleEffect(pulse(t, at: 1.6, duration: 0.6, peak: 1.3))
                        .position(x: pos.x + 12, y: pos.y - 24)
                } else {
                    ForEach([1.7, 1.9, 2.1], id: \.self) { peak in
                        if abs(t - peak) < 0.06 {
                            let side: CGFloat = sin(2 * .pi * (peak - 1.6) / 0.4) > 0 ? 1 : -1
                            Capsule().fill(Color.secondary.opacity(0.4)).frame(width: 14, height: 2)
                                .position(x: pos.x + 12 - side * 26, y: pos.y + 6)
                            Capsule().fill(Color.secondary.opacity(0.4)).frame(width: 10, height: 2)
                                .position(x: pos.x + 12 - side * 24, y: pos.y + 14)
                        }
                    }
                }
            }

            if pointerOpacity > 0 {
                MockPointer(dragging: dragging ? AnyView(
                    DemoThumb(kind: .video)
                        .scaleEffect(liftScale * lerp(dropP, 1, 0.2))
                        .opacity(1 - dropP)
                ) : nil)
                .opacity(pointerOpacity)
                .position(x: pos.x + 12, y: pos.y + 12)
            }
        }
    }

    private func quantised(_ t: TimeInterval) -> Double {
        let q = floor((t - 3.6) / 0.2) * 0.2
        return prog(3.6 + q, 3.6, 5.0, .easeInOut)
    }
}

// MARK: - Page 2: Bubbles

struct BubblesStage: View {
    let elapsed: TimeInterval
    let devices: [Device]
    var reduceMotion = false

    static let loop: TimeInterval = 7.2
    private let top: CGFloat = 96

    private func bubbleX(_ i: Int) -> CGFloat { 176 + 92 * CGFloat(i) }
    private var avatarY: CGFloat { top + 36 }

    var body: some View {
        let firstLoop = elapsed < Self.loop
        let t = elapsed.truncatingRemainder(dividingBy: Self.loop)
        let fadeAll = 1 - prog(t, 6.8, 7.2)
        let calloutDim = lerp(prog(t, 2.7, 3.4), 1, 0.4) * (1 - prog(t, 6.2, 6.5))
        let status1: DemoBubble.Status = t < 3.5 ? .idle : (t < 3.9 ? .waiting : (t < 5.3 ? .progress(prog(t, 3.9, 5.3, .easeInOut)) : .sent))
        let pointerTarget = CGPoint(x: bubbleX(1) - 4, y: avatarY - 6)
        let move = prog(t, 2.7, 3.4)
        let pos = CGPoint(x: lerp(move, 120, pointerTarget.x), y: lerp(move, 300, pointerTarget.y))
        let pointerOpacity = prog(t, 2.6, 2.75) * (1 - prog(t, 3.9, 4.2))
        let badgePulse = reduceMotion ? 1 : max(pulse(t, at: 1.3, duration: 0.3, peak: 1.25), pulse(t, at: 1.6, duration: 0.3, peak: 1.25))

        ZStack(alignment: .topLeading) {
            ForEach(Array(devices.prefix(5).enumerated()), id: \.element.id) { i, d in
                let appear = 0.30 + Double(i) * 0.08
                let p = firstLoop ? prog(t, appear, appear + 0.38, reduceMotion ? .easeOut : .spring) : 1
                let o = firstLoop ? prog(t, appear, appear + 0.2) : 1
                DemoBubble(device: d, targeted: i == 1 && t >= 3.2 && t < 3.5, status: i == 1 ? status1 : .idle,
                           checkVisible: t < 6.2)
                    .overlay(alignment: .top) {
                        if d.viaTaildrop && badgePulse > 1 {
                            Image(systemName: "arrow.down.circle.fill")
                                .font(.system(size: 58 * 0.2, weight: .semibold))
                                .foregroundStyle(.secondary)
                                .frame(width: 58 * 0.38, height: 58 * 0.38)
                                .background(Circle().fill(.regularMaterial))
                                .overlay(Circle().strokeBorder(.separator, lineWidth: 0.5))
                                .scaleEffect(badgePulse)
                                .offset(x: 21, y: 46)   // over the real badge (avatar centre + 21/21)
                        }
                    }
                    .scaleEffect(lerp(min(1, p), 0.7, 1))
                    .offset(y: lerp(min(1, p), 10, 0))
                    .opacity(o)
                    .position(x: bubbleX(i), y: top + DemoBubble.height / 2)
            }

            // Two rows so the labels (≈150 pt) never collide (bubbles are 92 pt apart).
            callout(OnboardingStrings.calloutOther, x: bubbleX(0), at: 1.0, t: t, dim: calloutDim, line: 22)
            callout(OnboardingStrings.calloutTaildrop, x: bubbleX(3), at: 1.3, t: t, dim: calloutDim, line: 62)
            callout(OnboardingStrings.calloutMine, x: bubbleX(2), at: 1.6, t: t, dim: calloutDim, line: 22)

            if pointerOpacity > 0 {
                MockPointer(dragging: t < 3.75 ? AnyView(DemoThumb(kind: .folder).opacity(1 - prog(t, 3.5, 3.75, .easeIn))
                    .scaleEffect(lerp(prog(t, 3.5, 3.75, .easeIn), 1, 0.2))) : nil)
                    .opacity(pointerOpacity)
                    .position(x: pos.x + 12, y: pos.y + 12)
            }
        }
        .opacity(fadeAll)
    }

    @ViewBuilder
    private func callout(_ text: (String, String), x: CGFloat, at start: TimeInterval, t: TimeInterval, dim: Double, line: CGFloat) -> some View {
        let o = prog(t, start, start + 0.2) * dim
        if o > 0 {
            VStack(spacing: 4) {
                Rectangle().fill(Color.secondary.opacity(0.4)).frame(width: 1, height: line)
                Text(text.0).font(.system(size: 11, weight: .medium)).foregroundStyle(.primary)
                Text(text.1).font(.system(size: 10)).foregroundStyle(.secondary)
            }
            .frame(width: 150)
            .opacity(o)
            .position(x: x, y: top + DemoBubble.height + 4 + (line + 33) / 2)
        }
    }
}

// MARK: - Page 3: Cards

struct CardsStage: View {
    let elapsed: TimeInterval
    var reduceMotion = false

    static let loop: TimeInterval = 9.4
    static let height: CGFloat = 310
    private let cardX: CGFloat = 720 - 352 - 10
    private let cardY: CGFloat = 24 + 10

    /// Status line that ticks every 0.25 s like the real card.
    private func status(start: TimeInterval, end: TimeInterval, t: TimeInterval, speed: String, totalSeconds: Double) -> String {
        let q = floor((t - start) / 0.25) * 0.25
        let f = prog(start + q, start, end, .easeInOut)
        let bytes = Int64(f * 2_400_000_000)
        let remaining = max(1, Int(((1 - f) * totalSeconds).rounded()))
        return "\(ByteFormat.string(bytes)) von 2.4 GB · \(speed) · noch \(remaining) s"
    }

    var body: some View {
        let t = elapsed.truncatingRemainder(dividingBy: Self.loop)
        let fadeAll = 1 - prog(t, 8.6, 8.8)
        let card1In = prog(t, 0.6, 1.05, reduceMotion ? .easeOut : .spring)
        let card2In = prog(t, 6.0, 6.45, reduceMotion ? .easeOut : .spring)
        let f1 = prog(t, 2.6, 4.6, .easeInOut)
        let f2 = prog(t, 6.0, 7.4, .easeInOut)
        let mode1: DemoIncomingCard.Mode = t < 2.6 ? .decision(pressed: t >= 2.45 && t < 2.57)
            : (t < 4.7 ? .progress(f1, status(start: 2.6, end: 4.6, t: t, speed: "240 MB/s", totalSeconds: 10)) : .finished(isFolder: true))
        let mode2: DemoIncomingCard.Mode = t < 7.5 ? .progress(f2, status(start: 6.0, end: 7.4, t: t, speed: "640 MB/s", totalSeconds: 4))
            : .finished(isFolder: false)
        let accept = CGPoint(x: 618, y: 110)
        let move = prog(t, 1.8, 2.4)
        let drift = prog(t, 2.6, 3.4)
        let pos = t < 2.6 ? CGPoint(x: lerp(move, 520, accept.x), y: lerp(move, 300, accept.y))
                          : CGPoint(x: lerp(drift, accept.x, 600), y: lerp(drift, accept.y, 320))
        let pointerOpacity = prog(t, 1.8, 1.95) * (1 - prog(t, 3.1, 3.4))
        let bounce = reduceMotion ? 0 : (t >= 4.8 && t < 5.6 ? -12 * abs(sin((t - 4.8) / 0.8 * 2 * .pi)) : 0)

        ZStack(alignment: .topLeading) {
            MenuBarStrip(active: t >= 0.6 && t < 0.9)

            VStack(alignment: .trailing, spacing: 8) {
                if t >= 0.6 {
                    DemoIncomingCard(peerName: "Noahs MacBook Pro", peerSymbol: "laptopcomputer", what: "Projekt-Export", size: "2.4 GB", mode: mode1)
                        .offset(x: lerp(card1In, 380, 0))
                        .opacity(prog(t, 0.6, 0.8))
                }
                if t >= 6.0 {
                    DemoIncomingCard(peerName: "MacBook Pro von Sara", peerSymbol: "laptopcomputer", what: "Ferien 2026", size: "2.4 GB",
                                     mode: mode2, mine: true, badge: OnboardingStrings.receiveDemoBadge)
                        .offset(x: lerp(card2In, 380, 0))
                        .opacity(prog(t, 6.0, 6.2))
                }
            }
            .frame(width: 352)
            .offset(x: cardX, y: cardY)

            // Mini Dock with the Downloads stack
            HStack(spacing: 10) {
                dockTile("square.grid.3x3.fill", colors: [Color(white: 0.55), Color(white: 0.35)])
                dockTile("arrow.down.circle.fill", colors: OnboardingTokens.brand).offset(y: bounce)
                dockTile("trash.fill", colors: [Color(white: 0.6), Color(white: 0.4)])
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(.regularMaterial))
            .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(.white.opacity(0.2), lineWidth: 0.5))
            .position(x: 360, y: Self.height - 36)

            if pointerOpacity > 0 {
                MockPointer().opacity(pointerOpacity).position(x: pos.x + 12, y: pos.y + 12)
            }
        }
        .opacity(fadeAll)
    }

    private func dockTile(_ symbol: String, colors: [Color]) -> some View {
        RoundedRectangle(cornerRadius: 10, style: .continuous)
            .fill(LinearGradient(colors: colors, startPoint: .top, endPoint: .bottom))
            .overlay(Image(systemName: symbol).font(.system(size: 22, weight: .medium)).foregroundStyle(.white))
            .frame(width: 44, height: 44)
            .shadow(color: .black.opacity(0.2), radius: 3, y: 2)
    }
}

// MARK: - Page 4: Keys

struct KeysStage: View {
    let elapsed: TimeInterval
    var reduceMotion = false

    static let loop: TimeInterval = 7.6
    static let height: CGFloat = 220
    private let shelfScale: CGFloat = 0.56
    private let keysCenter = CGPoint(x: 215, y: 126)
    private let shelfACenter = CGPoint(x: 520, y: 124)
    private let iconX: CGFloat = 620

    private var shelfBCenter: CGPoint {
        let w = DemoShelf.size.width * shelfScale, h = DemoShelf.size.height * shelfScale
        return CGPoint(x: min(iconX, 720 - 8 - w / 2), y: 30 + h / 2)
    }

    private var stackB: CGPoint {
        let local = DemoShelf.stackCenter
        return CGPoint(x: shelfBCenter.x + (local.x - DemoShelf.size.width / 2) * shelfScale,
                       y: shelfBCenter.y + (local.y - DemoShelf.size.height / 2) * shelfScale)
    }

    var body: some View {
        let t = elapsed.truncatingRemainder(dividingBy: Self.loop)
        let pressed = Set((0..<4).filter { t >= 0.50 + Double($0) * 0.08 && t < 1.6 })
        let keysOpacity = lerp(prog(t, 3.0, 3.25), 1, 0.4) * (1 - prog(t, 7.2, 7.6)) + prog(t, 7.2, 7.6)
        let shelfAIn = prog(t, 0.95, 1.3, reduceMotion ? .easeOut : .spring)
        let shelfAOpacity = prog(t, 0.95, 1.1) * (1 - prog(t, 3.0, 3.2))
        let toIcon = prog(t, 3.4, 4.3)
        let toStack = prog(t, 4.4, 4.9)
        let icon = CGPoint(x: iconX - 6, y: 4)
        let pos = t < 4.4 ? CGPoint(x: lerp(toIcon, 150, icon.x), y: lerp(toIcon, 175, icon.y))
                          : CGPoint(x: lerp(toStack, icon.x, stackB.x - 6), y: lerp(toStack, icon.y, stackB.y - 6))
        let pointerOpacity = prog(t, 3.4, 3.55) * (1 - prog(t, 6.2, 6.45))
        let shelfBIn = prog(t, 4.3, 4.65, reduceMotion ? .easeOut : .spring)
        let shelfBOpacity = prog(t, 4.3, 4.45) * (1 - prog(t, 6.2, 6.4))
        let dropped = t >= 5.0
        let thumbShrink = prog(t, 5.0, 5.2, .easeIn)

        ZStack(alignment: .topLeading) {
            MenuBarStrip(highlighted: t >= 4.3 && t < 6.2, iconX: iconX)

            KeyComboView(["⌃", "⌥", "⌘", "B"], size: 56, spacing: 10, pressed: pressed)
                .opacity(keysOpacity)
                .position(keysCenter)

            if shelfAOpacity > 0 {
                DemoShelf(devices: OnboardingMocks.shelfDevices, files: [OnboardingMocks.notes, OnboardingMocks.logo], summary: "2 Objekte · 1.3 MB")
                    .scaleEffect(shelfScale * lerp(shelfAIn, 0.9, 1))
                    .opacity(shelfAOpacity)
                    .position(shelfACenter)
            }

            if shelfBOpacity > 0 {
                DemoShelf(devices: OnboardingMocks.shelfDevices, files: dropped ? [OnboardingMocks.video] : [],
                          summary: "Ferien-Video.mov · 4.2 GB", stackTargeted: t >= 4.75 && t < 5.0)
                    .scaleEffect(shelfScale)
                    .opacity(shelfBOpacity)
                    .position(x: shelfBCenter.x, y: shelfBCenter.y + lerp(shelfBIn, -10, 0))
            }

            if pointerOpacity > 0 {
                MockPointer(dragging: t < 5.2 ? AnyView(DemoThumb(kind: .video, size: 48)
                    .scaleEffect(lerp(thumbShrink, 1, 0.2)).opacity(1 - thumbShrink)) : nil)
                    .opacity(pointerOpacity)
                    .position(x: pos.x + 12, y: pos.y + 12)
            }
        }
    }
}

// MARK: - Page 5: Live

struct LiveStage: View {
    let elapsed: TimeInterval
    let devices: [Device]
    let real: Bool
    let caption: String
    var reduceMotion = false

    static let loop: TimeInterval = 5.0
    static let height: CGFloat = 256
    private let center = CGPoint(x: 360, y: 134)

    private func pos(_ i: Int) -> CGPoint {
        let n = max(1, devices.count)
        let a = (n == 1 ? 0 : -90 + 180 / Double(n) + 360 * Double(i) / Double(n)) * .pi / 180   // one device sits to the right
        return CGPoint(x: center.x + 230 * cos(a), y: center.y + 78 * sin(a))
    }

    var body: some View {
        let firstLoop = elapsed < Self.loop
        let t = elapsed.truncatingRemainder(dividingBy: Self.loop)
        let iconScale = firstLoop ? lerp(prog(t, 0, 0.5, reduceMotion ? .easeOut : .spring), 0.92, 1) : 1
        let beamFade = (1 - prog(t, 4.6, 5.0))

        ZStack {
            if !reduceMotion {
                let phase = elapsed.truncatingRemainder(dividingBy: 2.5)
                let p = prog(phase, 0, 2.0, .easeOut)
                Ellipse()
                    .stroke(Color.primary.opacity(0.18), lineWidth: 1)
                    .frame(width: lerp(p, 120, 520), height: lerp(p, 120, 200))
                    .opacity(phase < 2.0 ? 0.5 * (1 - p) : 0)
                    .position(center)
            }

            ForEach(Array(devices.enumerated()), id: \.element.id) { i, d in
                let to = pos(i)
                let dx = to.x - center.x, dy = to.y - center.y
                let len = max(1, hypot(dx, dy))
                let u = CGPoint(x: dx / len, y: dy / len)
                let a = CGPoint(x: center.x + u.x * 54, y: center.y + u.y * 54)
                let b = CGPoint(x: to.x - u.x * 26, y: to.y - u.y * 26)
                let start = 1.2 + Double(i) * 0.15
                let draw = prog(t, start, start + 0.4, .easeOut)
                Path { p in p.move(to: a); p.addLine(to: b) }
                    .trim(from: 0, to: draw)
                    .stroke(OnboardingTokens.brandGradient, style: StrokeStyle(lineWidth: 2, lineCap: .round))
                    .opacity(lerp(prog(t, start + 0.4, start + 0.9), 1, 0.4) * beamFade)

                let appear = 0.2 + Double(i) * 0.07
                let p = firstLoop ? prog(t, appear, appear + 0.4, reduceMotion ? .easeOut : .spring) : 1
                VStack(spacing: 4) {
                    DeviceAvatar(device: d, size: 44)
                    Text(d.name).font(.system(size: 10, weight: .medium)).lineLimit(1).frame(width: 96)
                }
                .opacity(real ? 1 : 0.6)
                .scaleEffect(lerp(min(1, p), 0.6, 1))
                .opacity(firstLoop ? prog(t, appear, appear + 0.2) : 1)
                .position(x: to.x, y: to.y + 9)
            }

            AppIconView(size: 96, shadow: false)
                .shadow(color: .black.opacity(0.25), radius: 12, y: 6)
                .scaleEffect(iconScale)
                .position(center)

            Text(caption)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 10)
                .frame(height: 22)
                .background(Capsule().fill(.regularMaterial))
                .opacity(prog(t, 0.8, 1.0))
                .position(x: center.x, y: 22)
        }
    }
}
