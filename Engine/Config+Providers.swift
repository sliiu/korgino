import Foundation

/// Providers: part of AppConfig.
extension AppConfig {
    func aiKey(for profile: AIProfile) -> String { Keychain.get(profile.keychainAccount) ?? "" }

    func setAIKey(_ key: String, for profile: AIProfile) {
        Keychain.set(key, account: profile.keychainAccount)
        objectWillChange.send()
    }

    func isProviderOn(_ id: ProviderID) -> Bool {
        activeSimultaneous.contains(id.rawValue)
    }

    func setProviderOn(_ id: ProviderID, _ on: Bool) {
        let key = id.rawValue
        if on {
            activeSimultaneous.insert(key)
            enabledProviders.insert(key)
        } else {
            activeSimultaneous.remove(key)
            enabledProviders.remove(key)
        }
    }

    func isAIOn(_ profile: AIProfile) -> Bool { profile.enabled }

    func setAIOn(at idx: Int, _ on: Bool) {
        guard aiProfiles.indices.contains(idx) else { return }
        var p = aiProfiles[idx]
        p.enabled = on
        aiProfiles[idx] = p
        let key = "ai:\(p.id)"
        if on { activeSimultaneous.insert(key) }
        else { activeSimultaneous.remove(key) }
    }

    /// Presets not yet added (or custom always available). Add sheet lists these.
    func availablePresets() -> [AIPresetDef] {
        let have = Set(aiProfiles.map(\.preset).filter { !$0.isEmpty })
            .union(Set(aiProfiles.map(\.id)))
        return AIPresetDef.all.filter { p in
            if p.id == "custom" { return true }
            return !have.contains(p.id)
        }
    }

    /// Add from preset. If that preset id already exists, create a second instance with UUID suffix.
    @discardableResult
    func addProvider(from preset: AIPresetDef) -> Int {
        let already = aiProfiles.contains { $0.id == preset.id || $0.preset == preset.id && $0.id == preset.id }
        let profile: AIProfile
        if preset.id == "custom" || already {
            var p = AIProfile.fromPreset(preset, instanceSuffix: String(UUID().uuidString.prefix(8)))
            if preset.id == "custom" {
                p.name = String(format: L("自定义 %@"), String(aiProfiles.filter { $0.preset == "custom" || $0.preset.isEmpty }.count + 1))
                p.preset = "custom"
            }
            profile = p
        } else {
            profile = AIProfile.fromPreset(preset)
        }
        aiProfiles.append(profile)
        let idx = aiProfiles.count - 1
        setAIOn(at: idx, aiReady(aiProfiles[idx]))
        return idx
    }

    func removeAI(at idx: Int) {
        guard aiProfiles.indices.contains(idx) else { return }
        let id = aiProfiles[idx].id
        Keychain.delete("ai.\(id)")
        activeSimultaneous.remove("ai:\(id)")
        enabledProviders.remove("ai:\(id)")
        if fileAIProfileID == id { fileAIProfileID = "" }
        aiProfiles.remove(at: idx)
    }

    /// Export AI provider configs (no API keys).
    func exportAIProvidersJSON() -> Data? {
        struct Row: Codable {
            var id, name, baseURL, model, systemPrompt, preset: String
            var enabled: Bool
        }
        let rows = aiProfiles.map {
            Row(id: $0.id, name: $0.name, baseURL: $0.baseURL, model: $0.model,
                systemPrompt: $0.systemPrompt, preset: $0.preset, enabled: $0.enabled)
        }
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try? enc.encode(rows)
    }

    /// Import AI provider configs. Keys are never imported (user must re-fill).
    @discardableResult
    func importAIProvidersJSON(_ data: Data) -> Int {
        struct Row: Codable {
            var id, name, baseURL, model, systemPrompt, preset: String?
            var enabled: Bool?
        }
        guard let rows = try? JSONDecoder().decode([Row].self, from: data) else { return 0 }
        var added = 0
        let existing = Set(aiProfiles.map(\.id))
        for r in rows {
            let id = r.id ?? UUID().uuidString
            if existing.contains(id) { continue }
            let p = AIProfile(
                id: id,
                name: r.name ?? L("导入"),
                baseURL: r.baseURL ?? "",
                model: r.model ?? "",
                systemPrompt: r.systemPrompt ?? "",
                enabled: r.enabled ?? false,
                preset: r.preset ?? ""
            )
            aiProfiles.append(p)
            if p.enabled { activeSimultaneous.insert("ai:\(p.id)") }
            added += 1
        }
        return added
    }

    func enabledTranslateTargets() -> [TranslateTarget] {
        checkedTargets()
    }

    /// 勾着的全部，不管能不能用。
    func checkedTargets() -> [TranslateTarget] {
        ProviderID.allCases.filter(isProviderOn).map { .builtin($0) } + aiProfiles.filter(\.enabled).map { .ai($0) }
    }

    /// 目录里勾上、并且密钥齐全的翻译服务。没有免费档数量限制。
    func catalogTargets() -> [TranslateTarget] {
        let allowed = Set(checkedTargets().map(\.id))
        let out = availableTargets().filter { allowed.contains($0.id) }
        #if os(Windows)
        return out.isEmpty ? [.builtin(.googleFree)] : out
        #else
        return out.isEmpty ? [.builtin(.apple)] : out
        #endif
    }

    func simultaneousTargets() -> [TranslateTarget] { catalogTargets() }

    func translateCap(_ use: TranslateUse) -> Int? {
        if Pro.unlocked { return nil }
        switch use {
        case .select, .clipboard, .ocr: return Pro.freeSimultaneous
        case .file, .dictate, .live, .media: return 1
        }
    }

    func translateTargets(_ use: TranslateUse) -> [TranslateTarget] {
        let catalog = catalogTargets()
        let wanted = storedTranslateIDs(use)
        var picked = wanted.compactMap { id in catalog.first { $0.id == id } }
        if picked.isEmpty { picked = catalog }
        if let cap = translateCap(use) { picked = Array(picked.prefix(cap)) }
        return picked
    }

    func storedTranslateIDs(_ use: TranslateUse) -> [String] {
        switch use {
        case .select: return selectTranslateIDs
        case .clipboard: return clipboardTranslateIDs
        case .ocr: return ocrTranslateIDs
        case .file: return fileTranslateIDs
        case .dictate: return dictateTranslateID.isEmpty ? [] : [dictateTranslateID]
        case .live: return liveDefaultTranslateID.isEmpty ? [] : [liveDefaultTranslateID]
        case .media: return mediaDefaultTranslateID.isEmpty ? [] : [mediaDefaultTranslateID]
        }
    }

    func setTranslateIDs(_ ids: [String], _ use: TranslateUse) {
        var clean: [String] = []
        let catalog = catalogTargets()
        for id in ids where catalog.contains(where: { $0.id == id }) && !clean.contains(id) {
            clean.append(id)
        }
        if let cap = translateCap(use) { clean = Array(clean.prefix(cap)) }
        switch use {
        case .select: selectTranslateIDs = clean
        case .clipboard: clipboardTranslateIDs = clean
        case .ocr: ocrTranslateIDs = clean
        case .file: fileTranslateIDs = clean
        case .dictate: dictateTranslateID = clean.first ?? ""
        case .live: liveDefaultTranslateID = clean.first ?? ""
        case .media: mediaDefaultTranslateID = clean.first ?? ""
        }
    }

    func toggleTranslate(_ id: String, _ use: TranslateUse) -> Bool {
        var ids = storedTranslateIDs(use)
        if let index = ids.firstIndex(of: id) {
            ids.remove(at: index)
            setTranslateIDs(ids, use)
            return true
        }
        if let cap = translateCap(use), ids.count >= cap { return false }
        ids.append(id)
        setTranslateIDs(ids, use)
        return true
    }

    func moveTranslate(_ use: TranslateUse, from: String, to: String) {
        var ids = storedTranslateIDs(use)
        guard let i = ids.firstIndex(of: from), let j = ids.firstIndex(of: to), i != j else { return }
        let item = ids.remove(at: i)
        ids.insert(item, at: j)
        setTranslateIDs(ids, use)
    }

    /// 勾着且能用。对话和文件翻译从这些里选模型。
    func isActiveAI(_ p: AIProfile) -> Bool {
        p.enabled && catalogTargets().contains { $0.id == "ai:\(p.id)" }
    }

    func canEnableMore() -> Bool { true }

    func availableTargets() -> [TranslateTarget] {
        var out: [TranslateTarget] = []
        for id in ProviderID.allCases {
            #if os(Windows)
            if id == .apple { continue }
            #endif
            if id == .googleCloud && googleCloudKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { continue }
            if id == .deepl && deeplKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { continue }
            if id == .microsoft && microsoftKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { continue }
            if id == .baidu && (baiduAppID.isEmpty || baiduSecret.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty) { continue }
            if id == .youdao && (youdaoAppKey.isEmpty || youdaoSecret.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty) { continue }
            if id == .caiyun && caiyunToken.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { continue }
            out.append(.builtin(id))
        }
        for p in aiProfiles {
            let key = aiKey(for: p).trimmingCharacters(in: .whitespacesAndNewlines)
            let preset = AIPresetDef.find(p.preset)
            if key.isEmpty && !(preset?.noKey ?? false) { continue }
            if p.baseURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { continue }
            out.append(.ai(p))
        }
        return out
    }

    func profile(id: String) -> AIProfile? { aiProfiles.first { $0.id == id } }

    /// 同步密钥时对上的翻译提供商。同一家加了几个时，先挑填了 Key 的。
    func syncedAIProfile(preset: String) -> AIProfile? {
        let id = preset.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !id.isEmpty else { return nil }
        var matches = aiProfiles.filter { $0.preset == id || $0.id == id }
        if matches.isEmpty {
            switch id {
            case "openai": matches = aiProfiles.filter { $0.baseURL.contains("api.openai.com") }
            case "groq": matches = aiProfiles.filter { $0.baseURL.contains("groq.com") }
            case "siliconflow": matches = aiProfiles.filter { $0.baseURL.contains("siliconflow") }
            default: break
            }
        }
        return matches.first { !blank(aiKey(for: $0)) } ?? matches.first
    }

    /// 同步时真正借得到的 Key。对上的翻译提供商没填 Key 时是 nil，回到自己填的那个。
    func syncedAIKey(preset: String) -> String? {
        guard let p = syncedAIProfile(preset: preset) else { return nil }
        let key = aiKey(for: p).trimmingCharacters(in: .whitespacesAndNewlines)
        return key.isEmpty ? nil : key
    }
}
