import Foundation

/// A concrete translation language. `auto` remains only so older saved values still decode.
enum TargetLanguage: String, CaseIterable, Identifiable, Codable {
    case auto
    case zhHans, zhHant, en, ja, ko, fr, de, es, ru, pt, it, vi, th, id, ar, hi, tr, nl, pl, sv

    var id: String { rawValue }

    /// Languages a person can pick. `auto` is not one of them.
    static var specific: [TargetLanguage] {
        allCases.filter { $0 != .auto }
    }

    /// `auto` is no longer a destination. An old value follows the settings target, or English when that was auto too.
    var resolvedDestination: TargetLanguage {
        guard self == .auto else { return self }
        let settings = AppConfig.shared.targetLanguage
        return settings == .auto ? .en : settings
    }

    /// Native language for a fresh install. English systems start at Simplified Chinese so the pair is not English twice; the target language stays English either way.
    static func defaultNative() -> TargetLanguage {
        let system = fromSystem()
        return system == .en ? .zhHans : system
    }

    /// Caption target stored under `key`. `auto` is rewritten to the settings target, or English when that was auto too.
    static func storedCaptionTarget(key: String) -> TargetLanguage {
        let defaults = UserDefaults.standard
        if let lang = defaults.string(forKey: key).flatMap(TargetLanguage.init(rawValue:)), lang != .auto {
            return lang
        }
        let global = defaults.string(forKey: "targetLanguage").flatMap(TargetLanguage.init(rawValue:))
        let resolved: TargetLanguage = (global == nil || global == .auto) ? .en : global!
        if defaults.string(forKey: key) == TargetLanguage.auto.rawValue {
            defaults.set(resolved.rawValue, forKey: key)
        }
        return resolved
    }

    var menuTitle: String {
        switch self {
        case .auto: return L("自动（中↔英）")
        case .zhHans: return L("简体中文")
        case .zhHant: return L("繁體中文")
        case .en: return "English"
        case .ja: return L("日本語")
        case .ko: return "한국어"
        case .fr: return "Français"
        case .de: return "Deutsch"
        case .es: return "Español"
        case .ru: return "Русский"
        case .pt: return "Português"
        case .it: return "Italiano"
        case .vi: return "Tiếng Việt"
        case .th: return "ไทย"
        case .id: return "Indonesia"
        case .ar: return "العربية"
        case .hi: return "हिन्दी"
        case .tr: return "Türkçe"
        case .nl: return "Nederlands"
        case .pl: return "Polski"
        case .sv: return "Svenska"
        }
    }

    /// Short label for compact pickers.
    var shortTitle: String {
        switch self {
        case .auto: return L("自动")
        default: return menuTitle
        }
    }

    /// Apple Translation / BCP-47 style id (nil for auto).
    var appleCode: String? {
        switch self {
        case .auto: return nil
        case .zhHans: return "zh-Hans"
        case .zhHant: return "zh-Hant"
        case .en: return "en"
        case .ja: return "ja"
        case .ko: return "ko"
        case .fr: return "fr"
        case .de: return "de"
        case .es: return "es"
        case .ru: return "ru"
        case .pt: return "pt"
        case .it: return "it"
        case .vi: return "vi"
        case .th: return "th"
        case .id: return "id"
        case .ar: return "ar"
        case .hi: return "hi"
        case .tr: return "tr"
        case .nl: return "nl"
        case .pl: return "pl"
        case .sv: return "sv"
        }
    }

    var googleCode: String? {
        switch self {
        case .auto: return nil
        case .zhHans: return "zh-CN"
        case .zhHant: return "zh-TW"
        case .en: return "en"
        case .ja: return "ja"
        case .ko: return "ko"
        case .fr: return "fr"
        case .de: return "de"
        case .es: return "es"
        case .ru: return "ru"
        case .pt: return "pt"
        case .it: return "it"
        case .vi: return "vi"
        case .th: return "th"
        case .id: return "id"
        case .ar: return "ar"
        case .hi: return "hi"
        case .tr: return "tr"
        case .nl: return "nl"
        case .pl: return "pl"
        case .sv: return "sv"
        }
    }

    /// DeepL target_lang (nil for auto).
    var deepLCode: String? {
        switch self {
        case .auto: return nil
        case .zhHans, .zhHant: return "ZH"
        case .en: return "EN"
        case .ja: return "JA"
        case .ko: return "KO"
        case .fr: return "FR"
        case .de: return "DE"
        case .es: return "ES"
        case .ru: return "RU"
        case .pt: return "PT-PT"
        case .it: return "IT"
        case .vi: return "VI"
        case .th: return "TH"
        case .id: return "ID"
        case .ar: return "AR"
        case .hi: return nil  // DeepL may not support
        case .tr: return "TR"
        case .nl: return "NL"
        case .pl: return "PL"
        case .sv: return "SV"
        }
    }

    /// DeepL source_lang. Sources take no regional variant.
    var deepLSourceCode: String? {
        deepLCode.map { $0.hasPrefix("PT") ? "PT" : $0 }
    }

    /// Map macOS system preferred language → translation target. Used as default when unset.
    static func fromSystem() -> TargetLanguage {
        let prefs = Locale.preferredLanguages
        let ids = prefs.isEmpty ? [Locale.current.identifier] : prefs
        for raw in ids {
            let id = raw.replacingOccurrences(of: "_", with: "-").lowercased()
            if id.hasPrefix("zh-hant") || id.hasPrefix("zh-tw") || id.hasPrefix("zh-hk") || id.hasPrefix("zh-mo") {
                return .zhHant
            }
            if id.hasPrefix("zh") { return .zhHans }
            if id.hasPrefix("en") { return .en }
            if id.hasPrefix("ja") { return .ja }
            if id.hasPrefix("ko") { return .ko }
            if id.hasPrefix("fr") { return .fr }
            if id.hasPrefix("de") { return .de }
            if id.hasPrefix("es") { return .es }
            if id.hasPrefix("ru") { return .ru }
            if id.hasPrefix("pt") { return .pt }
            if id.hasPrefix("it") { return .it }
            if id.hasPrefix("vi") { return .vi }
            if id.hasPrefix("th") { return .th }
            if id.hasPrefix("id") || id.hasPrefix("in") { return .id }
            if id.hasPrefix("ar") { return .ar }
            if id.hasPrefix("hi") { return .hi }
            if id.hasPrefix("tr") { return .tr }
            if id.hasPrefix("nl") { return .nl }
            if id.hasPrefix("pl") { return .pl }
            if id.hasPrefix("sv") { return .sv }
        }
        return .en
    }

    /// Natural-language name for AI system prompts.
    var promptName: String {
        switch self {
        case .auto: return "the appropriate target language"
        case .zhHans: return L("Simplified Chinese (简体中文)")
        case .zhHant: return L("Traditional Chinese (繁體中文)")
        case .en: return "English"
        case .ja: return "Japanese"
        case .ko: return "Korean"
        case .fr: return "French"
        case .de: return "German"
        case .es: return "Spanish"
        case .ru: return "Russian"
        case .pt: return "Portuguese"
        case .it: return "Italian"
        case .vi: return "Vietnamese"
        case .th: return "Thai"
        case .id: return "Indonesian"
        case .ar: return "Arabic"
        case .hi: return "Hindi"
        case .tr: return "Turkish"
        case .nl: return "Dutch"
        case .pl: return "Polish"
        case .sv: return "Swedish"
        }
    }
}

enum Lang {
    struct Plan: Sendable {
        var src: String?
        var tgt: String
        var tgtGoogle: String
        var tgtDeepL: String
        var tgtName: String
        var directionLabel: String
        var isZhSource: Bool
        /// Source the user picked instead of detection. Services that detect on their own are told it too.
        var chosenSource: TargetLanguage? = nil
        /// Kept for older call sites that still read `.isZh`.
        var isZh: Bool { isZhSource }
    }

    static func isHan(_ v: UInt32) -> Bool {
        (0x4E00...0x9FFF).contains(v) || (0x3400...0x4DBF).contains(v) ||
        (0x20000...0x2A6DF).contains(v) || (0xF900...0xFAFF).contains(v)
    }

    /// 简体和繁体不算同一种语言。源语言判不出来时返回 false。
    static func sameLanguage(_ plan: Plan) -> Bool {
        guard let src = plan.src, !src.isEmpty, src != "auto" else { return false }
        return languageKey(src) == languageKey(plan.tgt)
    }

    static func languageKey(_ code: String) -> String {
        let s = code.lowercased().replacingOccurrences(of: "_", with: "-")
        if s.hasPrefix("zh-hant") || s.hasPrefix("zh-tw") || s.hasPrefix("zh-hk") || s.hasPrefix("zh-mo") || s == "cht" {
            return "zh-hant"
        }
        if s.hasPrefix("zh") || s == "chi" { return "zh-hans" }
        let head = s.split(separator: "-").first.map(String.init) ?? s
        return head
    }

    static func isMostlyChinese(_ s: String) -> Bool {
        var han = 0, words = 0, inWord = false
        for sc in s.unicodeScalars {
            if isHan(sc.value) { han += 1; inWord = false }
            else if CharacterSet.letters.contains(sc) { if !inWord { words += 1; inWord = true } }
            else { inWord = false }
        }
        guard han > 0 else { return false }
        return Double(han) / Double(han + words) >= 0.5
    }

    nonisolated(unsafe) static var detect: (String) -> (code: String?, isZh: Bool) = { text in
        let zh = isMostlyChinese(text)
        return (zh ? "zh-Hans" : nil, zh)
    }

    /// 浮层顶上给人看的方向：写语言名，不写代码。
    static func languageName(_ code: String?) -> String {
        guard let code, !code.isEmpty, code != "auto" else { return L("自动检测") }
        let lower = code.lowercased()
        if let hit = TargetLanguage.allCases.first(where: { $0.appleCode?.lowercased() == lower || $0.googleCode?.lowercased() == lower }) {
            return hit.shortTitle
        }
        if lower.hasPrefix("zh") { return lower.contains("hant") || lower.hasSuffix("tw") || lower.hasSuffix("hk") ? TargetLanguage.zhHant.shortTitle : TargetLanguage.zhHans.shortTitle }
        let base = String(lower.split(separator: "-").first ?? Substring(lower))
        return TargetLanguage.allCases.first { $0.appleCode == base }?.shortTitle ?? code
    }

    static func languagePair(_ source: String?, _ target: String) -> String {
        "\(languageName(source)) → \(languageName(target))"
    }

    static func detectSource(_ text: String) -> (code: String?, isZh: Bool) {
        detect(proseSample(text))
    }

    /// 代码不是语言。围栏和行内代码里的包名、命令是一串字母，
    /// 识别器会把它们当成波兰语、土耳其语。剥掉之后没有字母了，就还用原文。
    static func proseSample(_ text: String) -> String {
        var out = ""
        var i = text.startIndex
        while i < text.endIndex {
            if text[i...].hasPrefix("```") {
                let rest = text.index(i, offsetBy: 3)
                if let close = text[rest...].range(of: "```") {
                    i = close.upperBound
                    continue
                }
            }
            if text[i] == "`" {
                let rest = text.index(after: i)
                if let close = text[rest...].firstIndex(of: "`"), !text[rest..<close].contains("\n") {
                    i = text.index(after: close)
                    continue
                }
            }
            out.append(text[i])
            i = text.index(after: i)
        }
        guard out.contains(where: \.isLetter) else { return text }
        return out
    }

    /// `mutual` swaps between native language and `target`. Anything else, including a failed detection, goes to the native language. The two may be the same language.
    /// Passing `source` fixes the detected language and does not by itself turn mutual on. Captions and voice stay one-way into `target`.
    static func plan(
        _ text: String,
        target: TargetLanguage? = nil,
        source forcedSource: String? = nil,
        native: TargetLanguage? = nil,
        mutual: Bool = false
    ) -> Plan {
        let chosen = (target ?? AppConfig.shared.targetLanguage).resolvedDestination
        let home = (native ?? AppConfig.shared.nativeLanguage).resolvedDestination
        let det = detectSource(text)
        let srcCode: String? = {
            guard let forcedSource, !forcedSource.isEmpty else { return det.code }
            return forcedSource
        }()
        let isZh = forcedSource == nil ? det.isZh : (srcCode?.lowercased().hasPrefix("zh") == true)
        let destination = mutual ? pairDestination(source: srcCode, native: home, target: chosen) : chosen
        return makePlan(src: srcCode, destination: destination, isZhSource: isZh)
    }

    private static func pairDestination(source: String?, native: TargetLanguage, target: TargetLanguage) -> TargetLanguage {
        if native == target { return target }
        guard let source, !source.isEmpty, source != "auto" else { return native }
        if languageKey(source) == languageKey(of: native) { return target }
        if languageKey(source) == languageKey(of: target) { return native }
        return native
    }

    private static func languageKey(of language: TargetLanguage) -> String {
        languageKey(language.appleCode ?? language.rawValue)
    }

    private static func makePlan(src: String?, destination: TargetLanguage, isZhSource: Bool) -> Plan {
        let tgtApple = destination.appleCode ?? "en"
        let tgtGoogle = destination.googleCode ?? "en"
        let tgtDeepL = destination.deepLCode ?? ""
        return Plan(
            src: src,
            tgt: tgtApple,
            tgtGoogle: tgtGoogle,
            tgtDeepL: tgtDeepL,
            tgtName: destination.promptName,
            directionLabel: languagePair(src, tgtApple),
            isZhSource: isZhSource
        )
    }
}
