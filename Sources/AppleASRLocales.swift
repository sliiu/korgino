import Speech

enum AppleASRLocales {
    static func install() {
        ASRLanguage.appleList = { catalog in
            var out: [ASRLanguage] = []
            var seen = Set<String>()
            for lang in catalog {
                if lang.id == "system" || SFSpeechRecognizer(locale: lang.locale) != nil {
                    out.append(lang)
                    seen.insert(lang.id.replacingOccurrences(of: "_", with: "-").lowercased())
                }
            }
            for loc in SFSpeechRecognizer.supportedLocales() {
                let nid = loc.identifier.replacingOccurrences(of: "_", with: "-")
                let key = nid.lowercased()
                if seen.contains(key) { continue }
                out.append(ASRLanguage(id: nid))
                seen.insert(key)
            }
            return out
        }
    }
}
