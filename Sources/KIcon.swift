import SwiftUI

/// 自绘图标集。路径逐个抄自效果图 docs/design/mockups/2026-11-09-main-window.html 顶部 <defs>：
/// 16×16 视口、线宽 1.3（个别 1.2 / 1.4 / 1.6）、圆头圆角，随 foregroundStyle 着色。
/// 效果图里没有对应图标的地方（系统菜单勾、控件自带的 chevron 等）继续用 SF Symbols。
enum KIcon: String, CaseIterable, Identifiable {
    case tr, wave, clock, book, film, mic, gear, clip, shot, doc, spk, copy, back
    case pin, x, warn, pause, text, spark, pen, sum, q, more, search, check

    var id: String { rawValue }

    /// 图标选择器里排在最前面的 7 个：效果图划词插件默认集合用到的。
    static let pluginPicks: [KIcon] = [.tr, .pen, .sum, .spark, .q, .book, .text]

    /// 存进配置里的名字。带前缀，和 SF Symbol 名字不会撞。
    var storageName: String { "kicon." + rawValue }

    init?(storageName: String) {
        guard storageName.hasPrefix("kicon.") else { return nil }
        self.init(rawValue: String(storageName.dropFirst(6)))
    }

    // MARK: 图层

    fileprivate enum Layer {
        case stroke(String, CGFloat = 1.3, round: Bool = true)
        case fill(String)
        /// 镂空：把图层里已画的内容擦掉一块（效果图里的白色填充）。
        case erase(String)
        case eraseStroke(String, CGFloat)
    }

    fileprivate var layers: [Layer] {
        switch self {
        case .tr:
            return [.stroke("M2 3h7M5.5 1.5V3M4 3c0 3 2 5.5 4.5 6.5M7.5 3c-.5 2.5-2.5 5-5.5 6.5M8.5 14.5l3-7 3 7M9.6 12h3.8")]
        case .wave:
            return [.stroke("M2 8h1M5 5v6M8 2.5v11M11 5v6M14 8h-1", 1.4)]
        case .clock:
            return [.stroke(Self.circle(8, 8, 6)), .stroke("M8 4.5V8l2.5 1.5")]
        case .book:
            return [.stroke("M2.5 3c2-.8 3.8-.8 5.5.5 1.7-1.3 3.5-1.3 5.5-.5v10c-2-.8-3.8-.8-5.5.5-1.7-1.3-3.5-1.3-5.5-.5zM8 3.5v10")]
        case .film:
            return [.stroke(Self.rect(2, 3, 12, 10, 2)), .fill("M6.5 6v4l3.5-2z")]
        case .mic:
            return [.stroke(Self.rect(5.5, 1.5, 5, 8, 2.5)), .stroke("M3 7.5a5 5 0 0 0 10 0M8 12.5v2")]
        case .gear:
            return [.stroke(Self.circle(8, 8, 2.2)),
                    .stroke("M8 1.5v2M8 12.5v2M1.5 8h2M12.5 8h2M3.4 3.4l1.4 1.4M11.2 11.2l1.4 1.4M3.4 12.6l1.4-1.4M11.2 4.8l1.4-1.4")]
        case .clip:
            return [.stroke(Self.rect(3.5, 3, 9, 11, 1.5)),
                    .erase(Self.rect(6, 1.5, 4, 3, 1)),
                    .stroke(Self.rect(6, 1.5, 4, 3, 1), 1.2)]
        case .shot:
            return [.stroke("M2 5V3a1 1 0 0 1 1-1h2M11 2h2a1 1 0 0 1 1 1v2M14 11v2a1 1 0 0 1-1 1h-2M5 14H3a1 1 0 0 1-1-1v-2"),
                    .stroke("M5.5 6.5h5M5.5 9.5h3")]
        case .doc:
            return [.stroke("M4 1.5h5l3.5 3.5v9a.5.5 0 0 1-.5.5H4a.5.5 0 0 1-.5-.5v-12a.5.5 0 0 1 .5-.5zM9 1.5V5h3.5")]
        case .spk:
            return [.stroke("M2.5 6h2.5l3.5-3v10L5 10H2.5z"), .stroke("M11 5.5a3.5 3.5 0 0 1 0 5M12.8 3.8a6 6 0 0 1 0 8.4")]
        case .copy:
            return [.stroke(Self.rect(5, 5, 9, 9, 1.8)),
                    .stroke("M11 5V3.5A1.5 1.5 0 0 0 9.5 2h-6A1.5 1.5 0 0 0 2 3.5v6A1.5 1.5 0 0 0 3.5 11H5")]
        case .back:
            return [.stroke("M6 4L2.5 7.5 6 11M3 7.5h7a3.5 3.5 0 0 1 0 7H8")]
        case .pin:
            return [.stroke("M10 1.8l4.2 4.2-2.3.8-2.5 2.5.3 3.2-1.4 1.4-2.6-2.6L2.5 14.5M5.7 11.3L3 8.6l1.4-1.4 3.2.3 2.5-2.5z", 1.2)]
        case .x:
            return [.stroke("M4 4l8 8M12 4l-8 8", 1.4)]
        case .warn:
            return [.fill("M8 1.8L15 14H1z"),
                    .eraseStroke("M8 6v3.6", 1.5),
                    .erase(Self.circle(8, 11.6, 0.9))]
        case .pause:
            return [.stroke("M5 3v10M11 3v10", 2)]
        case .text:
            return [.stroke("M3 4h10M3 8h10M3 12h6", 1.4)]
        case .spark:
            return [.stroke("M8 1.5l1.4 4.1 4.1 1.4-4.1 1.4L8 12.5 6.6 8.4 2.5 7l4.1-1.4z", 1.2)]
        case .pen:
            return [.stroke("M11 2.5l2.5 2.5-8 8H3v-2.5z")]
        case .sum:
            return [.stroke("M12 3H4l4.5 5L4 13h8")]
        case .q:
            return [.stroke(Self.circle(8, 8, 6)),
                    .stroke("M6.3 6.3a1.8 1.8 0 1 1 2.4 1.7c-.5.2-.7.6-.7 1.1v.4"),
                    .fill(Self.circle(8, 11.4, 0.8))]
        case .more:
            return [.fill(Self.circle(3.5, 8, 1.2)), .fill(Self.circle(8, 8, 1.2)), .fill(Self.circle(12.5, 8, 1.2))]
        case .search:
            return [.stroke(Self.circle(7, 7, 4.5), 1.4), .stroke("M10.5 10.5L14 14", 1.4)]
        case .check:
            return [.stroke("M3.5 8.5l3 3 6-7", 1.6)]
        }
    }

    private static func circle(_ cx: Double, _ cy: Double, _ r: Double) -> String {
        "M\(cx - r) \(cy)a\(r) \(r) 0 1 0 \(2 * r) 0a\(r) \(r) 0 1 0 \(-2 * r) 0z"
    }

    private static func rect(_ x: Double, _ y: Double, _ w: Double, _ h: Double, _ r: Double) -> String {
        "M\(x + r) \(y)h\(w - 2 * r)a\(r) \(r) 0 0 1 \(r) \(r)v\(h - 2 * r)a\(r) \(r) 0 0 1 \(-r) \(r)h\(-(w - 2 * r))a\(r) \(r) 0 0 1 \(-r) \(-r)v\(-(h - 2 * r))a\(r) \(r) 0 0 1 \(r) \(-r)z"
    }

    /// 解析好的路径缓存。16×16 坐标系。
    fileprivate func parsedLayers() -> [(Layer, Path)] {
        if let cached = KIconCache.shared.get(self) { return cached }
        let parsed = layers.map { layer -> (Layer, Path) in
            switch layer {
            case .stroke(let d, _, _), .fill(let d), .erase(let d), .eraseStroke(let d, _):
                return (layer, SVGPathParser.path(d))
            }
        }
        KIconCache.shared.set(self, parsed)
        return parsed
    }
}

private final class KIconCache: @unchecked Sendable {
    static let shared = KIconCache()
    private let lock = NSLock()
    private var store: [KIcon: [(KIcon.Layer, Path)]] = [:]
    func get(_ i: KIcon) -> [(KIcon.Layer, Path)]? { lock.lock(); defer { lock.unlock() }; return store[i] }
    func set(_ i: KIcon, _ v: [(KIcon.Layer, Path)]) { lock.lock(); store[i] = v; lock.unlock() }
}

/// 把 KIcon 画出来。`size` 是边长（16×16 视口按比例缩放，线宽同比缩放，和效果图里 svg 缩放一致）。
struct KIconView: View {
    let icon: KIcon
    var size: CGFloat = 13

    init(_ icon: KIcon, size: CGFloat = 13) {
        self.icon = icon
        self.size = size
    }

    var body: some View {
        let parsed = icon.parsedLayers()
        let scale = size / 16
        Canvas { context, _ in
            context.drawLayer { layer in
                layer.scaleBy(x: scale, y: scale)
                for (l, path) in parsed {
                    switch l {
                    case .stroke(_, let w, _):
                        layer.stroke(path, with: .foreground,
                                     style: StrokeStyle(lineWidth: w, lineCap: .round, lineJoin: .round))
                    case .fill:
                        layer.fill(path, with: .foreground)
                    case .erase:
                        layer.blendMode = .clear
                        layer.fill(path, with: .color(.black))
                        layer.blendMode = .normal
                    case .eraseStroke(_, let w):
                        layer.blendMode = .clear
                        layer.stroke(path, with: .color(.black),
                                     style: StrokeStyle(lineWidth: w, lineCap: .round, lineJoin: .round))
                        layer.blendMode = .normal
                    }
                }
            }
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}

/// 存量配置里的图标名：自绘（kicon.xxx）或 SF Symbol（旧版本、用户自己选的）。图标选择器、插件条都走它。
struct StoredSymbol: View {
    let name: String
    var size: CGFloat = 13
    var font: Font = Theme.TypeScale.glyph

    var body: some View {
        if let k = KIcon(storageName: name) {
            KIconView(k, size: size)
        } else if name.hasPrefix("kicon.") {
            Image(systemName: "sparkles").font(font)
        } else {
            Image(systemName: name).font(font)
        }
    }
}

// MARK: - 最小 SVG path 解析（M L H V C S Q A Z，大小写都认）

enum SVGPathParser {
    static func path(_ d: String) -> Path {
        var p = Path()
        var scanner = Tokens(d)
        var cur = CGPoint.zero
        var start = CGPoint.zero
        var lastCtrl: CGPoint? = nil
        var cmd: Character = "M"

        while let next = scanner.peekCommand() ?? (scanner.hasNumber ? cmd : nil) {
            if scanner.peekCommand() != nil { scanner.consumeCommand() }
            cmd = next
            let rel = cmd.isLowercase
            let c = Character(cmd.uppercased())
            func pt(_ x: CGFloat, _ y: CGFloat) -> CGPoint { rel ? CGPoint(x: cur.x + x, y: cur.y + y) : CGPoint(x: x, y: y) }
            switch c {
            case "M":
                guard let x = scanner.number(), let y = scanner.number() else { return p }
                cur = pt(x, y); start = cur; p.move(to: cur); lastCtrl = nil
                cmd = rel ? "l" : "L"
            case "L":
                guard let x = scanner.number(), let y = scanner.number() else { return p }
                cur = pt(x, y); p.addLine(to: cur); lastCtrl = nil
            case "H":
                guard let x = scanner.number() else { return p }
                cur = CGPoint(x: rel ? cur.x + x : x, y: cur.y); p.addLine(to: cur); lastCtrl = nil
            case "V":
                guard let y = scanner.number() else { return p }
                cur = CGPoint(x: cur.x, y: rel ? cur.y + y : y); p.addLine(to: cur); lastCtrl = nil
            case "C":
                guard let x1 = scanner.number(), let y1 = scanner.number(),
                      let x2 = scanner.number(), let y2 = scanner.number(),
                      let x = scanner.number(), let y = scanner.number() else { return p }
                let c1 = pt(x1, y1), c2 = pt(x2, y2), e = pt(x, y)
                p.addCurve(to: e, control1: c1, control2: c2)
                lastCtrl = c2; cur = e
            case "S":
                guard let x2 = scanner.number(), let y2 = scanner.number(),
                      let x = scanner.number(), let y = scanner.number() else { return p }
                let c1 = lastCtrl.map { CGPoint(x: 2 * cur.x - $0.x, y: 2 * cur.y - $0.y) } ?? cur
                let c2 = pt(x2, y2), e = pt(x, y)
                p.addCurve(to: e, control1: c1, control2: c2)
                lastCtrl = c2; cur = e
            case "Q":
                guard let x1 = scanner.number(), let y1 = scanner.number(),
                      let x = scanner.number(), let y = scanner.number() else { return p }
                let c1 = pt(x1, y1), e = pt(x, y)
                p.addQuadCurve(to: e, control: c1)
                lastCtrl = nil; cur = e
            case "A":
                guard let rx = scanner.number(), let ry = scanner.number(), let rot = scanner.number(),
                      let large = scanner.flag(), let sweep = scanner.flag(),
                      let x = scanner.number(), let y = scanner.number() else { return p }
                let e = pt(x, y)
                addArc(&p, from: cur, to: e, rx: rx, ry: ry, rotation: rot, large: large, sweep: sweep)
                cur = e; lastCtrl = nil
            case "Z":
                p.closeSubpath(); cur = start; lastCtrl = nil
            default:
                return p
            }
        }
        return p
    }

    /// SVG 椭圆弧 → 三次贝塞尔（endpoint → center 参数化，W3C 附录 F.6）。
    private static func addArc(_ p: inout Path, from p0: CGPoint, to p1: CGPoint,
                               rx rx0: CGFloat, ry ry0: CGFloat, rotation: CGFloat, large: Bool, sweep: Bool) {
        if p0 == p1 { return }
        var rx = abs(rx0), ry = abs(ry0)
        if rx == 0 || ry == 0 { p.addLine(to: p1); return }
        let phi = rotation * .pi / 180
        let cosP = cos(phi), sinP = sin(phi)
        let dx = (p0.x - p1.x) / 2, dy = (p0.y - p1.y) / 2
        let x1p = cosP * dx + sinP * dy
        let y1p = -sinP * dx + cosP * dy
        let lambda = (x1p * x1p) / (rx * rx) + (y1p * y1p) / (ry * ry)
        if lambda > 1 { let s = sqrt(lambda); rx *= s; ry *= s }
        let num = rx * rx * ry * ry - rx * rx * y1p * y1p - ry * ry * x1p * x1p
        let den = rx * rx * y1p * y1p + ry * ry * x1p * x1p
        var coef = den == 0 ? 0 : sqrt(max(0, num / den))
        if large == sweep { coef = -coef }
        let cxp = coef * (rx * y1p / ry)
        let cyp = coef * -(ry * x1p / rx)
        let cx = cosP * cxp - sinP * cyp + (p0.x + p1.x) / 2
        let cy = sinP * cxp + cosP * cyp + (p0.y + p1.y) / 2
        func angle(_ ux: CGFloat, _ uy: CGFloat, _ vx: CGFloat, _ vy: CGFloat) -> CGFloat {
            let a = atan2(ux * vy - uy * vx, ux * vx + uy * vy)
            return a
        }
        let theta1 = atan2((y1p - cyp) / ry, (x1p - cxp) / rx)
        var delta = angle((x1p - cxp) / rx, (y1p - cyp) / ry, (-x1p - cxp) / rx, (-y1p - cyp) / ry)
        if !sweep && delta > 0 { delta -= 2 * .pi }
        if sweep && delta < 0 { delta += 2 * .pi }
        let segs = max(1, Int(ceil(abs(delta) / (.pi / 2) - 1e-9)))
        let step = delta / CGFloat(segs)
        let t = 4.0 / 3.0 * tan(step / 4)
        var a = theta1
        for _ in 0..<segs {
            let b = a + step
            let ca = cos(a), sa = sin(a), cb = cos(b), sb = sin(b)
            func map(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
                CGPoint(x: cx + cosP * rx * x - sinP * ry * y, y: cy + sinP * rx * x + cosP * ry * y)
            }
            let c1 = map(ca - t * sa, sa + t * ca)
            let c2 = map(cb + t * sb, sb - t * cb)
            p.addCurve(to: map(cb, sb), control1: c1, control2: c2)
            a = b
        }
    }

    private struct Tokens {
        let chars: [Character]
        var i = 0
        init(_ s: String) { chars = Array(s) }

        private mutating func skipSep() {
            while i < chars.count, chars[i] == " " || chars[i] == "," || chars[i] == "\n" { i += 1 }
        }
        mutating func peekCommand() -> Character? {
            skipSep()
            guard i < chars.count, chars[i].isLetter else { return nil }
            return chars[i]
        }
        mutating func consumeCommand() { i += 1 }
        var hasNumber: Bool {
            var j = i
            while j < chars.count, chars[j] == " " || chars[j] == "," { j += 1 }
            guard j < chars.count else { return false }
            return chars[j].isNumber || chars[j] == "-" || chars[j] == "." || chars[j] == "+"
        }
        /// arc 的 flag 是单个 0/1，可以和后面的数字连写。
        mutating func flag() -> Bool? {
            skipSep()
            guard i < chars.count, chars[i] == "0" || chars[i] == "1" else { return nil }
            defer { i += 1 }
            return chars[i] == "1"
        }
        mutating func number() -> CGFloat? {
            skipSep()
            var s = ""
            var seenDot = false
            if i < chars.count, chars[i] == "-" || chars[i] == "+" { s.append(chars[i]); i += 1 }
            while i < chars.count {
                let c = chars[i]
                if c.isNumber { s.append(c) }
                else if c == ".", !seenDot { seenDot = true; s.append(c) }
                else { break }
                i += 1
            }
            guard let v = Double(s) else { return nil }
            return CGFloat(v)
        }
    }
}
