import Foundation

/// The items to send plus where their bytes come from locally.
struct SourceManifest {
    var items: [WireItem] = []
    var sources: [String?] = []     // absolute path for files, nil for directories/symlinks

    static let skippedNames: Set<String> = [".DS_Store"]

    static func build(_ urls: [URL]) throws -> SourceManifest {
        var m = SourceManifest()
        var usedTop = Set<String>()
        let fm = FileManager.default
        let keys: [URLResourceKey] = [.isDirectoryKey, .isSymbolicLinkKey, .fileSizeKey, .contentModificationDateKey, .isExecutableKey]

        for url in urls {
            let url = url.standardizedFileURL
            var top = url.lastPathComponent
            if usedTop.contains(top) { top = uniqueName(top) { usedTop.contains($0) } }
            usedTop.insert(top)

            try m.add(url: url, relative: top, keys: keys)
            let values = try url.resourceValues(forKeys: Set(keys))
            if values.isDirectory == true && values.isSymbolicLink != true {
                guard let e = fm.enumerator(at: url, includingPropertiesForKeys: keys, options: []) else { continue }
                let basePath = url.path.hasSuffix("/") ? url.path : url.path + "/"
                for case let child as URL in e {
                    if skippedNames.contains(child.lastPathComponent) { continue }
                    let childPath = child.standardizedFileURL.path
                    guard childPath.hasPrefix(basePath) else { continue }
                    let rel = top + "/" + childPath.dropFirst(basePath.count)
                    try m.add(url: child, relative: rel, keys: keys)
                }
            }
        }
        return m
    }

    private mutating func add(url: URL, relative: String, keys: [URLResourceKey]) throws {
        let v = try url.resourceValues(forKeys: Set(keys))
        let mtime = v.contentModificationDate?.timeIntervalSince1970
        if v.isSymbolicLink == true {
            guard let dest = try? FileManager.default.destinationOfSymbolicLink(atPath: url.path) else { return }
            items.append(WireItem(p: relative, s: 0, d: false, m: mtime, l: dest))
            sources.append(nil)
        } else if v.isDirectory == true {
            items.append(WireItem(p: relative, s: 0, d: true, m: mtime))
            sources.append(nil)
        } else {
            items.append(WireItem(p: relative, s: Int64(v.fileSize ?? 0), d: false, m: mtime,
                                  x: v.isExecutable == true ? true : nil))
            sources.append(url.path)
        }
    }
}

/// "Report.pdf" -> "Report 2.pdf", "Folder" -> "Folder 2" (Finder style).
func uniqueName(_ name: String, taken: (String) -> Bool) -> String {
    let ns = name as NSString
    let ext = ns.pathExtension
    let base = ext.isEmpty ? name : ns.deletingPathExtension
    var i = 2
    while true {
        let candidate = ext.isEmpty ? "\(base) \(i)" : "\(base) \(i).\(ext)"
        if !taken(candidate) { return candidate }
        i += 1
    }
}
