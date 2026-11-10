import AppKit
import ApplicationServices
import Combine
import JavaScriptCore
import SwiftUI

// MARK: - Model

/// 划词插件：会在划词的位置上留一枚图标，点一下就直接出结果。
///
/// 三种做法：
/// - 翻译：走译文供应商，不看脚本和提示词。
/// - 脚本：在 JavaScriptCore 里跑，划词内容就是 `text` 变量，脚本的返回值就是结果。不上网，不花钱。
/// - AI：把提示词和划词交给一家 AI。
struct SelectionPlugin: Identifiable, Codable, Equatable, Sendable {
    enum Kind { case translate, script, ai }

    var id: String
    var title: String
    /// SF Symbol 名。
    var symbol: String
    /// AI 插件用的提示词。脚本里可以留空。
    var prompt: String
    /// 翻译走后端的翻译供应商，不看提示词。
    var isTranslate: Bool
    /// 有脚本就跑脚本，比 `prompt` 优先。
    var script: String?
    var enabled: Bool
    /// 自己改过名字或提示词。没有的内置项，标题和提示词跟着界面语言走。
    var edited: Bool?

    var kind: Kind {
        if isTranslate { return .translate }
        if !(script ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return .script }
        return .ai
    }

    var isScript: Bool { kind == .script }

    static let translateID = "translate"

    /// 一次划词最多送出去的字数。太长的不弹条，也不悄悄截断。
    static let sourceLimit = 8000

    static let builtin: [SelectionPlugin] = [
        SelectionPlugin(
            id: translateID,
            title: L("翻译"),
            symbol: "character.bubble",
            prompt: "",
            isTranslate: true,
            enabled: true
        ),
        SelectionPlugin(
            id: "explain",
            title: L("解释"),
            symbol: "questionmark.circle",
            prompt: "用原文的语言解释这段文字：它讲的是什么，有没有专有名词、典故或需要背景才能懂的地方。简明扼要。",
            isTranslate: false,
            enabled: false
        ),
        SelectionPlugin(
            id: "polish",
            title: L("润色"),
            symbol: "wand.and.sparkles",
            prompt: "把这段文字改得更通顺、更准确，保持原来的语言、语气和格式。只给出改好的文字，不要解释。",
            isTranslate: false,
            enabled: false
        ),
        SelectionPlugin(
            id: "summarize",
            title: L("总结"),
            symbol: "text.alignleft",
            prompt: "用三句话总结这段文字，用原文的语言。",
            isTranslate: false,
            enabled: false
        ),
        SelectionPlugin(
            id: "number-lines",
            title: L("编号"),
            symbol: "list.number",
            prompt: L("给每一行加上行号"),
            isTranslate: false,
            script: "return text.split('\\n').map(function (line, i) {\n  return (i + 1) + '. ' + line\n}).join('\\n')",
            enabled: false
        ),
    ]

    /// 一句话说完这个插件做什么，设置页用。
    var summary: String {
        switch kind {
        case .translate: return L("用翻译供应商给出译文")
        case .script: return L("跑一段脚本，返回什么就显示什么")
        case .ai: return prompt
        }
    }

    /// 内置项换成这一次的界面语言。自己改过的不动，自己加的本来就不是内置的。
    func relocalized() -> SelectionPlugin {
        guard edited != true,
              let builtin = Self.builtin.first(where: { $0.id == id }) else { return self }
        var next = self
        next.title = builtin.title
        next.prompt = builtin.prompt
        next.script = builtin.script
        return next
    }
}

/// 插件表。存 UserDefaults，和设置一起走。
@MainActor
final class SelectionPluginStore: ObservableObject {
    static let shared = SelectionPluginStore()

    static let storageKey = "selection.plugins"
    static let enabledKey = "feature.selectionPlugins"
    static let aiProfileKey = "selection.aiProfileID"
    /// 删掉的内置插件 id。内置表升级了也不把这些补回来。
    static let removedKey = "selection.plugins.removed"

    @Published private(set) var plugins: [SelectionPlugin] = []

    /// 设置里选的 AI。空字符串就是第一个能用的。
    var aiProfileID: String {
        get { UserDefaults.standard.string(forKey: Self.aiProfileKey) ?? "" }
        set {
            UserDefaults.standard.set(newValue, forKey: Self.aiProfileKey)
            objectWillChange.send()
        }
    }

    /// 能问的一家。钥匙、地址、模型都齐了才算。
    var readyAIProfiles: [AIProfile] {
        let cfg = AppConfig.shared
        return cfg.aiProfiles.filter { p in
            guard p.enabled else { return false }
            let preset = AIPresetDef.find(p.preset)
            let keyOK = (preset?.noKey ?? false)
                || !cfg.aiKey(for: p).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            return keyOK
                && !p.baseURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                && !p.model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
    }

    /// 插件里问 AI 用的那一家。选的那家停用了就退到第一家能用的。
    var aiProfile: AIProfile? {
        let ready = readyAIProfiles
        if let picked = ready.first(where: { $0.id == aiProfileID }) { return picked }
        return ready.first
    }

    private init() {
        load()
    }

    /// 划词后要不要弹这一条。
    var isOn: Bool {
        get { UserDefaults.standard.object(forKey: Self.enabledKey) as? Bool ?? false }
        set {
            UserDefaults.standard.set(newValue, forKey: Self.enabledKey)
            objectWillChange.send()
        }
    }

    var active: [SelectionPlugin] {
        active(bundleID: nil)
    }

    /// 来源应用自己改过插件表就用它那份：关掉的不弹，自选的只弹勾上的。没配过跟着这一页的开关和勾选走。
    func active(bundleID: String?) -> [SelectionPlugin] {
        guard isOn, AppConfig.shared.isAppOn(.select, bundleID: bundleID) else { return [] }
        guard let rule = AppConfig.shared.quickAppRule(bundleID: bundleID), !rule.plugins.isEmpty else {
            return plugins.filter(\.enabled)
        }
        if rule.plugins == QuickAppRule.pluginsNone { return [] }
        let wanted = Set(rule.pluginIDs)
        return plugins.filter { wanted.contains($0.id) }
    }

    func setEnabled(_ on: Bool, id: String) {
        guard let idx = plugins.firstIndex(where: { $0.id == id }) else { return }
        plugins[idx].enabled = on
        save()
    }

    func update(_ plugin: SelectionPlugin) {
        guard let idx = plugins.firstIndex(where: { $0.id == plugin.id }) else { return }
        var next = plugin
        // 内置项被改过就用新的，下次换语言也不再覆盖回去。
        if SelectionPlugin.builtin.contains(where: { $0.id == plugin.id }) { next.edited = true }
        plugins[idx] = next
        save()
    }

    /// 加一个自己的插件。id 用 UUID，和内置的不会撞。有脚本就是脚本插件，没有就是 AI 插件。
    @discardableResult
    func add(title: String, symbol: String, prompt: String, script: String? = nil) -> SelectionPlugin {
        let plugin = SelectionPlugin(
            id: UUID().uuidString,
            title: title,
            symbol: symbol,
            prompt: prompt,
            isTranslate: false,
            script: script,
            enabled: true
        )
        plugins.append(plugin)
        save()
        return plugin
    }

    /// 自己加的和内置的都能删。删掉的内置项记下来，升级或重启都不会再补回来。
    func remove(id: String) {
        plugins.removeAll { $0.id == id }
        if SelectionPlugin.builtin.contains(where: { $0.id == id }) {
            var gone = Set(UserDefaults.standard.stringArray(forKey: Self.removedKey) ?? [])
            gone.insert(id)
            UserDefaults.standard.set(Array(gone), forKey: Self.removedKey)
        }
        save()
    }

    /// 把 `id` 插到 `before` 前面。`before` 为空就放到最后。设置页拖动排序用。
    func move(id: String, before: String?) {
        guard let from = plugins.firstIndex(where: { $0.id == id }) else { return }
        let item = plugins.remove(at: from)
        if let before, let to = plugins.firstIndex(where: { $0.id == before }) {
            plugins.insert(item, at: to)
        } else {
            plugins.append(item)
        }
        save()
    }

    func reset() {
        UserDefaults.standard.removeObject(forKey: Self.removedKey)
        plugins = SelectionPlugin.builtin
        save()
    }

    /// 插件表还是默认那一套。比内容，不比 `edited` 标记，
    /// 也不比 `builtin` 里那份第一次启动时取好的本地化文本 —— 换过界面语言之后它还停在旧语言上。
    var isDefault: Bool {
        let expected = SelectionPlugin.builtin
        guard plugins.count == expected.count else { return false }
        for (now, base) in zip(plugins, expected) {
            guard now.id == base.id,
                  now.enabled == base.enabled,
                  now.symbol == base.symbol,
                  now.isTranslate == base.isTranslate,
                  now.script == base.script else { return false }
            let fresh = now.relocalized()
            guard fresh.title == now.title, fresh.prompt == now.prompt else { return false }
            guard now.id != SelectionPlugin.translateID || now.prompt.isEmpty else { return false }
        }
        return true
    }

    private func load() {
        let removed = Set(UserDefaults.standard.stringArray(forKey: Self.removedKey) ?? [])
        guard let data = UserDefaults.standard.data(forKey: Self.storageKey),
              let saved = try? JSONDecoder().decode([SelectionPlugin].self, from: data),
              !saved.isEmpty else {
            plugins = SelectionPlugin.builtin
            return
        }
        // 新版本加的内置插件，老用户表里没有就补进去；用户删掉的不补。
        // 标题和提示词每次启动都按当前界面语言重取，停用状态留着。
        var merged = saved.map { $0.relocalized() }
        for builtin in SelectionPlugin.builtin
        where !merged.contains(where: { $0.id == builtin.id }) && !removed.contains(builtin.id) {
            merged.append(builtin)
        }
        plugins = merged
        save()
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(plugins) else { return }
        UserDefaults.standard.set(data, forKey: Self.storageKey)
        objectWillChange.send()
    }
}

// MARK: - 划词后那一排

/// 划词松开后浮在选区上的一排插件图标。面板不是 key，点一下不抢来源应用的焦点，
/// 也就不需要先还焦点再弹结果。
@MainActor
final class SelectionPluginBar {
    static let shared = SelectionPluginBar()

    private var panel: NSPanel?
    private var hosting: NSHostingView<SelectionPluginBarView>?
    private let model = SelectionPluginBarModel()
    private var outsideMonitor: Any?
    private var localMonitor: Any?
    private var keyMonitor: Any?
    private var shownAt = Date()

    static let barHeight: CGFloat = 34
    /// 悬停时写插件名的那一行，摆在条背向选区的一侧，不挡选中的字。
    static let labelRow: CGFloat = 24
    /// 条四周留出来画阴影。窗口自带的阴影按第一次画出来的样子算，名字一出一隐就对不上了。
    static let margin: CGFloat = 8
    /// 放大镜就地展开后，搜索框的宽度。
    static let searchWidth: CGFloat = 168
    /// 「⋯」打开后的菜单宽度。
    static let menuWidth: CGFloat = 240
    /// 条上直接露出的勾选插件数，其余收进「⋯」。
    static let barSlots = 5
    private let gap: CGFloat = 8

    var isVisible: Bool { panel?.isVisible == true }

    /// `rect` 是辅助功能坐标，主屏左上角为原点；nil 时贴着鼠标。
    /// `plugins` 是这一次划词用的那一份（按应用可以另选）。`catalog` 是设置里的全表，搜索用。
    func show(
        source: String,
        plugins: [SelectionPlugin],
        catalog: [SelectionPlugin],
        rect: CGRect?,
        run: @escaping (SelectionPlugin, String) -> Void
    ) {
        guard !plugins.isEmpty || !catalog.isEmpty else { return }
        hide()
        model.source = source
        model.plugins = plugins
        model.catalog = catalog
        model.hovered = nil
        model.mode = .icons
        model.query = ""
        model.highlight = 0
        model.onPick = run
        model.onDismiss = { [weak self] in self?.hide() }
        model.onManage = { [weak self] in
            self?.hide()
            PreferencesController.shared.show(tab: .plugins)
        }
        model.onLayout = { [weak self] in self?.relayout() }

        let panel = ensurePanel()
        let size = panelSize()
        // 先定好面板的大小和位置，再把内容铺满。反过来做，内容会被 autoresizing 按尺寸差再拉一次，
        // 宽度变成「新 × 2 − 旧」，条就偏到一边，只露出左半或右半。
        place(rect: rect, size: size)
        let host = makeHosting()
        if host.superview !== panel.contentView {
            panel.contentView?.subviews.forEach { $0.removeFromSuperview() }
            panel.contentView?.addSubview(host)
        }
        host.autoresizingMask = [.width, .height]
        host.frame = panel.contentView?.bounds ?? NSRect(origin: .zero, size: size)
        panel.alphaValue = 0
        panel.orderFrontRegardless()
        OverlayPlacement.fadeIn(panel)
        shownAt = Date()
        installOutsideMonitor()
    }

    func hide() {
        removeOutsideMonitor()
        model.onPick = { _, _ in }
        model.onDismiss = {}
        model.onManage = {}
        model.onLayout = {}
        model.hovered = nil
        model.mode = .icons
        model.query = ""
        panel?.orderOut(nil)
        panel?.alphaValue = 0
    }

    /// 一排图标时的宽度：放大镜、分隔线、最多 5 枚、分隔线、「⋯」。
    /// 每枚 28、间距 2、左右各 5 的内边距。和 `SelectionPluginBarView` 里的排法一一对应。
    static func measuredWidth(count: Int) -> CGFloat {
        let shown = min(count, barSlots)
        let pieces = 2 + shown
        let buttons = CGFloat(pieces) * 28
        let gaps = CGFloat(max(0, pieces + 1)) * 2
        let rules = CGFloat(2) * (4 + 1)
        return 10 + buttons + gaps + rules
    }

    /// 放大镜就地展开后的宽度：搜索框取代放大镜，其余照旧。
    static func searchBarWidth(count: Int) -> CGFloat {
        measuredWidth(count: count) - 28 + searchWidth
    }

    /// 第 `index` 枚按钮的中心，从条的左边算起。
    /// 0 是放大镜，1…n 是露出的插件，「⋯」是 `shown + 1`。
    /// 放大镜就地变成搜索框时，左边那一截按搜索框的宽度算。
    static func buttonCenter(index: Int, shown: Int, searching: Bool = false) -> CGFloat {
        let rule: CGFloat = 9
        let lead: CGFloat = searching ? searchWidth : 28
        if index == 0 { return 5 + lead / 2 }
        if index <= shown {
            return 5 + lead + rule + CGFloat(index - 1) * 30 + 14
        }
        return 5 + lead + rule + CGFloat(shown) * 30 + rule + 14
    }

    static let labelMaxWidth: CGFloat = 220

    /// 名字胶囊的宽度：字宽加左右各 8。太长的截断，和视图里的 `labelMaxWidth` 一致。
    static func labelWidth(_ title: String) -> CGFloat {
        let font = Theme.TypeScale.nsCaptionMedium
        let text = ceil((title as NSString).size(withAttributes: [.font: font]).width)
        return min(text + 16, labelMaxWidth)
    }

    /// 搜索或菜单展开时，面板跟着变。条贴着选区的那一边不动，多出来的高度朝另一侧长。
    private func relayout() {
        guard let panel, panel.isVisible else { return }
        let old = panel.frame
        let size = panelSize()
        var frame = old
        frame.size = size
        frame.origin.x = old.midX - size.width / 2
        if model.labelBelow {
            frame.origin.y = old.maxY - size.height
        }
        if let visible = OverlayPlacement.screen(containing: frame)?.visibleFrame {
            if frame.minY < visible.minY { frame.origin.y = visible.minY }
            if frame.maxY > visible.maxY { frame.origin.y = visible.maxY - frame.height }
            if frame.maxX > visible.maxX { frame.origin.x = visible.maxX - frame.width }
            if frame.minX < visible.minX { frame.origin.x = visible.minX }
        }
        panel.setFrame(frame, display: true)
        hosting?.frame = panel.contentView?.bounds ?? NSRect(origin: .zero, size: size)
    }

    private func currentBarWidth() -> CGFloat {
        let count = model.plugins.count
        return model.mode == .search ? Self.searchBarWidth(count: count) : Self.measuredWidth(count: count)
    }

    /// 搜索框下面那张结果卡的高度，和视图里的排法一致。
    static func resultsHeight(rows: Int) -> CGFloat {
        8 + CGFloat(max(rows, 1)) * 28 + 8
    }

    /// 「⋯」菜单的高度：顶上搜索、结果、底部分隔和「管理插件…」。
    static func menuHeight(rows: Int) -> CGFloat {
        8 + 28 + 4 + CGFloat(max(rows, 1)) * 28 + 4 + 28 + 8
    }

    /// 面板要比条宽：名字胶囊、搜索结果和「⋯」菜单都不能被裁掉。
    private func panelSize() -> NSSize {
        let barWidth = currentBarWidth()
        let names = model.plugins.prefix(Self.barSlots).map(\.title) + [L("搜索插件"), L("更多插件")]
        let widest = names.map(Self.labelWidth).max() ?? 0
        var width = max(barWidth, widest)
        var height = Self.barHeight + Self.labelRow
        let rows = model.menuRows.count
        if model.mode == .menu {
            width = max(width, Self.menuWidth)
            height = Self.barHeight + 6 + Self.menuHeight(rows: rows)
        } else if model.mode == .search {
            width = max(width, Self.menuWidth)
            height = Self.barHeight + 6 + Self.resultsHeight(rows: rows)
        }
        return NSSize(width: width + Self.margin * 2, height: height + Self.margin * 2)
    }

    private func makeHosting() -> NSHostingView<SelectionPluginBarView> {
        if let hosting {
            hosting.rootView = SelectionPluginBarView(model: model)
            return hosting
        }
        let made = NSHostingView(rootView: SelectionPluginBarView(model: model))
        made.sizingOptions = []
        made.safeAreaRegions = []
        hosting = made
        return made
    }

    /// 鼠标点到别处就收起来。全局监控收不到打在我们自己窗口里的点击，
    /// 所以另外挂一个本地监控：去点菜单栏、偏好设置时这条也该让开。
    /// 刚弹出来的那一小会儿认不动：点图标的那一下本来就在自己窗口里。
    /// 键盘另挂一条：面板不是 key，搜索框的方向键和 Esc 从这里进。
    private func installOutsideMonitor() {
        removeOutsideMonitor()
        outsideMonitor = NSEvent.addGlobalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown, .keyDown]
        ) { [weak self] event in
            let key = event.type == .keyDown
            let code = event.keyCode
            let chars = event.charactersIgnoringModifiers ?? ""
            Task { @MainActor in
                guard let self, Date().timeIntervalSince(self.shownAt) > 0.2 else { return }
                if key {
                    self.handleKey(code: code, characters: chars)
                } else {
                    self.hide()
                }
            }
        }
        localMonitor = NSEvent.addLocalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]
        ) { [weak self] event in
            guard let self, Date().timeIntervalSince(self.shownAt) > 0.2 else { return event }
            let frame = self.panel?.frame ?? .zero
            if !frame.contains(NSEvent.mouseLocation) {
                self.hide()
            }
            return event
        }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown]) { [weak self] event in
            guard let self, self.panel?.isVisible == true else { return event }
            let searching = self.model.mode != .icons
            let frame = self.panel?.frame ?? .zero
            // 图标态下，按键发生在别处（用户还在原来的应用里打字）不该把条收掉。
            // 搜索展开后，方向键、回车、Esc 和输入都归这条。
            if !searching, !frame.contains(NSEvent.mouseLocation) { return event }
            self.handleKey(code: event.keyCode, characters: event.charactersIgnoringModifiers ?? "")
            return searching ? nil : event
        }
    }

    /// 回车用高亮的那一个，↑↓ 移动，Esc 先收起搜索或菜单，再收起整条。
    private func handleKey(code: UInt16, characters: String) {
        guard model.mode != .icons else {
            if code == 53 { hide() }
            return
        }
        switch code {
        case 53:
            model.closeSearch()
        case 125:
            model.moveHighlight(1)
        case 126:
            model.moveHighlight(-1)
        case 36, 76:
            model.commitHighlight()
        default:
            break
        }
        _ = characters
    }

    private func removeOutsideMonitor() {
        if let outsideMonitor { NSEvent.removeMonitor(outsideMonitor) }
        outsideMonitor = nil
        if let localMonitor { NSEvent.removeMonitor(localMonitor) }
        localMonitor = nil
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        keyMonitor = nil
    }

    /// 先摆条，再把面板围着条展开：名字那一行放在背向选区的一侧，四周再留出画阴影的边。
    /// 选区上方留 8 磅；上面放不下整块（含名字和菜单）就改到选区下方。
    private func place(rect: CGRect?, size: NSSize) {
        guard let panel else { return }
        let barHeight = Self.barHeight
        let barWidth = currentBarWidth()
        var bar: NSRect
        var visible: NSRect?
        var below = false
        if let rect, rect.width > 1, rect.height > 1 {
            // 辅助功能坐标换成屏幕坐标。主屏左上角为原点。
            let onScreen = OverlayPlacement.onScreen(rect)
            bar = NSRect(x: onScreen.midX - barWidth / 2, y: onScreen.maxY + gap, width: barWidth, height: barHeight)
            visible = OverlayPlacement.screen(containing: onScreen)?.visibleFrame
            // 上面连名字一起放不下就放选区下面。
            if let v = visible, bar.maxY + (size.height - barHeight) > v.maxY - 4 {
                bar.origin.y = onScreen.minY - gap - barHeight
                below = true
            }
        } else {
            let mouse = NSEvent.mouseLocation
            bar = NSRect(x: mouse.x + 10, y: mouse.y + 12, width: barWidth, height: barHeight)
            visible = (NSScreen.screens.first { $0.frame.contains(mouse) } ?? NSScreen.main)?.visibleFrame
            if let v = visible, bar.maxY + (size.height - barHeight) > v.maxY - 4 {
                bar.origin.y = mouse.y - 12 - barHeight
                below = true
            }
        }
        model.labelBelow = below
        let extra = size.height - barHeight - Self.margin * 2
        var frame = NSRect(
            x: bar.midX - size.width / 2,
            y: (below ? bar.minY - extra : bar.minY) - Self.margin,
            width: size.width,
            height: size.height
        )
        if let v = visible {
            if frame.minY < v.minY { frame.origin.y = v.minY }
            if frame.maxY > v.maxY { frame.origin.y = v.maxY - frame.height }
            if frame.maxX > v.maxX { frame.origin.x = v.maxX - frame.width }
            if frame.minX < v.minX { frame.origin.x = v.minX }
        }
        panel.setFrame(frame, display: true)
    }

    private func ensurePanel() -> NSPanel {
        if let panel { return panel }
        // 不是 key 窗口时，第一下点击本该是「激活窗口」，会被系统吞掉。工厂里的
        // becomesKeyOnlyIfNeeded 认下这一下，图标一下就点亮，也不抢来源应用的键盘。
        let container = FirstMouseView(frame: NSRect(x: 0, y: 0, width: 40, height: Self.barHeight))
        container.wantsLayer = true
        let made = OverlayPanel.make(
            contentRect: NSRect(x: 0, y: 0, width: 40, height: Self.barHeight),
            style: .floating,
            content: container,
            deferCreation: true
        )
        panel = made
        return made
    }
}

/// 条上正在干什么：一排图标、放大镜就地变成搜索框、或「⋯」打开的菜单。
enum SelectionPluginBarMode: Equatable {
    case icons
    case search
    case menu
}

/// 菜单或搜索结果里的一行。没勾选的标「未勾选」。
struct SelectionPluginMenuRow: Identifiable, Equatable {
    let plugin: SelectionPlugin
    var id: String { plugin.id }
    var unticked: Bool { !plugin.enabled }
}

@MainActor
final class SelectionPluginBarModel: ObservableObject {
    @Published var source = ""
    /// 这一次划词要用的插件，顺序就是条上的顺序。
    @Published var plugins: [SelectionPlugin] = []
    /// 设置里的全表。搜索时连没勾选的也列出来。
    @Published var catalog: [SelectionPlugin] = []
    /// 鼠标停在哪一枚上。放大镜是 `searchID`，「⋯」是 `moreID`。
    @Published var hovered: String?
    /// 悬停满 400 ms 才把名字写出来。移开或换一枚就取消。
    @Published var tipID: String?
    /// 条摆在选区下面时，名字写在条的下面，菜单也改到条的下面。
    @Published var labelBelow = false
    @Published var mode: SelectionPluginBarMode = .icons
    @Published var query = ""
    /// 搜索结果或菜单里键盘高亮的那一行。
    @Published var highlight = 0
    var onPick: (SelectionPlugin, String) -> Void = { _, _ in }
    var onDismiss: () -> Void = {}
    var onManage: () -> Void = {}
    var onLayout: () -> Void = {}

    static let searchID = "__search"
    static let moreID = "__more"

    private var tipTask: Task<Void, Never>?

    /// 直接露在条上的，勾选里的前 5 个。
    var shown: [SelectionPlugin] { Array(plugins.prefix(SelectionPluginBar.barSlots)) }
    /// 第 6 个起，收进「⋯」。
    var overflow: [SelectionPlugin] { Array(plugins.dropFirst(SelectionPluginBar.barSlots)) }

    /// 放大镜：不输入时列出全部插件。
    /// 「⋯」：不输入时只列收进来的。两边输入后都搜全部，没勾选的标出来。
    var menuRows: [SelectionPluginMenuRow] {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let source: [SelectionPlugin]
        if needle.isEmpty {
            source = mode == .search ? catalog : overflow
        } else {
            source = catalog.filter { $0.title.localizedCaseInsensitiveContains(needle) }
        }
        return source.map { SelectionPluginMenuRow(plugin: $0) }
    }

    func hover(_ id: String, _ inside: Bool) {
        if inside {
            hovered = id
            scheduleTip(id)
        } else if hovered == id {
            hovered = nil
            cancelTip()
        }
    }

    /// 名字提示不跟着鼠标立刻出，停够 400 ms 才写。
    private func scheduleTip(_ id: String) {
        tipTask?.cancel()
        tipID = nil
        tipTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 400_000_000)
            guard !Task.isCancelled, hovered == id else { return }
            tipID = id
        }
    }

    private func cancelTip() {
        tipTask?.cancel()
        tipTask = nil
        tipID = nil
    }

    func openSearch() {
        cancelTip()
        query = ""
        highlight = 0
        mode = .search
        onLayout()
    }

    func openMenu() {
        cancelTip()
        query = ""
        highlight = 0
        mode = .menu
        onLayout()
    }

    func closeSearch() {
        guard mode != .icons else { return }
        query = ""
        highlight = 0
        mode = .icons
        onLayout()
    }

    func moveHighlight(_ delta: Int) {
        let count = menuRows.count
        guard count > 0 else { return }
        highlight = (highlight + delta + count) % count
    }

    /// 输入变了，结果行数跟着变，面板要重新量。
    func queryChanged() {
        highlight = 0
        guard mode != .icons else { return }
        onLayout()
    }

    func commitHighlight() {
        let rows = menuRows
        guard rows.indices.contains(highlight) else { return }
        pick(rows[highlight].plugin)
    }

    func pick(_ plugin: SelectionPlugin) {
        let source = source
        onPick(plugin, source)
    }
}

/// 一排图标：最左放大镜，中间勾选的前 5 个，最右「⋯」。
/// 面板不是 key，系统的 `.help` 气泡出不来，所以名字自己画在条外面那一行，悬停 400 ms 才出。
struct SelectionPluginBarView: View {
    @ObservedObject var model: SelectionPluginBarModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @FocusState private var searchFocused: Bool

    var body: some View {
        GeometryReader { geo in
            let barWidth = model.mode == .search
                ? SelectionPluginBar.searchBarWidth(count: model.plugins.count)
                : SelectionPluginBar.measuredWidth(count: model.plugins.count)
            let margin = SelectionPluginBar.margin
            let barHeight = SelectionPluginBar.barHeight
            let row = SelectionPluginBar.labelRow
            let barY = margin + (model.labelBelow
                ? geo.size.height - margin * 2 - barHeight
                : (model.mode == .icons ? row : 0)) + barHeight / 2
            ZStack(alignment: .topLeading) {
                bar
                    .frame(width: barWidth, height: barHeight)
                    .position(x: geo.size.width / 2, y: barY)
                if model.mode == .icons, let tip {
                    let width = SelectionPluginBar.labelWidth(tip.title)
                    let center = (geo.size.width - barWidth) / 2
                        + SelectionPluginBar.buttonCenter(
                            index: tip.index, shown: model.shown.count, searching: model.mode == .search
                        )
                    label(tip.title)
                        .frame(width: width)
                        .position(
                            x: min(max(center, margin + width / 2), geo.size.width - margin - width / 2),
                            y: margin + (model.labelBelow ? barHeight + row / 2 : row / 2)
                        )
                        .transition(.opacity)
                        .id(tip.index)
                }
                if model.mode == .search {
                    resultsCard
                        .frame(width: SelectionPluginBar.menuWidth)
                        .position(
                            x: searchCardX(barWidth: barWidth, width: geo.size.width),
                            y: popoverY(barY: barY, barHeight: barHeight, height: resultsHeight)
                        )
                }
                if model.mode == .menu {
                    menu
                        .frame(width: SelectionPluginBar.menuWidth)
                        .position(
                            x: min(
                                geo.size.width - margin - SelectionPluginBar.menuWidth / 2,
                                max(margin + SelectionPluginBar.menuWidth / 2, moreCenter(barWidth: barWidth, width: geo.size.width))
                            ),
                            y: popoverY(barY: barY, barHeight: barHeight, height: menuHeight)
                        )
                }
            }
            .animation(reduceMotion ? nil : .easeOut(duration: 0.12), value: model.tipID)
        }
    }

    private var tip: (title: String, index: Int)? {
        guard let id = model.tipID else { return nil }
        if id == SelectionPluginBarModel.searchID { return (L("搜索插件"), 0) }
        if id == SelectionPluginBarModel.moreID { return (L("更多插件"), model.shown.count + 1) }
        guard let index = model.shown.firstIndex(where: { $0.id == id }) else { return nil }
        return (model.shown[index].title, index + 1)
    }

    /// 放大镜（或就地展开的搜索框）的中心，结果卡挂在它下面（或上面）。
    private func searchCardX(barWidth: CGFloat, width: CGFloat) -> CGFloat {
        let anchor = SelectionPluginBar.buttonCenter(
            index: 0, shown: model.shown.count, searching: model.mode == .search
        )
        let center = (width - barWidth) / 2 + anchor
        let half = SelectionPluginBar.menuWidth / 2
        return min(width - SelectionPluginBar.margin - half, max(SelectionPluginBar.margin + half, center))
    }

    /// 「⋯」按钮的中心，菜单挂在它下面（或上面）。
    private func moreCenter(barWidth: CGFloat, width: CGFloat) -> CGFloat {
        (width - barWidth) / 2 + SelectionPluginBar.buttonCenter(
            index: model.shown.count + 1, shown: model.shown.count, searching: model.mode == .search
        )
    }

    /// 条背向选区的一侧。条在选区上方时卡片在条下，条在选区下方时卡片在条上。
    private func popoverY(barY: CGFloat, barHeight: CGFloat, height: CGFloat) -> CGFloat {
        if model.labelBelow {
            return barY - barHeight / 2 - 6 - height / 2
        }
        return barY + barHeight / 2 + 6 + height / 2
    }

    private var resultsHeight: CGFloat {
        SelectionPluginBar.resultsHeight(rows: model.menuRows.count)
    }

    private var menuHeight: CGFloat {
        SelectionPluginBar.menuHeight(rows: model.menuRows.count)
    }

    private func label(_ title: String) -> some View {
        Text(title)
            .font(Theme.TypeScale.caption).fontWeight(.medium)
            .lineLimit(1)
            .truncationMode(.tail)
            .padding(.horizontal, 8)
            .frame(maxWidth: SelectionPluginBar.labelMaxWidth)
            .frame(height: 20)
            .background(.regularMaterial, in: Capsule())
            .overlay(Capsule().strokeBorder(Color.black.opacity(0.12), lineWidth: 0.5))
            // 浮层统一阴影：黑 18%，半径 12，y 4。
            .shadow(color: Theme.panelShadow, radius: Theme.panelShadowRadius, y: Theme.panelShadowY)
            .allowsHitTesting(false)
    }

    private var bar: some View {
        HStack(spacing: 2) {
            if model.mode == .search {
                searchField
            } else {
                iconButton(symbol: "magnifyingglass", id: SelectionPluginBarModel.searchID, label: L("搜索插件")) {
                    model.openSearch()
                }
            }
            divider
            ForEach(model.shown) { plugin in
                iconButton(symbol: plugin.symbol, id: plugin.id, label: plugin.title) {
                    model.pick(plugin)
                }
            }
            divider
            iconButton(symbol: "ellipsis", id: SelectionPluginBarModel.moreID, label: L("更多插件")) {
                if model.mode == .menu {
                    model.closeSearch()
                } else {
                    model.openMenu()
                }
            }
        }
        .padding(3)
        .frame(height: 34)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(Color.black.opacity(0.12), lineWidth: 0.5)
        )
        .shadow(color: Theme.panelShadow, radius: Theme.panelShadowRadius, y: Theme.panelShadowY)
    }

    /// 放大镜点开后就地变成的搜索框。输入的是全部插件，不限于条上那几个。
    private var searchField: some View {
        HStack(spacing: 4) {
            Image(systemName: "magnifyingglass")
                .font(Theme.TypeScale.caption)
                .foregroundStyle(Color.primary.opacity(0.55))
            TextField(L("搜索全部插件"), text: $model.query)
                .textFieldStyle(.plain)
                .font(Theme.TypeScale.label)
                .focused($searchFocused)
                .onAppear { searchFocused = true }
                .onSubmit { model.commitHighlight() }
                .onChange(of: model.query) { _, _ in model.queryChanged() }
            if !model.query.isEmpty {
                Button {
                    model.query = ""
                    model.queryChanged()
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(Theme.TypeScale.caption)
                        .foregroundStyle(Color.primary.opacity(0.4))
                }
                .buttonStyle(.plain)
                .accessibilityLabel(L("清除"))
            }
        }
        .padding(.horizontal, 8)
        .frame(width: SelectionPluginBar.searchWidth, height: 28)
        .background(Capsule().fill(Color.primary.opacity(0.08)))
    }

    /// 放大镜搜出来的列表。和「⋯」里是同一份结果，挂在搜索框背向选区的一侧。
    private var resultsCard: some View {
        resultList
            .padding(.vertical, 4)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(Color.black.opacity(0.12), lineWidth: 0.5)
            )
            .shadow(color: Theme.panelShadow, radius: Theme.panelShadowRadius, y: Theme.panelShadowY)
    }

    private var menu: some View {
        VStack(spacing: 0) {
            menuSearch
                .padding(.horizontal, 8)
                .padding(.top, 8)
            resultList
                .padding(.top, 4)
            Divider().padding(.horizontal, 8).padding(.vertical, 4)
            Button {
                model.onManage()
            } label: {
                HStack {
                    Text(L("管理插件…"))
                        .font(Theme.TypeScale.label)
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 10)
                .frame(height: 28)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 4)
            .padding(.bottom, 4)
        }
        .frame(width: SelectionPluginBar.menuWidth)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(Color.black.opacity(0.12), lineWidth: 0.5)
        )
        .shadow(color: Theme.panelShadow, radius: Theme.panelShadowRadius, y: Theme.panelShadowY)
    }

    /// 「⋯」打开后顶上默认就是搜索框，和放大镜同一个功能。
    private var menuSearch: some View {
        HStack(spacing: 4) {
            Image(systemName: "magnifyingglass")
                .font(Theme.TypeScale.caption)
                .foregroundStyle(Color.primary.opacity(0.55))
            TextField(L("搜索全部插件"), text: $model.query)
                .textFieldStyle(.plain)
                .font(Theme.TypeScale.label)
                .focused($searchFocused)
                .onAppear { searchFocused = true }
                .onSubmit { model.commitHighlight() }
                .onChange(of: model.query) { _, _ in model.queryChanged() }
        }
        .padding(.horizontal, 8)
        .frame(height: 28)
        .background(Capsule().fill(Color.primary.opacity(0.06)))
    }

    private var resultList: some View {
        VStack(spacing: 0) {
            if model.menuRows.isEmpty {
                Text(model.query.isEmpty ? L("没有更多插件") : L("没有匹配的插件"))
                    .font(Theme.TypeScale.label)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 10)
                    .frame(height: 28)
            } else {
                ForEach(Array(model.menuRows.enumerated()), id: \.element.id) { index, row in
                    Button {
                        model.pick(row.plugin)
                    } label: {
                        HStack(spacing: 8) {
                            Image(systemName: row.plugin.symbol)
                                .font(Theme.TypeScale.label)
                                .frame(width: 16)
                            Text(row.plugin.title)
                                .font(Theme.TypeScale.label)
                                .lineLimit(1)
                            Spacer(minLength: 4)
                            if row.unticked {
                                Text(L("未勾选"))
                                    .font(Theme.TypeScale.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .padding(.horizontal, 10)
                        .frame(height: 28)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(
                            RoundedRectangle(cornerRadius: 6, style: .continuous)
                                .fill(model.highlight == index ? Color.accentColor : Color.clear)
                        )
                        .foregroundStyle(model.highlight == index ? Color.white : Color.primary)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .onHover { inside in
                        if inside { model.highlight = index }
                    }
                }
            }
        }
        .padding(.horizontal, 4)
    }

    private var divider: some View {
        Rectangle()
            .fill(Color.primary.opacity(0.14))
            .frame(width: 1, height: 16)
            .padding(.horizontal, 2)
    }

    private func iconButton(symbol: String, id: String, label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(Theme.TypeScale.reading)
                .frame(width: 28, height: 28)
                .contentShape(Rectangle())
                .background(
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .fill(Color.primary.opacity(model.hovered == id ? 0.07 : 0))
                )
                .foregroundStyle(Color.primary.opacity(0.78))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
        .onHover { model.hover(id, $0) }
    }
}

// MARK: - 划词时把它叫出来

/// 全局鼠标松开后问一句：刚才是不是划了一段字。是的话在选区上留一排插件图标。
///
/// 只在「划词插件」打开时才装监控。读取走 `SelectionGrabber`，和「划词翻译」菜单项同一条路，
/// 所以权限、网页编辑区、多窗口这些边角的表现完全一致。
@MainActor
final class SelectionPluginWatcher {
    static let shared = SelectionPluginWatcher()

    private var monitor: Any?
    private var downMonitor: Any?
    /// 按下的位置。松开时离它够远才算拖选，读不到选区时才值得用 ⌘C 去问。
    private var downAt: NSPoint?
    private var pending: Task<Void, Never>?
    private var sink: AnyCancellable?
    /// 「划词翻译」在设置里被关掉时，这条也要停。它归 AppConfig 管，不归插件表管。
    private var configSink: AnyCancellable?

    private init() {}

    /// 启动时调一次。之后开关和「划词翻译」的启停都通过订阅跟进来。
    func refresh() {
        guard sink == nil else { return }
        sink = SelectionPluginStore.shared.objectWillChange
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                Task { @MainActor in self?.sync() }
            }
        configSink = AppConfig.shared.objectWillChange
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                Task { @MainActor in self?.sync() }
            }
        sync()
    }

    private func sync() {
        let on = SelectionPluginStore.shared.isOn
            && AppConfig.shared.isFeatureEnabled(.select)
        if on {
            install()
        } else {
            remove()
        }
    }

    private func install() {
        guard monitor == nil else { return }
        downMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown]) { [weak self] _ in
            let point = NSEvent.mouseLocation
            Task { @MainActor in self?.downAt = point }
        }
        monitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseUp]) { [weak self] event in
            guard let self else { return }
            let point = NSEvent.mouseLocation
            let clicks = event.clickCount
            Task { @MainActor in
                // 拖了一段，或双击选词、三击选段，才是在划词。单击只是放下光标。
                let dragged = self.downAt.map { hypot($0.x - point.x, $0.y - point.y) > 4 } ?? false
                self.downAt = nil
                self.selectionEnded(at: point, gesture: dragged || clicks >= 2)
            }
        }
    }

    private func remove() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        if let downMonitor { NSEvent.removeMonitor(downMonitor) }
        downMonitor = nil
        pending?.cancel()
        pending = nil
        SelectionPluginBar.shared.hide()
    }

    /// 松开之后系统还要一会儿才把选区交出来。等一小会儿再问，问不到就什么都不做。
    /// `point` 是松开的位置：既然要弹在选区上，那松开时手就该在选区附近，
    /// 在别处点一下（只是放下了光标、或点了工具栏）不该把条叫出来。
    /// `gesture` 是这一下确实像在划词（拖选、双击、三击）。辅助功能读不到选区的应用，只有这时才用 ⌘C 补问。
    private func selectionEnded(at point: NSPoint, gesture: Bool) {
        guard AXIsProcessTrusted() else { return }
        guard let front = NSWorkspace.shared.frontmostApplication,
              front.processIdentifier != getpid() else {
            SelectionPluginBar.shared.hide()
            return
        }
        // 来源应用可以自己决定弹哪几个，所以先认应用再取表。
        let plugins = SelectionPluginStore.shared.active(bundleID: front.bundleIdentifier)
        guard !plugins.isEmpty else {
            SelectionPluginBar.shared.hide()
            return
        }
        pending?.cancel()
        pending = Task { @MainActor in
            // 网页编辑器常常在松开之后才把选区交出来。等不到就隔一会儿再问，
            // 连着试几次都不行才算这次没有划词 —— 只问一次是「有时不触发」的来源。
            // 第一次问时顺手替 Chromium、Electron 打开辅助功能树，不然它们一直什么都不交。
            var unreadable = false
            for (i, delay) in [140, 180, 260, 360].enumerated() {
                try? await Task.sleep(nanoseconds: UInt64(delay) * 1_000_000)
                guard !Task.isCancelled else { return }
                switch await probe(plugins: plugins, app: front, release: point, wake: i == 0) {
                case .handled: return
                case .empty: unreadable = false
                case .unreadable: unreadable = true
                }
            }
            // 辅助功能什么都不交的应用（不少 Electron、Java、跨平台界面）：确实像划过词，才用 ⌘C 问一次。
            // 能读出选区、只是选区是空的，就是真没划词，不去碰剪贴板。
            guard gesture, unreadable, !Task.isCancelled,
                  !Self.noCopyApps.contains(front.bundleIdentifier ?? "") else {
                SelectionPluginBar.shared.hide()
                return
            }
            if await copyProbe(plugins: plugins, app: front, release: point) { return }
            SelectionPluginBar.shared.hide()
        }
    }

    /// 在这些应用里 ⌘C 复制的是文件、而不是字，划过去也不用剪贴板问。
    private static let noCopyApps: Set<String> = ["com.apple.finder"]

    enum ProbeResult {
        /// 弹了条，或者确定这次不该弹。不用再问。
        case handled
        /// 读得到编辑区，只是没有选中的字。
        case empty
        /// 辅助功能交不出能读选区的元素。
        case unreadable
    }

    /// 问一次。读到选区并弹出条时返回 `.handled`；读不到时说清是空选区还是根本读不了，交给上一层重试或退到 ⌘C。
    private func probe(plugins: [SelectionPlugin], app: NSRunningApplication, release: NSPoint, wake: Bool) async -> ProbeResult {
        let pid = app.processIdentifier
        let read = await QuickAX.run { Self.readSelection(pid: pid, wake: wake) }
        // 读的时候用户可能已经在别处点了一下，那这一条就不该再出现。
        guard !Task.isCancelled else { return .handled }
        let found: PluginSelection
        switch read {
        case .found(let f): found = f
        case .empty: return .empty
        case .unreadable: return .unreadable
        }
        let text = found.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, text.count <= SelectionPlugin.sourceLimit else {
            SelectionPluginBar.shared.hide()
            return .handled
        }
        // 选区范围只认真正的选区。读不到就贴着松开的位置弹 —— 这才是「选在哪就出现在哪」；
        // 退回整个网页元素的框会把条摆到页面中间，Opera 里那种顶部居中就是这么来的。
        var rect = found.rect
        if let r = rect {
            let onScreen = OverlayPlacement.onScreen(r)
            // 松开的位置离选区很远：多半是旧选区还挂着，这一下只是点在了别处。
            // 拖过行尾、拖到空白处松开也会离选区有一段，所以放宽到 80，再远就不弹。
            guard onScreen.insetBy(dx: -80, dy: -80).contains(release) else {
                SelectionPluginBar.shared.hide()
                return .handled
            }
            // 选区跨了好几行时，框的中间可能离手很远；这时贴着松开的位置弹。
            if !onScreen.insetBy(dx: -24, dy: -24).contains(release) { rect = nil }
        }
        // 插件运行前把写回的落点记下来，和菜单里的「划词翻译」一样。
        let slot = WriteBackSlot(
            element: found.element,
            original: text,
            sourceApp: app,
            writable: found.writable,
            markers: found.markers
        )
        SelectionPluginBar.shared.show(
            source: text, plugins: plugins, catalog: SelectionPluginStore.shared.plugins, rect: rect
        ) { plugin, source in
            SelectionPluginBar.shared.hide()
            SelectionPluginRunner.run(plugin, source: source, slot: slot, app: app)
        }
        return .handled
    }

    /// 辅助功能读不到选区时，用 ⌘C 问一次，和菜单里的「划词翻译」走同一条退路。剪贴板会还原。
    /// 读到的字没有可写回的元素，写回时交给粘贴去试。
    private func copyProbe(plugins: [SelectionPlugin], app: NSRunningApplication, release: NSPoint) async -> Bool {
        // 这一会儿用户可能已经切走了。⌘C 只能发给划词的那个应用。
        guard NSWorkspace.shared.frontmostApplication?.processIdentifier == app.processIdentifier else { return false }
        let copied = await SelectionGrabber.copyViaCmdC()
        guard !Task.isCancelled,
              NSWorkspace.shared.frontmostApplication?.processIdentifier == app.processIdentifier,
              let text = copied?.trimmingCharacters(in: .whitespacesAndNewlines),
              !text.isEmpty, text.count <= SelectionPlugin.sourceLimit else { return false }
        let slot = WriteBackSlot(element: nil, original: text, sourceApp: app)
        SelectionPluginBar.shared.show(
            source: text, plugins: plugins, catalog: SelectionPluginStore.shared.plugins, rect: nil
        ) { plugin, source in
            SelectionPluginBar.shared.hide()
            SelectionPluginRunner.run(plugin, source: source, slot: slot, app: app)
        }
        return true
    }

    enum SelectionRead {
        case found(PluginSelection)
        case empty
        case unreadable
    }

    /// 文件、表格、列表：⌘C 复制的是条目本身，不是字。
    private nonisolated static let itemRoles: Set<String> = [
        "AXList", "AXOutline", "AXTable", "AXBrowser", "AXGrid", "AXRow", "AXCell", "AXImage",
    ]

    /// 在辅助功能队列上做的读取：选区、选区范围、能不能写回。
    /// 这几下都带超时，放在主线程上做会让鼠标松开的那一刻顿一下。
    /// `wake` 时读不到焦点就替这个进程打开辅助功能树（每个进程只开一次）。
    private nonisolated static func readSelection(pid: pid_t, wake: Bool) -> SelectionRead {
        guard AXIsProcessTrusted() else { return .empty }
        guard let element = QuickAX.editor(pid: pid, timeout: 0.3, wake: wake) else { return .unreadable }
        // Chromium 的网页正文常把 `AXSelectedText` 答成空串，真正的选区只在文本标记里。
        var plain = AXEditing.string(element, kAXSelectedTextAttribute as String)
        if (plain ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
           let marked = markerSelectionText(element) {
            plain = marked
        }
        guard let raw = plain else {
            // 焦点落在文件列表、表格上：不是读不了，是这里本来就没有字可划。
            if let role = AXEditing.role(element), itemRoles.contains(role) { return .empty }
            return .unreadable
        }
        guard !raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return .empty }
        let markers = AXEditing.isWebEditor(element) ? AXEditing.selectionMarkers(element) : nil
        let writable = SelectionGrabber.writableWithoutMainActor(element)
        return .found(PluginSelection(
            element: element,
            text: raw,
            markers: markers,
            writable: writable,
            rect: QuickAX.selectionOnlyRect(element)
        ))
    }

    /// 网页编辑区有时只把选区放在文本标记里。
    private nonisolated static func markerSelectionText(_ element: AXUIElement) -> String? {
        guard let markers = AXEditing.selectionMarkers(element) else { return nil }
        return AXEditing.parameterized(element, "AXStringForTextMarkerRange", markers.selection) as? String
    }
}

/// 一次探测的结果。`AXUIElement` 不是 Sendable，但这个结构只在辅助功能队列上写完，
/// 然后整份交回主线程用，写回时也只在一个地方读。
struct PluginSelection: @unchecked Sendable {
    let element: AXUIElement
    let text: String
    let markers: AXEditing.SelectionMarkers?
    let writable: Bool
    let rect: CGRect?
}

// MARK: - 点一下之后

@MainActor
enum SelectionPluginRunner {
    /// 翻译走和菜单项一样的路，写回也照旧。脚本就地跑。AI 插件问一家 AI。
    /// 三种结果都进同一个浮层。
    static func run(_ plugin: SelectionPlugin, source: String, slot: WriteBackSlot, app: NSRunningApplication?) {
        guard let delegate = AppDelegate.shared else { return }
        switch plugin.kind {
        case .translate:
            delegate.panelTask?.cancel()
            delegate.panelTask = Task { @MainActor in
                await delegate.run(
                    source,
                    kind: "select",
                    writeBack: slot,
                    appName: app?.localizedName,
                    bundleID: app?.bundleIdentifier
                )
            }
            return
        case .script:
            delegate.panelTask?.cancel()
            delegate.panelTask = Task { @MainActor in
                await runScript(plugin, source: source, writeBack: slot, app: app, reusePanel: false)
            }
        case .ai:
            delegate.panelTask?.cancel()
            delegate.panelTask = Task { @MainActor in
                await delegate.runPlugin(plugin, source: source, writeBack: slot, app: app)
            }
        }
        // 浮层上的「重新翻译」要重跑这一个插件，而不是退回普通翻译。
        delegate.popup.model.sessionPlugin = plugin
    }

    /// 在后台跑脚本，结果照翻译浮层的样子摆出来。和 `AppDelegate.runPlugin` 同一套收尾。
    static func runScript(
        _ plugin: SelectionPlugin,
        source: String,
        writeBack: WriteBackSlot?,
        app: NSRunningApplication?,
        reusePanel: Bool
    ) async {
        guard let delegate = AppDelegate.shared else { return }
        delegate.beginPluginRun(plugin, source: source, writeBack: writeBack, app: app, reusePanel: reusePanel)
        let tabID = delegate.popup.model.activeTabID
        delegate.popup.updateOutcomes(
            [ProviderOutcome(id: "plugin:\(plugin.id)", name: plugin.title, text: nil, error: nil, loading: true)],
            direction: plugin.title,
            tabID: tabID,
            refresh: false
        )
        let outcome: ProviderOutcome
        do {
            let output = try await Background.run {
                try PluginScript.run(plugin.script ?? "", text: source)
            }
            outcome = ProviderOutcome(
                id: "plugin:\(plugin.id)", name: plugin.title,
                text: output.isEmpty ? nil : output,
                error: output.isEmpty ? L("脚本没有返回内容") : nil,
                loading: false
            )
        } catch {
            outcome = ProviderOutcome(
                id: "plugin:\(plugin.id)", name: plugin.title,
                text: nil, error: error.localizedDescription, loading: false
            )
        }
        guard !Task.isCancelled else {
            delegate.popup.settlePluginLoading(tabID: tabID)
            return
        }
        delegate.popup.showMulti(MultiResult(direction: plugin.title, outcomes: [outcome]), tabID: tabID)
        guard let text = outcome.text else { return }
        let histApp = app?.localizedName
        let histBundle = app?.bundleIdentifier
        let name = plugin.title
        Task.detached(priority: .utility) {
            HistoryStore.append(
                source: source,
                direction: name,
                kind: "plugin",
                results: [HistoryProviderResult(id: "plugin:\(plugin.id)", name: name, text: text, error: nil)],
                appName: histApp,
                bundleID: histBundle
            )
        }
    }
}

// MARK: - 设置

/// 设置 › 功能 › 划词插件。开关、AI、插件表都在这一页。
struct SelectionPluginSettingsSection: View {
    @ObservedObject private var store = SelectionPluginStore.shared
    @State private var adding = false
    @State private var editing: SelectionPlugin?
    @State private var confirmReset = false
    @State private var dragging: String?

    var body: some View {
        Group {
            Section {
                Toggle(isOn: Binding(
                    get: { store.isOn },
                    set: { store.isOn = $0 }
                )) {
                    Text(L("划词后显示插件"))
                    Text(L("在其他 App 里划选文字，选区上方浮出一排插件图标，点一下直接出结果"))
                }
                .toggleStyle(SegmentedToggleStyle())
            } footer: {
                Text(L("需要辅助功能权限。点图标不会抢走原来那个应用的焦点。翻译是其中一个插件；其余插件要么问下下面选的 AI，要么在本机跑一段脚本。"))
            }

            if store.isOn {
                Section {
                    Picker(L("AI"), selection: Binding(
                        get: { store.aiProfileID },
                        set: { store.aiProfileID = $0 }
                    )) {
                        Text(L("自动（第一个可用）")).tag("")
                        ForEach(store.readyAIProfiles) { p in
                            Text(p.name).tag(p.id)
                        }
                    }
                    if store.aiProfile == nil {
                        Text(L("还没有可用的 AI。到「翻译 › 服务」里加一家，填好密钥、地址和模型。"))
                            .font(.caption)
                            .foregroundStyle(Theme.attention)
                    }
                } header: {
                    Text(L("插件用的 AI"))
                } footer: {
                    Text(L("翻译插件不用这里，它走「翻译 › 服务」里给划词选的那几家。"))
                }

                Section {
                    pluginList
                    Button {
                        adding = true
                    } label: {
                        Label(L("添加插件"), systemImage: "plus")
                    }
                    Button(L("恢复默认插件")) {
                        confirmReset = true
                    }
                    .disabled(store.isDefault)
                } header: {
                    Text(L("插件"))
                } footer: {
                    Text(L("勾选的可以拖动排序。前 5 个出现在划词条上，其余收进「⋯」。没勾选的不在条上，放大镜和「⋯」里搜得到。翻译也是普通插件，可以不勾。"))
                }
            }
        }
        .sheet(isPresented: $adding) {
            SelectionPluginSheet(plugin: nil) { title, symbol, prompt, script in
                store.add(
                    title: title, symbol: symbol, prompt: prompt,
                    script: script.isEmpty ? nil : script
                )
            }
        }
        .sheet(item: $editing) { plugin in
            SelectionPluginSheet(plugin: plugin) { title, symbol, prompt, script in
                var next = plugin
                next.title = title
                next.symbol = symbol
                next.prompt = prompt
                next.script = script.isEmpty ? nil : script
                store.update(next)
            }
        }
        .confirmationDialog(L("恢复默认插件？"), isPresented: $confirmReset) {
            Button(L("恢复默认"), role: .destructive) { store.reset() }
            Button(L("取消"), role: .cancel) {}
        } message: {
            Text(L("自己加的插件会一起删掉。"))
        }
    }

    /// 勾上的在前，按表里的顺序；前 5 个和后面的之间写一条「以下收进「⋯」」。没勾的排在最后。
    private var pluginList: some View {
        let enabled = store.plugins.filter(\.enabled)
        let disabled = store.plugins.filter { !$0.enabled }
        return Group {
            ForEach(Array(enabled.enumerated()), id: \.element.id) { index, plugin in
                if index == SelectionPluginBar.barSlots {
                    Text(L("以下收进「⋯」"))
                        .font(Theme.TypeScale.caption)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                pluginRow(plugin, draggable: true)
            }
            ForEach(disabled) { plugin in
                pluginRow(plugin, draggable: false)
            }
        }
    }

    private func pluginRow(_ plugin: SelectionPlugin, draggable: Bool) -> some View {
        HStack(spacing: 8) {
            if draggable {
                Image(systemName: "line.3.horizontal")
                    .font(Theme.TypeScale.caption)
                    .foregroundStyle(.secondary)
            }
            Toggle(isOn: Binding(
                get: { plugin.enabled },
                set: { store.setEnabled($0, id: plugin.id) }
            )) {
                EmptyView()
            }
            .toggleStyle(CheckToggleStyle())

            Image(systemName: plugin.symbol)
                .font(Theme.TypeScale.body)
                .frame(width: 18)
            VStack(alignment: .leading, spacing: 1) {
                Text(plugin.title)
                Text(plugin.summary)
                    .font(Theme.TypeScale.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 8)
            Button {
                editing = plugin
            } label: {
                Image(systemName: "pencil")
            }
            .buttonStyle(.borderless)
            .help(L("编辑"))
            .disabled(plugin.isTranslate)
            Button {
                store.remove(id: plugin.id)
            } label: {
                Image(systemName: "trash")
            }
            .buttonStyle(.borderless)
            .help(L("删除"))
        }
        .opacity(dragging == plugin.id ? 0.4 : 1)
        .onDrag {
            guard draggable else { return NSItemProvider() }
            dragging = plugin.id
            return NSItemProvider(object: plugin.id as NSString)
        }
        .onDrop(of: [.plainText], delegate: PluginReorderDrop(
            target: plugin.id,
            dragging: $dragging,
            enabled: draggable,
            move: { store.move(id: $0, before: $1) }
        ))
    }
}

/// 勾选的插件之间拖动换序。拖进某一行就插到它前面，和设置里别的可排序列表一样。
/// 拖到没勾选的行上不起作用。
private struct PluginReorderDrop: DropDelegate {
    let target: String
    @Binding var dragging: String?
    let enabled: Bool
    let move: (String, String?) -> Void

    func dropEntered(info: DropInfo) {
        guard enabled, let dragging, dragging != target else { return }
        move(dragging, target)
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        DropProposal(operation: enabled ? .move : .forbidden)
    }

    func performDrop(info: DropInfo) -> Bool {
        dragging = nil
        return true
    }
}

/// 新建或改一个插件：名字、图标，以及它怎么算 —— 问 AI，还是跑一段脚本。
private struct SelectionPluginSheet: View {
    let plugin: SelectionPlugin?
    let onSave: (String, String, String, String) -> Void

    private enum Mode: String, CaseIterable, Identifiable {
        case ai, script
        var id: String { rawValue }
        var title: String { self == .ai ? L("问 AI") : L("脚本") }
    }

    @Environment(\.dismiss) private var dismiss
    @State private var title = ""
    @State private var symbol = "sparkles"
    @State private var prompt = ""
    @State private var script = ""
    @State private var mode: Mode = .ai
    /// 让 AI 写脚本时的一句话要求。不存进插件，只用于这一次生成。
    @State private var intent = ""
    @State private var generating = false
    @State private var generateError: String?
    /// 生成脚本用的 AI 和模型。只在这次编辑里有效，不改插件运行时的设置。
    @State private var generateProfileID = ""
    @State private var generateModels: ModelOverrides = [:]
    @State private var showSymbols = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(plugin == nil ? L("添加插件") : L("编辑插件"))
                .font(.headline)

            HStack(spacing: 8) {
                Button {
                    showSymbols.toggle()
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: symbol)
                            .font(Theme.TypeScale.reading)
                            .frame(width: 20, height: 20)
                        Image(systemName: "chevron.down")
                            .font(Theme.TypeScale.micro)
                            .foregroundStyle(.secondary)
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 5)
                    .background(
                        RoundedRectangle(cornerRadius: 6)
                            .fill(Color.primary.opacity(0.06))
                    )
                    .contentShape(RoundedRectangle(cornerRadius: 6))
                }
                .buttonStyle(.plain)
                .help(L("图标"))
                .popover(isPresented: $showSymbols, arrowEdge: .bottom) {
                    SymbolPicker(selection: $symbol) { showSymbols = false }
                }

                TextField(L("名字"), text: $title)
                    .textFieldStyle(.roundedBorder)
            }

            PillSegmented(
                selection: $mode,
                options: Mode.allCases.map { ($0, $0.title) }
            )

            if mode == .ai {
                VStack(alignment: .leading, spacing: 6) {
                    Text(L("提示词")).font(.caption).foregroundStyle(.secondary)
                    TextEditor(text: $prompt)
                        .font(Theme.TypeScale.label)
                        .scrollContentBackground(.hidden)
                        .frame(height: 92)
                        .overlay(
                            RoundedRectangle(cornerRadius: 6)
                                .strokeBorder(Color.primary.opacity(0.15))
                        )
                }
            } else {
                VStack(alignment: .leading, spacing: 6) {
                    HStack(alignment: .firstTextBaseline) {
                        Text(L("脚本（JavaScript）"))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Spacer(minLength: 8)
                        if generating {
                            ProgressView()
                                .controlSize(.mini)
                        }
                        Button(L("让 AI 写")) {
                            generateScript()
                        }
                        .controlSize(.small)
                        .disabled(generating || intent.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                        .help(L("按上面那句话生成一段脚本，填进下面，再自己改"))
                    }
                    HStack(spacing: 8) {
                        Menu {
                            Picker("", selection: $generateProfileID) {
                                ForEach(SelectionPluginStore.shared.readyAIProfiles) { p in
                                    Text(p.name).tag(p.id)
                                }
                            }
                            .pickerStyle(.inline)
                            .labelsHidden()
                        } label: {
                            Label(generateProfileName, systemImage: "sparkles")
                                .font(Theme.TypeScale.caption)
                        }
                        .menuStyle(.borderlessButton)
                        .fixedSize()
                        .help(L("用哪一家 AI 来写脚本"))

                        if let profile = generateProfile {
                            ModelOverrideMenu(
                                profile: profile,
                                override: Binding(
                                    get: { generateModels[profile.id] },
                                    set: { generateModels.setModel($0, for: profile) }
                                ),
                                maxWidth: 190,
                                freeBadge: false
                            )
                        }
                    }

                    TextField(L("想让它做什么，例如：把日期改成 2006-01-02 的样子"), text: $intent)
                        .textFieldStyle(.roundedBorder)
                    ScriptEditor(text: $script)
                        .frame(height: 132)
                        .overlay(
                            RoundedRectangle(cornerRadius: 6)
                                .strokeBorder(Color.primary.opacity(0.15))
                        )
                    if let generateError {
                        Text(generateError)
                            .font(.caption)
                            .foregroundStyle(Theme.danger)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Text(L("划选的字就是变量 text。返回什么就显示什么，也可以写 output = …. 不联网、不花钱，本机跑。别写死循环——界面不卡，但这条线程会一直占着。"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            HStack {
                Spacer()
                Button(L("取消")) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button(L("保存")) {
                    onSave(
                        title.trimmingCharacters(in: .whitespacesAndNewlines),
                        symbol,
                        prompt.trimmingCharacters(in: .whitespacesAndNewlines),
                        mode == .script ? script.trimmingCharacters(in: .whitespacesAndNewlines) : ""
                    )
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(!canSave)
            }
        }
        .padding(18)
        .frame(width: 420)
        .onAppear {
            generateProfileID = SelectionPluginStore.shared.aiProfile?.id ?? ""
            guard let plugin else { return }
            title = plugin.title
            symbol = plugin.symbol
            prompt = plugin.prompt
            script = plugin.script ?? ""
            mode = plugin.isScript ? .script : .ai
        }
    }

    /// 这次编辑里选的那家 AI，换过模型就带上换过的。
    private var generateProfile: AIProfile? {
        let store = SelectionPluginStore.shared
        let base = store.readyAIProfiles.first { $0.id == generateProfileID }
            ?? store.aiProfile
        return base?.withModel(generateModels[base?.id ?? ""])
    }

    private var generateProfileName: String {
        generateProfile?.name ?? L("选 AI")
    }

    /// 让插件用的那家 AI 写一段脚本。约定写死在这里，生成的东西才能直接跑。
    private func generateScript() {
        generateError = nil
        guard let profile = generateProfile else {
            generateError = L("没有可用的 AI，先在设置里加一家")
            return
        }
        let want = intent.trimmingCharacters(in: .whitespacesAndNewlines)
        let contract = """
        你在为一个 macOS 划词插件的脚本模式写 JavaScript。运行环境是 JavaScriptCore，没有浏览器和 Node 的 API。

        约定：
        - 用户划选的字已经在变量 text 里（字符串）。
        - 脚本的返回值就是显示给用户的结果；也可以给 output 赋值。
        - 顶层可以直接写 return，会被包进一个函数里执行。
        - 只能用纯 JavaScript（String/Array/RegExp/JSON/Math/Date 等），没有 DOM、没有 fetch、没有 require、没有 import。需要多行时用 \\n。
        - 只输出脚本本身，不要 Markdown 代码围栏，不要解释。

        用户想要的效果：\(want)
        """
        generating = true
        Task { @MainActor in
            defer { generating = false }
            do {
                let reply = try await Background.run {
                    try await ChatAPI.complete(
                        instruction: contract,
                        source: title.trimmingCharacters(in: .whitespacesAndNewlines),
                        profile: profile
                    )
                }
                script = Self.strippingFences(reply)
            } catch is MaskDeclined {
                // 用户在确认框里点了取消，什么都不做。
            } catch {
                generateError = error.localizedDescription
            }
        }
    }

    /// 模型常常还是会带围栏。取围栏里的那段；没有围栏就原样。
    private static func strippingFences(_ text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("```") else { return trimmed }
        var lines = trimmed.components(separatedBy: .newlines)
        lines.removeFirst()
        if let last = lines.last, last.trimmingCharacters(in: .whitespaces).hasPrefix("```") {
            lines.removeLast()
        }
        return lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var canSave: Bool {
        guard !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return false }
        switch mode {
        case .ai: return !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        case .script: return !script.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
    }
}


/// 不是 key 的面板默认要把第一下点击拿去激活窗口。这一层认下第一下，按钮直接可用。
private final class FirstMouseView: NSView {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

// MARK: - 脚本

/// 跑插件脚本。划词内容就是脚本里的 `text` 变量，脚本返回什么，结果就是什么。
///
/// 用 macOS 自带的 JavaScriptCore，不联网、不读文件，也不会花钱。脚本跑在后台队列上，
/// 写得慢也不挡界面；但写死循环会一直占着那一条线程，所以设置页里提醒一句。
enum PluginScript {
    /// 单次运行的上限字数按划词那一份走，这里不再另设。
    /// 返回非空的字符串。脚本抛错时抛出说明，脚本没返回东西时返回空串。
    nonisolated static func run(_ code: String, text: String) throws -> String {
        guard let context = JSContext() else {
            throw TErr(L("脚本引擎起不来"))
        }
        var failure: String?
        context.exceptionHandler = { _, exception in
            failure = exception?.toString() ?? L("脚本出错")
        }
        // `text` 放在全局，脚本里直接写 text 就行；同时作为参数传进去，
        // 这样顶层可以写 return，不必包一层函数。
        context.setObject(text, forKeyedSubscript: "__korgiText" as NSString)
        let wrapped = """
        (function(text) {
        \(code)
        })(__korgiText)
        """
        let value = context.evaluateScript(wrapped)
        if let failure, !failure.isEmpty {
            throw TErr(failure)
        }
        if let value, !value.isUndefined, !value.isNull {
            return stringify(value, in: context)
        }
        // 没写 return 时，看看有没有留下一个叫 output 的变量。
        let output = context.objectForKeyedSubscript("output")
        if let output, !output.isUndefined, !output.isNull {
            return stringify(output, in: context)
        }
        return ""
    }

    /// 字符串原样；数字、布尔按字面；数组和对象按 JSON 打出来，免得显示成 [object Object]。
    private nonisolated static func stringify(_ value: JSValue, in context: JSContext) -> String {
        if value.isArray || value.isObject {
            if let json = context.objectForKeyedSubscript("JSON")?
                .invokeMethod("stringify", withArguments: [value])?.toString(),
               !json.isEmpty, json != "undefined" {
                return json
            }
        }
        return value.toString() ?? ""
    }
}

/// 图标面板：按用途分组的一大片 SF Symbols，按钮上点开，选完自动收起。
private struct SymbolPicker: View {
    @Binding var selection: String
    let done: () -> Void

    /// 分组。用计算属性而不是 static let，切换语言后标题才会跟着变。
    private var groups: [(String, [String])] {
        [
            (L("翻译与语言"), [
                "character.bubble", "text.bubble", "globe", "character.book.closed",
                "book.closed", "quote.bubble", "bubble.left.and.bubble.right",
                "text.book.closed", "character.cursor.ibeam",
            ]),
            (L("文字处理"), [
                "text.alignleft", "text.aligncenter", "text.justify", "list.bullet",
                "list.number", "list.clipboard", "textformat", "textformat.size",
                "text.badge.checkmark", "text.redaction", "text.magnifyingglass",
                "character.textbox", "text.append", "text.quote", "scissors", "doc.on.doc",
            ]),
            (L("AI 与灵感"), [
                "sparkles", "wand.and.sparkles", "wand.and.stars", "lightbulb",
                "brain", "brain.head.profile", "questionmark.circle", "bolt",
                "flame", "star", "moon.stars", "atom",
            ]),
            (L("知识与检索"), [
                "book", "books.vertical", "magnifyingglass", "doc.text.magnifyingglass",
                "graduationcap", "bookmark", "link", "academiccap", "newspaper",
                "text.magnifyingglass", "tray.full", "archivebox",
            ]),
            (L("工具"), [
                "hammer", "wrench.and.screwdriver", "gearshape", "slider.horizontal.3",
                "terminal", "curlybraces", "number", "function", "calendar",
                "clock", "tag", "envelope", "paperplane", "arrow.triangle.2.circlepath",
                "chart.bar", "tablecells", "square.grid.2x2", "folder",
            ]),
            (L("标记与人物"), [
                "flag", "heart", "hand.thumbsup", "person.crop.circle", "checkmark.seal",
                "shield", "leaf", "sun.max", "cloud", "mappin.and.ellipse", "bell",
                "camera", "photo", "film", "music.note", "paintbrush",
            ]),
        ]
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                ForEach(groups, id: \.0) { group in
                    VStack(alignment: .leading, spacing: 4) {
                        Text(group.0)
                            .font(Theme.TypeScale.caption)
                            .foregroundStyle(.secondary)
                        LazyVGrid(columns: columns, spacing: 4) {
                            ForEach(group.1, id: \.self) { name in
                                cell(name)
                            }
                        }
                    }
                }
            }
            .padding(12)
        }
        .frame(width: 336, height: 380)
    }

    private var columns: [GridItem] {
        Array(repeating: GridItem(.fixed(30), spacing: 4), count: 9)
    }

    private func cell(_ name: String) -> some View {
        let on = selection == name
        return Button {
            selection = name
            done()
        } label: {
            Image(systemName: name)
                .font(Theme.TypeScale.reading)
                .frame(width: 30, height: 30)
                .background(
                    RoundedRectangle(cornerRadius: 6)
                        .fill(on ? Color.accentColor.opacity(0.22) : Color.primary.opacity(0.05))
                )
                .foregroundStyle(on ? Color.accentColor : Color.primary)
                .contentShape(RoundedRectangle(cornerRadius: 6))
        }
        .buttonStyle(.plain)
        .help(name)
    }
}
