import AppKit
import Carbon.HIToolbox
import Observation

/// System-wide "is a file drag going on right now?" plus the gesture triggers that hang off it.
///
/// A global mouse-down monitor arms a 60 Hz poller that lives only while the button is held. As soon as
/// the drag pasteboard carries file URLs, `isDraggingFiles` flips (menu-bar halo, drop zone in the shelf)
/// and every registered sampler sees the cursor position each tick – the shake detector and the
/// hold-⇧ trigger are such samplers. Nothing here needs Accessibility permission.
@MainActor @Observable
final class DragState {
    static let shared = DragState()

    /// True while the mouse button is down and the drag pasteboard holds file URLs.
    private(set) var isDraggingFiles = false
    /// Cursor position of the latest sample (screen coordinates); not observed – it changes 60×/s.
    @ObservationIgnored private(set) var location: NSPoint = .zero

    @ObservationIgnored private var monitors: [Any] = []
    @ObservationIgnored private var poller: Timer?
    @ObservationIgnored private var dragCountAtDown = 0
    @ObservationIgnored private var samplers: [ObjectIdentifier: (NSPoint) -> Void] = [:]
    @ObservationIgnored private var onDragStart: [ObjectIdentifier: () -> Void] = [:]
    @ObservationIgnored private var onDragEnd: [ObjectIdentifier: () -> Void] = [:]

    /// Open the shelf when ⇧ was held for 250 ms during a file drag (Settings.shiftDragTrigger).
    /// Default action: shelf under the cursor, exactly like the shake.
    @ObservationIgnored var onShiftTrigger: ((NSPoint) -> Void)? = { point in
        ShelfController.shared.show(at: point)
    }
    @ObservationIgnored private var shiftSince: TimeInterval?
    @ObservationIgnored private var shiftFired = false
    private let shiftHold: TimeInterval = 0.25

    /// Installs the mouse-down monitors; idempotent and cheap (the poller only runs while a button is held).
    /// Global monitors never see our own windows' events, so a local one covers drags that start in the shelf.
    func start() {
        guard monitors.isEmpty else { return }
        if let g = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown], handler: { [weak self] _ in
            MainActor.assumeIsolated { self?.arm() }
        }) { monitors.append(g) }
        if let l = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown], handler: { [weak self] event in
            MainActor.assumeIsolated { self?.arm() }
            return event
        }) { monitors.append(l) }
    }

    func stop() {
        monitors.forEach { NSEvent.removeMonitor($0) }
        monitors.removeAll()
        poller?.invalidate()
        poller = nil
        endDrag()
    }

    // MARK: clients

    func addSampler(_ owner: AnyObject, onStart: (() -> Void)? = nil, onEnd: (() -> Void)? = nil, _ sample: @escaping (NSPoint) -> Void) {
        let key = ObjectIdentifier(owner)
        samplers[key] = sample
        onDragStart[key] = onStart
        onDragEnd[key] = onEnd
        start()
    }

    func removeSampler(_ owner: AnyObject) {
        let key = ObjectIdentifier(owner)
        samplers[key] = nil
        onDragStart[key] = nil
        onDragEnd[key] = nil
    }

    // MARK: polling

    private func arm() {
        dragCountAtDown = NSPasteboard(name: .drag).changeCount
        location = NSEvent.mouseLocation
        shiftSince = nil
        shiftFired = false
        poller?.invalidate()
        let t = Timer(timeInterval: 1.0 / 60, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.sample() }
        }
        RunLoop.main.add(t, forMode: .common)   // keeps ticking while a drag session from our own windows runs
        poller = t
    }

    private func sample() {
        guard NSEvent.pressedMouseButtons & 1 != 0 else {
            poller?.invalidate()
            poller = nil
            endDrag()
            return
        }
        let pb = NSPasteboard(name: .drag)
        guard pb.changeCount != dragCountAtDown, pb.types?.contains(.fileURL) == true else { return }
        let point = NSEvent.mouseLocation
        location = point
        if !isDraggingFiles {
            isDraggingFiles = true
            for start in onDragStart.values { start() }
        }
        for s in samplers.values { s(point) }
        sampleShift(point)
    }

    private func endDrag() {
        guard isDraggingFiles else { return }
        isDraggingFiles = false
        shiftSince = nil
        for end in onDragEnd.values { end() }
    }

    /// Hold ⇧ (and nothing else) for 250 ms while dragging files → shelf under the cursor, once per drag.
    private func sampleShift(_ point: NSPoint) {
        guard Settings.shared.shiftDragTrigger, !shiftFired else { return }
        let flags = NSEvent.modifierFlags.intersection(KeyCombo.modifierMask)
        guard flags == [.shift] else { shiftSince = nil; return }
        let now = ProcessInfo.processInfo.systemUptime
        if let since = shiftSince {
            if now - since >= shiftHold {
                shiftFired = true
                Haptics.generic()
                onShiftTrigger?(point)
            }
        } else {
            shiftSince = now
        }
    }
}

/// Dropover-style "shake the cursor while dragging files" detection on top of `DragState`.
/// Horizontal direction reversals within a short window count as a shake; the thresholds come from
/// Settings.shakeSensitivity (read at the start of every drag).
@MainActor
final class ShakeDetector {
    var onShake: ((NSPoint) -> Void)?

    private var running = false
    private var lastX: CGFloat = 0
    private var anchorX: CGFloat = 0
    private var direction = 0
    private var reversals: [TimeInterval] = []
    private var fired = false
    private var minTravel: CGFloat = 28
    private var needed = 3
    private let window: TimeInterval = 0.75

    func start() {
        guard !running else { return }
        running = true
        DragState.shared.addSampler(self, onStart: { [weak self] in self?.reset() }) { [weak self] point in
            self?.sample(point)
        }
    }

    func stop() {
        guard running else { return }
        running = false
        DragState.shared.removeSampler(self)
    }

    private func reset() {
        let sensitivity = Settings.shared.shakeSensitivity
        minTravel = sensitivity.minTravel
        needed = sensitivity.reversalsNeeded
        lastX = DragState.shared.location.x
        anchorX = lastX
        direction = 0
        reversals = []
        fired = false
    }

    private func sample(_ point: NSPoint) {
        guard !fired else { return }
        let x = point.x
        let dx = x - lastX
        guard abs(dx) >= 2 else { return }
        let dir = dx > 0 ? 1 : -1
        if dir != direction {
            if direction != 0 && abs(lastX - anchorX) >= minTravel {
                let now = ProcessInfo.processInfo.systemUptime
                reversals.append(now)
                reversals.removeAll { now - $0 > window }
                if reversals.count >= needed {
                    fired = true
                    Haptics.generic()   // confirms the gesture before the shelf fades in
                    onShake?(point)
                }
            }
            anchorX = lastX
            direction = dir
        }
        lastX = x
    }
}

// Global hotkeys live in Shortcuts.swift (HotKeyCenter).

enum FinderSelection {
    /// Current Finder selection if Finder is the frontmost app; [] when another app is in front or nothing is
    /// selected. nil when Finder could not be asked at all – usually the Automation permission (macOS asks once)
    /// was denied – so callers can tell "nothing selected" from "could not look".
    static func current() -> [URL]? {
        guard NSWorkspace.shared.frontmostApplication?.bundleIdentifier == "com.apple.finder" else { return [] }
        let source = """
        tell application "Finder"
            set out to ""
            repeat with i in (get selection)
                set out to out & POSIX path of (i as alias) & linefeed
            end repeat
            return out
        end tell
        """
        var error: NSDictionary?
        guard let script = NSAppleScript(source: source) else { return nil }
        let result = script.executeAndReturnError(&error)
        if let error {
            NSLog("Tailbolt: Finder selection unavailable: \(error[NSAppleScript.errorMessage] ?? error)")
            return nil
        }
        guard let text = result.stringValue else { return nil }
        return text.split(separator: "\n").map { URL(fileURLWithPath: String($0)) }
    }
}

/// Finder → Services / Quick Actions → "Mit Tailbolt senden".
final class ServiceProvider: NSObject {
    @objc func sendFiles(_ pboard: NSPasteboard, userData: String?, error: AutoreleasingUnsafeMutablePointer<NSString?>?) {
        let urls = pboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
        guard !urls.isEmpty else { return }
        DispatchQueue.main.async {
            ShelfController.shared.show(at: nil, files: urls, keyboard: true)
        }
    }
}
