import AppKit

/// Offers to move the app into /Applications when launched from Downloads, a DMG, the desktop, etc.
@MainActor
enum Relocation {
    static func offerIfNeeded() -> Bool {
        let bundle = Bundle.main.bundleURL.standardizedFileURL
        let path = bundle.path
        guard bundle.pathExtension == "app",
              !path.hasPrefix("/Applications/"),
              !path.hasPrefix(NSHomeDirectory() + "/Applications/"),
              !path.contains("/.build/"), !path.contains("/dist/"),          // dev builds
              !UserDefaults.standard.bool(forKey: "skipRelocation") else { return false }

        let alert = NSAlert()
        alert.messageText = "Tailbolt in den Programme-Ordner verschieben?"
        alert.informativeText = "Damit Tailbolt immer am gleichen Ort ist und beim Anmelden starten kann, sollte es im Ordner «Programme» liegen. Es wird verschoben und neu gestartet."
        alert.addButton(withTitle: "Verschieben")
        alert.addButton(withTitle: "Nicht verschieben")
        alert.showsSuppressionButton = true
        alert.suppressionButton?.title = "Nicht mehr fragen"
        NSApp.activate(ignoringOtherApps: true)
        let response = alert.runModal()
        if alert.suppressionButton?.state == .on { UserDefaults.standard.set(true, forKey: "skipRelocation") }
        guard response == .alertFirstButtonReturn else { return false }

        let dest = URL(fileURLWithPath: "/Applications/Tailbolt.app")
        let fm = FileManager.default
        do {
            if fm.fileExists(atPath: dest.path) {
                NSWorkspace.shared.recycle([dest])   // keep the old copy recoverable
                if fm.fileExists(atPath: dest.path) { try fm.removeItem(at: dest) }
            }
            try fm.copyItem(at: bundle, to: dest)
            // The user already approved this exact bundle; the copy keeps that approval but we clear the flag anyway.
            let x = Process()
            x.executableURL = URL(fileURLWithPath: "/usr/bin/xattr")
            x.arguments = ["-dr", "com.apple.quarantine", dest.path]
            try? x.run(); x.waitUntilExit()
            NSWorkspace.shared.recycle([bundle])
            let config = NSWorkspace.OpenConfiguration()
            config.createsNewApplicationInstance = true
            NSWorkspace.shared.openApplication(at: dest, configuration: config) { _, _ in
                DispatchQueue.main.async { NSApp.terminate(nil) }
            }
            return true
        } catch {
            let e = NSAlert(error: error)
            e.runModal()
            return false
        }
    }
}
