import Foundation

/// TTS: part of AppConfig.
extension AppConfig {
    func enabledTTSChoices() -> [ASRChoice] {
        var out: [ASRChoice] = []
        if ttsAppleEnabled {
            out.append(ASRChoice(id: "apple", name: L("Apple 语音")))
        }
        for p in ttsProfiles where p.enabled {
            out.append(ASRChoice(id: p.id, name: p.name.isEmpty ? L("未命名") : p.name))
        }
        if out.isEmpty {
            out.append(ASRChoice(id: "apple", name: L("Apple 语音")))
        }
        return out
    }

    func setTTSApple(_ on: Bool) {
        if !on && !ttsProfiles.contains(where: \.enabled) { return }
        ttsAppleEnabled = on
    }

    func setTTSOn(at idx: Int, _ on: Bool) {
        guard ttsProfiles.indices.contains(idx) else { return }
        if !on && !ttsAppleEnabled && ttsProfiles.filter(\.enabled).count <= 1 { return }
        var p = ttsProfiles[idx]
        p.enabled = on
        ttsProfiles[idx] = p
    }

    @discardableResult
    func addTTS(from preset: TTSPresetDef) -> Int {
        let dup = preset.id != "custom" && ttsProfiles.contains { $0.preset == preset.id }
        let suffix = (dup || preset.id == "custom") ? String(UUID().uuidString.prefix(4)) : nil
        ttsProfiles.append(TTSProfile.fromPreset(preset, suffix: suffix))
        let idx = ttsProfiles.count - 1
        ttsProfiles[idx].enabled = ttsReady(ttsProfiles[idx])
        ttsSelection = ttsProfiles[idx].id
        return idx
    }

    func removeTTS(at idx: Int) {
        guard ttsProfiles.indices.contains(idx) else { return }
        let enabledCount = ttsProfiles.filter(\.enabled).count
        let removingEnabled = ttsProfiles[idx].enabled
        if removingEnabled && !ttsAppleEnabled && enabledCount <= 1 {
            ttsAppleEnabled = true
        }
        let id = ttsProfiles[idx].id
        ttsProfiles.remove(at: idx)
        Keychain.delete("tts.\(id)")
    }

    func availableTTSPresets() -> [TTSPresetDef] {
        let have = Set(ttsProfiles.map(\.preset))
        return TTSPresetDef.all.filter { $0.id == "custom" || !have.contains($0.id) }
    }

    func ttsKey(for profile: TTSProfile) -> String { Keychain.get(profile.keychainAccount) ?? "" }

    func setTTSKey(_ key: String, for profile: TTSProfile) {
        Keychain.set(key, account: profile.keychainAccount)
        objectWillChange.send()
    }

    func ttsRequest(selection: String? = nil) throws -> TTSRequest {
        let id = selection ?? ttsSelection
        guard id != "apple", let profile = ttsProfiles.first(where: { $0.id == id && $0.enabled }) else {
            throw TErr(L("当前为 Apple 语音"))
        }
        let preset = TTSPresetDef.find(profile.preset)
        let synced = profile.syncAI ? syncedAIKey(preset: preset?.aiPreset ?? "") : nil
        let key = (synced ?? ttsKey(for: profile))
            .trimmingCharacters(in: .whitespacesAndNewlines)
        var base = profile.baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        if base.isEmpty { base = preset?.baseURL ?? "" }
        if base.isEmpty { throw TErr(L("朗读接口地址无效")) }
        if key.isEmpty && !(preset?.noKey ?? false) {
            throw TErr(L("请先在设置里填写朗读 API Key"))
        }
        let model = profile.model.trimmingCharacters(in: .whitespacesAndNewlines)
        let voice = profile.voice.trimmingCharacters(in: .whitespacesAndNewlines)
        return TTSRequest(
            preset: profile.preset,
            wire: preset?.wire ?? .openai,
            baseURL: base,
            key: key,
            model: model.isEmpty ? (preset?.model ?? "") : model,
            voice: voice.isEmpty ? (preset?.voice ?? "") : voice
        )
    }

    func clampTTSSelection() {
        let ids = enabledTTSChoices().map(\.id)
        if !ids.contains(ttsSelection) {
            ttsSelection = ids.first ?? "apple"
        }
    }

    func persistTTSProfiles() {
        if let data = try? JSONEncoder().encode(ttsProfiles) {
            UserDefaults.standard.set(data, forKey: ConfigKeys.ttsProfiles)
        }
    }

    static func loadTTSState(_ d: UserDefaults) -> (apple: Bool, profiles: [TTSProfile], selection: String) {
        let apple = d.object(forKey: ConfigKeys.ttsAppleEnabled) as? Bool ?? true
        var profiles: [TTSProfile] = []
        if let data = d.data(forKey: ConfigKeys.ttsProfiles),
           let list = try? JSONDecoder().decode([TTSProfile].self, from: data) {
            profiles = list
        }
        var selection = d.string(forKey: ConfigKeys.ttsSelection) ?? "apple"
        var ids: [String] = apple ? ["apple"] : []
        ids += profiles.filter(\.enabled).map(\.id)
        if ids.isEmpty { ids = ["apple"] }
        if !ids.contains(selection) { selection = ids[0] }
        return (apple, profiles, selection)
    }

    func preferredFileProfile() -> AIProfile? {
        if let p = profile(id: fileAIProfileID), isActiveAI(p) {
            let preset = AIPresetDef.find(p.preset)
            if (preset?.noKey ?? false) || !aiKey(for: p).isEmpty { return p }
        }
        return aiProfiles.first {
            guard isActiveAI($0) else { return false }
            let preset = AIPresetDef.find($0.preset)
            return (preset?.noKey ?? false) || !aiKey(for: $0).isEmpty
        }
    }
}
