import AppKit
import AVFoundation
import Speech
import SwiftUI

/// 权限、录音与窗口：和状态机关系最松的三段，单独放一个文件。
extension SystemAudioTranslateController {

    // MARK: Permissions

    func ensurePermissions() async throws {
        if SourceKind.allCases.contains(where: { captures($0) && laneUsesSystemSpeech($0) }) {
            let speechStatus = await withCheckedContinuation { (cont: CheckedContinuation<SFSpeechRecognizerAuthorizationStatus, Never>) in
                SFSpeechRecognizer.requestAuthorization { status in
                    cont.resume(returning: status)
                }
            }
            switch speechStatus {
            case .authorized: break
            case .denied, .restricted:
                throw TErr(L("语音识别权限未授予：系统设置 › 隐私与安全性 › 语音识别 › 允许 Korgino"))
            case .notDetermined:
                throw TErr(L("语音识别权限未确定"))
            @unknown default:
                throw TErr(L("语音识别权限状态未知"))
            }
        }

        if captureSystem {
            if !CGPreflightScreenCaptureAccess() {
                PermissionGrantController.shared.prompt(.screenCapture)
                throw TErr(L("需要屏幕录制权限以捕获系统/应用音频（系统设置 › 隐私与安全性 › 屏幕录制）"))
            }
        }
        if captureMicrophone {
            let perm = AVCaptureDevice.authorizationStatus(for: .audio)
            if perm == .notDetermined {
                // The system sheet runs a nested event loop. Mouse moves that arrive as it
                // closes must not reach the live-caption SwiftUI view: SwiftUI's hover
                // path calls assumeIsolated while the executor pointer is still bad.
                let granted = await LiveCaptionHost.whileMicrophonePrompt {
                    await AVCaptureDevice.requestAccess(for: .audio)
                }
                if !granted { throw TErr(L("需要麦克风权限")) }
            } else if perm != .authorized {
                throw TErr(L("麦克风权限未授予：系统设置 › 隐私与安全性 › 麦克风 › 允许 Korgino"))
            }
        }
    }



    // MARK: Recording

    func attachRecorder(_ kind: SourceKind, to fan: LaneFan) throws {
        attachVoiceTagger(kind, to: fan)
        guard recordAudio else { return }
        let recorder = recordFolder.map { LiveAudioRecorder(url: $0.appendingPathComponent(Self.recordAudioName(kind))) }
            ?? LiveAudioRecorder(name: kind.rawValue)
        try recorder.prepare()
        fan.children.append(recorder)
        recorders[kind] = recorder
    }

    /// Runs after the fans stopped, so every file is closed.
    func collectRecordings() {
        for (kind, recorder) in recorders {
            if recorder.hasAudio { recordings[kind] = recorder.url }
            if let error = recorder.error { recordingFailure = error }
        }
        recorders.removeAll()
    }

    func discardRecordings() {
        recorders.removeAll()
        recordings = [:]
        recordingFailure = nil
        LiveAudioRecorder.discardAll()
    }

    func exportRecordings() {
        let files = SourceKind.allCases.compactMap { kind in recordings[kind].map { (kind, $0) } }
        guard !files.isEmpty, !isActive else { return }
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.prompt = L("导出")
        panel.message = L("把录音导出到")
        guard panel.runModal() == .OK, let folder = panel.url else { return }
        let base = exportBase()
        let fm = FileManager.default
        do {
            var urls: [URL] = []
            for (kind, source) in files {
                let dest = folder.appendingPathComponent("\(base).\(CaptionExport.sanitized(kind.title)).m4a")
                if fm.fileExists(atPath: dest.path) { try fm.removeItem(at: dest) }
                try fm.copyItem(at: source, to: dest)
                urls.append(dest)
            }
            NSWorkspace.shared.activateFileViewerSelecting(urls)
        } catch {
            statusLine = String(format: L("保存失败：%@"), String(describing: error.localizedDescription))
        }
    }



    // MARK: Window

    func showWindow() {
        if window == nil {
            let root = AnyView(
                SystemAudioTranslateView(model: self)
                    .environmentObject(AppConfig.shared)
            )
            let h = LiveCaptionHost(rootView: root)
            h.sizingOptions = []
            h.safeAreaRegions = []
            let w = NSPanel(
                contentRect: NSRect(x: 0, y: 0, width: 500, height: 440),
                styleMask: [.titled, .closable, .resizable, .utilityWindow, .nonactivatingPanel],
                backing: .buffered,
                defer: false
            )
            w.title = L("实时字幕")
            w.isFloatingPanel = true
            w.level = .floating
            w.hidesOnDeactivate = false
            w.contentView = h
            w.isReleasedWhenClosed = false
            w.minSize = NSSize(
                width: Self.minPanelWidth(wide: captureSystem && captureMicrophone),
                height: 300
            )
            w.center()
            window = w
            hosting = h
            NotificationCenter.default.addObserver(
                forName: NSWindow.didResizeNotification,
                object: w,
                queue: .main
            ) { [weak w] _ in
                MainActor.assumeIsolated {
                    CaptionBudget.note("live", w?.frame.width ?? 0)
                }
            }
        }
        window?.title = L("实时字幕")
        relayoutWindow()
        CaptionBudget.note("live", window?.frame.width ?? 0)
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func relocalize() {
        window?.title = L("实时字幕")
    }

    /// The narrowest the panel may be squeezed. The toolbar, the columns and the window's own `minSize`
    /// all read it here, so they can never disagree: a window allowed narrower than the toolbar needs
    /// drops to icon-only sources and hides the status words.
    /// Two columns need room for both, one lane each.
    static func minPanelWidth(wide: Bool) -> CGFloat { wide ? 900 : 640 }
    static func idealPanelWidth(wide: Bool) -> CGFloat { wide ? 980 : 700 }
    static func maxPanelWidth(wide: Bool) -> CGFloat { wide ? 1240 : 820 }

    /// Grow/shrink panel when toggles show/hide lane boxes — prevents checkbox-driven overflow clip.
    func relayoutWindow() {
        guard let w = window, let h = hosting else { return }
        h.rootView = AnyView(
            SystemAudioTranslateView(model: self)
                .environmentObject(AppConfig.shared)
        )
        h.layoutSubtreeIfNeeded()
        var size = h.fittingSize
        let wide = captureSystem && captureMicrophone
        size.width = max(size.width, Self.minPanelWidth(wide: wide))
        size.width = min(size.width, Self.maxPanelWidth(wide: wide))
        let room = (w.screen ?? NSScreen.main)?.visibleFrame.height ?? 800
        size.height = min(max(size.height + 16, w.frame.height, 600), min(room - 32, 900))
        w.minSize = NSSize(width: Self.minPanelWidth(wide: wide), height: 320)
        var frame = w.frame
        let oldMaxY = frame.maxY
        frame.size = size
        // Keep top edge stable when height changes.
        frame.origin.y = oldMaxY - size.height
        if let screen = w.screen ?? NSScreen.main {
            let vf = screen.visibleFrame
            if frame.minX < vf.minX { frame.origin.x = vf.minX + 8 }
            if frame.maxX > vf.maxX { frame.origin.x = vf.maxX - frame.width - 8 }
            if frame.minY < vf.minY { frame.origin.y = vf.minY + 8 }
            if frame.maxY > vf.maxY { frame.origin.y = vf.maxY - frame.height - 8 }
        }
        w.setFrame(frame, display: true, animate: false)
    }
}
