import Foundation

/// Marks received files the way browsers and AirDrop do, so macOS checks an app or script that came
/// from another device before it runs for the first time (Gatekeeper). Documents open as usual.
enum Quarantine {
    /// Marks `root` and everything below it. Symlinks are left alone: the mark belongs on files that
    /// arrived, not on whatever a link points to.
    static func mark(_ root: URL) {
        #if os(macOS)
        let fm = FileManager.default
        let keys: [URLResourceKey] = [.isSymbolicLinkKey]
        guard let walker = fm.enumerator(at: root, includingPropertiesForKeys: keys, options: [], errorHandler: nil) else { return }
        for case let url as URL in walker {
            if (try? url.resourceValues(forKeys: Set(keys)))?.isSymbolicLink == true { continue }
            var values = URLResourceValues()
            values.quarantineProperties = [
                "LSQuarantineAgentName": "Tailbolt",
                "LSQuarantineType": "LSQuarantineTypeOtherDownload",
            ]
            var target = url
            try? target.setResourceValues(values)
        }
        #endif
    }
}
