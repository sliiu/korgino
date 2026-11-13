import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

struct ProviderOutcome: Identifiable, Sendable {
    var id: String
    var name: String
    var text: String?
    var error: String?
    var loading: Bool
    var applePackMissing: Bool = false
}

struct MultiResult: Sendable {
    var direction: String
    var outcomes: [ProviderOutcome]
}

enum Translator {
    static func translateAll(
        _ text: String,
        targets: [TranslateTarget]? = nil,
        plan explicit: Lang.Plan? = nil,
        onUpdate: (@Sendable ([ProviderOutcome], String) async -> Void)? = nil
    ) async -> MultiResult {
        let plan = explicit ?? Lang.plan(text, mutual: true)
        let tgts = targets ?? AppConfig.shared.simultaneousTargets()
        if !tgts.isEmpty, tgts.allSatisfy({ returnsSource($0, plan: plan) }) {
            return MultiResult(direction: plan.directionLabel, outcomes: tgts.map {
                ProviderOutcome(id: $0.id, name: $0.displayName, text: text, error: nil, loading: false)
            })
        }
        let payload: String
        do {
            payload = try await confirming(text, targets: tgts)
        } catch is MaskDeclined {
            return MultiResult(direction: plan.directionLabel, outcomes: tgts.map {
                ProviderOutcome(id: $0.id, name: $0.displayName, text: nil, error: nil, loading: false)
            })
        } catch {
            return MultiResult(direction: plan.directionLabel, outcomes: tgts.map {
                ProviderOutcome(id: $0.id, name: $0.displayName, text: nil, error: error.localizedDescription, loading: false)
            })
        }
        var outcomes = tgts.map {
            ProviderOutcome(id: $0.id, name: $0.displayName, text: nil, error: nil, loading: true)
        }
        let onlyGoogleFree = tgts.count == 1 && tgts[0].id == ProviderID.googleFree.rawValue
        // 同一份原文的骨架对每个 target 都一样，html 与否只有两种。先算两个，任务里共用。
        let skeletonPlain = SourceSkeleton.prepare(payload, html: false)
        let skeletonHTML = SourceSkeleton.prepare(payload, html: true)
        await withTaskGroup(of: (Int, Result<String, Error>).self) { group in
            for (i, t) in tgts.enumerated() {
                let skeleton = sharedSkeleton(for: t, plain: skeletonPlain, html: skeletonHTML)
                group.addTask {
                    // Escape caller's actor (often MainActor) so network/CPU never freezes UI.
                    await Task.detached(priority: .userInitiated) {
                        do {
                            let s = try await translatePrepared(payload, target: t, plan: plan, prepared: skeleton)
                            return (i, .success(SecretCover.restore(s)))
                        } catch {
                            return (i, .failure(error))
                        }
                    }.value
                }
            }
            for await (i, res) in group {
                outcomes[i].loading = false
                switch res {
                case .success(let s): outcomes[i].text = s
                case .failure(let e):
                    outcomes[i].error = e.localizedDescription
                    if onlyGoogleFree {
                        outcomes[i].error = e.localizedDescription + " " + L("没开代理时可以在设置的「翻译服务」里启用 Apple 本地。")
                    }
                    if let te = e as? TErr { outcomes[i].applePackMissing = te.applePackMissing }
                    else if e.localizedDescription.contains("语言包") {
                        outcomes[i].applePackMissing = true
                    }
                }
                await onUpdate?(outcomes, plan.directionLabel)
            }
        }
        return MultiResult(direction: plan.directionLabel, outcomes: outcomes)
    }

    /// 这个 target 走哪份骨架。AI 走非 html（带自定义提示时根本不用骨架），内置按它自己要不要 HTML。
    private static func sharedSkeleton(
        for target: TranslateTarget,
        plain: SourceSkeleton.Prepared,
        html: SourceSkeleton.Prepared
    ) -> SourceSkeleton.Prepared {
        switch target {
        case .ai:
            return plain
        case .builtin:
            return target.protectsWithHTML ? html : plain
        }
    }

    static func translateOne(_ text: String, target: TranslateTarget,
                             plan: Lang.Plan? = nil) async throws -> String {
        let p = plan ?? Lang.plan(text, mutual: true)
        if returnsSource(target, plan: p) { return text }
        let payload = try await confirming(text, targets: [target])
        let out = try await translatePrepared(payload, target: target, plan: p)
        return SecretCover.restore(out)
    }

    /// 命中的话先问一句：发送遮盖版还是原文。没命中就直接用原文。
    static func confirming(_ text: String, targets: [TranslateTarget]) async throws -> String {
        try await MaskedSend.prepare(text, destination: MaskDestination.label(for: targets))
    }

    /// 快捷翻译。命中遮盖时不确认，占位符照发，结果回来再填回。遮盖自己出错时抛出，调用方不替换原文。
    static func translateQuiet(
        _ text: String,
        target: TranslateTarget,
        language: TargetLanguage? = nil,
        source: String? = nil,
        mutual: Bool = false
    ) async throws -> (text: String, direction: String) {
        let plan = Lang.plan(text, target: language, source: source, mutual: mutual)
        if returnsSource(target, plan: plan) {
            return (text, plan.directionLabel)
        }
        let payload = try await MaskedSend.prepare(text, destination: MaskDestination.label(for: [target]), confirm: false)
        let out = try await translatePrepared(payload, target: target, plan: plan)
        return (SecretCover.restore(out), plan.directionLabel)
    }

    /// 同语润色关着，且这条走默认提示时，译文就是原文，请求不发出去。
    private static func returnsSource(_ target: TranslateTarget, plan: Lang.Plan) -> Bool {
        guard Lang.sameLanguage(plan) else { return false }
        guard case .ai(let profile) = target else { return false }
        let custom = profile.systemPrompt.trimmingCharacters(in: .whitespacesAndNewlines)
        return custom.isEmpty && !AppConfig.shared.polishSameLanguage
    }

    struct LiveSend: Sendable {
        var text: String
        var maskRanges: [NSRange]
    }

    /// 实时字幕。同语时不发出去。命中隐私时不确认，占位符照发。
    static func translateLive(_ text: String, target: TranslateTarget, plan: Lang.Plan) async throws -> LiveSend {
        if Lang.sameLanguage(plan) {
            return LiveSend(text: text, maskRanges: [])
        }
        let covered = try SecretCover.cover(text)
        let out = try await translatePrepared(covered.text, target: target, plan: plan)
        return LiveSend(
            text: SecretCover.restore(out),
            maskRanges: covered.changed ? covered.ranges : []
        )
    }

    private static func translatePrepared(_ text: String, target: TranslateTarget,
                                          plan: Lang.Plan,
                                          prepared: SourceSkeleton.Prepared? = nil) async throws -> String {
        // 启动后头一个请求可能赶在密钥读回来之前。等一下，别拿着空密钥去报「未填」。
        await AppConfig.shared.awaitSecrets()
        if case .ai(let profile) = target {
            if returnsSource(target, plan: plan) { return text }
            let custom = profile.systemPrompt.trimmingCharacters(in: .whitespacesAndNewlines)
            if custom.isEmpty {
                let skeleton = prepared ?? SourceSkeleton.prepare(text, html: false)
                let raw = try await openai(skeleton.payload, profile: profile, plan: plan)
                return SourceSkeleton.finish(raw, prepared: skeleton)
            }
            return try await openai(text, profile: profile, plan: plan)
        }
        let skeleton = prepared ?? SourceSkeleton.prepare(text, html: target.protectsWithHTML)
        do {
            let raw = try await translateBuiltin(skeleton.payload, target: target, plan: plan, html: skeleton.html)
            return SourceSkeleton.finish(raw, prepared: skeleton)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            if Lang.sameLanguage(plan) { return text }
            throw error
        }
    }

    private static func translateBuiltin(_ text: String, target: TranslateTarget,
                                         plan: Lang.Plan, html: Bool) async throws -> String {
        let p = plan
        switch target {
        case .builtin(.googleFree):
            let (out, _) = try await googleFree(text, tl: p.tgtGoogle, sl: p.googleSource)
            return out
        case .builtin(.googleCloud):
            return try await googleCloud(text, target: p.tgtGoogle, source: p.chosenSource?.googleCode, key: AppConfig.shared.googleCloudKey, html: html)
        case .builtin(.deepl):
            guard !p.tgtDeepL.isEmpty else {
                throw TErr(String(format: L("DeepL 不支持目标语言 %@"), String(describing: p.tgt)))
            }
            return try await deepl(text, target: p.tgtDeepL, source: p.deepLSource, key: AppConfig.shared.deeplKey,
                                   free: AppConfig.shared.deeplUseFreeAPI, html: html)
        case .builtin(.apple):
            guard let src = p.src else { throw TErr(L("无法识别源语言")) }
            return try await apple(text, from: src, to: p.tgt)
        case .builtin(.microsoft):
            return try await microsoft(text, target: p.tgtGoogle, source: p.src, html: html)
        case .builtin(.baidu):
            return try await baidu(text, target: LangCode.baidu(p.tgtGoogle), source: LangCode.baidu(p.src ?? "auto"))
        case .builtin(.youdao):
            return try await youdao(text, target: LangCode.youdao(p.tgtGoogle), source: LangCode.youdao(p.src ?? "auto"))
        case .builtin(.caiyun):
            return try await caiyun(text, target: LangCode.caiyun(p.tgtGoogle), source: p.src)
        case .builtin(.mymemory):
            return try await mymemory(text, target: p.tgtGoogle, source: p.src)
        case .builtin(.libreTranslate):
            return try await libreTranslate(text, target: LangCode.libre(p.tgtGoogle), source: LangCode.libre(p.src ?? "auto"), html: html)
        case .builtin(.lingva):
            return try await lingva(text, target: LangCode.lingva(p.tgtGoogle), source: LangCode.lingva(p.src ?? "auto"))
        case .ai:
            throw TErr(L("内部错误"))
        }
    }

    // MARK: Google free (multi-endpoint; gtx often 429)
    static func googleFree(_ text: String, tl: String, sl: String = "auto") async throws -> (String, String?) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw TErr(L("文本为空")) }
        let body = text

        var errors: [String] = []
        // 1) Chrome dict endpoint — currently most reliable through CN proxies
        do {
            return try await googleFreeClients5(body, tl: tl, sl: sl)
        } catch {
            errors.append("clients5: \(error.localizedDescription)")
        }
        // 2) translate.google.com client=at
        do {
            return try await googleFreeSingle(
                host: "https://translate.google.com/translate_a/single",
                client: "at", text: body, tl: tl, sl: sl
            )
        } catch {
            errors.append("client=at: \(error.localizedDescription)")
        }
        // 3) Legacy gtx (often blocked / 429)
        do {
            return try await googleFreeSingle(
                host: "https://translate.googleapis.com/translate_a/single",
                client: "gtx", text: body, tl: tl, sl: sl
            )
        } catch {
            errors.append("gtx: \(error.localizedDescription)")
        }
        let hint = L("若在国内，请在偏好设置使用「跟随系统代理」或自定义 127.0.0.1:7890。")
        throw TErr(String(format: L("Google 免费翻译失败。%@ %@"), errors.joined(separator: " | "), hint))
    }

    private static func googleFreeClients5(_ text: String, tl: String, sl: String) async throws -> (String, String?) {
        var c = URLComponents(string: "https://clients5.google.com/translate_a/t")!
        c.queryItems = [
            .init(name: "client", value: "dict-chrome-ex"),
            .init(name: "sl", value: sl),
            .init(name: "tl", value: tl),
            .init(name: "q", value: text),
        ]
        encodePlus(&c)
        var req = URLRequest(url: c.url!)
        req.timeoutInterval = 20
        req.setValue(NetSession.chromeUA, forHTTPHeaderField: "User-Agent")
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        let (data, resp) = try await NetSession.data(for: req)
        try throwIfGoogleBlocked(data: data, resp: resp, label: "clients5")
        // Shape: [["你好世界","en"]] or [["你好","en"],["世界","en"]]
        guard let json = try JSONSerialization.jsonObject(with: data) as? [Any] else {
            throw TErr(L("clients5 JSON 无效"))
        }
        var out = ""
        var detected: String? = nil
        for row in json {
            if let a = row as? [Any] {
                if let s = a.first as? String { out += s }
                if detected == nil, a.count > 1, let lang = a[1] as? String { detected = lang }
            }
        }
        if out.isEmpty { throw TErr(L("clients5 结果为空")) }
        return (out, detected)
    }

    private static func googleFreeSingle(host: String, client: String, text: String, tl: String, sl: String) async throws -> (String, String?) {
        var c = URLComponents(string: host)!
        c.queryItems = [
            .init(name: "client", value: client),
            .init(name: "sl", value: sl),
            .init(name: "tl", value: tl),
            .init(name: "hl", value: "en"),
            .init(name: "dt", value: "t"),
            .init(name: "ie", value: "UTF-8"),
            .init(name: "oe", value: "UTF-8"),
            .init(name: "q", value: text),
        ]
        encodePlus(&c)
        var req = URLRequest(url: c.url!)
        req.timeoutInterval = 20
        req.setValue(NetSession.chromeUA, forHTTPHeaderField: "User-Agent")
        req.setValue("https://translate.google.com/", forHTTPHeaderField: "Referer")
        req.setValue("*/*", forHTTPHeaderField: "Accept")
        let (data, resp) = try await NetSession.data(for: req)
        try throwIfGoogleBlocked(data: data, resp: resp, label: client)
        guard let json = try JSONSerialization.jsonObject(with: data) as? [Any],
              let segs = json.first as? [Any] else {
            throw TErr(String(format: L("%@ 返回格式异常"), String(describing: client)))
        }
        var out = ""
        for seg in segs {
            if let a = seg as? [Any], let s = a.first as? String { out += s }
        }
        if out.isEmpty { throw TErr(String(format: L("%@ 结果为空"), String(describing: client))) }
        let detected = json.count > 2 ? json[2] as? String : nil
        return (out, detected)
    }

    private static func encodePlus(_ c: inout URLComponents) {
        c.percentEncodedQuery = c.percentEncodedQuery?.replacingOccurrences(of: "+", with: "%2B")
    }

    private static func throwIfGoogleBlocked(data: Data, resp: URLResponse, label: String) throws {
        let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
        let body = String(data: data, encoding: .utf8) ?? ""
        if code == 429 || body.contains("automated queries") || body.contains("unusual traffic") {
            throw TErr(String(format: L("%@ 被 Google 限流 (HTTP %@)。请换代理节点或稍后再试。"), String(describing: label), String(describing: code)))
        }
        if code == 403 {
            throw TErr(String(format: L("%@ 被拒绝 (HTTP 403)。请检查代理出口 IP。"), String(describing: label)))
        }
        if !(200...299).contains(code) {
            let snippet = body
                .replacingOccurrences(of: "\n", with: " ")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            throw TErr("\(label) HTTP \(code): \(snippet.prefix(160))")
        }
        if body.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("<") {
            throw TErr(String(format: L("%@ 返回了网页而非 JSON（可能被拦截）。"), String(describing: label)))
        }
    }

    // MARK: Google Cloud
    static func googleCloud(_ text: String, target: String, source: String? = nil, key: String, html: Bool = false) async throws -> String {
        let k = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !k.isEmpty else { throw TErr(L("未配置 Google Cloud API Key")) }
        var c = URLComponents(string: "https://translation.googleapis.com/language/translate/v2")!
        c.queryItems = [.init(name: "key", value: k)]
        var req = URLRequest(url: c.url!)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.timeoutInterval = 20
        var body: [String: Any] = ["q": text, "target": target, "format": html ? "html" : "text"]
        if let source { body["source"] = source }
        req.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, resp) = try await NetSession.data(for: req)
        let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
        guard code == 200,
              let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let dataObj = json["data"] as? [String: Any],
              let translations = dataObj["translations"] as? [[String: Any]],
              let first = translations.first,
              let out = first["translatedText"] as? String else {
            let msg = String(data: data, encoding: .utf8) ?? ""
            throw TErr(String(format: L("Google Cloud 失败 (%@): %@"), String(describing: code), String(describing: msg.prefix(200))))
        }
        return out
    }

    // MARK: DeepL
    static func deepl(_ text: String, target: String, source: String? = nil, key: String, free: Bool, html: Bool = false) async throws -> String {
        let k = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !k.isEmpty else { throw TErr(L("未配置 DeepL API Key")) }
        let host = free ? "https://api-free.deepl.com/v2/translate" : "https://api.deepl.com/v2/translate"
        var req = URLRequest(url: URL(string: host)!)
        req.httpMethod = "POST"
        req.setValue("DeepL-Auth-Key \(k)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.timeoutInterval = 20
        var body: [String: Any] = ["text": [text], "target_lang": target]
        if let source { body["source_lang"] = source }
        if html {
            body["tag_handling"] = "html"
            body["tag_handling_version"] = "v2"
        }
        req.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, resp) = try await NetSession.data(for: req)
        let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
        guard code == 200,
              let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let translations = json["translations"] as? [[String: Any]],
              let first = translations.first,
              let out = first["text"] as? String else {
            let msg = String(data: data, encoding: .utf8) ?? ""
            throw TErr(String(format: L("DeepL 失败 (%@): %@"), String(describing: code), String(describing: msg.prefix(200))))
        }
        return out
    }


    // MARK: - Language code helpers for extra engines
    enum LangCode {
        static func baidu(_ g: String) -> String {
            switch g.lowercased() {
            case "zh-cn", "zh-hans", "zh": return "zh"
            case "zh-tw", "zh-hant": return "cht"
            case "auto", "": return "auto"
            case "ja": return "jp"
            case "ko": return "kor"
            case "fr": return "fra"
            case "es": return "spa"
            case "ar": return "ara"
            default: return g.lowercased()
            }
        }
        static func youdao(_ g: String) -> String {
            switch g.lowercased() {
            case "zh-cn", "zh-hans", "zh": return "zh-CHS"
            case "zh-tw", "zh-hant": return "zh-CHT"
            case "auto", "": return "auto"
            default: return g.lowercased()
            }
        }
        static func caiyun(_ g: String) -> String {
            switch g.lowercased() {
            case "zh-cn", "zh-hans", "zh", "zh-tw", "zh-hant": return "zh"
            case "ja": return "ja"
            case "en": return "en"
            default: return "en"
            }
        }
        static func libre(_ g: String) -> String {
            switch g.lowercased() {
            case "zh-cn", "zh-hans", "zh", "zh-tw", "zh-hant": return "zh"
            case "auto", "": return "auto"
            default: return String(g.prefix(2)).lowercased()
            }
        }
        static func lingva(_ g: String) -> String {
            switch g.lowercased() {
            case "zh-cn", "zh-hans", "zh": return "zh"
            case "zh-tw", "zh-hant": return "zh_HANT"
            case "auto", "": return "auto"
            default: return g.lowercased()
            }
        }
    }

    // MARK: Microsoft / Azure Translator
    static func microsoft(_ text: String, target: String, source: String?, html: Bool = false) async throws -> String {
        let cfg = AppConfig.shared
        let key = cfg.microsoftKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { throw TErr(L("未配置 Microsoft Translator Key")) }
        var comps = URLComponents(string: "https://api.cognitive.microsofttranslator.com/translate")!
        var items: [URLQueryItem] = [
            .init(name: "api-version", value: "3.0"),
            .init(name: "to", value: target),
        ]
        if let source, !source.isEmpty, source != "auto" {
            items.append(.init(name: "from", value: source))
        }
        if html {
            items.append(.init(name: "textType", value: "html"))
        }
        comps.queryItems = items
        var req = URLRequest(url: comps.url!)
        req.httpMethod = "POST"
        req.setValue(key, forHTTPHeaderField: "Ocp-Apim-Subscription-Key")
        let region = cfg.microsoftRegion.trimmingCharacters(in: .whitespacesAndNewlines)
        if !region.isEmpty, region.lowercased() != "global" {
            req.setValue(region, forHTTPHeaderField: "Ocp-Apim-Subscription-Region")
        }
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.timeoutInterval = 20
        req.httpBody = try JSONSerialization.data(withJSONObject: [["Text": text]])
        let (data, resp) = try await NetSession.data(for: req)
        let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
        guard code == 200,
              let arr = try JSONSerialization.jsonObject(with: data) as? [[String: Any]],
              let first = arr.first,
              let translations = first["translations"] as? [[String: Any]],
              let t0 = translations.first,
              let out = t0["text"] as? String else {
            let msg = String(data: data, encoding: .utf8) ?? ""
            throw TErr(String(format: L("Microsoft 翻译失败 (%@): %@"), String(describing: code), String(describing: msg.prefix(200))))
        }
        return out
    }

    // MARK: Baidu
    static func baiduJSON(_ text: String, target: String, source: String) async throws -> [String: Any] {
        let cfg = AppConfig.shared
        let appid = cfg.baiduAppID.trimmingCharacters(in: .whitespacesAndNewlines)
        let secret = cfg.baiduSecret.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !appid.isEmpty, !secret.isEmpty else { throw TErr(L("未配置百度翻译 App ID / 密钥")) }
        let salt = String(Int.random(in: 10000...99999))
        let sign = md5Hex(appid + text + salt + secret)
        var comps = URLComponents(string: "https://fanyi-api.baidu.com/api/trans/vip/translate")!
        comps.queryItems = [
            .init(name: "q", value: text),
            .init(name: "from", value: source),
            .init(name: "to", value: target),
            .init(name: "appid", value: appid),
            .init(name: "salt", value: salt),
            .init(name: "sign", value: sign),
        ]
        var req = URLRequest(url: comps.url!)
        req.timeoutInterval = 20
        let (data, resp) = try await NetSession.data(for: req)
        let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
        guard code == 200,
              let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw TErr(String(format: L("百度翻译失败 (%@)"), String(describing: code)))
        }
        return json
    }

    static func baidu(_ text: String, target: String, source: String) async throws -> String {
        let json = try await baiduJSON(text, target: target, source: source)
        if let err = json["error_code"] as? String, err != "52000" {
            throw TErr(String(format: L("百度翻译错误 %@: %@"), err, json["error_msg"] as? String ?? ""))
        }
        guard let results = json["trans_result"] as? [[String: Any]] else {
            throw TErr(L("百度翻译无结果"))
        }
        let out = results.compactMap { $0["dst"] as? String }.joined(separator: "\n")
        guard !out.isEmpty else { throw TErr(L("百度翻译结果为空")) }
        return out
    }

    // MARK: Youdao (v3 sign)
    static func youdao(_ text: String, target: String, source: String) async throws -> String {
        let cfg = AppConfig.shared
        let appKey = cfg.youdaoAppKey.trimmingCharacters(in: .whitespacesAndNewlines)
        let secret = cfg.youdaoSecret.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !appKey.isEmpty, !secret.isEmpty else { throw TErr(L("未配置有道应用 ID / 密钥")) }
        let salt = UUID().uuidString
        let curtime = String(Int(Date().timeIntervalSince1970))
        let truncated: String = {
            let chars = Array(text)
            if chars.count <= 20 { return text }
            let head = String(chars.prefix(10))
            let tail = String(chars.suffix(10))
            return "\(head)\(chars.count)\(tail)"
        }()
        let sign = sha256Hex(appKey + truncated + salt + curtime + secret)
        var comps = URLComponents(string: "https://openapi.youdao.com/api")!
        comps.queryItems = [
            .init(name: "q", value: text),
            .init(name: "from", value: source),
            .init(name: "to", value: target),
            .init(name: "appKey", value: appKey),
            .init(name: "salt", value: salt),
            .init(name: "sign", value: sign),
            .init(name: "signType", value: "v3"),
            .init(name: "curtime", value: curtime),
        ]
        var req = URLRequest(url: comps.url!)
        req.timeoutInterval = 20
        let (data, resp) = try await NetSession.data(for: req)
        let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
        guard code == 200,
              let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw TErr(String(format: L("有道翻译失败 (%@)"), String(describing: code)))
        }
        let errCode = "\(json["errorCode"] ?? "")"
        guard errCode == "0", let arr = json["translation"] as? [String] else {
            throw TErr(String(format: L("有道翻译错误 %@"), String(describing: errCode)))
        }
        let out = arr.joined(separator: "\n")
        guard !out.isEmpty else { throw TErr(L("有道翻译结果为空")) }
        return out
    }

    // MARK: Caiyun
    static func caiyun(_ text: String, target: String, source: String?) async throws -> String {
        let token = AppConfig.shared.caiyunToken.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !token.isEmpty else { throw TErr(L("未配置彩云 Token")) }
        let src: String = {
            guard let source, !source.isEmpty, source != "auto" else { return "auto" }
            let s = source.lowercased()
            if s.hasPrefix("zh") { return "zh" }
            if s.hasPrefix("ja") { return "ja" }
            if s.hasPrefix("en") { return "en" }
            return "auto"
        }()
        let transType = "\(src)2\(target)"
        var req = URLRequest(url: URL(string: "https://api.interpreter.caiyunai.com/v1/translator")!)
        req.httpMethod = "POST"
        req.setValue("token \(token)", forHTTPHeaderField: "X-Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.timeoutInterval = 20
        let body: [String: Any] = [
            "source": [text],
            "trans_type": transType,
            "request_id": UUID().uuidString,
            "detect": true,
        ]
        req.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, resp) = try await NetSession.data(for: req)
        let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
        guard code == 200,
              let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let targetArr = json["target"] as? [String],
              let out = targetArr.first, !out.isEmpty else {
            let msg = String(data: data, encoding: .utf8) ?? ""
            throw TErr(String(format: L("彩云小译失败 (%@): %@"), String(describing: code), String(describing: msg.prefix(200))))
        }
        return out
    }

    static func youdaoDictJSON(_ text: String, langType: String, dicts: [String]) async throws -> [String: Any] {
        let cfg = AppConfig.shared
        let appKey = cfg.youdaoAppKey.trimmingCharacters(in: .whitespacesAndNewlines)
        let secret = cfg.youdaoSecret.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !appKey.isEmpty, !secret.isEmpty else { throw TErr(L("未配置有道应用 ID / 密钥")) }
        let salt = UUID().uuidString
        let curtime = String(Int(Date().timeIntervalSince1970))
        let truncated: String = {
            let chars = Array(text)
            if chars.count <= 20 { return text }
            let head = String(chars.prefix(10))
            let tail = String(chars.suffix(10))
            return "\(head)\(chars.count)\(tail)"
        }()
        let sign = sha256Hex(appKey + truncated + salt + curtime + secret)
        var items: [URLQueryItem] = [
            .init(name: "q", value: text),
            .init(name: "langType", value: langType),
            .init(name: "appKey", value: appKey),
            .init(name: "salt", value: salt),
            .init(name: "sign", value: sign),
            .init(name: "signType", value: "v3"),
            .init(name: "curtime", value: curtime),
            .init(name: "docType", value: "json"),
        ]
        for name in dicts where !name.isEmpty {
            items.append(.init(name: "dicts", value: name))
        }
        var comps = URLComponents(string: "https://openapi.youdao.com/v2/dict")!
        comps.queryItems = items
        var req = URLRequest(url: comps.url!)
        req.timeoutInterval = 15
        let (data, resp) = try await NetSession.data(for: req)
        let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
        guard code == 200,
              let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw TErr(String(format: L("词典查询失败 (%@)"), String(describing: code)))
        }
        let errCode = "\(json["errorCode"] ?? "")"
        guard errCode == "0" else { throw TErr(String(format: L("有道翻译错误 %@"), errCode)) }
        return json
    }

    static func caiyunDictJSON(_ text: String, transType: String) async throws -> [String: Any] {
        let token = AppConfig.shared.caiyunToken.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !token.isEmpty else { throw TErr(L("未配置彩云 Token")) }
        var req = URLRequest(url: URL(string: "https://api.interpreter.caiyunai.com/v1/dict")!)
        req.httpMethod = "POST"
        req.setValue("token \(token)", forHTTPHeaderField: "X-Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.timeoutInterval = 15
        req.httpBody = try JSONSerialization.data(withJSONObject: [
            "source": text,
            "trans_type": transType,
        ])
        let (data, resp) = try await NetSession.data(for: req)
        let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
        guard code == 200,
              let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw TErr(String(format: L("词典查询失败 (%@)"), String(describing: code)))
        }
        let rc = "\(json["rc"] ?? "0")"
        guard rc == "0" else { throw TErr(String(format: L("词典查询失败 (%@)"), rc)) }
        return json
    }

    // MARK: MyMemory (free)
    static func mymemory(_ text: String, target: String, source: String?) async throws -> String {
        let src = (source?.isEmpty == false && source != "auto") ? source! : "autodetect"
        let pair = "\(src)|\(target)"
        var comps = URLComponents(string: "https://api.mymemory.translated.net/get")!
        comps.queryItems = [
            .init(name: "q", value: String(text.prefix(500))),
            .init(name: "langpair", value: pair),
        ]
        var req = URLRequest(url: comps.url!)
        req.timeoutInterval = 20
        let (data, resp) = try await NetSession.data(for: req)
        let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
        guard code == 200,
              let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let responseData = json["responseData"] as? [String: Any],
              let out = responseData["translatedText"] as? String,
              !out.isEmpty else {
            let msg = String(data: data, encoding: .utf8) ?? ""
            throw TErr(String(format: L("MyMemory 失败 (%@): %@"), String(describing: code), String(describing: msg.prefix(200))))
        }
        // MyMemory sometimes returns "INVALID SOURCE LANGUAGE ..." as text
        if out.uppercased().contains("INVALID") { throw TErr("MyMemory: \(out)") }
        return out
    }

    // MARK: LibreTranslate
    static func libreTranslate(_ text: String, target: String, source: String, html: Bool = false) async throws -> String {
        var base = AppConfig.shared.libreTranslateURL.trimmingCharacters(in: .whitespacesAndNewlines)
        if base.hasSuffix("/") { base.removeLast() }
        guard let url = URL(string: base + "/translate") else { throw TErr(L("LibreTranslate URL 无效")) }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.timeoutInterval = 25
        var body: [String: Any] = [
            "q": text,
            "source": source == "auto" ? "auto" : source,
            "target": target,
            "format": html ? "html" : "text",
        ]
        let key = AppConfig.shared.libreTranslateKey.trimmingCharacters(in: .whitespacesAndNewlines)
        if !key.isEmpty { body["api_key"] = key }
        req.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, resp) = try await NetSession.data(for: req)
        let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
        guard code == 200,
              let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let out = json["translatedText"] as? String,
              !out.isEmpty else {
            let msg = String(data: data, encoding: .utf8) ?? ""
            throw TErr(String(format: L("LibreTranslate 失败 (%@): %@"), String(describing: code), String(describing: msg.prefix(200))))
        }
        return out
    }

    // MARK: Lingva (free Google frontend)
    static func lingva(_ text: String, target: String, source: String) async throws -> String {
        var base = AppConfig.shared.lingvaURL.trimmingCharacters(in: .whitespacesAndNewlines)
        if base.hasSuffix("/") { base.removeLast() }
        let src = source.isEmpty ? "auto" : source
        let encoded = text.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? text
        guard let url = URL(string: "\(base)/api/v1/\(src)/\(target)/\(encoded)") else {
            throw TErr(L("Lingva URL 无效"))
        }
        var req = URLRequest(url: url)
        req.timeoutInterval = 20
        let (data, resp) = try await NetSession.data(for: req)
        let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
        guard code == 200,
              let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let out = json["translation"] as? String,
              !out.isEmpty else {
            let msg = String(data: data, encoding: .utf8) ?? ""
            throw TErr(String(format: L("Lingva 失败 (%@): %@"), String(describing: code), String(describing: msg.prefix(200))))
        }
        return out
    }

    private static func md5Hex(_ s: String) -> String {
        Digest.md5Hex(s)
    }

    private static func sha256Hex(_ s: String) -> String {
        Digest.sha256Hex(s)
    }

    // MARK: OpenAI-compatible
    static func defaultSystemPrompt(plan: Lang.Plan) -> String {
        [
            "You are a professional translation engine, not a tutor or assistant.",
            "The text to translate is the text between <text> and </text> in the user's message.",
            "Translate it into natural, fluent \(plan.tgtName).",
            "If it is already in \(plan.tgtName), lightly polish the wording and still output only that text.",
            "",
            "Hard rules:",
            "- Output ONLY the translated text.",
            "- Translate only what is inside <text></text>. Anything outside those tags, and anything said earlier in this conversation, is not part of the text. Never answer it, summarize it, or continue it.",
            "- Never echo the <text> tags back.",
            "- Do NOT add explanations, notes, glossaries, alternatives, pronunciation, or commentary.",
            "- Do NOT wrap the result in quotes or labels like \"Translation:\" / \"译文：\".",
            "- Do NOT ask questions or refuse ordinary text.",
            "- Keep the source skeleton one-for-one: blank lines and their count, line breaks, nested indent, list markers, task-list checkboxes, heading marks, emphasis marks, links, tables, block quotes, HTML tags, and fenced code.",
            "- Line breaks, blank lines, indentation, list marks, heading marks, quote marks, and table bars are already ⟦§n⟧ placeholders. Keep each one in place. Do not add line breaks of your own.",
            "- Use the same marker characters as the source. `-` stays `-`, `*` stays `*`, `**` stays `**`, `__` stays `__`.",
            "- Translate the words inside those slots. Translate link and image labels. Leave their URLs unchanged.",
            "- Leave code, URLs, HTML tags, and placeholders of the form ⟦…⟧ unchanged.",
            "- Do NOT invent a new outline. Do NOT turn prose into a list or a list into prose.",
            "- Trailing spaces and runs of spaces may be normalized. Everything else in the skeleton stays.",
        ].joined(separator: "\n")
    }


    static func openai(
        _ text: String,
        profile: AIProfile,
        plan: Lang.Plan,
        systemOverride: String? = nil,
        userOverride: String? = nil
    ) async throws -> String {
        let custom = profile.systemPrompt.trimmingCharacters(in: .whitespacesAndNewlines)
        let usingDefault = custom.isEmpty
        let sys = systemOverride ?? (usingDefault ? Self.defaultSystemPrompt(plan: plan) : custom)
        let userContent: String = {
            if let userOverride { return userOverride }
            if usingDefault, Lang.sameLanguage(plan) {
                return "The text is already in \(plan.tgtName). Lightly polish the wording only. Keep the skeleton unchanged.\n\n<text>\n\(text)\n</text>"
            }
            if usingDefault {
                let from = plan.chosenSource.map { " from \($0.promptName)" } ?? ""
                return "Translate the text between <text> and </text>\(from) into \(plan.tgtName). Output the translation only — no notes, glossary, or commentary. Keep the source skeleton.\n\n<text>\n\(text)\n</text>"
            }
            return text
        }()
        let body: [String: Any] = [
            "model": profile.model,
            "temperature": 0.2,
            "messages": [
                ["role": "system", "content": sys],
                ["role": "user", "content": userContent],
            ],
        ]
        let content = try await postChat(profile: profile, body: body)
        guard userOverride == nil, usingDefault else { return content }
        return stripTextTags(content)
    }

    /// One page image straight to the model: no OCR round trip, so layout, tables and
    /// multi-column order survive. Builtin engines cannot do this and are not routed here.
    static func openaiPageImage(
        _ png: Data,
        profile: AIProfile,
        system: String,
        instruction: String
    ) async throws -> String {
        let body: [String: Any] = [
            "model": profile.model,
            "temperature": 0,
            "messages": [
                ["role": "system", "content": system],
                ["role": "user", "content": [
                    ["type": "text", "text": instruction],
                    ["type": "image_url", "image_url": [
                        "url": "data:image/png;base64,\(png.base64EncodedString())",
                        "detail": "high",
                    ]],
                ] as [[String: Any]]],
            ],
        ]
        let content = try await postChat(profile: profile, body: body, allowEmpty: true)
        return content
    }

    private static func postChat(profile: AIProfile, body: [String: Any], allowEmpty: Bool = false) async throws -> String {
        try await ChatClient.completion(
            profile: profile,
            body: body,
            timeout: 180,
            allowEmpty: allowEmpty,
            failFormat: L("%@ 失败 (%@): %@")
        )
    }

    /// Some models echo the `<text>` fence. Drop it, keep everything between.
    private static func stripTextTags(_ s: String) -> String {
        var out = s
        let trimmed = out.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("<text>") || trimmed.hasSuffix("</text>") else { return out }
        out = trimmed
        if out.hasPrefix("<text>") {
            out.removeFirst("<text>".count)
            if out.hasPrefix("\n") { out.removeFirst() }
        }
        if out.hasSuffix("</text>") {
            out.removeLast("</text>".count)
            if out.hasSuffix("\n") { out.removeLast() }
        }
        return out
    }

    /// 松开后整理口语。失败时调用方仍用原来的字。
    static func polishSpeech(_ text: String, profile: AIProfile, style: VoicePolishStyle, note: String) async throws -> String {
        let system = [
            "你整理口语转写。只输出整理后的文字，不要解释，不要加引号。",
            "去掉嗯、啊、呃、那个、就是、然后这类口头禅。",
            "把停顿收成完整的句子，补上必要的标点。",
            "不改变意思、人称和事实，不添加原文没有的内容。",
            style.instruction(note),
        ].joined(separator: "\n")
        let out = try await openai(text, profile: profile, plan: Lang.plan(text), systemOverride: system, userOverride: text)
        return out.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// 一场笔记。整场一次送出。命中遮盖时不确认，结果回来再填回。
    static func sessionNote(_ transcript: String, profile: AIProfile, languageName: String) async throws -> String {
        let payload = try await MaskedSend.prepare(transcript, destination: "AI", confirm: false)
        let system = [
            "你根据一场已经切好的字幕写会议纪要。正文用 \(languageName)。",
            "字幕每段第一行是 #编号，下面可能有一行说话人标记，再下面是原文，最后是译文。",
            "只输出下面五段，每段的小标题单独一行，原样写出，不要别的说明。没有内容的段只留小标题。",
            "## SAY 下面用几句到一段写出这场在说什么。不逐句翻译，不编造没说过的事。",
            "## TOPICS 下面每行一个议题，以「- 」开头，最多 8 行。",
            "## DECISIONS 下面每行一条已经说定的结论，以「- 」开头。还在讨论、没有定下来的不算。",
            "## TODOS 下面每行一条待办，以「- 」开头，写清谁做什么；字幕里说了期限才写期限。",
            "TOPICS、DECISIONS、TODOS 每行行尾用括号标出依据的字幕编号，例如 (#3, #12)。编号必须是上面出现过的。",
            "## TERMS 下面每行一个反复出现的词，格式是「原文词 | 译文里的一段」。竖线右边必须从字幕译文里原样抄一段，不能新译，不能改写。没有把握就不要这行。",
            "说话人标记照原样用，不要猜真名。",
        ].joined(separator: "\n")
        let sample = String(transcript.prefix(500))
        let out = try await openai(
            payload, profile: profile, plan: Lang.plan(sample), systemOverride: system, userOverride: payload
        )
        let restored = SecretCover.restore(out).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !restored.isEmpty else { throw TErr(L("笔记没有写成")) }
        return restored
    }

    /// Slices that join back to `text`. Cuts fall between blocks, never inside a fence.
    static func chunkText(_ text: String, maxChars: Int = 3000) -> [String] {
        SourceSkeleton.chunks(text, limit: maxChars)
    }

    static func translateFileText(_ text: String, profile: AIProfile,
                                  timed: TimedText.Kind? = nil,
                                  language: TargetLanguage? = nil,
                                  source: String? = nil,
                                  onProgress: @escaping (Int, Int) -> Void) async throws -> String {
        try await translateFileText(text, target: .ai(profile), timed: timed, language: language, source: source, onProgress: onProgress)
    }

    /// Chunk long file text and translate with any enabled provider (builtin or AI).
    /// `timed` keeps times and style, and translates only the spoken lines.
    /// `source` is the language the user picked for the whole file. Nil leaves detection on.
    static func translateFileText(_ text: String, target: TranslateTarget,
                                  timed: TimedText.Kind? = nil,
                                  language: TargetLanguage? = nil,
                                  source: String? = nil,
                                  onProgress: @escaping (Int, Int) -> Void) async throws -> String {
        if let timed, let script = TimedText.parse(text, kind: timed) {
            let plan = Lang.plan(script.dialogue.joined(separator: "\n"), target: language, source: source, mutual: true)
            if returnsSource(target, plan: plan) { return text }
            return try await translateCues(script, target: target, plan: plan, onProgress: onProgress)
        }
        let plan = Lang.plan(text, target: language, source: source, mutual: true)
        let chunks = chunkText(text)
        var outs: [String] = []
        for (i, chunk) in chunks.enumerated() {
            onProgress(i + 1, chunks.count)
            if chunk.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                outs.append(chunk)
                continue
            }
            let part = try await Task.detached(priority: .userInitiated) {
                try await translateOne(chunk, target: target, plan: plan)
            }.value
            outs.append(part)
        }
        return outs.joined()
    }

    private struct CueItem {
        var index: Int
        var payload: String
        var tokens: [String: String]
    }

    /// One spoken line that fails stays as written. None translated means the whole file fails.
    private static func translateCues(_ script: TimedText.Script, target: TranslateTarget,
                                      plan: Lang.Plan,
                                      onProgress: @escaping (Int, Int) -> Void) async throws -> String {
        var ready: [Int: String] = [:]
        var batch: [CueItem] = []
        for (index, line) in script.dialogue.enumerated() {
            let shielded = TimedText.shield(line)
            if shielded.payload.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                ready[index] = line
                continue
            }
            batch.append(CueItem(index: index, payload: shielded.payload, tokens: shielded.tokens))
        }
        let groups = cueGroups(batch, limit: 2500)
        if groups.isEmpty {
            onProgress(1, 1)
            return script.applying(ready)
        }
        var translated = 0
        var lastError: Error?
        for (gi, group) in groups.enumerated() {
            try Task.checkCancellation()
            onProgress(gi + 1, groups.count)
            let packed = group.enumerated().map { "⟦¶\($0.offset)⟧ \($0.element.payload)" }.joined(separator: "\n")
            do {
                let out = try await translateCueBatch(packed, target: target, plan: plan)
                guard let mapped = TimedText.unpack(out, count: group.count) else { continue }
                for (local, item) in group.enumerated() {
                    guard let piece = mapped[local],
                          !piece.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                          let restored = TimedText.restore(piece, tokens: item.tokens) else { continue }
                    ready[item.index] = restored
                    translated += 1
                }
            } catch let error as TErr where error.applePackMissing {
                throw error
            } catch is MaskDeclined {
                throw MaskDeclined()
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                lastError = error
            }
        }
        if translated == 0 { throw lastError ?? TErr(L("一句都没译成")) }
        return script.applying(ready)
    }

    private static func cueGroups(_ items: [CueItem], limit: Int) -> [[CueItem]] {
        var groups: [[CueItem]] = []
        var current: [CueItem] = []
        var size = 0
        for item in items {
            let cost = item.payload.count + 8
            if !current.isEmpty, size + cost > limit {
                groups.append(current)
                current = []
                size = 0
            }
            current.append(item)
            size += cost
        }
        if !current.isEmpty { groups.append(current) }
        return groups
    }

    /// Line breaks stay line breaks. HTML protection would wrap the batch and break the mapping.
    private static func translateCueBatch(_ text: String, target: TranslateTarget, plan: Lang.Plan) async throws -> String {
        if returnsSource(target, plan: plan) { return text }
        let payloadText = try await confirming(text, targets: [target])
        let prepared = SourceSkeleton.prepare(payloadText, html: false, layout: false)
        let raw: String
        if case .ai(let profile) = target {
            raw = try await openai(prepared.payload, profile: profile, plan: plan)
        } else {
            raw = try await translateBuiltin(prepared.payload, target: target, plan: plan, html: false)
        }
        return SecretCover.restore(SourceSkeleton.finish(raw, prepared: prepared))
    }
}
