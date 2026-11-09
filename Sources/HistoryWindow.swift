import Combine
import AppKit
import SwiftUI

@MainActor
final class HistoryController {
    static let shared = HistoryController()
    private var window: NSWindow?
    let model = HistoryModel()

    func show(pane: HistoryModel.Pane = .history) {
        model.pane = pane
        model.reload()
        if window == nil {
            let hc = NSHostingController(rootView: HistoryFavoritesView(model: model))
            hc.sceneBridgingOptions = [.toolbars]
            let w = NSWindow(contentViewController: hc)
            w.title = L("历史和收藏")
            w.styleMask = [.titled, .closable, .resizable, .miniaturizable, .fullSizeContentView]
            w.toolbarStyle = .unified
            w.isReleasedWhenClosed = false
            w.setContentSize(NSSize(width: 520, height: 600))
            // Without this the window lets itself be dragged narrower than the list and toolbar need.
            w.minSize = NSSize(width: 440, height: 420)
            w.center()
            window = w
        }
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func relocalize() {
        window?.title = L("历史和收藏")
    }

    func reshowHistory(_ e: HistoryEntry) {
        guard let app = NSApp.delegate as? AppDelegate else { return }
        app.popup.show(source: e.source, kind: e.kind, appName: e.appName, bundleID: e.bundleID, filePath: e.filePath)
        let outcomes = e.results.map {
            ProviderOutcome(id: $0.id, name: $0.name, text: $0.text, error: $0.error, loading: false)
        }
        app.popup.showMulti(MultiResult(direction: e.direction + L(" · 历史"), outcomes: outcomes))
    }

    func reshowFavorite(_ e: FavoriteEntry) {
        guard let app = NSApp.delegate as? AppDelegate else { return }
        app.popup.show(source: e.source)
        let outcomes = [
            ProviderOutcome(
                id: "favorite",
                name: e.providerName.isEmpty ? L("收藏") : e.providerName,
                text: e.translation,
                error: nil,
                loading: false
            )
        ]
        app.popup.showMulti(MultiResult(direction: e.direction + L(" · 收藏"), outcomes: outcomes))
    }
}

final class HistoryModel: ObservableObject {
    enum Pane: String, CaseIterable, Identifiable {
        case history, favorites
        var id: String { rawValue }
        var title: String {
            switch self {
            case .history: return L("历史")
            case .favorites: return L("收藏")
            }
        }
    }

    @Published var pane: Pane = .history
    @Published var entries: [HistoryEntry] = []
    /// 免费档看不到的较早几条。
    @Published var hiddenCount = 0
    @Published var favorites: [FavoriteEntry] = []

    /// 读盘在后台做：历史是整份 JSON，最多 200 条，主线程上读会让窗口僵一下。
    /// 连着来几次只认最后一次的结果。
    private var reloadGeneration = 0

    func reload() {
        reloadGeneration += 1
        let generation = reloadGeneration
        Task { @MainActor in
            let (all, kept) = await Background.run {
                (HistoryStore.load(), FavoritesStore.load())
            }
            guard generation == reloadGeneration else { return }
            entries = Pro.unlocked ? all : Array(all.prefix(Pro.freeHistoryLimit))
            hiddenCount = all.count - entries.count
            favorites = kept
        }
    }

    func clearHistory() {
        HistoryStore.clear()
        reload()
    }

    func clearFavorites() {
        FavoritesStore.clear()
        reload()
    }

    func removeFavorite(id: String) {
        FavoritesStore.remove(id: id)
        reload()
    }
}

struct HistoryFavoritesView: View {
    @ObservedObject var model: HistoryModel
    @ObservedObject private var lang = AppConfig.shared
    @State private var query = ""

    private var trimmedQuery: String { query.trimmingCharacters(in: .whitespacesAndNewlines) }

    private func matches(_ fields: [String?]) -> Bool {
        let q = trimmedQuery
        guard !q.isEmpty else { return true }
        return fields.contains { $0?.localizedCaseInsensitiveContains(q) == true }
    }

    private var filteredEntries: [HistoryEntry] {
        model.entries.filter { e in
            var fields: [String?] = [e.source, e.appName, e.filePath, kindLabel(e.kind)]
            fields.append(contentsOf: e.results.map(\.text))
            if e.kind == "file", let path = e.filePath, !path.isEmpty {
                fields.append(URL(fileURLWithPath: path).lastPathComponent)
            }
            if e.kind == "ocr" { fields.append("OCR") }
            return matches(fields)
        }
    }

    private var filteredFavorites: [FavoriteEntry] {
        model.favorites.filter { e in matches([e.source, e.translation, e.providerName]) }
    }

    private let fmt = TimeText.shortList

    var body: some View {
        let _ = lang.appLanguage
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                SearchField(text: $query, prompt: L("搜索原文、译文、应用或文件"))
                IconButton(
                    systemImage: "trash",
                    help: model.pane == .history ? L("清空历史") : L("清空收藏")
                ) {
                    if model.pane == .history { model.clearHistory() }
                    else { model.clearFavorites() }
                }
                .disabled(model.pane == .history ? model.entries.isEmpty : model.favorites.isEmpty)
            }
            .padding(.leading, 16)
            .padding(.trailing, 10)
            .padding(.vertical, 8)
            Group {
                switch model.pane {
                case .history:
                    historyList
                case .favorites:
                    favoritesList
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(minWidth: 420, maxWidth: .infinity, minHeight: 400, maxHeight: .infinity)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                PillSegmented(
                    selection: $model.pane,
                    options: HistoryModel.Pane.allCases.map { ($0, $0.title) },
                    fontSize: 12
                )
            }
            .korgiHideToolbarBackground()
        }
        .onAppear { model.reload() }
        .onReceive(NotificationCenter.default.publisher(for: Pro.changed)) { _ in model.reload() }
        .onChange(of: model.pane) { _, _ in model.reload() }
    }

    @ViewBuilder
    private var historyList: some View {
        if model.entries.isEmpty {
            ContentUnavailableView(L("暂无历史"), systemImage: "clock")
        } else if filteredEntries.isEmpty {
            ContentUnavailableView.search(text: trimmedQuery)
        } else {
            List {
                ForEach(filteredEntries) { e in
                    Button {
                        HistoryController.shared.reshowHistory(e)
                    } label: {
                        row(
                            kind: e.kind,
                            source: e.source,
                            translation: e.results.first(where: { $0.text != nil })?.text,
                            date: e.timestamp,
                            help: e.direction,
                            place: placeLabel(e),
                            bundleID: e.bundleID,
                            appName: e.appName
                        )
                    }
                    .buttonStyle(.plain)
                }
                if model.hiddenCount > 0 {
                    HStack(spacing: 6) {
                        Text(String(format: L("还有 %@ 条较早的记录"), String(model.hiddenCount)))
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                        ProBadge(help: L("Pro 能看全部历史"))
                        Spacer(minLength: 0)
                    }
                    .padding(.vertical, 4)
                }
            }
            .listStyle(.inset)
            .scrollContentBackground(.hidden)
        }
    }

    @ViewBuilder
    private var favoritesList: some View {
        if model.favorites.isEmpty {
            ContentUnavailableView(L("暂无收藏"), systemImage: "star", description: Text(L("在翻译结果旁点星标即可收藏")))
        } else if filteredFavorites.isEmpty {
            ContentUnavailableView.search(text: trimmedQuery)
        } else {
            let items = filteredFavorites
            List {
                ForEach(items) { e in
                    Button {
                        HistoryController.shared.reshowFavorite(e)
                    } label: {
                        row(
                            kind: e.kind,
                            source: e.source,
                            translation: e.translation,
                            date: e.timestamp,
                            help: [e.providerName, e.direction].filter { !$0.isEmpty }.joined(separator: " · ")
                        )
                    }
                    .buttonStyle(.plain)
                    .contextMenu {
                        Button(L("取消收藏"), role: .destructive) {
                            model.removeFavorite(id: e.id)
                        }
                    }
                }
                .onDelete { idx in
                    for i in idx {
                        model.removeFavorite(id: items[i].id)
                    }
                }
            }
            .listStyle(.inset)
            .scrollContentBackground(.hidden)
        }
    }

    private func placeLabel(_ e: HistoryEntry) -> String {
        if e.kind == "file", let path = e.filePath, !path.isEmpty {
            let name = URL(fileURLWithPath: path).lastPathComponent
            if !name.isEmpty { return name }
        }
        if let app = e.appName?.trimmingCharacters(in: .whitespacesAndNewlines), !app.isEmpty {
            return app
        }
        return kindLabel(e.kind)
    }

    private func row(kind: String, source: String, translation: String?, date: Date, help: String, place: String? = nil, bundleID: String? = nil, appName: String? = nil) -> some View {
        HStack(alignment: .top, spacing: 10) {
            leadingMark(kind: kind, bundleID: bundleID, appName: appName)
            VStack(alignment: .leading, spacing: 3) {
                HStack(alignment: .firstTextBaseline) {
                    Text(source)
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    Spacer(minLength: 8)
                    HStack(alignment: .center, spacing: 4) {
                        Image(systemName: kindSymbol(kind))
                            .font(.system(size: 10, weight: .medium))
                            .foregroundStyle(.tertiary)
                            .frame(width: 14, height: 12)
                            .help(kindLabel(kind))
                        Text(fmt.string(from: date))
                            .font(.system(size: 11).monospacedDigit())
                            .foregroundStyle(.tertiary)
                    }
                }
                if let place, !place.isEmpty {
                    Text(place)
                        .font(.system(size: 11))
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                }
                if let translation {
                    Text(translation)
                        .font(.system(size: 15, weight: .medium))
                        .lineLimit(2)
                }
            }
        }
        .padding(.vertical, 5)
        .contentShape(Rectangle())
        .help(help)
    }

    @ViewBuilder
    private func leadingMark(kind: String, bundleID: String?, appName: String?) -> some View {
        if let icon = AppIcon.image(bundleID: bundleID, appName: appName) {
            Image(nsImage: icon)
                .resizable()
                .interpolation(.high)
                .frame(width: 26, height: 26)
                .help(kindLabel(kind))
        } else {
            Image(systemName: kindSymbol(kind))
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.secondary)
                .frame(width: 26, height: 26)
                .well(radius: 7)
                .help(kindLabel(kind))
        }
    }

    private func kindSymbol(_ k: String) -> String {
        switch k {
        case "select": return "text.cursor"
        case "clipboard": return "doc.on.clipboard"
        case "ocr": return "text.viewfinder"
        case "file": return "doc.text"
        case "quick": return "keyboard"
        case "live": return "captions.bubble"
        case "voice": return "waveform"
        case "voiceTranslate": return "character.bubble"
        case "voiceInterpret": return "speaker.wave.2"
        case "plugin": return "plus.magnifyingglass"
        default: return "character.bubble"
        }
    }

    private func kindLabel(_ k: String) -> String {
        switch k {
        case "select": return L("划词")
        case "clipboard": return L("剪贴板")
        case "ocr": return L("截图识别")
        case "file": return L("文件")
        case "quick": return L("快捷翻译")
        case "live": return L("字幕")
        case "voice": return L("语音识别")
        case "voiceTranslate": return L("语音翻译")
        case "voiceInterpret": return L("语音传译")
        case "plugin": return L("划词插件")
        default: return k.isEmpty ? L("翻译") : k
        }
    }
}

@MainActor
private enum AppIcon {
    private static var images: [String: NSImage] = [:]
    private static var missing: Set<String> = []
    private static var names: [String: String]?

    static func image(bundleID: String?, appName: String?) -> NSImage? {
        if let bundleID, let icon = image(bundleID: bundleID) { return icon }
        let name = appName?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !name.isEmpty else { return nil }
        if names == nil { names = displayNames() }
        guard let id = names?[name] else { return nil }
        return image(bundleID: id)
    }

    private static func image(bundleID: String) -> NSImage? {
        if missing.contains(bundleID) { return nil }
        if let cached = images[bundleID] { return cached }
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else {
            missing.insert(bundleID)
            return nil
        }
        let icon = NSWorkspace.shared.icon(forFile: url.path)
        images[bundleID] = icon
        return icon
    }

    /// Older rows stored only the display name. Match it once against installed apps.
    private static func displayNames() -> [String: String] {
        var index: [String: String] = [:]
        for app in NSWorkspace.shared.runningApplications {
            guard let name = app.localizedName, let id = app.bundleIdentifier, index[name] == nil else { continue }
            index[name] = id
        }
        let fm = FileManager.default
        var roots = [
            URL(fileURLWithPath: "/Applications", isDirectory: true),
            URL(fileURLWithPath: "/System/Applications", isDirectory: true),
            URL(fileURLWithPath: "/System/Applications/Utilities", isDirectory: true),
        ]
        roots.append(contentsOf: fm.urls(for: .applicationDirectory, in: .userDomainMask))
        for root in roots {
            collect(root, depth: 0, into: &index)
        }
        return index
    }

    private static func collect(_ dir: URL, depth: Int, into index: inout [String: String]) {
        let fm = FileManager.default
        guard let items = try? fm.contentsOfDirectory(
            at: dir,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else { return }
        for url in items {
            if url.pathExtension == "app" {
                let name = fm.displayName(atPath: url.path)
                if index[name] == nil, let id = Bundle(url: url)?.bundleIdentifier {
                    index[name] = id
                }
                continue
            }
            if depth >= 1 { continue }
            let isDir = (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
            if isDir { collect(url, depth: depth + 1, into: &index) }
        }
    }
}
