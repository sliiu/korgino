import Foundation

/// ASR: part of AppConfig.
extension AppConfig {
    func resolvedLiveAsr() -> String {
        orderedASR(stored: liveAsrOrder, preferred: liveDefaultAsrID).first?.id ?? "apple"
    }

    func resolvedMediaAsr() -> String {
        mediaASRChoices().first?.id ?? "apple"
    }

    func resolvedDictateAsr() -> String {
        let ids = liveASRChoices().map(\.id)
        if ids.contains(dictateEngineID) { return dictateEngineID }
        return ids.first ?? "apple"
    }

    func isLegacyASR(_ id: String) -> Bool { id == "apple" }

    func isAnalyzerASR(_ id: String) -> Bool { id == "analyzer" }

    func isSystemASR(_ id: String) -> Bool { isLegacyASR(id) || isAnalyzerASR(id) }

    /// 同传服务的接口，不是同传服务时为 nil。
    func interpWire(_ id: String) -> InterpWire? {
        guard let profile = asrProfiles.first(where: { $0.id == id }) else { return nil }
        return ASRPresetDef.find(profile.preset)?.interpWire
    }

    func isInterpASR(_ id: String) -> Bool { interpWire(id) != nil }

    /// 同传连接要的地址、密钥和模型。密钥可以跟同一家的翻译服务共用，地址只用自己的。
    func interpConfig(selection id: String, target: TargetLanguage, audio: Bool, withTerms: Bool = true) throws -> InterpConfig {
        guard let profile = asrProfiles.first(where: { $0.id == id }),
              let preset = ASRPresetDef.find(profile.preset),
              let wire = preset.interpWire else {
            throw TErr(L("这不是同传服务"))
        }
        let synced = profile.syncAI ? syncedAIKey(preset: preset.aiPreset) : nil
        let key = (synced ?? asrKey(for: profile))
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if key.isEmpty { throw TErr(L("请先在设置里填写同传服务的 API Key")) }
        var base = profile.baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        if base.isEmpty { base = preset.baseURL }
        let model = profile.model.trimmingCharacters(in: .whitespacesAndNewlines)
        let chosen = model.isEmpty ? preset.model : model
        guard let url = Self.interpURL(base, model: chosen) else { throw TErr(L("同传接口地址无效")) }
        return InterpConfig(
            wire: wire,
            url: url,
            key: key,
            model: chosen,
            target: InterpLanguages.code(target),
            terms: withTerms ? asrContextTerms : [],
            audio: audio,
            voice: profile.voice.trimmingCharacters(in: .whitespacesAndNewlines)
        )
    }

    static func interpURL(_ base: String, model: String) -> URL? {
        var raw = base.trimmingCharacters(in: .whitespacesAndNewlines)
        if raw.hasPrefix("https://") { raw = "wss://" + raw.dropFirst("https://".count) }
        if raw.hasPrefix("http://") { raw = "ws://" + raw.dropFirst("http://".count) }
        guard var parts = URLComponents(string: raw), let scheme = parts.scheme,
              scheme == "wss" || scheme == "ws", let host = parts.host?.lowercased(), !host.isEmpty else { return nil }
        // 百炼控制台给的是 HTTP 地址（…/api/v1 或 …/compatible-mode/v1），同传走同一台主机上的 WebSocket 路径。
        if host.hasSuffix(".aliyuncs.com"), !parts.path.contains("/api-ws/") {
            parts.path = "/api-ws/v1/realtime"
        }
        if host == "api.openai.com", !parts.path.contains("/realtime/") {
            parts.path = "/v1/realtime/translations"
        }
        var items = parts.queryItems ?? []
        if !items.contains(where: { $0.name == "model" }) {
            items.append(URLQueryItem(name: "model", value: model))
        }
        parts.queryItems = items
        return parts.url
    }

    func liveASRChoices() -> [ASRChoice] { orderedASR(stored: liveAsrOrder, preferred: liveDefaultAsrID) }

    /// 媒体是整份文件，不走同传。
    func mediaASRChoices() -> [ASRChoice] {
        orderedASR(stored: mediaAsrOrder, preferred: mediaDefaultAsrID).filter { !isInterpASR($0.id) }
    }

    func orderedASR(stored: [String], preferred: String) -> [ASRChoice] {
        let choices = enabledASRChoices()
        var result: [ASRChoice] = []
        let rank = stored.isEmpty && choices.contains(where: { $0.id == preferred })
            ? [preferred] + choices.map(\.id).filter { $0 != preferred }
            : stored
        for id in rank {
            if let choice = choices.first(where: { $0.id == id }) { result.append(choice) }
        }
        for choice in choices where !result.contains(where: { $0.id == choice.id }) {
            result.append(choice)
        }
        return result
    }

    func moveASR(live: Bool, from: String, to: String) {
        let current = (live ? liveASRChoices() : mediaASRChoices()).map(\.id)
        guard let i = current.firstIndex(of: from), let j = current.firstIndex(of: to), i != j else { return }
        var ids = current
        let item = ids.remove(at: i)
        ids.insert(item, at: j)
        if live { liveAsrOrder = ids } else { mediaAsrOrder = ids }
    }

    func setDefaultAsr(_ id: String, live: Bool) {
        var ids = (live ? liveASRChoices() : mediaASRChoices()).map(\.id)
        ids.removeAll { $0 == id }
        ids.insert(id, at: 0)
        if live { liveAsrOrder = ids } else { mediaAsrOrder = ids }
    }

    func enabledASRChoices() -> [ASRChoice] {
        var out: [ASRChoice] = []
        if asrAnalyzerEnabled {
            out.append(ASRChoice(id: "analyzer", name: L("Apple 语音分析")))
        }
        if asrAppleEnabled {
            out.append(ASRChoice(id: "apple", name: L("Apple 语音")))
        }
        for p in asrProfiles where p.enabled {
            guard asrProfileReady(p) else { continue }
            out.append(ASRChoice(id: p.id, name: p.name.isEmpty ? L("未命名") : p.name))
        }
        if out.isEmpty {
            out.append(ASRChoice(id: "apple", name: L("Apple 语音")))
        }
        return out
    }

    func setASRApple(_ on: Bool) {
        if !on && !asrAnalyzerEnabled && !asrProfiles.contains(where: \.enabled) { return }
        asrAppleEnabled = on
    }

    func setASRAnalyzer(_ on: Bool) {
        if !on && !asrAppleEnabled && !asrProfiles.contains(where: \.enabled) { return }
        asrAnalyzerEnabled = on
    }

    func setASROn(at idx: Int, _ on: Bool) {
        guard asrProfiles.indices.contains(idx) else { return }
        if !on && !asrAppleEnabled && !asrAnalyzerEnabled && asrProfiles.filter(\.enabled).count <= 1 { return }
        var p = asrProfiles[idx]
        p.enabled = on
        asrProfiles[idx] = p
    }

    @discardableResult
    func addASR(from preset: ASRPresetDef) -> Int {
        let dup = preset.id != "custom" && asrProfiles.contains { $0.preset == preset.id }
        let suffix = (dup || preset.id == "custom") ? String(UUID().uuidString.prefix(4)) : nil
        asrProfiles.append(ASRProfile.fromPreset(preset, suffix: suffix))
        let idx = asrProfiles.count - 1
        asrProfiles[idx].enabled = asrProfileReady(asrProfiles[idx])
        return idx
    }

    func removeASR(at idx: Int) {
        guard asrProfiles.indices.contains(idx) else { return }
        let enabledCount = asrProfiles.filter(\.enabled).count
        let removingEnabled = asrProfiles[idx].enabled
        if removingEnabled && !asrAppleEnabled && !asrAnalyzerEnabled && enabledCount <= 1 {
            asrAppleEnabled = true
        }
        let id = asrProfiles[idx].id
        asrProfiles.remove(at: idx)
        Keychain.delete("asr.\(id)")
    }

    func availableASRPresets() -> [ASRPresetDef] {
        let have = Set(asrProfiles.map(\.preset))
        return ASRPresetDef.all.filter { $0.id == "custom" || !have.contains($0.id) }
    }

    func asrKey(for profile: ASRProfile) -> String { Keychain.get(profile.keychainAccount) ?? "" }

    func setASRKey(_ key: String, for profile: ASRProfile) {
        Keychain.set(key, account: profile.keychainAccount)
        objectWillChange.send()
    }

    func asrWhisperConfig(selection: String? = nil) throws -> WhisperASRConfig {
        let id = selection ?? asrSelection
        guard !isSystemASR(id), let profile = asrProfiles.first(where: { $0.id == id }) else {
            throw TErr(L("当前为 Apple 语音识别"))
        }
        if ASRPresetDef.find(profile.preset)?.interpWire != nil {
            throw TErr(L("同传服务不做整段转写"))
        }
        let preset = ASRPresetDef.find(profile.preset)
        let synced = profile.syncAI ? syncedAIProfile(preset: preset?.aiPreset ?? "") : nil
        let key = ((profile.syncAI ? syncedAIKey(preset: preset?.aiPreset ?? "") : nil) ?? asrKey(for: profile))
            .trimmingCharacters(in: .whitespacesAndNewlines)
        var base = profile.baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        if base.isEmpty { base = synced?.baseURL.trimmingCharacters(in: .whitespacesAndNewlines) ?? "" }
        if base.isEmpty { base = preset?.baseURL ?? "" }
        if base.isEmpty { throw TErr(L("Whisper 接口地址无效")) }
        if key.isEmpty && !(preset?.noKey ?? false) {
            throw TErr(L("请先在设置里填写语音识别 API Key"))
        }
        let model = profile.model.trimmingCharacters(in: .whitespacesAndNewlines)
        let fallback = preset?.model.isEmpty == false ? preset!.model : "whisper-1"
        return WhisperASRConfig(baseURL: base, key: key, model: model.isEmpty ? fallback : model)
    }

    func clampASRSelection() {
        let ids = enabledASRChoices().map(\.id)
        if !ids.contains(asrSelection) {
            asrSelection = ids.first ?? "apple"
        }
    }

    func persistASRProfiles() {
        if let data = try? JSONEncoder().encode(asrProfiles) {
            UserDefaults.standard.set(data, forKey: ConfigKeys.asrProfiles)
        }
    }

    static func loadASRState(_ d: UserDefaults) -> (apple: Bool, profiles: [ASRProfile], selection: String) {
        if let data = d.data(forKey: ConfigKeys.asrProfiles),
           let list = try? JSONDecoder().decode([ASRProfile].self, from: data) {
            let apple = d.object(forKey: ConfigKeys.asrAppleEnabled) as? Bool ?? true
            var selection = d.string(forKey: ConfigKeys.asrSelection) ?? "apple"
            var ids: [String] = apple ? ["apple"] : []
            ids += list.filter(\.enabled).map(\.id)
            if ids.isEmpty { ids = ["apple"] }
            if !ids.contains(selection) { selection = ids[0] }
            return (apple, list, selection)
        }
        let old = d.string(forKey: ConfigKeys.asrProvider) ?? "apple"
        var profiles: [ASRProfile] = []
        if let preset = ASRPresetDef.find("openai") {
            let key = Keychain.get("asrOpenAI") ?? ""
            let sync = d.object(forKey: ConfigKeys.asrOpenAISync) as? Bool ?? true
            if old == "openaiWhisper" || !key.isEmpty || !sync {
                var p = ASRProfile.fromPreset(preset)
                p.baseURL = d.string(forKey: ConfigKeys.asrOpenAIBaseURL) ?? preset.baseURL
                p.model = d.string(forKey: ConfigKeys.asrOpenAIModel) ?? preset.model
                p.syncAI = sync
                p.enabled = old == "openaiWhisper"
                if !key.isEmpty { Keychain.set(key, account: p.keychainAccount) }
                profiles.append(p)
            }
        }
        if let preset = ASRPresetDef.find("groq") {
            let key = Keychain.get("asrGroq") ?? ""
            let sync = d.object(forKey: ConfigKeys.asrGroqSync) as? Bool ?? true
            if old == "groqWhisper" || !key.isEmpty || !sync {
                var p = ASRProfile.fromPreset(preset)
                p.model = d.string(forKey: ConfigKeys.asrGroqModel) ?? preset.model
                p.syncAI = sync
                p.enabled = old == "groqWhisper"
                if !key.isEmpty { Keychain.set(key, account: p.keychainAccount) }
                profiles.append(p)
            }
        }
        let selection: String
        switch old {
        case "openaiWhisper": selection = profiles.first { $0.preset == "openai" }?.id ?? "apple"
        case "groqWhisper": selection = profiles.first { $0.preset == "groq" }?.id ?? "apple"
        default: selection = "apple"
        }
        if let data = try? JSONEncoder().encode(profiles) {
            d.set(data, forKey: ConfigKeys.asrProfiles)
        }
        d.set(true, forKey: ConfigKeys.asrAppleEnabled)
        d.set(selection, forKey: ConfigKeys.asrSelection)
        return (true, profiles, selection)
    }
}
