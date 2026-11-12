import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

enum OCRProviderID: String, CaseIterable, Codable, Identifiable {
    case appleVision
    case baidu
    case baiduAccurate
    case youdao
    case tencent
    case googleVision
    case azure
    case ocrSpace
    case aiVision

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .appleVision: return L("Apple Vision（本地）")
        case .baidu: return L("百度 OCR")
        case .baiduAccurate: return L("百度 OCR（高精度）")
        case .youdao: return L("有道 OCR")
        case .tencent: return L("腾讯云 OCR")
        case .googleVision: return "Google Cloud Vision"
        case .azure: return "Azure AI Vision"
        case .ocrSpace: return "OCR.space"
        case .aiVision: return L("AI 视觉模型")
        }
    }

    var systemImage: String {
        switch self {
        case .appleVision: return "apple.logo"
        case .baidu, .baiduAccurate: return "b.circle.fill"
        case .youdao: return "y.circle.fill"
        case .tencent: return "t.circle.fill"
        case .googleVision: return "globe"
        case .azure: return "m.circle.fill"
        case .ocrSpace: return "doc.text.viewfinder"
        case .aiVision: return "sparkles"
        }
    }
}

enum CloudOCR {
    // Token cache; races only cause an extra token request.
    private nonisolated(unsafe) static var baiduToken: (client: String, value: String, exp: Date)?

    static func recognizeText(png: Data, provider: OCRProviderID) async throws -> String {
        await AppConfig.shared.awaitSecrets()
        switch provider {
        case .appleVision:
            throw TErr(L("Apple Vision 只在 Mac 上可用"))
        case .baidu:
            return try await baiduOCR(png, endpoint: "general_basic")
        case .baiduAccurate:
            return try await baiduOCR(png, endpoint: "accurate_basic")
        case .youdao:
            return try await youdaoOCR(png)
        case .tencent:
            return try await tencentOCR(png)
        case .googleVision:
            return try await googleVisionOCR(png)
        case .azure:
            return try await azureOCR(png)
        case .ocrSpace:
            return try await ocrSpaceOCR(png)
        case .aiVision:
            return try await aiVisionOCR(png)
        }
    }

    private static func trimmed(_ s: String) -> String {
        s.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func hex(_ bytes: some Sequence<UInt8>) -> String {
        bytes.map { String(format: "%02x", $0) }.joined()
    }

    // MARK: Baidu

    private static func baiduAccessToken() async throws -> String {
        let creds = AppConfig.shared.ocrBaiduCredentials
        let id = trimmed(creds.id)
        let secret = trimmed(creds.secret)
        guard !id.isEmpty, !secret.isEmpty else {
            throw TErr(L("百度 OCR 需要填写 App ID 与密钥"))
        }
        if let t = baiduToken, t.client == id, t.exp > Date().addingTimeInterval(60) {
            return t.value
        }

        var comps = URLComponents(string: "https://aip.baidubce.com/oauth/2.0/token")!
        comps.queryItems = [
            .init(name: "grant_type", value: "client_credentials"),
            .init(name: "client_id", value: id),
            .init(name: "client_secret", value: secret),
        ]
        var req = URLRequest(url: comps.url!)
        req.timeoutInterval = 20
        let (data, _) = try await NetSession.data(for: req)
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        guard let token = json?["access_token"] as? String else {
            let err = json?["error_description"] as? String ?? json?["error"] as? String ?? L("未知错误")
            throw TErr(String(format: L("百度 OCR token：%@"), String(describing: err)))
        }
        let expires = (json?["expires_in"] as? Int) ?? 2592000
        baiduToken = (id, token, Date().addingTimeInterval(TimeInterval(expires)))
        return token
    }

    private static func baiduOCR(_ imageData: Data, endpoint: String) async throws -> String {
        let token = try await baiduAccessToken()
        let b64 = imageData.base64EncodedString()
            .addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? ""
        var req = URLRequest(url: URL(string: "https://aip.baidubce.com/rest/2.0/ocr/v1/\(endpoint)?access_token=\(token)")!)
        req.httpMethod = "POST"
        req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        req.httpBody = "image=\(b64)".data(using: .utf8)
        req.timeoutInterval = 30
        let (data, _) = try await NetSession.data(for: req)
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        if let err = json?["error_msg"] as? String {
            throw TErr(String(format: L("百度 OCR：%@"), String(describing: err)))
        }
        let words = (json?["words_result"] as? [[String: Any]]) ?? []
        let text = words.compactMap { $0["words"] as? String }.joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if text.isEmpty { throw TErr(L("百度 OCR 未识别到文字")) }
        return text
    }

    // MARK: Youdao

    private static func youdaoOCR(_ imageData: Data) async throws -> String {
        let creds = AppConfig.shared.ocrYoudaoCredentials
        let appKey = trimmed(creds.appKey)
        let secret = trimmed(creds.secret)
        guard !appKey.isEmpty, !secret.isEmpty else {
            throw TErr(L("有道 OCR 需要填写应用 ID 与密钥"))
        }
        let b64 = imageData.base64EncodedString()
        let salt = UUID().uuidString
        let curtime = String(Int(Date().timeIntervalSince1970))
        let truncated: String = {
            if b64.count <= 20 { return b64 }
            return "\(b64.prefix(10))\(b64.count)\(b64.suffix(10))"
        }()
        let signStr = appKey + truncated + salt + curtime + secret
        let sign = Digest.sha256Hex(signStr)

        let pairs: [(String, String)] = [
            ("img", b64),
            ("langType", "auto"),
            ("detectType", "10012"),
            ("imageType", "1"),
            ("appKey", appKey),
            ("salt", salt),
            ("sign", sign),
            ("docType", "json"),
            ("signType", "v3"),
            ("curtime", curtime),
        ]
        let body = pairs.map { key, val in
            let e = val.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? val
            return "\(key)=\(e)"
        }.joined(separator: "&")

        var req = URLRequest(url: URL(string: "https://openapi.youdao.com/ocrapi")!)
        req.httpMethod = "POST"
        req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        req.httpBody = body.data(using: .utf8)
        req.timeoutInterval = 30
        let (data, _) = try await NetSession.data(for: req)
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        let code = "\(json?["errorCode"] ?? "")"
        if code != "0" && !code.isEmpty {
            throw TErr(String(format: L("有道 OCR 错误码 %@"), String(describing: code)))
        }
        var lines: [String] = []
        if let result = json?["Result"] as? [String: Any],
           let regions = result["regions"] as? [[String: Any]] {
            for reg in regions {
                if let ls = reg["lines"] as? [[String: Any]] {
                    for ln in ls {
                        if let t = ln["text"] as? String { lines.append(t) }
                    }
                }
            }
        }
        let text = lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        if text.isEmpty { throw TErr(L("有道 OCR 未识别到文字")) }
        return text
    }

    // MARK: Tencent

    private static func tencentOCR(_ imageData: Data) async throws -> String {
        let cfg = AppConfig.shared
        let secretID = trimmed(cfg.tencentSecretID)
        let secretKey = trimmed(cfg.tencentSecretKey)
        guard !secretID.isEmpty, !secretKey.isEmpty else {
            throw TErr(L("腾讯云 OCR 需要填写 SecretId 与 SecretKey"))
        }
        let host = "ocr.tencentcloudapi.com"
        let service = "ocr"
        let contentType = "application/json; charset=utf-8"
        let payload = try JSONSerialization.data(withJSONObject: ["ImageBase64": imageData.base64EncodedString()])
        let timestamp = Int(Date().timeIntervalSince1970)
        let date = TimeText.utcDay.string(from: Date(timeIntervalSince1970: TimeInterval(timestamp)))

        let canonical = [
            "POST", "/", "",
            "content-type:\(contentType)\nhost:\(host)\n",
            "content-type;host",
            hex(Digest.sha256(payload)),
        ].joined(separator: "\n")
        let scope = "\(date)/\(service)/tc3_request"
        let stringToSign = [
            "TC3-HMAC-SHA256", String(timestamp), scope,
            hex(Digest.sha256(Data(canonical.utf8))),
        ].joined(separator: "\n")
        func hmac(_ key: [UInt8], _ msg: String) -> [UInt8] {
            Digest.hmacSHA256(Data(msg.utf8), key: key)
        }
        let kDate = hmac(Array("TC3\(secretKey)".utf8), date)
        let kSigning = hmac(hmac(kDate, service), "tc3_request")
        let signature = hex(Digest.hmacSHA256(Data(stringToSign.utf8), key: kSigning))

        var req = URLRequest(url: URL(string: "https://\(host)")!)
        req.httpMethod = "POST"
        req.setValue(contentType, forHTTPHeaderField: "Content-Type")
        req.setValue("GeneralBasicOCR", forHTTPHeaderField: "X-TC-Action")
        req.setValue("2018-11-19", forHTTPHeaderField: "X-TC-Version")
        req.setValue("ap-guangzhou", forHTTPHeaderField: "X-TC-Region")
        req.setValue(String(timestamp), forHTTPHeaderField: "X-TC-Timestamp")
        req.setValue(
            "TC3-HMAC-SHA256 Credential=\(secretID)/\(scope), SignedHeaders=content-type;host, Signature=\(signature)",
            forHTTPHeaderField: "Authorization"
        )
        req.httpBody = payload
        req.timeoutInterval = 30
        let (data, _) = try await NetSession.data(for: req)
        let resp = JSONValue.object(data)?["Response"] as? [String: Any]
        if let err = resp?["Error"] as? [String: Any] {
            throw TErr(String(format: L("腾讯云 OCR：%@"), err["Message"] as? String ?? L("未知错误")))
        }
        let items = (resp?["TextDetections"] as? [[String: Any]]) ?? []
        let text = trimmed(items.compactMap { $0["DetectedText"] as? String }.joined(separator: "\n"))
        if text.isEmpty { throw TErr(L("腾讯云 OCR 未识别到文字")) }
        return text
    }

    // MARK: Google Cloud Vision

    private static func googleVisionOCR(_ imageData: Data) async throws -> String {
        let key = trimmed(AppConfig.shared.ocrGoogleAPIKey)
        guard !key.isEmpty else { throw TErr(L("Google Cloud Vision 需要填写 Google Cloud API Key")) }
        var comps = URLComponents(string: "https://vision.googleapis.com/v1/images:annotate")!
        comps.queryItems = [.init(name: "key", value: key)]
        var req = URLRequest(url: comps.url!)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONSerialization.data(withJSONObject: [
            "requests": [[
                "image": ["content": imageData.base64EncodedString()],
                "features": [["type": "TEXT_DETECTION"]],
            ]],
        ])
        req.timeoutInterval = 30
        let (data, _) = try await NetSession.data(for: req)
        let json = JSONValue.object(data)
        if let err = json?["error"] as? [String: Any] {
            throw TErr(String(format: L("Google Vision：%@"), err["message"] as? String ?? L("未知错误")))
        }
        let first = (json?["responses"] as? [[String: Any]])?.first
        if let err = first?["error"] as? [String: Any] {
            throw TErr(String(format: L("Google Vision：%@"), err["message"] as? String ?? L("未知错误")))
        }
        let text = trimmed((first?["fullTextAnnotation"] as? [String: Any])?["text"] as? String ?? "")
        if text.isEmpty { throw TErr(L("Google Vision 未识别到文字")) }
        return text
    }

    // MARK: Azure AI Vision

    private static func azureOCR(_ imageData: Data) async throws -> String {
        let cfg = AppConfig.shared
        var endpoint = trimmed(cfg.azureVisionEndpoint)
        let key = trimmed(cfg.azureVisionKey)
        guard !endpoint.isEmpty, !key.isEmpty else {
            throw TErr(L("Azure AI Vision 需要填写终结点与密钥"))
        }
        while endpoint.hasSuffix("/") { endpoint.removeLast() }
        guard let url = URL(string: endpoint + "/computervision/imageanalysis:analyze?api-version=2024-02-01&features=read") else {
            throw TErr(L("Azure 终结点无效"))
        }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
        req.setValue(key, forHTTPHeaderField: "Ocp-Apim-Subscription-Key")
        req.httpBody = imageData
        req.timeoutInterval = 30
        let (data, _) = try await NetSession.data(for: req)
        let json = JSONValue.object(data)
        if let err = json?["error"] as? [String: Any] {
            throw TErr(String(format: L("Azure Vision：%@"), err["message"] as? String ?? L("未知错误")))
        }
        let blocks = ((json?["readResult"] as? [String: Any])?["blocks"] as? [[String: Any]]) ?? []
        let lines = blocks.flatMap { ($0["lines"] as? [[String: Any]]) ?? [] }
        let text = trimmed(lines.compactMap { $0["text"] as? String }.joined(separator: "\n"))
        if text.isEmpty { throw TErr(L("Azure Vision 未识别到文字")) }
        return text
    }

    // MARK: OCR.space

    private static func ocrSpaceOCR(_ imageData: Data) async throws -> String {
        let key = trimmed(AppConfig.shared.ocrSpaceKey)
        guard !key.isEmpty else { throw TErr(L("OCR.space 需要填写 API Key")) }
        let boundary = UUID().uuidString
        var body = Data()
        func field(_ name: String, _ value: String) {
            body.append(Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"\(name)\"\r\n\r\n\(value)\r\n".utf8))
        }
        field("language", "auto")
        field("OCREngine", "2")
        field("scale", "true")
        body.append(Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"file\"; filename=\"ocr.png\"\r\nContent-Type: image/png\r\n\r\n".utf8))
        body.append(imageData)
        body.append(Data("\r\n--\(boundary)--\r\n".utf8))

        var req = URLRequest(url: URL(string: "https://api.ocr.space/parse/image")!)
        req.httpMethod = "POST"
        req.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        req.setValue(key, forHTTPHeaderField: "apikey")
        req.httpBody = body
        req.timeoutInterval = 60
        let (data, _) = try await NetSession.data(for: req)
        let json = JSONValue.object(data)
        if json?["IsErroredOnProcessing"] as? Bool == true {
            let msg = (json?["ErrorMessage"] as? [String])?.joined(separator: "；")
                ?? json?["ErrorMessage"] as? String ?? L("未知错误")
            throw TErr("OCR.space：\(msg)")
        }
        let results = (json?["ParsedResults"] as? [[String: Any]]) ?? []
        let text = trimmed(results.compactMap { $0["ParsedText"] as? String }.joined(separator: "\n"))
        if text.isEmpty { throw TErr(L("OCR.space 未识别到文字")) }
        return text
    }

    // MARK: AI Vision

    private static func aiVisionOCR(_ imageData: Data) async throws -> String {
        let cfg = AppConfig.shared
        guard let profile = cfg.aiProfiles.first(where: { $0.id == cfg.ocrAIProfileID }) ?? cfg.aiProfiles.first else {
            throw TErr(L("AI 视觉模型需要先添加 AI 提供商"))
        }
        return try await aiVisionText(imageData, profile: profile)
    }

    static func aiVisionText(_ imageData: Data, profile: AIProfile) async throws -> String {
        let prompt = "Extract all text from this image exactly as it appears, preserving line breaks. Output only the text, no commentary or markdown fences."
        let body: [String: Any] = [
            "model": profile.model,
            "temperature": 0,
            "messages": [[
                "role": "user",
                "content": [
                    ["type": "text", "text": prompt],
                    ["type": "image_url", "image_url": ["url": "data:image/png;base64,\(imageData.base64EncodedString())"]],
                ],
            ]],
        ]
        let text = try await ChatClient.completion(
            profile: profile,
            body: body,
            timeout: 120,
            failFormat: L("%@ 视觉识别失败 (%@): %@")
        )
        if text.isEmpty { throw TErr(String(format: L("%@ 未识别到文字"), String(describing: profile.name))) }
        return text
    }
}
