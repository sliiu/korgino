import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

struct ASRChoice: Identifiable, Hashable {
    var id: String
    var name: String
}

struct ASRPresetDef: Identifiable, Equatable {
    let id: String
    let name: String
    let baseURL: String
    let model: String
    let models: [String]
    let note: String
    let aiPreset: String
    let noKey: Bool

    static let all: [ASRPresetDef] = [
        ASRPresetDef(
            id: "openai", name: "OpenAI Whisper",
            baseURL: "https://api.openai.com/v1", model: "whisper-1",
            models: ["whisper-1", "gpt-4o-mini-transcribe", "gpt-4o-transcribe"],
            note: "whisper-1 / gpt-4o-transcribe", aiPreset: "openai", noKey: false
        ),
        ASRPresetDef(
            id: "groq", name: "Groq Whisper",
            baseURL: "https://api.groq.com/openai/v1", model: "whisper-large-v3-turbo",
            models: ["whisper-large-v3-turbo", "whisper-large-v3", "distil-whisper-large-v3-en"],
            note: "whisper-large-v3", aiPreset: "groq", noKey: false
        ),
        ASRPresetDef(
            id: "siliconflow", name: "SiliconFlow",
            baseURL: "https://api.siliconflow.cn/v1", model: "FunAudioLLM/SenseVoiceSmall",
            models: ["FunAudioLLM/SenseVoiceSmall", "TeleAI/TeleSpeechASR"],
            note: L("中文语音转写"), aiPreset: "siliconflow", noKey: false
        ),
        ASRPresetDef(
            id: "fireworks", name: "Fireworks",
            baseURL: "https://api.fireworks.ai/inference/v1", model: "whisper-v3-turbo",
            models: ["whisper-v3-turbo", "whisper-v3"],
            note: "", aiPreset: "fireworks", noKey: false
        ),
        ASRPresetDef(
            id: "together", name: "Together",
            baseURL: "https://api.together.xyz/v1", model: "openai/whisper-large-v3",
            models: ["openai/whisper-large-v3"],
            note: "", aiPreset: "together", noKey: false
        ),
        ASRPresetDef(
            id: "deepinfra", name: "DeepInfra",
            baseURL: "https://api.deepinfra.com/v1/openai", model: "openai/whisper-large-v3",
            models: ["openai/whisper-large-v3", "openai/whisper-large-v3-turbo"],
            note: "", aiPreset: "deepinfra", noKey: false
        ),
        ASRPresetDef(
            id: "local", name: L("本地 Whisper"),
            baseURL: "http://127.0.0.1:8000/v1", model: "whisper-1",
            models: ["whisper-1", "Systran/faster-whisper-small", "Systran/faster-distil-whisper-large-v3"],
            note: L("本地 OpenAI 兼容接口，通常无需 Key"), aiPreset: "", noKey: true
        ),
        ASRPresetDef(
            id: "qwen-live", name: L("千问同传"),
            baseURL: "wss://dashscope.aliyuncs.com/api-ws/v1/realtime", model: "qwen3.8-livetranslate-flash-realtime",
            models: ["qwen3.8-livetranslate-flash-realtime", "qwen3.5-livetranslate-flash-realtime", "qwen3-livetranslate-flash-realtime"],
            note: L("同传：边听边出译文和译音"), aiPreset: "qwen", noKey: false
        ),
        ASRPresetDef(
            id: "openai-live", name: L("OpenAI 同传"),
            baseURL: "wss://api.openai.com/v1/realtime/translations", model: "gpt-realtime-translate",
            models: ["gpt-realtime-translate"],
            note: L("同传：边听边出译文和译音"), aiPreset: "openai", noKey: false
        ),
        ASRPresetDef(
            id: "custom", name: L("自定义语音识别"),
            baseURL: "", model: "",
            models: [],
            note: L("OpenAI 兼容的语音转写接口"), aiPreset: "", noKey: false
        ),
    ]

    static func find(_ id: String) -> ASRPresetDef? { all.first { $0.id == id } }

    /// 同传服务：识别和译文都从它来。
    var interpWire: InterpWire? {
        switch id {
        case "qwen-live": return .qwen
        case "openai-live": return .openai
        default: return nil
        }
    }
}

struct ASRProfile: Identifiable, Equatable, Codable {
    var id: String
    var name: String
    var baseURL: String
    var model: String
    var enabled: Bool
    var preset: String
    var syncAI: Bool
    /// 同传译音用的系统音色。空着用服务的默认。只对千问同传有意义。
    var voice: String = ""

    var keychainAccount: String { "asr.\(id)" }

    static func fromPreset(_ preset: ASRPresetDef, suffix: String? = nil) -> ASRProfile {
        ASRProfile(
            id: suffix.map { "\(preset.id)-\($0)" } ?? preset.id,
            name: preset.name,
            baseURL: preset.baseURL,
            model: preset.model,
            enabled: true,
            preset: preset.id,
            syncAI: !preset.aiPreset.isEmpty
        )
    }
}

/// 千问同传译音的系统音色。`voice` 是发给服务的值。名单见百炼「全模态音色列表」，默认 Tina。
enum QwenInterpVoice {
    static let fallback = "Cherry Tina"

    static let all: [(voice: String, name: String)] = [
        ("Cherry Tina", "甜甜"), ("Cindy", "林欣宜"), ("Liora Mira", "莉奥拉"), ("Sunnybobi", "晴天"),
        ("Raymond", "雷蒙"), ("Ethan", "晨煦"), ("Theo Calm", "西奥"), ("Serena", "苏瑶"),
        ("Harvey", "哈维"), ("Maia", "玛雅"), ("Evan", "江晨"), ("Qiao", "乔"),
        ("Momo", "茉兔"), ("Wil", "威尔"), ("Angel", "安洁"), ("Li Cassian", "卡西安"),
        ("Mia", "米娅"), ("Joyner", "乔伊纳"), ("Gold", "戈尔德"), ("Katerina", "卡特琳娜"),
        ("Ryan", "莱恩"), ("Jennifer", "詹妮弗"), ("Aiden", "艾登"), ("Mione", "米奥内"),
        ("Sohee", "苏熙"), ("Lenn", "伦恩"), ("Ono Anna", "小野安娜"), ("Sonrisa", "索尼莎"),
        ("Bodega", "博德加"), ("Emilien", "埃米利安"), ("Andre", "安德烈"), ("Radio Gol", "电台"),
        ("Alek", "阿列克"), ("Rizky", "里兹基"), ("Roya", "罗娅"), ("Arda", "阿尔达"),
        ("Hana", "花"), ("Dolce", "多尔切"), ("Jakub", "雅各布"), ("Griet", "格丽特"),
        ("Eliška", "伊利什卡"), ("Marina", "玛丽娜"), ("Siiri", "西丽"), ("Ingrid", "英格丽"),
        ("Sigga", "西加"), ("Bea", "贝娅"), ("Chloe", "克洛伊"),
    ]

    static func name(for voice: String) -> String {
        all.first { $0.voice == voice }?.name ?? voice
    }
}

struct ASRLanguage: Identifiable, Hashable {
    let id: String

    var title: String {
        if id == "system" { return L("跟随系统") }
        let code = AppConfig.shared.appLanguage == .system
            ? Locale.current.identifier
            : AppConfig.shared.appLanguage.code
        return Locale(identifier: code).localizedString(forIdentifier: id) ?? id
    }

    var locale: Locale {
        id == "system" ? Locale.current : Locale(identifier: id)
    }

    var whisperCode: String? {
        if id == "system" { return nil }
        let raw = id.replacingOccurrences(of: "_", with: "-").lowercased()
        if raw.hasPrefix("zh") { return "zh" }
        return String(raw.prefix(2))
    }

    /// Apple Translation source id. Nil when recognition follows the system language.
    var appleSource: String? {
        if id == "system" { return nil }
        let raw = id.replacingOccurrences(of: "_", with: "-").lowercased()
        if raw.hasPrefix("zh-hant") || raw.hasPrefix("zh-tw") || raw.hasPrefix("zh-hk") || raw.hasPrefix("zh-mo") || raw.hasPrefix("yue") {
            return "zh-Hant"
        }
        if raw.hasPrefix("zh") { return "zh-Hans" }
        return raw.split(separator: "-").first.map(String.init) ?? raw
    }

    static var catalog: [ASRLanguage] {
        [
            "system", "zh-CN", "zh-TW", "zh-HK",
            "en-US", "en-GB", "en-AU", "en-IN",
            "ja-JP", "ko-KR", "fr-FR", "de-DE", "es-ES", "es-MX",
            "pt-BR", "pt-PT", "it-IT", "ru-RU", "vi-VN", "th-TH",
            "id-ID", "ar-SA", "hi-IN", "tr-TR", "nl-NL", "pl-PL",
            "sv-SE", "da-DK", "fi-FI", "nb-NO", "cs-CZ", "uk-UA",
            "el-GR", "he-IL", "ro-RO", "hu-HU", "ca-ES", "ms-MY",
        ].map { ASRLanguage(id: $0) }
    }

    nonisolated(unsafe) static var appleList: (([ASRLanguage]) -> [ASRLanguage])?

    static func available(apple: Bool) -> [ASRLanguage] {
        let list = apple ? (appleList?(catalog) ?? catalog) : catalog
        let system = list.filter { $0.id == "system" }
        let rest = list.filter { $0.id != "system" }.sorted {
            $0.title.localizedStandardCompare($1.title) == .orderedAscending
        }
        return system + rest
    }
}

struct WhisperASRConfig: Sendable {
    var baseURL: String
    var key: String
    var model: String

    var transcriptionURL: URL? {
        let trimmed = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        if trimmed.isEmpty { return nil }
        if trimmed.hasSuffix("/audio/transcriptions") { return URL(string: trimmed) }
        if trimmed.hasSuffix("/v1") { return URL(string: trimmed + "/audio/transcriptions") }
        return URL(string: trimmed + "/v1/audio/transcriptions")
    }
}

enum WhisperASR {
    static func transcribe(wav: Data, config: WhisperASRConfig, language: String?, prompt: String? = nil) async throws -> String {
        do {
            return try await transcribeOnce(wav: wav, config: config, language: language, prompt: prompt)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            if Task.isCancelled { throw CancellationError() }
            guard let prompt, !prompt.isEmpty else { throw error }
            return try await transcribeOnce(wav: wav, config: config, language: language, prompt: nil)
        }
    }

    private static func transcribeOnce(wav: Data, config: WhisperASRConfig, language: String?, prompt: String?) async throws -> String {
        guard let url = config.transcriptionURL else {
            throw TErr(L("Whisper 接口地址无效"))
        }
        let boundary = "Boundary-\(UUID().uuidString)"
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.timeoutInterval = 45
        req.setValue("Bearer \(config.key)", forHTTPHeaderField: "Authorization")
        req.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")

        var body = Data()
        func field(_ name: String, _ value: String) {
            body.append(contentsOf: Data("--\(boundary)\r\n".utf8))
            body.append(contentsOf: Data("Content-Disposition: form-data; name=\"\(name)\"\r\n\r\n".utf8))
            body.append(contentsOf: Data("\(value)\r\n".utf8))
        }
        field("model", config.model)
        if let language, !language.isEmpty { field("language", language) }
        if let prompt, !prompt.isEmpty { field("prompt", prompt) }
        field("response_format", "json")
        body.append(contentsOf: Data("--\(boundary)\r\n".utf8))
        body.append(contentsOf: Data("Content-Disposition: form-data; name=\"file\"; filename=\"audio.wav\"\r\n".utf8))
        body.append(contentsOf: Data("Content-Type: audio/wav\r\n\r\n".utf8))
        body.append(wav)
        body.append(contentsOf: Data("\r\n--\(boundary)--\r\n".utf8))
        req.httpBody = body

        let (data, resp) = try await NetSession.data(for: req)
        let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
        if let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            if let text = obj["text"] as? String {
                let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
                if !t.isEmpty { return t }
            }
            if let err = obj["error"] as? [String: Any] {
                let msg = (err["message"] as? String) ?? String(describing: err)
                throw TErr(String(format: L("Whisper 失败：%@"), msg))
            }
        }
        if !(200...299).contains(code) {
            let raw = String(data: data, encoding: .utf8) ?? ""
            throw TErr(String(format: L("Whisper 失败（%@）：%@"), String(code), String(raw.prefix(160))))
        }
        throw TErr(L("Whisper 返回为空"))
    }

    /// Timed cues for one chunk. Times are relative to the start of `wav`.
    /// Falls back to a single cue spanning the chunk when the engine has no segment times.
    static func transcribeCues(
        wav: Data,
        config: WhisperASRConfig,
        language: String?,
        chunkDuration: TimeInterval,
        prompt: String? = nil
    ) async throws -> [(text: String, start: TimeInterval, end: TimeInterval)] {
        do {
            let cues = try await transcribeVerbose(wav: wav, config: config, language: language, prompt: prompt)
            if !cues.isEmpty { return cues }
        } catch {
            // Some transcribe models reject verbose_json. The plain text still covers the chunk.
        }
        let text = try await transcribe(wav: wav, config: config, language: language, prompt: prompt)
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }
        return [(trimmed, 0, max(chunkDuration, 0.2))]
    }

    private static func transcribeVerbose(
        wav: Data,
        config: WhisperASRConfig,
        language: String?,
        prompt: String?
    ) async throws -> [(text: String, start: TimeInterval, end: TimeInterval)] {
        do {
            return try await transcribeVerboseOnce(wav: wav, config: config, language: language, prompt: prompt)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            if Task.isCancelled { throw CancellationError() }
            guard let prompt, !prompt.isEmpty else { throw error }
            return try await transcribeVerboseOnce(wav: wav, config: config, language: language, prompt: nil)
        }
    }

    private static func transcribeVerboseOnce(
        wav: Data,
        config: WhisperASRConfig,
        language: String?,
        prompt: String?
    ) async throws -> [(text: String, start: TimeInterval, end: TimeInterval)] {
        guard let url = config.transcriptionURL else {
            throw TErr(L("Whisper 接口地址无效"))
        }
        let boundary = "Boundary-\(UUID().uuidString)"
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.timeoutInterval = 45
        req.setValue("Bearer \(config.key)", forHTTPHeaderField: "Authorization")
        req.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")

        var body = Data()
        func field(_ name: String, _ value: String) {
            body.append(contentsOf: Data("--\(boundary)\r\n".utf8))
            body.append(contentsOf: Data("Content-Disposition: form-data; name=\"\(name)\"\r\n\r\n".utf8))
            body.append(contentsOf: Data("\(value)\r\n".utf8))
        }
        field("model", config.model)
        if let language, !language.isEmpty { field("language", language) }
        if let prompt, !prompt.isEmpty { field("prompt", prompt) }
        field("response_format", "verbose_json")
        field("timestamp_granularities[]", "segment")
        body.append(contentsOf: Data("--\(boundary)\r\n".utf8))
        body.append(contentsOf: Data("Content-Disposition: form-data; name=\"file\"; filename=\"audio.wav\"\r\n".utf8))
        body.append(contentsOf: Data("Content-Type: audio/wav\r\n\r\n".utf8))
        body.append(wav)
        body.append(contentsOf: Data("\r\n--\(boundary)--\r\n".utf8))
        req.httpBody = body

        let (data, resp) = try await NetSession.data(for: req)
        let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
        guard (200...299).contains(code) else {
            let raw = String(data: data, encoding: .utf8) ?? ""
            throw TErr(String(format: L("Whisper 失败（%@）：%@"), String(code), String(raw.prefix(160))))
        }
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return [] }
        guard let segments = obj["segments"] as? [[String: Any]] else { return [] }
        return segments.compactMap { seg in
            let text = (seg["text"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            guard !text.isEmpty else { return nil }
            let start = seg["start"] as? Double ?? 0
            let end = seg["end"] as? Double ?? start
            return (text, start, max(end, start + 0.2))
        }
    }
}

enum PCM16WAV {
    static func data(samples: [Float], sampleRate: Int) -> Data {
        let n = samples.count
        var data = Data()
        func ascii(_ s: String) { data.append(contentsOf: s.utf8) }
        func u32(_ v: UInt32) {
            var le = v.littleEndian
            Swift.withUnsafeBytes(of: &le) { data.append(contentsOf: $0) }
        }
        func u16(_ v: UInt16) {
            var le = v.littleEndian
            Swift.withUnsafeBytes(of: &le) { data.append(contentsOf: $0) }
        }
        let dataSize = UInt32(n * 2)
        ascii("RIFF")
        u32(36 + dataSize)
        ascii("WAVE")
        ascii("fmt ")
        u32(16)
        u16(1)
        u16(1)
        u32(UInt32(sampleRate))
        u32(UInt32(sampleRate * 2))
        u16(2)
        u16(16)
        ascii("data")
        u32(dataSize)
        data.reserveCapacity(data.count + n * 2)
        for s in samples {
            let clipped = max(-1, min(1, s))
            var v = Int16((clipped * 32767).rounded()).littleEndian
            Swift.withUnsafeBytes(of: &v) { data.append(contentsOf: $0) }
        }
        return data
    }
}

