import AppKit
import Carbon.HIToolbox

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    static weak var shared: AppDelegate?

    private var statusItem: StatusItemController?
    private let shake = ShakeDetector()
    private let services = ServiceProvider()

    func applicationDidFinishLaunching(_ notification: Notification) {
        AppDelegate.shared = self
        let args = CommandLine.arguments
        if let i = args.firstIndex(of: "--snapshot"), i + 1 < args.count {
            AppModel.shared.refresh()
            // A timer, not DispatchQueue.main: Snapshot spins nested run loops, and the main dispatch queue is not
            // re-entrant – scheduled from a dispatch block, every `DispatchQueue.main.async` (thumbnails, AsyncImage,
            // engine callbacks) would starve until exit.
            let dir = URL(fileURLWithPath: args[i + 1])
            let files = args.dropFirst(i + 2).map { URL(fileURLWithPath: $0) }
            Timer.scheduledTimer(withTimeInterval: 4, repeats: false) { _ in
                MainActor.assumeIsolated { Snapshot.run(dir: dir, files: files) }
            }
            return
        }
        if let i = args.firstIndex(of: "--onboarding-preview") {   // dev/QA: just the setup assistant, no server/hotkeys/shake
            AppModel.shared.refresh()
            OnboardingController.shared.show()
            if i + 1 < args.count { OnboardingController.shared.debugTour(dir: URL(fileURLWithPath: args[i + 1])) }   // + PNG of every page
            return
        }
        if Relocation.offerIfNeeded() { return }
        AppModel.shared.start()
        Updater.shared.start()
        statusItem = StatusItemController()
        // First-run setup assistant (replaces the old didShowWelcome → popover); "Fertig" then opens the popover.
        OnboardingController.shared.onFinished = { [weak self] in
            LocalNetworkPermission.prime()      // get the macOS "Lokales Netzwerk" prompt out of the way now
            self?.statusItem?.showPopover()
        }
        OnboardingController.shared.quickActionInstaller = { try? QuickActionInstaller.install() }
        OnboardingController.shared.isQuickActionInstalled = { QuickActionInstaller.isInstalled }
        QuickActionInstaller.migrateIfNeeded()   // Finder menu title follows the UI language
        SettingsActions.openOnboarding = { OnboardingController.shared.show() }   // popover footer, status menu, Allgemein
        OnboardingController.shared.showIfNeeded()

        shake.onShake = { point in
            ShelfController.shared.show(at: point)
        }
        applyTriggers()
        HotKeyCenter.shared.start()

        NSApp.servicesProvider = services
        NSUpdateDynamicServices()

        NSAppleEventManager.shared().setEventHandler(self, andSelector: #selector(handleURL(_:reply:)),
                                                     forEventClass: AEEventClass(kInternetEventClass),
                                                     andEventID: AEEventID(kAEGetURL))
    }

    func applicationWillTerminate(_ notification: Notification) {
        HotKeyCenter.shared.cancelRecording()
    }

    /// Gesture triggers; the global hotkeys watch Settings themselves (HotKeyCenter).
    /// The shake thresholds (`shakeSensitivity`) are read at the start of every drag and the hold-⇧ trigger
    /// checks `shiftDragTrigger` live, so only the shake sampler needs switching here.
    func applyTriggers() {
        DragState.shared.start()   // menu-bar halo, shelf drop zone and hold-⇧ work even with the shake off
        if Settings.shared.shakeToOpen { shake.start() } else { shake.stop() }
    }

    /// Files opened with Tailbolt (Dock icon drop, "Open With", Finder Quick Action, `open -a Tailbolt`).
    func application(_ application: NSApplication, open urls: [URL]) {
        let files = urls.filter(\.isFileURL)
        if !files.isEmpty { ShelfController.shared.show(at: nil, files: files, keyboard: true) }
    }

    /// tailbolt://send?path=/a&path=/b — used by the Share extension.
    @objc func handleURL(_ event: NSAppleEventDescriptor, reply: NSAppleEventDescriptor) {
        guard let s = event.paramDescriptor(forKeyword: keyDirectObject)?.stringValue,
              let comps = URLComponents(string: s) else { return }
        let paths = comps.queryItems?.filter { $0.name == "path" }.compactMap(\.value) ?? []
        let files = paths.map { URL(fileURLWithPath: $0) }.filter { FileManager.default.fileExists(atPath: $0.path) }
        ShelfController.shared.show(at: nil, files: files, keyboard: true)
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        ShelfController.shared.show(at: nil, keyboard: true)
        return false
    }
}

AppLanguage.applyAtLaunch()   // before any localized string is resolved

MainActor.assumeIsolated {
    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    app.setActivationPolicy(.accessory)
    app.run()
}
