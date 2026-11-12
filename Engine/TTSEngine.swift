import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

enum TTSWire: String, Codable {
    case openai, elevenlabs, minimax, azure, google, dashscope, deepgram
}

struct TTSVoice: Identifiable, Equatable {
    var id: String
    var name: String

    init(_ id: String, _ name: String? = nil) {
        self.id = id
        self.name = name ?? id
    }
}

struct TTSPresetDef: Identifiable, Equatable {
    let id: String
    let name: String
    let wire: TTSWire
    let baseURL: String
    let model: String
    let voice: String
    let models: [String]
    let voices: [TTSVoice]
    let note: String
    let aiPreset: String
    let noKey: Bool

    var namedVoices: Bool { voices.contains { $0.name != $0.id } }

    static let all: [TTSPresetDef] = [
        TTSPresetDef(
            id: "openai", name: "OpenAI", wire: .openai,
            baseURL: "https://api.openai.com/v1", model: "gpt-4o-mini-tts", voice: "marin",
            models: ["gpt-4o-mini-tts", "tts-1-hd", "tts-1"],
            voices: ["marin", "cedar", "alloy", "ash", "ballad", "coral", "echo", "fable", "nova", "onyx", "sage", "shimmer", "verse"].map { TTSVoice($0) },
            note: "gpt-4o-mini-tts", aiPreset: "openai", noKey: false
        ),
        TTSPresetDef(
            id: "elevenlabs", name: "ElevenLabs", wire: .elevenlabs,
            baseURL: "https://api.elevenlabs.io", model: "eleven_multilingual_v2", voice: "21m00Tcm4TlvDq8ikWAM",
            models: ["eleven_multilingual_v2", "eleven_turbo_v2_5", "eleven_flash_v2_5", "eleven_v3"],
            voices: [
                TTSVoice("21m00Tcm4TlvDq8ikWAM", "Rachel"),
                TTSVoice("pNInz6obpgDQGcFmaJgB", "Adam"),
                TTSVoice("ErXwobaYiN019PkySvjV", "Antoni"),
                TTSVoice("MF3mGyEYCl7XYWbV9V6O", "Elli"),
                TTSVoice("TxGEqnHWrfWFTfGW9XjX", "Josh"),
                TTSVoice("XB0fDUnXU5powFXDhCwa", "Charlotte"),
                TTSVoice("XrExE9yKIg1WjnnlVkGX", "Matilda"),
                TTSVoice("JBFqnCBsd6RMkjVDRZzb", "George"),
                TTSVoice("pFZP5JQG7iQjIQuC4Bku", "Lily"),
                TTSVoice("nPczCjzI2devNBz1zQrb", "Brian"),
            ],
            note: L("多语言，音色填 voice id"), aiPreset: "", noKey: false
        ),
        TTSPresetDef(
            id: "azure", name: "Azure Speech", wire: .azure,
            baseURL: "eastasia", model: "", voice: "zh-CN-XiaoxiaoMultilingualNeural",
            models: [],
            voices: [
                "zh-CN-XiaoxiaoMultilingualNeural",
                "zh-CN-XiaoxiaoNeural",
                "zh-CN-YunxiNeural",
                "en-US-AvaMultilingualNeural",
                "en-US-AndrewMultilingualNeural",
                "ja-JP-NanamiNeural",
                "ko-KR-SunHiNeural",
            ].map { TTSVoice($0) },
            note: L("区域填 eastasia 这类"), aiPreset: "", noKey: false
        ),
        TTSPresetDef(
            id: "google", name: "Google Cloud", wire: .google,
            baseURL: "https://texttospeech.googleapis.com/v1/text:synthesize",
            model: "", voice: "zh-CN-Neural2-A",
            models: [],
            voices: [
                "zh-CN-Neural2-A", "zh-CN-Neural2-B", "zh-CN-Neural2-C", "zh-CN-Neural2-D",
                "en-US-Neural2-C", "en-US-Neural2-D", "en-US-Neural2-F",
                "ja-JP-Neural2-B", "ko-KR-Neural2-A",
            ].map { TTSVoice($0) },
            note: "Text-to-Speech", aiPreset: "", noKey: false
        ),
        TTSPresetDef(
            id: "minimax", name: "MiniMax", wire: .minimax,
            baseURL: "https://api.minimaxi.com/v1", model: "speech-2.8-hd",
            voice: "Chinese (Mandarin)_Lyrical_Voice",
            models: ["speech-2.8-hd", "speech-2.8-turbo", "speech-2.6-hd", "speech-2.6-turbo"],
            voices: [
                "Chinese (Mandarin)_Lyrical_Voice",
                "Chinese (Mandarin)_HK_Flight_Attendant",
                "English_Graceful_Lady",
                "English_Insightful_Speaker",
                "English_radiant_girl",
                "English_Persuasive_Man",
                "Japanese_Whisper_Belle",
            ].map { TTSVoice($0) },
            note: L("国际站把地址改成 https://api.minimax.io/v1"), aiPreset: "minimax", noKey: false
        ),
        TTSPresetDef(
            id: "qwen", name: L("通义千问"), wire: .dashscope,
            baseURL: "https://dashscope.aliyuncs.com/api/v1/services/aigc/multimodal-generation/generation",
            model: "qwen3-tts-flash", voice: "Cherry",
            models: ["qwen3-tts-flash"],
            voices: ["Cherry", "Serena", "Ethan", "Chelsie"].map { TTSVoice($0) },
            note: L("国内 DashScope，国际站可改地址"), aiPreset: "qwen", noKey: false
        ),
        TTSPresetDef(
            id: "siliconflow", name: "SiliconFlow", wire: .openai,
            baseURL: "https://api.siliconflow.cn/v1", model: "FunAudioLLM/CosyVoice2-0.5B", voice: "alex",
            models: ["FunAudioLLM/CosyVoice2-0.5B", "fishaudio/fish-speech-1.5"],
            voices: ["alex", "anna", "bella", "benjamin", "charles", "claire", "david", "diana"].map { TTSVoice($0) },
            note: "CosyVoice / Fish", aiPreset: "siliconflow", noKey: false
        ),
        TTSPresetDef(
            id: "groq", name: "Groq", wire: .openai,
            baseURL: "https://api.groq.com/openai/v1", model: "canopylabs/orpheus-v1-english", voice: "tara",
            models: ["canopylabs/orpheus-v1-english"],
            voices: ["tara", "leah", "jess", "leo", "dan", "mia", "zac", "zoe"].map { TTSVoice($0) },
            note: "Orpheus", aiPreset: "groq", noKey: false
        ),
        TTSPresetDef(
            id: "deepgram", name: "Deepgram", wire: .deepgram,
            baseURL: "https://api.deepgram.com", model: "aura-2-thalia-en", voice: "",
            models: [
                "aura-2-thalia-en", "aura-2-andromeda-en", "aura-2-helena-en",
                "aura-2-apollo-en", "aura-2-arcas-en", "aura-2-orion-en",
                "aura-2-luna-en", "aura-2-athena-en", "aura-2-zeus-en",
            ],
            voices: [],
            note: "Aura", aiPreset: "", noKey: false
        ),
        TTSPresetDef(
            id: "local", name: L("本地语音"), wire: .openai,
            baseURL: "http://127.0.0.1:8880/v1", model: "tts-1", voice: "alloy",
            models: ["tts-1"],
            voices: ["alloy"].map { TTSVoice($0) },
            note: L("本地 OpenAI 兼容接口，通常无需 Key"), aiPreset: "", noKey: true
        ),
        TTSPresetDef(
            id: "custom", name: L("自定义朗读"), wire: .openai,
            baseURL: "", model: "", voice: "",
            models: [],
            voices: [],
            note: L("OpenAI 兼容的 /audio/speech"), aiPreset: "", noKey: false
        ),
    ]

    static func find(_ id: String) -> TTSPresetDef? { all.first { $0.id == id } }
}

struct TTSProfile: Identifiable, Equatable, Codable {
    var id: String
    var name: String
    var baseURL: String
    var model: String
    var voice: String
    var enabled: Bool
    var preset: String
    var syncAI: Bool

    var keychainAccount: String { "tts.\(id)" }

    static func fromPreset(_ preset: TTSPresetDef, suffix: String? = nil) -> TTSProfile {
        TTSProfile(
            id: suffix.map { "\(preset.id)-\($0)" } ?? preset.id,
            name: preset.name,
            baseURL: preset.baseURL,
            model: preset.model,
            voice: preset.voice,
            enabled: true,
            preset: preset.id,
            syncAI: !preset.aiPreset.isEmpty
        )
    }
}

struct TTSRequest: Sendable {
    var preset: String
    var wire: TTSWire
    var baseURL: String
    var key: String
    var model: String
    var voice: String
}

enum TTSText {
    static func chunks(_ text: String, maxBytes: Int = 3500) -> [String] {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }
        if trimmed.utf8.count <= maxBytes { return [trimmed] }
        let breaks: Set<Character> = ["\n", "。", "！", "？", "!", "?", "."]
        var sentences: [String] = []
        var buf = ""
        for ch in trimmed {
            buf.append(ch)
            if breaks.contains(ch) {
                let piece = buf.trimmingCharacters(in: .whitespacesAndNewlines)
                if !piece.isEmpty { sentences.append(piece) }
                buf = ""
            }
        }
        let tail = buf.trimmingCharacters(in: .whitespacesAndNewlines)
        if !tail.isEmpty { sentences.append(tail) }
        var out: [String] = []
        var cur = ""
        func flush() {
            let t = cur.trimmingCharacters(in: .whitespacesAndNewlines)
            if !t.isEmpty { out.append(t) }
            cur = ""
        }
        for s in sentences {
            if s.utf8.count > maxBytes {
                flush()
                out.append(contentsOf: hard(s, maxBytes))
                continue
            }
            let joined = cur.isEmpty ? s : cur + " " + s
            if joined.utf8.count > maxBytes {
                flush()
                cur = s
            } else {
                cur = joined
            }
        }
        flush()
        return out
    }

    static func xml(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "'", with: "&apos;")
    }

    private static func hard(_ s: String, _ maxBytes: Int) -> [String] {
        var out: [String] = []
        var cur = ""
        for ch in s {
            let next = cur + String(ch)
            if next.utf8.count > maxBytes, !cur.isEmpty {
                out.append(cur)
                cur = String(ch)
            } else {
                cur = next
            }
        }
        if !cur.isEmpty { out.append(cur) }
        return out
    }
}

enum TTSLang {
    static func bcp47(_ code: String?) -> String? {
        guard var raw = code?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else { return nil }
        raw = raw.replacingOccurrences(of: "_", with: "-")
        let lower = raw.lowercased()
        if lower.hasPrefix("zh-hant") || lower.hasPrefix("zh-tw") || lower.hasPrefix("zh-hk") || lower.hasPrefix("zh-mo") {
            return "zh-TW"
        }
        if lower.hasPrefix("zh") { return lower.contains("-") && !lower.hasPrefix("zh-hans") ? raw : "zh-CN" }
        if raw.contains("-") { return raw }
        switch lower {
        case "en": return "en-US"
        case "ja": return "ja-JP"
        case "ko": return "ko-KR"
        case "fr": return "fr-FR"
        case "de": return "de-DE"
        case "es": return "es-ES"
        case "pt": return "pt-BR"
        case "ru": return "ru-RU"
        case "it": return "it-IT"
        case "vi": return "vi-VN"
        case "th": return "th-TH"
        case "id": return "id-ID"
        case "ar": return "ar-SA"
        case "hi": return "hi-IN"
        case "tr": return "tr-TR"
        case "nl": return "nl-NL"
        case "pl": return "pl-PL"
        case "sv": return "sv-SE"
        default: return raw
        }
    }

    static func localePrefix(_ voice: String) -> String? {
        let parts = voice.split(separator: "-")
        guard parts.count >= 2 else { return nil }
        let lang = parts[0]
        let region = parts[1]
        guard (2...3).contains(lang.count), region.count == 2, region.allSatisfy({ $0.isLetter }) else { return nil }
        return "\(lang)-\(region)"
    }

    static func same(_ a: String, _ b: String) -> Bool {
        let al = a.lowercased()
        let bl = b.lowercased()
        if al.hasPrefix("zh"), bl.hasPrefix("zh") {
            func trad(_ s: String) -> Bool { s.contains("hant") || s.contains("tw") || s.contains("hk") }
            return trad(al) == trad(bl)
        }
        return al.prefix(2) == bl.prefix(2)
    }

    static func xmlLang(voice: String, languageCode: String?) -> String {
        let fromVoice = localePrefix(voice)
        let asked = bcp47(languageCode)
        if voice.lowercased().contains("multilingual"), let asked { return asked }
        if let fromVoice { return fromVoice }
        return asked ?? "en-US"
    }

    static func qwen(_ code: String?) -> String {
        guard let b = bcp47(code)?.lowercased() else { return "Auto" }
        if b.hasPrefix("zh") { return "Chinese" }
        if b.hasPrefix("en") { return "English" }
        if b.hasPrefix("ja") { return "Japanese" }
        if b.hasPrefix("ko") { return "Korean" }
        if b.hasPrefix("fr") { return "French" }
        if b.hasPrefix("de") { return "German" }
        if b.hasPrefix("es") { return "Spanish" }
        if b.hasPrefix("pt") { return "Portuguese" }
        if b.hasPrefix("ru") { return "Russian" }
        if b.hasPrefix("it") { return "Italian" }
        return "Auto"
    }
}

enum TTSEngine {
    static func synthesize(text: String, request: TTSRequest, languageCode: String?) async throws -> Data {
        await AppConfig.shared.awaitSecrets()
        switch request.wire {
        case .openai: return try await openai(text, request)
        case .elevenlabs: return try await elevenlabs(text, request)
        case .minimax: return try await minimax(text, request)
        case .azure: return try await azure(text, request, languageCode: languageCode)
        case .google: return try await google(text, request, languageCode: languageCode)
        case .dashscope: return try await dashscope(text, request, languageCode: languageCode)
        case .deepgram: return try await deepgram(text, request)
        }
    }

    private static func openai(_ text: String, _ request: TTSRequest) async throws -> Data {
        guard let url = speechURL(request.baseURL, path: "/audio/speech") else {
            throw TErr(L("朗读接口地址无效"))
        }
        let model = try need(request.model, L("请先在设置里填写模型"))
        var voice = try need(request.voice, L("请先在设置里填写音色"))
        if request.preset == "siliconflow", !voice.contains(":") {
            voice = "\(model):\(voice)"
        }
        let format = request.preset == "groq" ? "wav" : "mp3"
        let (data, http) = try await postJSON(
            url,
            bearer: request.key,
            body: ["model": model, "input": text, "voice": voice, "response_format": format]
        )
        return try audioBytes(data, http)
    }

    private static func elevenlabs(_ text: String, _ request: TTSRequest) async throws -> Data {
        let voice = try need(request.voice, L("请先在设置里填写音色"))
        let encoded = voice.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? voice
        guard let url = rooted(request.baseURL, path: "/text-to-speech/\(encoded)") else {
            throw TErr(L("朗读接口地址无效"))
        }
        var body: [String: Any] = ["text": text]
        let model = request.model.trimmingCharacters(in: .whitespacesAndNewlines)
        if !model.isEmpty { body["model_id"] = model }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.timeoutInterval = 90
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("audio/mpeg", forHTTPHeaderField: "Accept")
        if !request.key.isEmpty { req.setValue(request.key, forHTTPHeaderField: "xi-api-key") }
        req.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, resp) = try await NetSession.data(for: req)
        guard let http = resp as? HTTPURLResponse else { throw TErr(L("朗读失败")) }
        return try audioBytes(data, http)
    }

    private static func minimax(_ text: String, _ request: TTSRequest) async throws -> Data {
        guard let url = speechURL(request.baseURL, path: "/t2a_v2") else {
            throw TErr(L("朗读接口地址无效"))
        }
        let model = try need(request.model, L("请先在设置里填写模型"))
        let voice = try need(request.voice, L("请先在设置里填写音色"))
        let body: [String: Any] = [
            "model": model,
            "text": text,
            "stream": false,
            "output_format": "hex",
            "voice_setting": ["voice_id": voice, "speed": 1, "vol": 1, "pitch": 0],
            "audio_setting": ["sample_rate": 32000, "bitrate": 128000, "format": "mp3"],
        ]
        let (data, http) = try await postJSON(url, bearer: request.key, body: body)
        if !(200...299).contains(http.statusCode) { throw error(data, http.statusCode) }
        guard let obj = JSONValue.object(data) else { throw TErr(L("朗读返回为空")) }
        if let base = obj["base_resp"] as? [String: Any], let code = base["status_code"] as? Int, code != 0 {
            let msg = (base["status_msg"] as? String) ?? String(code)
            throw TErr(String(format: L("朗读失败：%@"), msg))
        }
        guard let payload = obj["data"] as? [String: Any], let audio = payload["audio"] as? String else {
            throw TErr(L("朗读返回为空"))
        }
        return try await decodePayload(audio, hex: true)
    }

    private static func azure(_ text: String, _ request: TTSRequest, languageCode: String?) async throws -> Data {
        let voice = try need(request.voice, L("请先在设置里填写音色"))
        guard let url = azureURL(request.baseURL) else { throw TErr(L("朗读接口地址无效")) }
        let lang = TTSLang.xmlLang(voice: voice, languageCode: languageCode)
        let ssml = """
        <speak version='1.0' xmlns='http://www.w3.org/2001/10/synthesis' xml:lang='\(TTSText.xml(lang))'><voice name='\(TTSText.xml(voice))'>\(TTSText.xml(text))</voice></speak>
        """
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.timeoutInterval = 90
        req.setValue("application/ssml+xml", forHTTPHeaderField: "Content-Type")
        req.setValue("audio-24khz-48kbitrate-mono-mp3", forHTTPHeaderField: "X-Microsoft-OutputFormat")
        req.setValue("Korgino", forHTTPHeaderField: "User-Agent")
        if !request.key.isEmpty { req.setValue(request.key, forHTTPHeaderField: "Ocp-Apim-Subscription-Key") }
        req.httpBody = Data(ssml.utf8)
        let (data, resp) = try await NetSession.data(for: req)
        guard let http = resp as? HTTPURLResponse else { throw TErr(L("朗读失败")) }
        return try audioBytes(data, http)
    }

    private static func google(_ text: String, _ request: TTSRequest, languageCode: String?) async throws -> Data {
        let raw = request.baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        let endpoint = raw.isEmpty ? "https://texttospeech.googleapis.com/v1/text:synthesize" : raw
        guard var parts = URLComponents(string: endpoint) else { throw TErr(L("朗读接口地址无效")) }
        var items = parts.queryItems ?? []
        if !request.key.isEmpty { items.append(URLQueryItem(name: "key", value: request.key)) }
        parts.queryItems = items.isEmpty ? nil : items
        guard let url = parts.url else { throw TErr(L("朗读接口地址无效")) }
        let picked = googleVoice(request.voice, languageCode: languageCode)
        var voice: [String: Any] = ["languageCode": picked.language]
        if let name = picked.name { voice["name"] = name }
        let (data, http) = try await postJSON(
            url,
            bearer: nil,
            body: [
                "input": ["text": text],
                "voice": voice,
                "audioConfig": ["audioEncoding": "MP3"],
            ]
        )
        if !(200...299).contains(http.statusCode) { throw error(data, http.statusCode) }
        guard let obj = JSONValue.object(data), let b64 = obj["audioContent"] as? String else {
            throw error(data, http.statusCode)
        }
        return try await decodePayload(b64)
    }

    private static func dashscope(_ text: String, _ request: TTSRequest, languageCode: String?) async throws -> Data {
        let raw = request.baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: raw), !raw.isEmpty else { throw TErr(L("朗读接口地址无效")) }
        let model = try need(request.model, L("请先在设置里填写模型"))
        let voice = try need(request.voice, L("请先在设置里填写音色"))
        let (data, http) = try await postJSON(
            url,
            bearer: request.key,
            body: [
                "model": model,
                "input": [
                    "text": text,
                    "voice": voice,
                    "format": "mp3",
                    "language_type": TTSLang.qwen(languageCode),
                ],
            ]
        )
        if !(200...299).contains(http.statusCode) { throw error(data, http.statusCode) }
        let mime = http.mimeType?.lowercased() ?? ""
        if mime.contains("event-stream") || (String(data: data.prefix(5), encoding: .utf8) == "data:") {
            return try await dashscopeStream(data)
        }
        guard let obj = JSONValue.object(data) else { throw TErr(L("朗读返回为空")) }
        if let code = obj["code"] as? String, !code.isEmpty {
            let msg = (obj["message"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? code
            throw TErr(String(format: L("朗读失败：%@"), msg))
        }
        guard let output = obj["output"] as? [String: Any] else { throw TErr(L("朗读返回为空")) }
        if let audio = output["audio"] as? [String: Any] {
            if let urlString = audio["url"] as? String, !urlString.isEmpty { return try await decodePayload(urlString) }
            if let payload = audio["data"] as? String, !payload.isEmpty { return try await decodePayload(payload) }
        }
        if let audio = output["audio"] as? String, !audio.isEmpty { return try await decodePayload(audio) }
        throw TErr(L("朗读返回为空"))
    }

    private static func deepgram(_ text: String, _ request: TTSRequest) async throws -> Data {
        let model = try need(request.model, L("请先在设置里填写音色"))
        let root = request.baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        let base = root.isEmpty ? "https://api.deepgram.com" : root
        guard var parts = URLComponents(string: speakRoot(base)) else { throw TErr(L("朗读接口地址无效")) }
        var items = parts.queryItems ?? []
        items.append(URLQueryItem(name: "model", value: model))
        parts.queryItems = items
        guard let url = parts.url else { throw TErr(L("朗读接口地址无效")) }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.timeoutInterval = 90
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("audio/mpeg", forHTTPHeaderField: "Accept")
        if !request.key.isEmpty { req.setValue("Token \(request.key)", forHTTPHeaderField: "Authorization") }
        req.httpBody = try JSONSerialization.data(withJSONObject: ["text": text])
        let (data, resp) = try await NetSession.data(for: req)
        guard let http = resp as? HTTPURLResponse else { throw TErr(L("朗读失败")) }
        return try audioBytes(data, http)
    }

    private static func googleVoice(_ voice: String, languageCode: String?) -> (name: String?, language: String) {
        let name = voice.trimmingCharacters(in: .whitespacesAndNewlines)
        let fromVoice = TTSLang.localePrefix(name)
        let asked = TTSLang.bcp47(languageCode)
        if let asked, let fromVoice, !TTSLang.same(fromVoice, asked) {
            return (nil, asked)
        }
        return (name.isEmpty ? nil : name, fromVoice ?? asked ?? "en-US")
    }

    private static func dashscopeStream(_ data: Data) async throws -> Data {
        let text = String(data: data, encoding: .utf8) ?? ""
        var audio = Data()
        var url: String?
        for line in text.split(separator: "\n") {
            guard line.hasPrefix("data:") else { continue }
            let payload = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
            guard payload != "[DONE]",
                  let raw = payload.data(using: .utf8),
                  let obj = JSONValue.object(raw),
                  let output = obj["output"] as? [String: Any],
                  let au = output["audio"] as? [String: Any] else { continue }
            if let u = au["url"] as? String, !u.isEmpty { url = u }
            if let b64 = au["data"] as? String,
               let chunk = Data(base64Encoded: b64, options: .ignoreUnknownCharacters) {
                audio.append(chunk)
            }
        }
        if !audio.isEmpty { return audio }
        if let url { return try await decodePayload(url) }
        throw TErr(L("朗读返回为空"))
    }

    private static func need(_ value: String, _ message: String) throws -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { throw TErr(message) }
        return trimmed
    }

    private static func speechURL(_ base: String, path: String) -> URL? {
        var root = base.trimmingCharacters(in: .whitespacesAndNewlines)
        while root.hasSuffix("/") { root.removeLast() }
        if root.isEmpty { return nil }
        if root.hasSuffix(path) { return URL(string: root) }
        if root.hasSuffix("/v1") { return URL(string: root + path) }
        return URL(string: root + "/v1" + path)
    }

    private static func rooted(_ base: String, path: String) -> URL? {
        var root = base.trimmingCharacters(in: .whitespacesAndNewlines)
        while root.hasSuffix("/") { root.removeLast() }
        if root.isEmpty { return nil }
        if root.hasSuffix("/v1") { return URL(string: root + path) }
        return URL(string: root + "/v1" + path)
    }

    private static func speakRoot(_ base: String) -> String {
        var root = base.trimmingCharacters(in: .whitespacesAndNewlines)
        while root.hasSuffix("/") { root.removeLast() }
        if root.hasSuffix("/speak") { return root }
        if root.hasSuffix("/v1") { return root + "/speak" }
        return root + "/v1/speak"
    }

    private static func azureURL(_ base: String) -> URL? {
        let raw = base.trimmingCharacters(in: .whitespacesAndNewlines)
        if raw.contains("://") { return URL(string: raw) }
        let region = raw.isEmpty ? "eastasia" : raw
        return URL(string: "https://\(region).tts.speech.microsoft.com/cognitiveservices/v1")
    }

    private static func postJSON(_ url: URL, bearer: String?, body: [String: Any]) async throws -> (Data, HTTPURLResponse) {
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.timeoutInterval = 90
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let bearer, !bearer.isEmpty { req.setValue("Bearer \(bearer)", forHTTPHeaderField: "Authorization") }
        req.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, resp) = try await NetSession.data(for: req)
        guard let http = resp as? HTTPURLResponse else { throw TErr(L("朗读失败")) }
        return (data, http)
    }

    private static func audioBytes(_ data: Data, _ http: HTTPURLResponse) throws -> Data {
        guard (200...299).contains(http.statusCode) else { throw error(data, http.statusCode) }
        if data.isEmpty { throw TErr(L("朗读返回为空")) }
        if let obj = JSONValue.object(data), obj["error"] != nil || obj["detail"] != nil || obj["message"] != nil {
            throw error(data, http.statusCode)
        }
        return data
    }

    private static func decodePayload(_ raw: String, hex: Bool = false) async throws -> Data {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix("http://") || trimmed.hasPrefix("https://") {
            guard let url = URL(string: trimmed) else { throw TErr(L("朗读返回为空")) }
            var req = URLRequest(url: url)
            req.timeoutInterval = 90
            let (data, resp) = try await NetSession.data(for: req)
            let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
            guard (200...299).contains(code), !data.isEmpty else { throw TErr(L("朗读音频下载失败")) }
            return data
        }
        if hex {
            let cleaned = trimmed.filter { !$0.isWhitespace }
            if cleaned.count >= 2, cleaned.count % 2 == 0, let data = hexData(cleaned), !data.isEmpty {
                return data
            }
        }
        if let data = Data(base64Encoded: trimmed, options: .ignoreUnknownCharacters), data.count > 16 {
            return data
        }
        throw TErr(L("朗读返回为空"))
    }

    private static func hexData(_ s: String) -> Data? {
        var data = Data(capacity: s.count / 2)
        var i = s.startIndex
        while i < s.endIndex {
            let j = s.index(i, offsetBy: 2)
            guard let b = UInt8(s[i..<j], radix: 16) else { return nil }
            data.append(b)
            i = j
        }
        return data
    }

    private static func error(_ data: Data, _ code: Int) -> TErr {
        if let obj = JSONValue.object(data) {
            if let err = obj["error"] as? [String: Any] {
                let msg = (err["message"] as? String) ?? String(describing: err)
                return TErr(String(format: L("朗读失败：%@"), msg))
            }
            if let err = obj["error"] as? String, !err.isEmpty {
                return TErr(String(format: L("朗读失败：%@"), err))
            }
            if let detail = obj["detail"] as? [String: Any] {
                let msg = (detail["message"] as? String) ?? String(describing: detail)
                return TErr(String(format: L("朗读失败：%@"), msg))
            }
            if let detail = obj["detail"] as? String, !detail.isEmpty {
                return TErr(String(format: L("朗读失败：%@"), detail))
            }
            if let msg = obj["message"] as? String, !msg.isEmpty {
                return TErr(String(format: L("朗读失败：%@"), msg))
            }
        }
        let raw = String(data: data, encoding: .utf8) ?? ""
        if raw.isEmpty { return TErr(String(format: L("朗读失败（%@）"), String(code))) }
        return TErr(String(format: L("朗读失败（%@）：%@"), String(code), String(raw.prefix(160))))
    }
}

