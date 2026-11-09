import SwiftUI

/// 「更多 › 语音」。内容就是原来放在设置里的那一页：三种模式、听、译、润色。
struct VoiceSettingsPage: View {
    @EnvironmentObject private var config: AppConfig

    var body: some View {
        let _ = config.appLanguage
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(L("语音"))
                        .font(Theme.TypeScale.title)
                    Text(PreferencesTab.voice.blurb)
                        .font(Theme.TypeScale.caption)
                        .foregroundStyle(.secondary)
                }
                VoiceSettingsBody()
            }
            .frame(maxWidth: .infinity, alignment: .topLeading)
            .padding(.horizontal, 28)
            .padding(.top, 36)
            .padding(.bottom, 28)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Theme.windowFill)
        .controlSize(.small)
    }
}

/// 语音页的内容。主窗口「更多 › 语音」用这一份，设置里不再放一份。
struct VoiceSettingsBody: View {
    @EnvironmentObject private var config: AppConfig

    private var dictateEngine: String {
        config.dictateEngineID.isEmpty ? (config.liveASRChoices().first?.id ?? "apple") : config.dictateEngineID
    }

    var body: some View {
        let _ = config.appLanguage
        VStack(alignment: .leading, spacing: 18) {
            HStack {
                Spacer(minLength: 0)
                Toggle("", isOn: $config.dictateEnabled)
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .controlSize(.small)
                    .accessibilityLabel(L("语音"))
            }
            .padding(.top, -28)

            voiceModeCards

            SettingsGroups.group(L("听")) {
                SettingsGroups.row(L("识别")) {
                    Menu {
                        Button(L("自动（第一个可用）")) { config.dictateEngineID = "" }
                        ForEach(config.liveASRChoices()) { choice in
                            Button(choice.name) { config.dictateEngineID = choice.id }
                        }
                    } label: {
                        let name = config.dictateEngineID.isEmpty
                            ? L("自动（第一个可用）")
                            : (config.liveASRChoices().first { $0.id == config.dictateEngineID }?.name ?? L("自动（第一个可用）"))
                        SettingsGroups.menuLabel(name)
                    }
                    .menuStyle(.borderlessButton)
                    .fixedSize()
                }
                SettingsGroups.row(L("识别语言")) {
                    Menu {
                        ForEach(ASRLanguage.available(apple: config.isSystemASR(dictateEngine))) { lang in
                            Button(lang.title) { config.dictateLocaleID = lang.id }
                        }
                    } label: {
                        let title = ASRLanguage.available(apple: config.isSystemASR(dictateEngine))
                            .first { $0.id == config.dictateLocaleID }?.title ?? L("跟随系统")
                        SettingsGroups.menuLabel(title)
                    }
                    .menuStyle(.borderlessButton)
                    .fixedSize()
                }
                SettingsGroups.row(L("麦克风")) {
                    dictateInputMenu
                }
            }
            SettingsGroups.group(L("译")) {
                SettingsGroups.row(L("译成")) {
                    Menu {
                        Button(L("跟随设置里的目标语言")) { config.dictateTargetLanguage = .auto }
                        ForEach(TargetLanguage.specific) { lang in
                            Button(lang.menuTitle) { config.dictateTargetLanguage = lang }
                        }
                    } label: {
                        SettingsGroups.menuLabel(config.dictateTargetLanguage == .auto
                                  ? L("跟随设置里的目标语言")
                                  : config.dictateTargetLanguage.menuTitle)
                    }
                    .menuStyle(.borderlessButton)
                    .fixedSize()
                }
                SettingsGroups.row(L("翻译服务")) {
                    Menu {
                        ForEach(config.catalogTargets()) { target in
                            Button(target.displayName) {
                                config.setTranslateIDs([target.id], .dictate)
                            }
                        }
                    } label: {
                        let id = config.storedTranslateIDs(.dictate).first ?? ""
                        SettingsGroups.menuLabel(config.catalogTargets().first { $0.id == id }?.displayName
                                  ?? config.catalogTargets().first?.displayName
                                  ?? L("Google (免费)"))
                    }
                    .menuStyle(.borderlessButton)
                    .fixedSize()
                }
            }
            SettingsGroups.group(L("润色")) {
                SettingsGroups.row(L("松开后润色"), detail: L("去掉口头禅，把停顿收成句子。没有 AI 时不改字")) {
                    Toggle("", isOn: $config.voicePolish)
                        .labelsHidden()
                        .toggleStyle(.switch)
                        .controlSize(.small)
                }
                if config.voicePolish {
                    SettingsGroups.row(L("风格")) {
                        PillSegmented(
                            selection: $config.voicePolishStyle,
                            options: [
                            (VoicePolishStyle.clean, L("收干净")),
                            (.formal, L("书面")),
                            (.brief, L("简洁")),
                            (.custom, L("自己写")),
                        ]
                        )
                    }
                    if config.voicePolishStyle == .custom {
                        SettingsGroups.field(L("自己的要求")) {
                            TextField("", text: $config.voicePolishNote)
                                .textFieldStyle(.roundedBorder)
                                .frame(width: SettingsMetrics.controlWidth)
                        }
                    }
                }
            }
            SettingsGroups.group(L("切换快捷键")) {
                voiceHotkeyRow(.voiceRecognize, spec: $config.hotkeyVoiceRecognize)
                voiceHotkeyRow(.voiceTranslate, spec: $config.hotkeyVoiceTranslate)
                voiceHotkeyRow(.voiceInterpret, spec: $config.hotkeyVoiceInterpret)
            }
            Text(L("快捷键只切换模式，不开始听。按住 Fn 走当前这一条。"))
                .font(Theme.TypeScale.caption)
                .foregroundStyle(.secondary)
                .padding(.top, -10)
        }
    }

    private var voiceModeCards: some View {
        HStack(alignment: .top, spacing: 10) {
            ForEach(VoiceMode.allCases) { mode in
                let on = config.voiceMode == mode
                Button {
                    config.voiceMode = mode
                } label: {
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text(mode.title)
                                .font(Theme.TypeScale.body)
                                .fontWeight(on ? .semibold : .regular)
                            Spacer(minLength: 4)
                            Text(voiceModeKeys(mode))
                                .font(Theme.TypeScale.micro)
                                .foregroundStyle(.secondary)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(Capsule().fill(Theme.wellFill))
                        }
                        Text(voiceModeDetail(mode))
                            .font(Theme.TypeScale.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(
                        RoundedRectangle(cornerRadius: Theme.cardRadius, style: .continuous)
                            .fill(Theme.cardFill)
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: Theme.cardRadius, style: .continuous)
                            .strokeBorder(on ? Theme.accent : Theme.hairline, lineWidth: on ? 1.5 : 0.5)
                    )
                    .contentShape(RoundedRectangle(cornerRadius: Theme.cardRadius, style: .continuous))
                }
                .buttonStyle(.plain)
            }
        }
    }

    private func voiceModeKeys(_ mode: VoiceMode) -> String {
        switch mode {
        case .recognize: return config.hotkeyVoiceRecognize.display
        case .translate: return config.hotkeyVoiceTranslate.display
        case .interpret: return config.hotkeyVoiceInterpret.display
        }
    }

    private func voiceModeDetail(_ mode: VoiceMode) -> String {
        switch mode {
        case .recognize: return L("写下听到的字")
        case .translate: return L("边听边出译文，松开写入")
        case .interpret: return L("说完一句就读出译文")
        }
    }

    private var dictateInputMenu: some View {
        let devices = MicInput.devices()
        return Menu {
            Button(L("系统默认")) { config.dictateInputUID = "" }
            ForEach(devices) { device in
                Button(device.name) { config.dictateInputUID = device.uid }
            }
            if !config.dictateInputUID.isEmpty, !devices.contains(where: { $0.uid == config.dictateInputUID }) {
                Button(L("已断开")) {}
                    .disabled(true)
            }
        } label: {
            let name = devices.first { $0.uid == config.dictateInputUID }?.name
                ?? (config.dictateInputUID.isEmpty ? L("系统默认") : L("已断开"))
            SettingsGroups.menuLabel(name)
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
    }

    private func voiceHotkeyRow(_ action: HotkeyAction, spec: Binding<HotkeySpec>) -> some View {
        HotkeyRecorderButton(
            action: action,
            enabled: .constant(true),
            spec: spec,
            conflictWarning: config.hotkeyConflictWarning(for: action),
            showsToggle: false,
            onChange: { config.setHotkey($0, for: action) }
        ) {
            EmptyView()
        }
    }
}

/// 设置页那一套圆角列表。语音页挪到主窗口后还用同一套，不另写一份行。
enum SettingsGroups {
    static func group<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            if !title.isEmpty {
                Text(title)
                    .font(Theme.TypeScale.caption)
                    .foregroundStyle(.secondary)
                    .padding(.leading, 12)
            }
            VStack(alignment: .leading, spacing: 0) {
                content()
            }
            .background(
                RoundedRectangle(cornerRadius: Theme.cardRadius, style: .continuous)
                    .fill(Theme.cardFill)
            )
            .overlay(
                RoundedRectangle(cornerRadius: Theme.cardRadius, style: .continuous)
                    .strokeBorder(Theme.hairline, lineWidth: 0.5)
            )
            .clipShape(RoundedRectangle(cornerRadius: Theme.cardRadius, style: .continuous))
        }
    }

    static func row<Control: View>(
        _ title: String,
        detail: String? = nil,
        @ViewBuilder control: () -> Control
    ) -> some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(Theme.TypeScale.body)
                    .foregroundStyle(.primary)
                if let detail, !detail.isEmpty {
                    Text(detail)
                        .font(Theme.TypeScale.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 12)
            control()
        }
        .padding(.horizontal, 14)
        .frame(minHeight: 38)
        .overlay(alignment: .bottom) {
            Rectangle().fill(Theme.hairline).frame(height: 0.5).padding(.leading, 14)
        }
    }

    static func field<Control: View>(_ title: String, @ViewBuilder control: () -> Control) -> some View {
        HStack(alignment: .center, spacing: 12) {
            Text(title)
                .font(Theme.TypeScale.body)
                .foregroundStyle(.primary)
                .frame(maxWidth: .infinity, alignment: .leading)
            control()
        }
        .padding(.horizontal, 12)
        .frame(minHeight: 38)
    }

    static func menuLabel(_ text: String) -> some View {
        HStack(spacing: 4) {
            Text(text)
                .font(Theme.TypeScale.body)
                .foregroundStyle(.primary)
            Image(systemName: "chevron.up.chevron.down")
                .font(Theme.TypeScale.micro)
                .foregroundStyle(.secondary)
        }
    }
}
