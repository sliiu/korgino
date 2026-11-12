import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

struct DictionarySense: Identifiable, Equatable {
    let id = UUID()
    var partOfSpeech: String
    var definition: String
    var example: String?
    /// The dictionary's own wording when `definition` was translated into the reading language.
    var original: String? = nil
}

struct DictionarySection: Identifiable, Equatable {
    let id = UUID()
    var title: String
    var phonetic: String?
    var senses: [DictionarySense]
}

enum DictionaryProviderID: String, CaseIterable, Codable, Identifiable {
    case freeDictionary, youdao, baidu, caiyun
    var id: String { rawValue }
    var displayName: String {
        switch self {
        case .freeDictionary: return "Free Dictionary"
        case .youdao: return ProviderID.youdao.displayName
        case .baidu: return ProviderID.baidu.displayName
        case .caiyun: return ProviderID.caiyun.displayName
        }
    }
    var systemImage: String {
        switch self {
        case .freeDictionary: return "character.book.closed"
        case .youdao: return "y.circle.fill"
        case .baidu: return "b.circle.fill"
        case .caiyun: return "cloud.fill"
        }
    }
    var translateProvider: ProviderID? {
        switch self {
        case .freeDictionary: return nil
        case .youdao: return .youdao
        case .baidu: return .baidu
        case .caiyun: return .caiyun
        }
    }
}

struct DictionaryEntry: Equatable {
    var word: String
    var phonetic: String?
    var sections: [DictionarySection]

    var senses: [DictionarySense] { sections.flatMap(\.senses) }
}

enum DictionaryLookup {
    /// Suitable for dictionary lookup: short word / phrase.
    static func isLookupCandidate(_ text: String) -> Bool {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty, t.count <= 64 else { return false }
        let words = t.split(whereSeparator: { $0.isWhitespace || $0.isNewline })
        return words.count <= 6
    }

    /// Latin-script short text — good Free Dictionary API target (e.g. English translation of a Chinese word).
    static func looksLatinLemma(_ text: String) -> Bool {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return false }
        let letterCount = t.unicodeScalars.filter { CharacterSet.letters.contains($0) }.count
        guard letterCount > t.count / 3 else { return false }
        return t.rangeOfCharacter(from: CharacterSet(charactersIn: "一"..."鿿")) == nil
    }

    /// `explainIn` is the language the definitions should read in. Nil means the native language.
    /// `source` is a language the user picked for the word. Nil means detect.
    static func lookup(_ text: String, explainIn: TargetLanguage? = nil, source: TargetLanguage? = nil) async throws -> DictionaryEntry {
        let q = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { throw TErr(L("查询词为空")) }
        await AppConfig.shared.awaitSecrets()
        let payload = try await MaskedSend.prepare(
            q,
            destination: AppConfig.shared.dictProvider.displayName
        )
        var entry = try await lookupUncovered(payload, source: source)
        let reading = (explainIn ?? AppConfig.shared.nativeLanguage).resolvedDestination
        entry.sections = await explain(entry.sections, in: reading)
        return DictionaryEntry(
            word: SecretCover.restore(entry.word),
            phonetic: entry.phonetic.map(SecretCover.restore),
            sections: entry.sections.map { section in
                DictionarySection(
                    title: section.title,
                    phonetic: section.phonetic.map(SecretCover.restore),
                    senses: section.senses.map { sense in
                        DictionarySense(
                            partOfSpeech: sense.partOfSpeech,
                            definition: SecretCover.restore(sense.definition),
                            example: sense.example.map(SecretCover.restore),
                            original: sense.original.map(SecretCover.restore)
                        )
                    }
                )
            }
        )
    }

    /// Free Dictionary only writes English. For any other reading language its definitions go
    /// through one builtin translation service in a single request; the English stays as `original`.
    /// A failed translation keeps the English.
    private static func explain(_ sections: [DictionarySection], in reading: TargetLanguage) async -> [DictionarySection] {
        guard reading != .en,
              let index = sections.firstIndex(where: { $0.title == "Free Dictionary" }),
              let service = explainService() else { return sections }
        let senses = sections[index].senses
        let joined = senses.map { $0.definition.replacingOccurrences(of: "\n", with: " ") }.joined(separator: "\n")
        guard let out = try? await Translator.translateQuiet(joined, target: service, language: reading) else {
            return sections
        }
        let lines = out.text.components(separatedBy: "\n")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        guard lines.count == senses.count else { return sections }
        var result = sections
        result[index].senses = zip(senses, lines).map { sense, line in
            var s = sense
            s.original = sense.definition
            s.definition = line
            return s
        }
        return result
    }

    /// Prefers a builtin service; AI is slow and costs a call for a few short lines. Falls back to whatever is enabled.
    private static func explainService() -> TranslateTarget? {
        let targets = AppConfig.shared.simultaneousTargets()
        let builtin = targets.first {
            if case .builtin = $0 { return true }
            return false
        }
        return builtin ?? targets.first
    }

    private static func lookupUncovered(_ q: String, source: TargetLanguage?) async throws -> DictionaryEntry {
        // Free Dictionary is English only. A word picked as another language must not get the English entry.
        let latin = looksLatinLemma(q) && (source == nil || source == .en)
        let targets = AppConfig.shared.activeDictionaryProviders()
        let want = Set(targets)
        async let free = section(want.contains(.freeDictionary) && latin) { try await freeDictionary(q) }
        async let youdao = section(want.contains(.youdao)) { try await youdaoDictionary(q) }
        async let baidu = section(want.contains(.baidu) && (latin || hasHan(q))) { try await baiduDictionary(q) }
        async let caiyun = section(want.contains(.caiyun)) { try await caiyunDictionary(q) }
        let found: [DictionaryProviderID: DictionarySection] = [
            .freeDictionary: await free,
            .youdao: await youdao,
            .baidu: await baidu,
            .caiyun: await caiyun,
        ].compactMapValues { $0 }
        let sections = targets.compactMap { found[$0] }
        if sections.isEmpty { return try await glossFallback(q, source: source) }
        return DictionaryEntry(
            word: q,
            phonetic: sections.compactMap(\.phonetic).first { !$0.isEmpty },
            sections: sections
        )
    }

    private static func section(_ on: Bool, _ work: @escaping () async throws -> DictionarySection) async -> DictionarySection? {
        guard on else { return nil }
        return try? await work()
    }

    private static func freeDictionary(_ word: String) async throws -> DictionarySection {
        let encoded = word.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? word
        guard let url = URL(string: "https://api.dictionaryapi.dev/api/v2/entries/en/\(encoded)") else {
            throw TErr(L("无效查询"))
        }
        var req = URLRequest(url: url)
        req.timeoutInterval = 15
        let (data, resp) = try await NetSession.data(for: req)
        let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
        if code == 404 { throw TErr(L("未找到词条")) }
        guard code == 200,
              let arr = try JSONSerialization.jsonObject(with: data) as? [[String: Any]],
              let first = arr.first else {
            throw TErr(String(format: L("词典查询失败 (%@)"), String(describing: code)))
        }
        var phonetic = first["phonetic"] as? String
        if phonetic == nil, let phonetics = first["phonetics"] as? [[String: Any]] {
            phonetic = phonetics.compactMap { $0["text"] as? String }.first
        }
        var senses: [DictionarySense] = []
        if let meanings = first["meanings"] as? [[String: Any]] {
            for m in meanings {
                let pos = m["partOfSpeech"] as? String ?? ""
                if let defs = m["definitions"] as? [[String: Any]] {
                    for d in defs.prefix(4) {
                        guard let def = d["definition"] as? String, !def.isEmpty else { continue }
                        push(&senses, pos: pos, def: def, example: d["example"] as? String)
                    }
                }
            }
        }
        guard !senses.isEmpty else { throw TErr(L("词条无释义")) }
        return DictionarySection(title: "Free Dictionary", phonetic: phonetic, senses: senses)
    }

    private static func youdaoDictionary(_ word: String) async throws -> DictionarySection {
        let (lang, dicts) = youdaoQuery(word)
        let json = try await Translator.youdaoDictJSON(word, langType: lang, dicts: dicts)
        var senses: [DictionarySense] = []
        var phonetic: String?
        for block in youdaoBlocks(json) {
            if phonetic == nil { phonetic = youdaoPhonetic(block) }
            for node in youdaoWords(block) {
                if phonetic == nil { phonetic = youdaoPhonetic(node) }
                if let trs = node["trs"] as? [[String: Any]] {
                    for tr in trs {
                        for (pos, line) in youdaoLines(tr) {
                            push(&senses, pos: pos, def: line, example: nil)
                        }
                    }
                }
            }
            if phonetic == nil, let basic = block["basic"] as? [String: Any] {
                phonetic = youdaoPhonetic(basic)
            }
            if senses.isEmpty {
                let explains = (block["explains"] as? [String])
                    ?? ((block["basic"] as? [String: Any])?["explains"] as? [String])
                    ?? []
                for line in explains {
                    push(&senses, pos: "", def: line, example: nil)
                }
            }
            if senses.count < 6, let web = block["web"] as? [[String: Any]] {
                for item in web.prefix(2) {
                    let key = (item["key"] as? String) ?? (item["phrase"] as? String) ?? ""
                    let meaning = youdaoWebMeaning(item)
                    guard !meaning.isEmpty else { continue }
                    let text = key.isEmpty ? meaning : "\(key)：\(meaning)"
                    push(&senses, pos: L("网络释义"), def: text, example: nil)
                }
            }
            if let sample = youdaoExample(block), let index = senses.firstIndex(where: { $0.example == nil }) {
                senses[index].example = sample
            }
        }
        guard !senses.isEmpty else { throw TErr(L("未找到词条")) }
        return DictionarySection(title: ProviderID.youdao.displayName, phonetic: phonetic, senses: senses)
    }

    private static func youdaoQuery(_ word: String) -> (String, [String]) {
        if hasKana(word) { return ("ja", ["jc"]) }
        if hasHangul(word) { return ("ko", ["kc"]) }
        if hasHan(word) { return ("zh-CHS", ["ce", "yw"]) }
        return ("en", ["ec", "ee"])
    }

    private static func youdaoBlocks(_ json: [String: Any]) -> [[String: Any]] {
        let roots: [[String: Any]]
        if let result = json["result"] as? [[String: Any]] {
            roots = result
        } else if let result = json["result"] as? [String: Any] {
            roots = [result]
        } else {
            roots = [json]
        }
        let keys = ["ec", "ee", "ce", "yw", "jc", "cj", "kc", "ck"]
        var blocks: [[String: Any]] = []
        for root in roots {
            let picked = keys.compactMap { root[$0] as? [String: Any] }
            blocks.append(contentsOf: picked.isEmpty ? [root] : picked)
        }
        return blocks
    }

    private static func youdaoWords(_ block: [String: Any]) -> [[String: Any]] {
        if let word = block["word"] as? [String: Any] { return [word] }
        if let word = block["word"] as? [[String: Any]] { return word }
        return []
    }

    private static func youdaoLines(_ tr: [String: Any]) -> [(String, String)] {
        let pos = (tr["pos"] as? String) ?? ""
        if let tran = tr["tran"] as? String, !tran.isEmpty { return [(pos, tran)] }
        guard let nested = tr["tr"] as? [[String: Any]] else { return [] }
        return nested.flatMap { item in youdaoTexts(item["l"]).map { (pos, $0) } }
    }

    private static func youdaoTexts(_ node: Any?) -> [String] {
        guard let node else { return [] }
        if let s = node as? String {
            let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
            return t.isEmpty ? [] : [t]
        }
        if let arr = node as? [String] { return arr.flatMap { youdaoTexts($0) } }
        if let arr = node as? [Any] { return arr.flatMap { youdaoTexts($0) } }
        if let dict = node as? [String: Any] {
            if let i = dict["i"] { return youdaoTexts(i) }
            if let l = dict["l"] { return youdaoTexts(l) }
        }
        return []
    }

    private static func youdaoWebMeaning(_ item: [String: Any]) -> String {
        if let values = item["value"] as? [String] {
            return values.filter { !$0.isEmpty }.joined(separator: "；")
        }
        if let meaning = item["meaning"] as? String { return meaning }
        if let meaning = item["meaning"] as? [String] {
            return meaning.filter { !$0.isEmpty }.joined(separator: "；")
        }
        return ""
    }

    private static func youdaoExample(_ block: [String: Any]) -> String? {
        let samples = (block["sentenceSample"] as? [[String: Any]]) ?? []
        for sample in samples {
            let sentence = (sample["sentence"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            guard !sentence.isEmpty else { continue }
            let translation = (sample["translation"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return translation.isEmpty ? sentence : "\(sentence) \(translation)"
        }
        return nil
    }

    private static func youdaoPhonetic(_ dict: [String: Any]) -> String? {
        let uk = firstString(dict, ["ukPhonetic", "ukphone", "uk-phonetic"])
        let us = firstString(dict, ["usPhonetic", "usphone", "us-phonetic"])
        let ph = firstString(dict, ["phonetic"])
        return phoneticLabel(uk: uk, us: us, other: ph)
    }

    private static func baiduDictionary(_ word: String) async throws -> DictionarySection {
        let from = hasHan(word) ? "zh" : "en"
        let to = from == "zh" ? "en" : "zh"
        let json = try await Translator.baiduJSON(word, target: to, source: from)
        if let err = json["error_code"] {
            let code = "\(err)"
            if code != "52000" { throw TErr(String(format: L("百度翻译错误 %@: %@"), code, json["error_msg"] as? String ?? "")) }
        }
        guard let results = json["trans_result"] as? [[String: Any]] else { throw TErr(L("未找到词条")) }
        var senses: [DictionarySense] = []
        var phonetic: String?
        for row in results {
            guard let dict = baiduDictObject(row["dict"]),
                  let wordResult = dict["word_result"] as? [String: Any] else { continue }
            if let simple = wordResult["simple_means"] as? [String: Any] {
                if let symbols = simple["symbols"] as? [[String: Any]] {
                    for sym in symbols {
                        if phonetic == nil {
                            phonetic = phoneticLabel(
                                uk: sym["ph_en"] as? String,
                                us: sym["ph_am"] as? String,
                                other: sym["word_symbol"] as? String
                            )
                        }
                        for (pos, line) in baiduMeans(sym["parts"]) {
                            push(&senses, pos: pos, def: line, example: nil)
                        }
                    }
                }
                if senses.isEmpty {
                    for (_, line) in baiduMeans(simple["word_means"]) {
                        push(&senses, pos: "", def: line, example: nil)
                    }
                }
            }
            if let edict = wordResult["edict"] as? [String: Any], let items = edict["item"] as? [[String: Any]] {
                for item in items {
                    let pos = (item["pos"] as? String) ?? ""
                    guard let groups = item["tr_group"] as? [[String: Any]] else { continue }
                    for group in groups {
                        let example = (group["example"] as? [String])?.first { !$0.isEmpty }
                        let lines = (group["tr"] as? [String]) ?? []
                        for line in lines.prefix(2) {
                            push(&senses, pos: pos, def: line, example: example)
                        }
                    }
                }
            }
            if senses.count < 4, let zdict = wordResult["zdict"] as? [String: Any] {
                for key in ["simple", "detail"] {
                    for (pos, line) in baiduMeans(zdict[key]) {
                        push(&senses, pos: pos, def: line, example: nil)
                    }
                }
            }
        }
        guard !senses.isEmpty else { throw TErr(L("未找到词条")) }
        return DictionarySection(title: ProviderID.baidu.displayName, phonetic: phonetic, senses: senses)
    }

    private static func baiduDictObject(_ raw: Any?) -> [String: Any]? {
        if let dict = raw as? [String: Any] { return dict }
        guard let text = raw as? String else { return nil }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed != "\"\"",
              let data = trimmed.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        return obj
    }

    private static func baiduMeans(_ node: Any?) -> [(String, String)] {
        var out: [(String, String)] = []
        func walk(_ node: Any?, pos: String) {
            if let text = node as? String {
                let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
                if !t.isEmpty { out.append((pos, t)) }
                return
            }
            if let arr = node as? [Any] {
                for item in arr { walk(item, pos: pos) }
                return
            }
            guard let dict = node as? [String: Any] else { return }
            let pos2 = firstString(dict, ["part", "pos", "part_name"]) ?? pos
            if let means = dict["means"] { walk(means, pos: pos2); return }
            if let text = dict["text"] { walk(text, pos: pos2) }
            if let wordMean = dict["word_mean"] { walk(wordMean, pos: pos2) }
            if let explain = dict["explain"] { walk(explain, pos: pos2) }
            if let exp = dict["exp"] as? [String: Any], let des = exp["des"] { walk(des, pos: pos2) }
            if let parts = dict["parts"] { walk(parts, pos: pos2) }
        }
        walk(node, pos: "")
        return out
    }

    private static func caiyunDictionary(_ word: String) async throws -> DictionarySection {
        let transType: String = {
            if hasKana(word) { return "ja2zh" }
            if hasHan(word) { return "zh2en" }
            return "en2zh"
        }()
        let json = try await Translator.caiyunDictJSON(word, transType: transType)
        guard let dict = (json["dictionary"] as? [String: Any]) ?? (json["dict"] as? [String: Any]) else {
            throw TErr(L("未找到词条"))
        }
        var senses: [DictionarySense] = []
        for line in caiyunLines(dict["explanations"]) {
            push(&senses, pos: "", def: line, example: nil)
        }
        if let examples = dict["wqx_example"] as? [[String]],
           let first = examples.first,
           let sentence = first.first?.trimmingCharacters(in: .whitespacesAndNewlines),
           !sentence.isEmpty,
           let index = senses.firstIndex(where: { $0.example == nil }) {
            let translation = first.dropFirst().first?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            senses[index].example = translation.isEmpty ? sentence : "\(sentence) \(translation)"
        }
        guard !senses.isEmpty else { throw TErr(L("未找到词条")) }
        let prons = dict["prons"] as? [String: Any]
        let phonetic = phoneticLabel(
            uk: prons?["en"] as? String,
            us: prons?["en-us"] as? String,
            other: (prons?["zh"] as? String) ?? (dict["phonetic"] as? String)
        )
        return DictionarySection(title: ProviderID.caiyun.displayName, phonetic: phonetic, senses: senses)
    }

    private static func caiyunLines(_ node: Any?) -> [String] {
        if let text = node as? String {
            let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
            return t.isEmpty ? [] : [t]
        }
        if let arr = node as? [String] { return arr.flatMap { caiyunLines($0) } }
        if let arr = node as? [Any] {
            return arr.flatMap { item -> [String] in
                if let dict = item as? [String: Any] {
                    return caiyunLines(dict["text"] ?? dict["meaning"] ?? dict["explain"])
                }
                return caiyunLines(item)
            }
        }
        return []
    }

    /// Lightweight gloss when no dictionary returned an entry.
    private static func glossFallback(_ text: String, source: TargetLanguage?) async throws -> DictionaryEntry {
        let plan = Lang.plan(text, source: source?.appleCode, mutual: true)
        let translated: String
        do {
            translated = try await Translator.mymemory(text, target: plan.tgtGoogle, source: plan.src)
        } catch {
            if Lang.sameLanguage(plan) { translated = text } else { throw error }
        }
        let label = L("对译参考")
        return DictionaryEntry(
            word: text,
            phonetic: nil,
            sections: [
                DictionarySection(
                    title: ProviderID.mymemory.displayName,
                    phonetic: nil,
                    senses: [
                        DictionarySense(partOfSpeech: label, definition: translated, example: nil),
                        DictionarySense(
                            partOfSpeech: L("提示"),
                            definition: L("没有词典释义，上面是一句对译。"),
                            example: nil
                        ),
                    ]
                ),
            ]
        )
    }

    private static func push(_ senses: inout [DictionarySense], pos: String, def: String, example: String?) {
        let text = def.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, senses.count < 8 else { return }
        if senses.contains(where: { $0.definition == text }) { return }
        let sample = example?.trimmingCharacters(in: .whitespacesAndNewlines)
        senses.append(DictionarySense(
            partOfSpeech: pos.trimmingCharacters(in: .whitespacesAndNewlines),
            definition: text,
            example: (sample?.isEmpty == false) ? sample : nil
        ))
    }

    private static func firstString(_ dict: [String: Any], _ keys: [String]) -> String? {
        for key in keys {
            if let text = dict[key] as? String {
                let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
                if !t.isEmpty { return t }
            }
        }
        return nil
    }

    private static func phoneticLabel(uk: String?, us: String?, other: String?) -> String? {
        var bits: [String] = []
        if let uk, !uk.isEmpty { bits.append("UK \(ipa(uk))") }
        if let us, !us.isEmpty, us != uk { bits.append("US \(ipa(us))") }
        if bits.isEmpty, let other, !other.isEmpty { bits.append(ipa(other)) }
        return bits.isEmpty ? nil : bits.joined(separator: "  ")
    }

    private static func ipa(_ raw: String) -> String {
        let t = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if t.hasPrefix("/") || t.hasPrefix("[") { return t }
        return "/\(t)/"
    }

    private static func hasHan(_ text: String) -> Bool {
        text.rangeOfCharacter(from: CharacterSet(charactersIn: "\u{4e00}"..."\u{9fff}")) != nil
    }

    private static func hasKana(_ text: String) -> Bool {
        text.unicodeScalars.contains { (0x3040...0x30FF).contains($0.value) }
    }

    private static func hasHangul(_ text: String) -> Bool {
        text.unicodeScalars.contains { (0xAC00...0xD7AF).contains($0.value) }
    }
}
