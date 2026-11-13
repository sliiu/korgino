import Foundation

/// Keeps a translation lined up with the source skeleton.
/// Tag-capable engines receive HTML. The others receive the source with code,
/// URLs, tags, and placeholders lifted out. Either way the markers go back on
/// after the engine returns.
enum SourceSkeleton {
    struct Prepared: Sendable {
        var payload: String
        var html: Bool
        fileprivate var tokens: [String: String]
        fileprivate var tails: [String]
    }

    static func prepare(_ text: String, html: Bool, layout: Bool = true) -> Prepared {
        let shielded = shield(text)
        guard html else {
            guard layout else {
                return Prepared(payload: shielded.text, html: false, tokens: shielded.tokens, tails: [])
            }
            let frozen = freezeLayout(shielded.text, tokens: shielded.tokens)
            return Prepared(payload: frozen.text, html: false, tokens: frozen.tokens, tails: [])
        }
        let pieces = htmlPieces(shielded.text)
        let payload = pieces.map(\.html).joined()
        guard !payload.isEmpty else {
            return Prepared(payload: shielded.text, html: false, tokens: shielded.tokens, tails: [])
        }
        return Prepared(payload: payload, html: true, tokens: shielded.tokens, tails: pieces.map(\.tail))
    }

    static func finish(_ translated: String, prepared: Prepared) -> String {
        let body: String
        if prepared.html {
            let decoded = unescapeHTML(translated)
            let blocks = markdownBlocks(decoded)
            if blocks.count == prepared.tails.count, !blocks.isEmpty {
                body = zip(blocks, prepared.tails).map { $0 + $1 }.joined()
            } else if !blocks.isEmpty {
                body = blocks.joined(separator: "\n\n")
            } else {
                body = stripTags(decoded)
            }
        } else {
            body = translated
        }
        return restore(body, tokens: prepared.tokens)
    }

    /// Exact slices of `text`. A fence stays inside one slice. Joining the
    /// slices reproduces `text`.
    static func chunks(_ text: String, limit: Int = 3000) -> [String] {
        if text.isEmpty { return [text] }
        let parts = atoms(text)
        guard parts.joined() == text else { return [text] }
        if text.count <= limit { return [text] }
        var out: [String] = []
        var cur = ""
        for part in parts {
            let blank = part.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            if blank {
                cur += part
                continue
            }
            if !cur.isEmpty, cur.count + part.count > limit {
                out.append(cur)
                cur = ""
            }
            cur += part
        }
        if !cur.isEmpty { out.append(cur) }
        return out.isEmpty ? [text] : out
    }

    // MARK: - Shield

    private struct Shielded {
        var text: String
        var tokens: [String: String]
    }

    private static func shield(_ text: String) -> Shielded {
        var tokens: [String: String] = [:]
        var n = 0
        func take(_ original: String) -> String {
            let token = "⟦§\(n)⟧"
            n += 1
            tokens[token] = original
            return token
        }
        var out = ""
        var i = text.startIndex
        while i < text.endIndex {
            if atLineStart(text, i), let end = fenceEnd(text, from: i) {
                out += take(String(text[i..<end]))
                i = end
                continue
            }
            if let end = inlineCodeEnd(text, from: i) {
                out += take(String(text[i..<end]))
                i = end
                continue
            }
            if let end = secretEnd(text, from: i) {
                out += take(String(text[i..<end]))
                i = end
                continue
            }
            if let end = htmlTagEnd(text, from: i) {
                out += take(String(text[i..<end]))
                i = end
                continue
            }
            if let (alt, dest, end) = imageAt(text, i) {
                out += "![" + alt + "](" + take(dest) + ")"
                i = end
                continue
            }
            if let (label, dest, end) = linkAt(text, i) {
                out += "[" + label + "](" + take(dest) + ")"
                i = end
                continue
            }
            if let end = urlEnd(text, from: i) {
                out += take(String(text[i..<end]))
                i = end
                continue
            }
            out.append(text[i])
            i = text.index(after: i)
        }
        return Shielded(text: out, tokens: tokens)
    }

    private static func restore(_ text: String, tokens: [String: String]) -> String {
        var out = repairTokens(text)
        for (token, original) in tokens.sorted(by: { $0.key.count > $1.key.count }) {
            let squeeze = !original.isEmpty && original.allSatisfy { $0 == " " || $0 == "\t" || $0 == "\n" || $0 == "\r" }
            out = replace(out, token: token, with: original, squeeze: squeeze)
        }
        return strayTokens.stringByReplacingMatches(in: out, range: NSRange(out.startIndex..., in: out), withTemplate: "")
    }

    /// 有的引擎会把 `⟦§4⟧` 改成 `⟦ § 4⟧`、`⟦ § 4您⟧`，Apple 还会把开头的 `⟦` 和 `§` 之间塞进空格：
    /// 先拼回原样，夹进去的字挪到后面。
    private static let mangledToken = try! NSRegularExpression(pattern: "\\s*⟦\\s*§\\s*(\\d+)\\s*([^⟦⟧\\n]{0,40}?)\\s*⟧")
    private static let strayTokens = try! NSRegularExpression(pattern: "⟦§\\d+⟧")

    private static func repairTokens(_ text: String) -> String {
        guard text.contains("⟦") else { return text }
        return mangledToken.stringByReplacingMatches(in: text, range: NSRange(text.startIndex..., in: text), withTemplate: "⟦§$1⟧$2")
    }

    private static func replace(_ text: String, token: String, with original: String, squeeze: Bool) -> String {
        guard text.contains(token) else { return text }
        var out = ""
        var i = text.startIndex
        while i < text.endIndex {
            if text[i...].hasPrefix(token) {
                if squeeze {
                    while let last = out.last, last == " " || last == "\t" { out.removeLast() }
                }
                out += original
                i = text.index(i, offsetBy: token.count)
                if squeeze {
                    while i < text.endIndex, text[i] == " " || text[i] == "\t" { i = text.index(after: i) }
                }
                continue
            }
            out.append(text[i])
            i = text.index(after: i)
        }
        return out
    }

    private struct Frozen {
        var text: String
        var tokens: [String: String]
    }

    private static func freezeLayout(_ text: String, tokens: [String: String]) -> Frozen {
        var tokens = tokens
        var n = nextTokenID(tokens)
        func take(_ original: String) -> String {
            let token = "⟦§\(n)⟧"
            n += 1
            tokens[token] = original
            return token
        }
        var out = ""
        var i = text.startIndex
        while i < text.endIndex {
            var j = i
            while j < text.endIndex, text[j] != "\n", text[j] != "\r" {
                j = text.index(after: j)
            }
            out += freezeLine(String(text[i..<j]), take: take)
            if j < text.endIndex {
                var breakEnd = text.index(after: j)
                if text[j] == "\r", breakEnd < text.endIndex, text[breakEnd] == "\n" {
                    breakEnd = text.index(after: breakEnd)
                }
                out += take(String(text[j..<breakEnd]))
                i = breakEnd
            } else {
                i = j
            }
        }
        return Frozen(text: out, tokens: tokens)
    }

    private static func nextTokenID(_ tokens: [String: String]) -> Int {
        var maxID = -1
        for key in tokens.keys {
            guard key.hasPrefix("⟦§"), key.hasSuffix("⟧") else { continue }
            let inner = key.dropFirst(2).dropLast()
            if let id = Int(inner) { maxID = max(maxID, id) }
        }
        return maxID + 1
    }

    private static func freezeLine(_ line: String, take: (String) -> String) -> String {
        var i = line.startIndex
        while i < line.endIndex, line[i] == " " || line[i] == "\t" {
            i = line.index(after: i)
        }
        var out = ""
        if i > line.startIndex {
            out += take(String(line[..<i]))
        }
        var rest = String(line[i...])
        if lineIsTokens(rest) { return out + rest }
        if let heading = headingMatch(rest) {
            out += take(heading.mark)
            rest = heading.rest
        } else if let item = listMatch(rest) {
            out += take(item.mark)
            rest = item.rest
        } else if quoteMatch(rest) != nil {
            while let quote = quoteMatch(rest) {
                out += take(quote.mark)
                rest = quote.rest
            }
        } else if isDelimiterRow(rest) {
            return out + take(rest)
        }
        out += freezeInline(rest, take: take)
        return out
    }

    private static func freezeInline(_ text: String, take: (String) -> String) -> String {
        var out = ""
        var i = text.startIndex
        while i < text.endIndex {
            if let end = skeletonTokenEnd(text, i) {
                out += text[i..<end]
                i = end
                continue
            }
            if text[i] == "|" {
                out += take("|")
                i = text.index(after: i)
                continue
            }
            out.append(text[i])
            i = text.index(after: i)
        }
        return out
    }

    private static func lineIsTokens(_ text: String) -> Bool {
        var i = text.startIndex
        var any = false
        while i < text.endIndex {
            guard let end = skeletonTokenEnd(text, i) else { return false }
            any = true
            i = end
        }
        return any
    }

    private static func skeletonTokenEnd(_ text: String, _ i: String.Index) -> String.Index? {
        guard text[i...].hasPrefix("⟦§") else { return nil }
        guard let end = text[i...].firstIndex(of: "⟧") else { return nil }
        let inner = text[text.index(i, offsetBy: 2)..<end]
        guard !inner.isEmpty, inner.allSatisfy(\.isNumber) else { return nil }
        return text.index(after: end)
    }

    // MARK: - HTML

    private struct Piece {
        var html: String
        var tail: String
    }

    private struct Line {
        var text: String
        var end: String
    }

    private static func htmlPieces(_ text: String) -> [Piece] {
        let lines = splitLines(text)
        var pieces: [Piece] = []
        var i = 0
        while i < lines.count {
            let line = lines[i]
            if line.text.isEmpty {
                let tail = absorbBlanks(lines, from: i)
                if var last = pieces.popLast() {
                    last.tail += tail
                    pieces.append(last)
                } else if !tail.isEmpty {
                    pieces.append(Piece(html: "", tail: tail))
                }
                i += blankCount(lines, from: i)
                continue
            }
            if isToken(line.text.trimmingCharacters(in: .whitespaces)) {
                let tail = line.end + followingBlanks(lines, after: i)
                pieces.append(Piece(html: "<pre translate=\"no\">\(escapeText(line.text.trimmingCharacters(in: .whitespaces)))</pre>", tail: tail))
                i += 1 + blankCount(lines, from: i + 1)
                continue
            }
            if let heading = headingMatch(line.text) {
                let tail = line.end + followingBlanks(lines, after: i)
                let inner = "<span translate=\"no\">\(escapeText(heading.mark))</span>" + inlineHTML(heading.rest)
                pieces.append(Piece(html: "<h\(heading.level)>\(inner)</h\(heading.level)>", tail: tail))
                i += 1 + blankCount(lines, from: i + 1)
                continue
            }
            if isDelimiterRow(line.text) {
                let tail = line.end + followingBlanks(lines, after: i)
                pieces.append(Piece(html: "<p><span translate=\"no\">\(escapeText(line.text))</span></p>", tail: tail))
                i += 1 + blankCount(lines, from: i + 1)
                continue
            }
            if listMatch(line.text) != nil {
                var items: [String] = []
                var ordered = false
                var tail = ""
                while i < lines.count, let item = listMatch(lines[i].text) {
                    ordered = item.ordered
                    items.append("<li><span translate=\"no\">\(escapeText(item.mark))</span>\(inlineHTML(item.rest))</li>")
                    tail = lines[i].end
                    i += 1
                    if i < lines.count, listMatch(lines[i].text) == nil { break }
                }
                let blanks = followingBlanks(lines, after: i - 1)
                tail += blanks
                i += blankCount(lines, from: i)
                let tag = ordered ? "ol" : "ul"
                pieces.append(Piece(html: "<\(tag)>" + items.joined() + "</\(tag)>", tail: tail))
                continue
            }
            if quoteMatch(line.text) != nil {
                var rows: [String] = []
                var tail = ""
                while i < lines.count, let q = quoteMatch(lines[i].text) {
                    rows.append("<span translate=\"no\">\(escapeText(q.mark))</span>" + inlineHTML(q.rest))
                    tail = lines[i].end
                    i += 1
                }
                let blanks = followingBlanks(lines, after: i - 1)
                tail += blanks
                i += blankCount(lines, from: i)
                pieces.append(Piece(html: "<blockquote><p>" + rows.joined(separator: "<br>") + "</p></blockquote>", tail: tail))
                continue
            }
            if isTableRow(line.text) {
                var rows: [String] = []
                var tail = ""
                while i < lines.count, isTableRow(lines[i].text) || isDelimiterRow(lines[i].text) {
                    if isDelimiterRow(lines[i].text) {
                        rows.append("<tr translate=\"no\"><td><span translate=\"no\">\(escapeText(lines[i].text))</span></td></tr>")
                    } else {
                        rows.append("<tr><td>\(pipeHTML(lines[i].text))</td></tr>")
                    }
                    tail = lines[i].end
                    i += 1
                }
                let blanks = followingBlanks(lines, after: i - 1)
                tail += blanks
                i += blankCount(lines, from: i)
                pieces.append(Piece(html: "<table>" + rows.joined() + "</table>", tail: tail))
                continue
            }
            var bits: [String] = []
            var tail = ""
            while i < lines.count, isParagraphLine(lines[i].text) {
                if !bits.isEmpty { bits.append("<br>") }
                bits.append(inlineHTML(lines[i].text))
                tail = lines[i].end
                i += 1
            }
            let blanks = followingBlanks(lines, after: i - 1)
            tail += blanks
            i += blankCount(lines, from: i)
            pieces.append(Piece(html: "<p>" + bits.joined() + "</p>", tail: tail))
        }
        return pieces
    }

    private static func inlineHTML(_ s: String) -> String {
        var out = ""
        var i = s.startIndex
        while i < s.endIndex {
            if let (token, end) = tokenAt(s, i) {
                out += "<span translate=\"no\">\(token)</span>"
                i = end
                continue
            }
            if let (alt, dest, end) = imageAt(s, i) {
                out += "<span translate=\"no\">![</span>" + inlineHTML(alt) + "<span translate=\"no\">](\(dest))</span>"
                i = end
                continue
            }
            if let (label, dest, end) = linkAt(s, i) {
                out += "<a href=\"\(escapeAttr(dest))\">" + inlineHTML(label) + "</a>"
                i = end
                continue
            }
            if let (tag, inner, end) = emphAt(s, i) {
                out += "<\(tag)>" + inlineHTML(inner) + "</\(tag)>"
                i = end
                continue
            }
            out += escape(s[i])
            i = s.index(after: i)
        }
        return out
    }

    private static func pipeHTML(_ line: String) -> String {
        var html = ""
        var cell = ""
        for ch in line {
            if ch == "|" {
                html += inlineHTML(cell)
                html += "<span translate=\"no\">|</span>"
                cell = ""
            } else {
                cell.append(ch)
            }
        }
        html += inlineHTML(cell)
        return html
    }

    private static func markdownBlocks(_ html: String) -> [String] {
        let s = html
        var i = s.startIndex
        var blocks: [String] = []
        while i < s.endIndex {
            skipHTMLNoise(&i, s)
            guard i < s.endIndex else { break }
            if s[i] != "<" {
                let end = s[i...].firstIndex(of: "<") ?? s.endIndex
                let raw = String(s[i..<end])
                if !raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    blocks.append(raw.replacingOccurrences(of: "\n", with: ""))
                }
                i = end
                continue
            }
            guard let tag = readTag(s, at: i) else { break }
            i = tag.end
            switch tag.name {
            case "p":
                let inner = readUntilClose("p", s, from: &i)
                blocks.append(inlineMarkdown(inner))
            case "h1", "h2", "h3", "h4", "h5", "h6":
                let inner = readUntilClose(tag.name, s, from: &i)
                blocks.append(inlineMarkdown(inner))
            case "ul", "ol":
                let inner = readUntilClose(tag.name, s, from: &i)
                let items = listItems(inner)
                if !items.isEmpty { blocks.append(items.joined(separator: "\n")) }
            case "blockquote":
                let inner = readUntilClose("blockquote", s, from: &i)
                let text = markdownBlocks(inner).joined(separator: "\n")
                blocks.append(text)
            case "pre":
                let inner = readUntilClose("pre", s, from: &i)
                blocks.append(stripTags(inner).trimmingCharacters(in: .whitespacesAndNewlines))
            case "table":
                let inner = readUntilClose("table", s, from: &i)
                let rows = tableRows(inner)
                if !rows.isEmpty { blocks.append(rows.joined(separator: "\n")) }
            case "br":
                break
            case "span", "strong", "b", "em", "i", "a", "code":
                let inner = tag.closing ? "" : readUntilClose(tag.name, s, from: &i)
                let text = inlineMarkdown("<\(tag.name)\(tag.attr)>" + inner + "</\(tag.name)>")
                if !text.isEmpty { blocks.append(text) }
            default:
                if !tag.closing, !tag.empty {
                    _ = readUntilClose(tag.name, s, from: &i)
                }
            }
        }
        return blocks
    }

    private static func listItems(_ html: String) -> [String] {
        var i = html.startIndex
        var items: [String] = []
        let s = html
        while i < s.endIndex {
            skipHTMLNoise(&i, s)
            guard i < s.endIndex, s[i] == "<", let tag = readTag(s, at: i), tag.name == "li" else {
                if i < s.endIndex { i = s.index(after: i) }
                continue
            }
            i = tag.end
            let inner = readUntilClose("li", s, from: &i)
            items.append(inlineMarkdown(inner))
        }
        return items
    }

    private static func tableRows(_ html: String) -> [String] {
        var i = html.startIndex
        var rows: [String] = []
        let s = html
        while i < s.endIndex {
            skipHTMLNoise(&i, s)
            guard i < s.endIndex, s[i] == "<", let tag = readTag(s, at: i), tag.name == "tr" else {
                if i < s.endIndex { i = s.index(after: i) }
                continue
            }
            i = tag.end
            let inner = readUntilClose("tr", s, from: &i)
            rows.append(inlineMarkdown(inner).replacingOccurrences(of: "\n", with: ""))
        }
        return rows
    }

    private static func inlineMarkdown(_ html: String) -> String {
        var out = ""
        var i = html.startIndex
        let s = html
        while i < s.endIndex {
            if s[i] == "\n" || s[i] == "\r" {
                i = s.index(after: i)
                continue
            }
            if s[i] != "<" {
                let end = s[i...].firstIndex(of: "<") ?? s.endIndex
                out += String(s[i..<end])
                i = end
                continue
            }
            guard let tag = readTag(s, at: i) else {
                out.append(s[i])
                i = s.index(after: i)
                continue
            }
            i = tag.end
            if tag.name == "br" { out += "\n"; continue }
            if tag.closing || tag.empty { continue }
            let inner = readUntilClose(tag.name, s, from: &i)
            let body = inlineMarkdown(inner)
            switch tag.name {
            case "strong": out += "**" + body + "**"
            case "b": out += "__" + body + "__"
            case "em": out += "*" + body + "*"
            case "i": out += "_" + body + "_"
            case "code": out += "`" + body + "`"
            case "span": out += body
            case "a":
                let href = attrValue("href", tag.attr)
                out += "[" + body + "](" + href + ")"
            default:
                out += body
            }
        }
        return out
    }

    // MARK: - Lines

    private static func splitLines(_ text: String) -> [Line] {
        if text.isEmpty { return [] }
        var out: [Line] = []
        var i = text.startIndex
        while i < text.endIndex {
            if let nl = text[i...].firstIndex(of: "\n") {
                out.append(Line(text: String(text[i..<nl]), end: "\n"))
                i = text.index(after: nl)
            } else {
                out.append(Line(text: String(text[i...]), end: ""))
                break
            }
        }
        return out
    }

    private static func absorbBlanks(_ lines: [Line], from index: Int) -> String {
        var tail = ""
        var i = index
        while i < lines.count, lines[i].text.isEmpty {
            tail += lines[i].end
            i += 1
        }
        return tail
    }

    private static func followingBlanks(_ lines: [Line], after index: Int) -> String {
        absorbBlanks(lines, from: index + 1)
    }

    private static func blankCount(_ lines: [Line], from index: Int) -> Int {
        var n = 0
        var i = index
        while i < lines.count, lines[i].text.isEmpty {
            n += 1
            i += 1
        }
        return n
    }

    private static func isParagraphLine(_ text: String) -> Bool {
        if text.isEmpty { return false }
        if isToken(text.trimmingCharacters(in: .whitespaces)) { return false }
        if headingMatch(text) != nil { return false }
        if listMatch(text) != nil { return false }
        if quoteMatch(text) != nil { return false }
        if isDelimiterRow(text) || isTableRow(text) { return false }
        return true
    }

    private struct Heading {
        var level: Int
        var mark: String
        var rest: String
    }

    private static func headingMatch(_ line: String) -> Heading? {
        var i = line.startIndex
        var hashes = 0
        while i < line.endIndex, line[i] == "#", hashes < 6 {
            hashes += 1
            i = line.index(after: i)
        }
        guard hashes > 0, i < line.endIndex, line[i] == " " || line[i] == "\t" else { return nil }
        let mark = String(line[..<i]) + String(line[i])
        let restStart = line.index(after: i)
        return Heading(level: hashes, mark: mark, rest: String(line[restStart...]))
    }

    private struct ListItem {
        var ordered: Bool
        var mark: String
        var rest: String
    }

    private static func listMatch(_ line: String) -> ListItem? {
        let pattern = #"^(\s*(?:[-*+]|\d+[.)])\s+)(\[[ xX]\]\s+)?(.*)$"#
        guard let re = RegexCache.cached(pattern) else { return nil }
        let ns = line as NSString
        let full = NSRange(location: 0, length: ns.length)
        guard let m = re.firstMatch(in: line, range: full), m.range.location == 0 else { return nil }
        let markRange = m.range(at: 1)
        var mark = ns.substring(with: markRange)
        if m.range(at: 2).location != NSNotFound {
            mark += ns.substring(with: m.range(at: 2))
        }
        let rest = ns.substring(with: m.range(at: 3))
        let ordered = mark.unicodeScalars.contains { $0.value >= 48 && $0.value <= 57 }
        return ListItem(ordered: ordered, mark: mark, rest: rest)
    }

    private struct Quote {
        var mark: String
        var rest: String
    }

    private static func quoteMatch(_ line: String) -> Quote? {
        let pattern = #"^(\s*>\s?)(.*)$"#
        guard let re = RegexCache.cached(pattern) else { return nil }
        let ns = line as NSString
        guard let m = re.firstMatch(in: line, range: NSRange(location: 0, length: ns.length)) else { return nil }
        return Quote(mark: ns.substring(with: m.range(at: 1)), rest: ns.substring(with: m.range(at: 2)))
    }

    private static func isTableRow(_ line: String) -> Bool {
        let t = line.trimmingCharacters(in: .whitespaces)
        guard t.contains("|"), !isDelimiterRow(line) else { return false }
        return t.first == "|" || t.filter { $0 == "|" }.count >= 2
    }

    private static func isDelimiterRow(_ line: String) -> Bool {
        let t = line.trimmingCharacters(in: .whitespaces)
        guard t.contains("|"), t.contains("-") else { return false }
        return t.allSatisfy { "|-: \t".contains($0) }
    }

    private static func isToken(_ text: String) -> Bool {
        guard text.hasPrefix("⟦§"), text.hasSuffix("⟧") else { return false }
        let inner = text.dropFirst(2).dropLast()
        return !inner.isEmpty && inner.allSatisfy(\.isNumber)
    }

    // MARK: - Scanners

    private static func atLineStart(_ text: String, _ i: String.Index) -> Bool {
        i == text.startIndex || text[text.index(before: i)] == "\n"
    }

    private static func fenceEnd(_ text: String, from i: String.Index) -> String.Index? {
        let rest = text[i...]
        var spaces = 0
        var j = rest.startIndex
        while j < rest.endIndex, rest[j] == " ", spaces < 3 {
            spaces += 1
            j = rest.index(after: j)
        }
        guard j < rest.endIndex, rest[j] == "`" || rest[j] == "~" else { return nil }
        let marker = rest[j]
        var count = 0
        while j < rest.endIndex, rest[j] == marker {
            count += 1
            j = rest.index(after: j)
        }
        guard count >= 3 else { return nil }
        guard let lineEnd = rest[j...].firstIndex(of: "\n") else { return text.endIndex }
        var k = rest.index(after: lineEnd)
        while k < text.endIndex {
            let lineStart = k
            let nextBreak = text[k...].firstIndex(of: "\n") ?? text.endIndex
            let line = text[lineStart..<nextBreak]
            if closesFence(line, marker: marker, count: count) {
                return nextBreak == text.endIndex ? text.endIndex : text.index(after: nextBreak)
            }
            if nextBreak == text.endIndex { break }
            k = text.index(after: nextBreak)
        }
        return text.endIndex
    }

    private static func closesFence(_ line: Substring, marker: Character, count: Int) -> Bool {
        var j = line.startIndex
        var spaces = 0
        while j < line.endIndex, line[j] == " ", spaces < 3 {
            spaces += 1
            j = line.index(after: j)
        }
        var n = 0
        while j < line.endIndex, line[j] == marker {
            n += 1
            j = line.index(after: j)
        }
        guard n >= count else { return false }
        return line[j...].trimmingCharacters(in: .whitespaces).isEmpty
    }

    private static func inlineCodeEnd(_ text: String, from i: String.Index) -> String.Index? {
        guard text[i] == "`" else { return nil }
        var j = i
        var count = 0
        while j < text.endIndex, text[j] == "`" {
            count += 1
            j = text.index(after: j)
        }
        guard count > 0 else { return nil }
        var k = j
        while k < text.endIndex {
            if text[k] == "\n" { return nil }
            if text[k] == "`" {
                var n = 0
                var e = k
                while e < text.endIndex, text[e] == "`" {
                    n += 1
                    e = text.index(after: e)
                }
                if n == count { return e }
            }
            k = text.index(after: k)
        }
        return nil
    }

    private static func secretEnd(_ text: String, from i: String.Index) -> String.Index? {
        guard text[i] == "⟦" else { return nil }
        let next = text.index(after: i)
        if next < text.endIndex, text[next] == "§" { return nil }
        guard let end = text[next...].firstIndex(of: "⟧") else { return nil }
        return text.index(after: end)
    }

    private static func htmlTagEnd(_ text: String, from i: String.Index) -> String.Index? {
        guard text[i] == "<" else { return nil }
        let next = text.index(after: i)
        guard next < text.endIndex else { return nil }
        let ch = text[next]
        guard ch == "/" || ch == "!" || ch.isLetter else { return nil }
        guard let end = text[next...].firstIndex(of: ">") else { return nil }
        return text.index(after: end)
    }

    private static func imageAt(_ text: String, _ i: String.Index) -> (alt: String, dest: String, end: String.Index)? {
        guard text[i...].hasPrefix("![") else { return nil }
        return bracketDest(text, from: text.index(i, offsetBy: 2), bang: true).map { ($0.0, $0.1, $0.2) }
    }

    private static func linkAt(_ text: String, _ i: String.Index) -> (label: String, dest: String, end: String.Index)? {
        guard text[i] == "[", !(i > text.startIndex && text[text.index(before: i)] == "!") else { return nil }
        guard !text[i...].hasPrefix("![") else { return nil }
        return bracketDest(text, from: text.index(after: i), bang: false)
    }

    private static func bracketDest(_ text: String, from i: String.Index, bang: Bool) -> (String, String, String.Index)? {
        guard let close = text[i...].firstIndex(of: "]"), text[close...].hasPrefix("](") else { return nil }
        let label = String(text[i..<close])
        let destStart = text.index(close, offsetBy: 2)
        guard let endParen = text[destStart...].firstIndex(of: ")") else { return nil }
        let dest = String(text[destStart..<endParen])
        guard !label.contains("\n"), !dest.contains("\n") else { return nil }
        return (label, dest, text.index(after: endParen))
    }

    private static func urlEnd(_ text: String, from i: String.Index) -> String.Index? {
        let rest = text[i...]
        guard rest.hasPrefix("https://") || rest.hasPrefix("http://") else { return nil }
        var j = i
        while j < text.endIndex {
            let ch = text[j]
            if ch.isWhitespace || "<>()[]\"'".contains(ch) { break }
            j = text.index(after: j)
        }
        return j > i ? j : nil
    }

    private static func tokenAt(_ text: String, _ i: String.Index) -> (String, String.Index)? {
        guard text[i...].hasPrefix("⟦§") else { return nil }
        guard let end = text[i...].firstIndex(of: "⟧") else { return nil }
        let token = String(text[i...end])
        guard isToken(token) else { return nil }
        return (token, text.index(after: end))
    }

    private static func emphAt(_ text: String, _ i: String.Index) -> (tag: String, inner: String, end: String.Index)? {
        let pairs: [(String, String)] = [("**", "strong"), ("__", "b"), ("*", "em"), ("_", "i")]
        for (marker, tag) in pairs {
            guard text[i...].hasPrefix(marker) else { continue }
            if marker == "*", text[i...].hasPrefix("**") { continue }
            if marker == "_", text[i...].hasPrefix("__") { continue }
            if marker == "_" || marker == "*", !emphasisBoundary(text, at: i, marker: marker) { continue }
            let innerStart = text.index(i, offsetBy: marker.count)
            guard let close = findMarker(marker, in: text, from: innerStart) else { continue }
            let inner = String(text[innerStart..<close])
            guard !inner.isEmpty, !inner.hasPrefix(marker), !inner.hasSuffix(marker) else { continue }
            return (tag, inner, text.index(close, offsetBy: marker.count))
        }
        return nil
    }

    private static func emphasisBoundary(_ text: String, at i: String.Index, marker: String) -> Bool {
        if marker != "_" && marker != "*" { return true }
        if i > text.startIndex {
            let prev = text[text.index(before: i)]
            if prev.isLetter || prev.isNumber { return false }
        }
        return true
    }

    private static func findMarker(_ marker: String, in text: String, from i: String.Index) -> String.Index? {
        var k = i
        while k < text.endIndex {
            if text[k...].hasPrefix(marker) {
                if marker == "*" || marker == "_" {
                    let after = text.index(k, offsetBy: marker.count, limitedBy: text.endIndex) ?? text.endIndex
                    if after < text.endIndex, text[after...].hasPrefix(marker) {
                        k = text.index(after: k)
                        continue
                    }
                }
                return k
            }
            k = text.index(after: k)
        }
        return nil
    }

    // MARK: - HTML reader

    private struct Tag {
        var name: String
        var attr: String
        var closing: Bool
        var empty: Bool
        var end: String.Index
    }

    private static func readTag(_ s: String, at i: String.Index) -> Tag? {
        guard s[i] == "<" else { return nil }
        var j = s.index(after: i)
        guard j < s.endIndex else { return nil }
        let closing = s[j] == "/"
        if closing { j = s.index(after: j) }
        guard j < s.endIndex, s[j].isLetter else { return nil }
        let nameStart = j
        while j < s.endIndex, s[j].isLetter || s[j].isNumber {
            j = s.index(after: j)
        }
        let name = String(s[nameStart..<j]).lowercased()
        let attrStart = j
        while j < s.endIndex, s[j] != ">" {
            j = s.index(after: j)
        }
        guard j < s.endIndex else { return nil }
        let attr = String(s[attrStart..<j])
        let empty = attr.hasSuffix("/") || name == "br"
        return Tag(name: name, attr: attr, closing: closing, empty: empty, end: s.index(after: j))
    }

    private static func readUntilClose(_ name: String, _ s: String, from i: inout String.Index) -> String {
        var depth = 1
        let start = i
        while i < s.endIndex {
            guard s[i] == "<", let tag = readTag(s, at: i) else {
                i = s.index(after: i)
                continue
            }
            if tag.name == name, !tag.closing, !tag.empty { depth += 1 }
            if tag.name == name, tag.closing {
                depth -= 1
                if depth == 0 {
                    let inner = String(s[start..<i])
                    i = tag.end
                    return inner
                }
            }
            i = tag.end
        }
        return String(s[start...])
    }

    private static func skipHTMLNoise(_ i: inout String.Index, _ s: String) {
        while i < s.endIndex {
            if s[i].isWhitespace {
                i = s.index(after: i)
                continue
            }
            if s[i...].hasPrefix("<!") || s[i...].hasPrefix("<?") {
                if let end = s[i...].firstIndex(of: ">") {
                    i = s.index(after: end)
                    continue
                }
            }
            break
        }
    }

    private static func attrValue(_ name: String, _ attr: String) -> String {
        let pattern = "\(name)\\s*=\\s*(\"([^\"]*)\"|'([^']*)')"
        guard let re = RegexCache.cached(pattern, options: [.caseInsensitive]) else { return "" }
        let ns = attr as NSString
        guard let m = re.firstMatch(in: attr, range: NSRange(location: 0, length: ns.length)) else { return "" }
        if m.range(at: 2).location != NSNotFound { return unescapeHTML(ns.substring(with: m.range(at: 2))) }
        if m.range(at: 3).location != NSNotFound { return unescapeHTML(ns.substring(with: m.range(at: 3))) }
        return ""
    }

    private static func escape(_ ch: Character) -> String {
        switch ch {
        case "&": return "&amp;"
        case "<": return "&lt;"
        case ">": return "&gt;"
        default: return String(ch)
        }
    }

    private static func escapeText(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
    }

    private static func escapeAttr(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "<", with: "&lt;")
    }

    private static func unescapeHTML(_ s: String) -> String {
        var out = s
        for _ in 0..<2 {
            let next = out
                .replacingOccurrences(of: "&lt;", with: "<")
                .replacingOccurrences(of: "&gt;", with: ">")
                .replacingOccurrences(of: "&quot;", with: "\"")
                .replacingOccurrences(of: "&#39;", with: "'")
                .replacingOccurrences(of: "&apos;", with: "'")
                .replacingOccurrences(of: "&amp;", with: "&")
            if next == out { break }
            out = next
        }
        return out
    }

    private static func stripTags(_ s: String) -> String {
        guard let re = RegexCache.cached("<[^>]+>") else { return s }
        let ns = s as NSString
        return re.stringByReplacingMatches(in: s, range: NSRange(location: 0, length: ns.length), withTemplate: "")
    }

    // MARK: - Apple marks

    /// Apple 翻译会改写 `⟦§n⟧` 这种占位符，骨架还原不回来，Markdown 就散掉。
    /// 26.4 起它可以按 `AttributedString` 的 `skipsTranslation` 跳过标记，
    /// 所以这里把骨架切成一段段，标记段标上不翻译。
    static func appleSegments(_ text: String) -> [AppleSegment] {
        var out: [AppleSegment] = []
        func append(_ raw: String, keep: Bool) {
            guard !raw.isEmpty else { return }
            if let last = out.last, last.keep == keep {
                out[out.count - 1].text += raw
            } else {
                out.append(AppleSegment(text: raw, keep: keep))
            }
        }
        var i = text.startIndex
        var plain = ""
        while i < text.endIndex {
            if let (token, end) = tokenAt(text, i) {
                append(plain, keep: false)
                plain = ""
                append(token, keep: true)
                i = end
                continue
            }
            plain.append(text[i])
            i = text.index(after: i)
        }
        append(plain, keep: false)
        return out
    }

    struct AppleSegment: Sendable {
        var text: String
        /// 骨架标记，原样保留，不送去翻译。
        var keep: Bool
    }

    // MARK: - Chunks

    private static func atoms(_ text: String) -> [String] {
        var out: [String] = []
        var i = text.startIndex
        while i < text.endIndex {
            if atLineStart(text, i), let end = fenceEnd(text, from: i) {
                out.append(String(text[i..<end]))
                i = end
                continue
            }
            let lineEnd = endOfLine(text, i)
            let line = String(text[i..<lineEnd])
            i = lineEnd
            if line.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                var blanks = line
                while i < text.endIndex, atLineStart(text, i), fenceEnd(text, from: i) == nil {
                    let n = endOfLine(text, i)
                    let next = String(text[i..<n])
                    if !next.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { break }
                    blanks += next
                    i = n
                }
                out.append(blanks)
            } else {
                var block = line
                while i < text.endIndex {
                    if atLineStart(text, i), fenceEnd(text, from: i) != nil { break }
                    let n = endOfLine(text, i)
                    let next = String(text[i..<n])
                    if next.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { break }
                    block += next
                    i = n
                }
                out.append(block)
            }
        }
        return out
    }

    private static func endOfLine(_ text: String, _ i: String.Index) -> String.Index {
        guard let nl = text[i...].firstIndex(of: "\n") else { return text.endIndex }
        return text.index(after: nl)
    }
}

#if SKELETON_CHECK
@main
struct SkeletonCheck {
    static func main() {
        var failed = 0
        func check(_ name: String, _ ok: Bool) {
            if ok { print("ok \(name)") }
            else { failed += 1; print("FAIL \(name)") }
        }
        let sample = """
        ## Title

        See **this** and __that__ and *one* now.

        - [ ] alpha
        - [x] beta

        > quoted

        ```swift
        func keep() {}
        ```

        [docs](https://example.com/a) and https://example.com/b

        | A | B |
        | --- | :---: |
        | 1 | 2 |
        """
        let prepared = SourceSkeleton.prepare(sample, html: true)
        let back = SourceSkeleton.finish(prepared.payload, prepared: prepared)
        check("html identity", back == sample)
        if back != sample {
            print("--- got ---")
            print(back)
            print("--- payload ---")
            print(prepared.payload)
        }
        let plain = SourceSkeleton.prepare(sample, html: false)
        let plainBack = SourceSkeleton.finish(plain.payload, prepared: plain)
        check("token identity", plainBack == sample)
        if plainBack != sample {
            print("--- plain got ---")
            print(plainBack)
            print("--- plain payload ---")
            print(plain.payload)
        }
        let lines = "  Hello\r\nWorld\n\n- [ ] alpha\n> quoted\n| A | B |\n| --- | --- |\n"
        let lined = SourceSkeleton.prepare(lines, html: false)
        let linedBack = SourceSkeleton.finish(lined.payload, prepared: lined)
        check("plain lines", linedBack == lines)
        if linedBack != lines {
            print("--- lines got ---")
            print(linedBack.debugDescription)
            print("--- lines payload ---")
            print(lined.payload)
        }
        check("plain lines hide breaks", !lined.payload.contains("\n"))
        let chunks = SourceSkeleton.chunks(sample, limit: 80)
        check("chunks join", chunks.joined() == sample)
        check("fence intact", chunks.allSatisfy { part in
            let opens = part.components(separatedBy: "```").count - 1
            return opens != 1
        })
        let same = "Hello\nWorld\n\nNext"
        let again = SourceSkeleton.finish(SourceSkeleton.prepare(same, html: true).payload, prepared: SourceSkeleton.prepare(same, html: true))
        check("line breaks", again == same)
        if failed > 0 { exit(1) }
    }
}
#endif

/// Patterns are fixed or few, but they're matched per line while preparing large files.
enum RegexCache {
    private static let lock = NSLock()
    private static var compiled: [String: NSRegularExpression] = [:]

    static func cached(_ pattern: String, options: NSRegularExpression.Options = []) -> NSRegularExpression? {
        let key = "\(options.rawValue)|\(pattern)"
        lock.lock()
        defer { lock.unlock() }
        if let hit = compiled[key] { return hit }
        guard let re = try? NSRegularExpression(pattern: pattern, options: options) else { return nil }
        compiled[key] = re
        return re
    }
}
