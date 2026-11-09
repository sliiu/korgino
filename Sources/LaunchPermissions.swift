import AppKit
import AVFoundation
import ApplicationServices
import CoreGraphics

/// First-launch sheet for the four privacy toggles. AppKit only: the live-caption
/// window is the one that hosts SwiftUI, and a system permission dialog must not
/// land mouse moves on that hosting view.
@MainActor
final class LaunchPermissionPanel: NSWindowController, NSWindowDelegate {
    static let shared = LaunchPermissionPanel()

    /// Set once the window has been skipped or closed. Later launches stay quiet;
    /// the menu-bar "需要…" rows still appear while a permission is missing.
    static let seenKey = "launchPermissions.seen"

    private var rows: [LaunchPermissionRow] = []
    private var poll: Timer?
    private var finished = false

    static func presentIfNeeded() {
        guard UserDefaults.standard.object(forKey: seenKey) == nil else { return }
        shared.show()
    }

    private func show() {
        if window == nil { window = makeWindow() }
        rebuildRows()
        window?.center()
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        startPolling()
    }

    private func makeWindow() -> NSWindow {
        let content = NSView(frame: NSRect(x: 0, y: 0, width: 560, height: 420))
        let window = NSWindow(
            contentRect: content.frame,
            styleMask: [.titled, .closable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.title = L("权限")
        window.titlebarAppearsTransparent = false
        window.isReleasedWhenClosed = false
        window.contentView = content
        window.delegate = self

        let intro = wrappingLabel(L("这几项用来划词、截图、快捷键和听麦克风。可以先跳过，缺的时候菜单栏还会提醒。"), size: 13, color: .secondaryLabelColor)
        intro.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(intro)

        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        stack.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(stack)

        for kind in LaunchPermissionKind.allCases {
            let row = LaunchPermissionRow(kind: kind) { [weak self] in
                self?.grant(kind)
            }
            row.translatesAutoresizingMaskIntoConstraints = false
            stack.addArrangedSubview(row)
            row.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
            rows.append(row)
        }

        let skip = NSButton(title: L("跳过"), target: self, action: #selector(skip))
        skip.bezelStyle = .rounded
        skip.keyEquivalent = "\u{1b}"
        skip.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(skip)

        NSLayoutConstraint.activate([
            intro.topAnchor.constraint(equalTo: content.topAnchor, constant: 20),
            intro.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 20),
            intro.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -20),

            stack.topAnchor.constraint(equalTo: intro.bottomAnchor, constant: 16),
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 20),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -20),

            skip.topAnchor.constraint(equalTo: stack.bottomAnchor, constant: 16),
            skip.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -20),
            skip.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -16),
        ])
        return window
    }

    /// Status can flip while System Settings is in front. Refresh without asking again.
    private func startPolling() {
        poll?.invalidate()
        // Not assumeIsolated: this fires from inside the microphone sheet's nested
        // event loop, the same moment SwiftUI's hover path crashes on a bad executor.
        let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
            DispatchQueue.main.async { self?.refresh() }
        }
        RunLoop.main.add(timer, forMode: .common)
        poll = timer
    }

    private func refresh() {
        for row in rows { row.refresh() }
    }

    private func rebuildRows() {
        refresh()
    }

    private func grant(_ kind: LaunchPermissionKind) {
        switch kind {
        case .accessibility:
            PermissionGrantController.shared.prompt(.accessibility)
        case .screenCapture:
            PermissionGrantController.shared.prompt(.screenCapture)
        case .inputMonitoring:
            PermissionGrantController.shared.prompt(.inputMonitoring)
        case .microphone:
            requestMicrophone()
        }
    }

    /// The system sheet only appears while the status is still undecided. A denial
    /// has no second prompt, so that path opens the Microphone privacy page.
    private func requestMicrophone() {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            refresh()
        case .notDetermined:
            Task { @MainActor in
                _ = await LiveCaptionHost.whileMicrophonePrompt {
                    await AVCaptureDevice.requestAccess(for: .audio)
                }
                self.refresh()
            }
        case .denied, .restricted:
            openMicrophoneSettings()
        @unknown default:
            openMicrophoneSettings()
        }
    }

    private func openMicrophoneSettings() {
        let modern = "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?Privacy_Microphone"
        let legacy = "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone"
        for raw in [modern, legacy] {
            guard let url = URL(string: raw), NSWorkspace.shared.open(url) else { continue }
            return
        }
    }

    @objc private func skip() {
        finish()
    }

    func windowWillClose(_ notification: Notification) {
        finish()
    }

    private func finish() {
        guard !finished else { return }
        finished = true
        poll?.invalidate()
        poll = nil
        UserDefaults.standard.set(true, forKey: Self.seenKey)
        // orderOut does not post willClose, so Skip and the close button both land here once.
        window?.orderOut(nil)
    }
}

private enum LaunchPermissionKind: CaseIterable {
    case accessibility
    case screenCapture
    case inputMonitoring
    case microphone

    var title: String {
        switch self {
        case .accessibility: return L("辅助功能")
        case .screenCapture: return L("屏幕录制")
        case .inputMonitoring: return L("输入监视")
        case .microphone: return L("麦克风")
        }
    }

    var purpose: String {
        switch self {
        case .accessibility: return L("读取其他 App 里选中的文字，做划词翻译")
        case .screenCapture: return L("OCR 截图，以及实时字幕里的系统声音")
        case .inputMonitoring: return L("快捷翻译的连按空格，以及按住 Fn 说话")
        case .microphone: return L("实时字幕和语音输入要听你说话")
        }
    }

    var granted: Bool {
        switch self {
        case .accessibility: return AXIsProcessTrusted()
        case .screenCapture: return CGPreflightScreenCaptureAccess()
        case .inputMonitoring: return CGPreflightListenEventAccess()
        case .microphone: return AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
        }
    }
}

@MainActor
private final class LaunchPermissionRow: NSView {
    private let kind: LaunchPermissionKind
    private let onGrant: () -> Void
    private let titleField = NSTextField(labelWithString: "")
    private let purposeField = NSTextField(wrappingLabelWithString: "")
    private let statusField = NSTextField(labelWithString: "")
    private let dot = NSView()
    private let grantButton: NSButton

    init(kind: LaunchPermissionKind, onGrant: @escaping () -> Void) {
        self.kind = kind
        self.onGrant = onGrant
        grantButton = NSButton(title: L("去授权"), target: nil, action: nil)
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 10
        layer?.backgroundColor = NSColor.controlBackgroundColor.cgColor

        titleField.stringValue = kind.title
        titleField.font = .systemFont(ofSize: 13, weight: .semibold)
        titleField.textColor = .labelColor
        titleField.translatesAutoresizingMaskIntoConstraints = false

        purposeField.stringValue = kind.purpose
        purposeField.font = .systemFont(ofSize: 12)
        purposeField.textColor = .secondaryLabelColor
        purposeField.maximumNumberOfLines = 3
        purposeField.cell?.wraps = true
        purposeField.cell?.isScrollable = false
        purposeField.translatesAutoresizingMaskIntoConstraints = false

        statusField.font = .systemFont(ofSize: 12)
        statusField.textColor = .secondaryLabelColor
        statusField.translatesAutoresizingMaskIntoConstraints = false

        dot.wantsLayer = true
        dot.layer?.cornerRadius = 3.5
        dot.translatesAutoresizingMaskIntoConstraints = false

        grantButton.bezelStyle = .rounded
        grantButton.controlSize = .regular
        grantButton.target = self
        grantButton.action = #selector(grant)
        grantButton.translatesAutoresizingMaskIntoConstraints = false

        addSubview(titleField)
        addSubview(purposeField)
        addSubview(dot)
        addSubview(statusField)
        addSubview(grantButton)

        NSLayoutConstraint.activate([
            heightAnchor.constraint(greaterThanOrEqualToConstant: 64),

            titleField.topAnchor.constraint(equalTo: topAnchor, constant: 10),
            titleField.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            titleField.trailingAnchor.constraint(lessThanOrEqualTo: dot.leadingAnchor, constant: -12),

            purposeField.topAnchor.constraint(equalTo: titleField.bottomAnchor, constant: 2),
            purposeField.leadingAnchor.constraint(equalTo: titleField.leadingAnchor),
            purposeField.trailingAnchor.constraint(lessThanOrEqualTo: grantButton.leadingAnchor, constant: -12),
            purposeField.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -10),

            grantButton.centerYAnchor.constraint(equalTo: centerYAnchor),
            grantButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),

            statusField.centerYAnchor.constraint(equalTo: centerYAnchor),
            statusField.trailingAnchor.constraint(equalTo: grantButton.leadingAnchor, constant: -10),

            dot.widthAnchor.constraint(equalToConstant: 7),
            dot.heightAnchor.constraint(equalToConstant: 7),
            dot.centerYAnchor.constraint(equalTo: centerYAnchor),
            dot.trailingAnchor.constraint(equalTo: statusField.leadingAnchor, constant: -6),
        ])
        refresh()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        layer?.backgroundColor = NSColor.controlBackgroundColor.cgColor
    }

    func refresh() {
        let on = kind.granted
        statusField.stringValue = on ? L("已开") : L("未开")
        dot.layer?.backgroundColor = (on ? NSColor.systemGreen : NSColor.systemOrange).cgColor
        grantButton.isHidden = on
        grantButton.isEnabled = !on
    }

    @objc private func grant() {
        onGrant()
    }
}

private func wrappingLabel(_ text: String, size: CGFloat, color: NSColor) -> NSTextField {
    let field = NSTextField(wrappingLabelWithString: text)
    field.font = .systemFont(ofSize: size)
    field.textColor = color
    field.maximumNumberOfLines = 3
    return field
}
