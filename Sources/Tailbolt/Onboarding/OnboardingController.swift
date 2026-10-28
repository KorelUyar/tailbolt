import AppKit
import Observation
import SwiftUI
import TailboltCore

enum OnboardingPage: Int, CaseIterable {
    case welcome, tailscale, send, devices, receive, shortcuts, ready

    /// Height of the demo stage; the text block gets the rest of the 600 pt window.
    var stageHeight: CGFloat {
        switch self {
        case .welcome, .tailscale: return 340
        case .send, .devices: return 320
        case .receive: return CardsStage.height
        case .shortcuts: return KeysStage.height
        case .ready: return LiveStage.height
        }
    }

    static let dotted: [OnboardingPage] = [.welcome, .send, .devices, .receive, .shortcuts, .ready]
    var dotIndex: Int { self == .tailscale ? 0 : OnboardingPage.dotted.firstIndex(of: self) ?? 0 }
}

enum NavDirection { case forward, back }

/// Everything the onboarding views read. Owned by `OnboardingController`; a fresh one per show().
@MainActor @Observable
final class OnboardingState {
    var page: OnboardingPage = .welcome
    var direction: NavDirection = .forward
    var visited: Set<OnboardingPage> = [.welcome]
    var tailscaleNeedsSetup = false
    var tailscaleConnected = false
    var launchAtLoginWanted = true
    var quickActionInstalled = false
    var shelfOpened = false
    var inviteCopied = false
    var hoveringButton = false
    var isWindowKey = true
    var reduceMotion = false
    /// Set by `--snapshot`: stages render this exact time instead of animating.
    var frozenTime: TimeInterval?

    var isRunning: Bool { isWindowKey && frozenTime == nil }
    var visiblePages: [OnboardingPage] { OnboardingPage.allCases.filter { $0 != .tailscale || tailscaleNeedsSetup } }

    func next(after p: OnboardingPage) -> OnboardingPage? {
        visiblePages.first { $0.rawValue > p.rawValue }
    }

    func previous(before p: OnboardingPage) -> OnboardingPage? {
        visiblePages.last { $0.rawValue < p.rawValue }
    }
}

/// First-run setup assistant. One window, ever; `showIfNeeded()` on launch, `show()` from settings.
@MainActor
final class OnboardingController: NSObject, NSWindowDelegate {
    static let shared = OnboardingController()
    static let currentVersion = 1
    static let completedKey = "onboardingCompletedVersion"
    static let lastPageKey = "onboardingLastPage"
    static let resumeKey = "onboardingResumed"

    // MARK: hooks the app wires (safe defaults so the window works stand-alone)

    /// Installs the Finder Quick Action ("Mit Tailbolt senden"). nil = not available yet.
    var quickActionInstaller: (() -> Void)?
    /// Whether the Quick Action is installed; default checks ~/Library/Services.
    var isQuickActionInstalled: () -> Bool = {
        FileManager.default.fileExists(atPath: NSHomeDirectory() + "/Library/Services/Mit Tailbolt senden.workflow")
    }
    /// Called 0.4 s after "Fertig" closed the window (main.swift opens the menu-bar popover).
    var onFinished: (() -> Void)?
    /// Link copied by "Einladungslink kopieren".
    var downloadURL = URL(string: "https://github.com/KorelUyar/tailbolt/releases/latest")!

    private(set) var state = OnboardingState()
    private var window: OnboardingWindow?
    private var pollTimer: Timer?
    private var shelfTimer: Timer?
    private var deferTimer: Timer?
    private var advanceWork: DispatchWorkItem?

    var isVisible: Bool { window?.isVisible == true }

    private var defaults: UserDefaults { .standard }
    var isCompleted: Bool { defaults.integer(forKey: Self.completedKey) >= Self.currentVersion }

    // MARK: launch integration

    /// First launch only (`onboardingCompletedVersion` < current). `--onboarding` forces it,
    /// `--no-onboarding` suppresses it. Waits for the shelf to close if files arrived in the same launch.
    func showIfNeeded() {
        let args = CommandLine.arguments
        if args.contains("--onboarding") { show(); return }
        guard !args.contains("--no-onboarding"), !isCompleted else { return }

        var start: OnboardingPage = .welcome
        let last = defaults.integer(forKey: Self.lastPageKey)
        if let p = OnboardingPage(rawValue: last), p != .welcome {
            if defaults.bool(forKey: Self.resumeKey) {   // quit mid-flow twice → leave the user alone
                markCompleted()
                return
            }
            defaults.set(true, forKey: Self.resumeKey)
            start = p
        }
        deferTimer?.invalidate()
        deferTimer = Timer.scheduledTimer(withTimeInterval: 0.4, repeats: true) { [weak self] timer in
            MainActor.assumeIsolated {
                guard let self else { timer.invalidate(); return }
                if ShelfController.shared.isVisible { return }   // files arrived first; the shelf has priority
                timer.invalidate()
                self.deferTimer = nil
                self.show(startingAt: start)
            }
        }
    }

    /// Shows the assistant from the first page (settings "Einführung erneut anzeigen").
    func show() { show(startingAt: .welcome) }

    private func show(startingAt start: OnboardingPage) {
        deferTimer?.invalidate(); deferTimer = nil
        if let window, window.isVisible {
            NSApp.activate(ignoringOtherApps: true)
            window.makeKeyAndOrderFront(nil)
            return
        }
        OnboardingMocks.prepareFiles()
        let state = OnboardingState()
        state.reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        state.launchAtLoginWanted = true
        state.quickActionInstalled = isQuickActionInstalled()
        self.state = state
        refreshTailscale()
        let visible = state.visiblePages
        state.page = visible.contains(start) ? start : .welcome
        state.visited = Set(visible.prefix(through: visible.firstIndex(of: state.page) ?? 0))

        let window = OnboardingWindow(controller: self)
        let hosting = NSHostingView(rootView: OnboardingView(state: state))
        hosting.sizingOptions = []   // the window is exactly 720×600; never let the title-bar inset grow it
        hosting.autoresizingMask = [.width, .height]
        window.contentView = hosting
        self.window = window
        AppModel.shared.visibleSurfaces += 1
        startTimers()

        NSApp.activate(ignoringOtherApps: true)
        window.alphaValue = 0
        window.makeKeyAndOrderFront(nil)
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.2
            window.animator().alphaValue = 1
        }
    }

    // MARK: navigation

    func next() {
        guard let n = state.next(after: state.page) else { finish(); return }
        go(to: n, direction: .forward)
    }

    func back() {
        guard let p = state.previous(before: state.page) else { return }
        go(to: p, direction: .back)
    }

    /// Dots: only pages already seen, or the next one.
    func canJump(toDot i: Int) -> Bool {
        guard let page = OnboardingPage.dotted[safe: i] else { return false }
        let target = page == .welcome && state.tailscaleNeedsSetup && state.page != .welcome ? OnboardingPage.tailscale : page
        return state.visited.contains(target) || state.next(after: state.page) == target
    }

    func jump(toDot i: Int) {
        guard canJump(toDot: i), let page = OnboardingPage.dotted[safe: i], page != state.page else { return }
        go(to: page, direction: page.rawValue > state.page.rawValue ? .forward : .back)
    }

    private func go(to page: OnboardingPage, direction: NavDirection) {
        advanceWork?.cancel()
        state.direction = direction
        // Direction first (non-animated) so the outgoing view picks up the matching transition edge.
        DispatchQueue.main.async { [self] in
            withAnimation(state.reduceMotion ? .easeInOut(duration: 0.2) : .spring(response: 0.42, dampingFraction: 0.88)) {
                state.page = page
            }
            state.visited.insert(page)
            if page != .welcome { defaults.set(page.rawValue, forKey: Self.lastPageKey) }
            startTimers()
        }
    }

    /// Überspringen / close button / Escape.
    func skip() {
        markCompleted()
        close(fade: 0.15)
    }

    /// Fertig: apply the consented settings, persist, close, then show where Tailbolt lives.
    func finish() {
        let s = Settings.shared
        if s.launchAtLogin != state.launchAtLoginWanted { s.launchAtLogin = state.launchAtLoginWanted }
        markCompleted()
        close(fade: 0.2)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [self] in onFinished?() }
    }

    func installQuickAction() {
        quickActionInstaller?()
        state.quickActionInstalled = isQuickActionInstalled()
    }

    func copyInviteLink() {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(downloadURL.absoluteString, forType: .string)
        state.inviteCopied = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [self] in state.inviteCopied = false }
    }

    private func markCompleted() {
        defaults.set(Self.currentVersion, forKey: Self.completedKey)
        defaults.removeObject(forKey: Self.lastPageKey)
        defaults.removeObject(forKey: Self.resumeKey)
    }

    private func close(fade: TimeInterval) {
        guard let window else { return }
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = fade
            window.animator().alphaValue = 0
        }, completionHandler: {
            MainActor.assumeIsolated { window.close() }
        })
    }

    // MARK: timers (status polling on page 0/0b, shelf watching on page 1)

    private func startTimers() {
        pollTimer?.invalidate(); pollTimer = nil
        shelfTimer?.invalidate(); shelfTimer = nil
        switch state.page {
        case .welcome, .tailscale:
            pollTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated {
                    AppModel.shared.refresh()
                    self?.refreshTailscale()
                }
            }
        case .send:
            shelfTimer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self, !self.state.shelfOpened, ShelfController.shared.isVisible else { return }
                    withAnimation(.spring(response: 0.35, dampingFraction: 0.75)) { self.state.shelfOpened = true }
                }
            }
        default:
            break
        }
    }

    private func refreshTailscale() {
        let app = AppModel.shared
        let running = app.status?.running == true
        let needsSetup = app.hasRefreshed && (Tailnet.cliPath == nil || app.status == nil || !running)
        // Only re-evaluated on the welcome page; while 0b is showing it stays in the flow (auto-advance handles success).
        if needsSetup != state.tailscaleNeedsSetup, state.page == .welcome {
            state.tailscaleNeedsSetup = needsSetup
        }
        if state.page == .tailscale && running && !state.tailscaleConnected {
            withAnimation(.spring(response: 0.4, dampingFraction: 0.8)) { state.tailscaleConnected = true }
            let work = DispatchWorkItem { [weak self] in
                guard let self, self.state.page == .tailscale, !self.state.hoveringButton else { return }
                self.next()
            }
            advanceWork = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.2, execute: work)
        }
    }

    // MARK: dev tour (`Tailbolt --onboarding-preview <dir>`)

    /// Walks every page with simulated key presses (→, one ←, Esc on the last page), writing a PNG of
    /// the real window (frame view, so the title-bar buttons are included) after each step, then quits.
    func debugTour(dir: URL) {
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        var step = 0
        var wentBack = false
        func capture(_ suffix: String) {
            guard let window, let frameView = window.contentView?.superview,
                  let rep = frameView.bitmapImageRepForCachingDisplay(in: frameView.bounds) else { return }
            frameView.cacheDisplay(in: frameView.bounds, to: rep)
            try? rep.representation(using: .png, properties: [:])?.write(to: dir.appendingPathComponent("tour-\(step)-\(suffix).png"))
        }
        func key(_ code: UInt16) {
            guard let window, let e = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
                                                       windowNumber: window.windowNumber, context: nil, characters: "",
                                                       charactersIgnoringModifiers: "", isARepeat: false, keyCode: code) else { return }
            window.keyDown(with: e)
        }
        func tick() {
            capture("\(state.page)")
            step += 1
            if state.page == .ready {
                state.launchAtLoginWanted = Settings.shared.launchAtLogin   // the tour must not touch login items
                key(53)                                                     // Esc on the last page = Fertig
                DispatchQueue.main.asyncAfter(deadline: .now() + 1) { exit(0) }
                return
            }
            if state.page == .devices && !wentBack { wentBack = true; key(123) } else { key(124) }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) { capture("transition") }
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.0, execute: tick)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0, execute: tick)
    }

    // MARK: NSWindowDelegate

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        if !isCompleted { markCompleted() }   // red button / ⌘W = skip
        return true
    }

    func windowWillClose(_ notification: Notification) {
        pollTimer?.invalidate(); pollTimer = nil
        shelfTimer?.invalidate(); shelfTimer = nil
        advanceWork?.cancel()
        AppModel.shared.visibleSurfaces -= 1
        OnboardingMocks.removeFiles()
        window = nil
    }

    func windowDidBecomeKey(_ notification: Notification) { state.isWindowKey = true }
    func windowDidResignKey(_ notification: Notification) { state.isWindowKey = false }

    // MARK: keys

    /// → / ⌘→ / ↩ = Weiter · ← / ⌘← = Zurück · Esc / ⌘. = Überspringen (page 5: Fertig).
    fileprivate func handle(_ event: NSEvent) -> Bool {
        if let r = window?.firstResponder, r is NSTextView { return false }
        let cmd = event.modifierFlags.contains(.command)
        switch event.keyCode {
        case 124: next(); return true                       // →
        case 123: back(); return true                       // ←
        case 36, 76: next(); return true                    // ↩ / enter
        case 53: state.page == .ready ? finish() : skip(); return true   // esc
        case 47 where cmd: state.page == .ready ? finish() : skip(); return true   // ⌘.
        default: return false
        }
    }
}

final class OnboardingWindow: NSWindow {
    private weak var controller: OnboardingController?

    @MainActor
    init(controller: OnboardingController) {
        self.controller = controller
        let size = NSSize(width: OnboardingTokens.windowWidth, height: OnboardingTokens.windowHeight)
        super.init(contentRect: NSRect(origin: .zero, size: size), styleMask: [.titled, .closable, .fullSizeContentView],
                   backing: .buffered, defer: false)
        title = "Willkommen bei Tailbolt"
        titlebarAppearsTransparent = true
        titleVisibility = .hidden
        standardWindowButton(.miniaturizeButton)?.isHidden = true
        standardWindowButton(.zoomButton)?.isHidden = true
        isMovableByWindowBackground = true
        isReleasedWhenClosed = false
        backgroundColor = .windowBackgroundColor
        collectionBehavior = [.moveToActiveSpace]
        level = .normal
        delegate = controller
        // Full-size content: the whole 720×600 frame is ours, the title bar only hosts the close button.
        var frame = NSRect(origin: .zero, size: size)
        if let screen = NSScreen.main ?? NSScreen.screens.first {
            let vf = screen.visibleFrame
            frame.origin = NSPoint(x: (vf.midX - size.width / 2).rounded(), y: (vf.midY - size.height / 2 + 20).rounded())
        }
        setFrame(frame, display: false)
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }

    override func keyDown(with event: NSEvent) {
        if MainActor.assumeIsolated({ controller?.handle(event) == true }) { return }
        super.keyDown(with: event)
    }
}

extension Array {
    subscript(safe i: Int) -> Element? { indices.contains(i) ? self[i] : nil }
}
