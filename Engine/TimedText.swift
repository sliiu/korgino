import Foundation

/// Already-written lyrics and subtitles. Times, metadata, and style stay put;
/// only the words that are sung or read are replaced.
enum TimedText {
    enum Kind: Sendable {
        case lrc, srt, vtt, ass

        static func forExtension(_ ext: String) -> Kind? {
            switch ext.lowercased() {
            case "lrc": return .lrc
            case "srt": return .srt
            case "vtt": return .vtt
            case "ass", "ssa": return .ass
            default: return nil
            }
        }
    }

    enum Part: Equatable, Sendable {
        case keep(String)
        case say(String)
    }

    struct Script: Sendable {
        let parts: [Part]

        var dialogue: [String] {
            parts.compactMap { part in
                if case .say(let text) = part { return text }
                return nil
            }
        }

        func applying(_ translations: [Int: String]) -> String {
            var n = 0
            var out = ""
            for part in parts {
                switch part {
                case .keep(let text):
                    out += text
                case .say(let text):
                    out += translations[n] ?? text
                    n += 1
                }
            }
            return out
        }
    }

    /// Nil when the file has no spoken line. The caller then translates it as plain text.
    static func parse(_ text: String, kind: Kind) -> Script? {
        var body = text
        if body.hasPrefix("\u{FEFF}") { body.removeFirst() }
        let parts = normalize(parts(of: body, kind: kind))
        let script = Script(parts: parts)
        guard !script.dialogue.isEmpty else { return nil }
        return script
    }

    /// Style tags inside one spoken line, lifted out so the engine does not rewrite them.
    static func shield(_ line: String) -> (payload: String, tokens: [String: String]) {
        var tokens: [String: String] = [:]
        var n = 0
        func take(_ original: String) -> String {
            let token = "⟦‡\(n)⟧"
            n += 1
            tokens[token] = original
            return token
        }
        var out = ""
        var i = line.startIndex
        while i < line.endIndex {
            if line[i] == "{", let end = braceEnd(line, from: i) {
                out += take(String(line[i..<end]))
                i = end
                continue
            }
            if line[i] == "<", let end = tagEnd(line, from: i) {
                out += take(String(line[i..<end]))
                i = end
                continue
            }
            if line[i] == "\\", let next = index(line, after: i), line[next] == "h" {
                out += take(String(line[i...next]))
                i = index(line, after: next) ?? line.endIndex
                continue
            }
            out.append(line[i])
            i = index(line, after: i) ?? line.endIndex
        }
        return (out, tokens)
    }

    static func restore(_ translated: String, tokens: [String: String]) -> String? {
        var out = translated
        for (token, original) in tokens {
            guard let range = out.range(of: token) else { return nil }
            out.replaceSubrange(range, with: original)
        }
        return out
    }

    static func unpack(_ text: String, count: Int) -> [Int: String]? {
        var normalized = text.replacingOccurrences(of: "\r\n", with: "\n")
        normalized = normalized.replacingOccurrences(of: "\r", with: "\n")
        var rows = normalized.components(separatedBy: "\n")
        if rows.last == "" { rows.removeLast() }
        var found: [Int: String] = [:]
        var marked = true
        for row in rows {
            let trimmed = row.drop(while: { $0 == " " || $0 == "\t" })
            guard trimmed.hasPrefix("⟦¶"), let close = trimmed.firstIndex(of: "⟧") else {
                marked = false
                break
            }
            let idText = trimmed[trimmed.index(trimmed.startIndex, offsetBy: 2)..<close]
            guard let id = Int(idText), idText.allSatisfy(\.isNumber), found[id] == nil else {
                marked = false
                break
            }
            var payload = trimmed[trimmed.index(after: close)...]
            if payload.first == " " { payload.removeFirst() }
            found[id] = String(payload)
        }
        if marked, found.count == count, (0..<count).allSatisfy({ found[$0] != nil }) { return found }
        if rows.count == count, rows.allSatisfy({ !$0.contains("⟦¶") }) {
            return Dictionary(uniqueKeysWithValues: rows.enumerated().map { ($0.offset, $0.element) })
        }
        return nil
    }

    // MARK: - Parse

    private struct RawLine {
        var text: String
        var ending: String
    }

    private static func parts(of text: String, kind: Kind) -> [Part] {
        switch kind {
        case .lrc: return lrcParts(splitLines(text))
        case .srt: return cueParts(splitLines(text), blocks: false)
        case .vtt: return cueParts(splitLines(text), blocks: true)
        case .ass: return assParts(splitLines(text))
        }
    }

    private static func splitLines(_ text: String) -> [RawLine] {
        var lines: [RawLine] = []
        var i = text.startIndex
        while i < text.endIndex {
            let start = i
            while i < text.endIndex, text[i] != "\n", text[i] != "\r" {
                i = index(text, after: i) ?? text.endIndex
            }
            let content = String(text[start..<i])
            var ending = ""
            if i < text.endIndex, text[i] == "\r" {
                ending.append("\r")
                i = index(text, after: i) ?? text.endIndex
            }
            if i < text.endIndex, text[i] == "\n" {
                ending.append("\n")
                i = index(text, after: i) ?? text.endIndex
            }
            lines.append(RawLine(text: content, ending: ending))
        }
        return lines
    }

    private static func normalize(_ parts: [Part]) -> [Part] {
        parts.map { part in
            guard case .say(let text) = part else { return part }
            if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return .keep(text) }
            return part
        }
    }

    private static func lrcParts(_ lines: [RawLine]) -> [Part] {
        var parts: [Part] = []
        for line in lines {
            guard let peeled = peelTimestamps(line.text) else {
                parts.append(.keep(line.text + line.ending))
                continue
            }
            let spoken = decompose(peeled.rest)
            if spoken.contains(where: isSay) {
                parts.append(.keep(peeled.prefix))
                parts.append(contentsOf: spoken)
            } else {
                parts.append(.keep(line.text))
            }
            parts.append(.keep(line.ending))
        }
        return parts
    }

    private static func peelTimestamps(_ line: String) -> (prefix: String, rest: String)? {
        var i = line.startIndex
        var prefix = ""
        var found = false
        while i < line.endIndex, line[i] == "[" {
            guard let close = line[i...].firstIndex(of: "]") else { break }
            let tag = String(line[i...close])
            guard isLRCTime(tag) else { break }
            prefix += tag
            found = true
            i = index(line, after: close) ?? line.endIndex
        }
        guard found else { return nil }
        return (prefix, String(line[i...]))
    }

    private static func isLRCTime(_ tag: String) -> Bool {
        tag.range(of: #"^\[(?:\d{1,2}:)?\d{1,3}:\d{2}(?:[.:]\d{1,3})?\]$"#, options: .regularExpression) != nil
    }

    private static func cueParts(_ lines: [RawLine], blocks: Bool) -> [Part] {
        var parts: [Part] = []
        var i = 0
        while i < lines.count {
            let line = lines[i].text
            if blocks, isMetaBlock(line) {
                parts.append(.keep(line + lines[i].ending))
                i += 1
                while i < lines.count,
                      !lines[i].text.trimmingCharacters(in: .whitespaces).isEmpty,
                      !isCueTiming(lines[i].text) {
                    parts.append(.keep(lines[i].text + lines[i].ending))
                    i += 1
                }
                continue
            }
            if isCueTiming(line) {
                appendCue(lines, at: &i, to: &parts)
                continue
            }
            if i + 1 < lines.count,
               !line.trimmingCharacters(in: .whitespaces).isEmpty,
               !isPreamble(line),
               isCueTiming(lines[i + 1].text) {
                parts.append(.keep(line + lines[i].ending))
                i += 1
                appendCue(lines, at: &i, to: &parts)
                continue
            }
            parts.append(.keep(line + lines[i].ending))
            i += 1
        }
        return parts
    }

    private static func appendCue(_ lines: [RawLine], at i: inout Int, to parts: inout [Part]) {
        parts.append(.keep(lines[i].text + lines[i].ending))
        i += 1
        while i < lines.count, !lines[i].text.trimmingCharacters(in: .whitespaces).isEmpty {
            let spoken = decompose(lines[i].text)
            if spoken.contains(where: isSay) {
                parts.append(contentsOf: spoken)
            } else {
                parts.append(.keep(lines[i].text))
            }
            parts.append(.keep(lines[i].ending))
            i += 1
        }
    }

    private static func isCueTiming(_ line: String) -> Bool {
        line.range(
            of: #"(?:(?:\d{1,2}:)?\d{1,2}:\d{2}[,.]\d{1,3})\s*-->\s*(?:(?:\d{1,2}:)?\d{1,2}:\d{2}[,.]\d{1,3})"#,
            options: .regularExpression
        ) != nil
    }

    private static func isMetaBlock(_ line: String) -> Bool {
        let t = line.trimmingCharacters(in: .whitespaces)
        return t == "STYLE" || t == "REGION" || t.hasPrefix("NOTE")
    }

    private static func isPreamble(_ line: String) -> Bool {
        let t = line.trimmingCharacters(in: .whitespaces)
        return t.hasPrefix("WEBVTT") || isMetaBlock(t)
    }

    private static func assParts(_ lines: [RawLine]) -> [Part] {
        var parts: [Part] = []
        var inEvents = false
        var textIndex = 9
        for line in lines {
            let trimmed = line.text.trimmingCharacters(in: .whitespaces)
            let lower = trimmed.lowercased()
            if lower.hasPrefix("["), lower.hasSuffix("]") {
                inEvents = lower == "[events]"
                parts.append(.keep(line.text + line.ending))
                continue
            }
            if inEvents, lower.hasPrefix("format:"), let colon = line.text.firstIndex(of: ":") {
                let fields = line.text[line.text.index(after: colon)...]
                    .split(separator: ",", omittingEmptySubsequences: false)
                    .map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
                if let idx = fields.firstIndex(of: "text") { textIndex = idx }
                parts.append(.keep(line.text + line.ending))
                continue
            }
            if inEvents, lower.hasPrefix("dialogue:"),
               let bodyStart = line.text.range(of: ":", options: .caseInsensitive)?.upperBound,
               let split = splitDialogue(String(line.text[bodyStart...]), textIndex: textIndex) {
                let spoken = decompose(split.text)
                parts.append(.keep(String(line.text[..<bodyStart]) + split.head))
                if spoken.contains(where: isSay) {
                    parts.append(contentsOf: spoken)
                } else {
                    parts.append(.keep(split.text))
                }
                parts.append(.keep(line.ending))
                continue
            }
            parts.append(.keep(line.text + line.ending))
        }
        return parts
    }

    private static func splitDialogue(_ body: String, textIndex: Int) -> (head: String, text: String)? {
        guard textIndex > 0 else { return ("", body) }
        var commas = 0
        var i = body.startIndex
        while i < body.endIndex {
            if body[i] == "," {
                commas += 1
                if commas == textIndex {
                    let after = index(body, after: i) ?? body.endIndex
                    return (String(body[..<after]), String(body[after...]))
                }
            }
            i = index(body, after: i) ?? body.endIndex
        }
        return nil
    }

    /// Spoken pieces of one cue line. Karaoke tags and word times are dropped.
    /// Drawing commands stay literal. `\N` and `\n` stay as their own pieces.
    private static func decompose(_ text: String) -> [Part] {
        var parts: [Part] = []
        var say = ""
        var literal = ""
        var drawing = false
        func flushSay() {
            if !say.isEmpty {
                parts.append(.say(say))
                say = ""
            }
        }
        func flushLiteral() {
            if !literal.isEmpty {
                parts.append(.keep(literal))
                literal = ""
            }
        }
        var i = text.startIndex
        while i < text.endIndex {
            if text[i] == "\\", let next = index(text, after: i), text[next] == "N" || text[next] == "n" {
                flushSay()
                flushLiteral()
                parts.append(.keep(String(text[i...next])))
                i = index(text, after: next) ?? text.endIndex
                continue
            }
            if text[i] == "{", let end = braceEnd(text, from: i) {
                let raw = String(text[i..<end])
                if stripKaraoke(raw) == nil {
                    if let flag = drawingFlag(raw) { drawing = flag }
                    i = end
                    continue
                }
                flushSay()
                flushLiteral()
                if let kept = stripKaraoke(raw) { parts.append(.keep(kept)) }
                if let flag = drawingFlag(raw) { drawing = flag }
                i = end
                continue
            }
            if !drawing, text[i] == "<", let end = wordTimeEnd(text, from: i) {
                i = end
                continue
            }
            if drawing {
                flushSay()
                literal.append(text[i])
            } else {
                flushLiteral()
                say.append(text[i])
            }
            i = index(text, after: i) ?? text.endIndex
        }
        flushSay()
        flushLiteral()
        return parts
    }

    private static func isSay(_ part: Part) -> Bool {
        if case .say(let text) = part {
            return !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
        return false
    }

    private static func stripKaraoke(_ block: String) -> String? {
        guard block.hasPrefix("{"), block.hasSuffix("}") else { return block }
        let inner = block.dropFirst().dropLast()
        var out = ""
        var i = inner.startIndex
        while i < inner.endIndex {
            if inner[i] == "\\", let span = commandSpan(inner, from: i), isKaraoke(span.name) {
                i = span.end
                continue
            }
            out.append(inner[i])
            i = index(inner, after: i) ?? inner.endIndex
        }
        if out.trimmingCharacters(in: .whitespaces).isEmpty { return nil }
        return "{" + out + "}"
    }

    private static func drawingFlag(_ block: String) -> Bool? {
        guard block.hasPrefix("{"), block.hasSuffix("}") else { return nil }
        let inner = block.dropFirst().dropLast()
        var flag: Bool?
        var i = inner.startIndex
        while i < inner.endIndex {
            if inner[i] == "\\", let span = commandSpan(inner, from: i) {
                if span.name == "p" {
                    flag = (Int(span.argument) ?? 1) != 0
                }
                i = span.end
                continue
            }
            i = index(inner, after: i) ?? inner.endIndex
        }
        return flag
    }

    private struct Command {
        var name: String
        var argument: String
        var end: String.Index
    }

    private static func commandSpan(_ text: Substring, from i: String.Index) -> Command? {
        guard text[i] == "\\" else { return nil }
        guard let nameStart = index(text, after: i), nameStart < text.endIndex, text[nameStart].isLetter else {
            return nil
        }
        var j = nameStart
        while j < text.endIndex, text[j].isLetter {
            j = index(text, after: j) ?? text.endIndex
        }
        let name = String(text[nameStart..<j])
        var argument = ""
        if j < text.endIndex, text[j] == "(" {
            argument.append("(")
            j = index(text, after: j) ?? text.endIndex
            while j < text.endIndex, text[j] != ")" {
                argument.append(text[j])
                j = index(text, after: j) ?? text.endIndex
            }
            if j < text.endIndex, text[j] == ")" {
                argument.append(")")
                j = index(text, after: j) ?? text.endIndex
            }
        } else {
            let digits = j
            while j < text.endIndex, text[j].isNumber {
                j = index(text, after: j) ?? text.endIndex
            }
            argument = String(text[digits..<j])
        }
        return Command(name: name, argument: argument, end: j)
    }

    private static func isKaraoke(_ name: String) -> Bool {
        switch name.lowercased() {
        case "k", "kf", "ko", "kt": return true
        default: return false
        }
    }

    private static func braceEnd(_ text: String, from i: String.Index) -> String.Index? {
        guard text[i] == "{" else { return nil }
        var j = index(text, after: i) ?? text.endIndex
        while j < text.endIndex, text[j] != "}" {
            j = index(text, after: j) ?? text.endIndex
        }
        guard j < text.endIndex else { return nil }
        return index(text, after: j)
    }

    private static func wordTimeEnd(_ text: String, from i: String.Index) -> String.Index? {
        guard text[i] == "<" else { return nil }
        let rest = text[i...]
        guard let match = rest.range(
            of: #"^<(?:(?:\d{1,2}:)?\d{1,2}:\d{2}(?:[.:]\d{1,3})?)>"#,
            options: .regularExpression
        ) else { return nil }
        return match.upperBound
    }

    private static func tagEnd(_ text: String, from i: String.Index) -> String.Index? {
        guard text[i] == "<" else { return nil }
        let rest = text[i...]
        guard let match = rest.range(
            of: #"^</?[A-Za-z][A-Za-z0-9.]*(?:\s[^>\n\r]*)?>"#,
            options: .regularExpression
        ) else { return nil }
        return match.upperBound
    }

    private static func index<S: StringProtocol>(_ text: S, after i: String.Index) -> String.Index? {
        guard i < text.endIndex else { return nil }
        let next = text.index(after: i)
        return next <= text.endIndex ? next : nil
    }
}

#if TIMED_TEXT_CHECK
@main
enum TimedTextCheck {
    static func main() {
        var failed = 0
        func check(_ name: String, _ got: String, _ want: String) {
            if got == want {
                print("ok \(name)")
            } else {
                failed += 1
                print("FAIL \(name)\n got: \(String(reflecting: got))\n want: \(String(reflecting: want))")
            }
        }
        func checkNil(_ name: String, _ value: TimedText.Script?) {
            if value == nil {
                print("ok \(name)")
            } else {
                failed += 1
                print("FAIL \(name) parsed \(String(reflecting: value!.applying([:])))")
            }
        }

        let lrc = "[ti:夜曲]\n[ar:周杰伦]\n[00:12.00]<00:12.20>为<00:12.80>你\n[00:01.00][00:45.00]chorus\n"
        let lrcScript = TimedText.parse(lrc, kind: .lrc)!
        check("lrc lines", lrcScript.dialogue.joined(separator: "|"), "为你|chorus")
        check(
            "lrc render",
            lrcScript.applying([0: "For you", 1: "refrain"]),
            "[ti:夜曲]\n[ar:周杰伦]\n[00:12.00]For you\n[00:01.00][00:45.00]refrain\n"
        )

        let srt = "hello\n\n1\n00:00:01,000 --> 00:00:02,000\nHello <i>world</i>\n\n2\n00:00:03,000 --> 00:00:04,000\n{\\an8}Next\n"
        let srtScript = TimedText.parse(srt, kind: .srt)!
        check("srt lines", srtScript.dialogue.joined(separator: "|"), "Hello <i>world</i>|Next")
        check(
            "srt render",
            srtScript.applying([0: "你好 <i>世界</i>", 1: "下一句"]),
            "hello\n\n1\n00:00:01,000 --> 00:00:02,000\n你好 <i>世界</i>\n\n2\n00:00:03,000 --> 00:00:04,000\n{\\an8}下一句\n"
        )
        let (shielded, tokens) = TimedText.shield(srtScript.dialogue[0])
        check("shield", TimedText.restore(shielded, tokens: tokens) ?? "", "Hello <i>world</i>")
        check("unpack", TimedText.unpack("⟦¶0⟧ 你好\n⟦¶1⟧ 世界\n", count: 2)?[1] ?? "", "世界")
        check("unpack lines", TimedText.unpack("你好\n世界\n", count: 2)?[0] ?? "", "你好")
        checkNil("unpack stray", nil)

        let vtt = "WEBVTT\n\nNOTE\nkeep me\n\n00:00:01.000 --> 00:00:04.000 align:middle\n<v Roger>Hello\n"
        let vttScript = TimedText.parse(vtt, kind: .vtt)!
        check("vtt line", vttScript.dialogue.joined(separator: "|"), "<v Roger>Hello")
        check(
            "vtt render",
            vttScript.applying([0: "<v Roger>你好"]),
            "WEBVTT\n\nNOTE\nkeep me\n\n00:00:01.000 --> 00:00:04.000 align:middle\n<v Roger>你好\n"
        )

        let ass = """
        [Script Info]
        Title: Demo

        [Events]
        Format: Layer, Start, End, Style, Name, MarginL, MarginR, MarginV, Effect, Text
        Comment: 0,0:00:01.00,0:00:02.00,Default,,0,0,0,,do not translate
        Dialogue: 0,0:00:01.00,0:00:04.00,Default,Alice,0,0,0,,{\\pos(100,200)\\k20}Hel{\\k40}lo\\Nworld
        Dialogue: 0,0:00:05.00,0:00:06.00,Default,,0,0,0,,{\\p1}m 0 0 l 10 10{\\p0}Hello

        """
        let assScript = TimedText.parse(ass, kind: .ass)!
        check("ass lines", assScript.dialogue.joined(separator: "|"), "Hello|world|Hello")
        let assOut = assScript.applying([0: "Hi", 1: "there", 2: "你好"])
        check("ass comment", assOut.contains("do not translate") ? "yes" : "no", "yes")
        check("ass pos", assOut.contains("{\\pos(100,200)}Hi\\Nthere") ? "yes" : "no", "yes")
        check("ass karaoke gone", assOut.contains("\\k") ? "yes" : "no", "no")
        check("ass draw", assOut.contains("{\\p1}m 0 0 l 10 10{\\p0}你好") ? "yes" : "no", "yes")
        check("ass name", assOut.contains("Default,Alice,") ? "yes" : "no", "yes")

        checkNil("plain srt", TimedText.parse("this is an article\nwithout times\n", kind: .srt))
        checkNil("meta only", TimedText.parse("[ti:夜曲]\n[ar:周杰伦]\n", kind: .lrc))

        let partial = TimedText.parse(srt, kind: .srt)!.applying([1: "下一句"])
        check("partial keeps", partial.contains("Hello <i>world</i>") && partial.contains("下一句") ? "yes" : "no", "yes")

        if failed > 0 { exit(1) }
    }
}
#endif
