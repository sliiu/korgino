import AppKit
import SwiftUI

/// 每个来源应用自己的一套快捷配置。开关仍记在排除名单里，其余记在 `QuickAppRule`。
struct QuickAppsSection: View {
    @ObservedObject private var config = AppConfig.shared
    @State private var expanded: Set<String> = []

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            SettingsGroup(title: "") {
                let apps = visibleApps()
                if apps.isEmpty {
                    Text(L("还没有单独配置的应用"))
                        .font(Theme.TypeScale.body)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 14)
                        .frame(minHeight: SettingsChrome.rowMinHeight)
                }
                ForEach(apps, id: \.bundleID) { app in
                    appCard(app)
                }
                Button {
                    addApps()
                } label: {
                    Text(L("＋ 添加应用…"))
                        .font(Theme.TypeScale.body)
                        .foregroundStyle(Theme.accent)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 14)
                        .frame(minHeight: SettingsChrome.rowMinHeight)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            Text(L("三条开关各自管各自：关掉的触发在这个应用里不动，划词插件跟划词一起。默认提供商和下面几项留空就跟随设置里各页自己的默认。"))
                .font(Theme.TypeScale.caption)
                .foregroundStyle(.secondary)
                .padding(.top, -4)
        }
    }

    // MARK: 名单

    private struct AppRow: Identifiable {
        var bundleID: String
        var name: String
        var icon: NSImage?
        var installed: Bool
        var id: String { bundleID }
    }

    /// 配过的、被排除的、以及默认名单里的，合起来一份，按名字排。
    /// 默认名单里没装的不列出来，但仍在名单里。
    private func visibleApps() -> [AppRow] {
        let defaults = Set(AppConfig.quickExcludedDefaults)
        var ids: [String] = config.quickAppRules.map(\.bundleID)
        for trigger in AppTrigger.allCases {
            for id in config.excludedApps(trigger) where !ids.contains(id) { ids.append(id) }
        }
        for id in AppConfig.quickExcludedDefaults where !ids.contains(id) { ids.append(id) }
        return ids.compactMap { id -> AppRow? in
            let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: id)
            if url == nil, defaults.contains(id) { return nil }
            let name = url.map { FileManager.default.displayName(atPath: $0.path) }
                .map { $0.hasSuffix(".app") ? String($0.dropLast(4)) : $0 } ?? id
            let icon = url.map { NSWorkspace.shared.icon(forFile: $0.path) }
            return AppRow(bundleID: id, name: name, icon: icon, installed: url != nil)
        }
        .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    // MARK: 一张卡

    private func appCard(_ app: AppRow) -> some View {
        let open = expanded.contains(app.bundleID)
        return VStack(alignment: .leading, spacing: 0) {
            Button {
                if open { expanded.remove(app.bundleID) } else { expanded.insert(app.bundleID) }
            } label: {
                HStack(spacing: 8) {
                    if let icon = app.icon {
                        Image(nsImage: icon)
                            .resizable()
                            .frame(width: 18, height: 18)
                    } else {
                        Image(systemName: "app.dashed")
                            .frame(width: 18, height: 18)
                            .foregroundStyle(.secondary)
                    }
                    Text(app.name)
                        .font(Theme.TypeScale.body)
                        .lineLimit(1)
                    Image(systemName: "chevron.right")
                        .font(Theme.TypeScale.micro)
                        .foregroundStyle(.tertiary)
                        .rotationEffect(.degrees(open ? 90 : 0))
                    Spacer(minLength: 8)
                    if let note = statusNote(app) {
                        Text(note)
                            .font(Theme.TypeScale.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 7)
                .frame(minHeight: SettingsChrome.rowMinHeight)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .overlay(alignment: .bottom) {
                Rectangle().fill(Theme.hairline).frame(height: 0.5)
            }
            if open {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(AppTrigger.allCases) { trigger in
                        triggerRow(app.bundleID, trigger)
                    }
                    targetRow(app.bundleID, L("划词"), L("跟随「翻译」页"), \.select)
                    targetRow(app.bundleID, L("快捷翻译"), L("跟随「翻译」页"), \.quick)
                    targetRow(app.bundleID, L("语音"), L("跟随语音页"), \.voice)
                    languageRow(app.bundleID)
                    voiceModeRow(app.bundleID)
                    pluginsRow(app.bundleID)
                    HStack {
                        Button(L("移出这个应用")) {
                            config.quickAppRules.removeAll { $0.bundleID == app.bundleID }
                            for trigger in AppTrigger.allCases {
                                config.setAppOn(trigger, bundleID: app.bundleID, true)
                            }
                            expanded.remove(app.bundleID)
                        }
                        .buttonStyle(.plain)
                        .font(Theme.TypeScale.label)
                        .foregroundStyle(Theme.danger)
                        Spacer(minLength: 0)
                    }
                    .padding(.vertical, 8)
                }
                .padding(.leading, SettingsChrome.expandLeading)
                .padding(.trailing, SettingsChrome.expandTrailing)
                .background(Theme.expandFill)
                .overlay(alignment: .top) {
                    Rectangle().fill(Theme.hairline).frame(height: 0.5)
                }
            }
        }
    }

    /// 一条触发模式自己的开关。
    private func triggerRow(_ bundleID: String, _ trigger: AppTrigger) -> some View {
        SettingsRow(title: trigger.title) {
            Toggle("", isOn: Binding(
                get: { config.isAppOn(trigger, bundleID: bundleID) },
                set: { config.setAppOn(trigger, bundleID: bundleID, $0) }
            ))
            .labelsHidden()
            .toggleStyle(.switch)
            .controlSize(.small)
        }
    }

    /// 收起时也能看出这个应用现在是什么状态。
    private func statusNote(_ app: AppRow) -> String? {
        let rule = config.quickAppRule(bundleID: app.bundleID)
        let closed = config.closedTriggers(bundleID: app.bundleID)
        var bits: [String] = []
        if !closed.isEmpty {
            bits.append(closed.map(\.title).joined(separator: "、") + L("关"))
        }
        if let rule, !isUntouched(rule) {
            bits.append(L("已单独配置"))
        } else if closed.isEmpty {
            bits.append(L("跟随默认"))
        }
        if !app.installed { bits.append(L("没装")) }
        return bits.isEmpty ? nil : bits.joined(separator: " · ")
    }

    private func isUntouched(_ rule: QuickAppRule) -> Bool {
        rule.select.isEmpty && rule.quick.isEmpty && rule.voice.isEmpty
            && rule.voiceMode.isEmpty && rule.language.isEmpty && rule.plugins.isEmpty
    }

    /// 展开区每一行都是左边标签、右边控件贴边。
    private func targetRow(
        _ bundleID: String,
        _ title: String,
        _ followTitle: String,
        _ keyPath: WritableKeyPath<QuickAppRule, QuickAppTarget>
    ) -> some View {
        let target = binding(bundleID, keyPath)
        let providers = config.catalogTargets()
        return SettingsRow(title: title) {
            HStack(spacing: 6) {
                Picker(title, selection: Binding(
                    get: { target.wrappedValue.providerID },
                    set: { id in
                        // 换了供应商，上一个供应商的模型不再适用。
                        guard id != target.wrappedValue.providerID else { return }
                        var next = target.wrappedValue
                        next.providerID = id
                        next.model = ""
                        target.wrappedValue = next
                    }
                )) {
                    Text(followTitle).tag("")
                    ForEach(providers) { p in
                        Text(p.displayName).tag(p.id)
                    }
                    let id = target.wrappedValue.providerID
                    if !id.isEmpty, !providers.contains(where: { $0.id == id }) {
                        Text(pausedTitle(id)).tag(id)
                    }
                }
                .labelsHidden()
                .fixedSize()
                if let profile = aiProfile(for: target.wrappedValue) {
                    ModelComboBox(
                        text: Binding(
                            get: { target.wrappedValue.model },
                            set: { target.wrappedValue.model = $0 }
                        ),
                        items: ModelChoices.models(for: profile, current: nil),
                        placeholder: profile.model.isEmpty ? L("跟随设置里的模型") : profile.model
                    )
                    .frame(width: 140)
                }
            }
            .frame(maxWidth: SettingsChrome.controlWidth, alignment: .trailing)
        }
    }

    private func voiceModeRow(_ bundleID: String) -> some View {
        SettingsRow(title: L("语音模式")) {
            Picker(L("语音模式"), selection: binding(bundleID, \.voiceMode)) {
                Text(L("跟随语音页")).tag("")
                ForEach(VoiceMode.allCases) { m in
                    Text(m.title).tag(m.rawValue)
                }
            }
            .labelsHidden()
            .fixedSize()
            .frame(maxWidth: SettingsChrome.controlWidth, alignment: .trailing)
        }
    }

    private func languageRow(_ bundleID: String) -> some View {
        SettingsRow(title: L("应用目标语言")) {
            Picker(L("应用目标语言"), selection: binding(bundleID, \.language)) {
                Text(L("跟随默认")).tag("")
                Text(L("跟随语音页的目标语言")).tag(QuickAppRule.followVoice)
                ForEach(TargetLanguage.specific) { lang in
                    Text(lang.menuTitle).tag(lang.rawValue)
                }
            }
            .labelsHidden()
            .fixedSize()
            .frame(maxWidth: SettingsChrome.controlWidth, alignment: .trailing)
        }
    }

    /// 划词插件：跟随插件页的勾选、这个应用里不弹、或者只弹勾上的这几个。
    private func pluginsRow(_ bundleID: String) -> some View {
        let mode = pluginModeBinding(bundleID)
        return VStack(alignment: .leading, spacing: 0) {
            SettingsRow(title: L("启用的插件"), showsDivider: mode.wrappedValue == QuickAppRule.pluginsCustom) {
                Picker(L("启用的插件"), selection: mode) {
                    Text(L("跟随默认")).tag("")
                    Text(L("不配置")).tag(QuickAppRule.pluginsNone)
                    Text(L("勾选要启用的")).tag(QuickAppRule.pluginsCustom)
                }
                .labelsHidden()
                .fixedSize()
                .frame(maxWidth: SettingsChrome.controlWidth, alignment: .trailing)
            }
            if mode.wrappedValue == QuickAppRule.pluginsCustom {
                pluginChips(bundleID)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .overlay(alignment: .bottom) {
                        Rectangle().fill(Theme.hairline).frame(height: 0.5)
                    }
            }
        }
    }

    private func pluginChips(_ bundleID: String) -> some View {
        let chosen = Set(config.quickAppRule(bundleID: bundleID)?.pluginIDs ?? [])
        let plugins = SelectionPluginStore.shared.plugins
        return FlowTags(spacing: 6) {
            ForEach(plugins) { plugin in
                let on = chosen.contains(plugin.id)
                Button {
                    var ids = config.quickAppRule(bundleID: bundleID)?.pluginIDs ?? []
                    if on { ids.removeAll { $0 == plugin.id } } else { ids.append(plugin.id) }
                    updateRule(bundleID) { $0.pluginIDs = ids }
                } label: {
                    HStack(spacing: 4) {
                        StoredSymbol(name: plugin.symbol, size: 11, font: Theme.TypeScale.micro)
                        Text(plugin.title)
                            .font(Theme.TypeScale.caption)
                    }
                    .foregroundStyle(on ? Color.white : Color.secondary)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(
                        Capsule().fill(on ? Color.accentColor : Theme.wellFill)
                    )
                }
                .buttonStyle(.plain)
                .help(plugin.prompt.isEmpty ? plugin.title : plugin.prompt)
            }
        }
    }

    // MARK: 读写

    /// 改了哪一项就补一条规则。规则里全是空的也留着，直到用户移出。
    private func binding(_ bundleID: String, _ keyPath: WritableKeyPath<QuickAppRule, String>) -> Binding<String> {
        Binding(
            get: { config.quickAppRule(bundleID: bundleID)?[keyPath: keyPath] ?? "" },
            set: { value in
                var rules = config.quickAppRules
                if let idx = rules.firstIndex(where: { $0.bundleID == bundleID }) {
                    rules[idx][keyPath: keyPath] = value
                } else {
                    var rule = QuickAppRule(bundleID: bundleID)
                    rule[keyPath: keyPath] = value
                    rules.append(rule)
                }
                config.quickAppRules = rules
            }
        )
    }

    private func binding(_ bundleID: String, _ keyPath: WritableKeyPath<QuickAppRule, QuickAppTarget>) -> Binding<QuickAppTarget> {
        Binding(
            get: { config.quickAppRule(bundleID: bundleID)?[keyPath: keyPath] ?? QuickAppTarget() },
            set: { value in
                var rules = config.quickAppRules
                if let idx = rules.firstIndex(where: { $0.bundleID == bundleID }) {
                    rules[idx][keyPath: keyPath] = value
                } else {
                    var rule = QuickAppRule(bundleID: bundleID)
                    rule[keyPath: keyPath] = value
                    rules.append(rule)
                }
                config.quickAppRules = rules
            }
        )
    }

    /// 改一条规则上的任意字段。还没有规则就补一条。
    private func updateRule(_ bundleID: String, _ change: (inout QuickAppRule) -> Void) {
        var rules = config.quickAppRules
        if let idx = rules.firstIndex(where: { $0.bundleID == bundleID }) {
            change(&rules[idx])
        } else {
            var rule = QuickAppRule(bundleID: bundleID)
            change(&rule)
            rules.append(rule)
        }
        config.quickAppRules = rules
    }

    /// 插件三态。切到「自选」时，先把插件页当前勾着的那几个带过来，不然是一片空白。
    private func pluginModeBinding(_ bundleID: String) -> Binding<String> {
        Binding(
            get: { config.quickAppRule(bundleID: bundleID)?.plugins ?? "" },
            set: { mode in
                updateRule(bundleID) { rule in
                    rule.plugins = mode
                    if mode == QuickAppRule.pluginsCustom, rule.pluginIDs.isEmpty {
                        rule.pluginIDs = SelectionPluginStore.shared.plugins.filter(\.enabled).map(\.id)
                    }
                    if mode != QuickAppRule.pluginsCustom {
                        rule.pluginIDs = []
                    }
                }
            }
        )
    }

    /// 这一格选的是不是 AI，是哪一个。选的是内置服务时没有模型可换。
    private func aiProfile(for target: QuickAppTarget) -> AIProfile? {
        guard !target.isEmpty else { return nil }
        return config.catalogTargets().first { $0.id == target.providerID }?.aiProfile
    }

    private func pausedTitle(_ id: String) -> String {
        let name: String
        if let provider = ProviderID(rawValue: id) {
            name = provider.displayName
        } else {
            name = config.aiProfiles.first { "ai:\($0.id)" == id }?.name ?? id
        }
        return String(format: L("%@（已暂停）"), name)
    }

    private func addApps() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowedContentTypes = [.application]
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.prompt = L("添加")
        guard panel.runModal() == .OK else { return }
        var rules = config.quickAppRules
        var added: [String] = []
        for url in panel.urls {
            guard let id = Bundle(url: url)?.bundleIdentifier else { continue }
            for trigger in AppTrigger.allCases {
                config.setAppOn(trigger, bundleID: id, true)
            }
            if !rules.contains(where: { $0.bundleID == id }) {
                rules.append(QuickAppRule(bundleID: id))
            }
            added.append(id)
            expanded.insert(id)
        }
        config.quickAppRules = rules
    }
}
