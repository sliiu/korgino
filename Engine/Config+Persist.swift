import Foundation

/// Persist: part of AppConfig.
extension AppConfig {
    func setASRPreset(_ preset: ASRPreset, on: Bool) {
        var next = asrPresets
        if on {
            if !next.contains(preset.rawValue) { next.append(preset.rawValue) }
        } else {
            next.removeAll { $0 == preset.rawValue }
        }
        asrPresets = next
    }

    func syncAppleLanguages() {
        if appLanguage == .system {
            UserDefaults.standard.removeObject(forKey: ConfigKeys.appleLanguages)
        } else {
            UserDefaults.standard.set([appLanguage.code], forKey: ConfigKeys.appleLanguages)
        }
    }

    /// Decode older AIProfile without `preset` field.
    static func normalizeProfile(_ p: AIProfile) -> AIProfile {
        var p = p
        if p.preset.isEmpty, AIPresetDef.presetIDs.contains(p.id) {
            p.preset = p.id
        }
        return p
    }

    func saveSets() {
        let d = UserDefaults.standard
        d.set(Array(enabledProviders), forKey: ConfigKeys.enabledProviders)
        d.set(Array(activeSimultaneous), forKey: ConfigKeys.activeSimultaneous)
    }

    func saveUses() {
        let d = UserDefaults.standard
        d.set(selectTranslateIDs, forKey: ConfigKeys.use_select)
        d.set(clipboardTranslateIDs, forKey: ConfigKeys.use_clipboard)
        d.set(ocrTranslateIDs, forKey: ConfigKeys.use_ocr)
        d.set(fileTranslateIDs, forKey: ConfigKeys.use_file)
        d.set(dictateTranslateID, forKey: ConfigKeys.use_dictateTranslate)
        d.set(liveDefaultAsrID, forKey: ConfigKeys.live_defaultAsr)
        d.set(liveDefaultTranslateID, forKey: ConfigKeys.use_liveTranslate)
        d.set(mediaDefaultAsrID, forKey: ConfigKeys.media_asrEngine)
        d.set(mediaDefaultTranslateID, forKey: ConfigKeys.use_mediaTranslate)
    }

    /// 老的「勾上即一起用」拆成目录和各功能默认。只跑一次。
    func seedFeatureDefaultsIfNeeded() {
        let d = UserDefaults.standard
        let flag = "didSeedFeatureUses_v1"
        guard !d.bool(forKey: flag) else { return }
        d.set(true, forKey: flag)
        let ordered = checkedTargets().map(\.id).filter { id in
            availableTargets().contains { $0.id == id }
        }
        let pair = Array(ordered.prefix(2))
        let first = ordered.first ?? ""
        let quick = d.string(forKey: ConfigKeys.quickProviderID) ?? ""
        selectTranslateIDs = pair
        clipboardTranslateIDs = pair
        ocrTranslateIDs = pair
        fileTranslateIDs = first.isEmpty ? [] : [first]
        dictateTranslateID = quick.isEmpty ? first : quick
        liveDefaultTranslateID = first
        mediaDefaultTranslateID = first
        d.set(pair, forKey: ConfigKeys.use_select)
        d.set(pair, forKey: ConfigKeys.use_clipboard)
        d.set(pair, forKey: ConfigKeys.use_ocr)
        d.set(first.isEmpty ? [String]() : [first], forKey: ConfigKeys.use_file)
        d.set(dictateTranslateID, forKey: ConfigKeys.use_dictateTranslate)
        d.set(liveDefaultAsrID, forKey: ConfigKeys.live_defaultAsr)
        d.set(first, forKey: ConfigKeys.use_liveTranslate)
        d.set(mediaDefaultAsrID, forKey: ConfigKeys.media_asrEngine)
        d.set(first, forKey: ConfigKeys.use_mediaTranslate)
    }

    func persistProfiles() {
        if let data = try? JSONEncoder().encode(aiProfiles) {
            UserDefaults.standard.set(data, forKey: ConfigKeys.aiProfiles)
        }
    }
}
