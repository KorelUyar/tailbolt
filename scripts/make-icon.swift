// Tailbolt app icon + menu-bar glyph renderer — concept "pure-bolt".
//
// A single custom-drawn lightning bolt: broad, rounded top, gently curved edges, a sharp white-hot
// tip landing bottom-right. Crisp white body (top-lit, white → #F2EEFF), violet bloom and a faint
// motion smear strictly OUTSIDE the body, on an indigo → violet squircle.
//
// Usage (modes can be combined):
//   swift scripts/make-icon.swift <out.iconset>          icon_16x16.png … icon_512x512@2x.png
//   swift scripts/make-icon.swift --menubar <dir>        menubar.png, menubar@2x.png,
//                                                        menubar-active.png, menubar-active@2x.png
//   swift scripts/make-icon.swift --preview <file.png>   the 1024 px icon on a neutral background
//   swift scripts/make-icon.swift --sheet <file.png>     inspection sheet (light/dark, 16–512, menu bar)
//
// Everything is drawn at the target pixel size (nothing is downsampled from 1024): geometry is
// authored in a 1024-unit space and mapped through `k = px / 1024`, and the small sizes get their
// own tuning (no smear, tighter bloom, a slightly fatter silhouette). AppKit / CoreGraphics only.

import AppKit

// MARK: - CLI

struct Options {
    var iconset: URL?
    var menubarDir: URL?
    var preview: URL?
    var sheet: URL?
    var grid = false
}

func usage() -> Never {
    let text = """
    usage: swift scripts/make-icon.swift <out.iconset> [--menubar <dir>] [--preview <file.png>] [--sheet <file.png>] [--grid]

    """
    FileHandle.standardError.write(text.data(using: .utf8)!)
    exit(1)
}

var opts = Options()
var argIter = CommandLine.arguments.dropFirst().makeIterator()
while let a = argIter.next() {
    switch a {
    case "--menubar": guard let v = argIter.next() else { usage() }; opts.menubarDir = URL(fileURLWithPath: v)
    case "--preview": guard let v = argIter.next() else { usage() }; opts.preview = URL(fileURLWithPath: v)
    case "--sheet": guard let v = argIter.next() else { usage() }; opts.sheet = URL(fileURLWithPath: v)
    case "--grid": opts.grid = true
    case "-h", "--help": usage()
    default:
        if a.hasPrefix("-") || opts.iconset != nil { usage() }
        opts.iconset = URL(fileURLWithPath: a)
    }
}
if opts.iconset == nil && opts.menubarDir == nil && opts.preview == nil && opts.sheet == nil { usage() }

// MARK: - Small helpers

func rgb(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat, _ a: CGFloat = 1) -> NSColor {
    NSColor(srgbRed: r, green: g, blue: b, alpha: a)
}
func hex(_ v: UInt32, _ a: CGFloat = 1) -> NSColor {
    rgb(CGFloat((v >> 16) & 0xff) / 255, CGFloat((v >> 8) & 0xff) / 255, CGFloat(v & 0xff) / 255, a)
}
func deg(_ d: CGFloat) -> CGFloat { d * .pi / 180 }

func makeRep(_ w: Int, _ h: Int) -> NSBitmapImageRep {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: w, pixelsHigh: h, bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                               colorSpaceName: .calibratedRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    rep.size = NSSize(width: w, height: h)
    return rep
}

func render(_ w: Int, _ h: Int, _ body: () -> Void) -> NSBitmapImageRep {
    let rep = makeRep(w, h)
    NSGraphicsContext.saveGraphicsState()
    let ctx = NSGraphicsContext(bitmapImageRep: rep)!
    NSGraphicsContext.current = ctx
    ctx.imageInterpolation = .high
    ctx.shouldAntialias = true
    ctx.cgContext.setAllowsAntialiasing(true)
    ctx.cgContext.setShouldAntialias(true)
    body()
    ctx.flushGraphics()
    NSGraphicsContext.restoreGraphicsState()
    return rep
}

func savePNG(_ rep: NSBitmapImageRep, _ url: URL) throws {
    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try rep.representation(using: .png, properties: [:])!.write(to: url)
}

func saved(_ body: () -> Void) {
    NSGraphicsContext.saveGraphicsState()
    body()
    NSGraphicsContext.restoreGraphicsState()
}

// MARK: - Point math

extension CGPoint {
    static func + (a: CGPoint, b: CGPoint) -> CGPoint { CGPoint(x: a.x + b.x, y: a.y + b.y) }
    static func - (a: CGPoint, b: CGPoint) -> CGPoint { CGPoint(x: a.x - b.x, y: a.y - b.y) }
    static func * (a: CGPoint, s: CGFloat) -> CGPoint { CGPoint(x: a.x * s, y: a.y * s) }
    var length: CGFloat { hypot(x, y) }
    var unit: CGPoint { let l = length; return l > 0 ? CGPoint(x: x / l, y: y / l) : .zero }
    func dot(_ b: CGPoint) -> CGFloat { x * b.x + y * b.y }
}
func lerp(_ a: CGPoint, _ b: CGPoint, _ t: CGFloat) -> CGPoint { a + (b - a) * t }
func lerp(_ a: CGFloat, _ b: CGFloat, _ t: CGFloat) -> CGFloat { a + (b - a) * t }

// MARK: - Continuous-curvature rounded rect (Apple-style squircle)

func squircle(_ rect: NSRect, radius: CGFloat, smoothing s: CGFloat = 0.6) -> NSBezierPath {
    let w = rect.width, h = rect.height
    let r = min(radius, min(w, h) / 2)
    let p = min(min(w, h) / 2, (1 + s) * r)
    let arcMeasure = 90 * (1 - s)
    let arcLen = sin(deg(arcMeasure / 2)) * r * sqrt(2)
    let angleAlpha = (90 - arcMeasure) / 2
    let p3p4 = r * tan(deg(angleAlpha / 2))
    let angleBeta = 45 * s
    let c = p3p4 * cos(deg(angleBeta))
    let d = c * tan(deg(angleBeta))
    let b = (p - arcLen - c - d) / 3
    let a = 2 * b

    let path = NSBezierPath()
    var cur = CGPoint.zero
    func P(_ x: CGFloat, _ y: CGFloat) -> NSPoint { NSPoint(x: rect.minX + x, y: rect.minY + (h - y)) }
    func move(_ x: CGFloat, _ y: CGFloat) { cur = CGPoint(x: x, y: y); path.move(to: P(x, y)) }
    func line(_ x: CGFloat, _ y: CGFloat) { cur = CGPoint(x: x, y: y); path.line(to: P(x, y)) }
    func curve(_ dx1: CGFloat, _ dy1: CGFloat, _ dx2: CGFloat, _ dy2: CGFloat, _ dx: CGFloat, _ dy: CGFloat) {
        let c1 = CGPoint(x: cur.x + dx1, y: cur.y + dy1)
        let c2 = CGPoint(x: cur.x + dx2, y: cur.y + dy2)
        let e = CGPoint(x: cur.x + dx, y: cur.y + dy)
        path.curve(to: P(e.x, e.y), controlPoint1: P(c1.x, c1.y), controlPoint2: P(c2.x, c2.y))
        cur = e
    }
    func arc(_ r: CGFloat, _ dx: CGFloat, _ dy: CGFloat) {
        let p1 = cur, p2 = CGPoint(x: cur.x + dx, y: cur.y + dy)
        let vx = p2.x - p1.x, vy = p2.y - p1.y
        let L = hypot(vx, vy)
        let mid = CGPoint(x: (p1.x + p2.x) / 2, y: (p1.y + p2.y) / 2)
        let hd = sqrt(max(0, r * r - (L / 2) * (L / 2)))
        let n = CGPoint(x: -vy / L, y: vx / L)
        let cen = CGPoint(x: mid.x + n.x * hd, y: mid.y + n.y * hd)
        let t1 = atan2(p1.y - cen.y, p1.x - cen.x)
        var t2 = atan2(p2.y - cen.y, p2.x - cen.x)
        while t2 < t1 { t2 += 2 * .pi }
        let delta = t2 - t1
        let kk = 4.0 / 3.0 * tan(delta / 4)
        let c1 = CGPoint(x: p1.x - kk * r * sin(t1), y: p1.y + kk * r * cos(t1))
        let c2 = CGPoint(x: p2.x + kk * r * sin(t2), y: p2.y - kk * r * cos(t2))
        path.curve(to: P(p2.x, p2.y), controlPoint1: P(c1.x, c1.y), controlPoint2: P(c2.x, c2.y))
        cur = p2
    }

    move(p, 0)
    line(w - p, 0)
    curve(a, 0, a + b, 0, a + b + c, d)
    arc(r, arcLen, arcLen)
    curve(d, c, d, b + c, d, a + b + c)
    line(w, h - p)
    curve(0, a, 0, a + b, -d, a + b + c)
    arc(r, -arcLen, arcLen)
    curve(-c, d, -(b + c), d, -(a + b + c), d)
    line(p, h)
    curve(-a, 0, -(a + b), 0, -(a + b + c), -d)
    arc(r, -arcLen, -arcLen)
    curve(-d, -c, -d, -(b + c), -d, -(a + b + c))
    line(0, p)
    curve(0, -a, 0, -(a + b), d, -(a + b + c))
    arc(r, arcLen, -arcLen)
    curve(c, -d, b + c, -d, a + b + c, -d)
    path.close()
    return path
}

func circle(_ c: CGPoint, _ r: CGFloat) -> NSBezierPath {
    NSBezierPath(ovalIn: NSRect(x: c.x - r, y: c.y - r, width: 2 * r, height: 2 * r))
}

/// Draws only the Gaussian glow of `path` (shape drawn far off-canvas, the shadow offset brings
/// the blur back), so the glow can be composited under or around other fills.
func glow(_ path: NSBezierPath, color: NSColor, blur: CGFloat) {
    saved {
        let off: CGFloat = 20000
        let sh = NSShadow()
        sh.shadowColor = color
        sh.shadowBlurRadius = blur
        sh.shadowOffset = NSSize(width: off, height: 0)
        sh.set()
        let t = NSAffineTransform()
        t.translateX(by: -off, yBy: 0)
        NSColor.black.setFill()
        t.transform(path).fill()
    }
}

extension NSBezierPath {
    var cgPath: CGPath {
        let p = CGMutablePath()
        var pts = [NSPoint](repeating: .zero, count: 3)
        for i in 0..<elementCount {
            switch element(at: i, associatedPoints: &pts) {
            case .moveTo: p.move(to: pts[0])
            case .lineTo: p.addLine(to: pts[0])
            case .curveTo: p.addCurve(to: pts[2], control1: pts[0], control2: pts[1])
            case .cubicCurveTo: p.addCurve(to: pts[2], control1: pts[0], control2: pts[1])
            case .quadraticCurveTo: p.addQuadCurve(to: pts[1], control: pts[0])
            case .closePath: p.closeSubpath()
            @unknown default: break
            }
        }
        return p
    }
}

// MARK: - Cubic Bézier utilities + smooth polygon (pen-tool style outline with fillets)

struct Cubic {
    var p0, c1, c2, p3: CGPoint
    func point(_ t: CGFloat) -> CGPoint {
        let mt = 1 - t
        let a = mt * mt * mt, b = 3 * mt * mt * t, c = 3 * mt * t * t, d = t * t * t
        return p0 * a + c1 * b + c2 * c + p3 * d
    }
    func tangent(_ t: CGFloat) -> CGPoint {
        let mt = 1 - t
        return (c1 - p0) * (3 * mt * mt) + (c2 - c1) * (6 * mt * t) + (p3 - c2) * (3 * t * t)
    }
    func split(_ t: CGFloat) -> (Cubic, Cubic) {
        let p01 = lerp(p0, c1, t), p12 = lerp(c1, c2, t), p23 = lerp(c2, p3, t)
        let p012 = lerp(p01, p12, t), p123 = lerp(p12, p23, t)
        let m = lerp(p012, p123, t)
        return (Cubic(p0: p0, c1: p01, c2: p012, p3: m), Cubic(p0: m, c1: p123, c2: p23, p3: p3))
    }
    func length(_ n: Int = 48) -> CGFloat {
        var l: CGFloat = 0, prev = p0
        for i in 1...n { let q = point(CGFloat(i) / CGFloat(n)); l += (q - prev).length; prev = q }
        return l
    }
    func t(atLength s: CGFloat, _ n: Int = 96) -> CGFloat {
        var l: CGFloat = 0, prev = p0
        for i in 1...n {
            let t = CGFloat(i) / CGFloat(n)
            let q = point(t)
            let seg = (q - prev).length
            if l + seg >= s { return CGFloat(i - 1) / CGFloat(n) + (s - l) / max(seg, 1e-9) / CGFloat(n) }
            l += seg; prev = q
        }
        return 1
    }
    func transformed(_ f: (CGPoint) -> CGPoint) -> Cubic {
        Cubic(p0: f(p0), c1: f(c1), c2: f(c2), p3: f(p3))
    }
}

/// Outline from a vertex ring. Edges are cubics bowed sideways by `bows` (per edge: handle offset
/// at start/end along the outward normal; positive = outward for a clockwise ring in y-down space).
/// Each vertex gets a circular-ish fillet of radius `radii[i]` (0 = sharp corner).
func smoothPolygon(_ v: [CGPoint], radii: [CGFloat], bows: [(CGFloat, CGFloat)]) -> [Cubic] {
    let n = v.count
    var edges: [Cubic] = []
    for i in 0..<n {
        let p0 = v[i], p3 = v[(i + 1) % n]
        let L = (p3 - p0).length
        let d = (p3 - p0).unit
        let nrm = CGPoint(x: d.y, y: -d.x)
        edges.append(Cubic(p0: p0, c1: p0 + d * (L / 3) + nrm * bows[i].0,
                           c2: p3 - d * (L / 3) + nrm * bows[i].1, p3: p3))
    }
    var startTrim = [CGFloat](repeating: 0, count: n), endTrim = startTrim
    for i in 0..<n where radii[i] > 0 {
        let ein = edges[(i + n - 1) % n], eout = edges[i]
        let tin = ein.tangent(1).unit, tout = eout.tangent(0).unit
        let delta = acos(max(-1, min(1, tin.dot(tout))))
        let s = radii[i] * tan(delta / 2)
        endTrim[(i + n - 1) % n] = s
        startTrim[i] = s
    }
    var trimmed: [Cubic] = []
    for i in 0..<n {
        var e = edges[i]
        let len = e.length()
        var sT = startTrim[i], eT = endTrim[i]
        if sT + eT > 0.9 * len { let f = 0.9 * len / (sT + eT); sT *= f; eT *= f }
        if eT > 0 { e = e.split(e.t(atLength: len - eT)).0 }
        if sT > 0 { e = e.split(e.t(atLength: sT)).1 }
        trimmed.append(e)
    }
    var out: [Cubic] = []
    for i in 0..<n {
        out.append(trimmed[i])
        let j = (i + 1) % n
        if radii[j] > 0 {
            let next = trimmed[j]
            let P = trimmed[i].p3, Q = next.p0
            let tin = trimmed[i].tangent(1).unit, tout = next.tangent(0).unit
            let chord = (Q - P).length
            let delta = acos(max(-1, min(1, tin.dot(tout))))
            let h: CGFloat
            if delta > 1e-3 {
                let R = chord / (2 * sin(delta / 2))
                h = (4.0 / 3.0) * tan(delta / 4) * R
            } else { h = chord / 3 }
            out.append(Cubic(p0: P, c1: P + tin * h, c2: Q - tout * h, p3: Q))
        }
    }
    return out
}

func bezierPath(_ cubics: [Cubic], map: (CGPoint) -> NSPoint) -> NSBezierPath {
    let p = NSBezierPath()
    guard let first = cubics.first else { return p }
    p.move(to: map(first.p0))
    for c in cubics { p.curve(to: map(c.p3), controlPoint1: map(c.c1), controlPoint2: map(c.c2)) }
    p.close()
    return p
}

/// Area centroid of a closed outline (flattened), in the outline's own space.
func centroid(_ cubics: [Cubic]) -> CGPoint {
    var pts: [CGPoint] = []
    for c in cubics { for i in 0..<24 { pts.append(c.point(CGFloat(i) / 24)) } }
    var area: CGFloat = 0, cx: CGFloat = 0, cy: CGFloat = 0
    for i in 0..<pts.count {
        let p = pts[i], q = pts[(i + 1) % pts.count]
        let cross = p.x * q.y - q.x * p.y
        area += cross; cx += (p.x + q.x) * cross; cy += (p.y + q.y) * cross
    }
    area *= 0.5
    return CGPoint(x: cx / (6 * area), y: cy / (6 * area))
}

// MARK: - The bolt design

/// Bolt authored in a free design space (y-down, height 100), ring order clockwise on screen:
/// A top-left corner, B top-right corner, C right notch outer, D right notch inner, E tip,
/// F left notch outer, G left notch inner. Radii / bows are fractions of the design width.
/// The vertex bounding box is mapped onto `box` when building the outline.
struct BoltDesign {
    var verts: [CGPoint]
    var radii: [CGFloat]
    var bows: [(CGFloat, CGFloat)]

    var bbox: CGRect {
        let xs = verts.map { $0.x }, ys = verts.map { $0.y }
        return CGRect(x: xs.min()!, y: ys.min()!, width: xs.max()! - xs.min()!, height: ys.max()! - ys.min()!)
    }
    var aspect: CGFloat { bbox.width / bbox.height }

    func cubics(box: CGRect) -> [Cubic] {
        let bb = bbox
        let vs = verts.map { CGPoint(x: ($0.x - bb.minX) / bb.width, y: ($0.y - bb.minY) / bb.height) }
        let W = box.width, H = box.height
        let pts = vs.map { CGPoint(x: box.minX + $0.x * W, y: box.minY + $0.y * H) }
        return smoothPolygon(pts, radii: radii.map { $0 * W }, bows: bows.map { ($0.0 * W, $0.1 * W) })
    }

    /// Linear blend towards another design with the same vertex count (t = 0 → self, 1 → other).
    func blended(with o: BoltDesign, _ t: CGFloat) -> BoltDesign {
        BoltDesign(verts: zip(verts, o.verts).map { lerp($0, $1, t) },
                   radii: zip(radii, o.radii).map { lerp($0, $1, t) },
                   bows: zip(bows, o.bows).map { (lerp($0.0, $1.0, t), lerp($0.1, $1.1, t)) })
    }
}

// Both bands share one ≈28° lean (dx/dy ≈ 0.5). The upper band tapers very slightly, the lower
// band is a wedge to a needle tip. Top cap is tilted perpendicular-ish to the lean and well rounded.
let iconBolt = BoltDesign(
    verts: [CGPoint(x: 0.0, y: 8.0),     // A top-left
            CGPoint(x: 23.0, y: 0.0),    // B top-right
            CGPoint(x: 48.7, y: 57.0),   // C right notch outer
            CGPoint(x: 32.0, y: 57.0),   // D right notch inner
            CGPoint(x: 46.0, y: 100.0),  // E tip
            CGPoint(x: 2.5, y: 43.0),    // F left notch outer
            CGPoint(x: 21.5, y: 43.0)],  // G left notch inner
    radii: [0.16, 0.16, 0.04, 0.0, 0.015, 0.04, 0.0],
    bows: [(0.03, 0.03),     // A→B top cap
           (0.05, 0.03),     // B→C upper right edge (convex)
           (0.0, 0.0),       // C→D notch
           (-0.03, -0.02),   // D→E lower right edge (concave)
           (0.05, 0.04),     // E→F long lower-left edge (convex)
           (0.0, 0.0),       // F→G notch
           (-0.03, -0.03)]   // G→A upper left edge (concave, follows the band's curve)
)

/// Small-size / menu-bar silhouette: same lean, both bands fatter, tip a touch blunter, notches
/// opened so they survive as a gap at 1x. Blended into `iconBolt` for the 16–64 px icons.
let fatBolt = BoltDesign(
    verts: [CGPoint(x: 0.0, y: 8.0),
            CGPoint(x: 26.0, y: 0.0),
            CGPoint(x: 51.0, y: 56.0),
            CGPoint(x: 26.0, y: 56.0),
            CGPoint(x: 48.0, y: 100.0),
            CGPoint(x: 0.0, y: 44.0),
            CGPoint(x: 22.0, y: 44.0)],
    radii: [0.14, 0.14, 0.02, 0.0, 0.03, 0.02, 0.0],
    bows: [(0.03, 0.03), (0.04, 0.03), (0, 0), (-0.015, -0.015), (0.04, 0.04), (0, 0), (-0.02, -0.02)]
)

/// Menu-bar silhouette: same lean, both bands ≈3.5 px thick at 1x (the weight of SF `bolt.fill`
/// at 15 pt medium), tip blunted so the wedge never thins below ~1.5 px until its last pixel.
let menuBolt = BoltDesign(
    verts: [CGPoint(x: 0.0, y: 9.0),
            CGPoint(x: 28.0, y: 0.0),
            CGPoint(x: 55.0, y: 55.0),
            CGPoint(x: 30.0, y: 55.0),
            CGPoint(x: 51.0, y: 100.0),
            CGPoint(x: 0.0, y: 46.0),
            CGPoint(x: 25.0, y: 46.0)],
    radii: [0.13, 0.13, 0.02, 0.0, 0.05, 0.02, 0.0],
    bows: [(0.03, 0.03), (0.04, 0.03), (0, 0), (-0.012, -0.012), (0.04, 0.04), (0, 0), (-0.02, -0.02)]
)

/// Places a bolt of `height` so that its optical centre lands on `centre` (y-down space).
/// The optical centre is a blend between the bounding-box centre and the area centroid — the
/// broad upper band carries the mass, so pure bbox centring reads top-left-heavy, pure centroid
/// centring pushes the needle tip into the corner.
func place(_ design: BoltDesign, height: CGFloat, centre: CGPoint, biasX: CGFloat, biasY: CGFloat) -> CGRect {
    let w = height * design.aspect
    let box0 = CGRect(x: centre.x - w / 2, y: centre.y - height / 2, width: w, height: height)
    let c = centroid(design.cubics(box: box0))
    let optical = CGPoint(x: lerp(box0.midX, c.x, biasX), y: lerp(box0.midY, c.y, biasY))
    return box0.offsetBy(dx: centre.x - optical.x, dy: centre.y - optical.y)
}

// MARK: - Size-dependent tuning

struct Tuning {
    var fat: CGFloat        // 0 = icon silhouette, 1 = fatBolt
    var trail: Bool         // motion smear behind the bolt
    var bloom: CGFloat      // multiplier on bloom radii (1024-space units)
    var bloomAlpha: CGFloat // multiplier on bloom alphas
    var height: CGFloat     // bolt height in 1024 space
}

func tuning(for px: CGFloat) -> Tuning {
    switch px {
    case ..<24:  return Tuning(fat: 1.0, trail: false, bloom: 0.55, bloomAlpha: 1.25, height: 660)   // 16
    case ..<48:  return Tuning(fat: 0.7, trail: false, bloom: 0.65, bloomAlpha: 1.15, height: 648)   // 32
    case ..<96:  return Tuning(fat: 0.35, trail: false, bloom: 0.8, bloomAlpha: 1.05, height: 640)   // 64
    case ..<192: return Tuning(fat: 0.1, trail: true, bloom: 0.9, bloomAlpha: 1.0, height: 632)      // 128
    default:     return Tuning(fat: 0.0, trail: true, bloom: 1.0, bloomAlpha: 1.0, height: 632)      // 256+
    }
}

// MARK: - The app icon

/// Draws the full icon (shadow included) into a `px`-square at `origin` of the current context.
func drawIcon(px: CGFloat, at origin: NSPoint, grid: Bool = false) {
    let k = px / 1024
    let tune = tuning(for: px)
    let T = NSAffineTransform()
    T.translateX(by: origin.x, yBy: origin.y)
    T.scale(by: k)
    func tp(_ p: NSBezierPath) -> NSBezierPath { T.transform(p) }
    func tr(_ r: NSRect) -> NSRect {
        NSRect(x: origin.x + r.minX * k, y: origin.y + r.minY * k, width: r.width * k, height: r.height * k)
    }
    func tpt(_ p: CGPoint) -> NSPoint { NSPoint(x: origin.x + p.x * k, y: origin.y + p.y * k) }
    /// y-down 1024 bolt space → context
    func md(_ p: CGPoint) -> NSPoint { NSPoint(x: origin.x + p.x * k, y: origin.y + (1024 - p.y) * k) }

    let bodyRect = NSRect(x: 100, y: 100, width: 824, height: 824)
    let body = tp(squircle(bodyRect, radius: 824 * 0.2237))

    // 1. Drop shadow outside the body.
    saved {
        let sh = NSShadow()
        sh.shadowColor = NSColor.black.withAlphaComponent(0.30)
        sh.shadowBlurRadius = 22 * k
        sh.shadowOffset = NSSize(width: 0, height: -10 * k)
        sh.set()
        hex(0x1A1550).setFill()
        body.fill()
    }

    // Bolt geometry (y-down 1024 space), optically centred on the body.
    let design = iconBolt.blended(with: fatBolt, tune.fat)
    let boltBox = place(design, height: tune.height, centre: CGPoint(x: 512, y: 512), biasX: 0.55, biasY: 0.25)
    let cubics = design.cubics(box: boltBox)
    let bolt = bezierPath(cubics, map: md)
    // Travel axis: from the broad end to the tip (y-down space).
    let topC = CGPoint(x: boltBox.minX + 0.24 * boltBox.width, y: boltBox.minY)
    let tipP = CGPoint(x: boltBox.minX + 0.94 * boltBox.width, y: boltBox.maxY)
    let axis = (tipP - topC).unit

    saved {
        body.addClip()

        // 2. Base gradient: deep indigo (bottom-left) → violet (top-right).
        NSGradient(colorsAndLocations:
            (hex(0x171352), 0.0),
            (hex(0x2A2186), 0.45),
            (hex(0x5B33C9), 1.0))!
            .draw(in: tr(bodyRect), angle: 52)

        // 3. Atmosphere: violet bloom around the bolt's body, cool pool where the tip lands.
        let ctx = NSGraphicsContext.current!.cgContext
        let cs = CGColorSpace(name: CGColorSpace.sRGB)!
        func radial(_ c: CGPoint, _ r: CGFloat, _ col: NSColor, _ a0: CGFloat) {
            let g = CGGradient(colorsSpace: cs, colors: [
                col.withAlphaComponent(a0).cgColor,
                col.withAlphaComponent(a0 * 0.35).cgColor,
                col.withAlphaComponent(0).cgColor] as CFArray, locations: [0, 0.45, 1])!
            let cc = tpt(c)
            ctx.drawRadialGradient(g, startCenter: cc, startRadius: 0, endCenter: cc, endRadius: r * k, options: [])
        }
        radial(CGPoint(x: 470, y: 620), 460, hex(0x9B6CFF), 0.55)
        radial(CGPoint(x: 640, y: 230), 300, hex(0x3B5BE0), 0.32)

        // 4 + 5. Everything luminous is clipped to the body MINUS the bolt, so the bolt's own edge
        // stays a hard, anti-aliased line and nothing bleeds onto the white.
        saved {
            let outside = NSBezierPath()
            outside.append(tp(NSBezierPath(rect: bodyRect)))
            outside.append(bolt)
            outside.windingRule = .evenOdd
            outside.addClip()

            // 4. Motion smear: faint ghosts trailing opposite to the direction of travel.
            if tune.trail {
                let steps = 12
                for i in 1...steps {
                    let f = CGFloat(i) / CGFloat(steps)
                    let off = axis * (-10 - 100 * f)
                    let ghost = bezierPath(cubics.map { $0.transformed { $0 + off } }, map: md)
                    let a = 0.11 * pow(1 - f, 1.8)
                    glow(ghost, color: hex(0xD2C4FF, a), blur: (10 + 22 * f) * k)
                }
            }

            // 5. Bloom: wide violet, medium lavender, tight lavender rim. The tight layer is
            // deliberately not white so the body/halo boundary keeps contrast.
            let b = tune.bloom * k, a = tune.bloomAlpha
            glow(bolt, color: hex(0xA27BFF, min(1, 0.95 * a)), blur: 120 * b)
            glow(bolt, color: hex(0xCDBBFF, min(1, 0.80 * a)), blur: 42 * b)
            glow(bolt, color: hex(0xE6DDFF, min(1, 0.70 * a)), blur: 12 * b)
        }

        // 6. Bolt body: crisp fill, top-lit (white → #F2EEFF at the bottom) for a hint of volume.
        NSGradient(colors: [hex(0xFFFFFF), hex(0xF2EEFF)])!.draw(in: bolt, angle: -90)

        // 7. Body lighting: top sheen + thin light rim on the upper edge of the squircle.
        NSGradient(colors: [hex(0xFFFFFF, 0.14), hex(0xFFFFFF, 0.0)])!
            .draw(in: tr(NSRect(x: 100, y: 512, width: 824, height: 412)), angle: -90)
        saved {
            let rim = body.cgPath.copy(strokingWithWidth: 6 * k, lineCap: .round, lineJoin: .round, miterLimit: 10)
            ctx.addPath(rim)
            ctx.clip()
            NSGradient(colors: [hex(0xFFFFFF, 0.45), hex(0xFFFFFF, 0.08), hex(0xFFFFFF, 0.0)])!
                .draw(in: tr(bodyRect), angle: -90)
        }

        if grid {
            // Apple-grid overlay (inspection only): centre cross, bbox, centroid.
            hex(0x00E5FF, 0.8).setStroke()
            let cross = NSBezierPath(); cross.lineWidth = 1
            cross.move(to: tpt(CGPoint(x: 512, y: 100))); cross.line(to: tpt(CGPoint(x: 512, y: 924)))
            cross.move(to: tpt(CGPoint(x: 100, y: 512))); cross.line(to: tpt(CGPoint(x: 924, y: 512)))
            cross.stroke()
            hex(0xFF3B30, 0.8).setStroke()
            let bb = NSBezierPath(rect: NSRect(x: md(CGPoint(x: boltBox.minX, y: boltBox.maxY)).x,
                                               y: md(CGPoint(x: boltBox.minX, y: boltBox.maxY)).y,
                                               width: boltBox.width * k, height: boltBox.height * k))
            bb.lineWidth = 1; bb.stroke()
            let c = centroid(cubics)
            hex(0xFFCC00).setFill(); circle(CGPoint(x: md(c).x, y: md(c).y), 4).fill()
        }
    }
}

// MARK: - Menu-bar template glyph

/// Bolt silhouette for the menu bar, designed in an 18-pt box (y-down) with a 16-pt-tall glyph.
/// `scale` 1 → 18 px, 2 → 36 px. Pure `color` on transparent. `active` adds a filled circle at the
/// lower right with a clear knockout ring, and nudges the bolt left so the badge gets room.
func drawMenubar(scale: CGFloat, at origin: NSPoint, color: NSColor, active: Bool) {
    let H: CGFloat = 16
    let shift: CGFloat = active ? -1.25 : 0
    let box = place(menuBolt, height: H, centre: CGPoint(x: 9 + shift, y: 9), biasX: 0.55, biasY: 0.25)
    let cubics = menuBolt.cubics(box: box)
    func md(_ p: CGPoint) -> NSPoint { NSPoint(x: origin.x + p.x * scale, y: origin.y + (18 - p.y) * scale) }
    let bolt = bezierPath(cubics, map: md)

    saved {
        if active {
            // Knockout ring: clear the area under the badge before filling the bolt.
            let badgeC = CGPoint(x: 14.6, y: 14.6)
            let ring = circle(CGPoint(x: md(badgeC).x, y: md(badgeC).y), 3.9 * scale)
            let keep = NSBezierPath()
            keep.append(NSBezierPath(rect: NSRect(x: origin.x, y: origin.y, width: 18 * scale, height: 18 * scale)))
            keep.append(ring)
            keep.windingRule = .evenOdd
            keep.addClip()
            color.setFill(); bolt.fill()
            NSGraphicsContext.restoreGraphicsState(); NSGraphicsContext.saveGraphicsState()
            color.setFill()
            circle(CGPoint(x: md(badgeC).x, y: md(badgeC).y), 2.6 * scale).fill()
        } else {
            color.setFill(); bolt.fill()
        }
    }
}

// MARK: - Inspection sheet helpers

func label(_ s: String, at p: NSPoint, color: NSColor, size: CGFloat = 13, centered: Bool = true) {
    let attrs: [NSAttributedString.Key: Any] = [
        .font: NSFont.systemFont(ofSize: size, weight: .medium),
        .foregroundColor: color]
    let str = NSAttributedString(string: s, attributes: attrs)
    let sz = str.size()
    str.draw(at: NSPoint(x: centered ? p.x - sz.width / 2 : p.x, y: p.y))
}

func drawSymbol(_ name: String, pointSize: CGFloat, color: NSColor, centerAt c: NSPoint) {
    let cfg = NSImage.SymbolConfiguration(pointSize: pointSize, weight: .medium)
        .applying(.init(paletteColors: [color]))
    if let sym = NSImage(systemSymbolName: name, accessibilityDescription: nil)?.withSymbolConfiguration(cfg) {
        let s = sym.size
        sym.draw(in: NSRect(x: c.x - s.width / 2, y: c.y - s.height / 2, width: s.width, height: s.height))
    }
}

/// Nearest-neighbour blow-up of a small rendering.
func zoom(_ rep: NSBitmapImageRep, by z: CGFloat, at p: NSPoint) {
    let img = NSImage(size: rep.size); img.addRepresentation(rep)
    saved {
        NSGraphicsContext.current!.imageInterpolation = .none
        img.draw(in: NSRect(x: p.x, y: p.y, width: CGFloat(rep.pixelsWide) * z, height: CGFloat(rep.pixelsHigh) * z),
                 from: .zero, operation: .sourceOver, fraction: 1)
    }
}

/// A fake menu bar strip (22 pt tall) with our glyph(s) between real SF Symbols, at `scale`.
func drawMenuBarStrip(scale: CGFloat, at origin: NSPoint, dark: Bool) -> NSRect {
    let w: CGFloat = 236 * scale, h: CGFloat = 22 * scale
    let r = NSRect(x: origin.x, y: origin.y, width: w, height: h)
    (dark ? hex(0x2B2B2E) : hex(0xE7E6EA)).setFill()
    NSBezierPath(roundedRect: r, xRadius: 4 * scale, yRadius: 4 * scale).fill()
    let fg: NSColor = dark ? .white : .black
    let cy = r.midY
    var x = r.minX + 10 * scale
    func sym(_ n: String) { drawSymbol(n, pointSize: 15 * scale, color: fg, centerAt: NSPoint(x: x + 11 * scale, y: cy)); x += 30 * scale }
    sym("wifi")
    drawMenubar(scale: scale, at: NSPoint(x: x + 2 * scale, y: cy - 9 * scale), color: fg, active: false); x += 30 * scale
    drawMenubar(scale: scale, at: NSPoint(x: x + 2 * scale, y: cy - 9 * scale), color: fg, active: true); x += 30 * scale
    sym("bolt.fill")
    sym("dot.radiowaves.up.forward")
    sym("battery.75percent")
    sym("magnifyingglass")
    return r
}

// MARK: - Outputs

if let dir = opts.iconset {
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    for base in [16, 32, 128, 256, 512] {
        for (scale, suffix) in [(1, ""), (2, "@2x")] {
            let px = base * scale
            let rep = render(px, px) { drawIcon(px: CGFloat(px), at: .zero) }
            try savePNG(rep, dir.appendingPathComponent("icon_\(base)x\(base)\(suffix).png"))
        }
    }
    print("wrote iconset → \(dir.path)")
}

if let dir = opts.menubarDir {
    for (name, active) in [("menubar", false), ("menubar-active", true)] {
        for (scale, suffix) in [(CGFloat(1), ""), (2, "@2x")] {
            let px = Int(18 * scale)
            let rep = render(px, px) { drawMenubar(scale: scale, at: .zero, color: .black, active: active) }
            try savePNG(rep, dir.appendingPathComponent("\(name)\(suffix).png"))
        }
    }
    print("wrote menubar.png, menubar@2x.png, menubar-active.png, menubar-active@2x.png → \(dir.path)")
}

if let file = opts.preview {
    let W = 1280
    let rep = render(W, W) {
        hex(0xECECF1).setFill(); NSRect(x: 0, y: 0, width: W, height: W).fill()
        drawIcon(px: 1024, at: NSPoint(x: 128, y: 128))
    }
    try savePNG(rep, file)
    print("wrote preview → \(file.path)")
}

if let file = opts.sheet {
    let W = 1400, H = 1300
    let light = hex(0xF2F2F7), dark = hex(0x1C1C1E)
    let grid = opts.grid
    // Pre-render the small sizes once so the zooms show the real pixels.
    func small(_ px: Int) -> NSBitmapImageRep { render(px, px) { drawIcon(px: CGFloat(px), at: .zero) } }
    let s16 = small(16), s32 = small(32), s64 = small(64)
    func glyph(_ scale: CGFloat, _ active: Bool, _ color: NSColor) -> NSBitmapImageRep {
        let px = Int(18 * scale)
        return render(px, px) { drawMenubar(scale: scale, at: .zero, color: color, active: active) }
    }
    let rep = render(W, H) {
        // Row 1: 512 light / dark.
        light.setFill(); NSRect(x: 0, y: 700, width: 700, height: 600).fill()
        dark.setFill(); NSRect(x: 700, y: 700, width: 700, height: 600).fill()
        drawIcon(px: 512, at: NSPoint(x: 94, y: 750), grid: grid)
        drawIcon(px: 512, at: NSPoint(x: 794, y: 750))
        label("512 px · light", at: NSPoint(x: 350, y: 716), color: hex(0x6E6E73))
        label("512 px · dark", at: NSPoint(x: 1050, y: 716), color: hex(0x98989D))

        // Row 2: natural-size renders 256 … 16, and zooms of 32 / 16.
        hex(0xFFFFFF).setFill(); NSRect(x: 0, y: 330, width: 700, height: 370).fill()
        hex(0x000000).setFill(); NSRect(x: 700, y: 330, width: 700, height: 370).fill()
        for (i, bg) in [0, 700].enumerated() {
            let fg = i == 0 ? hex(0x6E6E73) : hex(0x98989D)
            var x = CGFloat(bg) + 24
            for s in [256, 128, 64, 32, 16] {
                let sz = CGFloat(s)
                drawIcon(px: sz, at: NSPoint(x: x, y: 560 - sz / 2))
                label("\(s)", at: NSPoint(x: x + sz / 2, y: 410), color: fg, size: 11)
                x += sz + 16
            }
            zoom(s32, by: 4, at: NSPoint(x: CGFloat(bg) + 560, y: 560 - 64))
            zoom(s16, by: 4, at: NSPoint(x: CGFloat(bg) + 560, y: 440 - 32))
            label("32 ×4", at: NSPoint(x: CGFloat(bg) + 624, y: 480), color: fg, size: 11)
            label("16 ×4", at: NSPoint(x: CGFloat(bg) + 624, y: 390), color: fg, size: 11)
            label("natural size", at: NSPoint(x: CGFloat(bg) + 180, y: 676), color: fg, size: 11)
        }
        _ = s64

        // Row 3: menu bar strips at 2x and 1x, with zooms of the glyphs.
        hex(0xFFFFFF).setFill(); NSRect(x: 0, y: 0, width: 700, height: 330).fill()
        hex(0x000000).setFill(); NSRect(x: 700, y: 0, width: 700, height: 330).fill()
        for (i, bg) in [0, 700].enumerated() {
            let isDark = i == 1
            let fg = isDark ? hex(0x98989D) : hex(0x6E6E73)
            let x0 = CGFloat(bg) + 24
            _ = drawMenuBarStrip(scale: 2, at: NSPoint(x: x0, y: 262), dark: isDark)
            label("menu bar @2x · wifi · bolt · bolt+badge · SF bolt.fill · SF radiowaves · battery · search",
                  at: NSPoint(x: x0, y: 244), color: fg, size: 11, centered: false)
            _ = drawMenuBarStrip(scale: 1, at: NSPoint(x: x0, y: 206), dark: isDark)
            label("menu bar @1x", at: NSPoint(x: x0, y: 188), color: fg, size: 11, centered: false)
            // Zooms: 1x ×6, 2x ×3 (same on-sheet size), normal + active.
            let g: NSColor = isDark ? .white : .black
            let bgc = isDark ? hex(0x2B2B2E) : hex(0xE7E6EA)
            var zx = x0
            for (rep, z, name) in [(glyph(1, false, g), CGFloat(6), "1x ×6"), (glyph(1, true, g), 6, "1x active ×6"),
                                   (glyph(2, false, g), 3, "2x ×3"), (glyph(2, true, g), 3, "2x active ×3")] {
                bgc.setFill(); NSRect(x: zx, y: 50, width: 108, height: 108).fill()
                zoom(rep, by: z, at: NSPoint(x: zx, y: 50))
                label(name, at: NSPoint(x: zx + 54, y: 30), color: fg, size: 11)
                zx += 124
            }
            // SF bolt.fill @1x ×6 for a size reference.
            let sf = render(18, 18) { drawSymbol("bolt.fill", pointSize: 15, color: g, centerAt: NSPoint(x: 9, y: 9)) }
            bgc.setFill(); NSRect(x: zx, y: 50, width: 108, height: 108).fill()
            zoom(sf, by: 6, at: NSPoint(x: zx, y: 50))
            label("SF bolt.fill ×6", at: NSPoint(x: zx + 54, y: 30), color: fg, size: 11)
        }
    }
    try savePNG(rep, file)
    // Diagnostics for the placement.
    let t = tuning(for: 1024)
    let d = iconBolt.blended(with: fatBolt, t.fat)
    let box = place(d, height: t.height, centre: CGPoint(x: 512, y: 512), biasX: 0.55, biasY: 0.25)
    let c = centroid(d.cubics(box: box))
    print(String(format: "bolt box x %.1f…%.1f  y %.1f…%.1f  centroid (%.1f, %.1f)", box.minX, box.maxX, box.minY, box.maxY, c.x, c.y))
    print("wrote sheet → \(file.path)")
}
