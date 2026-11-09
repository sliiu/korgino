import SwiftUI

/// 当次换的模型。键是 AI 配置的 id，值是模型 id。只在内存里，不写回设置（docs/adr/0053）。
typealias ModelOverrides = [String: String]

extension AIProfile {
    /// 同一份配置换一个模型。密钥按配置 id 取，不受影响。
    func withModel(_ model: String?) -> AIProfile {
        guard let model, !model.isEmpty else { return self }
        var p = self
        p.model = model
        return p
    }
}

extension TranslateTarget {
    var aiProfile: AIProfile? {
        if case .ai(let p) = self { return p }
        return nil
    }

    func applying(_ overrides: ModelOverrides) -> TranslateTarget {
        guard case .ai(let p) = self, let m = overrides[p.id] else { return self }
        return .ai(p.withModel(m))
    }
}

extension Dictionary where Key == String, Value == String {
    /// 选回设置里的那个模型就等于没换。
    mutating func setModel(_ model: String?, for profile: AIProfile) {
        let m = model?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if m.isEmpty || m == profile.model {
            removeValue(forKey: profile.id)
        } else {
            self[profile.id] = m
        }
    }
}

enum ModelChoices {
    /// 设置里的模型在最前，后面是拉取过的列表。
    static func models(for profile: AIProfile, current: String?) -> [String] {
        var out: [String] = []
        for m in [profile.model, current ?? ""] + ModelListFetcher.cached(profileID: profile.id) {
            let t = m.trimmingCharacters(in: .whitespacesAndNewlines)
            if !t.isEmpty && !out.contains(t) { out.append(t) }
        }
        return out
    }

    static func short(_ model: String, limit: Int = 24) -> String {
        model.truncatedInside(limit)
    }
}

/// 菜单里点「刷新模型列表」的进度和结果。拉到的列表照旧存在 `ModelListFetcher` 里。
@MainActor
final class ModelListRefresh: ObservableObject {
    static let shared = ModelListRefresh()
    @Published private(set) var fetching: Set<String> = []
    @Published private(set) var errors: [String: String] = [:]
    /// 拉到新列表时加一，菜单跟着重画。
    @Published private(set) var version = 0

    func refresh(_ profile: AIProfile) {
        guard !fetching.contains(profile.id) else { return }
        let p = profile
        let key = AppConfig.shared.aiKey(for: p)
        let noKey = AIPresetDef.find(p.preset)?.noKey ?? false
        fetching.insert(p.id)
        errors[p.id] = nil
        Task { @MainActor in
            defer { fetching.remove(p.id) }
            do {
                let models = try await Background.run {
                    try await ModelListFetcher.fetch(baseURL: p.baseURL, apiKey: key, allowEmptyKey: noKey)
                }
                ModelListFetcher.store(profileID: p.id, baseURL: p.baseURL, models: models)
                version += 1
            } catch {
                errors[p.id] = error.localizedDescription
            }
        }
    }
}

/// 一份 AI 配置的模型列表，放进别的菜单里用。选回设置里的模型就清掉临时的。
struct ModelOverrideItems: View {
    let profile: AIProfile
    @Binding var override: String?
    @ObservedObject private var lists = ModelListRefresh.shared

    var body: some View {
        let current = override ?? profile.model
        let _ = lists.version
        let fetching = lists.fetching.contains(profile.id)
        Section(L("模型")) {
            Picker(L("模型"), selection: Binding(
                get: { current },
                set: { override = $0 == profile.model ? nil : $0 }
            )) {
                ForEach(ModelChoices.models(for: profile, current: override), id: \.self) { m in
                    Text(m == profile.model ? String(format: L("%@（设置里的）"), m) : m).tag(m)
                }
            }
            .pickerStyle(.inline)
            .labelsHidden()
        }
        Divider()
        Button(fetching ? L("正在拉取模型列表…") : L("刷新模型列表")) {
            lists.refresh(profile)
        }
        .disabled(fetching)
        if let e = lists.errors[profile.id] {
            Text(e).lineLimit(2)
        }
    }
}

/// 翻译服务旁边的模型下拉。免费时只显示设置里的模型，挂 Pro 标签。
struct ModelOverrideMenu: View {
    let profile: AIProfile
    @Binding var override: String?
    var maxWidth: CGFloat = 160
    /// 免费时挂不挂 Pro 标签。浮层里每家都挂太吵，只显示模型。
    var freeBadge = true
    @ObservedObject private var pro = Pro.shared
    @ObservedObject private var lists = ModelListRefresh.shared

    var body: some View {
        let current = override ?? profile.model
        let _ = lists.version
        if Pro.unlocked {
            Menu {
                ModelOverrideItems(profile: profile, override: $override)
            } label: {
                Text(ModelChoices.short(current))
                    .font(.system(size: 11))
                    .foregroundStyle(override == nil ? Color.secondary : Color.accentColor)
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.visible)
            .fixedSize()
            .frame(maxWidth: maxWidth, alignment: .leading)
            .help(override == nil
                  ? L("这次换一个模型，不改设置")
                  : String(format: L("这次用 %@，设置里仍是 %@"), current, profile.model))
        } else {
            HStack(spacing: 4) {
                Text(ModelChoices.short(current))
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                if freeBadge {
                    ProBadge(help: L("Pro 可以这次换一个模型"))
                }
            }
            .fixedSize()
        }
    }
}

extension Binding where Value == ModelOverrides {
    /// 把一份配置的那一格拆成 `String?`。
    func model(for profile: AIProfile) -> Binding<String?> {
        Binding<String?>(
            get: { wrappedValue[profile.id] },
            set: { wrappedValue.setModel($0, for: profile) }
        )
    }
}
