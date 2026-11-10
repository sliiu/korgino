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

    /// 实时字幕嵌在主窗口里。原来的浮动面板不再单独打开。
    func showWindow() {
        MainWindowController.shared.show(page: .live)
    }

    func relocalize() {}

    /// The narrowest the panel may be squeezed. The toolbar, the columns and the window's own `minSize`
    /// all read it here, so they can never disagree: a window allowed narrower than the toolbar needs
    /// drops to icon-only sources and hides the status words.
    /// Two columns need room for both, one lane each.
    static func minPanelWidth(wide: Bool) -> CGFloat { wide ? 900 : 640 }
    static func idealPanelWidth(wide: Bool) -> CGFloat { wide ? 980 : 700 }
    static func maxPanelWidth(wide: Bool) -> CGFloat { wide ? 1240 : 820 }

    /// 主窗口自己记住大小，不再按内容把窗口撑开或缩回去。
    func relayoutWindow() {}
}
