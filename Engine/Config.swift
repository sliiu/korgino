#if canImport(Combine)
import Combine
#endif
import Foundation

enum AppearanceMode: String, CaseIterable, Identifiable, Codable {
    case system, light, dark
    var id: String { rawValue }
    var title: String {
        switch self {
        case .system: return L("跟随系统")
        case .light: return L("浅色")
        case .dark: return L("深色")
        }
    }
    var systemImage: String {
        switch self {
        case .light: return "sun.max.fill"
        case .system: return "circle.lefthalf.filled"
        case .dark: return "moon.fill"
        }
    }
}

enum ProxyMode: String, CaseIterable, Identifiable {
    case system, custom, off
    var id: String { rawValue }
    var label: String {
        switch self {
        case .system: return L("跟随系统代理")
        case .custom: return L("自定义代理")
        case .off: return L("不使用代理")
        }
    }
}

enum ProxyType: String, CaseIterable, Identifiable {
    case http, socks5
    var id: String { rawValue }
    var label: String {
        switch self {
        case .http: return "HTTP / HTTPS"
        case .socks5: return "SOCKS5"
        }
    }
}


enum ProviderID: String, CaseIterable, Codable, Identifiable {
    case apple, googleFree, googleCloud, deepl
    case microsoft, baidu, youdao, caiyun
    case mymemory, libreTranslate, lingva
    var id: String { rawValue }
    var displayName: String {
        switch self {
        case .googleFree: return L("Google (免费)")
        case .googleCloud: return "Google Cloud"
        case .deepl: return "DeepL"
        case .apple: return L("Apple 本地")
        case .microsoft: return "Microsoft / Bing"
        case .baidu: return L("百度翻译")
        case .youdao: return L("有道翻译")
        case .caiyun: return L("彩云小译")
        case .mymemory: return L("MyMemory (免费)")
        case .libreTranslate: return "LibreTranslate"
        case .lingva: return L("Lingva (免费)")
        }
    }
    var suitsLiveTranslation: Bool {
        switch self {
        case .apple, .googleCloud, .deepl, .microsoft, .baidu, .youdao, .caiyun, .libreTranslate:
            return true
        case .googleFree, .mymemory, .lingva:
            return false
        }
    }
    /// These engines can leave HTML tags alone and translate the text inside them.
    var protectsWithHTML: Bool {
        switch self {
        case .googleCloud, .deepl, .microsoft, .libreTranslate: return true
        default: return false
        }
    }
    var needsKey: Bool {
        switch self {
        case .googleFree, .apple, .mymemory, .lingva: return false
        case .libreTranslate: return false // optional key
        default: return true
        }
    }
}

/// Grouping for the Add-provider sheet.
enum AIPresetKind: String, Codable {
    case vendor, relay, local
    var sectionTitle: String {
        switch self {
        case .vendor: return L("厂商")
        case .relay: return L("聚合 / 中转")
        case .local: return L("本地")
        }
    }
}

struct AIProfile: Identifiable, Equatable {
    var id: String
    var name: String
    var baseURL: String
    var model: String
    var systemPrompt: String
    var enabled: Bool
    /// Preset id this was created from (empty for freeform custom).
    var preset: String

    static func makeDefault(name: String = L("自定义")) -> AIProfile {
        AIProfile(
            id: UUID().uuidString,
            name: name,
            baseURL: "",
            model: "",
            systemPrompt: "",
            enabled: false,
            preset: ""
        )
    }

    static func fromPreset(_ p: AIPresetDef, instanceSuffix: String? = nil) -> AIProfile {
        let id: String
        if let s = instanceSuffix {
            id = "\(p.id)-\(s)"
        } else {
            id = p.id
        }
        return AIProfile(
            id: id,
            name: p.name,
            baseURL: p.baseURL,
            model: p.model,
            systemPrompt: "",
            enabled: true,
            preset: p.id
        )
    }

    var keychainAccount: String { "ai.\(id)" }
}

extension AIProfile: Codable {
    enum CodingKeys: String, CodingKey {
        case id, name, baseURL, model, systemPrompt, enabled, preset
    }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? ""
        baseURL = try c.decodeIfPresent(String.self, forKey: .baseURL) ?? ""
        model = try c.decodeIfPresent(String.self, forKey: .model) ?? ""
        systemPrompt = try c.decodeIfPresent(String.self, forKey: .systemPrompt) ?? ""
        enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? false
        preset = try c.decodeIfPresent(String.self, forKey: .preset) ?? ""
    }
    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(name, forKey: .name)
        try c.encode(baseURL, forKey: .baseURL)
        try c.encode(model, forKey: .model)
        try c.encode(systemPrompt, forKey: .systemPrompt)
        try c.encode(enabled, forKey: .enabled)
        try c.encode(preset, forKey: .preset)
    }
}

extension AIProfile {
    /// 认模型名猜这个模型能不能看图。猜错不影响正确性：直读失败会说清楚，关掉开关就回到识图 OCR。
    /// 没有可靠的探测接口，ModelScope / 自建端点上报的模型名千奇百怪，所以宁可漏判也不错认成通用模型。
    var supportsVision: Bool {
        let m = model.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        guard !m.isEmpty else { return false }
        return Self.visionHints.contains { m.contains($0) }
    }

    private static let visionHints: [String] = [
        // 名字里直接写着能力
        "vision", "-vl", "vl-", "omni", "pixtral", "llava", "internvl", "minicpm-v", "qvq",
        // 各家默认带视觉的模型
        "gpt-4o", "gpt-4.1", "gpt-4-turbo", "gpt-5", "chatgpt-4o", "o3", "o4-mini",
        "claude", "gemini", "gemma-3", "gemma-4",
        "grok-2-vision", "grok-4",
        "glm-4v", "glm-4.1v", "glm-4.5v", "glm-4-5v",
        "qwen2-vl", "qwen2.5-vl", "qwen3-vl",
        "llama-3.2-vision", "llama-4", "mistral-small-3", "mistral-medium-3",
        "kimi-latest", "step-1o", "step-3", "yi-vision",
        "minimax-vl", "doubao-vision", "doubao-seed", "doubao-1.5-vision",
        "ernie-4.5-vl", "hunyuan-vision", "baichuan-vl",
    ]
}

struct AIPresetDef: Identifiable, Equatable {
    let id: String
    let name: String
    let kind: AIPresetKind
    let baseURL: String
    let model: String
    let note: String
    let keysURL: String
    let noKey: Bool

    static let all: [AIPresetDef] = [
        // Vendors — global
        AIPresetDef(id: "openai", name: "OpenAI", kind: .vendor,
                    baseURL: "https://api.openai.com/v1", model: "gpt-4o-mini",
                    note: "Chat Completions", keysURL: "https://platform.openai.com/api-keys", noKey: false),
        AIPresetDef(id: "gemini", name: "Google Gemini", kind: .vendor,
                    baseURL: "https://generativelanguage.googleapis.com/v1beta/openai", model: "gemini-2.0-flash",
                    note: L("官方 OpenAI 兼容端点"), keysURL: "https://aistudio.google.com/apikey", noKey: false),
        AIPresetDef(id: "mistral", name: "Mistral", kind: .vendor,
                    baseURL: "https://api.mistral.ai/v1", model: "mistral-small-latest",
                    note: "", keysURL: "https://console.mistral.ai/api-keys", noKey: false),
        AIPresetDef(id: "groq", name: "Groq", kind: .vendor,
                    baseURL: "https://api.groq.com/openai/v1", model: "llama-3.3-70b-versatile",
                    note: "", keysURL: "https://console.groq.com/keys", noKey: false),
        AIPresetDef(id: "xai", name: "xAI", kind: .vendor,
                    baseURL: "https://api.x.ai/v1", model: "grok-2-latest",
                    note: "", keysURL: "https://console.x.ai", noKey: false),
        AIPresetDef(id: "cerebras", name: "Cerebras", kind: .vendor,
                    baseURL: "https://api.cerebras.ai/v1", model: "llama-3.3-70b",
                    note: "", keysURL: "https://cloud.cerebras.ai", noKey: false),
        AIPresetDef(id: "sambanova", name: "SambaNova", kind: .vendor,
                    baseURL: "https://api.sambanova.ai/v1", model: "Meta-Llama-3.3-70B-Instruct",
                    note: "", keysURL: "https://cloud.sambanova.ai", noKey: false),
        AIPresetDef(id: "nvidia", name: "NVIDIA NIM", kind: .vendor,
                    baseURL: "https://integrate.api.nvidia.com/v1", model: "meta/llama-3.3-70b-instruct",
                    note: "", keysURL: "https://build.nvidia.com/settings/api-keys", noKey: false),
        AIPresetDef(id: "perplexity", name: "Perplexity", kind: .vendor,
                    baseURL: "https://api.perplexity.ai", model: "sonar",
                    note: "Chat Completions", keysURL: "https://www.perplexity.ai/settings/api", noKey: false),
        AIPresetDef(id: "cohere", name: "Cohere", kind: .vendor,
                    baseURL: "https://api.cohere.com/compatibility/v1", model: "command-r-plus",
                    note: L("OpenAI 兼容层"), keysURL: "https://dashboard.cohere.com/api-keys", noKey: false),

        // Vendors — China
        AIPresetDef(id: "deepseek", name: "DeepSeek", kind: .vendor,
                    baseURL: "https://api.deepseek.com", model: "deepseek-chat",
                    note: "", keysURL: "https://platform.deepseek.com/api_keys", noKey: false),
        AIPresetDef(id: "moonshot", name: "Kimi / Moonshot", kind: .vendor,
                    baseURL: "https://api.moonshot.cn/v1", model: "moonshot-v1-8k",
                    note: "China endpoint", keysURL: "https://platform.moonshot.cn/console/api-keys", noKey: false),
        AIPresetDef(id: "moonshot-intl", name: "Kimi (International)", kind: .vendor,
                    baseURL: "https://api.moonshot.ai/v1", model: "moonshot-v1-8k",
                    note: "Global endpoint", keysURL: "https://platform.moonshot.ai/console/api-keys", noKey: false),
        AIPresetDef(id: "zhipu", name: L("智谱 GLM"), kind: .vendor,
                    baseURL: "https://open.bigmodel.cn/api/paas/v4", model: "glm-4-flash",
                    note: "", keysURL: "https://open.bigmodel.cn/usercenter/proj-mgmt/apikeys", noKey: false),
        AIPresetDef(id: "qwen", name: L("通义千问"), kind: .vendor,
                    baseURL: "https://dashscope.aliyuncs.com/compatible-mode/v1", model: "qwen-turbo",
                    note: "DashScope China", keysURL: "https://bailian.console.aliyun.com/?tab=model#/api-key", noKey: false),
        AIPresetDef(id: "qwen-intl", name: L("通义千问 (国际)"), kind: .vendor,
                    baseURL: "https://dashscope-intl.aliyuncs.com/compatible-mode/v1", model: "qwen-turbo",
                    note: "DashScope International", keysURL: "https://modelstudio.console.alibabacloud.com/", noKey: false),
        AIPresetDef(id: "doubao", name: L("豆包 / 火山方舟"), kind: .vendor,
                    baseURL: "https://ark.cn-beijing.volces.com/api/v3", model: "doubao-pro-32k",
                    note: L("model 填方舟接入点 ID"), keysURL: "https://console.volcengine.com/ark/region:ark+cn-beijing/apiKey", noKey: false),
        AIPresetDef(id: "hunyuan", name: L("腾讯混元"), kind: .vendor,
                    baseURL: "https://api.hunyuan.cloud.tencent.com/v1", model: "hunyuan-turbo",
                    note: "", keysURL: "https://console.cloud.tencent.com/hunyuan/start", noKey: false),
        AIPresetDef(id: "qianfan", name: L("百度千帆"), kind: .vendor,
                    baseURL: "https://qianfan.baidubce.com/v2", model: "ernie-4.0-turbo-8k",
                    note: L("OpenAI 兼容 v2"), keysURL: "https://console.bce.baidu.com/qianfan/ais/console/apiKey", noKey: false),
        AIPresetDef(id: "baichuan", name: L("百川"), kind: .vendor,
                    baseURL: "https://api.baichuan-ai.com/v1", model: "Baichuan4",
                    note: "", keysURL: "https://platform.baichuan-ai.com/console/apikey", noKey: false),
        AIPresetDef(id: "yi", name: L("零一万物 Yi"), kind: .vendor,
                    baseURL: "https://api.lingyiwanwu.com/v1", model: "yi-lightning",
                    note: "", keysURL: "https://platform.lingyiwanwu.com/apikeys", noKey: false),
        AIPresetDef(id: "stepfun", name: L("阶跃星辰"), kind: .vendor,
                    baseURL: "https://api.stepfun.com/v1", model: "step-2-mini",
                    note: "", keysURL: "https://platform.stepfun.com/interface-key", noKey: false),
        AIPresetDef(id: "minimax", name: "MiniMax", kind: .vendor,
                    baseURL: "https://api.minimaxi.com/v1", model: "MiniMax-Text-01",
                    note: "China", keysURL: "https://platform.minimaxi.com/user-center/basic-information/interface-key", noKey: false),
        AIPresetDef(id: "modelscope", name: L("ModelScope 魔搭"), kind: .vendor,
                    baseURL: "https://api-inference.modelscope.cn/v1", model: "Qwen/Qwen2.5-7B-Instruct",
                    note: L("OpenAI 兼容推理"), keysURL: "https://modelscope.cn/my/myaccesstoken", noKey: false),

        // Relays / aggregators
        AIPresetDef(id: "openrouter", name: "OpenRouter", kind: .relay,
                    baseURL: "https://openrouter.ai/api/v1", model: "openai/gpt-4o-mini",
                    note: "", keysURL: "https://openrouter.ai/keys", noKey: false),
        AIPresetDef(id: "siliconflow", name: "SiliconFlow", kind: .relay,
                    baseURL: "https://api.siliconflow.cn/v1", model: "deepseek-ai/DeepSeek-V3",
                    note: "China", keysURL: "https://cloud.siliconflow.cn/account/ak", noKey: false),
        AIPresetDef(id: "together", name: "Together AI", kind: .relay,
                    baseURL: "https://api.together.xyz/v1", model: "meta-llama/Meta-Llama-3.1-70B-Instruct-Turbo",
                    note: "", keysURL: "https://api.together.xyz/settings/api-keys", noKey: false),
        AIPresetDef(id: "fireworks", name: "Fireworks", kind: .relay,
                    baseURL: "https://api.fireworks.ai/inference/v1", model: "accounts/fireworks/models/llama-v3p3-70b-instruct",
                    note: "", keysURL: "https://fireworks.ai/account/api-keys", noKey: false),
        AIPresetDef(id: "deepinfra", name: "DeepInfra", kind: .relay,
                    baseURL: "https://api.deepinfra.com/v1/openai", model: "meta-llama/Meta-Llama-3.1-70B-Instruct",
                    note: "", keysURL: "https://deepinfra.com/dash/api_keys", noKey: false),
        AIPresetDef(id: "novita", name: "Novita AI", kind: .relay,
                    baseURL: "https://api.novita.ai/v3/openai", model: "meta-llama/llama-3.1-70b-instruct",
                    note: "", keysURL: "https://novita.ai/settings", noKey: false),
        AIPresetDef(id: "github-models", name: "GitHub Models", kind: .relay,
                    baseURL: "https://models.inference.ai.azure.com", model: "gpt-4o-mini",
                    note: L("需 GitHub PAT"), keysURL: "https://github.com/settings/tokens", noKey: false),
        AIPresetDef(id: "azure-openai", name: "Azure OpenAI", kind: .relay,
                    baseURL: "", model: "gpt-4o-mini",
                    note: L("自行填写 https://{resource}.openai.azure.com/openai/deployments/{deploy}"), keysURL: "https://portal.azure.com", noKey: false),
        AIPresetDef(id: "anthropic", name: L("Anthropic 兼容"), kind: .relay,
                    baseURL: "https://openrouter.ai/api/v1", model: "anthropic/claude-3.5-sonnet",
                    note: L("经 OpenAI 兼容网关（非官方 Messages API）"), keysURL: "https://openrouter.ai/keys", noKey: false),

        // Local
        AIPresetDef(id: "ollama", name: "Ollama", kind: .local,
                    baseURL: "http://localhost:11434/v1", model: "llama3.2",
                    note: L("本地，通常无需 Key"), keysURL: "https://ollama.com", noKey: true),
        AIPresetDef(id: "lmstudio", name: "LM Studio", kind: .local,
                    baseURL: "http://localhost:1234/v1", model: "local-model",
                    note: L("本地，默认端口 1234"), keysURL: "https://lmstudio.ai", noKey: true),

        // Custom blank
        AIPresetDef(id: "custom", name: L("自定义 OpenAI 兼容"), kind: .relay,
                    baseURL: "", model: "",
                    note: L("自己填 Base URL / 模型"), keysURL: "", noKey: false),
    ]

    static var presetIDs: Set<String> { Set(all.map(\.id)) }

    static func find(_ id: String) -> AIPresetDef? { all.first { $0.id == id } }
}

enum TranslateTarget: Identifiable {
    case builtin(ProviderID)
    case ai(AIProfile)
    var id: String {
        switch self {
        case .builtin(let p): return p.rawValue
        case .ai(let p): return "ai:\(p.id)"
        }
    }
    var displayName: String {
        switch self {
        case .builtin(let p): return p.displayName
        case .ai(let p): return p.name
        }
    }
    var suitsLiveTranslation: Bool {
        switch self {
        case .builtin(let p): return p.suitsLiveTranslation
        case .ai: return false
        }
    }
    var protectsWithHTML: Bool {
        switch self {
        case .builtin(let p): return p.protectsWithHTML
        case .ai: return false
        }
    }
}

/// One-shot migrate prefs / history domain from older names → Korgino.
/// `KorgiTranslate`（上一代名字）和 `SelectTranslate`（最早的名字）。
enum LegacyMigrate {
    private static let flag = "didMigrateFromKorgiTranslate_v1"
    private static let pruneFlag = "didPruneUnusedAIPresets_v2"

    /// 偏好设置域随 bundle id 走，改名后默认域是空的。旧域按新到旧排。
    private static let formerDomains = [
        "com.sliiu.KorgiTranslate",
        "com.pax.KorgiTranslate",
        "com.pax.SelectTranslate",
    ]

    static func runIfNeeded() {
        let d = UserDefaults.standard
        if !d.bool(forKey: flag) {
            defer { d.set(true, forKey: flag) }
            for domain in formerDomains {
                guard let old = UserDefaults(suiteName: domain) else { continue }
                for (key, value) in old.dictionaryRepresentation() {
                    // 这些由系统写，不是用户的设置。
                    if key.hasPrefix("NS") || key.hasPrefix("Apple") { continue }
                    if d.object(forKey: key) == nil {
                        d.set(value, forKey: key)
                    }
                }
            }
            _ = HistoryStore.load()
        }
    }

    /// Keep only profiles the user actually added (enabled / has key / custom id).
    static func pruneUnusedPresetsIfNeeded(profiles: [AIProfile]) -> [AIProfile] {
        let d = UserDefaults.standard
        guard !d.bool(forKey: pruneFlag) else { return profiles }
        d.set(true, forKey: pruneFlag)

        var out: [AIProfile] = []
        for p in profiles {
            let key = Keychain.get("ai.\(p.id)") ?? ""
            let isBuiltinPreset = AIPresetDef.presetIDs.contains(p.id) || AIPresetDef.presetIDs.contains(p.preset)
            let isBlankCustomSlot = p.id == "custom" && !p.enabled && key.isEmpty && p.baseURL.isEmpty
            if isBlankCustomSlot { continue }
            if isBuiltinPreset && !p.enabled && key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                // unused preset row from old "always list all" UI — drop
                continue
            }
            out.append(p)
        }
        return out
    }
}

/// 按住 Fn 时走的那一条。快捷键只改这一条。
enum VoiceMode: String, CaseIterable, Identifiable {
    case recognize, translate, interpret

    var id: String { rawValue }

    var title: String {
        switch self {
        case .recognize: return L("语音识别")
        case .translate: return L("语音翻译")
        case .interpret: return L("语音传译")
        }
    }

    var historyKind: String {
        switch self {
        case .recognize: return "voice"
        case .translate: return "voiceTranslate"
        case .interpret: return "voiceInterpret"
        }
    }

    var translates: Bool { self != .recognize }
    var writesField: Bool { self != .interpret }
}

/// 一个功能自己的翻译名单。快捷翻译不在这里，它始终一家。
enum TranslateUse: String {
    case select, clipboard, ocr, file, dictate, live, media
}

/// 某个来源应用在一触发模式下用哪一家、哪个模型。留空跟随这个功能的默认。
struct QuickAppTarget: Codable, Equatable {
    var providerID = ""
    /// 只对 AI 那一家生效。留空用设置里的模型。
    var model = ""
    var isEmpty: Bool { providerID.trimmingCharacters(in: .whitespaces).isEmpty }
}

/// 一个来源应用里，三种触发各自一份开关。
enum AppTrigger: String, CaseIterable, Identifiable {
    case select, quick, voice

    var id: String { rawValue }

    var title: String {
        switch self {
        case .select: return L("划词")
        case .quick: return L("快捷翻译")
        case .voice: return L("语音")
        }
    }
}

/// 某个来源应用自己的设置：三触发模式各一家，加语音模式、目标语言。
/// 开没开各自记在三份排除名单里，这里不另存一份。
struct QuickAppRule: Codable, Equatable, Identifiable {
    var bundleID: String
    /// 划词。
    var select = QuickAppTarget()
    /// 快捷翻译：连按三下空格或组合键。
    var quick = QuickAppTarget()
    /// 按住 Fn。
    var voice = QuickAppTarget()
    /// 空串跟随语音页选的模式；其余是 `VoiceMode` 的 rawValue。
    var voiceMode = ""
    /// 空串跟随设置里的目标语言；`followVoice` 跟随语音页选的目标语言；其余是语种代码。
    var language = ""
    /// 划词插件：空串跟随插件页的勾选；`pluginsNone` 这个应用里不弹；`pluginsCustom` 只弹 `pluginIDs`。
    var plugins = ""
    var pluginIDs: [String] = []
    var id: String { bundleID }

    /// `language` 的一个取值，不是语种，所以不会和语种代码撞上。
    static let followVoice = "voice"
    static let pluginsNone = "none"
    static let pluginsCustom = "custom"

    init(bundleID: String) { self.bundleID = bundleID }

    private enum CodingKeys: String, CodingKey {
        case bundleID, select, quick, voice, voiceMode, language, plugins, pluginIDs
        /// 旧版只有这一家，管的是快捷翻译。
        case legacyProvider = "providerID"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        bundleID = try c.decode(String.self, forKey: .bundleID)
        select = try c.decodeIfPresent(QuickAppTarget.self, forKey: .select) ?? QuickAppTarget()
        quick = try c.decodeIfPresent(QuickAppTarget.self, forKey: .quick) ?? QuickAppTarget()
        voice = try c.decodeIfPresent(QuickAppTarget.self, forKey: .voice) ?? QuickAppTarget()
        voiceMode = try c.decodeIfPresent(String.self, forKey: .voiceMode) ?? ""
        language = try c.decodeIfPresent(String.self, forKey: .language) ?? ""
        plugins = try c.decodeIfPresent(String.self, forKey: .plugins) ?? ""
        pluginIDs = try c.decodeIfPresent([String].self, forKey: .pluginIDs) ?? []
        if quick.isEmpty, let legacy = try c.decodeIfPresent(String.self, forKey: .legacyProvider),
           !legacy.trimmingCharacters(in: .whitespaces).isEmpty {
            quick.providerID = legacy
        }
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(bundleID, forKey: .bundleID)
        try c.encode(select, forKey: .select)
        try c.encode(quick, forKey: .quick)
        try c.encode(voice, forKey: .voice)
        try c.encode(voiceMode, forKey: .voiceMode)
        try c.encode(language, forKey: .language)
        try c.encode(plugins, forKey: .plugins)
        try c.encode(pluginIDs, forKey: .pluginIDs)
    }
}

final class AppConfig: ObservableObject {
    static let shared = AppConfig()
    #if !canImport(Combine)
    let objectWillChange = ObservableObjectPublisher()
    #endif

    @Published var enabledProviders: Set<String> { didSet { saveSets() } }
    @Published var activeSimultaneous: Set<String> { didSet { saveSets() } }
    @Published var selectTranslateIDs: [String] { didSet { saveUses() } }
    @Published var clipboardTranslateIDs: [String] { didSet { saveUses() } }
    @Published var ocrTranslateIDs: [String] { didSet { saveUses() } }
    @Published var fileTranslateIDs: [String] { didSet { saveUses() } }
    @Published var dictateTranslateID: String { didSet { saveUses() } }
    @Published var liveDefaultAsrID: String { didSet { saveUses() } }
    @Published var liveAsrOrder: [String] {
        didSet {
            UserDefaults.standard.set(liveAsrOrder, forKey: ConfigKeys.live_asrOrder)
            guard hotkeysReady, let first = liveAsrOrder.first, first != liveDefaultAsrID else { return }
            liveDefaultAsrID = first
        }
    }
    @Published var liveDefaultTranslateID: String { didSet { saveUses() } }
    @Published var mediaDefaultAsrID: String { didSet { saveUses() } }
    @Published var mediaAsrOrder: [String] {
        didSet {
            UserDefaults.standard.set(mediaAsrOrder, forKey: ConfigKeys.media_asrOrder)
            guard hotkeysReady, let first = mediaAsrOrder.first, first != mediaDefaultAsrID else { return }
            mediaDefaultAsrID = first
        }
    }
    @Published var mediaDefaultTranslateID: String { didSet { saveUses() } }
    @Published var googleCloudKey: String = "" {
        didSet { Keychain.set(googleCloudKey, account: "googleCloud") }
    }
    @Published var deeplKey: String = "" {
        didSet { Keychain.set(deeplKey, account: "deepl") }
    }
    @Published var deeplUseFreeAPI: Bool {
        didSet { UserDefaults.standard.set(deeplUseFreeAPI, forKey: ConfigKeys.deeplUseFreeAPI) }
    }
    @Published var microsoftKey: String = "" {
        didSet { Keychain.set(microsoftKey, account: "microsoft") }
    }
    @Published var microsoftRegion: String {
        didSet { UserDefaults.standard.set(microsoftRegion, forKey: ConfigKeys.microsoftRegion) }
    }
    @Published var baiduAppID: String {
        didSet { UserDefaults.standard.set(baiduAppID, forKey: ConfigKeys.baiduAppID) }
    }
    @Published var baiduSecret: String = "" {
        didSet { Keychain.set(baiduSecret, account: "baiduSecret") }
    }
    @Published var youdaoAppKey: String {
        didSet { UserDefaults.standard.set(youdaoAppKey, forKey: ConfigKeys.youdaoAppKey) }
    }
    @Published var youdaoSecret: String = "" {
        didSet { Keychain.set(youdaoSecret, account: "youdaoSecret") }
    }
    @Published var caiyunToken: String = "" {
        didSet { Keychain.set(caiyunToken, account: "caiyun") }
    }
    @Published var libreTranslateURL: String {
        didSet { UserDefaults.standard.set(libreTranslateURL, forKey: ConfigKeys.libreTranslateURL) }
    }
    @Published var libreTranslateKey: String = "" {
        didSet { Keychain.set(libreTranslateKey, account: "libreTranslate") }
    }
    @Published var lingvaURL: String {
        didSet { UserDefaults.standard.set(lingvaURL, forKey: ConfigKeys.lingvaURL) }
    }
    @Published var aiProfiles: [AIProfile] { didSet { persistProfiles() } }
    @Published var fileAIProfileID: String {
        didSet { UserDefaults.standard.set(fileAIProfileID, forKey: ConfigKeys.fileAIProfileID) }
    }
    /// 快捷翻译的默认供应商。空字符串表示打开名单里的第一家。
    @Published var quickProviderID: String {
        didSet { UserDefaults.standard.set(quickProviderID, forKey: ConfigKeys.quickProviderID) }
    }
    /// 排除应用的 bundle id。快捷翻译在这些应用里不动手。
    @Published var quickExcludedApps: [String] {
        didSet { UserDefaults.standard.set(quickExcludedApps, forKey: ConfigKeys.quickExcludedApps) }
    }
    /// 划词在这些应用里不动手。划词插件跟着它走。
    @Published var selectExcludedApps: [String] {
        didSet { UserDefaults.standard.set(selectExcludedApps, forKey: ConfigKeys.selectExcludedApps) }
    }
    /// 按住 Fn 在这些应用里不开始听。
    @Published var voiceExcludedApps: [String] {
        didSet { UserDefaults.standard.set(voiceExcludedApps, forKey: ConfigKeys.voiceExcludedApps) }
    }
    /// 某个来源应用自己的快捷翻译。供应商或语言留空时跟随上面的默认。
    @Published var quickAppRules: [QuickAppRule] = [] {
        didSet {
            if let data = try? JSONEncoder().encode(quickAppRules) {
                UserDefaults.standard.set(data, forKey: ConfigKeys.quickAppRules)
            }
        }
    }

    /// 终端和代码编辑器：连按空格缩进很常见，整段是整个文件或整屏输出。
    static let quickExcludedDefaults: [String] = [
        "com.apple.Terminal", "com.googlecode.iterm2", "dev.warp.Warp-Stable", "com.mitchellh.ghostty",
        "org.alacritty", "net.kovidgoyal.kitty", "com.github.wez.wezterm", "co.zeit.hyper", "com.termius-dmg.mac",
        "com.apple.dt.Xcode", "com.microsoft.VSCode", "com.microsoft.VSCodeInsiders", "com.vscodium",
        "com.todesktop.230313mzl4w4u92", "com.exafunction.windsurf", "dev.zed.Zed", "com.sublimetext.4",
        "com.sublimetext.3", "com.panic.Nova", "com.barebones.bbedit", "org.vim.MacVim", "org.gnu.Emacs",
        "com.google.android.studio", "com.jetbrains.intellij", "com.jetbrains.intellij.ce", "com.jetbrains.pycharm",
        "com.jetbrains.pycharm.ce", "com.jetbrains.WebStorm", "com.jetbrains.goland", "com.jetbrains.CLion",
        "com.jetbrains.rider", "com.jetbrains.PhpStorm", "com.jetbrains.rubymine", "com.jetbrains.datagrip",
        "com.jetbrains.fleet", "com.jetbrains.toolbox"
    ]

    /// 用来读译文的那一种语言。
    @Published var nativeLanguage: TargetLanguage {
        didSet { UserDefaults.standard.set(nativeLanguage.rawValue, forKey: ConfigKeys.nativeLanguage) }
    }
    /// 和母语对翻的那一种。默认 English，不随母语改。
    @Published var targetLanguage: TargetLanguage {
        didSet { UserDefaults.standard.set(targetLanguage.rawValue, forKey: ConfigKeys.targetLanguage) }
    }
    /// 同语润色。关上时，走默认提示的 AI 在原文已是目标语言时不发出去。
    @Published var polishSameLanguage: Bool {
        didSet { UserDefaults.standard.set(polishSameLanguage, forKey: ConfigKeys.polishSameLanguage) }
    }

    /// 翻译浮层里，短词翻完后是否自己展开释义。默认关。
    @Published var dictAutoOpen: Bool {
        didSet { UserDefaults.standard.set(dictAutoOpen, forKey: ConfigKeys.dict_autoOpen) }
    }
    /// 词典目录里的默认一家。
    @Published var dictProvider: DictionaryProviderID {
        didSet { UserDefaults.standard.set(dictProvider.rawValue, forKey: ConfigKeys.dict_provider) }
    }
    /// 词典目录。勾选不表示这次都会查。
    @Published var dictEnabled: Set<String> {
        didSet {
            UserDefaults.standard.set(dictEnabled.sorted(), forKey: ConfigKeys.dict_enabled)
            guard hotkeysReady else { return }
            if !dictEnabled.contains(dictProvider.rawValue),
               let fallback = DictionaryProviderID.allCases.first(where: { dictEnabled.contains($0.rawValue) }) {
                dictProvider = fallback
            }
        }
    }

    /// 遮盖：每一类各自开关。命中后先确认，再把占位符发出去。
    @Published var maskPrefs: MaskPrefs {
        didSet {
            if let data = try? JSONEncoder().encode(maskPrefs) {
                UserDefaults.standard.set(data, forKey: ConfigKeys.maskPrefs)
            }
        }
    }

    /// App-wide appearance: system / light / dark. Applies to all windows via NSApp.appearance.
    @Published var appearance: AppearanceMode {
        didSet {
            UserDefaults.standard.set(appearance.rawValue, forKey: ConfigKeys.appearance)
            appearance.apply()
        }
    }

    /// Translation panel glass, 1 = full material. Text stays opaque.
    @Published var panelOpacity: Double {
        didSet {
            let clamped = min(1, max(0.35, panelOpacity))
            if clamped != panelOpacity {
                panelOpacity = clamped
                return
            }
            UserDefaults.standard.set(clamped, forKey: ConfigKeys.panelOpacity)
        }
    }

    /// OCR engine for screenshot recognize (Apple Vision / Baidu / Youdao).
    /// `ocrProvider` is the default among `ocrEnabled`.
    @Published var ocrProvider: OCRProviderID {
        didSet { UserDefaults.standard.set(ocrProvider.rawValue, forKey: ConfigKeys.ocrProvider) }
    }
    @Published var ocrEnabled: Set<String> {
        didSet {
            UserDefaults.standard.set(ocrEnabled.sorted(), forKey: ConfigKeys.ocrEnabled)
            guard hotkeysReady else { return }
            if !ocrEnabled.contains(ocrProvider.rawValue), let fallback = orderedOCRProviders().first {
                ocrProvider = fallback
            }
        }
    }
    /// 截图识别的显示顺序。第一家是默认。
    @Published var ocrOrder: [String] {
        didSet {
            UserDefaults.standard.set(ocrOrder, forKey: ConfigKeys.ocr_order)
            guard hotkeysReady, let first = orderedOCRProviders().first, ocrProvider != first else { return }
            ocrProvider = first
        }
    }
    @Published var ocrBaiduSync: Bool {
        didSet { UserDefaults.standard.set(ocrBaiduSync, forKey: ConfigKeys.ocrBaiduSync) }
    }
    @Published var ocrBaiduAppID: String {
        didSet { UserDefaults.standard.set(ocrBaiduAppID, forKey: ConfigKeys.ocrBaiduAppID) }
    }
    @Published var ocrBaiduSecret: String = "" {
        didSet { Keychain.set(ocrBaiduSecret, account: "ocrBaiduSecret") }
    }
    @Published var ocrYoudaoSync: Bool {
        didSet { UserDefaults.standard.set(ocrYoudaoSync, forKey: ConfigKeys.ocrYoudaoSync) }
    }
    @Published var ocrYoudaoAppKey: String {
        didSet { UserDefaults.standard.set(ocrYoudaoAppKey, forKey: ConfigKeys.ocrYoudaoAppKey) }
    }
    @Published var ocrYoudaoSecret: String = "" {
        didSet { Keychain.set(ocrYoudaoSecret, account: "ocrYoudaoSecret") }
    }
    @Published var ocrGoogleSync: Bool {
        didSet { UserDefaults.standard.set(ocrGoogleSync, forKey: ConfigKeys.ocrGoogleSync) }
    }
    @Published var ocrGoogleKey: String = "" {
        didSet { Keychain.set(ocrGoogleKey, account: "ocrGoogleKey") }
    }
    var ocrBaiduCredentials: (id: String, secret: String) {
        ocrBaiduSync ? (baiduAppID, baiduSecret) : (ocrBaiduAppID, ocrBaiduSecret)
    }
    var ocrYoudaoCredentials: (appKey: String, secret: String) {
        ocrYoudaoSync ? (youdaoAppKey, youdaoSecret) : (ocrYoudaoAppKey, ocrYoudaoSecret)
    }
    var ocrGoogleAPIKey: String { ocrGoogleSync ? googleCloudKey : ocrGoogleKey }
    @Published var tencentSecretID: String {
        didSet { UserDefaults.standard.set(tencentSecretID, forKey: ConfigKeys.tencentSecretID) }
    }
    @Published var tencentSecretKey: String = "" {
        didSet { Keychain.set(tencentSecretKey, account: "tencentSecretKey") }
    }
    @Published var azureVisionEndpoint: String {
        didSet { UserDefaults.standard.set(azureVisionEndpoint, forKey: ConfigKeys.azureVisionEndpoint) }
    }
    @Published var azureVisionKey: String = "" {
        didSet { Keychain.set(azureVisionKey, account: "azureVision") }
    }
    @Published var ocrSpaceKey: String = "" {
        didSet { Keychain.set(ocrSpaceKey, account: "ocrSpace") }
    }
    @Published var ocrAIProfileID: String {
        didSet { UserDefaults.standard.set(ocrAIProfileID, forKey: ConfigKeys.ocrAIProfileID) }
    }

    @Published var asrAppleEnabled: Bool = true {
        didSet {
            UserDefaults.standard.set(asrAppleEnabled, forKey: ConfigKeys.asrAppleEnabled)
            clampASRSelection()
        }
    }
    @Published var asrAnalyzerEnabled: Bool = true {
        didSet {
            UserDefaults.standard.set(asrAnalyzerEnabled, forKey: ConfigKeys.asrAnalyzerEnabled)
            clampASRSelection()
        }
    }
    @Published var asrAppleOnDevice: Bool = true {
        didSet { UserDefaults.standard.set(asrAppleOnDevice, forKey: ConfigKeys.asrAppleOnDevice) }
    }
    @Published var dictateEnabled: Bool = true {
        didSet {
            UserDefaults.standard.set(dictateEnabled, forKey: ConfigKeys.dictateEnabled)
            guard hotkeysReady else { return }
            NotificationCenter.default.post(name: .korgiHotkeysDidChange, object: nil)
        }
    }
    @Published var dictateEngineID: String = "" {
        didSet { UserDefaults.standard.set(dictateEngineID, forKey: ConfigKeys.dictateEngineID) }
    }
    @Published var dictateLocaleID: String = "system" {
        didSet { UserDefaults.standard.set(dictateLocaleID, forKey: ConfigKeys.dictateLocaleID) }
    }
    /// 语音听哪一只麦克风。空字符串是系统默认输入，和实时字幕的麦克风设备互不影响。
    @Published var dictateInputUID: String = "" {
        didSet { UserDefaults.standard.set(dictateInputUID, forKey: ConfigKeys.dictateInputUID) }
    }
    /// 语音这条线的目标语言。`.auto` 跟随设置里的目标语言；来源应用自己配的仍然优先。
    @Published var dictateTargetLanguage: TargetLanguage = .auto {
        didSet { UserDefaults.standard.set(dictateTargetLanguage.rawValue, forKey: ConfigKeys.dictateTargetLanguage) }
    }
    @Published var voicePolish: Bool = false {
        didSet {
            guard hotkeysReady else { return }
            UserDefaults.standard.set(voicePolish, forKey: ConfigKeys.voicePolish)
        }
    }
    @Published var voicePolishStyle: VoicePolishStyle = .clean {
        didSet {
            guard hotkeysReady else { return }
            UserDefaults.standard.set(voicePolishStyle.rawValue, forKey: ConfigKeys.voicePolishStyle)
        }
    }
    @Published var voicePolishNote: String = "" {
        didSet {
            guard hotkeysReady else { return }
            UserDefaults.standard.set(voicePolishNote, forKey: ConfigKeys.voicePolishNote)
        }
    }
    /// 菜单栏图标旁边是否写出当前语音模式。
    @Published var voiceModeInMenuBar: Bool = true {
        didSet {
            guard hotkeysReady else { return }
            UserDefaults.standard.set(voiceModeInMenuBar, forKey: ConfigKeys.voiceModeInMenuBar)
            NotificationCenter.default.post(name: .korgiHotkeysDidChange, object: nil)
        }
    }
    @Published var voiceMode: VoiceMode {
        didSet {
            guard hotkeysReady else { return }
            UserDefaults.standard.set(voiceMode.rawValue, forKey: ConfigKeys.voiceMode)
        }
    }
    @Published var asrProfiles: [ASRProfile] = [] {
        didSet {
            persistASRProfiles()
            clampASRSelection()
        }
    }
    @Published var asrSelection: String = "apple" {
        didSet { UserDefaults.standard.set(asrSelection, forKey: ConfigKeys.asrSelection) }
    }

    @Published var ttsAppleEnabled: Bool = true {
        didSet {
            UserDefaults.standard.set(ttsAppleEnabled, forKey: ConfigKeys.ttsAppleEnabled)
            clampTTSSelection()
        }
    }
    @Published var ttsProfiles: [TTSProfile] = [] {
        didSet {
            persistTTSProfiles()
            clampTTSSelection()
        }
    }
    @Published var ttsSelection: String = "apple" {
        didSet { UserDefaults.standard.set(ttsSelection, forKey: ConfigKeys.ttsSelection) }
    }

    // MARK: Hotkeys
    /// 跨文件（Config+Hotkeys）读取：首次加载完成前不写回，免得把默认值盖掉。
    var hotkeysReady = false

    @Published var hotkeySelect: HotkeySpec {
        didSet { persistHotkey(.select, hotkeySelect) }
    }
    @Published var hotkeyClipboard: HotkeySpec {
        didSet { persistHotkey(.clipboard, hotkeyClipboard) }
    }
    @Published var hotkeyOCR: HotkeySpec {
        didSet { persistHotkey(.ocr, hotkeyOCR) }
    }
    @Published var hotkeyFile: HotkeySpec {
        didSet { persistHotkey(.file, hotkeyFile) }
    }
    @Published var hotkeyLiveCaptions: HotkeySpec {
        didSet { persistHotkey(.liveCaptions, hotkeyLiveCaptions) }
    }
    @Published var hotkeyMediaCaptions: HotkeySpec {
        didSet { persistHotkey(.mediaCaptions, hotkeyMediaCaptions) }
    }
    @Published var hotkeyDictionary: HotkeySpec {
        didSet { persistHotkey(.dictionary, hotkeyDictionary) }
    }
    @Published var hotkeyHistory: HotkeySpec {
        didSet { persistHotkey(.history, hotkeyHistory) }
    }
    @Published var hotkeyQuick: HotkeySpec {
        didSet { persistHotkey(.quickTranslate, hotkeyQuick) }
    }
    @Published var hotkeyQuickUndo: HotkeySpec {
        didSet { persistHotkey(.quickUndo, hotkeyQuickUndo) }
    }
    @Published var hotkeyVoiceRecognize: HotkeySpec {
        didSet { persistHotkey(.voiceRecognize, hotkeyVoiceRecognize) }
    }
    @Published var hotkeyVoiceTranslate: HotkeySpec {
        didSet { persistHotkey(.voiceTranslate, hotkeyVoiceTranslate) }
    }
    @Published var hotkeyVoiceInterpret: HotkeySpec {
        didSet { persistHotkey(.voiceInterpret, hotkeyVoiceInterpret) }
    }
    @Published var hotkeyOpenMain: HotkeySpec {
        didSet { persistHotkey(.openMain, hotkeyOpenMain) }
    }
    @Published var asrTerms: [String] = [] {
        didSet { UserDefaults.standard.set(asrTerms, forKey: ConfigKeys.asrTerms) }
    }
    /// 勾上的 THUOCL 预设。自己加的词在 `asrTerms`，不写进这里。
    @Published var asrPresets: [String] = [] {
        didSet {
            guard hotkeysReady else { return }
            UserDefaults.standard.set(asrPresets, forKey: ConfigKeys.asrPresets)
        }
    }

    @Published var featureEnabled: [String: Bool] = [:]

    var asrContextTerms: [String] {
        var seen = Set<String>()
        var out: [String] = []
        func add(_ raw: String) {
            let term = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !term.isEmpty, seen.insert(term).inserted, out.count < 100 else { return }
            out.append(String(term.prefix(80)))
        }
        for raw in asrTerms { add(raw) }
        for id in asrPresets {
            guard let pack = ASRPreset(rawValue: id) else { continue }
            for word in pack.words { add(word) }
        }
        return out
    }

    var asrContextPrompt: String? {
        var prompt = ""
        for term in asrContextTerms {
            let next = prompt.isEmpty ? term : prompt + ", " + term
            if next.utf8.count > 800 { break }
            prompt = next
        }
        return prompt.isEmpty ? nil : prompt
    }

    /// 语音页选的目标语言；没选就是设置里的目标语言。
    var voiceTargetLanguage: TargetLanguage {
        dictateTargetLanguage != .auto ? dictateTargetLanguage : targetLanguage.resolvedDestination
    }

    /// Set by AppDelegate after Carbon register; action.rawValue → message (empty = ok).
    @Published var hotkeySystemWarnings: [String: String] = [:]

    // MARK: Network proxy
    /// 跨文件（Config+Proxy）读写。
    var proxyReady = false

    @Published var proxyMode: ProxyMode {
        didSet {
            UserDefaults.standard.set(proxyMode.rawValue, forKey: ConfigKeys.proxyMode)
            notifyProxyChange()
        }
    }
    @Published var proxyType: ProxyType {
        didSet {
            UserDefaults.standard.set(proxyType.rawValue, forKey: ConfigKeys.proxyType)
            notifyProxyChange()
        }
    }
    @Published var proxyHost: String {
        didSet {
            UserDefaults.standard.set(proxyHost, forKey: ConfigKeys.proxyHost)
            notifyProxyChange()
        }
    }
    @Published var proxyPort: Int {
        didSet {
            UserDefaults.standard.set(proxyPort, forKey: ConfigKeys.proxyPort)
            notifyProxyChange()
        }
    }
    @Published var proxyUsername: String {
        didSet {
            UserDefaults.standard.set(proxyUsername, forKey: ConfigKeys.proxyUsername)
            notifyProxyChange()
        }
    }
    @Published var proxyPassword: String = "" {
        didSet {
            Keychain.set(proxyPassword, account: "proxyPassword")
            notifyProxyChange()
        }
    }

    /// 离开键盘 0.4 秒后重建会话；跨文件（Config+Proxy）读写。
    var proxyReload: DispatchWorkItem?

    private init() {
        LegacyMigrate.runIfNeeded()
        let d = UserDefaults.standard
        #if os(Windows)
        let fresh = [ProviderID.googleFree.rawValue]
        #else
        let fresh = [ProviderID.apple.rawValue, ProviderID.googleFree.rawValue]
        #endif
        enabledProviders = Set(d.stringArray(forKey: ConfigKeys.enabledProviders) ?? fresh)
        activeSimultaneous = Set(d.stringArray(forKey: ConfigKeys.activeSimultaneous) ?? fresh)
        selectTranslateIDs = d.stringArray(forKey: ConfigKeys.use_select) ?? []
        clipboardTranslateIDs = d.stringArray(forKey: ConfigKeys.use_clipboard) ?? []
        ocrTranslateIDs = d.stringArray(forKey: ConfigKeys.use_ocr) ?? []
        fileTranslateIDs = d.stringArray(forKey: ConfigKeys.use_file) ?? []
        dictateTranslateID = d.string(forKey: ConfigKeys.use_dictateTranslate) ?? ""
        liveDefaultAsrID = d.string(forKey: ConfigKeys.live_defaultAsr)
            ?? d.string(forKey: ConfigKeys.live_asr_system)
            ?? d.string(forKey: ConfigKeys.asrSelection)
            ?? "apple"
        liveAsrOrder = d.stringArray(forKey: ConfigKeys.live_asrOrder) ?? []
        liveDefaultTranslateID = d.string(forKey: ConfigKeys.use_liveTranslate) ?? ""
        mediaDefaultAsrID = d.string(forKey: ConfigKeys.media_asrEngine)
            ?? d.string(forKey: ConfigKeys.asrSelection)
            ?? "apple"
        mediaAsrOrder = d.stringArray(forKey: ConfigKeys.media_asrOrder) ?? []
        mediaDefaultTranslateID = d.string(forKey: ConfigKeys.use_mediaTranslate) ?? ""
        deeplUseFreeAPI = d.object(forKey: ConfigKeys.deeplUseFreeAPI) as? Bool ?? true
        googleCloudKey = Keychain.get("googleCloud") ?? ""
        deeplKey = Keychain.get("deepl") ?? ""
        microsoftKey = Keychain.get("microsoft") ?? ""
        microsoftRegion = d.string(forKey: ConfigKeys.microsoftRegion) ?? "global"
        baiduAppID = d.string(forKey: ConfigKeys.baiduAppID) ?? ""
        baiduSecret = Keychain.get("baiduSecret") ?? ""
        youdaoAppKey = d.string(forKey: ConfigKeys.youdaoAppKey) ?? ""
        youdaoSecret = Keychain.get("youdaoSecret") ?? ""
        caiyunToken = Keychain.get("caiyun") ?? ""
        libreTranslateURL = d.string(forKey: ConfigKeys.libreTranslateURL) ?? "https://libretranslate.com"
        libreTranslateKey = Keychain.get("libreTranslate") ?? ""
        lingvaURL = d.string(forKey: ConfigKeys.lingvaURL) ?? "https://lingva.ml"
        fileAIProfileID = d.string(forKey: ConfigKeys.fileAIProfileID) ?? ""
        quickProviderID = d.string(forKey: ConfigKeys.quickProviderID) ?? ""
        quickExcludedApps = d.stringArray(forKey: ConfigKeys.quickExcludedApps) ?? Self.quickExcludedDefaults
        selectExcludedApps = d.stringArray(forKey: ConfigKeys.selectExcludedApps) ?? []
        voiceExcludedApps = d.stringArray(forKey: ConfigKeys.voiceExcludedApps) ?? []
        if let data = d.data(forKey: ConfigKeys.quickAppRules),
           let list = try? JSONDecoder().decode([QuickAppRule].self, from: data) {
            quickAppRules = list.map { rule in
                guard rule.language == TargetLanguage.auto.rawValue else { return rule }
                var copy = rule
                copy.language = TargetLanguage.en.rawValue
                return copy
            }
        }
        if let raw = d.string(forKey: ConfigKeys.nativeLanguage),
           let saved = TargetLanguage(rawValue: raw), saved != .auto {
            nativeLanguage = saved
        } else {
            nativeLanguage = TargetLanguage.defaultNative()
        }
        // 「自动」改成 English。没存过的也是 English，不跟系统走。
        if let raw = d.string(forKey: ConfigKeys.targetLanguage),
           let saved = TargetLanguage(rawValue: raw), saved != .auto {
            targetLanguage = saved
        } else {
            targetLanguage = .en
        }
        polishSameLanguage = d.object(forKey: ConfigKeys.polishSameLanguage) as? Bool ?? true
        dictAutoOpen = d.object(forKey: ConfigKeys.dict_autoOpen) as? Bool ?? false
        let dictKnown = Set(DictionaryProviderID.allCases.map(\.rawValue))
        var dictOn: Set<String>
        if d.object(forKey: ConfigKeys.dict_enabled) == nil {
            dictOn = [DictionaryProviderID.freeDictionary.rawValue]
            let sim = Set(d.stringArray(forKey: ConfigKeys.activeSimultaneous) ?? fresh)
            let youdaoKey = (d.string(forKey: ConfigKeys.youdaoAppKey) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            let youdaoSec = (Keychain.get("youdaoSecret") ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            let baiduID = (d.string(forKey: ConfigKeys.baiduAppID) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            let baiduSec = (Keychain.get("baiduSecret") ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            let caiyun = (Keychain.get("caiyun") ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            if sim.contains(ProviderID.youdao.rawValue), !youdaoKey.isEmpty, !youdaoSec.isEmpty {
                dictOn.insert(DictionaryProviderID.youdao.rawValue)
            }
            if sim.contains(ProviderID.baidu.rawValue), !baiduID.isEmpty, !baiduSec.isEmpty {
                dictOn.insert(DictionaryProviderID.baidu.rawValue)
            }
            if sim.contains(ProviderID.caiyun.rawValue), !caiyun.isEmpty {
                dictOn.insert(DictionaryProviderID.caiyun.rawValue)
            }
        } else {
            dictOn = Set(d.stringArray(forKey: ConfigKeys.dict_enabled) ?? []).intersection(dictKnown)
            if dictOn.isEmpty { dictOn = [DictionaryProviderID.freeDictionary.rawValue] }
        }
        let dictChosen = DictionaryProviderID(rawValue: d.string(forKey: ConfigKeys.dict_provider) ?? "") ?? .freeDictionary
        dictProvider = dictOn.contains(dictChosen.rawValue)
            ? dictChosen
            : (DictionaryProviderID.allCases.first { dictOn.contains($0.rawValue) } ?? .freeDictionary)
        dictEnabled = dictOn
        maskPrefs = MaskPrefs.load(d)
        appearance = AppearanceMode(rawValue: d.string(forKey: ConfigKeys.appearance) ?? "") ?? .system
        if let stored = d.object(forKey: ConfigKeys.panelOpacity) as? Double {
            panelOpacity = min(1, max(0.35, stored))
        } else {
            panelOpacity = 1
        }
        appLanguage = AppLanguage(rawValue: d.string(forKey: ConfigKeys.appLanguage) ?? "") ?? .system
        let ocrChosen = OCRProviderID(rawValue: d.string(forKey: ConfigKeys.ocrProvider) ?? "") ?? .appleVision
        let ocrKnown = Set(OCRProviderID.allCases.map(\.rawValue))
        var ocrOn: Set<String>
        if d.object(forKey: ConfigKeys.ocrEnabled) == nil {
            ocrOn = [ocrChosen.rawValue]
        } else {
            ocrOn = Set(d.stringArray(forKey: ConfigKeys.ocrEnabled) ?? []).intersection(ocrKnown)
            if ocrOn.isEmpty { ocrOn = [OCRProviderID.appleVision.rawValue] }
        }
        let ocrDefault = ocrOn.contains(ocrChosen.rawValue)
            ? ocrChosen
            : (OCRProviderID.allCases.first { ocrOn.contains($0.rawValue) } ?? .appleVision)
        var ocrRank = (d.stringArray(forKey: ConfigKeys.ocr_order) ?? []).filter { ocrOn.contains($0) }
        for id in OCRProviderID.allCases.map(\.rawValue) where ocrOn.contains(id) && !ocrRank.contains(id) {
            ocrRank.append(id)
        }
        if let idx = ocrRank.firstIndex(of: ocrDefault.rawValue), idx != 0 {
            ocrRank.remove(at: idx)
            ocrRank.insert(ocrDefault.rawValue, at: 0)
        }
        ocrOrder = ocrRank
        ocrProvider = OCRProviderID(rawValue: ocrRank.first ?? ocrDefault.rawValue) ?? ocrDefault
        ocrEnabled = ocrOn
        ocrBaiduSync = d.object(forKey: ConfigKeys.ocrBaiduSync) as? Bool ?? true
        ocrBaiduAppID = d.string(forKey: ConfigKeys.ocrBaiduAppID) ?? ""
        ocrBaiduSecret = Keychain.get("ocrBaiduSecret") ?? ""
        ocrYoudaoSync = d.object(forKey: ConfigKeys.ocrYoudaoSync) as? Bool ?? true
        ocrYoudaoAppKey = d.string(forKey: ConfigKeys.ocrYoudaoAppKey) ?? ""
        ocrYoudaoSecret = Keychain.get("ocrYoudaoSecret") ?? ""
        ocrGoogleSync = d.object(forKey: ConfigKeys.ocrGoogleSync) as? Bool ?? true
        ocrGoogleKey = Keychain.get("ocrGoogleKey") ?? ""
        tencentSecretID = d.string(forKey: ConfigKeys.tencentSecretID) ?? ""
        tencentSecretKey = Keychain.get("tencentSecretKey") ?? ""
        azureVisionEndpoint = d.string(forKey: ConfigKeys.azureVisionEndpoint) ?? ""
        azureVisionKey = Keychain.get("azureVision") ?? ""
        ocrSpaceKey = Keychain.get("ocrSpace") ?? ""
        ocrAIProfileID = d.string(forKey: ConfigKeys.ocrAIProfileID) ?? ""
        let asr = Self.loadASRState(d)
        asrAppleEnabled = asr.apple
        asrAnalyzerEnabled = d.object(forKey: ConfigKeys.asrAnalyzerEnabled) as? Bool ?? true
        asrAppleOnDevice = d.object(forKey: ConfigKeys.asrAppleOnDevice) as? Bool ?? true
        dictateEnabled = d.object(forKey: ConfigKeys.dictateEnabled) as? Bool ?? true
        dictateEngineID = d.string(forKey: ConfigKeys.dictateEngineID) ?? ""
        dictateLocaleID = d.string(forKey: ConfigKeys.dictateLocaleID) ?? "system"
        dictateInputUID = d.string(forKey: ConfigKeys.dictateInputUID) ?? ""
        dictateTargetLanguage = d.string(forKey: ConfigKeys.dictateTargetLanguage).flatMap(TargetLanguage.init(rawValue:)) ?? .auto
        if let raw = d.string(forKey: ConfigKeys.voiceMode), let mode = VoiceMode(rawValue: raw) {
            voiceMode = mode
        } else {
            voiceMode = (d.object(forKey: ConfigKeys.dictateTranslate) as? Bool == true) ? .translate : .recognize
        }
        asrProfiles = asr.profiles
        asrSelection = asr.selection
        let tts = Self.loadTTSState(d)
        ttsAppleEnabled = tts.apple
        ttsProfiles = tts.profiles
        ttsSelection = tts.selection
        hotkeySelect = Self.loadHotkey(.select, defaults: d)
        hotkeyClipboard = Self.loadHotkey(.clipboard, defaults: d)
        hotkeyOCR = Self.loadHotkey(.ocr, defaults: d)
        hotkeyFile = Self.loadHotkey(.file, defaults: d)
        hotkeyLiveCaptions = Self.loadHotkey(.liveCaptions, defaults: d)
        hotkeyMediaCaptions = Self.loadHotkey(.mediaCaptions, defaults: d)
        hotkeyDictionary = Self.loadHotkey(.dictionary, defaults: d)
        hotkeyHistory = Self.loadHotkey(.history, defaults: d)
        hotkeyQuick = Self.loadHotkey(.quickTranslate, defaults: d)
        hotkeyQuickUndo = Self.loadHotkey(.quickUndo, defaults: d)
        hotkeyVoiceRecognize = Self.loadHotkey(.voiceRecognize, defaults: d)
        hotkeyVoiceTranslate = Self.loadHotkey(.voiceTranslate, defaults: d)
        hotkeyVoiceInterpret = Self.loadHotkey(.voiceInterpret, defaults: d)
        hotkeyOpenMain = Self.loadHotkey(.openMain, defaults: d)
        asrTerms = d.stringArray(forKey: ConfigKeys.asrTerms) ?? []
        asrPresets = d.stringArray(forKey: ConfigKeys.asrPresets) ?? []
        voicePolish = d.object(forKey: ConfigKeys.voicePolish) as? Bool ?? false
        voicePolishStyle = VoicePolishStyle(rawValue: d.string(forKey: ConfigKeys.voicePolishStyle) ?? "") ?? .clean
        voicePolishNote = d.string(forKey: ConfigKeys.voicePolishNote) ?? ""
        voiceModeInMenuBar = d.object(forKey: ConfigKeys.voiceModeInMenuBar) as? Bool ?? true
        var enabled: [String: Bool] = [:]
        for action in HotkeyAction.allCases {
            if d.object(forKey: action.enabledKey) != nil {
                enabled[action.rawValue] = d.bool(forKey: action.enabledKey)
            }
        }
        featureEnabled = enabled
        proxyMode = ProxyMode(rawValue: d.string(forKey: ConfigKeys.proxyMode) ?? "") ?? .system
        proxyType = ProxyType(rawValue: d.string(forKey: ConfigKeys.proxyType) ?? "") ?? .http
        proxyHost = d.string(forKey: ConfigKeys.proxyHost) ?? "127.0.0.1"
        let port = d.object(forKey: ConfigKeys.proxyPort) as? Int ?? 7890
        proxyPort = (1...65535).contains(port) ? port : 7890
        proxyUsername = d.string(forKey: ConfigKeys.proxyUsername) ?? ""
        proxyPassword = Keychain.get("proxyPassword") ?? ""
        var loaded: [AIProfile] = []
        if let data = d.data(forKey: ConfigKeys.aiProfiles),
           let list = try? JSONDecoder().decode([AIProfile].self, from: data) {
            loaded = list.map { Self.normalizeProfile($0) }
        }
        loaded = LegacyMigrate.pruneUnusedPresetsIfNeeded(profiles: loaded)
        aiProfiles = loaded
        if let data = try? JSONEncoder().encode(aiProfiles) {
            d.set(data, forKey: ConfigKeys.aiProfiles)
        }
        let unified = enabledProviders.union(activeSimultaneous)
        enabledProviders = unified.isEmpty ? [ProviderID.googleFree.rawValue] : unified
        activeSimultaneous = enabledProviders
        for i in aiProfiles.indices {
            let key = "ai:\(aiProfiles[i].id)"
            if aiProfiles[i].enabled {
                activeSimultaneous.insert(key)
            } else if activeSimultaneous.contains(key) {
                var p = aiProfiles[i]
                p.enabled = true
                aiProfiles[i] = p
            }
        }
        seedFeatureDefaultsIfNeeded()
        enforceReadyInvariant()
        proxyReady = true
        hotkeysReady = true
        L10n.use(appLanguage)
        syncAppleLanguages()
    }

    @Published var appLanguage: AppLanguage = .system {
        didSet {
            guard hotkeysReady else { return }
            UserDefaults.standard.set(appLanguage.rawValue, forKey: ConfigKeys.appLanguage)
            L10n.use(appLanguage)
            syncAppleLanguages()
            NotificationCenter.default.post(name: .korgiLanguageDidChange, object: nil)
        }
    }

    var asrUsesApple: Bool { isSystemASR(asrSelection) }

    var liveCaptionsUseApple: Bool { asrUsesApple }

    // MARK: - 就绪判定（启用的前提：必填字段齐全；免密钥/本地的除外）

}
