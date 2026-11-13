import Foundation

extension Notification.Name {
    static let korgiLanguageDidChange = Notification.Name("Korgino.languageDidChange")
}

enum AppLanguage: String, CaseIterable, Identifiable, Hashable {
    case system
    case zhHans, zhHant, en, ja, ko, fr, de, es, ru, pt, it, vi, th, id, ar, hi, tr, nl, pl, sv
    var id: String { rawValue }

    var title: String {
        switch self {
        case .system: return L("跟随系统")
        default: return TargetLanguage(rawValue: rawValue)?.menuTitle ?? rawValue
        }
    }

    var code: String {
        switch self {
        case .system: return Self.systemCode
        default: return TargetLanguage(rawValue: rawValue)?.appleCode ?? "en"
        }
    }

    static var systemCode: String {
        let first: String
        if let global = UserDefaults.standard.persistentDomain(forName: UserDefaults.globalDomain),
           let langs = global["AppleLanguages"] as? [String],
           let lang = langs.first {
            first = lang
        } else {
            first = Locale.preferredLanguages.first ?? "en"
        }
        return resolve(first)
    }

    static func resolve(_ raw: String) -> String {
        let s = raw.lowercased()
        if s.hasPrefix("zh-hant") || s.hasPrefix("zh-tw") || s.hasPrefix("zh-hk") || s.hasPrefix("zh-mo") {
            return "zh-Hant"
        }
        if s.hasPrefix("zh") { return "zh-Hans" }
        let two = String(s.prefix(2))
        let known = ["en", "ja", "ko", "fr", "de", "es", "ru", "pt", "it", "vi", "th", "id", "ar", "hi", "tr", "nl", "pl", "sv"]
        return known.contains(two) ? two : "en"
    }
}

enum L10n {
    static var bundle: Bundle = .main
    static var sourceKeys = false

    static func use(_ language: AppLanguage) {
        let code = language.code
        if code == "zh-Hans" {
            bundle = .main
            sourceKeys = true
            return
        }
        sourceKeys = false
        // 还没译的语言（俄、葡、意、泰、印尼、阿）退到英文，不跟着系统落回中文。
        for candidate in [code, "en"] {
            if let path = Bundle.main.path(forResource: candidate, ofType: "lproj"),
               let localized = Bundle(path: path) {
                bundle = localized
                return
            }
        }
        bundle = .main
    }
}

func L(_ key: String) -> String {
    if L10n.sourceKeys { return key }
    return L10n.bundle.localizedString(forKey: key, value: key, table: nil)
}
