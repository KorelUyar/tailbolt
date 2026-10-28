import AppKit

/// Finder "Teilen" → Tailbolt. Collects the shared file URLs and hands them to the main app,
/// which shows its shelf with the device picker. No UI of its own.
@objc(ShareViewController)
final class ShareViewController: NSViewController {
    override var nibName: NSNib.Name? { nil }

    override func loadView() {
        view = NSView(frame: NSRect(x: 0, y: 0, width: 1, height: 1))
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        let items = extensionContext?.inputItems as? [NSExtensionItem] ?? []
        let providers = items.flatMap { $0.attachments ?? [] }
        let group = DispatchGroup()
        let lock = NSLock()
        var paths: [String] = []
        for p in providers where p.hasItemConformingToTypeIdentifier("public.file-url") {
            group.enter()
            p.loadItem(forTypeIdentifier: "public.file-url", options: nil) { item, _ in
                var url: URL?
                if let u = item as? URL { url = u }
                else if let d = item as? Data { url = URL(dataRepresentation: d, relativeTo: nil) }
                if let url, url.isFileURL { lock.lock(); paths.append(url.path); lock.unlock() }
                group.leave()
            }
        }
        group.notify(queue: .main) {
            var c = URLComponents()
            c.scheme = "tailbolt"
            c.host = "send"
            c.queryItems = paths.map { URLQueryItem(name: "path", value: $0) }
            if let url = c.url { NSWorkspace.shared.open(url) }
            self.extensionContext?.completeRequest(returningItems: nil, completionHandler: nil)
        }
    }
}
