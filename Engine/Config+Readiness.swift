import Foundation

/// Readiness: part of AppConfig.
extension AppConfig {
    func isPaused(_ id: String) -> Bool { false }

    func isDictOn(_ p: DictionaryProviderID) -> Bool { dictEnabled.contains(p.rawValue) }

    func setDictOn(_ p: DictionaryProviderID, _ on: Bool) {
        if !on, dictEnabled.count <= 1, dictEnabled.contains(p.rawValue) { return }
        if on { dictEnabled.insert(p.rawValue) }
        else { dictEnabled.remove(p.rawValue) }
    }

    func setDictDefault(_ p: DictionaryProviderID) {
        if !dictEnabled.contains(p.rawValue) { dictEnabled.insert(p.rawValue) }
        dictProvider = p
    }

    func dictReady(_ p: DictionaryProviderID) -> Bool {
        switch p {
        case .freeDictionary:
            return true
        case .youdao:
            return !youdaoAppKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                && !youdaoSecret.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        case .baidu:
            return !baiduAppID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                && !baiduSecret.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        case .caiyun:
            return !caiyunToken.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
    }

    /// 被 Config+Providers 的就绪判定用。
    func blank(_ s: String) -> Bool {
        s.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// 内置翻译引擎是否已配好可启用。免密钥的（Apple、Google 免费、Bing、MyMemory 等）恒为就绪。
    func builtinReady(_ p: ProviderID) -> Bool {
        switch p {
        case .googleCloud: return !blank(googleCloudKey)
        case .deepl: return !blank(deeplKey)
        case .microsoft: return !blank(microsoftKey)
        case .baidu: return !blank(baiduAppID) && !blank(baiduSecret)
        case .youdao: return !blank(youdaoAppKey) && !blank(youdaoSecret)
        case .caiyun: return !blank(caiyunToken)
        default: return true
        }
    }

    /// AI 提供商是否已配好可启用：填了 Base URL，且有 Key（本地免密钥的除外）。
    func aiReady(_ p: AIProfile) -> Bool {
        let preset = AIPresetDef.find(p.preset)
        if blank(aiKey(for: p)) && !(preset?.noKey ?? false) { return false }
        return !blank(p.baseURL)
    }

    /// 识别提供商是否已配好可启用。
    func asrProfileReady(_ p: ASRProfile) -> Bool {
        if ASRPresetDef.find(p.preset)?.interpWire != nil {
            return (try? interpConfig(selection: p.id, target: .en, audio: false, withTerms: false)) != nil
        }
        return (try? asrWhisperConfig(selection: p.id)) != nil
    }

    /// 朗读提供商是否已配好可启用：有接口地址，且有 Key（本地免密钥的除外）。
    func ttsReady(_ p: TTSProfile) -> Bool {
        let preset = TTSPresetDef.find(p.preset)
        let synced = p.syncAI ? syncedAIProfile(preset: preset?.aiPreset ?? "") : nil
        let key = (p.syncAI ? syncedAIKey(preset: preset?.aiPreset ?? "") : nil) ?? ttsKey(for: p)
        if blank(key) && !(preset?.noKey ?? false) { return false }
        var base = p.baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        if base.isEmpty { base = synced?.baseURL.trimmingCharacters(in: .whitespacesAndNewlines) ?? "" }
        if base.isEmpty { base = preset?.baseURL ?? "" }
        return !blank(base)
    }

    /// 守不变式：启用 ⇒ 已就绪。清掉未就绪却被标为启用的（旧数据，或密钥被清空）。
    func enforceReadyInvariant() {
        for p in ProviderID.allCases where isProviderOn(p) && !builtinReady(p) {
            setProviderOn(p, false)
        }
        if ProviderID.allCases.allSatisfy({ !isProviderOn($0) }), !aiProfiles.contains(where: \.enabled) {
            setProviderOn(.googleFree, true)
        }
        for p in OCRProviderID.allCases where isOCROn(p) && !ocrReady(p) {
            ocrEnabled.remove(p.rawValue)
            ocrOrder.removeAll { $0 == p.rawValue }
        }
        if ocrEnabled.isEmpty {
            ocrEnabled.insert(OCRProviderID.appleVision.rawValue)
            if !ocrOrder.contains(OCRProviderID.appleVision.rawValue) {
                ocrOrder.insert(OCRProviderID.appleVision.rawValue, at: 0)
            }
        }
        for p in DictionaryProviderID.allCases where isDictOn(p) && !dictReady(p) {
            dictEnabled.remove(p.rawValue)
        }
        if dictEnabled.isEmpty { dictEnabled.insert(DictionaryProviderID.freeDictionary.rawValue) }
        for i in aiProfiles.indices where aiProfiles[i].enabled && !aiReady(aiProfiles[i]) {
            setAIOn(at: i, false)
        }
        for i in asrProfiles.indices where asrProfiles[i].enabled && !asrProfileReady(asrProfiles[i]) {
            asrProfiles[i].enabled = false
        }
        for i in ttsProfiles.indices where ttsProfiles[i].enabled && !ttsReady(ttsProfiles[i]) {
            ttsProfiles[i].enabled = false
        }
    }

    /// 这次查词要用的几家。免费只有默认那一家。
    func activeDictionaryProviders() -> [DictionaryProviderID] {
        let ready = DictionaryProviderID.allCases.filter { isDictOn($0) && dictReady($0) }
        if Pro.unlocked {
            guard ready.contains(dictProvider) else { return ready }
            return [dictProvider] + ready.filter { $0 != dictProvider }
        }
        if isDictOn(dictProvider), dictReady(dictProvider) { return [dictProvider] }
        return []
    }

}
