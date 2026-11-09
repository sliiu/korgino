import NaturalLanguage

enum AppleLanguageDetect {
    static func install() {
        Lang.detect = { text in
            let zh = Lang.isMostlyChinese(text)
            let rec = NLLanguageRecognizer()
            rec.processString(text)
            let dom = rec.dominantLanguage?.rawValue
            if zh {
                return (hasTraditionalOnly(text) ? "zh-Hant" : "zh-Hans", true)
            }
            return (dom, false)
        }
    }

    /// 「你好」这类两种写法一样的字，NLLanguageRecognizer 常判成繁体；只有转成简体后字变了才算繁体。
    private static func hasTraditionalOnly(_ text: String) -> Bool {
        guard let simplified = text.applyingTransform(StringTransform("Hant-Hans"), reverse: false) else { return false }
        return simplified != text
    }
}
