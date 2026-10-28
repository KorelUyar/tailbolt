import AppKit

struct InstallError: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}

/// Finder → right-click → Quick Actions → "Send with Tailbolt". A Quick Action is an Automator
/// workflow bundle in ~/Library/Services; this writes the same plists Automator would (one
/// "Run Shell Script" action that hands the selected files to the app via `open`).
/// The bundle's file name is the menu title Finder shows, so it follows the UI language.
enum QuickActionInstaller {
    static let bundleID = "com.koreluyar.tailbolt"

    static func name(for language: AppLanguage) -> String {
        switch language {
        case .english: return "Send with Tailbolt"
        case .german: return "Mit Tailbolt senden"
        }
    }

    /// Menu title (and file name) in the current UI language.
    static var name: String { name(for: AppLanguage.current) }

    /// Names the workflow may have been installed under in another language.
    private static var otherNames: [String] {
        AppLanguage.allCases.filter { $0 != AppLanguage.current }.map { name(for: $0) }
    }

    static func bundleURL(named name: String) -> URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Services/\(name).workflow", isDirectory: true)
    }

    static var bundleURL: URL { bundleURL(named: name) }

    private static func exists(named name: String) -> Bool {
        FileManager.default.fileExists(atPath: bundleURL(named: name).appendingPathComponent("Contents/document.wflow").path)
    }

    /// True for the workflow under any language's name.
    static var isInstalled: Bool {
        AppLanguage.allCases.contains { exists(named: name(for: $0)) }
    }

    static func install() throws {
        try write(to: bundleURL)
        for other in otherNames {
            let url = bundleURL(named: other)
            if FileManager.default.fileExists(atPath: url.path) { try? FileManager.default.removeItem(at: url) }
        }
        refreshServices()
    }

    /// After a language switch: a workflow installed under the other language's name is reinstalled
    /// under the current one, so Finder's menu title matches the UI.
    static func migrateIfNeeded() {
        guard !exists(named: name), otherNames.contains(where: { exists(named: $0) }) else { return }
        try? install()
    }

    /// Writes the .workflow bundle at `url` (also used by `--snapshot` to inspect the output).
    static func write(to url: URL) throws {
        let contents = url.appendingPathComponent("Contents", isDirectory: true)
        try FileManager.default.createDirectory(at: contents, withIntermediateDirectories: true)
        try plist(infoPlist).write(to: contents.appendingPathComponent("Info.plist"), options: .atomic)
        try plist(document).write(to: contents.appendingPathComponent("document.wflow"), options: .atomic)
    }

    static func uninstall() throws {
        for language in AppLanguage.allCases {
            let url = bundleURL(named: name(for: language))
            if FileManager.default.fileExists(atPath: url.path) {
                try FileManager.default.removeItem(at: url)
            }
        }
        refreshServices()
    }

    /// Tells the pasteboard server to rescan ~/Library/Services so the menu updates right away.
    static func refreshServices() {
        NSUpdateDynamicServices()
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/System/Library/CoreServices/pbs")
        p.arguments = ["-update"]
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        try? p.run()
    }

    private static func plist(_ object: Any) throws -> Data {
        try PropertyListSerialization.data(fromPropertyList: object, format: .xml, options: 0)
    }

    private static var infoPlist: [String: Any] {
        [
            "CFBundleName": name,
            "CFBundleIdentifier": "\(bundleID).quickaction",
            "CFBundleShortVersionString": "1.0",
            "NSServices": [[
                "NSBackgroundColorName": "background",
                "NSIconName": "NSActionTemplate",
                "NSMenuItem": ["default": name],
                "NSMessage": "runWorkflowAsService",
                "NSRequiredContext": [String: Any](),
                "NSSendFileTypes": ["public.item"],
            ]],
        ]
    }

    /// Mirrors what Automator 2.10 saves for a Quick Action with a single "Run Shell Script" action
    /// (input as arguments, zsh). The app is addressed by bundle id, so it may live anywhere.
    private static var document: [String: Any] {
        let command = "open -b \(bundleID) \"$@\" 2>/dev/null || open -a Tailbolt \"$@\""
        let argument: ([String: Any]) -> [String: Any] = { extra in
            var a: [String: Any] = ["required": "0", "type": "0"]
            a.merge(extra) { _, new in new }
            return a
        }
        let action: [String: Any] = [
            "AMAccepts": ["Container": "List", "Optional": true, "Types": ["com.apple.cocoa.string"]],
            "AMActionVersion": "2.0.3",
            "AMApplication": ["Automator"],
            "AMParameterProperties": ["COMMAND_STRING": [:], "CheckedForUserDefaultShell": [:], "inputMethod": [:], "shell": [:], "source": [:]],
            "AMProvides": ["Container": "List", "Types": ["com.apple.cocoa.string"]],
            "ActionBundlePath": "/System/Library/Automator/Run Shell Script.action",
            "ActionName": "Run Shell Script",
            "ActionParameters": [
                "COMMAND_STRING": command,
                "CheckedForUserDefaultShell": true,
                "inputMethod": 1,
                "shell": "/bin/zsh",
                "source": "",
            ],
            "BundleIdentifier": "com.apple.RunShellScript",
            "CFBundleVersion": "2.0.3",
            "CanShowSelectedItemsWhenRun": false,
            "CanShowWhenRun": true,
            "Category": ["AMCategoryUtilities"],
            "Class Name": "RunShellScriptAction",
            "InputUUID": "A63C0057-65D7-4947-B815-6DE57F462947",
            "Keywords": ["Shell", "Script", "Command", "Run", "Unix"],
            "OutputUUID": "37104E7D-3DE2-42D0-9B52-2D15C0C8CA4B",
            "UUID": "992C77ED-C318-4112-9778-08557E540CD5",
            "UnlocalizedApplications": ["Automator"],
            "arguments": [
                "0": argument(["default value": 0, "name": "inputMethod", "uuid": "0"]),
                "1": argument(["default value": false, "name": "CheckedForUserDefaultShell", "uuid": "1"]),
                "2": argument(["default value": "", "name": "source", "uuid": "2"]),
                "3": argument(["default value": "", "name": "COMMAND_STRING", "uuid": "3"]),
                "4": argument(["default value": "/bin/sh", "name": "shell", "uuid": "4"]),
            ],
            "conversionLabel": 0,
            "isViewVisible": 1,
            "location": "309.000000:305.000000",
            "nibPath": "/System/Library/Automator/Run Shell Script.action/Contents/Resources/Base.lproj/main.nib",
        ]
        return [
            "AMApplicationBuild": "534",
            "AMApplicationVersion": "2.10",
            "AMDocumentVersion": "2",
            "actions": [["action": action, "isViewVisible": 1]],
            "connectors": [String: Any](),
            "workflowMetaData": [
                "applicationBundleIDsByPath": [String: Any](),
                "applicationPaths": [String](),
                "inputTypeIdentifier": "com.apple.Automator.fileSystemObject",
                "outputTypeIdentifier": "com.apple.Automator.nothing",
                "presentationMode": 15,
                "processesInput": false,
                "serviceInputTypeIdentifier": "com.apple.Automator.fileSystemObject",
                "serviceOutputTypeIdentifier": "com.apple.Automator.nothing",
                "serviceProcessesInput": false,
                "systemImageName": "NSActionTemplate",
                "useAutomaticInputType": false,
                "workflowTypeIdentifier": "com.apple.Automator.servicesMenu",
            ],
        ]
    }
}

/// `tailbolt` on the command line: a symlink in /usr/local/bin to the CLI bundled with the app.
enum CLIInstaller {
    static let link = URL(fileURLWithPath: "/usr/local/bin/tailbolt")

    /// The bundled CLI (Tailbolt.app/Contents/Resources/tailbolt-cli), or the sibling binary of a dev build.
    static var target: URL? {
        let fm = FileManager.default
        let bundled = Bundle.main.bundleURL.appendingPathComponent("Contents/Resources/tailbolt-cli")
        if fm.isExecutableFile(atPath: bundled.path) { return bundled }
        if let sibling = Bundle.main.executableURL?.deletingLastPathComponent().appendingPathComponent("tailbolt-cli"),
           fm.isExecutableFile(atPath: sibling.path) { return sibling }
        return nil
    }

    static var isInstalled: Bool {
        let fm = FileManager.default
        return (try? fm.destinationOfSymbolicLink(atPath: link.path)) != nil || fm.fileExists(atPath: link.path)
    }

    static func install() throws {
        guard let target else { throw InstallError(String(localized: "tailbolt-cli wasn’t found in the app bundle")) }
        let fm = FileManager.default
        do {
            try fm.createDirectory(at: link.deletingLastPathComponent(), withIntermediateDirectories: true)
            if isInstalled { try fm.removeItem(at: link) }
            try fm.createSymbolicLink(at: link, withDestinationURL: target)
        } catch {
            // /usr/local/bin is usually root-owned on a fresh Mac → ask once for the admin password.
            try privileged("mkdir -p /usr/local/bin && ln -sfn \(quote(target.path)) \(quote(link.path))")
        }
    }

    static func uninstall() throws {
        guard isInstalled else { return }
        do {
            try FileManager.default.removeItem(at: link)
        } catch {
            try privileged("rm -f \(quote(link.path))")
        }
    }

    private static func privileged(_ command: String) throws {
        let escaped = command.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
        let source = "do shell script \"\(escaped)\" with administrator privileges"
        var error: NSDictionary?
        NSAppleScript(source: source)?.executeAndReturnError(&error)
        if let error {
            let code = error[NSAppleScript.errorNumber] as? Int
            throw InstallError(code == -128 ? String(localized: "Cancelled") : (error[NSAppleScript.errorMessage] as? String ?? String(localized: "Failed")))
        }
    }

    private static func quote(_ s: String) -> String {
        "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
