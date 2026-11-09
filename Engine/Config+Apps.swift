import Foundation

/// Apps: part of AppConfig.
extension AppConfig {
    /// 润色用的 AI。语音页上的翻译若是 AI 就用它，否则用目录里第一家已经填了密钥的。
    func voicePolishProfile(bundleID: String? = nil) -> AIProfile? {
        if let target = dictateTranslateTarget(bundleID: bundleID), case .ai(let profile) = target, profile.enabled,
           !aiKey(for: profile).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return profile
        }
        return aiProfiles.first {
            $0.enabled && !aiKey(for: $0).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
    }

    /// 笔记用的 AI。这一路选中的翻译若是 AI 就用它，否则用目录里第一家已经填了密钥的。
    func sessionNoteProfile(preferredID: String?) -> AIProfile? {
        if let preferredID,
           let profile = aiProfiles.first(where: { "ai:\($0.id)" == preferredID }),
           profile.enabled,
           !aiKey(for: profile).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return profile
        }
        return aiProfiles.first {
            $0.enabled && !aiKey(for: $0).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
    }

    func quickAppRule(bundleID: String?) -> QuickAppRule? {
        guard let bundleID, !bundleID.isEmpty else { return nil }
        return quickAppRules.first { $0.bundleID == bundleID }
    }

    /// 这个来源应用里，某一条触发是不是开着。三条各看自己那份名单。
    func isAppOn(_ trigger: AppTrigger, bundleID: String?) -> Bool {
        guard let bundleID, !bundleID.isEmpty else { return true }
        switch trigger {
        case .select: return !selectExcludedApps.contains(bundleID)
        case .quick: return !quickExcludedApps.contains(bundleID)
        case .voice: return !voiceExcludedApps.contains(bundleID)
        }
    }

    func setAppOn(_ trigger: AppTrigger, bundleID: String?, _ on: Bool) {
        guard let bundleID, !bundleID.isEmpty else { return }
        var list = excludedApps(trigger)
        if on {
            list.removeAll { $0 == bundleID }
        } else if !list.contains(bundleID) {
            list.append(bundleID)
        }
        switch trigger {
        case .select: selectExcludedApps = list
        case .quick: quickExcludedApps = list
        case .voice: voiceExcludedApps = list
        }
    }

    /// 这个来源应用关掉了哪几条。
    func closedTriggers(bundleID: String?) -> [AppTrigger] {
        AppTrigger.allCases.filter { !isAppOn($0, bundleID: bundleID) }
    }

    func excludedApps(_ trigger: AppTrigger) -> [String] {
        switch trigger {
        case .select: return selectExcludedApps
        case .quick: return quickExcludedApps
        case .voice: return voiceExcludedApps
        }
    }

    /// 应用自己选的那一家是不是还在目录里。不在就算没配，退回默认。
    private func appTarget(_ choice: QuickAppTarget) -> TranslateTarget? {
        guard !choice.isEmpty else { return nil }
        return catalogTargets().first { $0.id == choice.providerID }
    }

    /// 给一家 AI 换上应用自己的模型。别的供应商没有模型可言。
    private func applying(_ model: String, to target: TranslateTarget) -> TranslateTarget {
        let m = model.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !m.isEmpty, case .ai(var profile) = target else { return target }
        profile.model = m
        return .ai(profile)
    }

    /// 快捷翻译实际使用的那一家。应用有自己的供应商就用那家；关了或不能用时，用打开名单里的第一家。
    func quickTranslateTarget(bundleID: String? = nil) -> TranslateTarget? {
        let enabled = catalogTargets()
        let rule = quickAppRule(bundleID: bundleID)
        let id = rule?.quick.providerID ?? ""
        let preferred = (id.isEmpty ? quickProviderID : id)
        let picked: TranslateTarget?
        if !preferred.isEmpty, let match = enabled.first(where: { $0.id == preferred }) {
            picked = match
        } else {
            picked = enabled.first
        }
        guard let picked else { return nil }
        // 只有应用自己点的那家还在时，它存的模型才算数。
        guard rule?.quick.providerID == picked.id else { return picked }
        return applying(rule?.quick.model ?? "", to: picked)
    }

    /// 划词实际跑的那几家。应用指定了一家并还在目录里时，只跑这一家。
    func selectTranslateTargets(bundleID: String?) -> [TranslateTarget] {
        let defaults = translateTargets(.select)
        guard let rule = quickAppRule(bundleID: bundleID),
              let target = appTarget(rule.select) else { return defaults }
        return [applying(rule.select.model, to: target)]
    }

    /// 按住 Fn 时用的那一家。应用指定了语音那一家就用它。
    func dictateTranslateTarget(bundleID: String? = nil) -> TranslateTarget? {
        if let rule = quickAppRule(bundleID: bundleID), let target = appTarget(rule.voice) {
            return applying(rule.voice.model, to: target)
        }
        return translateTargets(.dictate).first
    }

    /// 按住 Fn 时走的模式。应用自己指定了就用应用的那条，否则跟语音页上的。
    func resolvedVoiceMode(bundleID: String?) -> VoiceMode {
        guard let raw = quickAppRule(bundleID: bundleID)?.voiceMode, !raw.isEmpty else { return voiceMode }
        return VoiceMode(rawValue: raw) ?? voiceMode
    }

    /// 这个应用自己存的目标语言。留空或跟随语音页时返回 nil。
    func quickTargetLanguage(bundleID: String?) -> TargetLanguage? {
        guard let raw = quickAppRule(bundleID: bundleID)?.language, !raw.isEmpty else { return nil }
        guard let lang = TargetLanguage(rawValue: raw), lang != .auto else { return nil }
        return lang
    }

    /// 来源应用的目标语言。应用规则跟随语音页时用语音页的；没有单独配置时用设置里的目标语言。
    func appTargetLanguage(bundleID: String?) -> TargetLanguage {
        if quickAppRule(bundleID: bundleID)?.language == QuickAppRule.followVoice {
            return voiceTargetLanguage
        }
        return quickTargetLanguage(bundleID: bundleID) ?? targetLanguage.resolvedDestination
    }

    /// 语音用的目标语言。来源应用自己指定的最优先，其次是语音页选的，最后跟设置里的目标语言。
    func resolvedDictateTarget(bundleID: String?) -> TargetLanguage {
        quickTargetLanguage(bundleID: bundleID) ?? voiceTargetLanguage
    }
}
