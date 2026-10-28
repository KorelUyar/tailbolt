import AppKit

/// The status-item glyph: the bolt from the app icon as a menu-bar template image.
///
/// Loads `menubar.png` / `menubar@2x.png` (idle) and `menubar-active.png` / `menubar-active@2x.png`
/// (transferring: bolt with a badge) from the app bundle's Resources — pure black on transparent,
/// 18 × 18 pt, both scales folded into one `NSImage` with `isTemplate = true` so AppKit tints it for
/// light / dark menu bars. Falls back to SF Symbols when the resources are missing, e.g. when the
/// bare executable runs in `--snapshot` mode outside the .app bundle.
///
/// Regenerate the PNGs with `swift scripts/make-icon.swift --menubar Resources`.
enum MenuBarIcon {
    static let pointSize = NSSize(width: 18, height: 18)

    static func image(active: Bool) -> NSImage? {
        (active ? activeTemplate : idleTemplate) ?? symbol(active: active)
    }

    // MARK: - Template PNGs (cached; static lets are initialised once, lazily and thread-safely)

    private static let idleTemplate = loadTemplate(named: "menubar")
    private static let activeTemplate = loadTemplate(named: "menubar-active")

    private static func loadTemplate(named base: String) -> NSImage? {
        let image = NSImage(size: pointSize)
        for suffix in ["", "@2x"] {
            guard let url = Bundle.main.url(forResource: base + suffix, withExtension: "png"),
                  let data = try? Data(contentsOf: url),
                  let rep = NSBitmapImageRep(data: data) else { continue }
            rep.size = pointSize   // 18 px → 1x, 36 px → 2x; the backing store keeps its pixel size
            image.addRepresentation(rep)
        }
        guard !image.representations.isEmpty else { return nil }
        image.isTemplate = true
        image.accessibilityDescription = "Tailbolt"
        return image
    }

    // MARK: - Fallback (same symbols StatusItemController used before the custom glyph)

    private static func symbol(active: Bool) -> NSImage? {
        let name = active ? "arrow.up.arrow.down.circle.fill" : "dot.radiowaves.up.forward"
        let img = NSImage(systemSymbolName: name, accessibilityDescription: "Tailbolt")?
            .withSymbolConfiguration(.init(pointSize: 15, weight: .medium))
        img?.isTemplate = true
        return img
    }
}
