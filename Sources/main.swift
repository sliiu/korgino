import AppKit
import SwiftUI
import Combine
import Carbon.HIToolbox
import ApplicationServices
import CoreGraphics

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    static weak var shared: AppDelegate?

    var statusItem: NSStatusItem!
    let hotKeys = HotKeys()
    let popup = PopupController()
    var selectItem: NSMenuItem!
    var quickItem: NSMenuItem!
    var quickUndoItem: NSMenuItem!
    var clipboardItem: NSMenuItem!
    var ocrItem: NSMenuItem!
    var fileItem: NSMenuItem!
    var translateGroupItem: NSMenuItem!
    var captionsGroupItem: NSMenuItem!
    var liveCaptionsWindowItem: NSMenuItem!
    var mediaCaptionsItem: NSMenuItem!
    var meetingRecordsItem: NSMenuItem!
    var dictionaryItem: NSMenuItem!
    var historyItem: NSMenuItem!
    var voiceModeItem: NSMenuItem!
    var voiceRecognizeItem: NSMenuItem!
    var voiceTranslateItem: NSMenuItem!
    var voiceInterpretItem: NSMenuItem!
    var axItem: NSMenuItem!
    var screenItem: NSMenuItem!
    var listenItem: NSMenuItem!
    var prefsItem: NSMenuItem!
    var quitItem: NSMenuItem!
    /// Work that fills the translation panel. Starting one replaces the last: they
    /// all write into the same popup, so the older answer must not land in it.
    var panelTask: Task<Void, Never>?
    /// Region capture owns the screen until the user picks a rect. A new
    /// translation must not cancel a drag that is already in progress.
    var ocrTask: Task<Void, Never>?
    /// Undo writes back into another app and never touches the panel, so it
    /// keeps its own slot.
    var undoTask: Task<Void, Never>?
    private var translateGeneration = 0
    private var hotkeyObserver: NSObjectProtocol?
    private var languageObserver: NSObjectProtocol?
    private var liveStateSink: AnyCancellable?
    private var didPromptListen = false
    private var voiceFeatureWasOn = true

    /// Custom monochrome template from Resources (falls back to SF Symbol).
    static func menuBarIcon() -> NSImage? {
        if let url = Bundle.main.url(forResource: "MenuBarTemplate", withExtension: "png"),
           let img = NSImage(contentsOf: url) {
            img.isTemplate = true
            img.size = NSSize(width: 18, height: 18)
            return img
        }
        let sf = NSImage(systemSymbolName: "character.bubble", accessibilityDescription: L("划词翻译"))
        sf?.isTemplate = true
        return sf
    }

    func applicationWillTerminate(_ n: Notification) {
        SystemAudioTranslateController.shared.prepareForQuit()
    }

    func applicationDidFinishLaunching(_ n: Notification) {
        AppDelegate.shared = self
        MacKeychain.install()
        AppleLanguageDetect.install()
        AppleASRLocales.install()
        _ = AppConfig.shared
        AppConfig.shared.appearance.apply()
        UIChrome.apply()
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let b = statusItem.button {
            MenuBarPulse.shared.attach(b, image: Self.menuBarIcon())
            b.imagePosition = .imageOnly
            b.toolTip = "Korgino"
        }
        let menu = NSMenu()
        menu.autoenablesItems = false
        menu.delegate = self

        // One row per feature: menu click + displayed shortcut share the same @objc action.
        // Global hotkeys (Carbon) below call the identical methods.
        selectItem = item(L("划词翻译"), #selector(translateSelection))
        menu.addItem(selectItem)
        // 快捷翻译只在连按空格/组合键时走，菜单里不占一行。撤销有记录时才冒出来。
        quickItem = item(L("快捷翻译"), #selector(quickTranslate))
        quickUndoItem = item(L("撤销快捷翻译"), #selector(undoQuickTranslate))
        menu.addItem(quickUndoItem)

        clipboardItem = item(L("翻译剪贴板"), #selector(translateClipboard))
        ocrItem = item(L("OCR 截图翻译"), #selector(ocrTranslate))
        fileItem = item(L("文档翻译"), #selector(fileTranslate))
        translateGroupItem = group(L("翻译"), [clipboardItem, ocrItem, fileItem])
        menu.addItem(translateGroupItem)

        voiceModeItem = NSMenuItem(title: L("语音"), action: nil, keyEquivalent: "")
        let voiceMenu = NSMenu()
        voiceMenu.autoenablesItems = false
        voiceRecognizeItem = item(L("语音识别"), #selector(voiceRecognizeMode))
        voiceMenu.addItem(voiceRecognizeItem)
        voiceTranslateItem = item(L("语音翻译"), #selector(voiceTranslateMode))
        voiceMenu.addItem(voiceTranslateItem)
        voiceInterpretItem = item(L("语音传译"), #selector(voiceInterpretMode))
        voiceMenu.addItem(voiceInterpretItem)
        voiceModeItem.submenu = voiceMenu
        menu.addItem(voiceModeItem)

        // 一次听下来的字幕、笔记和录音都收在字幕这一组里。
        liveCaptionsWindowItem = item(L("实时/会议"), #selector(liveCaptions))
        mediaCaptionsItem = item(L("媒体字幕"), #selector(mediaCaptions))
        meetingRecordsItem = item(L("会议记录"), #selector(showMeetingRecords))
        captionsGroupItem = group(L("字幕"), [liveCaptionsWindowItem, mediaCaptionsItem, meetingRecordsItem])
        menu.addItem(captionsGroupItem)

        dictionaryItem = item(L("词典"), #selector(showDictionary))
        menu.addItem(dictionaryItem)
        menu.addItem(.separator())
        historyItem = item(L("历史和收藏"), #selector(showHistory))
        menu.addItem(historyItem)
        prefsItem = item(L("偏好设置…"), #selector(showPrefs), key: ",", mods: [.command])
        menu.addItem(prefsItem)
        menu.addItem(.separator())
        // Permission rows: only visible when NOT granted (updated in menuWillOpen).
        axItem = item(L("需要辅助功能（划词翻译）"), #selector(openAXSettings))
        menu.addItem(axItem)
        screenItem = item(L("需要屏幕录制（OCR）"), #selector(openScreenSettings))
        menu.addItem(screenItem)
        listenItem = item(L("需要输入监视（快捷翻译）"), #selector(openListenSettings))
        menu.addItem(listenItem)
        menu.addItem(.separator())
        // 检查更新 / 关于 → 偏好设置 › 通用（避免菜单栏重复）
        quitItem = NSMenuItem(title: L("退出 Korgino"), action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        quitItem.keyEquivalentModifierMask = [.command]
        // 退出项不画图标。系统有时会给 terminate 补一个方框叉，这里明确清掉。
        quitItem.image = nil
        menu.addItem(quitItem)
        statusItem.menu = menu

        installMainMenu()
        Pro.shared.start()
        SelectionPluginWatcher.shared.refresh()
        NSApp.servicesProvider = self
        NSUpdateDynamicServices()
        applyHotkeys()
        hotkeyObserver = NotificationCenter.default.addObserver(
            forName: .korgiHotkeysDidChange, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.applyHotkeys() }
        }
        languageObserver = NotificationCenter.default.addObserver(
            forName: .korgiLanguageDidChange, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.refreshLocalizedChrome() }
        }
        // 实时字幕（含会议记录）一在听，菜单栏图标就摆起来。
        liveStateSink = SystemAudioTranslateController.shared.$state
            .removeDuplicates()
            .sink { state in
                MainActor.assumeIsolated {
                    if case .listening = state {
                        MenuBarPulse.shared.setActive(true, for: .liveCaptions)
                    } else {
                        MenuBarPulse.shared.setActive(false, for: .liveCaptions)
                    }
                }
            }

        // 不再弹系统辅助功能框。首次启动用自己的面板列四项权限，跳过或关掉之后不再自动出现。
        LaunchPermissionPanel.presentIfNeeded()
    }

    private func item(
        _ title: String,
        _ sel: Selector,
        key: String = "",
        mods: NSEvent.ModifierFlags = []
    ) -> NSMenuItem {
        let i = NSMenuItem(title: title, action: sel, keyEquivalent: key)
        i.target = self
        if !key.isEmpty { i.keyEquivalentModifierMask = mods }
        return i
    }

    /// 一组功能收进一个子菜单，菜单栏只留一行。父项自己没有动作。
    private func group(_ title: String, _ rows: [NSMenuItem]) -> NSMenuItem {
        let parent = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        let sub = NSMenu()
        sub.autoenablesItems = false
        for r in rows { sub.addItem(r) }
        parent.submenu = sub
        return parent
    }

    /// Apply UserDefaults hotkeys → Carbon register + menu keyEquivalents.
    func applyHotkeys() {
        let cfg = AppConfig.shared
        applyFeature(selectItem, action: .select, spec: cfg.hotkeySelect) { [weak self] in
            MainActor.assumeIsolated { self?.translateSelection() }
        }
        applyFeature(clipboardItem, action: .clipboard, spec: cfg.hotkeyClipboard) { [weak self] in
            MainActor.assumeIsolated { self?.translateClipboard() }
        }
        applyFeature(ocrItem, action: .ocr, spec: cfg.hotkeyOCR) { [weak self] in
            MainActor.assumeIsolated { self?.ocrTranslate() }
        }
        applyFeature(fileItem, action: .file, spec: cfg.hotkeyFile) { [weak self] in
            MainActor.assumeIsolated { self?.fileTranslate() }
        }
        applyFeature(liveCaptionsWindowItem, action: .liveCaptions, spec: cfg.hotkeyLiveCaptions) { [weak self] in
            MainActor.assumeIsolated { self?.liveCaptions() }
        }
        applyFeature(mediaCaptionsItem, action: .mediaCaptions, spec: cfg.hotkeyMediaCaptions) { [weak self] in
            MainActor.assumeIsolated { self?.mediaCaptions() }
        }
        applyFeature(dictionaryItem, action: .dictionary, spec: cfg.hotkeyDictionary) { [weak self] in
            MainActor.assumeIsolated { self?.showDictionary() }
        }
        applyFeature(historyItem, action: .history, spec: cfg.hotkeyHistory) { [weak self] in
            MainActor.assumeIsolated { self?.showHistory() }
        }
        applyFeature(quickItem, action: .quickTranslate, spec: cfg.hotkeyQuick) { [weak self] in
            MainActor.assumeIsolated { self?.quickTranslate() }
        }
        applyFeature(quickUndoItem, action: .quickUndo, spec: cfg.hotkeyQuickUndo) { [weak self] in
            MainActor.assumeIsolated { self?.undoQuickTranslate() }
        }
        applyFeature(voiceRecognizeItem, action: .voiceRecognize, spec: cfg.hotkeyVoiceRecognize) { [weak self] in
            MainActor.assumeIsolated { self?.selectVoiceMode(.recognize) }
        }
        applyFeature(voiceTranslateItem, action: .voiceTranslate, spec: cfg.hotkeyVoiceTranslate) { [weak self] in
            MainActor.assumeIsolated { self?.selectVoiceMode(.translate) }
        }
        applyFeature(voiceInterpretItem, action: .voiceInterpret, spec: cfg.hotkeyVoiceInterpret) { [weak self] in
            MainActor.assumeIsolated { self?.selectVoiceMode(.interpret) }
        }
        markVoiceMode()
        if voiceFeatureWasOn, !cfg.dictateEnabled {
            FnDictate.shared.cancel()
        }
        voiceFeatureWasOn = cfg.dictateEnabled
        let wantTap = (cfg.isFeatureEnabled(.quickTranslate) && cfg.hotkeyQuick.isBareSpace) || cfg.dictateEnabled
        QuickSpaceTap.shared.setDictate(cfg.dictateEnabled)
        if wantTap {
            if let problem = QuickTranslate.enableSpaceGesture() {
                sysErrors[.quickTranslate] = problem
                if !didPromptListen, !CGPreflightListenEventAccess() {
                    didPromptListen = true
                    PermissionGrantController.shared.prompt(.inputMonitoring)
                }
            }
        } else {
            QuickTranslate.disableSpaceGesture()
        }

        cfg.hotkeySystemWarnings = Dictionary(uniqueKeysWithValues: HotkeyAction.allCases.map { a in
            (a.rawValue, sysErrors[a] ?? "")
        })
    }

    private var sysErrors: [HotkeyAction: String] = [:]

    private func applyFeature(
        _ item: NSMenuItem?,
        action: HotkeyAction,
        spec: HotkeySpec,
        handler: @escaping () -> Void
    ) {
        let cfg = AppConfig.shared
        let on = cfg.isFeatureEnabled(action)
        item?.isHidden = !on
        guard on else {
            item?.keyEquivalent = ""
            item?.keyEquivalentModifierMask = []
            item?.view = nil
            item?.setAccessibilityLabel(nil)
            hotKeys.unregister(id: action.carbonID)
            sysErrors[action] = ""
            return
        }
        applyMenuHotkey(item, spec: spec)
        if spec.isBareSpace {
            hotKeys.unregister(id: action.carbonID)
            sysErrors[action] = ""
            return
        }
        if let conflict = cfg.hotkeyInternalConflict(for: action) {
            hotKeys.unregister(id: action.carbonID)
            sysErrors[action] = conflict
            return
        }
        let st = hotKeys.register(
            id: action.carbonID,
            keyCode: spec.keyCode,
            modifiers: spec.carbonModifiers,
            handler: handler
        )
        if st != noErr {
            if st == OSStatus(-9878) {
                sysErrors[action] = String(format: L("已被其他应用占用（%@）"), String(describing: spec.display))
            } else {
                sysErrors[action] = String(format: L("注册失败（错误 %@，%@）"), String(describing: st), String(describing: spec.display))
            }
        } else {
            sysErrors[action] = ""
        }
    }

    private func applyMenuHotkey(_ item: NSMenuItem?, spec: HotkeySpec) {
        guard let item else { return }
        // 系统菜单的按键栏只能放一个键。连按三下空格画成三个空格符号。
        if spec.isBareSpace {
            item.keyEquivalent = ""
            item.keyEquivalentModifierMask = []
            item.setAccessibilityLabel("\(item.title)，\(spec.display)")
            let row = (item.view as? GestureShortcutMenuView) ?? GestureShortcutMenuView()
            row.title = item.title
            row.shortcut = "␣\u{2006}␣\u{2006}␣"
            row.autoresizingMask = [.width]
            if item.view !== row { item.view = row }
            return
        }
        item.view = nil
        item.setAccessibilityLabel(nil)
        let key = spec.menuKeyEquivalent
        if key.isEmpty {
            item.keyEquivalent = ""
            item.keyEquivalentModifierMask = []
        } else {
            item.keyEquivalent = key
            item.keyEquivalentModifierMask = spec.menuModifierMask
        }
    }

    func refreshLocalizedChrome() {
        selectItem.title = L("划词翻译")
        voiceModeItem.title = L("语音")
        voiceRecognizeItem.title = L("语音识别")
        voiceTranslateItem.title = L("语音翻译")
        voiceInterpretItem.title = L("语音传译")
        quickItem.title = L("快捷翻译")
        quickUndoItem.title = L("撤销快捷翻译")
        clipboardItem.title = L("翻译剪贴板")
        ocrItem.title = L("OCR 截图翻译")
        fileItem.title = L("文档翻译")
        translateGroupItem.title = L("翻译")
        liveCaptionsWindowItem.title = L("实时/会议")
        captionsGroupItem.title = L("字幕")
        mediaCaptionsItem.title = L("媒体字幕")
        meetingRecordsItem.title = L("会议记录")
        dictionaryItem.title = L("词典")
        historyItem.title = L("历史和收藏")
        prefsItem.title = L("偏好设置…")
        quitItem.title = L("退出 Korgino")
        quitItem.image = nil
        axItem.title = L("需要辅助功能（划词翻译）")
        screenItem.title = L("需要屏幕录制（OCR）")
        listenItem.title = L("需要输入监视（快捷翻译）")
        installMainMenu()
        PreferencesController.shared.relocalize()
        HistoryController.shared.relocalize()
        DictionaryController.shared.relocalize()
        FileTranslateController.shared.relocalize()
        SystemAudioTranslateController.shared.relocalize()
        MediaCaptionsController.shared.relocalize()
        MeetingRecordsController.shared.relocalize()
        markVoiceMode()
        AppleLangPack.relocalize()
    }

    func menuWillOpen(_ menu: NSMenu) {
        markVoiceMode()

        // 剪贴板里有可翻的字才出现这行；没有就整行不显示，留个灰的没法点反而碍事。
        // 要在 syncFeatureRows 之前定下来，分组才知道这一组还剩不剩东西。
        let clipOn = AppConfig.shared.isFeatureEnabled(.clipboard)
            && Self.clipboardHasTranslatableText()
        clipboardItem.isHidden = !clipOn
        clipboardItem.isEnabled = clipOn

        // 偏好设置里勾了哪几项，菜单栏就只留哪几行。整行列表在这里统一过一遍，
        // 不靠各个 @Published 自己发通知 —— 语音模式那几行由 markVoiceMode 管。
        syncFeatureRows()
        collapseSeparators(in: menu)

        // Only show permission prompts when not granted — hide once authorized.
        let axOK = AXIsProcessTrusted()
        axItem.isHidden = axOK
        axItem.title = L("需要辅助功能（划词翻译）")
        let screenOK = CGPreflightScreenCaptureAccess()
        screenItem.isHidden = screenOK
        screenItem.title = L("需要屏幕录制（OCR）")
        let needsListen = AppConfig.shared.isFeatureEnabled(.quickTranslate)
            && AppConfig.shared.hotkeyQuick.isBareSpace
        listenItem.isHidden = CGPreflightListenEventAccess() || !needsListen
        listenItem.title = L("需要输入监视（快捷翻译）")
        if needsListen, CGPreflightListenEventAccess() {
            _ = QuickTranslate.enableSpaceGesture()
        }
        // 权限行也参与收线，所以放在最后再收一次。
        collapseSeparators(in: menu)
    }

    /// 每个功能一行，勾选状态直接决定 `isHidden`。撤销行另外要求手上真有一条可撤的记录。
    private func syncFeatureRows() {
        let cfg = AppConfig.shared
        for (item, action) in [
            (selectItem, HotkeyAction.select),
            (quickItem, .quickTranslate),
            (clipboardItem, .clipboard),
            (ocrItem, .ocr),
            (fileItem, .file),
            (liveCaptionsWindowItem, .liveCaptions),
            (mediaCaptionsItem, .mediaCaptions),
            (dictionaryItem, .dictionary),
            (historyItem, .history),
        ] {
            item?.isHidden = !cfg.isFeatureEnabled(action)
        }
        if let quickUndoItem {
            let quickOn = cfg.isFeatureEnabled(.quickTranslate) && cfg.isFeatureEnabled(.quickUndo)
            quickUndoItem.isHidden = !quickOn || !QuickTranslate.canUndo
        }
        // 一组里一行都不剩时，连父项一起收起来，免得上层留个空子菜单。
        translateGroupItem?.isHidden = [clipboardItem, ocrItem, fileItem].allSatisfy { $0?.isHidden != false }
        captionsGroupItem?.isHidden = [liveCaptionsWindowItem, mediaCaptionsItem, meetingRecordsItem]
            .allSatisfy { $0?.isHidden != false }
    }

    /// 行被藏掉之后，开头、末尾和连着两条的分隔线一起收起来，菜单里不留空档。
    /// 只改 `isHidden`，不删条目 —— 下次打开时行可能又回来了。
    private func collapseSeparators(in menu: NSMenu) {
        var previousVisible: NSMenuItem?
        for item in menu.items {
            guard item.isSeparatorItem else {
                if !item.isHidden { previousVisible = item }
                continue
            }
            item.isHidden = previousVisible == nil || previousVisible!.isSeparatorItem
            if !item.isHidden { previousVisible = item }
        }
        // 末尾那条也是多余的。
        for item in menu.items.reversed() {
            guard item.isSeparatorItem else { break }
            item.isHidden = true
        }
    }

    /// Plain text on the general pasteboard, after trim — same gate as translateClipboard.
    static func clipboardHasTranslatableText() -> Bool {
        guard let raw = NSPasteboard.general.string(forType: .string) else { return false }
        return !raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    @objc func translateSelection() {
        guard AppConfig.shared.isFeatureEnabled(.select) else { return }
        panelTask?.cancel()
        panelTask = Task { @MainActor in
            let front = SelectionGrabber.sourceApp()
            // 这个来源应用关掉了划词，划词就不动。
            guard AppConfig.shared.isAppOn(.select, bundleID: front?.bundleIdentifier) else {
                NSSound.beep()
                return
            }
            let focused = SelectionGrabber.focusedSelection(in: front)
            var text = focused?.text
            if text == nil { text = await SelectionGrabber.copyViaCmdC() }
            guard let t = text?.trimmingCharacters(in: .whitespacesAndNewlines), !t.isEmpty else {
                if !AXIsProcessTrusted() {
                    popup.show(source: "")
                    popup.showError(L("划词翻译需要辅助功能权限：系统设置 › 隐私与安全性 › 辅助功能 › 允许 Korgino（用于读取并写回其他 App 中选中的文字）"))
                } else { NSSound.beep() }
                return
            }
            let writable = focused.map { SelectionGrabber.canWrite($0.element) } ?? true
            let slot = WriteBackSlot(
                element: focused?.element,
                original: t,
                sourceApp: front,
                writable: writable,
                markers: focused?.markers
            )
            await run(t, kind: "select", writeBack: slot, appName: front?.localizedName, bundleID: front?.bundleIdentifier)
        }
    }

    @objc func quickTranslate() {
        guard AppConfig.shared.isFeatureEnabled(.quickTranslate) else { return }
        QuickTranslate.perform()
    }

    @objc func undoQuickTranslate() {
        guard AppConfig.shared.isFeatureEnabled(.quickUndo) else { return }
        undoTask?.cancel()
        undoTask = Task { @MainActor in await QuickTranslate.undo() }
    }

    @objc func voiceRecognizeMode() { selectVoiceMode(.recognize) }
    @objc func voiceTranslateMode() { selectVoiceMode(.translate) }
    @objc func voiceInterpretMode() { selectVoiceMode(.interpret) }

    /// 快捷键和菜单只切换模式，并亮一下胶囊。按住 Fn 才开始听。
    private func selectVoiceMode(_ mode: VoiceMode) {
        guard AppConfig.shared.dictateEnabled else { return }
        AppConfig.shared.voiceMode = mode
        FnDictate.shared.abandon()
        FnDictate.shared.suppressOverlayHide()
        QuickOverlay.shared.announce(mode.title)
        markVoiceMode()
        DispatchQueue.main.async { FnDictate.shared.expireOverlaySuppress() }
    }

    private func markVoiceMode() {
        let cfg = AppConfig.shared
        let mode = cfg.voiceMode
        let voiceOn = cfg.dictateEnabled
        voiceModeItem?.isHidden = !voiceOn
        if voiceOn {
            voiceRecognizeItem?.isHidden = false
            voiceTranslateItem?.isHidden = false
            voiceInterpretItem?.isHidden = false
            voiceRecognizeItem?.state = mode == .recognize ? .on : .off
            voiceTranslateItem?.state = mode == .translate ? .on : .off
            voiceInterpretItem?.state = mode == .interpret ? .on : .off
        }
        guard let button = statusItem?.button else { return }
        MenuBarPulse.shared.setBase(Self.menuBarIcon())
        if voiceOn, cfg.voiceModeInMenuBar {
            button.imagePosition = .imageLeading
            button.attributedTitle = NSAttributedString(string: "")
            button.title = mode.title
            button.toolTip = mode.title
        } else {
            button.imagePosition = .imageOnly
            button.attributedTitle = NSAttributedString(string: "")
            button.title = ""
            button.toolTip = "Korgino"
        }
    }

    @objc func translateClipboard() {
        guard AppConfig.shared.isFeatureEnabled(.clipboard) else { return }
        guard let t = NSPasteboard.general.string(forType: .string)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !t.isEmpty else { NSSound.beep(); return }
        panelTask?.cancel()
        panelTask = Task { @MainActor in await run(t, kind: "clipboard") }
    }

    @objc func ocrTranslate() {
        guard AppConfig.shared.isFeatureEnabled(.ocr) else { return }
        ocrTask?.cancel()
        ocrTask = Task { @MainActor in
            do {
                await Task.yield()
                let captured = try await OCRCapture.captureRegion()
                popup.model.ocrGroups = []
                popup.showOCRDraft(source: captured.0.text, links: captured.0.links, shot: captured.1)
            } catch {
                let msg = error.localizedDescription
                if msg.contains("取消") || msg.contains("已取消") || msg.localizedCaseInsensitiveContains("cancel") { return }
                popup.show(source: "")
                popup.showError(String(format: L("OCR 失败：%@"), String(describing: msg)))
            }
        }
    }

    @objc func liveCaptions() {
        guard AppConfig.shared.isFeatureEnabled(.liveCaptions) else { return }
        SystemAudioTranslateController.shared.show()
    }

    @objc func showMeetingRecords() {
        MeetingRecordsController.shared.show(select: SystemAudioTranslateController.shared.recordID)
    }

    @objc func mediaCaptions() {
        guard AppConfig.shared.isFeatureEnabled(.mediaCaptions) else { return }
        MediaCaptionsController.shared.show()
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard MediaCaptionsController.shared.needsFlushBeforeQuit else { return .terminateNow }
        Task { @MainActor in
            await MediaCaptionsController.shared.flushForQuit()
            NSApp.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }

    @objc func showDictionary() {
        guard AppConfig.shared.isFeatureEnabled(.dictionary) else { return }
        DictionaryController.shared.show()
    }

    @objc func fileTranslate() {
        guard AppConfig.shared.isFeatureEnabled(.file) else { return }
        FileTranslateController.shared.pickAndTranslate()
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        openFile(urls.first)
    }

    @objc func translateFileService(_ pboard: NSPasteboard, userData: String?, error: AutoreleasingUnsafeMutablePointer<NSString?>) {
        let urls = pboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL]
        openFile(urls?.first)
    }

    private func openFile(_ url: URL?) {
        guard let url else { return }
        NSApp.activate()
        if MediaDrop.looksLikeMedia(url) {
            MediaCaptionsController.shared.add(url)
            return
        }
        guard AppConfig.shared.isFeatureEnabled(.file) else { return }
        FileTranslateController.shared.loadSource(url: url, autoStart: true)
    }

    @objc func showHistory() {
        guard AppConfig.shared.isFeatureEnabled(.history) else { return }
        HistoryController.shared.show()
    }
    @objc func showPrefs() { PreferencesController.shared.show() }

    @objc func showAbout() { PreferencesController.shared.show(tab: .about) }

    @objc func checkForUpdates() {
        Task { @MainActor in
            let outcome = await UpdateChecker.check()
            UpdateChecker.presentResult(outcome)
        }
    }

    /// App menu so ⌘, / ⌘Q / About work when a window is key (menu-bar accessory).
    private func installMainMenu() {
        let main = NSMenu()

        let appItem = NSMenuItem()
        main.addItem(appItem)
        let appMenu = NSMenu(title: "Korgino")
        let about = NSMenuItem(title: L("关于 Korgino"), action: #selector(showAbout), keyEquivalent: "")
        about.target = self
        appMenu.addItem(about)
        appMenu.addItem(NSMenuItem.separator())
        let prefs = NSMenuItem(title: L("偏好设置…"), action: #selector(showPrefs), keyEquivalent: ",")
        prefs.keyEquivalentModifierMask = [.command]
        prefs.target = self
        appMenu.addItem(prefs)
        appMenu.addItem(NSMenuItem.separator())
        let quit = NSMenuItem(title: L("退出 Korgino"), action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        quit.keyEquivalentModifierMask = [.command]
        appMenu.addItem(quit)
        appItem.submenu = appMenu

        // Empty Edit menu so standard text-field shortcuts (⌘C/V/A) keep working in prefs.
        let editItem = NSMenuItem()
        main.addItem(editItem)
        let edit = NSMenu(title: L("编辑"))
        edit.addItem(withTitle: L("撤销"), action: Selector(("undo:")), keyEquivalent: "z")
        edit.addItem(withTitle: L("重做"), action: Selector(("redo:")), keyEquivalent: "Z")
        edit.addItem(NSMenuItem.separator())
        edit.addItem(withTitle: L("剪切"), action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: L("拷贝"), action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: L("粘贴"), action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: L("全选"), action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editItem.submenu = edit

        let windowItem = NSMenuItem()
        main.addItem(windowItem)
        let windowMenu = NSMenu(title: L("窗口"))
        windowMenu.addItem(withTitle: L("关闭窗口"), action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        windowMenu.addItem(withTitle: L("最小化"), action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        windowItem.submenu = windowMenu
        NSApp.windowsMenu = windowMenu

        NSApp.mainMenu = main
    }

    /// Re-run translation from popup after user edits source.
    /// 插件页重跑那个插件；普通页照旧走翻译。
    func retranslateFromPopup(text: String, kind: String, plugin: SelectionPlugin? = nil) {
        panelTask?.cancel()
        panelTask = Task { @MainActor in
            if let plugin {
                await runPlugin(plugin, source: text, writeBack: nil, app: nil, reusePanel: true)
            } else {
                await run(text, kind: kind, reusePanel: true)
            }
        }
    }

    /// 只请求新加的这一家，其余已出或还在出的不动。
    func addSessionTranslate(_ id: String) {
        guard Pro.unlocked else { return }
        let model = popup.model
        guard !model.sessionExtraIDs.contains(id),
              let target = AppConfig.shared.catalogTargets().first(where: { $0.id == id })?
                .applying(model.sessionModelOverrides) else { return }
        model.sessionExtraIDs.append(id)
        // 截图草稿还没翻过，点翻译时一起出。
        guard let language = model.translatedTarget else { return }
        let text = model.translatedText
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        let tabID = model.activeTabID
        let plan = model.plan(for: text, target: language)
        popup.putOutcome(
            ProviderOutcome(id: id, name: target.displayName, text: nil, error: nil, loading: true),
            tabID: tabID
        )
        Task { @MainActor in
            let result = await Background.run {
                await Translator.translateAll(text, targets: [target], plan: plan)
            }
            guard let outcome = result.outcomes.first else { return }
            self.popup.finishAdded(outcome, tabID: tabID, text: text, target: language)
        }
    }

    /// 这次浮层给一家 AI 换模型，只重出这一家。不写回设置。
    func setSessionModel(_ newModel: String?, for profile: AIProfile) {
        guard Pro.unlocked else { return }
        let model = popup.model
        let before = model.sessionModelOverrides[profile.id]
        model.sessionModelOverrides.setModel(newModel, for: profile)
        let now = model.sessionModelOverrides[profile.id]
        guard now != before else { return }
        let id = "ai:\(profile.id)"
        guard model.outcomes.contains(where: { $0.id == id }),
              let language = model.translatedTarget else { return }
        let text = model.translatedText
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        let target = TranslateTarget.ai(profile.withModel(now))
        let tabID = model.activeTabID
        let plan = model.plan(for: text, target: language)
        popup.putOutcome(
            ProviderOutcome(id: id, name: target.displayName, text: nil, error: nil, loading: true),
            tabID: tabID
        )
        Task { @MainActor in
            let result = await Background.run {
                await Translator.translateAll(text, targets: [target], plan: plan)
            }
            // 等的时候又换了一次，这份已经过时。
            guard let outcome = result.outcomes.first,
                  self.popup.model.sessionModelOverrides[profile.id] == now else { return }
            self.popup.finishAdded(outcome, tabID: tabID, text: text, target: language)
        }
    }

    /// 这一次翻译真正要跑的那几家。划词会看来源应用自己指定的那一家。
    private func baseTargets(_ kind: String, bundleID: String?) -> [TranslateTarget] {
        switch kind {
        case "clipboard": return AppConfig.shared.translateTargets(.clipboard)
        case "ocr": return AppConfig.shared.translateTargets(.ocr)
        default: return AppConfig.shared.selectTranslateTargets(bundleID: bundleID)
        }
    }

    private func sessionExtras(_ kind: String, bundleID: String?) -> [TranslateTarget] {
        guard Pro.unlocked else { return [] }
        let have = Set(baseTargets(kind, bundleID: bundleID).map(\.id))
        return popup.model.sessionExtraIDs.compactMap { id in
            guard !have.contains(id) else { return nil }
            return AppConfig.shared.catalogTargets().first { $0.id == id }
        }
    }

    func run(_ text: String, kind: String, reusePanel: Bool = false, writeBack: WriteBackSlot? = nil, appName: String? = nil, bundleID: String? = nil) async {
        translateGeneration += 1
        let generation = translateGeneration
        let origin: (appName: String?, bundleID: String?, filePath: String?)
        if reusePanel {
            origin = popup.originForActiveTab()
        } else {
            origin = (appName, bundleID, nil)
        }
        if reusePanel {
            popup.lastKind = kind
            popup.model.source = text
            popup.model.direction = ""
            popup.model.outcomes = []
            popup.model.loading = true
            popup.model.globalError = nil
            popup.model.copiedID = nil
            popup.model.writeBackNote = nil
            popup.model.writeBackNoteID = nil
            popup.model.chatExpanded = false
            popup.model.pendingFirstTranslate = false
            if kind == "ocr" {
                popup.model.sourceCaption = L("识别文字（可编辑）")
            } else {
                popup.model.sourceCaption = L("原文（可编辑）")
            }
            popup.chat.reset(source: text, translations: [])
        } else {
            popup.model.sessionExtraIDs = []
            popup.model.sessionModelOverrides = [:]
            popup.show(
                source: text,
                kind: kind,
                writeBack: kind == "select" ? writeBack : nil,
                appName: origin.appName,
                bundleID: origin.bundleID,
                filePath: origin.filePath
            )
        }
        let overrides = popup.model.sessionModelOverrides
        let targets = (baseTargets(kind, bundleID: origin.bundleID) + sessionExtras(kind, bundleID: origin.bundleID))
            .map { $0.applying(overrides) }
        let plan = popup.model.plan(for: text)
        let tabID = popup.model.activeTabID
        popup.model.translatedText = text
        popup.model.translatedTarget = popup.model.targetLanguage
        popup.updateOutcomes(
            targets.map { ProviderOutcome(id: $0.id, name: $0.displayName, text: nil, error: nil, loading: true) },
            direction: plan.directionLabel,
            tabID: tabID,
            refresh: false
        )
        let result = await Background.run {
            await Translator.translateAll(text, targets: targets, plan: plan) { outcomes, direction in
                await MainActor.run {
                    guard let app = AppDelegate.shared, app.translateGeneration == generation else { return }
                    app.popup.updateOutcomes(outcomes, direction: direction, tabID: tabID, refresh: false)
                }
            }
        }
        guard translateGeneration == generation, !Task.isCancelled else { return }
        popup.showMulti(result, tabID: tabID)
        let histResults = result.outcomes.map {
            HistoryProviderResult(id: $0.id, name: $0.name, text: $0.text, error: $0.error)
        }
        let dir = result.direction
        let histApp = origin.appName
        let histBundle = origin.bundleID
        let histPath = origin.filePath
        Task.detached(priority: .utility) {
            HistoryStore.append(
                source: text, direction: dir, kind: kind, results: histResults,
                filePath: histPath, appName: histApp, bundleID: histBundle
            )
        }
    }

    /// 划词插件里非翻译的那几种：把提示词和原文交给一家 AI，结果照翻译浮层的样子摆出来。
    /// 写回落点照旧带着，所以「润色」之后可以直接盖回选区。
    /// AI 和脚本插件共用的开头：顶掉上一次运行、摆好浮层、记下这一页是哪个插件。
    func beginPluginRun(
        _ plugin: SelectionPlugin,
        source: String,
        writeBack: WriteBackSlot?,
        app: NSRunningApplication?,
        reusePanel: Bool
    ) {
        translateGeneration += 1
        let origin: (appName: String?, bundleID: String?) = reusePanel
            ? { let o = popup.originForActiveTab(); return (o.appName, o.bundleID) }()
            : (app?.localizedName, app?.bundleIdentifier)
        if reusePanel {
            // 重新翻译：原地重来，不另开一页，写回的落点留着。
            popup.lastKind = "plugin"
            popup.model.source = source
            popup.model.direction = plugin.title
            popup.model.outcomes = []
            popup.model.loading = true
            popup.model.globalError = nil
            popup.model.copiedID = nil
            popup.model.writeBackNote = nil
            popup.model.writeBackNoteID = nil
            popup.model.chatExpanded = false
            popup.model.pendingFirstTranslate = false
            popup.model.sourceCaption = L("原文（可编辑）")
            popup.model.sessionPlugin = plugin
            popup.chat.reset(source: source, translations: [])
        } else {
            popup.model.sessionExtraIDs = []
            popup.model.sessionModelOverrides = [:]
            popup.show(
                source: source,
                kind: "plugin",
                writeBack: writeBack,
                appName: origin.appName,
                bundleID: origin.bundleID
            )
            popup.model.sessionPlugin = plugin
        }
    }

    func runPlugin(
        _ plugin: SelectionPlugin,
        source: String,
        writeBack: WriteBackSlot?,
        app: NSRunningApplication?,
        reusePanel: Bool = false
    ) async {
        if plugin.isScript {
            await SelectionPluginRunner.runScript(
                plugin, source: source, writeBack: writeBack, app: app, reusePanel: reusePanel
            )
            return
        }
        beginPluginRun(plugin, source: source, writeBack: writeBack, app: app, reusePanel: reusePanel)
        let generation = translateGeneration
        let tabID = popup.model.activeTabID
        let name = plugin.title
        guard let profile = SelectionPluginStore.shared.aiProfile else {
            popup.updateOutcomes(
                [ProviderOutcome(id: "plugin:\(plugin.id)", name: name, text: nil,
                                 error: L("没有可用的 AI，先在设置里加一家"), loading: false)],
                direction: name,
                tabID: tabID,
                refresh: false
            )
            return
        }
        popup.updateOutcomes(
            [ProviderOutcome(id: "plugin:\(plugin.id)", name: name, text: nil, error: nil, loading: true)],
            direction: name,
            tabID: tabID,
            refresh: false
        )
        let reply: Result<String, Error>
        do {
            let text = try await Background.run {
                try await ChatAPI.complete(instruction: plugin.prompt, source: source, profile: profile)
            }
            reply = .success(text)
        } catch {
            reply = .failure(error)
        }
        // 被取消、被换掉：这一页不能留在转圈里。浮层已经关掉了就什么都不用做。
        guard !Task.isCancelled, translateGeneration == generation else {
            popup.settlePluginLoading(tabID: tabID)
            return
        }
        if case .failure(let error) = reply, error is MaskDeclined {
            // 用户在「将要发送的内容」里点了取消，安静收场，不摆一张红色的报错卡。
            popup.settlePluginLoading(tabID: tabID)
            return
        }
        let outcome: ProviderOutcome
        switch reply {
        case .success(let text):
            outcome = ProviderOutcome(
                id: "plugin:\(plugin.id)", name: name,
                text: text.isEmpty ? nil : text,
                error: text.isEmpty ? L("回复是空的") : nil,
                loading: false
            )
        case .failure(let error):
            outcome = ProviderOutcome(
                id: "plugin:\(plugin.id)", name: name,
                text: nil, error: error.localizedDescription, loading: false
            )
        }
        popup.showMulti(
            MultiResult(direction: name, outcomes: [outcome]),
            tabID: tabID
        )
        guard let text = outcome.text else { return }
        let histApp = app?.localizedName
        let histBundle = app?.bundleIdentifier
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

    @objc func openAXSettings() {
        PermissionGrantController.shared.prompt(.accessibility)
    }

    @objc func openScreenSettings() {
        PermissionGrantController.shared.prompt(.screenCapture)
    }

    @objc func openListenSettings() {
        PermissionGrantController.shared.prompt(.inputMonitoring)
    }
}

/// 菜单栏里画出系统按键栏放不下的快捷键。连按三下空格画成三个空格符号。
///
/// 菜单项一旦设了 `view`，AppKit 就不再画系统标题，也不会把点击转成 action ——
/// 标题、高亮和鼠标左键都得在这里自己处理，少一样这行就是「看得见点不动」或者彻底空白。
private final class GestureShortcutMenuView: NSView {
    var title = "" { didSet { guard title != oldValue else { return }; refit() } }
    var shortcut = "" { didSet { guard shortcut != oldValue else { return }; refit() } }

    private static let leftInset: CGFloat = 18
    private static let rightInset: CGFloat = 18
    private static let columnGap: CGFloat = 28
    private static let rowHeight: CGFloat = 22

    private var hovering = false
    private var pressed = false
    private var tracking: NSTrackingArea?

    /// 连按三下空格的记号。系统菜单字体里没有 U+2423，直接画三个小方框，和按键栏的观感一致。
    private static let spaceMark = "\u{2423}\u{2006}\u{2423}\u{2006}\u{2423}"
    private var showsSpaceMark: Bool { shortcut == Self.spaceMark }

    override init(frame frameRect: NSRect) {
        // 这个视图当菜单行的底，起手就得有高度；零高度时菜单会把整行摆成空白。
        super.init(frame: NSRect(x: 0, y: 0, width: 120, height: Self.rowHeight))
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override var isFlipped: Bool { true }
    override var isOpaque: Bool { false }

    private func refit() {
        // 菜单按 intrinsicContentSize 排高度；这一行自己定死 22，别跟着字宽变高。
        let size = Self.measured(title: title, shortcut: shortcut)
        if abs(frame.width - size.width) > 0.5 || abs(frame.height - size.height) > 0.5 {
            setFrameSize(NSSize(width: max(frame.width, size.width), height: size.height))
        }
        invalidateIntrinsicContentSize()
        needsDisplay = true
    }

    override var intrinsicContentSize: NSSize {
        Self.measured(title: title, shortcut: shortcut)
    }

    private static func measured(title: String, shortcut: String) -> NSSize {
        let font = NSFont.menuFont(ofSize: 0)
        let attrs: [NSAttributedString.Key: Any] = [.font: font]
        let titleW = ceil((title as NSString).size(withAttributes: attrs).width)
        let shortcutW = shortcut == spaceMark
            ? spaceMarkWidth
            : ceil((shortcut as NSString).size(withAttributes: attrs).width)
        return NSSize(
            width: leftInset + titleW + columnGap + shortcutW + rightInset,
            height: rowHeight
        )
    }

    /// 三个空格方框占的宽度。手画的，不经过字体，所以单独算。
    private static let spaceBoxSide: CGFloat = 9
    private static let spaceBoxGap: CGFloat = 4
    private static var spaceMarkWidth: CGFloat {
        spaceBoxSide * 3 + spaceBoxGap * 2
    }

    // MARK: - 鼠标

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
            owner: self
        )
        addTrackingArea(area)
        tracking = area
    }

    override func mouseEntered(with event: NSEvent) {
        hovering = true
        needsDisplay = true
    }

    override func mouseExited(with event: NSEvent) {
        hovering = false
        pressed = false
        needsDisplay = true
    }

    override func mouseDown(with event: NSEvent) {
        pressed = true
        needsDisplay = true
    }

    /// 在自绘行上松手就是「点了这项」。先收起菜单，再照菜单项原本的 action 走一遍。
    override func mouseUp(with event: NSEvent) {
        let wasPressed = pressed
        pressed = false
        needsDisplay = true
        guard wasPressed, bounds.contains(convert(event.locationInWindow, from: nil)),
              let item = enclosingMenuItem, let action = item.action else { return }
        item.menu?.cancelTracking()
        NSApp.sendAction(action, to: item.target, from: item)
    }

    override func draw(_ dirtyRect: NSRect) {
        let highlighted = pressed || hovering || enclosingMenuItem?.isHighlighted == true
        if highlighted {
            let bubble = bounds.insetBy(dx: 5, dy: 1)
            NSColor.selectedContentBackgroundColor.setFill()
            NSBezierPath(roundedRect: bubble, xRadius: 5, yRadius: 5).fill()
        }
        let font = NSFont.menuFont(ofSize: 0)
        let color: NSColor = highlighted ? .selectedMenuItemTextColor : .labelColor
        let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: color]
        let titleSize = (title as NSString).size(withAttributes: attrs)
        let titleY = (bounds.height - titleSize.height) / 2
        (title as NSString).draw(
            at: NSPoint(x: Self.leftInset, y: titleY),
            withAttributes: attrs
        )
        if showsSpaceMark {
            drawSpaceMark(color: color)
        } else {
            let shortcutSize = (shortcut as NSString).size(withAttributes: attrs)
            let shortcutY = (bounds.height - shortcutSize.height) / 2
            (shortcut as NSString).draw(
                at: NSPoint(x: bounds.width - shortcutSize.width - Self.rightInset, y: shortcutY),
                withAttributes: attrs
            )
        }
    }

    /// 三个空心小方框，间距和字号都对着菜单字调过。
    private func drawSpaceMark(color: NSColor) {
        let side = Self.spaceBoxSide
        let gap = Self.spaceBoxGap
        let total = Self.spaceMarkWidth
        let x0 = bounds.width - total - Self.rightInset
        let y = (bounds.height - side) / 2
        color.setStroke()
        for i in 0..<3 {
            let box = NSRect(x: x0 + CGFloat(i) * (side + gap), y: y, width: side, height: side)
            let path = NSBezierPath(roundedRect: box.insetBy(dx: 1, dy: 1), xRadius: 1.5, yRadius: 1.5)
            path.lineWidth = 1
            path.stroke()
        }
    }
}

// MARK: - CLI / Entry
let args = CommandLine.arguments
if let i = args.firstIndex(of: "--test") {
    let onlyGoogle = args.contains("--google")
    let text: String = {
        for a in args[(i + 1)...] where !a.hasPrefix("-") { return a }
        return "hello world"
    }()
    Task.detached {
        do {
            if onlyGoogle {
                let (out, detected) = try await Translator.googleFree(text, tl: Lang.plan(text, mutual: true).tgtGoogle)
                print("engine: Google (免费)\ndirection: \(detected ?? "auto") → …\nresult: \(out)")
            } else {
                let r = await Translator.translateAll(text, targets: [.builtin(.googleFree)])
                if let o = r.outcomes.first, let t = o.text {
                    print("engine: \(o.name)\ndirection: \(r.direction)\nresult: \(t)")
                } else {
                    print("error: \(r.outcomes.first?.error ?? "unknown")")
                    fflush(stdout); _exit(1)
                }
            }
            fflush(stdout); _exit(0)
        } catch {
            print("error: \(error.localizedDescription)")
            fflush(stdout); _exit(1)
        }
    }
    RunLoop.main.run()
}

if let i = args.firstIndex(of: "--test-ocr") {
    let path = i + 1 < args.count ? args[i + 1] : ""
    Task.detached {
        do {
            if path.isEmpty {
                let size = NSSize(width: 320, height: 64)
                let rep = NSBitmapImageRep(
                    bitmapDataPlanes: nil, pixelsWide: Int(size.width), pixelsHigh: Int(size.height),
                    bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                    colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
                NSGraphicsContext.saveGraphicsState()
                NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
                NSColor.white.setFill()
                NSRect(origin: .zero, size: size).fill()
                let str = NSAttributedString(string: "Hello OCR", attributes: [
                    .font: NSFont.systemFont(ofSize: 28),
                    .foregroundColor: NSColor.black,
                ])
                str.draw(at: NSPoint(x: 20, y: 18))
                NSGraphicsContext.restoreGraphicsState()
                let cg = rep.cgImage!
                let text = try await OCRCapture.recognize(cg)
                print("ocr: \(text)")
            } else {
                let text = try await OCRCapture.recognizeFile(path: path)
                print("ocr: \(text)")
            }
            fflush(stdout); _exit(0)
        } catch {
            print("error: \(error.localizedDescription)")
            fflush(stdout); _exit(1)
        }
    }
    RunLoop.main.run()
}

/// Info.plist 里的布尔。macOS 15 的包用 `LSUIElement` 声明自己是菜单栏应用。
private func infoPlistFlag(_ key: String) -> Bool {
    switch Bundle.main.object(forInfoDictionaryKey: key) {
    case let value as Bool:
        return value
    case let value as NSNumber:
        return value.boolValue
    case let value as String:
        return value == "1" || value.lowercased() == "true"
    default:
        return false
    }
}

MainActor.assumeIsolated {
    // WebKit (incl. Quick Look previews) only draws overlay scrollers when this resolves to overlay.
    UserDefaults.standard.set("WhenScrolling", forKey: "AppleShowScrollBars")
    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    // macOS 15 只认 Info.plist 的 LSUIElement。启动前切 accessory 会留下 Dock，菜单栏图标也不出现。
    // macOS 26 不能写这个键，否则 Finder / open 报 -600。那份包只在 26 及以上切。
    // 已经是 LSUIElement 的包不要再切：两套叠在一起，Control Center 会把状态栏图标拉黑。
    // 见 docs/adr/0069-menubar-on-macos-15.md。
    let macOS26 = ProcessInfo.processInfo.operatingSystemVersion.majorVersion >= 26
    if !infoPlistFlag("LSUIElement"), macOS26 {
        app.setActivationPolicy(.accessory)
    }
    app.run()
}
