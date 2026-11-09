import AppKit
import Foundation

struct LiveCaptionSegment: Identifiable, Equatable {
    let id: UUID
    var laneID: UUID = UUID()
    var kind: SystemAudioTranslateController.SourceKind
    var source: String
    var speaker: Int
    /// binding key → translation
    var translations: [String: String]
    var errors: [String: String]
    var loadingProviderIDs: Set<String>
    /// Ranges in `source` that were covered on the way out. Empty when this segment was not sent.
    var maskRanges: [NSRange] = []
    /// Seconds from the moment listening began.
    var start: TimeInterval = 0
    var end: TimeInterval = 0

    func text(for providerID: String) -> String? {
        if let t = translations[providerID], !t.isEmpty { return t }
        if let e = errors[providerID], !e.isEmpty { return e }
        return nil
    }
}

struct ImmersiveCaptionLines: Equatable {
    var mark = ""
    var source = ""
    var sourcePartial = false
    var sourceMask: [NSRange] = []
    var translation = ""
    var translationPartial = false
}

/// 主文件里的字幕游标状态用到它。
struct CaptionCursor {
    var committed = ""
    var lastFull = ""
}

enum CaptionBudget {
    static let maxDuration: TimeInterval = 4.2
    private static let lock = NSLock()
    private static var screenWidth: CGFloat = 1280
    private static var surfaces: [String: CGFloat] = [:]
    private static var line: CGFloat = 480

    static func note(_ id: String, _ width: CGFloat) {
        let screen = NSScreen.main?.visibleFrame.width ?? screenWidth
        lock.lock()
        screenWidth = max(screen, screenWidth)
        if id == "screen" {
            if width > 80 { screenWidth = width }
        } else if width > 80 {
            surfaces[id] = width
        }
        let surface = surfaces.values.min() ?? screenWidth
        let area = max(240, min(surface, screen) - 96)
        line = min(area * 0.7, screen * 0.46)
        lock.unlock()
    }

    static var lineWidth: CGFloat {
        lock.lock()
        defer { lock.unlock() }
        return line
    }

    static func textWidth(_ text: String) -> CGFloat {
        let font = Theme.TypeScale.nsReading
        return ceil((text as NSString).size(withAttributes: [.font: font]).width)
    }

    /// 一句话里每个位置能排到多宽，一次量完。以前对每个字符前缀重新排版，
    /// 长句在老机器上是看得见的卡顿；现在按字增量累加，每句只排一遍。
    static func textWidths(_ text: String) -> [CGFloat] {
        let font = Theme.TypeScale.nsReading
        var widths: [CGFloat] = [0]
        widths.reserveCapacity(text.count + 1)
        var total: CGFloat = 0
        for ch in text {
            total += ceil((String(ch) as NSString).size(withAttributes: [.font: font]).width)
            widths.append(total)
        }
        return widths
    }
}

enum CaptionCut {
    static func split(_ text: String, finishAll: Bool) -> (ready: [String], held: String) {
        if text.isEmpty { return ([], "") }
        var ready: [String] = []
        for unit in units(of: text) {
            let parts = fitted(unit.text)
            if unit.closed || finishAll {
                ready.append(contentsOf: parts)
                continue
            }
            guard let last = parts.last else { return (ready, "") }
            if parts.count > 1 { ready.append(contentsOf: parts.dropLast()) }
            return (ready, last)
        }
        return (ready, "")
    }

    static func letterCount(_ text: String) -> Int {
        text.reduce(into: 0) { count, ch in
            if ch.isLetter { count += 1 }
        }
    }

    private static func fits(_ text: String) -> Bool {
        CaptionBudget.textWidth(text) <= CaptionBudget.lineWidth
    }

    private static func terminatorEnds(_ text: String) -> [String.Index] {
        var ends: [String.Index] = []
        var i = text.startIndex
        while i < text.endIndex {
            if isTerminator(text, at: i) {
                var end = text.index(after: i)
                while end < text.endIndex {
                    let ch = text[end]
                    if ch == ".", !isSentenceDot(text, at: end) { break }
                    if !"。！？!?…．".contains(ch) { break }
                    end = text.index(after: end)
                }
                ends.append(end)
                i = end
            } else {
                i = text.index(after: i)
            }
        }
        return ends
    }

    private static func isTerminator(_ text: String, at i: String.Index) -> Bool {
        let ch = text[i]
        if "。！？!?…．\n".contains(ch) { return true }
        if ch == "." { return isSentenceDot(text, at: i) }
        return false
    }

    private static let abbreviations: Set<String> = [
        "mr", "mrs", "ms", "dr", "prof", "sr", "jr", "st", "vs", "etc", "ie", "eg", "am", "pm", "fig", "no"
    ]

    private static func isSentenceDot(_ text: String, at i: String.Index) -> Bool {
        if i > text.startIndex {
            let prev = text[text.index(before: i)]
            if prev.isNumber { return false }
        }
        let after = text.index(after: i)
        if after < text.endIndex {
            let next = text[after]
            if next.isNumber || next == "." { return false }
        }
        if isAbbreviation(text, before: i) { return false }
        if after < text.endIndex {
            let next = text[after]
            if next == " " || next == "\n" || next == "\t" { return true }
            if next.isLetter, next.isUppercase { return true }
            return false
        }
        return true
    }

    private static func isAbbreviation(_ text: String, before dot: String.Index) -> Bool {
        var j = dot
        var token = ""
        while j > text.startIndex {
            let p = text.index(before: j)
            let c = text[p]
            guard c.isLetter else { break }
            token.insert(c, at: token.startIndex)
            if token.count > 5 { return false }
            j = p
        }
        if token.count == 1 { return true }
        return abbreviations.contains(token.lowercased())
    }

    private struct Unit {
        var text: String
        var closed: Bool
    }

    private static func units(of text: String) -> [Unit] {
        var out: [Unit] = []
        var start = text.startIndex
        for end in terminatorEnds(text) {
            if start < end { out.append(Unit(text: String(text[start..<end]), closed: true)) }
            start = end
        }
        if start < text.endIndex {
            out.append(Unit(text: String(text[start...]), closed: false))
        }
        return out
    }

    private static func fitted(_ text: String) -> [String] {
        if text.isEmpty { return [] }
        if fits(text) { return [text] }
        let limit = CaptionBudget.lineWidth
        // 每个位置前面排到多宽，一次量完；下面全部按下标查表。
        let widths = CaptionBudget.textWidths(text)
        let chars = Array(text)
        func width(_ from: Int, _ to: Int) -> CGFloat { widths[to] - widths[from] }
        var out: [String] = []
        var start = 0
        while start < chars.count {
            let rest = String(chars[start...])
            if fits(rest) {
                out.append(rest)
                break
            }
            var best: Int?
            var lastFit = start
            var i = start
            while i < chars.count {
                let next = i + 1
                if width(start, next) > limit { break }
                lastFit = next
                if isSoft(chars, at: i) { best = next }
                i = next
            }
            var end = lastFit
            if let best, width(start, best) >= limit * 0.45 {
                end = best
            }
            if end <= start { end = start + 1 }
            out.append(String(chars[start..<end]))
            start = end
        }
        return out
    }

    /// `fitted` 按字符数组切的时候用的软断点判断，避免每步构造 String.Index。
    private static func isSoft(_ chars: [Character], at i: Int) -> Bool {
        guard i >= 0, i < chars.count else { return false }
        let ch = chars[i]
        guard ch.isWhitespace || "，,、；;：:".contains(ch) else { return false }
        if ch == "," || ch == "，" || ch == ":" || ch == "：" {
            let next = i + 1
            if i > 0, next < chars.count {
                if chars[i - 1].isNumber, chars[next].isNumber { return false }
            }
        }
        return true
    }

    private static func isSoft(_ text: String, at i: String.Index) -> Bool {
        let ch = text[i]
        guard ch.isWhitespace || "，,、；;：:".contains(ch) else { return false }
        if ch == "," || ch == "，" || ch == ":" || ch == "：" {
            let next = text.index(after: i)
            if i > text.startIndex, next < text.endIndex {
                let prev = text[text.index(before: i)]
                if prev.isNumber, text[next].isNumber { return false }
            }
        }
        return true
    }

    static func isWide(_ ch: Character) -> Bool {
        ch.unicodeScalars.contains { scalar in
            switch scalar.value {
            case 0x1100...0x115F, 0x2E80...0x9FFF, 0xA960...0xA97F, 0xAC00...0xD7AF,
                 0xF900...0xFAFF, 0xFE30...0xFE6F, 0xFF01...0xFF60, 0xFFE0...0xFFE6,
                 0x20000...0x3FFFD:
                return true
            default:
                return false
            }
        }
    }
}
