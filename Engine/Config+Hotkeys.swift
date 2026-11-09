import Foundation

/// Hotkeys: part of AppConfig.
extension AppConfig {
    func isFeatureEnabled(_ action: HotkeyAction) -> Bool {
        switch action {
        case .voiceRecognize, .voiceTranslate, .voiceInterpret:
            return dictateEnabled
        default:
            return featureEnabled[action.rawValue] ?? true
        }
    }

    func setFeatureEnabled(_ on: Bool, for action: HotkeyAction) {
        var next = featureEnabled
        next[action.rawValue] = on
        featureEnabled = next
        guard hotkeysReady else { return }
        UserDefaults.standard.set(on, forKey: action.enabledKey)
        NotificationCenter.default.post(name: .korgiHotkeysDidChange, object: nil)
    }

    func hotkey(for action: HotkeyAction) -> HotkeySpec {
        switch action {
        case .select: return hotkeySelect
        case .clipboard: return hotkeyClipboard
        case .ocr: return hotkeyOCR
        case .file: return hotkeyFile
        case .liveCaptions: return hotkeyLiveCaptions
        case .mediaCaptions: return hotkeyMediaCaptions
        case .dictionary: return hotkeyDictionary
        case .history: return hotkeyHistory
        case .quickTranslate: return hotkeyQuick
        case .quickUndo: return hotkeyQuickUndo
        case .voiceRecognize: return hotkeyVoiceRecognize
        case .voiceTranslate: return hotkeyVoiceTranslate
        case .voiceInterpret: return hotkeyVoiceInterpret
        }
    }

    func setHotkey(_ spec: HotkeySpec, for action: HotkeyAction) {
        switch action {
        case .select: hotkeySelect = spec
        case .clipboard: hotkeyClipboard = spec
        case .ocr: hotkeyOCR = spec
        case .file: hotkeyFile = spec
        case .liveCaptions: hotkeyLiveCaptions = spec
        case .mediaCaptions: hotkeyMediaCaptions = spec
        case .dictionary: hotkeyDictionary = spec
        case .history: hotkeyHistory = spec
        case .quickTranslate: hotkeyQuick = spec
        case .quickUndo: hotkeyQuickUndo = spec
        case .voiceRecognize: hotkeyVoiceRecognize = spec
        case .voiceTranslate: hotkeyVoiceTranslate = spec
        case .voiceInterpret: hotkeyVoiceInterpret = spec
        }
    }

    func resetHotkeysToDefaults() {
        hotkeySelect = .selectDefault
        hotkeyClipboard = .clipboardDefault
        hotkeyOCR = .ocrDefault
        hotkeyFile = .fileDefault
        hotkeyLiveCaptions = .liveCaptionsDefault
        hotkeyMediaCaptions = .mediaCaptionsDefault
        hotkeyDictionary = .dictionaryDefault
        hotkeyHistory = .historyDefault
        hotkeyQuick = .quickTranslateDefault
        hotkeyQuickUndo = .quickUndoDefault
        hotkeyVoiceRecognize = .voiceRecognizeDefault
        hotkeyVoiceTranslate = .voiceTranslateDefault
        hotkeyVoiceInterpret = .voiceInterpretDefault
    }

    /// Conflict among our hotkeys only (no Carbon status).
    func hotkeyInternalConflict(for action: HotkeyAction) -> String? {
        let mine = hotkey(for: action)
        let others: [(HotkeyAction, HotkeySpec)] = HotkeyAction.allCases
            .filter { $0 != action && isFeatureEnabled($0) }
            .map { ($0, hotkey(for: $0)) }
        guard isFeatureEnabled(action) else { return nil }
        if let hit = others.first(where: { $0.1 == mine }) {
            return String(format: L("与「%@」冲突（%@）"), String(describing: hit.0.title), String(describing: mine.display))
        }
        return nil
    }

    /// Prefs UI: internal conflict first, else Carbon/system register warning.
    func hotkeyConflictWarning(for action: HotkeyAction) -> String? {
        if let c = hotkeyInternalConflict(for: action) { return c }
        let sys = hotkeySystemWarnings[action.rawValue] ?? ""
        return sys.isEmpty ? nil : sys
    }

    func persistHotkey(_ action: HotkeyAction, _ spec: HotkeySpec) {
        guard hotkeysReady else { return }
        if let data = try? JSONEncoder().encode(spec) {
            UserDefaults.standard.set(data, forKey: action.defaultsKey)
        }
        NotificationCenter.default.post(name: .korgiHotkeysDidChange, object: nil)
    }

    static func loadHotkey(_ action: HotkeyAction, defaults d: UserDefaults) -> HotkeySpec {
        if let data = d.data(forKey: action.defaultsKey),
           let spec = try? JSONDecoder().decode(HotkeySpec.self, from: data) {
            return spec
        }
        return action.default
    }
}
