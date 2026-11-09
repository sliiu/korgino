import Foundation

struct SessionNoteBinding: Equatable {
    var id: String
    var key: String
    var isSource: Bool
    var translatesToNative: Bool

    static let source = SessionNoteBinding(id: "none", key: "none", isSource: true, translatesToNative: false)
}

struct SessionNoteCue: Equatable {
    /// The segment this cue came from. A note line points back here.
    var id: String = ""
    var mark: String
    var source: String
    /// Set when this binding already has a translation. Errors and blanks stay nil.
    var translation: String?
    var waiting: Bool
}

struct SessionNoteTerm: Equatable, Codable {
    var word: String
    var rendering: String
}

/// One line of a section, with the segments it was taken from.
struct SessionNoteItem: Equatable, Codable {
    var text: String
    /// Segment ids, in the order the model cited them. Unknown numbers are dropped.
    var cues: [String] = []
}

struct SessionNotePage: Equatable, Codable {
    var summary: String
    var topics: [SessionNoteItem] = []
    var decisions: [SessionNoteItem] = []
    var todos: [SessionNoteItem] = []
    var terms: [SessionNoteTerm]
    var unmatched: [String]
    /// How many finished segments the page was written from.
    var cueCount: Int = 0
    var writtenAt: Date?

    init(
        summary: String,
        topics: [SessionNoteItem] = [],
        decisions: [SessionNoteItem] = [],
        todos: [SessionNoteItem] = [],
        terms: [SessionNoteTerm],
        unmatched: [String],
        cueCount: Int = 0,
        writtenAt: Date? = nil
    ) {
        self.summary = summary
        self.topics = topics
        self.decisions = decisions
        self.todos = todos
        self.terms = terms
        self.unmatched = unmatched
        self.cueCount = cueCount
        self.writtenAt = writtenAt
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        summary = try c.decodeIfPresent(String.self, forKey: .summary) ?? ""
        topics = try c.decodeIfPresent([SessionNoteItem].self, forKey: .topics) ?? []
        decisions = try c.decodeIfPresent([SessionNoteItem].self, forKey: .decisions) ?? []
        todos = try c.decodeIfPresent([SessionNoteItem].self, forKey: .todos) ?? []
        terms = try c.decodeIfPresent([SessionNoteTerm].self, forKey: .terms) ?? []
        unmatched = try c.decodeIfPresent([String].self, forKey: .unmatched) ?? []
        cueCount = try c.decodeIfPresent(Int.self, forKey: .cueCount) ?? 0
        writtenAt = try c.decodeIfPresent(Date.self, forKey: .writtenAt)
    }

    func copyText() -> String {
        var lines: [String] = [L("这场在说什么"), summary.isEmpty ? L("没有") : summary]
        for (title, items) in [(L("议题"), topics), (L("结论"), decisions), (L("待办"), todos)] {
            lines.append("")
            lines.append(title)
            if items.isEmpty {
                lines.append(L("没有"))
            } else {
                lines.append(contentsOf: items.map { "- \($0.text)" })
            }
        }
        lines.append("")
        lines.append(L("反复出现的词"))
        if terms.isEmpty {
            lines.append(L("没有"))
        } else {
            for term in terms {
                lines.append("\(term.word)  \(term.rendering)")
            }
        }
        lines.append("")
        lines.append(L("没对上的地方"))
        if unmatched.isEmpty {
            lines.append(L("没有"))
        } else {
            lines.append(contentsOf: unmatched)
        }
        return lines.joined(separator: "\n")
    }
}

struct SessionNoteBrief: Equatable {
    var serviceID: String?
    var transcript: String
    var sources: String
    var translations: String
    var unmatched: [String]
    var hasCue: Bool
    /// Segment id for each `#n` in the transcript, `ids[n - 1]`.
    var ids: [String] = []

    var cueCount: Int { ids.count }

    static let empty = SessionNoteBrief(
        serviceID: nil, transcript: "", sources: "", translations: "", unmatched: [], hasCue: false
    )
}

enum SessionNote {
    /// First binding aimed at the native language, otherwise the first binding. 「不翻译」 counts.
    static func choose(_ bindings: [SessionNoteBinding]) -> SessionNoteBinding {
        if let native = bindings.first(where: { !$0.isSource && $0.translatesToNative }) { return native }
        return bindings.first ?? .source
    }

    static func brief(_ cues: [SessionNoteCue], binding: SessionNoteBinding) -> SessionNoteBrief {
        var blocks: [String] = []
        var sources: [String] = []
        var translations: [String] = []
        var unmatched: [String] = []
        var ids: [String] = []
        for cue in cues where !cue.waiting {
            let source = cue.source.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !source.isEmpty else { continue }
            sources.append(source)
            ids.append(cue.id)
            var lines: [String] = ["#\(ids.count)"]
            let mark = cue.mark.trimmingCharacters(in: .whitespacesAndNewlines)
            if !mark.isEmpty { lines.append(mark) }
            lines.append(source)
            if binding.isSource {
                translations.append(source)
            } else if let translation = cue.translation?.trimmingCharacters(in: .whitespacesAndNewlines), !translation.isEmpty {
                lines.append(translation)
                translations.append(translation)
            } else {
                unmatched.append(mark.isEmpty ? source : "\(mark) \(source)")
            }
            blocks.append(lines.joined(separator: "\n"))
        }
        let sourceText = sources.joined(separator: "\n")
        let translationText = binding.isSource ? sourceText : translations.joined(separator: "\n")
        return SessionNoteBrief(
            serviceID: binding.isSource ? nil : binding.id,
            transcript: blocks.joined(separator: "\n\n"),
            sources: sourceText,
            translations: translationText,
            unmatched: unmatched,
            hasCue: !blocks.isEmpty,
            ids: ids
        )
    }

    /// The page the model wrote, or nil when nothing usable came back.
    /// A term stays only when both sides already appear in what was sent. A line's `#n` must be a sent segment.
    static func page(_ reply: String, brief: SessionNoteBrief, at date: Date = Date()) -> SessionNotePage? {
        var summary: [String] = []
        var lists: [Heading: [String]] = [:]
        var mode: Heading = .say
        var sawHeading = false
        for raw in reply.components(separatedBy: "\n") {
            if let heading = heading(raw) {
                sawHeading = true
                mode = heading
                continue
            }
            if mode == .say {
                summary.append(raw)
            } else {
                lists[mode, default: []].append(raw)
            }
        }
        var summaryText = summary.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        if !sawHeading { summaryText = reply.trimmingCharacters(in: .whitespacesAndNewlines) }
        summaryText = stripRefs(summaryText)
        var terms: [SessionNoteTerm] = []
        var seen: Set<String> = []
        let corpus = brief.translations.isEmpty ? brief.sources : brief.translations
        for raw in lists[.terms] ?? [] {
            guard let term = term(from: raw, sources: brief.sources, translations: corpus) else { continue }
            let key = term.word.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
            guard seen.insert(key).inserted else { continue }
            terms.append(term)
            if terms.count == 40 { break }
        }
        let topics = items(lists[.topics] ?? [], ids: brief.ids, limit: 12)
        let decisions = items(lists[.decisions] ?? [], ids: brief.ids, limit: 20)
        let todos = items(lists[.todos] ?? [], ids: brief.ids, limit: 20)
        guard !summaryText.isEmpty || !terms.isEmpty || !topics.isEmpty || !decisions.isEmpty || !todos.isEmpty else {
            return nil
        }
        return SessionNotePage(
            summary: summaryText,
            topics: topics,
            decisions: decisions,
            todos: todos,
            terms: terms,
            unmatched: brief.unmatched,
            cueCount: brief.cueCount,
            writtenAt: date
        )
    }

    /// `- text (#3, #12)` → text plus the ids of segments 3 and 12. 「无」 and empty lines are dropped.
    static func items(_ lines: [String], ids: [String], limit: Int) -> [SessionNoteItem] {
        var out: [SessionNoteItem] = []
        for raw in lines {
            let line = stripListMark(raw.trimmingCharacters(in: .whitespacesAndNewlines))
            guard !line.isEmpty else { continue }
            var cues: [String] = []
            for number in refNumbers(line) where number >= 1 && number <= ids.count {
                let id = ids[number - 1]
                if !id.isEmpty, !cues.contains(id) { cues.append(id) }
            }
            let text = clean(stripRefs(line))
            let bare = text.trimmingCharacters(in: CharacterSet(charactersIn: "。.、 "))
            guard !bare.isEmpty, !["无", "没有", "暂无", "none", "n/a", "-"].contains(bare.lowercased()) else { continue }
            out.append(SessionNoteItem(text: text, cues: cues))
            if out.count == limit { break }
        }
        return out
    }

    private static let refPattern = #"#\s?(\d{1,5})"#

    private static func refNumbers(_ line: String) -> [Int] {
        guard let regex = try? NSRegularExpression(pattern: refPattern) else { return [] }
        let ns = line as NSString
        return regex.matches(in: line, range: NSRange(location: 0, length: ns.length)).compactMap { match in
            Int(ns.substring(with: match.range(at: 1)))
        }
    }

    /// Drops `(#3, #12)`, `[#3]`, `（#3）` and bare `#3` the model left in the text.
    static func stripRefs(_ text: String) -> String {
        var t = text
        let patterns = [
            #"\s*[（(\[【]\s*(?:#\s?\d{1,5}\s*[,，、;；和与及&\s]*)+\s*[)）\]】]"#,
            #"\s*#\s?\d{1,5}"#,
        ]
        for pattern in patterns {
            t = t.replacingOccurrences(of: pattern, with: "", options: .regularExpression)
        }
        return t.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func rejectedForLength(_ message: String) -> Bool {
        let text = message.lowercased()
        let needles = [
            "context length", "context_length", "maximum context", "max context",
            "too many tokens", "token limit", "maximum tokens", "max tokens",
            "request entity too large", "payload too large", "string too long",
            "超出长度", "超过长度", "长度超", "上下文长度",
        ]
        if needles.contains(where: { text.contains($0) }) { return true }
        if text.contains("413"),
           text.contains("large") || text.contains("long") || text.contains("token") || text.contains("length") {
            return true
        }
        return false
    }

    private enum Heading { case say, topics, decisions, todos, terms }

    private static func heading(_ line: String) -> Heading? {
        var trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        // `#12 ...` is a citation, not a heading.
        if trimmed.range(of: #"^#\s?\d"#, options: .regularExpression) != nil { return nil }
        trimmed = trimmed.trimmingCharacters(in: CharacterSet(charactersIn: "#*>-• "))
        trimmed = trimmed.trimmingCharacters(in: CharacterSet(charactersIn: "：: "))
        let key = trimmed.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
        switch key {
        case "say", "summary", "这场在说什么", "总结": return .say
        case "topics", "topic", "议题": return .topics
        case "decisions", "decision", "conclusions", "结论": return .decisions
        case "todos", "todo", "action items", "待办": return .todos
        case "terms", "反复出现的词", "术语": return .terms
        default: return nil
        }
    }

    private static func term(from line: String, sources: String, translations: String) -> SessionNoteTerm? {
        var trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        trimmed = stripListMark(trimmed)
        guard let split = firstSplit(trimmed) else { return nil }
        let word = clean(split.word)
        let rendering = clean(split.rendering)
        guard word.count >= 2, rendering.count >= 2 else { return nil }
        guard contains(word, in: sources), contains(rendering, in: translations) else { return nil }
        return SessionNoteTerm(word: word, rendering: rendering)
    }

    /// Pipe first. A colon or a spaced dash only when the model did not use a pipe.
    private static func firstSplit(_ line: String) -> (word: String, rendering: String)? {
        if let range = earliest(line, ["|", "｜"]) {
            return (String(line[..<range.lowerBound]), String(line[range.upperBound...]))
        }
        if let range = earliest(line, ["：", ":"]) {
            return (String(line[..<range.lowerBound]), String(line[range.upperBound...]))
        }
        if let range = earliest(line, [" — ", "——", " - "]) {
            return (String(line[..<range.lowerBound]), String(line[range.upperBound...]))
        }
        return nil
    }

    private static func earliest(_ line: String, _ seps: [String]) -> Range<String.Index>? {
        var best: Range<String.Index>?
        for sep in seps {
            guard let range = line.range(of: sep) else { continue }
            if best == nil || range.lowerBound < best!.lowerBound { best = range }
        }
        return best
    }

    private static func stripListMark(_ line: String) -> String {
        var t = line
        if t.hasPrefix("- ") || t.hasPrefix("* ") || t.hasPrefix("• ") {
            t.removeFirst(2)
        } else if let range = t.range(of: #"^\d+[.)]\s+"#, options: .regularExpression) {
            t.removeSubrange(range)
        }
        return t.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func clean(_ raw: String) -> String {
        var t = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let junk = CharacterSet(charactersIn: "*_`「」\"'“”")
        while let first = t.unicodeScalars.first, junk.contains(first) {
            t.unicodeScalars.removeFirst()
        }
        while let last = t.unicodeScalars.last, junk.contains(last) {
            t.unicodeScalars.removeLast()
        }
        return t.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Han phrases match as written. A Latin word has to stand on its own, so "to" does not hit "today".
    private static func contains(_ needle: String, in haystack: String) -> Bool {
        if needle.unicodeScalars.contains(where: { (0x4E00...0x9FFF).contains($0.value) || (0x3400...0x4DBF).contains($0.value) }) {
            return haystack.range(of: needle, options: [.caseInsensitive, .diacriticInsensitive]) != nil
        }
        var search = haystack.startIndex
        let options: String.CompareOptions = [.caseInsensitive, .diacriticInsensitive]
        while let range = haystack.range(of: needle, options: options, range: search..<haystack.endIndex) {
            let before = range.lowerBound == haystack.startIndex || !isWord(haystack[haystack.index(before: range.lowerBound)])
            let after = range.upperBound == haystack.endIndex || !isWord(haystack[range.upperBound])
            if before && after { return true }
            search = range.upperBound
        }
        return false
    }

    private static func isWord(_ c: Character) -> Bool {
        c.unicodeScalars.contains { CharacterSet.alphanumerics.contains($0) }
    }
}
