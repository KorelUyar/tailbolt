import AppKit
import SwiftUI
import TailboltCore
import UniformTypeIdentifiers

/// What a device looks like: Apple's own product picture (the one Finder and "About This Mac" use) when the model is
/// known or can be guessed, else an SF Symbol. Tailbolt 2.3+ peers send their hardware model in hello; for older
/// peers and Taildrop-only devices the Tailscale host name and OS are enough for a good guess
/// ("iphone173" → iPhone17,3, "Noah’s MacBook Air" → a MacBook Air).
struct DeviceArt: Hashable {
    /// UTType identifier with a system icon ("com.apple.macbookpro-14-2024"), nil → `symbol` only.
    let typeID: String?
    let symbol: String

    static func make(os: String, name: String, model: String?) -> DeviceArt {
        let symbol = DeviceSymbol.for(os: os, name: name)
        return DeviceArt(typeID: resolveType(os: os, name: name, model: model), symbol: symbol)
    }

    static let thisMac = make(os: "macOS", name: Host.current().localizedName ?? "Mac", model: Platform.model)

    // MARK: model → picture

    private static let modelTag = UTTagClass(rawValue: "com.apple.device-model-code")

    /// A declared type for a model code ("Mac16,1"), skipping codes this macOS doesn't know yet.
    private static func type(forModel code: String) -> String? {
        guard let t = UTType(tag: code, tagClass: modelTag, conformingTo: nil), !t.isDynamic else { return nil }
        return t.identifier
    }

    private static func declared(_ id: String) -> String? {
        UTType(id).map { _ in id }
    }

    private static func resolveType(os: String, name: String, model: String?) -> String? {
        if let model, let t = type(forModel: model) { return t }
        let n = name.lowercased()
        switch os.lowercased() {
        case "macos":
            // Current-generation pictures for the family named in the device name; a laptop when nothing matches.
            let guess: String
            if n.contains("mini") { guess = "Mac16,10" }
            else if n.contains("studio") { guess = "Mac16,9" }
            else if n.contains("imac") { guess = "Mac16,2" }
            else if n.contains("air") { guess = "Mac15,12" }
            else if n.contains("mac pro") || n.contains("macpro") { return declared("com.apple.macpro-2019") }
            else { guess = "Mac16,1" }
            return type(forModel: guess) ?? declared("com.apple.macbookpro")
        case "ios":
            let ipad = n.contains("ipad")
            // Tailscale names iOS devices after the model code: "iphone173", "ipad1410".
            if let code = modelCode(fromHostName: n, family: ipad ? "ipad" : "iphone") { return code }
            // Or after the marketing name: "iphone-15-pro" → com.apple.iphone-15-pro-1.
            let slug = n.replacingOccurrences(of: " ", with: "-")
            for candidate in ["com.apple.\(slug)-1", "com.apple.\(slug)"] where slug.hasPrefix(ipad ? "ipad" : "iphone") {
                if let t = declared(candidate) { return t }
            }
            return type(forModel: ipad ? "iPad16,3" : "iPhone17,1") ?? declared(ipad ? "com.apple.ipad" : "com.apple.iphone")
        case "linux":
            return declared("com.apple.xserve")
        case "tvos":
            return declared("com.apple.apple-tv")
        default:
            return nil
        }
    }

    /// "iphone173" → the type for iPhone17,3; "ipad1410" → iPad14,10. The digits don't say where major ends, so
    /// every split is tried, two-digit majors first.
    private static func modelCode(fromHostName n: String, family: String) -> String? {
        guard n.hasPrefix(family) else { return nil }
        let digits = String(n.dropFirst(family.count))
        guard digits.count >= 2, digits.count <= 4, digits.allSatisfy(\.isNumber) else { return nil }
        let prefix = family == "ipad" ? "iPad" : "iPhone"
        for majorLength in [2, 1] where majorLength < digits.count {
            let major = digits.prefix(majorLength), minor = digits.dropFirst(majorLength)
            if minor.hasPrefix("0") { continue }
            if let t = type(forModel: "\(prefix)\(major),\(minor)") { return t }
        }
        return nil
    }

    // MARK: image

    @MainActor private static var cache: [String: NSImage] = [:]

    /// How much of the plate the picture fills: desktops (Mac mini, Studio, Xserve) sit small inside their icon
    /// canvas and get more room, phones and tablets are tall and get less.
    var fill: CGFloat {
        guard let id = typeID else { return 0.4 }
        if id.contains("macmini") || id.contains("macstudio") || id.contains("xserve") || id.contains("apple-tv") { return 0.84 }
        if id.contains("iphone") || id.contains("ipad") { return 0.64 }
        return 0.74
    }

    @MainActor
    var image: NSImage? {
        guard let typeID else { return nil }
        if let hit = Self.cache[typeID] { return hit }
        guard let t = UTType(typeID) else { return nil }
        let icon = NSWorkspace.shared.icon(for: t)
        Self.cache[typeID] = icon
        return icon
    }
}

enum DeviceSymbol {
    static func `for`(os: String, name: String) -> String {
        let n = name.lowercased()
        switch os.lowercased() {
        case "macos":
            if n.contains("mini") { return "macmini" }
            if n.contains("studio") { return "macstudio" }
            if n.contains("imac") { return "desktopcomputer" }
            return "laptopcomputer"
        case "ios":
            return n.contains("ipad") ? "ipad" : "iphone"
        case "windows": return "pc"
        case "linux": return "server.rack"
        case "android": return "smartphone"
        case "tvos": return "appletv"
        default: return "desktopcomputer"
        }
    }
}

/// The disc behind a device picture: a soft lit plate in the owner's colour (other people) or in graphite (own
/// devices), with the product picture standing on it – or a white glyph when there is no picture.
struct DevicePlate: View {
    let art: DeviceArt
    let colors: [Color]
    var size: CGFloat
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        ZStack {
            Circle().fill(LinearGradient(colors: colors, startPoint: .top, endPoint: .bottom))
            // Top light: reads as a lit glass disc instead of a flat fill.
            Circle().fill(RadialGradient(colors: [.white.opacity(scheme == .dark ? 0.22 : 0.34), .clear],
                                         center: UnitPoint(x: 0.5, y: 0.08), startRadius: 0, endRadius: size * 0.7))
            if let image = art.image {
                Image(nsImage: image)
                    .resizable()
                    .interpolation(.high)
                    .scaledToFit()
                    .frame(width: size * art.fill, height: size * art.fill)
                    .shadow(color: .black.opacity(0.28), radius: size * 0.04, y: size * 0.03)
            } else {
                Image(systemName: art.symbol)
                    .font(.system(size: size * 0.4, weight: .regular))
                    .foregroundStyle(.white)
                    .shadow(color: .black.opacity(0.18), radius: 1, y: 1)
            }
        }
        .frame(width: size, height: size)
        .clipShape(Circle())
        .overlay(Circle().strokeBorder(
            LinearGradient(colors: [.white.opacity(0.45), .white.opacity(0.06)], startPoint: .top, endPoint: .bottom),
            lineWidth: 0.75))
    }
}

/// Small device picture for list rows and settings (no plate: the product shot is the icon).
struct DeviceThumb: View {
    let art: DeviceArt
    var size: CGFloat = 30

    var body: some View {
        Group {
            if let image = art.image {
                Image(nsImage: image)
                    .resizable()
                    .interpolation(.high)
                    .scaledToFit()
                    .padding(size * 0.08)
                    .shadow(color: .black.opacity(0.18), radius: 1, y: 0.5)
            } else {
                Image(systemName: art.symbol)
                    .font(.system(size: size * 0.5))
                    .foregroundStyle(.secondary)
            }
        }
        .frame(width: size, height: size)
        .background(RoundedRectangle(cornerRadius: size * 0.27, style: .continuous).fill(.quaternary))
    }
}
