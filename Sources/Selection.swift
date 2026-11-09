import AppKit
import ApplicationServices
import Carbon.HIToolbox

/// One 划词 grab: the other app's focused element, and the sentence to match later.
struct FocusedSelection {
    let element: AXUIElement
    let text: String
    /// The selection as a text marker range, for editors whose DOM selection survives losing focus.
    /// Nil for native text fields, which keep their selection on their own.
    let markers: AXEditing.SelectionMarkers?
}

/// Remembered target for 写回. `element` is nil when the grab only succeeded through ⌘C.
struct WriteBackSlot {
    let element: AXUIElement?
    let original: String
    let sourceApp: NSRunningApplication?
    /// False when the selection sits in text that cannot be changed, or a write was already refused.
    var writable: Bool = true
    /// Kept from the grab: a webpage editor forgets its selection when the popup takes the keyboard,
    /// and X's composer will not accept a paste without it.
    var markers: AXEditing.SelectionMarkers? = nil
}

/// Reading and writing the editing box itself, not whatever node inside it happens to hold focus.
///
/// Web editors are the reason this exists. In Chrome the focused element of a `contenteditable`
/// (X's composer, Bluesky, Notion) is a node *inside* the editable region, and that node answers
/// `AXSelectedText` writes with success while changing nothing. Typing and pasting both work, so
/// they are the only writes worth attempting there.
enum AXEditing {
    /// Where the selection was, in marker form. Restoring it needs both halves.
    struct SelectionMarkers {
        let selection: CFTypeRef
        let root: CFTypeRef
    }

    static let webRoles: Set<String> = [
        "AXWebArea", "AXDocument", "AXScrollArea", "AXGroup", "AXGenericElement",
    ]

    /// The editable region enclosing `element`, ascending as far as it goes.
    /// A webpage's editable area answers `AXHighestEditableAncestor`; a plain text field is its own root.
    ///
    /// The climb stops before any document-level container. A whole `AXWebArea` can answer as editable
    /// (its selection is settable), and taking it would replace the page body instead of the post.
    static func editingRoot(_ element: AXUIElement) -> AXUIElement {
        AXUIElementSetMessagingTimeout(element, 0.3)
        var current = element
        if let top = elementAttribute(element, "AXHighestEditableAncestor"), !isDocumentLevel(top) {
            current = top
        }
        // Chromium sometimes only marks the immediate parent. Climb until nothing more is editable.
        for _ in 0..<8 {
            guard let parent = elementAttribute(current, kAXParentAttribute as String) else { break }
            guard !isDocumentLevel(parent), isEditable(parent) else { break }
            current = parent
        }
        AXUIElementSetMessagingTimeout(current, 0.3)
        return current
    }

    /// Window chrome and page containers, which must never be a write target.
    static func isDocumentLevel(_ element: AXUIElement) -> Bool {
        switch role(element) {
        case "AXWebArea", "AXDocument", "AXWindow", "AXApplication", "AXSheet", "AXDialog":
            return true
        default:
            return false
        }
    }

    /// True when the editor lives in a webpage rather than an AppKit text view.
    /// Writing `AXSelectedText` there reports success and changes nothing.
    static func isWebEditor(_ element: AXUIElement) -> Bool {
        if hasAttribute(element, "ChromeAXNodeId") { return true }
        if hasAttribute(element, "AXDOMIdentifier") || hasAttribute(element, "AXDOMManaged") { return true }
        if role(element).map(webRoles.contains) == true { return true }
        // A contenteditable is hosted in a web area; a native text field never is.
        var node: AXUIElement? = element
        for _ in 0..<12 {
            guard let current = node else { break }
            if role(current) == "AXWebArea" { return true }
            node = elementAttribute(current, kAXParentAttribute as String)
        }
        return false
    }

    static func isEditable(_ element: AXUIElement) -> Bool {
        if hasAttribute(element, "AXEditableAncestor") { return true }
        if let settable = isSettable(element, kAXSelectedTextAttribute as String), settable { return true }
        switch role(element) {
        case "AXTextArea", "AXTextField", "AXComboBox", "AXSearchField": return true
        default: return false
        }
    }

    static func hasAttribute(_ element: AXUIElement, _ name: String) -> Bool {
        var names: CFArray?
        guard AXUIElementCopyAttributeNames(element, &names) == .success,
              let list = names as? [String] else { return false }
        return list.contains(name)
    }

    static func isSettable(_ element: AXUIElement, _ name: String) -> Bool? {
        var settable: DarwinBoolean = false
        guard AXUIElementIsAttributeSettable(element, name as CFString, &settable) == .success else { return nil }
        return settable.boolValue
    }

    static func string(_ element: AXUIElement, _ name: String) -> String? {
        var raw: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name as CFString, &raw) == .success else { return nil }
        return raw as? String
    }

    static func role(_ element: AXUIElement) -> String? {
        string(element, kAXRoleAttribute)
    }

    static func elementAttribute(_ element: AXUIElement, _ name: String) -> AXUIElement? {
        var raw: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name as CFString, &raw) == .success,
              let raw, CFGetTypeID(raw) == AXUIElementGetTypeID() else { return nil }
        return (raw as! AXUIElement)
    }

    static func parameterized(_ element: AXUIElement, _ name: String, _ argument: CFTypeRef) -> CFTypeRef? {
        var raw: CFTypeRef?
        guard AXUIElementCopyParameterizedAttributeValue(element, name as CFString, argument, &raw) == .success
        else { return nil }
        return raw
    }

    /// Whole field text, read the way web editors expose it. Chromium leaves `AXValue` empty on a
    /// contenteditable, so the body is read through text markers.
    static func fieldText(_ element: AXUIElement) -> String? {
        if let value = string(element, kAXValueAttribute), !value.isEmpty { return value }
        guard let whole = markerRange(element),
              let text = parameterized(element, "AXStringForTextMarkerRange", whole) as? String,
              !text.isEmpty else { return string(element, kAXValueAttribute) }
        return text
    }

    static func selectionMarkers(_ element: AXUIElement) -> SelectionMarkers? {
        guard let selection = attribute(element, "AXSelectedTextMarkerRange"),
              let root = markerRange(element) else { return nil }
        return SelectionMarkers(selection: selection, root: root)
    }

    /// Put the grab-time selection back. A no-op for native fields, which never lose it.
    /// Restoring markers does not move the caret through AppKit, so it cannot relocate the popup.
    @discardableResult
    static func restoreSelection(_ markers: SelectionMarkers, in element: AXUIElement) -> Bool {
        AXUIElementSetAttributeValue(
            element, "AXSelectedTextMarkerRange" as CFString, markers.selection
        ) == .success
    }

    /// The whole range of the editor. Used to read back what a write actually produced.
    static func markerRange(_ element: AXUIElement) -> CFTypeRef? {
        if let own = parameterized(element, "AXTextMarkerRangeForUIElement", element) { return own }
        guard let start = attribute(element, "AXStartTextMarker"),
              let end = attribute(element, "AXEndTextMarker") else { return nil }
        return parameterized(element, "AXTextMarkerRangeForUnorderedTextMarkers", [start, end] as CFArray)
    }

    static func attribute(_ element: AXUIElement, _ name: String) -> CFTypeRef? {
        var raw: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name as CFString, &raw) == .success else { return nil }
        return raw
    }
}

enum WriteBackRefusal {
    case empty
    case missing
    case mismatch
    case rejected

    var message: String {
        switch self {
        case .empty: return L("读出来是空的，没有写回")
        case .missing: return L("找不到当时的选区，没有写回")
        case .mismatch: return L("选区已经不是这次划词的原文，没有写回")
        case .rejected: return L("这里写不进去，没有写回")
        }
    }
}

@MainActor
enum SelectionGrabber {
    static func axSelectedText() -> String? {
        focusedSelection()?.text
    }

    /// The app that owns the selection. An accessory panel often is not frontmost; the menu-bar owner is.
    static func sourceApp() -> NSRunningApplication? {
        let us = getpid()
        if let front = NSWorkspace.shared.frontmostApplication, front.processIdentifier != us {
            return front
        }
        if let owner = NSWorkspace.shared.menuBarOwningApplication, owner.processIdentifier != us {
            return owner
        }
        return nil
    }

    /// Whether the selection can be replaced. A field that takes neither an Accessibility write nor typing is read-only text.
    /// An element that does not answer is treated as writable, so the paste fallback still gets its chance.
    ///
    /// The answer is taken from the editing box, not the node that held focus: in a webpage the focused
    /// node is a child of the `contenteditable`, and asking the child reports no write support.
    static func canWrite(_ element: AXUIElement) -> Bool {
        writableWithoutMainActor(element)
    }

    /// Same question, callable off the main thread — the Accessibility probes behind it do not need the main actor.
    nonisolated static func writableWithoutMainActor(_ element: AXUIElement) -> Bool {
        let editor = AXEditing.editingRoot(element)
        if AXEditing.isSettable(editor, kAXSelectedTextAttribute as String) == true { return true }
        if AXEditing.isEditable(editor) { return true }
        guard let role = AXEditing.role(editor) else { return true }
        let editable: Set<String> = [
            kAXTextFieldRole as String, kAXTextAreaRole as String, kAXComboBoxRole as String, "AXSearchField",
        ]
        return editable.contains(role)
    }

    /// Focused selection in another app. Our own fields are ignored so 写回 cannot target the popup.
    static func focusedSelection(in app: NSRunningApplication? = nil) -> FocusedSelection? {
        if let app, app.processIdentifier != getpid(),
           let found = selection(from: AXUIElementCreateApplication(app.processIdentifier)) {
            return found
        }
        return selection(from: AXUIElementCreateSystemWide())
    }

    /// Give the source app the keyboard, confirm the selection is still the original sentence, then replace it.
    /// Accessibility write is preferred where it works. A verified paste is used everywhere else, and the clipboard is put back.
    static func writeBack(slot: WriteBackSlot, markdown: String) async -> WriteBackRefusal? {
        await preservingClipboard { await writeBackUnguarded(slot: slot, markdown: markdown) }
    }

    private static func writeBackUnguarded(slot: WriteBackSlot, markdown: String) async -> WriteBackRefusal? {
        let plain = MarkdownTextUtil.plain(markdown)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !plain.isEmpty else { return .empty }

        guard let app = slot.sourceApp, !app.isTerminated else { return .missing }
        // The keyboard has to be back in the source app before anything is written or pasted. Writing
        // to the stale element first is what put text into a detached node while the popup owned focus.
        guard await focus(app) else { return .missing }

        // Re-resolve the live editor now that the app is frontmost again. The element captured at grab
        // time survives a re-render on some pages and dies on X, so it is only a hint.
        let live = focusedSelection(in: app)?.element ?? slot.element
        let markers = slot.markers ?? live.flatMap { AXEditing.selectionMarkers(AXEditing.editingRoot($0)) }

        if let live {
            if let markers, AXEditing.isWebEditor(AXEditing.editingRoot(live)) {
                // A web editor drops its DOM selection when it loses focus. Put it back before pasting,
                // otherwise ⌘V lands at wherever the caret reset to — usually the end of the box.
                AXEditing.restoreSelection(markers, in: AXEditing.editingRoot(live))
            }
            switch apply(plain, original: slot.original, element: AXEditing.editingRoot(live), markers: markers) {
            case .ok: return nil
            case .mismatch: return .mismatch
            case .missing, .rejected: break
            }
        }

        guard await confirmSelection(slot: slot, app: app, markers: markers) else { return .mismatch }
        guard await focus(app) else { return .missing }
        if let markers, let element = live ?? slot.element {
            AXEditing.restoreSelection(markers, in: AXEditing.editingRoot(element))
        }
        // The body is snapshotted right before the paste: a page's editor usually holds more than the
        // selected sentence (the rest of the draft), so "the body is not the original" proves nothing.
        let beforePaste = bodySnapshot(slot: slot, app: app)
        await pastePlain(plain)
        guard await confirmReplaced(slot: slot, app: app, before: beforePaste) else { return .rejected }
        return nil
    }

    /// The editable body as it stands, if it can be read.
    private static func bodySnapshot(slot: WriteBackSlot, app: NSRunningApplication) -> String? {
        guard let element = focusedSelection(in: app)?.element ?? slot.element else { return nil }
        return AXEditing.fieldText(AXEditing.editingRoot(element))
    }

    /// ⌘C the current selection and check it is still the original sentence.
    /// A failed copy means the selection is gone, not that it changed — the paste path can still
    /// use the remembered markers, so `missing` from the copy alone must not read as a mismatch.
    private static func confirmSelection(
        slot: WriteBackSlot, app: NSRunningApplication, markers: AXEditing.SelectionMarkers?
    ) async -> Bool {
        if let live = await copyViaCmdC()?.trimmingCharacters(in: .whitespacesAndNewlines), !live.isEmpty {
            return live == slot.original
        }
        // Nothing copied: a webpage selection that lost focus reads as empty. Trust the grab only when
        // the editor still holds the sentence somewhere, and let the paste verification decide.
        guard markers != nil, let element = focusedSelection(in: app)?.element else { return false }
        guard let body = AXEditing.fieldText(AXEditing.editingRoot(element)) else { return false }
        return body.contains(slot.original)
    }

    /// Read the field back and make sure the paste actually changed it.
    /// `before` is the body snapshotted immediately before the paste; without it a draft that already
    /// differs from the original sentence would read as a successful replacement.
    private static func confirmReplaced(
        slot: WriteBackSlot, app: NSRunningApplication, before: String?
    ) async -> Bool {
        for attempt in 0..<5 {
            if attempt > 0 { try? await Task.sleep(nanoseconds: 60_000_000) }
            if let now = bodySnapshot(slot: slot, app: app) {
                let trimmed = now.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmed.isEmpty else { continue }
                if let before { return now != before }
                return trimmed != slot.original
            }
        }
        if let after = await copyViaCmdC()?.trimmingCharacters(in: .whitespacesAndNewlines), !after.isEmpty {
            return after != slot.original
        }
        // Nothing readable at all: the paste was issued and nothing contradicted it.
        return true
    }

    private static func selection(from root: AXUIElement) -> FocusedSelection? {
        AXUIElementSetMessagingTimeout(root, 0.5)
        var focused: CFTypeRef?
        guard AXUIElementCopyAttributeValue(root, kAXFocusedUIElementAttribute as CFString, &focused) == .success,
              let f = focused, CFGetTypeID(f) == AXUIElementGetTypeID() else { return nil }
        let el = unsafeBitCast(f, to: AXUIElement.self)
        let kept = Unmanaged.passRetained(el).takeRetainedValue()
        var pid: pid_t = 0
        if AXUIElementGetPid(kept, &pid) == .success, pid == getpid() { return nil }
        // In a webpage the focused node sits inside the editable region; reading and writing it is
        // what produced text in the wrong place, or no text at all, on X and other contenteditable editors.
        let editor = AXEditing.editingRoot(kept)
        AXUIElementSetMessagingTimeout(editor, 0.5)
        guard let s = selectedText(editor), !s.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            // A web editor can report the selection only through markers, not as a plain string.
            guard AXEditing.isWebEditor(editor),
                  let markers = AXEditing.selectionMarkers(editor),
                  let s = selectedTextByMarkers(editor, markers),
                  !s.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
            return FocusedSelection(element: editor, text: s, markers: markers)
        }
        return FocusedSelection(
            element: editor,
            text: s,
            markers: AXEditing.isWebEditor(editor) ? AXEditing.selectionMarkers(editor) : nil
        )
    }

    private static func selectedText(_ element: AXUIElement) -> String? {
        AXEditing.string(element, kAXSelectedTextAttribute as String)
    }

    /// The selected run through text markers. Chromium exposes `AXSelectedTextMarkerRange` even when
    /// `AXSelectedText` comes back empty on a contenteditable.
    private static func selectedTextByMarkers(
        _ element: AXUIElement, _ markers: AXEditing.SelectionMarkers
    ) -> String? {
        guard let text = AXEditing.parameterized(
            element, "AXStringForTextMarkerRange", markers.selection
        ) as? String else { return nil }
        return text
    }

    private enum ApplyResult { case ok, mismatch, missing, rejected }

    /// Replace the remembered selection with `plain`.
    ///
    /// Native fields take an Accessibility write. Web editors do not: Chromium answers the write with
    /// success and changes nothing, so a write there is reported as `.rejected` and the caller falls
    /// through to a paste. Every `.ok` here means the text was read back and it changed.
    private static func apply(
        _ plain: String, original: String, element: AXUIElement, markers: AXEditing.SelectionMarkers?
    ) -> ApplyResult {
        AXUIElementSetMessagingTimeout(element, 0.5)
        guard let current = selectedText(element) ?? markers.flatMap({ selectedTextByMarkers(element, $0) })
        else { return .missing }
        guard current.trimmingCharacters(in: .whitespacesAndNewlines) == original else { return .mismatch }

        if AXEditing.isWebEditor(element) { return .rejected }
        // The body has to be read *before* the write; reading it after would compare the new text
        // with itself and report a change that never happened.
        let before = AXEditing.fieldText(element) ?? current
        guard AXUIElementSetAttributeValue(
            element, kAXSelectedTextAttribute as CFString, plain as CFString
        ) == .success else { return .rejected }

        // A write only counts when the editor shows it. Chromium can accept the call and change
        // nothing, and the plain-string read-back is exactly what it lies about — so compare the
        // field body, which there is read through markers.
        for attempt in 0..<5 {
            if attempt > 0 { usleep(40_000) }
            guard let after = AXEditing.fieldText(element) else { continue }
            if after != before, after.contains(plain) { return .ok }
        }
        return .rejected
    }

    /// Return the keyboard to `app`. False when it never becomes frontmost, so a later paste cannot land here.
    private static func focus(_ app: NSRunningApplication) async -> Bool {
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

    /// 从 HID 层发带 ⌘ 的按键，系统会一直当 ⌘ 按着，之后的点击和按键都带上 ⌘。用户本来没按 ⌘ 时，发完补一个 ⌘ 松开。
    private static func postCommand(_ key: CGKeyCode, tap: CGEventTapLocation = .cghidEventTap) {
        let held = CGEventSource.flagsState(.hidSystemState)
        let src = CGEventSource(stateID: .combinedSessionState)
        let down = CGEvent(keyboardEventSource: src, virtualKey: key, keyDown: true)
        let up = CGEvent(keyboardEventSource: src, virtualKey: key, keyDown: false)
        down?.flags = .maskCommand
        up?.flags = .maskCommand
        down?.post(tap: tap)
        up?.post(tap: tap)
        guard tap == .cghidEventTap, !held.contains(.maskCommand),
              let release = CGEvent(keyboardEventSource: src, virtualKey: CGKeyCode(kVK_Command), keyDown: false) else { return }
        release.flags = held.intersection([.maskShift, .maskControl, .maskAlternate, .maskSecondaryFn])
        release.post(tap: tap)
    }

    // MARK: Clipboard

    /// The user's clipboard, saved once for a whole write. Nil when no guarded write is running.
    private static var guardedClipboard: [NSPasteboardItem]?

    /// Run a write that copies and pastes through the clipboard, and give the user their clipboard back
    /// exactly once at the end.
    ///
    /// Saving and restoring per step was wrong: a ⌘C that arrives after its own timeout lands on the
    /// clipboard after that step gave up, and the next step then saved *that* — the source sentence —
    /// as the user's clipboard and "restored" it at the end.
    static func preservingClipboard<T>(_ body: () async -> T) async -> T {
        if guardedClipboard != nil { return await body() }
        let pb = NSPasteboard.general
        guardedClipboard = snapshot(pb)
        let result = await body()
        let saved = guardedClipboard ?? []
        guardedClipboard = nil
        restore(pb, saved)
        // A copy the target app was still finishing can land after the restore. Put it back once more.
        let restoredAt = pb.changeCount
        try? await Task.sleep(nanoseconds: 300_000_000)
        if pb.changeCount != restoredAt { restore(pb, saved) }
        return result
    }

    /// Paste through the clipboard, then put the user's clipboard back.
    ///
    /// The wait is deliberate: Chromium and Electron read the pasteboard when their own paste command
    /// runs, usually a good 100–200 ms after the ⌘V event. A short wait let web editors paste the
    /// previous clipboard contents, or nothing at all.
    private static func pastePlain(_ text: String, tap: CGEventTapLocation = .cghidEventTap) async {
        await preservingClipboard {
            let pb = NSPasteboard.general
            pb.clearContents()
            let item = NSPasteboardItem()
            item.setString(text, forType: .string)
            markTransient(item)
            pb.writeObjects([item])
            postCommand(CGKeyCode(kVK_ANSI_V), tap: tap)
            try? await Task.sleep(nanoseconds: 450_000_000)
        }
    }

    /// nspasteboard.org markers: clipboard history apps (Raycast, Paste, Maccy, Alfred) skip these,
    /// so the translation passing through for a paste does not show up as something the user copied.
    private static func markTransient(_ item: NSPasteboardItem) {
        item.setData(Data(), forType: NSPasteboard.PasteboardType("org.nspasteboard.TransientType"))
        item.setData(Data(), forType: NSPasteboard.PasteboardType("org.nspasteboard.AutoGeneratedType"))
    }

    private static func snapshot(_ pb: NSPasteboard) -> [NSPasteboardItem] {
        (pb.pasteboardItems ?? []).map { item in
            let n = NSPasteboardItem()
            for t in item.types { if let d = item.data(forType: t) { n.setData(d, forType: t) } }
            return n
        }
    }

    private static func restore(_ pb: NSPasteboard, _ saved: [NSPasteboardItem]) {
        pb.clearContents()
        if !saved.isEmpty { pb.writeObjects(saved.map(copyItem)) }
    }

    /// A pasteboard item can be written only once; restoring twice needs fresh copies.
    private static func copyItem(_ item: NSPasteboardItem) -> NSPasteboardItem {
        let n = NSPasteboardItem()
        for t in item.types { if let d = item.data(forType: t) { n.setData(d, forType: t) } }
        return n
    }

    static func copyViaCmdC(tap: CGEventTapLocation = .cghidEventTap) async -> String? {
        await preservingClipboard {
            let pb = NSPasteboard.general
            let before = pb.changeCount
            postCommand(CGKeyCode(kVK_ANSI_C), tap: tap)
            for _ in 0..<12 {
                try? await Task.sleep(nanoseconds: 50_000_000)
                if pb.changeCount != before { break }
            }
            guard pb.changeCount != before else { return nil }
            // The writer may still be adding types; give it a moment before reading.
            try? await Task.sleep(nanoseconds: 30_000_000)
            return pb.string(forType: .string)
        }
    }

    static func selectAll(tap: CGEventTapLocation = .cghidEventTap) {
        postCommand(CGKeyCode(kVK_ANSI_A), tap: tap)
    }

    static func pastePlainText(_ text: String, tap: CGEventTapLocation = .cghidEventTap) async {
        await pastePlain(text, tap: tap)
    }

    /// 把整段字按输入法上屏的方式送进当前光标。不经过剪贴板。
    ///
    /// 网页编辑器（X 的编辑器、Draft.js、ProseMirror）处理按键是异步的，一口气灌进去会丢字或乱序。
    /// 每组之间留几毫秒，跟人用输入法上屏的节奏接近。
    static func typePlainText(_ text: String) {
        let units = Array(text.utf16)
        guard !units.isEmpty, let src = CGEventSource(stateID: .combinedSessionState) else { return }
        var index = 0
        while index < units.count {
            var end = min(index + 20, units.count)
            if end < units.count, units[end - 1] >= 0xD800, units[end - 1] <= 0xDBFF { end -= 1 }
            if end <= index { end = min(index + 1, units.count) }
            let slice = Array(units[index..<end])
            guard let down = CGEvent(keyboardEventSource: src, virtualKey: 0, keyDown: true),
                  let up = CGEvent(keyboardEventSource: src, virtualKey: 0, keyDown: false) else { return }
            down.flags = []
            up.flags = []
            slice.withUnsafeBufferPointer { buf in
                if let base = buf.baseAddress {
                    down.keyboardSetUnicodeString(stringLength: slice.count, unicodeString: base)
                }
            }
            down.setIntegerValueField(.eventSourceUserData, value: QuickSpaceTap.stamp)
            up.setIntegerValueField(.eventSourceUserData, value: QuickSpaceTap.stamp)
            down.post(tap: .cghidEventTap)
            up.post(tap: .cghidEventTap)
            index = end
            if index < units.count { usleep(6_000) }
        }
    }
}

/// Multiple Carbon hotkeys dispatched by id. Supports full unregister + re-register.
final class HotKeys {
    static let sharedHandlers = HandlerBox()
    final class HandlerBox {
        var handlers: [UInt32: () -> Void] = [:]
    }
    private var refs: [UInt32: EventHotKeyRef] = [:]
    private var installed = false

    /// Register or replace one hotkey id. Returns OSStatus (noErr = 0).
    @discardableResult
    func register(id: UInt32, keyCode: UInt32, modifiers: UInt32, handler: @escaping () -> Void) -> OSStatus {
        ensureHandler()
        if let old = refs[id] {
            UnregisterEventHotKey(old)
            refs.removeValue(forKey: id)
        }
        HotKeys.sharedHandlers.handlers[id] = handler
        var ref: EventHotKeyRef?
        let hid = EventHotKeyID(signature: OSType(0x4B524749), id: id) // 'KRGI'
        let st = RegisterEventHotKey(keyCode, modifiers, hid, GetApplicationEventTarget(), 0, &ref)
        if st != noErr {
            NSLog("Korgino: RegisterEventHotKey id=\(id) failed: \(st)")
        } else if let ref {
            refs[id] = ref
        }
        return st
    }

    func unregister(id: UInt32) {
        if let old = refs[id] {
            UnregisterEventHotKey(old)
            refs.removeValue(forKey: id)
        }
        HotKeys.sharedHandlers.handlers.removeValue(forKey: id)
    }

    func unregisterAll() {
        for (_, ref) in refs {
            UnregisterEventHotKey(ref)
        }
        refs.removeAll()
        HotKeys.sharedHandlers.handlers.removeAll()
    }

    private func ensureHandler() {
        guard !installed else { return }
        installed = true
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { (_, event, _) -> OSStatus in
            var hk = EventHotKeyID()
            GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                              nil, MemoryLayout<EventHotKeyID>.size, nil, &hk)
            let id = hk.id
            DispatchQueue.main.async { HotKeys.sharedHandlers.handlers[id]?() }
            return noErr
        }, 1, &spec, nil, nil)
    }
}
