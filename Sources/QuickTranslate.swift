import AppKit
import ApplicationServices
import Carbon.HIToolbox
import Combine
import CoreGraphics

/// 快捷翻译：其他应用的输入框里，连按三下空格，把划选或整段换成一家供应商的译文。
@MainActor
enum QuickTranslate {
    private static var configWatch: AnyCancellable?
    private static var undoRecord: QuickUndoRecord?

    private struct QuickUndoRecord {
        var pid: pid_t
        var original: String
        var translated: String
    }

    /// 组合键那条路。没有手势空格要去掉。
    static func perform() {
        guard let front = NSWorkspace.shared.frontmostApplication,
              front.processIdentifier != getpid() else { return }
        if isExcluded(front.bundleIdentifier) { return }
        guard QuickSpaceTap.shared.claim() else { return }
        Task {
            await run(.field(pid: front.processIdentifier, typedSpaces: 0))
            QuickSpaceTap.shared.release()
        }
    }

    /// 连按三下空格。装不上时返回说明，组合键那条路不受影响。
    static func enableSpaceGesture() -> String? {
        watchConfig()
        QuickSpaceTap.shared.setExcluded(Set(AppConfig.shared.quickExcludedApps))
        return QuickSpaceTap.shared.install()
            ? nil
            : L("需要在系统设置的「输入监视」里允许本应用，连按三下空格才能用。允许后重新打开一次。")
    }

    static func disableSpaceGesture() {
        QuickSpaceTap.shared.remove()
    }

    static func isExcluded(_ bundleID: String?) -> Bool {
        guard let bundleID else { return false }
        return AppConfig.shared.quickExcludedApps.contains(bundleID)
    }

    private static func watchConfig() {
        guard configWatch == nil else { return }
        configWatch = AppConfig.shared.$quickExcludedApps.sink { list in
            QuickSpaceTap.shared.setExcluded(Set(list))
        }
    }

    fileprivate static func run(_ trigger: QuickTrigger) async {
        let overlay = QuickOverlay.shared
        guard let app = NSRunningApplication(processIdentifier: trigger.pid), !app.isTerminated else { return }
        guard AXIsProcessTrusted() else {
            overlay.fail(L("快捷翻译需要辅助功能权限"), rect: nil)
            Onboarding.showPermissions(pane: .accessibility)
            return
        }
        let bundleID = app.bundleIdentifier
        guard let target = AppConfig.shared.quickTranslateTarget(bundleID: bundleID) else {
            overlay.fail(L("没有可用的翻译服务"), rect: nil)
            return
        }
        let read: QuickRead
        switch await QuickReader.read(trigger) {
        case .success(let got):
            read = got
        case .failure(let reason):
            QuickSpaceTap.trace("read failed \(reason.trace) app=\(app.bundleIdentifier ?? "?")")
            overlay.fail(reason.message, rect: reason.rect)
            return
        }
        let language = AppConfig.shared.appTargetLanguage(bundleID: bundleID)
        let plan = Lang.plan(read.text, target: language, mutual: true)
        overlay.begin(rect: read.rect, provider: target.displayName, language: Lang.languageName(plan.tgt))
        QuickSpaceTap.trace("translate len=\(read.text.count) via=\(target.id)")

        let translated: String
        let direction: String
        do {
            let result = try await Translator.translateQuiet(
                read.text,
                target: target,
                language: language,
                mutual: true
            )
            translated = result.text
            direction = result.direction
        } catch {
            QuickSpaceTap.trace("translate failed \(type(of: error)) \((error as NSError).code)")
            await QuickReader.dropGestureSpaces(read)
            overlay.fail(error.localizedDescription, rect: read.rect)
            return
        }
        let plain = MarkdownTextUtil.plain(translated)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !plain.isEmpty else {
            QuickSpaceTap.trace("translation empty")
            await QuickReader.dropGestureSpaces(read)
            overlay.fail(L("译文是空的，没有替换"), rect: read.rect)
            return
        }
        guard await focus(app) else {
            QuickSpaceTap.trace("focus failed app=\(app.bundleIdentifier ?? "?")")
            overlay.fail(L("回不到原来的应用，没有替换"), rect: read.rect)
            return
        }
        let outcome = await QuickField.commit(read, plain: plain)
        QuickSpaceTap.trace("commit \(outcome)")
        switch outcome {
        case .done:
            overlay.succeed()
            TryProbe.land(.quick, source: read.text, translation: plain)
        case .changed:
            overlay.fail(L("输入框里的字已经变了，没有替换"), rect: read.rect)
            return
        case .rejected:
            await QuickReader.dropGestureSpaces(read)
            overlay.fail(L("这里写不进去，没有替换"), rect: read.rect)
            return
        }
        // 写盘不在主线程上做：历史和译文都在这里，落盘要读整份再写回。
        let histSource = read.text
        let histApp = app.localizedName
        let histBundle = app.bundleIdentifier
        Task.detached(priority: .utility) {
            HistoryStore.append(
                source: histSource,
                direction: direction,
                kind: "quick",
                results: [HistoryProviderResult(id: target.id, name: target.displayName, text: plain, error: nil)],
                appName: histApp,
                bundleID: histBundle
            )
        }
        undoRecord = QuickUndoRecord(pid: read.pid, original: read.text, translated: plain)
    }

    static var canUndo: Bool { undoRecord != nil }

    static func undo() async {
        let overlay = QuickOverlay.shared
        guard let record = undoRecord else {
            overlay.fail(L("没有可撤销的快捷翻译"), rect: nil)
            return
        }
        guard AXIsProcessTrusted() else {
            overlay.fail(L("快捷翻译需要辅助功能权限"), rect: nil)
            Onboarding.showPermissions(pane: .accessibility)
            return
        }
        guard let app = NSRunningApplication(processIdentifier: record.pid), !app.isTerminated else {
            undoRecord = nil
            overlay.fail(L("原来的应用已经关了，没有撤销"), rect: nil)
            return
        }
        overlay.begin(rect: nil, provider: L("撤销"))
        guard await focus(app) else {
            overlay.fail(L("回不到原来的应用，没有撤销"), rect: nil)
            return
        }
        var outcome = await QuickAX.run {
            QuickAX.restore(pid: record.pid, expected: record.translated, replacement: record.original)
        }
        if outcome == .rejected {
            // 网页编辑区不接受辅助功能写入，全选、复制确认还是译文，再贴回原文。
            let read = QuickRead(
                pid: record.pid, text: record.translated, span: .value, wholeField: true, typedSpaces: 0, rect: nil
            )
            outcome = await QuickField.pasteConfirmed(read, plain: record.original)
        }
        switch outcome {
        case .done:
            undoRecord = nil
            overlay.succeed()
        case .changed:
            overlay.fail(L("输入框里的字已经变了，没有撤销"), rect: nil)
        case .rejected:
            overlay.fail(L("这里写不回去，没有撤销"), rect: nil)
        }
    }

    private static func focus(_ app: NSRunningApplication) async -> Bool {
        if NSWorkspace.shared.frontmostApplication?.processIdentifier == app.processIdentifier {
            return true
        }
        NSApp.keyWindow?.resignKey()
        NSApp.yieldActivation(to: app)
        app.activate(from: .current, options: [.activateAllWindows])
        for _ in 0..<12 {
            if NSWorkspace.shared.frontmostApplication?.processIdentifier == app.processIdentifier {
                return true
            }
            try? await Task.sleep(nanoseconds: 40_000_000)
        }
        return NSWorkspace.shared.frontmostApplication?.processIdentifier == app.processIdentifier
    }
}

/// 第三下空格按下时已经知道的事。
enum QuickTrigger {
    /// 第一下按下时就有划选。三下空格都没进输入框。
    case selection(pid: pid_t, text: String)
    /// 没有划选。`typedSpaces` 是已经进了输入框的手势空格，最多两格。
    case field(pid: pid_t, typedSpaces: Int)

    var pid: pid_t {
        switch self {
        case .selection(let pid, _), .field(let pid, _): return pid
        }
    }
}

enum QuickSpan {
    case selection, value
}

struct QuickRead {
    var pid: pid_t
    /// 要翻译的原文，手势空格已经去掉。
    var text: String
    var span: QuickSpan
    /// 读到的是整个输入框。写回可以再全选。划选只替换那一段。
    var wholeField: Bool
    /// 进了输入框的手势空格。没换成时删掉。
    var typedSpaces: Int
    /// 辅助功能坐标，左上角为原点。
    var rect: CGRect?
}

struct QuickReadFailure: Error {
    var message: String
    var trace: String
    var rect: CGRect?
}

/// 读原文。辅助功能都在后台队列上问，主线程只做复制粘贴。
@MainActor
enum QuickReader {
    static func read(_ trigger: QuickTrigger) async -> Result<QuickRead, QuickReadFailure> {
        switch trigger {
        case .selection(let pid, let text):
            let rect = await QuickAX.run { () -> CGRect? in
                guard let element = QuickAX.editor(pid: pid, timeout: 0.3, wake: false) else { return nil }
                return QuickAX.overlayRect(element, selection: true)
            }
            return .success(QuickRead(pid: pid, text: text, span: .selection, wholeField: false, typedSpaces: 0, rect: rect))
        case .field(let pid, let typed):
            let snapshot = await QuickAX.run { QuickAX.fieldSnapshot(pid: pid) }
            switch snapshot {
            case .missing:
                return .failure(QuickReadFailure(message: L("找不到输入框"), trace: "no focus", rect: nil))
            case .secure:
                return .failure(QuickReadFailure(message: L("密码框不翻译"), trace: "secure", rect: nil))
            case .selection(let text, let rect):
                return .success(QuickRead(pid: pid, text: text, span: .selection, wholeField: false, typedSpaces: 0, rect: rect))
            case .value(let value, let caret, let rect):
                let source = QuickField.strippingGestureSpaces(value, caret: caret, count: typed)
                guard !source.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                    return .failure(QuickReadFailure(message: L("输入框是空的"), trace: "empty", rect: rect))
                }
                return .success(QuickRead(pid: pid, text: source, span: .value, wholeField: true, typedSpaces: typed, rect: rect))
            case .unreadable(let role, let selectable, let rect):
                guard selectable else {
                    return .failure(QuickReadFailure(message: L("这里读不到输入框里的字"), trace: "role \(role)", rect: rect))
                }
                guard let copied = await readBySelectingAll() else {
                    return .failure(QuickReadFailure(message: L("这里读不到输入框里的字"), trace: "select-all \(role)", rect: rect))
                }
                let source = copied.trimmingCharacters(in: .whitespacesAndNewlines)
                return .success(QuickRead(pid: pid, text: source, span: .selection, wholeField: true, typedSpaces: typed, rect: rect))
            }
        }
    }

    /// 整段读不到时全选再复制。只对文本框做，避免把网页整页选走。
    private static func readBySelectingAll() async -> String? {
        await SelectionGrabber.preservingClipboard { await readBySelectingAllUnguarded() }
    }

    private static func readBySelectingAllUnguarded() async -> String? {
        for tap in [CGEventTapLocation.cgAnnotatedSessionEventTap, .cghidEventTap] {
            SelectionGrabber.selectAll(tap: tap)
            try? await Task.sleep(nanoseconds: 120_000_000)
            if let copied = await SelectionGrabber.copyViaCmdC(tap: tap),
               !copied.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return copied
            }
        }
        return nil
    }

    /// 没换成时，把打进去的手势空格删掉。输入框已经被改过就不动。
    static func dropGestureSpaces(_ read: QuickRead) async {
        guard read.typedSpaces > 0, read.span == .value else { return }
        let pid = read.pid
        let removable = await QuickAX.run { () -> Int in
            guard let element = QuickAX.editor(pid: pid, timeout: 0.3, wake: false),
                  let now = QuickAX.fieldText(element) else { return 0 }
            let caret = QuickAX.markerText(element)?.caret ?? QuickAX.caret(element)
            let stripped = QuickField.strippingGestureSpaces(now, caret: caret, count: read.typedSpaces)
            guard stripped == read.text else { return 0 }
            return (now as NSString).length - (stripped as NSString).length
        }
        guard removable > 0, NSWorkspace.shared.frontmostApplication?.processIdentifier == pid else { return }
        QuickSpaceTap.shared.postKeys(CGKeyCode(kVK_Delete), count: removable)
    }
}

enum QuickCommit {
    case done, changed, rejected
}

@MainActor
enum QuickField {
    /// 先改选区或整段的值，并且读回来必须是译文。读不回来就全选或沿用划选，复制确认还是原文，再粘贴。
    static func commit(_ read: QuickRead, plain: String) async -> QuickCommit {
        let direct = await QuickAX.run { () -> QuickCommit? in
            guard let element = QuickAX.editor(pid: read.pid, timeout: 0.5, wake: false) else { return nil }
            return QuickAX.replaceVerified(element, read: read, plain: plain)
        }
        if let direct {
            if direct == .done { QuickSpaceTap.trace("commit ax") }
            if direct != .rejected { return direct }
        }
        return await pasteConfirmed(read, plain: plain)
    }

    /// 粘贴前用复制确认还是刚才那一段。对不上就不贴。贴完不再要求把译文读回来。
    static func pasteConfirmed(_ read: QuickRead, plain: String) async -> QuickCommit {
        await SelectionGrabber.preservingClipboard { await pasteConfirmedUnguarded(read, plain: plain) }
    }

    private static func pasteConfirmedUnguarded(_ read: QuickRead, plain: String) async -> QuickCommit {
        for tap in [CGEventTapLocation.cgAnnotatedSessionEventTap, .cghidEventTap] {
            if read.wholeField {
                SelectionGrabber.selectAll(tap: tap)
                try? await Task.sleep(nanoseconds: 120_000_000)
            }
            // 能用辅助功能读到选区就不复制：复制出来的原文是来源应用写的，带不上临时标记，会进剪贴板历史。
            let pid = read.pid
            let selected = await QuickAX.run { () -> String? in
                guard let element = QuickAX.editor(pid: pid, timeout: 0.3, wake: false) else { return nil }
                return AXEditing.string(element, kAXSelectedTextAttribute as String)
            }
            if let selected, matches(read.text, selected) {
                await SelectionGrabber.pastePlainText(plain, tap: tap)
                QuickSpaceTap.trace("commit pasted (ax confirm)")
                return .done
            }
            guard let copied = await SelectionGrabber.copyViaCmdC(tap: tap),
                  !copied.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { continue }
            guard matches(read.text, copied) else {
                QuickSpaceTap.trace("commit mismatch \(copied.count)/\(read.text.count)")
                return .changed
            }
            await SelectionGrabber.pastePlainText(plain, tap: tap)
            QuickSpaceTap.trace("commit pasted")
            return .done
        }
        QuickSpaceTap.trace("commit copy failed")
        return .rejected
    }

    nonisolated static func matches(_ source: String, _ live: String) -> Bool {
        let trimmedSource = source.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedLive = live.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmedSource == trimmedLive { return true }
        return sameAsideFromGestureSpaces(trimmedSource, trimmedLive)
    }

    /// 原文，或原文里多插了一两格手势空格（半角、不换行、全角）。
    nonisolated static func sameAsideFromGestureSpaces(_ before: String, _ after: String) -> Bool {
        if after == before { return true }
        var i = before.startIndex
        var j = after.startIndex
        var extra = 0
        while j < after.endIndex {
            if i < before.endIndex, before[i] == after[j] {
                i = before.index(after: i)
                j = after.index(after: j)
            } else if extra < 2, isGestureSpace(after[j]) {
                extra += 1
                j = after.index(after: j)
            } else {
                return false
            }
        }
        return i == before.endIndex && extra > 0
    }

    /// 光标前面最多 `count` 格空格是手势打进去的。光标位置读不到时按结尾算。
    nonisolated static func strippingGestureSpaces(_ value: String, caret: Int?, count: Int) -> String {
        guard count > 0 else { return value }
        let ns = value as NSString
        let end = min(max(caret ?? ns.length, 0), ns.length)
        var start = end
        while end - start < count, start > 0 {
            let ch = ns.character(at: start - 1)
            guard ch == 0x20 || ch == 0xA0 || ch == 0x3000 else { break }
            start -= 1
        }
        guard start < end else { return value }
        return ns.replacingCharacters(in: NSRange(location: start, length: end - start), with: "")
    }

    nonisolated private static func isGestureSpace(_ ch: Character) -> Bool {
        ch == " " || ch == "\u{00A0}" || ch == "\u{3000}"
    }
}

/// 辅助功能读写。都在 `queue` 上跑，不占主线程，也不占听键盘的线程。
enum QuickAX {
    static let queue = DispatchQueue(label: "Korgino.quick.ax", qos: .userInitiated)

    private static let lock = NSLock()
    /// 打开辅助功能树的时刻。刚启动的 Chromium 要两秒左右才交出焦点，这段时间里读不到就接着等。
    nonisolated(unsafe) private static var opened: [pid_t: Date] = [:]
    /// 引导里让自家的输入框当目标。只在这一段时间内认自己的进程。
    nonisolated(unsafe) private static var trial = false

    static func setTrial(_ on: Bool) {
        lock.lock()
        trial = on
        lock.unlock()
    }

    private static func isTrial() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return trial
    }

    static func run<T>(_ body: @escaping () -> T) async -> T {
        // 引导里目标就是自己：AX 写属性会直接落回自家的 NSTextView，那条路径只能在主线程走。
        if isTrial() {
            return await withCheckedContinuation { cont in
                DispatchQueue.main.async { cont.resume(returning: body()) }
            }
        }
        return await withCheckedContinuation { cont in
            queue.async { cont.resume(returning: body()) }
        }
    }

    /// 不等结果的版本，同样在主线程接自己的窗口。
    static func spawn(_ body: @escaping () -> Void) {
        if isTrial() {
            DispatchQueue.main.async(execute: body)
        } else {
            queue.async(execute: body)
        }
    }

    enum SelectionProbe {
        case selection(String)
        case none
        case secure
    }

    /// 第一下空格时问：有没有划选。组字中的那段不算划选。
    static func probeSelection(pid: pid_t) -> SelectionProbe {
        guard AXIsProcessTrusted(), let element = editor(pid: pid, timeout: 0.12, wake: true) else { return .none }
        if isSecure(element) { return .secure }
        if hasMarkedText(element) { return .none }
        if let selected = string(element, kAXSelectedTextAttribute),
           !selected.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return .selection(selected)
        }
        return .none
    }

    enum FieldSnapshot {
        case missing
        case secure
        case selection(String, CGRect?)
        case value(String, caret: Int?, CGRect?)
        case unreadable(role: String, selectable: Bool, CGRect?)
    }

    static func fieldSnapshot(pid: pid_t) -> FieldSnapshot {
        guard let inner = focused(pid: pid, timeout: 0.3, wake: true) else { return .missing }
        let element = editingRoot(inner)
        if isSecure(element) { return .secure }
        if let selected = string(element, kAXSelectedTextAttribute),
           !selected.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return .selection(selected, overlayRect(element, selection: true))
        }
        let rect = overlayRect(element, selection: false)
        let value = valueText(element)
        let editable = isEditable(element)
        let marked = editable ? markerText(element) : nil
        QuickSpaceTap.trace(
            "field role=\(role(inner) ?? "?")>\(role(element) ?? "?") value=\((value as NSString?)?.length ?? -1) marker=\((marked?.text as NSString?)?.length ?? -1)"
        )
        if !editable, (value ?? "").isEmpty { return .missing }
        if let marked, (value ?? "").isEmpty || (marked.text as NSString).length > ((value ?? "") as NSString).length {
            return .value(marked.text, caret: marked.caret ?? caret(element), rect)
        }
        if let value {
            return .value(value, caret: caret(element), rect)
        }
        return .unreadable(role: role(element) ?? "?", selectable: canSelectAll(element), rect)
    }

    /// 焦点所在的编辑区。网页里焦点常落在编辑区里的某一段上，读写都要对着整个编辑区。
    static func editor(pid: pid_t, timeout: Float, wake: Bool) -> AXUIElement? {
        focused(pid: pid, timeout: timeout, wake: wake).map(editingRoot)
    }

    static func editingRoot(_ element: AXUIElement) -> AXUIElement {
        AXEditing.editingRoot(element)
    }

    /// 网页编辑区（Gecko 的正文、Chromium 的 contenteditable）的 AXValue 常是空的，字要按文本标记读。
    /// 只读可编辑的元素：整页网页也能这样读出全文。
    static func markerText(_ element: AXUIElement) -> (text: String, caret: Int?)? {
        guard let whole = markerRange(element),
              let text = parameterized(element, "AXStringForTextMarkerRange", whole) as? String else { return nil }
        var caret: Int?
        if let start = parameterized(element, "AXStartTextMarkerForTextMarkerRange", whole),
           let selection = attribute(element, "AXSelectedTextMarkerRange"),
           let selectionEnd = parameterized(element, "AXEndTextMarkerForTextMarkerRange", selection),
           let head = parameterized(element, "AXTextMarkerRangeForUnorderedTextMarkers", [start, selectionEnd] as CFArray),
           let length = parameterized(element, "AXLengthForTextMarkerRange", head) as? Int {
            caret = length
        }
        return (text, caret)
    }

    /// Chromium 的 `AXStartTextMarker` 是整页的开头，只有元素本身就是文档（Gecko 的正文）时才能用。
    private static func markerRange(_ element: AXUIElement) -> CFTypeRef? {
        if let own = parameterized(element, "AXTextMarkerRangeForUIElement", element) { return own }
        guard role(element) == "AXWebArea",
              let start = attribute(element, "AXStartTextMarker"),
              let end = attribute(element, "AXEndTextMarker") else { return nil }
        return parameterized(element, "AXTextMarkerRangeForUnorderedTextMarkers", [start, end] as CFArray)
    }

    /// 读写时用的正文：AXValue，空的话退到文本标记。
    static func fieldText(_ element: AXUIElement) -> String? {
        let value = valueText(element)
        guard isEditable(element), let marked = markerText(element)?.text else { return value }
        if (value ?? "").isEmpty || (marked as NSString).length > ((value ?? "") as NSString).length { return marked }
        return value
    }

    /// 当前焦点是能写入的输入框。窗口、按钮、普通网页不算。
    static func canInsert(pid: pid_t) -> Bool {
        guard pid != 0, AXIsProcessTrusted() else { return false }
        guard let app = NSRunningApplication(processIdentifier: pid), !app.isTerminated else { return false }
        let root = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(root, 0.12)
        var found = copyFocused(root)
        if found == nil || shallow(found) {
            _ = openTree(pid: pid, root: root)
            let deadline = Date().addingTimeInterval(0.2)
            while (found == nil || shallow(found)), Date() < deadline {
                usleep(40_000)
                found = copyFocused(root)
            }
        }
        guard let found else { return false }
        AXUIElementSetMessagingTimeout(found, 0.12)
        let box = editingRoot(found)
        return isEditable(box) || isEditable(found)
    }

    private static func isEditable(_ element: AXUIElement) -> Bool {
        if elementAttribute(element, "AXEditableAncestor") != nil { return true }
        switch role(element) {
        case "AXTextField", "AXTextArea", "AXComboBox", "AXSearchField": return true
        default: return false
        }
    }

    private static func attribute(_ element: AXUIElement, _ name: String) -> CFTypeRef? {
        var raw: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name as CFString, &raw) == .success else { return nil }
        return raw
    }

    private static func elementAttribute(_ element: AXUIElement, _ name: String) -> AXUIElement? {
        guard let raw = attribute(element, name), CFGetTypeID(raw) == AXUIElementGetTypeID() else { return nil }
        return (raw as! AXUIElement)
    }

    private static func parameterized(_ element: AXUIElement, _ name: String, _ argument: CFTypeRef) -> CFTypeRef? {
        var raw: CFTypeRef?
        guard AXUIElementCopyParameterizedAttributeValue(element, name as CFString, argument, &raw) == .success else { return nil }
        return raw
    }

    /// 焦点元素。Chromium、Electron、Firefox 系默认不交出焦点；读不到时替这个进程打开一次辅助功能树再问。
    static func focused(pid: pid_t, timeout: Float, wake: Bool) -> AXUIElement? {
        guard let app = NSRunningApplication(processIdentifier: pid), !app.isTerminated else { return nil }
        let root = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(root, timeout)
        var found = copyFocused(root)
        if wake, shallow(found) {
            let deadline = openTree(pid: pid, root: root).addingTimeInterval(3)
            while shallow(found), Date() < deadline {
                usleep(60_000)
                found = copyFocused(root)
            }
        }
        guard let found else { return nil }
        var owner: pid_t = 0
        if AXUIElementGetPid(found, &owner) == .success, owner == getpid(), !isTrial() { return nil }
        AXUIElementSetMessagingTimeout(found, timeout)
        return found
    }

    private static func copyFocused(_ root: AXUIElement) -> AXUIElement? {
        var raw: CFTypeRef?
        guard AXUIElementCopyAttributeValue(root, kAXFocusedUIElementAttribute as CFString, &raw) == .success,
              let raw, CFGetTypeID(raw) == AXUIElementGetTypeID() else { return nil }
        return (raw as! AXUIElement)
    }

    private static func shallow(_ element: AXUIElement?) -> Bool {
        guard let element else { return true }
        let role = role(element)
        return role == nil || role == "AXWindow" || role == "AXApplication"
    }

    /// Electron 认 `AXManualAccessibility`，没副作用。不认的再开 `AXEnhancedUserInterface`。每个进程只开一次，返回打开的时刻。
    private static func openTree(pid: pid_t, root: AXUIElement) -> Date {
        lock.lock()
        if let since = opened[pid] {
            lock.unlock()
            return since
        }
        let now = Date()
        opened[pid] = now
        lock.unlock()
        let manual = AXUIElementSetAttributeValue(root, "AXManualAccessibility" as CFString, kCFBooleanTrue)
        if manual != .success {
            _ = AXUIElementSetAttributeValue(root, "AXEnhancedUserInterface" as CFString, kCFBooleanTrue)
        }
        QuickSpaceTap.trace("open tree pid=\(pid) manual=\(manual.rawValue)")
        return now
    }

    static func forget(pid: pid_t) {
        lock.lock()
        opened[pid] = nil
        lock.unlock()
    }

    /// 辅助功能说写上了，但选区或正文还是原文时，不算成功。光标处插进译文会让选中文字变成译文，整段必须看正文。
    static func restore(pid: pid_t, expected: String, replacement: String) -> QuickCommit {
        guard let element = editor(pid: pid, timeout: 0.5, wake: true) else { return .rejected }
        if isSecure(element) { return .rejected }
        let now = fieldText(element)
        if let selected = string(element, kAXSelectedTextAttribute),
           QuickField.matches(expected, selected), !isChromium(element) {
            let before = now ?? selected
            if setSelected(element, replacement),
               let outcome = settle(element, before: before, done: { _ in
                   string(element, kAXSelectedTextAttribute).map { QuickField.matches(replacement, $0) } ?? false
               }) {
                return outcome
            }
        }
        // 网页编辑区（X 的 Draft.js 等）改 AXValue 只改了 DOM，编辑器自己的状态没变，读回来是对的但不算数。
        if isChromium(element) { return .rejected }
        if let now, QuickField.matches(expected, now) {
            guard setValue(element, replacement) else { return .rejected }
            return caretToEnd(element, after: settle(element, before: now) { QuickField.matches(replacement, $0) } ?? .rejected)
        }
        guard let now else { return .rejected }
        let ns = now as NSString
        let range = ns.range(of: expected)
        guard range.location != NSNotFound else { return .changed }
        let rest = NSRange(location: range.location + range.length, length: ns.length - (range.location + range.length))
        guard ns.range(of: expected, options: [], range: rest).location == NSNotFound else { return .changed }
        guard !isChromium(element),
              selectRange(element, location: range.location, length: range.length),
              setSelected(element, replacement) else { return .rejected }
        let written = ns.replacingCharacters(in: range, with: replacement)
        return settle(element, before: now) { QuickField.matches(written, $0) } ?? .rejected
    }

    static func replaceVerified(_ element: AXUIElement, read: QuickRead, plain: String) -> QuickCommit {
        switch read.span {
        case .selection:
            guard !read.wholeField else { return .rejected }
            guard let now = string(element, kAXSelectedTextAttribute) else { return .rejected }
            guard QuickField.matches(read.text, now) else { return .changed }
            guard !isChromium(element) else { return .rejected }
            let before = fieldText(element)
            guard setSelected(element, plain) else { return .rejected }
            return settle(element, before: before ?? "") { after in
                string(element, kAXSelectedTextAttribute) == plain || (before != nil && after.contains(plain))
            } ?? .rejected
        case .value:
            guard let now = fieldText(element) else { return .rejected }
            guard QuickField.matches(read.text, now) else { return .changed }
            let length = (now as NSString).length
            if !isChromium(element), selectRange(element, location: 0, length: length), setSelected(element, plain),
               let outcome = settle(element, before: now, done: { QuickField.matches(plain, $0) }) {
                return caretToEnd(element, after: outcome)
            }
            // 网页编辑区改 AXValue 会直接改 DOM：读回来是译文，可 Draft.js、Lexical 这类编辑器的状态没变，
            // 下一次按键或发帖就还原。只能走粘贴，让编辑器自己处理。
            guard !isChromium(element) else { return .rejected }
            guard setValue(element, plain) else { return .rejected }
            return caretToEnd(element, after: settle(element, before: now) { QuickField.matches(plain, $0) } ?? .rejected)
        }
    }

    /// 网页编辑区写 `AXSelectedText` 回成功，其实什么都不改。Chromium 之外的原生输入框才走属性写法。
    private static func isChromium(_ element: AXUIElement) -> Bool {
        AXEditing.isWebEditor(element)
    }

    /// 整段换掉后 Chromium 把光标留在开头，接着打字会打到译文前面。
    private static func caretToEnd(_ element: AXUIElement, after outcome: QuickCommit) -> QuickCommit {
        if case .done = outcome, let text = fieldText(element) {
            _ = selectRange(element, location: (text as NSString).length, length: 0)
        }
        return outcome
    }

    /// 写完之后网页编辑区要过一会儿才读得到新字。等到是译文算成；一直是原文说明没写进去，返回空，换下一种写法；
    /// 成了别的样子说明正文已经动了，不能再写第二遍。
    private static func settle(_ element: AXUIElement, before: String, done: (String) -> Bool) -> QuickCommit? {
        var last: String?
        for attempt in 0..<6 {
            if attempt > 0 { usleep(50_000) }
            guard let after = fieldText(element) else { continue }
            if done(after) { return .done }
            last = after
        }
        guard let last, last != before else { return nil }
        return .changed
    }

    // MARK: Geometry

    /// 划选的范围，或输入框本身，裁到窗口里。都读不到时用窗口上沿。
    static func overlayRect(_ element: AXUIElement, selection: Bool) -> CGRect? {
        var rect: CGRect?
        if selection { rect = selectionBounds(element) }
        if rect == nil { rect = frame(element) }
        let window = windowFrame(element)
        if let r = rect, let window {
            let clipped = r.intersection(window)
            rect = clipped.isNull ? nil : clipped
        }
        if rect == nil, let window {
            rect = CGRect(x: window.minX, y: window.minY, width: window.width, height: min(window.height, 44))
        }
        guard let rect, rect.width >= 4, rect.height >= 4 else { return nil }
        return rect
    }

    /// 只要真正的选区范围，读不到就是 nil，绝不退回整个输入框或整个网页的框。
    ///
    /// 划词插件条要贴着选中的那几个字出现。`overlayRect` 在选区读不到时会给元素自己的框，
    /// 网页里那就是整页，条会被摆到页面中间 —— 所以这里另外要一份「只认选区」的。
    static func selectionOnlyRect(_ element: AXUIElement) -> CGRect? {
        var rect = selectionBounds(element)
        if rect == nil {
            // 网页编辑区常把选区放在文本标记里，`AXSelectedTextRange` 却是空的。
            if let markers = AXEditing.selectionMarkers(element),
               let raw = AXEditing.parameterized(
                   element, "AXBoundsForTextMarkerRange", markers.selection
               ) {
                rect = rectValue(raw)
            }
        }
        guard let rect, rect.width >= 2, rect.height >= 2 else { return nil }
        let window = windowFrame(element)
        if let window {
            let clipped = rect.intersection(window)
            return clipped.isNull ? nil : clipped
        }
        return rect
    }

    private static func selectionBounds(_ element: AXUIElement) -> CGRect? {
        var raw: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXSelectedTextRangeAttribute as CFString, &raw) == .success,
              let raw, CFGetTypeID(raw) == AXValueGetTypeID() else { return nil }
        var bounds: CFTypeRef?
        guard AXUIElementCopyParameterizedAttributeValue(
            element, kAXBoundsForRangeParameterizedAttribute as CFString, raw, &bounds
        ) == .success, let bounds else { return nil }
        return rectValue(bounds)
    }

    private static func frame(_ element: AXUIElement) -> CGRect? {
        var raw: CFTypeRef?
        if AXUIElementCopyAttributeValue(element, "AXFrame" as CFString, &raw) == .success, let raw,
           let rect = rectValue(raw) {
            return rect
        }
        var pos: CFTypeRef?
        var size: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXPositionAttribute as CFString, &pos) == .success,
              AXUIElementCopyAttributeValue(element, kAXSizeAttribute as CFString, &size) == .success,
              let pos, let size,
              CFGetTypeID(pos) == AXValueGetTypeID(), CFGetTypeID(size) == AXValueGetTypeID() else { return nil }
        var point = CGPoint.zero
        var extent = CGSize.zero
        guard AXValueGetValue(pos as! AXValue, .cgPoint, &point),
              AXValueGetValue(size as! AXValue, .cgSize, &extent) else { return nil }
        return CGRect(origin: point, size: extent)
    }

    private static func windowFrame(_ element: AXUIElement) -> CGRect? {
        var raw: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXWindowAttribute as CFString, &raw) == .success,
              let raw, CFGetTypeID(raw) == AXUIElementGetTypeID() else { return nil }
        return frame(raw as! AXUIElement)
    }

    private static func rectValue(_ raw: CFTypeRef) -> CGRect? {
        guard CFGetTypeID(raw) == AXValueGetTypeID() else { return nil }
        var rect = CGRect.zero
        guard AXValueGetValue(raw as! AXValue, .cgRect, &rect), rect.width > 0, rect.height > 0 else { return nil }
        return rect
    }

    // MARK: Attributes

    static func valueText(_ element: AXUIElement) -> String? {
        var raw: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXValueAttribute as CFString, &raw) == .success else { return nil }
        return raw as? String
    }

    static func caret(_ element: AXUIElement) -> Int? {
        var raw: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXSelectedTextRangeAttribute as CFString, &raw) == .success,
              let raw, CFGetTypeID(raw) == AXValueGetTypeID() else { return nil }
        var range = CFRange(location: 0, length: 0)
        guard AXValueGetValue(raw as! AXValue, .cfRange, &range) else { return nil }
        return range.location + range.length
    }

    static func role(_ element: AXUIElement) -> String? {
        string(element, kAXRoleAttribute)
    }

    /// 文本框可以全选。网页、窗口、列表不行，避免把整页换成译文。
    private static func canSelectAll(_ element: AXUIElement) -> Bool {
        if isEditable(element) { return true }
        guard let role = role(element) else { return true }
        switch role {
        case "AXTextField", "AXTextArea", "AXComboBox", "AXSearchField":
            return true
        case "AXWebArea", "AXWindow", "AXScrollArea", "AXList", "AXOutline", "AXTable", "AXButton", "AXImage",
             "AXStaticText", "AXLink", "AXGroup", "AXApplication":
            return false
        default:
            return true
        }
    }

    private static func selectRange(_ element: AXUIElement, location: Int, length: Int) -> Bool {
        var range = CFRange(location: location, length: length)
        guard let marker = AXValueCreate(.cfRange, &range) else { return false }
        return AXUIElementSetAttributeValue(element, kAXSelectedTextRangeAttribute as CFString, marker) == .success
    }

    private static func setValue(_ element: AXUIElement, _ text: String) -> Bool {
        AXUIElementSetAttributeValue(element, kAXValueAttribute as CFString, text as CFString) == .success
    }

    private static func setSelected(_ element: AXUIElement, _ text: String) -> Bool {
        AXUIElementSetAttributeValue(element, kAXSelectedTextAttribute as CFString, text as CFString) == .success
    }

    private static func string(_ element: AXUIElement, _ name: String) -> String? {
        var raw: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name as CFString, &raw) == .success else { return nil }
        return raw as? String
    }

    private static func isSecure(_ element: AXUIElement) -> Bool {
        string(element, kAXSubroleAttribute) == "AXSecureTextField"
    }

    private static func hasMarkedText(_ element: AXUIElement) -> Bool {
        for name in ["AXMarkedTextRange", "AXMarkedTextMarkerRange"] {
            var raw: CFTypeRef?
            guard AXUIElementCopyAttributeValue(element, name as CFString, &raw) == .success, let raw else { continue }
            if let marked = raw as? String {
                if !marked.isEmpty { return true }
                continue
            }
            guard CFGetTypeID(raw) == AXValueGetTypeID() else { continue }
            var range = CFRange(location: 0, length: 0)
            if AXValueGetValue(raw as! AXValue, .cfRange, &range), range.length > 0 { return true }
        }
        return false
    }
}

/// 空格手势。监听跑在自己的线程上：回调里只数空格，不问辅助功能，也不等主线程。
/// 手势状态只在这条线程上读写；别的线程通过 `onTap` 把事情排进来。
final class QuickSpaceTap: @unchecked Sendable {
    static let shared = QuickSpaceTap()

    // MARK: Shared across threads (guarded by `lock`)

    private let lock = NSLock()
    private var runLoop: CFRunLoop?
    private var port: CFMachPort?
    private var thread: Thread?
    private var busy = false
    private var excluded: Set<String> = []
    private var dictate = false
    private var trial = false
    private var frontPid: pid_t = 0
    private var frontBundle: String?
    private var trusted = false
    private var observers: [NSObjectProtocol] = []

    // MARK: Tap thread only

    private var gesture: Gesture?
    private var nextToken = 0
    /// 吞掉的空格按下还欠着的抬起。
    private var owedUps = 0
    /// 相邻两下之间。跟系统双击速度走，至少 0.6 秒。
    private let gap: TimeInterval = max(NSEvent.doubleClickInterval, 0.6)
    /// 第一下空格最多扣这么久等划选的答案，过了就先放进去。
    private let probeWait: TimeInterval = 0.15
    /// 自己补回去的按键。再进回调时直接放行。
    static let stamp: Int64 = 0x4B54_5153

    private struct Gesture {
        var token: Int
        var pid: pid_t
        var last: TimeInterval
        var count: Int
        /// 吞下还没补回去的空格。
        var held: Int
        var probe: Probe
        /// 第三下来了，答案还没到。
        var fireOnAnswer: Bool
    }

    private enum Probe {
        case waiting
        case selection(String)
        case open
    }

    // MARK: Lifecycle (main thread)

    @MainActor
    func install() -> Bool {
        lock.lock()
        let running = port != nil
        lock.unlock()
        if running {
            refreshFront(NSWorkspace.shared.frontmostApplication)
            return true
        }
        if !CGPreflightListenEventAccess() {
            _ = CGRequestListenEventAccess()
        }
        var mask: CGEventMask = 0
        for type in [CGEventType.keyDown, .keyUp, .flagsChanged, .leftMouseDown, .rightMouseDown, .otherMouseDown] {
            mask |= CGEventMask(1) << CGEventMask(type.rawValue)
        }
        // 微信输入法在键盘刚进系统时就看空格。装在它后面就数不到用户真正按下的那几下。
        guard let made = CGEvent.tapCreate(
            tap: .cghidEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: mask,
            callback: { proxy, type, event, _ in
                QuickSpaceTap.shared.receive(proxy: proxy, type: type, event: event)
            },
            userInfo: nil
        ) else {
            Self.trace("install failed")
            return false
        }
        watchWorkspace()
        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, made, 0)
        let ready = DispatchSemaphore(value: 0)
        let worker = Thread { [weak self] in
            guard let self, let rl = CFRunLoopGetCurrent() else { ready.signal(); return }
            CFRunLoopAddSource(rl, source, .commonModes)
            CGEvent.tapEnable(tap: made, enable: true)
            self.lock.lock()
            self.runLoop = rl
            self.lock.unlock()
            ready.signal()
            CFRunLoopRun()
        }
        worker.name = "Korgino.quick.tap"
        worker.qualityOfService = .userInteractive
        lock.lock()
        port = made
        thread = worker
        lock.unlock()
        worker.start()
        ready.wait()
        Self.trace("install hid")
        return true
    }

    @MainActor
    func remove() {
        lock.lock()
        let rl = runLoop
        let made = port
        runLoop = nil
        port = nil
        thread = nil
        let watchers = observers
        observers = []
        lock.unlock()
        for observer in watchers {
            NSWorkspace.shared.notificationCenter.removeObserver(observer)
        }
        guard let made else { return }
        CGEvent.tapEnable(tap: made, enable: false)
        CFMachPortInvalidate(made)
        if let rl {
            CFRunLoopPerformBlock(rl, CFRunLoopMode.commonModes.rawValue) { [weak self] in
                self?.gesture = nil
                self?.owedUps = 0
                self?.spaceDown = false
                self?.spaceHoldNoted = false
                CFRunLoopStop(CFRunLoopGetCurrent())
            }
            CFRunLoopWakeUp(rl)
        }
    }

    @MainActor
    private func watchWorkspace() {
        refreshFront(NSWorkspace.shared.frontmostApplication)
        guard observers.isEmpty else { return }
        let center = NSWorkspace.shared.notificationCenter
        let activate = center.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
        ) { [weak self] note in
            let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            MainActor.assumeIsolated { self?.refreshFront(app) }
        }
        let quit = center.addObserver(
            forName: NSWorkspace.didTerminateApplicationNotification, object: nil, queue: .main
        ) { note in
            guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
            QuickAX.forget(pid: app.processIdentifier)
        }
        lock.lock()
        observers = [activate, quit]
        lock.unlock()
    }

    @MainActor
    private func refreshFront(_ app: NSRunningApplication?) {
        let ax = AXIsProcessTrusted()
        lock.lock()
        frontPid = app?.processIdentifier ?? 0
        frontBundle = app?.bundleIdentifier
        trusted = ax
        lock.unlock()
    }

    func setExcluded(_ list: Set<String>) {
        lock.lock()
        excluded = list
        lock.unlock()
    }

    func setDictate(_ on: Bool) {
        lock.lock()
        dictate = on
        lock.unlock()
    }

    /// 引导里把自家窗口当成目标应用。跟着辅助功能那边一起开、一起关。
    func setTrial(_ on: Bool) {
        lock.lock()
        trial = on
        lock.unlock()
        QuickAX.setTrial(on)
    }

    /// 组合键和手势共用一把锁：同一时间只换一处。
    func claim() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if busy { return false }
        busy = true
        return true
    }

    func release() {
        lock.lock()
        busy = false
        lock.unlock()
    }

    private struct Front {
        var pid: pid_t
        var excluded: Bool
        var trusted: Bool
        var busy: Bool
        var dictate: Bool
        var trial: Bool
    }

    private func front() -> Front {
        lock.lock()
        defer { lock.unlock() }
        let skip = frontBundle.map { excluded.contains($0) } ?? false
        return Front(pid: frontPid, excluded: skip, trusted: trusted, busy: busy, dictate: dictate, trial: trial)
    }

    // MARK: Tap thread

    private func receive(proxy: CGEventTapProxy, type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            lock.lock()
            let made = port
            lock.unlock()
            if let made { CGEvent.tapEnable(tap: made, enable: true) }
            return nil
        }
        if event.getIntegerValueField(.eventSourceUserData) == Self.stamp {
            return Unmanaged.passUnretained(event)
        }
        switch type {
        case .leftMouseDown, .rightMouseDown, .otherMouseDown:
            cancel(proxy: proxy)
            dropFn()
            return Unmanaged.passUnretained(event)
        case .flagsChanged:
            return fnFlags(event)
        case .keyUp:
            if event.getIntegerValueField(.keyboardEventKeycode) == Int64(kVK_Function), fnHeld || fnOwned {
                return nil
            }
            if event.getIntegerValueField(.keyboardEventKeycode) == Int64(kVK_Space) {
                spaceDown = false
                spaceHoldNoted = false
                if owedUps > 0 {
                    owedUps -= 1
                    return nil
                }
            }
            return Unmanaged.passUnretained(event)
        case .keyDown:
            return keyDown(proxy: proxy, event: event)
        default:
            return Unmanaged.passUnretained(event)
        }
    }

    private var fnHeld = false
    private var fnOwned = false
    /// 空格还按着。抬起之前再来的按下都是同一次，不管系统有没有标自动重复。
    private var spaceDown = false
    private var spaceHoldNoted = false

    private func dropFn() {
        fnHeld = false
        guard fnOwned else { return }
        fnOwned = false
        DispatchQueue.main.async { FnDictate.shared.cancel() }
    }

    private func fnFlags(_ event: CGEvent) -> Unmanaged<CGEvent>? {
        let down = event.flags.contains(.maskSecondaryFn)
        let chord = !event.flags.intersection([.maskCommand, .maskShift, .maskControl, .maskAlternate]).isEmpty
        let key = event.getIntegerValueField(.keyboardEventKeycode)
        if down, !fnHeld {
            // 只有 Globe 键自己的按下沿才听写。空格按住时，别的键的事件也会带着 Fn 标志。
            let globe = key == Int64(kVK_Function) || key == 0
            if !globe || spaceDown {
                return Unmanaged.passUnretained(event)
            }
            fnHeld = true
            let now = front()
            if !chord, now.dictate, !now.busy {
                fnOwned = true
                let pid = now.pid
                DispatchQueue.main.async { FnDictate.shared.begin(pid: pid) }
                return nil
            }
        } else if !down, fnHeld {
            fnHeld = false
            if fnOwned {
                fnOwned = false
                DispatchQueue.main.async { FnDictate.shared.end() }
                return nil
            }
        } else if down, fnOwned {
            if chord { dropFn() } else { return nil }
        }
        return Unmanaged.passUnretained(event)
    }

    private func keyDown(proxy: CGEventTapProxy, event: CGEvent) -> Unmanaged<CGEvent>? {
        if event.getIntegerValueField(.keyboardEventKeycode) == Int64(kVK_Function) {
            if fnOwned || fnHeld { return nil }
            if event.flags.contains(.maskSecondaryFn) { return fnFlags(event) }
            return Unmanaged.passUnretained(event)
        }
        if fnOwned || fnHeld { dropFn() }
        let modifiers: CGEventFlags = [.maskCommand, .maskAlternate, .maskControl, .maskShift, .maskSecondaryFn]
        let bare = event.flags.intersection(modifiers).isEmpty
        let isSpace = event.getIntegerValueField(.keyboardEventKeycode) == Int64(kVK_Space)
        let repeating = event.getIntegerValueField(.keyboardEventAutorepeat) != 0
        // 系统经常不给「自动重复」这个标记。空格还没抬起又来一次按下，就是同一次按住。
        let held = isSpace && (spaceDown || repeating)
        if isSpace {
            if held, !spaceHoldNoted {
                spaceHoldNoted = true
                Self.trace("space hold")
            }
            spaceDown = true
        }
        // 按住不放、带修饰键、别的键：这一轮不算了。扣下的空格先补回去，再放这一下。
        guard isSpace, bare, !held else {
            cancel(proxy: proxy)
            // 按住空格时，真正的抬起要送到，不然对方以为空格一直按着。
            if held { owedUps = 0 }
            return Unmanaged.passUnretained(event)
        }
        let now = front()
        guard now.pid != 0, now.trial || now.pid != getpid(), !now.excluded, now.trusted, !now.busy else {
            cancel(proxy: proxy)
            return Unmanaged.passUnretained(event)
        }
        let at = ProcessInfo.processInfo.systemUptime

        if var current = gesture, current.pid == now.pid, at - current.last <= gap {
            current.count += 1
            current.last = at
            if current.count >= 3 {
                owedUps += 1
                switch current.probe {
                case .waiting:
                    current.held += 1
                    current.fireOnAnswer = true
                    gesture = current
                case .selection(let text):
                    gesture = nil
                    fire(.selection(pid: current.pid, text: text))
                case .open:
                    gesture = nil
                    fire(.field(pid: current.pid, typedSpaces: 2 - current.held))
                }
                return nil
            }
            gesture = current
            schedule(expiry: current.token, after: gap)
            if current.held > 0 {
                gesture?.held += 1
                owedUps += 1
                return nil
            }
            return Unmanaged.passUnretained(event)
        }

        cancel(proxy: proxy)
        nextToken += 1
        let token = nextToken
        gesture = Gesture(token: token, pid: now.pid, last: at, count: 1, held: 1, probe: .waiting, fireOnAnswer: false)
        owedUps += 1
        let pid = now.pid
        QuickAX.spawn { [weak self] in
            let answer = QuickAX.probeSelection(pid: pid)
            self?.onTap { self?.answered(token, answer) }
        }
        onTap(after: probeWait) { [weak self] in self?.probeTimedOut(token) }
        schedule(expiry: token, after: gap)
        return nil
    }

    private func answered(_ token: Int, _ answer: QuickAX.SelectionProbe) {
        guard var current = gesture, current.token == token, case .waiting = current.probe else { return }
        switch answer {
        case .secure:
            gesture = nil
            replay(current.held, pid: current.pid)
        case .selection(let text):
            current.probe = .selection(text)
            if current.fireOnAnswer {
                gesture = nil
                fire(.selection(pid: current.pid, text: text))
            } else {
                gesture = current
            }
        case .none:
            open(&current)
        }
    }

    private func probeTimedOut(_ token: Int) {
        guard var current = gesture, current.token == token, case .waiting = current.probe else { return }
        Self.trace("probe slow")
        open(&current)
    }

    /// 没有划选：扣下的空格立刻补回去，之后的空格照常进输入框。第三下已经来了就直接触发，那几格都不补。
    private func open(_ current: inout Gesture) {
        current.probe = .open
        if current.fireOnAnswer {
            gesture = nil
            fire(.field(pid: current.pid, typedSpaces: 0))
            return
        }
        replay(current.held, pid: current.pid)
        current.held = 0
        gesture = current
    }

    private func schedule(expiry token: Int, after delay: TimeInterval) {
        onTap(after: delay + 0.01) { [weak self] in self?.expire(token) }
    }

    private func expire(_ token: Int) {
        guard let current = gesture, current.token == token, !current.fireOnAnswer else { return }
        guard ProcessInfo.processInfo.systemUptime - current.last >= gap else { return }
        gesture = nil
        replay(current.held, pid: current.pid)
    }

    /// 扣下的空格按原样补回去，排在当前这下前面。
    private func cancel(proxy: CGEventTapProxy) {
        guard let current = gesture else { return }
        gesture = nil
        guard current.held > 0, front().pid == current.pid else { return }
        for _ in 0..<current.held {
            guard let (down, up) = Self.keyPair(CGKeyCode(kVK_Space)) else { return }
            down.tapPostEvent(proxy)
            up.tapPostEvent(proxy)
        }
    }

    private func replay(_ count: Int, pid: pid_t) {
        guard count > 0, front().pid == pid else { return }
        postKeys(CGKeyCode(kVK_Space), count: count)
    }

    private func fire(_ trigger: QuickTrigger) {
        guard claim() else { return }
        Self.trace("fire \(trigger.trace)")
        Task { @MainActor in
            await QuickTranslate.run(trigger)
            QuickSpaceTap.shared.release()
        }
    }

    // MARK: Helpers

    func postKeys(_ key: CGKeyCode, count: Int) {
        for _ in 0..<count {
            guard let (down, up) = Self.keyPair(key) else { return }
            down.post(tap: .cghidEventTap)
            up.post(tap: .cghidEventTap)
        }
    }

    private static func keyPair(_ key: CGKeyCode) -> (CGEvent, CGEvent)? {
        let source = CGEventSource(stateID: .hidSystemState)
        guard let down = CGEvent(keyboardEventSource: source, virtualKey: key, keyDown: true),
              let up = CGEvent(keyboardEventSource: source, virtualKey: key, keyDown: false) else { return nil }
        down.flags = []
        up.flags = []
        down.setIntegerValueField(.eventSourceUserData, value: stamp)
        up.setIntegerValueField(.eventSourceUserData, value: stamp)
        return (down, up)
    }

    private func onTap(_ body: @escaping () -> Void) {
        lock.lock()
        let rl = runLoop
        lock.unlock()
        guard let rl else { return }
        CFRunLoopPerformBlock(rl, CFRunLoopMode.commonModes.rawValue, body)
        CFRunLoopWakeUp(rl)
    }

    private func onTap(after delay: TimeInterval, _ body: @escaping () -> Void) {
        lock.lock()
        let rl = runLoop
        lock.unlock()
        guard let rl else { return }
        let timer = CFRunLoopTimerCreateWithHandler(
            kCFAllocatorDefault, CFAbsoluteTimeGetCurrent() + delay, 0, 0, 0
        ) { _ in body() }
        CFRunLoopAddTimer(rl, timer, .commonModes)
    }

    // MARK: Trace

    private static let traceQueue = DispatchQueue(label: "Korgino.quick.trace", qos: .utility)
    private static let traceURL = URL(fileURLWithPath: "/tmp/korgi-quick.log")
    private static let traceLimit = 256 * 1024

    /// 只记判断和应用，不记输入框里的字。
    static func trace(_ message: String) {
        let stamp = Date()
        traceQueue.async {
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withTime, .withColonSeparatorInTime, .withFractionalSeconds]
            guard let data = "\(formatter.string(from: stamp)) \(message)\n".data(using: .utf8) else { return }
            let fm = FileManager.default
            if let size = (try? fm.attributesOfItem(atPath: traceURL.path)[.size] as? Int), size > traceLimit {
                try? fm.removeItem(at: traceURL)
            }
            if let handle = try? FileHandle(forWritingTo: traceURL) {
                defer { try? handle.close() }
                _ = try? handle.seekToEnd()
                try? handle.write(contentsOf: data)
            } else {
                try? data.write(to: traceURL)
            }
        }
    }
}

private extension QuickTrigger {
    var trace: String {
        switch self {
        case .selection(let pid, let text): return "selection pid=\(pid) len=\(text.count)"
        case .field(let pid, let typed): return "field pid=\(pid) typed=\(typed)"
        }
    }
}
