import Translation

extension Translator {
    static func apple(_ text: String, from s: String, to t: String) async throws -> String {
        let src = Locale.Language(identifier: s)
        let tgt = Locale.Language(identifier: t)
        let status = await LanguageAvailability().status(from: src, to: tgt)
        switch status {
        case .installed: break
        case .supported:
            await MainActor.run {
                AppleLangPack.presentDownloadPrompt(source: s, target: t)
            }
            throw TErr(String(format: L("Apple 语言包未下载（%@→%@）。已打开下载入口：系统设置 › 通用 › 语言与地区 › 翻译语言"), String(describing: s), String(describing: t)),
                       applePackMissing: true)
        case .unsupported: throw TErr(String(format: L("Apple 翻译不支持 %@→%@"), String(describing: s), String(describing: t)))
        @unknown default: throw TErr(L("Apple 翻译状态未知"))
        }
        if #available(macOS 26.0, *) {
            let session = TranslationSession(installedSource: src, target: tgt)
            return try await session.translate(text).targetText
        }
        // 15 没有现成的 session 构造器，只能借 SwiftUI 的 .translationTask 拿一个。
        return try await AppleTranslateHost.shared.translate(text, from: src, to: tgt)
    }
}
