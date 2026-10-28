import AppKit

/// UI language. English is the base language (the strings in the source code); German comes from
/// `Resources/de.lproj/Localizable.strings`. The choice is stored as this app's `AppleLanguages`, which is
/// what macOS itself uses for per-app languages – so Bundle, SwiftUI `Text` and `String(localized:)` all follow it.
/// Default is English, whatever the system language is.
enum AppLanguage: String, CaseIterable, Identifiable {
    case english = "en"
    case german = "de"

    var id: String { rawValue }

    /// Each language is named in itself, like the macOS language list.
    var nativeName: String {
        switch self {
        case .english: return "English"
        case .german: return "Deutsch"
        }
    }

    private static let key = "appLanguage"

    /// The language this process was started with.
    static let launched: AppLanguage = current

    static var current: AppLanguage {
        UserDefaults.standard.string(forKey: key).flatMap(AppLanguage.init(rawValue:)) ?? .english
    }

    /// Must run before the first localized string is looked up (top of `main.swift`).
    /// Respects `-AppleLanguages (…)` on the command line, so `Tailbolt -AppleLanguages '(de)' --snapshot …` still works.
    static func applyAtLaunch() {
        if CommandLine.arguments.contains("-AppleLanguages") { return }
        UserDefaults.standard.set([current.rawValue], forKey: "AppleLanguages")
    }

    /// Stores the choice; it takes effect on the next launch (see `relaunch()`).
    static func select(_ language: AppLanguage) {
        UserDefaults.standard.set(language.rawValue, forKey: key)
        UserDefaults.standard.set([language.rawValue], forKey: "AppleLanguages")
    }

    /// Quits and starts the app again (used after switching the language).
    @MainActor static func relaunch() {
        let path = Bundle.main.bundlePath
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/sh")
        task.arguments = ["-c", "sleep 0.6; /usr/bin/open \"$0\"", path]
        try? task.run()
        NSApp.terminate(nil)
    }
}
