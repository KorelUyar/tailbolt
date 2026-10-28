import AppKit
import Observation
import SwiftUI
import TailboltCore

/// What the HUD capsule shows right now.
@MainActor @Observable
final class ToastModel {
    enum Tone { case progress, success, error, info }

    var tone: Tone = .info
    var symbol = "info.circle"
    var title = ""
    var detail: String?
    /// nil hides the bar; `indeterminate` pulses it.
    var fraction: Double?
    var indeterminate = false

    func set(tone: Tone, symbol: String, title: String, detail: String? = nil, fraction: Double? = nil, indeterminate: Bool = false) {
        self.tone = tone
        self.symbol = symbol
        self.title = title
        self.detail = detail
        self.fraction = fraction
        self.indeterminate = indeterminate
    }
}

/// Never key, never main – it is pure feedback.
final class HUDPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

/// Volume-HUD-style capsule near the top centre of the main screen. The only UI the zero-click
/// paths (hotkey → last device / favorite) ever show. It never takes focus and ignores the mouse.
@MainActor
final class ToastController {
    static let shared = ToastController()

    let model = ToastModel()
    private var panel: HUDPanel?
    private var hosting: NSHostingView<ToastView>?
    private var timer: Timer?
    private var hideWork: DispatchWorkItem?
    private weak var tracked: TransferItem?

    /// One-off message, e.g. "Favorit 3 ist nicht belegt".
    func flash(_ title: String, symbol: String = "info.circle", tone: ToastModel.Tone = .info, duration: TimeInterval = 2) {
        guard Settings.shared.hudEnabled else { return }
        tracked = nil
        stopTimer()
        model.set(tone: tone, symbol: symbol, title: title)
        present()
        scheduleHide(after: duration)
    }

    /// Follows a transfer until it ends, then fades out by itself.
    func track(_ item: TransferItem) {
        guard Settings.shared.hudEnabled else { return }
        tracked = item
        hideWork?.cancel()
        apply(item)
        present()
        if timer == nil {
            timer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.tick() }
            }
        }
    }

    private func tick() {
        guard let item = tracked else { stopTimer(); return }
        apply(item)
        layout()
        if item.state.isTerminal {
            tracked = nil
            stopTimer()
            scheduleHide(after: item.state == .finished ? 2 : 3.5)
        }
    }

    private func apply(_ item: TransferItem) {
        let what = item.names.count == 1 ? "«\(item.names[0])»" : "\(item.names.count) Objekte"
        let to = "→ \(item.peerName)"
        switch item.state {
        case .preparing:
            model.set(tone: .progress, symbol: "arrow.up.right", title: to, detail: "Vorbereiten…", indeterminate: true)
        case .waiting:
            model.set(tone: .progress, symbol: "arrow.up.right", title: to, detail: "Warten auf Annahme…", indeterminate: true)
        case .transferring:
            if item.taildrop != nil {
                model.set(tone: .progress, symbol: "arrow.up.right", title: to, detail: "Sende \(what) via Taildrop…", indeterminate: true)
            } else {
                var d = "Sende \(what) · \(Int(item.fraction * 100)) %"
                if item.speed > 0 { d += " · \(ByteFormat.speed(item.speed))" }
                model.set(tone: .progress, symbol: "arrow.up.right", title: to, detail: d, fraction: item.fraction)
            }
        case .finishing:
            model.set(tone: .progress, symbol: "arrow.up.right", title: to, detail: "Abschliessen…", fraction: 1)
        case .finished:
            model.set(tone: .success, symbol: "checkmark.circle.fill", title: "Gesendet an \(item.peerName)", detail: ByteFormat.string(item.totalBytes))
        case .declined(let reason):
            model.set(tone: .error, symbol: "xmark.circle.fill", title: "Abgelehnt", detail: reason ?? "von \(item.peerName)")
        case .failed(let reason):
            model.set(tone: .error, symbol: "xmark.circle.fill", title: "Fehler", detail: reason)
        case .cancelled(let reason):
            model.set(tone: .info, symbol: "minus.circle.fill", title: "Abgebrochen", detail: reason)
        }
    }

    private func present() {
        hideWork?.cancel()
        let panel = self.panel ?? makePanel()
        self.panel = panel
        layout()
        guard !panel.isVisible || panel.alphaValue < 1 else { return }
        var frame = panel.frame
        frame.origin.y += 10
        panel.setFrame(frame, display: false)
        panel.alphaValue = 0
        panel.orderFrontRegardless()
        frame.origin.y -= 10
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.18
            ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
            panel.animator().alphaValue = 1
            panel.animator().setFrame(frame, display: true)
        }
    }

    private func scheduleHide(after seconds: TimeInterval) {
        hideWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.hide() }
        hideWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds, execute: work)
    }

    private func hide() {
        guard let panel, panel.isVisible else { return }
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.25
            panel.animator().alphaValue = 0
        }, completionHandler: {
            MainActor.assumeIsolated {
                if panel.alphaValue == 0 { panel.orderOut(nil) }
            }
        })
    }

    private func stopTimer() {
        timer?.invalidate()
        timer = nil
    }

    private func layout() {
        guard let panel, let hosting else { return }
        hosting.layoutSubtreeIfNeeded()
        let size = hosting.fittingSize
        let screen = NSScreen.main ?? NSScreen.screens[0]
        let vf = screen.visibleFrame
        let frame = NSRect(x: round(vf.midX - size.width / 2), y: vf.maxY - size.height - 10, width: size.width, height: size.height)
        if panel.frame.size != frame.size || (panel.alphaValue == 1 && panel.frame != frame) {
            panel.setFrame(frame, display: true)
        }
    }

    private func makePanel() -> HUDPanel {
        let p = HUDPanel(contentRect: NSRect(x: 0, y: 0, width: 280, height: 40),
                         styleMask: [.borderless, .nonactivatingPanel, .fullSizeContentView],
                         backing: .buffered, defer: false)
        p.isFloatingPanel = true
        p.level = .statusBar
        p.hidesOnDeactivate = false
        p.ignoresMouseEvents = true
        p.backgroundColor = .clear
        p.isOpaque = false
        p.hasShadow = true
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        let h = NSHostingView(rootView: ToastView(model: model))
        h.sizingOptions = []
        p.contentView = h
        hosting = h
        return p
    }
}

struct ToastView: View {
    var model: ToastModel

    var body: some View {
        HStack(spacing: 9) {
            Image(systemName: model.symbol)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(color)
                .frame(width: 16)
                .contentTransition(.symbolEffect(.replace))
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(model.title)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(model.tone == .error ? Color.red : Color.primary)
                        .lineLimit(1)
                    if let d = model.detail {
                        Text(d)
                            .font(.system(size: 12))
                            .foregroundStyle(model.tone == .error ? Color.red.opacity(0.8) : Color.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                }
                if model.fraction != nil || model.indeterminate {
                    Bar(value: model.indeterminate ? nil : model.fraction)
                        .frame(height: 3)
                }
            }
        }
        .padding(.leading, 13)
        .padding(.trailing, 16)
        .padding(.vertical, model.fraction != nil || model.indeterminate ? 8 : 9)
        .frame(minWidth: 200, maxWidth: 420)
        .fixedSize()
        .glassCapsule(material: .hudWindow)
        .animation(.easeOut(duration: 0.15), value: model.title)
    }

    private var color: Color {
        switch model.tone {
        case .progress: return .accentColor
        case .success: return .green
        case .error: return .red
        case .info: return .secondary
        }
    }
}
