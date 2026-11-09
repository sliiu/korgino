import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// 一处 OpenAI 兼容的 `/chat/completions` 调用。
///
/// 翻译、对话、划词插件和视觉识别都发这一个形状的请求；以前各写一份，
/// 报错文案、超时和空内容的处理慢慢就不一样了。这里只做「发出去、取第一段回复」，
/// 遮盖（SecretCover）和确认框留在调用方，因为各自的确认文案不同。
enum ChatClient {
    /// 发请求并取回第一条回复。失败时按调用方给的 `failFormat` 拼报错（现成的词条，不另造 key）。
    /// 返回的是去掉首尾空白的原文，没有做解码后的还原。
    static func completion(
        profile: AIProfile,
        body: [String: Any],
        timeout: TimeInterval = 120,
        allowEmpty: Bool = false,
        failFormat: String
    ) async throws -> String {
        let key = AppConfig.shared.aiKey(for: profile).trimmingCharacters(in: .whitespacesAndNewlines)
        // Ollama / LM Studio 这类本地端点本来就不要 key。
        let noKey = AIPresetDef.find(profile.preset)?.noKey ?? false
        guard !key.isEmpty || noKey else {
            throw TErr(String(format: L("未配置 %@ 的 API Key"), String(describing: profile.name)))
        }
        var base = profile.baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        while base.hasSuffix("/") { base.removeLast() }
        guard !base.isEmpty, let url = URL(string: base + "/chat/completions") else {
            throw TErr(L("无效的 base URL"))
        }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        if !key.isEmpty { req.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization") }
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.timeoutInterval = timeout
        req.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, resp) = try await NetSession.data(for: req)
        let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
        guard code == 200,
              let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let choices = json["choices"] as? [[String: Any]],
              let message = choices.first?["message"] as? [String: Any],
              let content = message["content"] as? String else {
            let msg = String(data: data, encoding: .utf8) ?? ""
            throw TErr(String(format: failFormat,
                              String(describing: profile.name), String(describing: code),
                              String(describing: msg.prefix(240))))
        }
        let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
        // 直读时空白页是合法的：扫描件里夹一页纯图或空白，不该让整份失败。
        if trimmed.isEmpty, !allowEmpty {
            throw TErr(String(format: L("%@ 返回了空内容"), String(describing: profile.name)))
        }
        return trimmed
    }
}
