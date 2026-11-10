import AppKit
import SwiftUI

/// 快捷翻译进行时，贴在输入框右下的那一颗胶囊。不抢焦点，也不挡鼠标。
/// 语音不再借这一层，它在 `VoiceCapsule`。
@MainActor
final class QuickOverlay {
    static let shared = QuickOverlay()

    private var panel: NSPanel?
    private let model = QuickOverlayModel()
    private var generation = 0

    private let gap: CGFloat = 6
    private let badgeHeight: CGFloat = 24

    /// `重试` 点下来。不接就不画这个字：这一层不知道怎么重跑上一次。
    var retry: (() -> Void)? {
        didSet { model.canRetry = retry != nil }
    }

    /// 失败胶囊上的「重试」重新走一遍快捷翻译。入口在 `QuickTranslate`，这里不重写翻译。
    func enableRetry() {
        retry = { QuickTranslate.perform() }
    }

    /// 菜单和快捷键切模式时还从这里进来。胶囊已经拆走，这里只转过去。
    func announce(_ title: String) {
        VoiceCapsule.shared.announce(title)
    }

    /// `rect` 是辅助功能坐标：主屏左上角为原点。供应商和语言不再写在胶囊上，胶囊只写「翻译中」。
    func begin(rect: CGRect?, provider: String, language: String? = nil) {
        _ = provider
        _ = language
        generation += 1
        if retry == nil { enableRetry() }
        model.phase = .working
        place(rect)
        present()
    }

    func generationToken() -> Int { generation }

    /// 这段时间里如果浮标已经换成别的内容，就不要把它收掉。
    func hideIfStill(_ token: Int) {
        guard generation == token else { return }
        hide()
    }

    func succeed() {
        guard panel?.isVisible == true else { return }
        model.phase = .done
        // 勾和「已替换」比「翻译中」宽，按现在的字再量一次，仍贴在输入框右下。
        place(model.anchor)
        dismiss(after: 2)
    }

    func hide() {
        generation += 1
        panel?.orderOut(nil)
    }

    func fail(_ message: String, rect: CGRect?) {
        generation += 1
        if retry == nil { enableRetry() }
        model.phase = .failed(message)
        place(rect ?? model.anchor)
        present()
        dismiss(after: 2.4)
    }

    /// 贴在输入框右下。没有框就贴在鼠标旁边。胶囊多宽多窄都只围住自己那一圈。
    private func place(_ axRect: CGRect?) {
        let panel = ensurePanel()
        model.anchor = axRect
        let width = badgeWidth()
        let primary = NSScreen.screens.first?.frame ?? .zero
        if let axRect {
            let field = OverlayPlacement.onScreen(axRect, primary: primary)
            var frame = NSRect(
                x: field.maxX - width,
                y: field.minY - badgeHeight - gap,
                width: width,
                height: badgeHeight
            )
            let screen = OverlayPlacement.screen(containing: field)
            if let visible = screen?.visibleFrame {
                OverlayPlacement.keepInsideScreen(&frame, visible: visible)
            }
            panel.setFrame(frame, display: false)
            return
        }
        let mouse = NSEvent.mouseLocation
        var frame = NSRect(x: mouse.x + 12, y: mouse.y - badgeHeight - 10, width: width, height: badgeHeight)
        let screen = NSScreen.screens.first { $0.frame.contains(mouse) } ?? NSScreen.main
        if let visible = screen?.visibleFrame {
            OverlayPlacement.keepInsideScreen(&frame, visible: visible)
        }
        panel.setFrame(frame, display: false)
    }

    /// 按当前这一句量宽度。失败时原因可能很长，宽度封一个上限。
    private func badgeWidth() -> CGFloat {
        let font = Theme.TypeScale.nsLabel
        let text: String
        let extras: CGFloat
        switch model.phase {
        case .working:
            text = L("翻译中")
            extras = 11 + 6
        case .done:
            text = L("已替换") + L("撤销")
            extras = 12 + 6 + 28 + 6
        case .failed(let message):
            text = message + (model.canRetry ? L("重试") : "")
            extras = 14 + (model.canRetry ? 14 : 0)
        }
        let measured = (text as NSString).size(withAttributes: [.font: font]).width
        return min(360, max(72, ceil(measured + extras + 20)))
    }

    private func present() {
        let panel = ensurePanel()
        OverlayPlacement.fadeIn(panel)
        panel.orderFrontRegardless()
    }

    private func dismiss(after delay: TimeInterval) {
        let mine = generation
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.generation == mine, let panel = self.panel else { return }
                NSAnimationContext.runAnimationGroup({ ctx in
                    ctx.duration = 0.09
                    panel.animator().alphaValue = 0
                }, completionHandler: {
                    MainActor.assumeIsolated {
                        guard self.generation == mine else { return }
                        panel.orderOut(nil)
                    }
                })
            }
        }
    }

    private func ensurePanel() -> NSPanel {
        if let panel { return panel }
        let made = OverlayPanel.make(
            contentRect: NSRect(x: 0, y: 0, width: 120, height: badgeHeight),
            style: .floating,
            content: NSHostingView(rootView: QuickBadgeView(model: model) { [weak self] in
                self?.retry?()
            }),
            deferCreation: true
        )
        made.level = .statusBar
        made.ignoresMouseEvents = false
        made.alphaValue = 0
        panel = made
        return made
    }
}

@MainActor
final class QuickOverlayModel: ObservableObject {
    enum Phase: Equatable {
        case working
        case done
        case failed(String)
    }

    @Published var phase: Phase = .working
    /// 有人接了 `retry` 才在失败胶囊上写「重试」。
    @Published var canRetry = false
    /// 辅助功能坐标里的输入框。换状态时还贴在这里。
    var anchor: CGRect?
}

private struct QuickBadgeView: View {
    @ObservedObject var model: QuickOverlayModel
    var retry: () -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var working: Bool {
        if case .working = model.phase { return true }
        return false
    }

    var body: some View {
        HStack(spacing: 6) {
            switch model.phase {
            case .working:
                ProgressView()
                    .controlSize(.mini)
                Text(L("翻译中"))
                    .lineLimit(1)
            case .done:
                Image(systemName: "checkmark")
                    .foregroundStyle(Theme.ok)
                Text(L("已替换"))
                    .lineLimit(1)
                Text("⌘Z")
                    .font(Theme.TypeScale.micro)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 4)
                    .padding(.vertical, 1)
                    .background(Capsule(style: .continuous).fill(Theme.wellFill))
                Text(L("撤销"))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            case .failed(let message):
                ErrorLine(text: message, lineLimit: 1, retry: model.canRetry ? retry : nil)
            }
        }
        .font(Theme.TypeScale.labelMedium)
        .padding(.horizontal, 10)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background { Capsule(style: .continuous).fill(.regularMaterial) }
        .overlay {
            let shape = Capsule(style: .continuous)
            // 效果图 `.mat`：0.5 磅描边，黑 12%。
            shape.strokeBorder(Color.black.opacity(0.12), lineWidth: 0.5)
            if working, !reduceMotion {
                SelectionSweep().clipShape(shape)
            }
        }
        .shadow(color: Theme.panelShadow, radius: Theme.panelShadowRadius, y: Theme.panelShadowY)
    }
}

/// 一道斜光只沿胶囊从左扫到右，1.2 秒一趟。不描输入框。
private struct SelectionSweep: View {
    var body: some View {
        GeometryReader { geo in
            let band = max(geo.size.width * 0.45, 28)
            let travel = geo.size.width + band * 2
            LinearGradient(
                colors: [Color.clear, Color.primary.opacity(0.22), Color.clear],
                startPoint: .leading,
                endPoint: .trailing
            )
            .frame(width: band, height: geo.size.height)
            .keyframeAnimator(initialValue: CGFloat(0), repeating: true) { content, t in
                content.offset(x: -band + travel * t)
            } keyframes: { _ in
                KeyframeTrack {
                    LinearKeyframe(CGFloat(1), duration: 1.2)
                }
            }
        }
        .allowsHitTesting(false)
    }
}

/// 按住 Fn 时屏幕底部居中的深色胶囊。和快捷翻译浮标分开：位置、颜色、三种状态都不一样。
/// 只负责显示。按住、松开、取消仍由 `FnDictate` 管。
@MainActor
final class VoiceCapsule {
    static let shared = VoiceCapsule()

    private var panel: NSPanel?
    private let model = VoiceCapsuleModel()
    private var generation = 0

    private let height: CGFloat = 40
    private let maxTextWidth: CGFloat = 300
    /// 离 Dock 上沿（也就是屏幕可用区底边）的距离。
    private let dockGap: CGFloat = 16

    func generationToken() -> Int { generation }

    /// 这段时间里如果胶囊已经换成别的内容，就不要把它收掉。
    func hideIfStill(_ token: Int) {
        guard generation == token else { return }
        hide()
    }

    /// 麦克风还没开。不要写成「在听」。
    func prepare(_ mode: VoiceMode) {
        generation += 1
        model.mode = mode
        model.phase = .preparing
        model.level = 0
        model.text = ""
        place()
        present()
    }

    /// 切换语音模式：只亮一下模式图标和名字，大约一秒后收起。
    /// `title` 是 `VoiceMode.title`。菜单那条路只传得出这个字符串。
    func announce(_ title: String) {
        let mode = VoiceMode.allCases.first { $0.title == title } ?? model.mode
        generation += 1
        model.mode = mode
        model.phase = .notice(title)
        model.level = 0
        model.text = ""
        place()
        present()
        dismiss(after: 1)
    }

    /// 按住 Fn：电平竖条跟着麦克风跳，右边写最近识别的字。
    func listen(_ mode: VoiceMode) {
        generation += 1
        model.mode = mode
        model.phase = .listening
        model.level = 0
        model.text = ""
        place()
        present()
    }

    /// 松开之后还在识别、翻译或润色。竖条换成转圈，字换成这一句。
    func busy(_ label: String) {
        guard panel?.isVisible == true else { return }
        model.phase = .busy(label)
        model.text = ""
        place()
    }

    func level(rms: Float) {
        guard model.phase == .listening else { return }
        let db = 20 * log10(Double(max(rms, 1e-7)))
        model.level = min(1, max(0, (db + 50) / 44))
    }

    /// 最近识别或译出的一句。太长时由视图从左边截。
    func note(_ text: String) {
        guard panel?.isVisible == true else { return }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, model.text != trimmed else { return }
        model.text = trimmed
        place()
    }

    /// 没写进输入框。字还留在胶囊上，旁边标已记入历史。
    func kept(_ message: String) {
        guard panel?.isVisible == true else {
            generation += 1
            model.phase = .notice(message)
            model.text = ""
            place()
            present()
            dismiss(after: 1.4)
            return
        }
        model.phase = .notice(message)
        dismiss(after: 1.4)
    }

    func fail(_ message: String) {
        generation += 1
        model.phase = .failed(message)
        model.text = ""
        place()
        present()
        dismiss(after: 1.6)
    }

    func hide() {
        generation += 1
        panel?.orderOut(nil)
    }

    /// 屏幕底部居中，离 Dock 上沿 16 磅。宽度跟着字数走，最长一行。
    private func place() {
        let panel = ensurePanel()
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { $0.frame.contains(mouse) } ?? NSScreen.main
        let visible = screen?.visibleFrame ?? NSScreen.main?.visibleFrame ?? .zero
        let width = min(capsuleWidth(), max(160, visible.width - 32))
        let frame = NSRect(
            x: visible.midX - width / 2,
            y: visible.minY + dockGap,
            width: width,
            height: height
        )
        panel.setFrame(frame, display: true)
    }

    private func capsuleWidth() -> CGFloat {
        let font = Theme.TypeScale.nsBody
        let text: String
        switch model.phase {
        case .listening:
            text = model.text
        case .preparing:
            text = ""
        case .busy(let label), .notice(let label), .failed(let label):
            text = label
        }
        let measured = text.isEmpty ? 0 : (text as NSString).size(withAttributes: [.font: font]).width
        // 模式图标 22 + 电平或转圈 18 + 间距和内边距。
        return ceil(min(measured, maxTextWidth) + 22 + 18 + 10 + 12 + 16)
    }

    private func present() {
        let panel = ensurePanel()
        OverlayPlacement.fadeIn(panel)
        panel.orderFrontRegardless()
    }

    private func dismiss(after delay: TimeInterval) {
        let mine = generation
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.generation == mine, let panel = self.panel else { return }
                NSAnimationContext.runAnimationGroup({ ctx in
                    ctx.duration = 0.09
                    panel.animator().alphaValue = 0
                }, completionHandler: {
                    MainActor.assumeIsolated {
                        guard self.generation == mine else { return }
                        panel.orderOut(nil)
                    }
                })
            }
        }
    }

    private func ensurePanel() -> NSPanel {
        if let panel { return panel }
        let made = OverlayPanel.make(
            contentRect: NSRect(x: 0, y: 0, width: 280, height: height),
            style: .floating,
            content: NSHostingView(rootView: VoiceCapsuleView(model: model)),
            deferCreation: true
        )
        made.level = .statusBar
        made.ignoresMouseEvents = true
        made.alphaValue = 0
        panel = made
        return made
    }
}

@MainActor
final class VoiceCapsuleModel: ObservableObject {
    enum Phase: Equatable {
        case preparing
        case listening
        case busy(String)
        case notice(String)
        case failed(String)
    }

    @Published var phase: Phase = .preparing
    @Published var mode: VoiceMode = .recognize
    @Published var level: Double = 0
    @Published var text = ""
}

private struct VoiceCapsuleView: View {
    @ObservedObject var model: VoiceCapsuleModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        HStack(spacing: 10) {
            KIconView(model.mode.icon, size: 12)
                .foregroundStyle(Theme.onDark.primary)
                .frame(width: 22, height: 22)
                .background(Circle().fill(Theme.onDark.primary.opacity(0.14)))
            middle
            caption
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.leading, 12)
        .padding(.trailing, 16)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background { Capsule(style: .continuous).fill(Color.black.opacity(0.8)) }
        .shadow(color: .black.opacity(0.18), radius: 12, y: 4)
    }

    @ViewBuilder
    private var middle: some View {
        switch model.phase {
        case .listening:
            VoiceLevelBars(level: model.level, reduceMotion: reduceMotion)
        case .failed:
            KIconView(.warn, size: 12)
                .foregroundStyle(Theme.danger)
        default:
            ProgressView()
                .controlSize(.small)
                .colorScheme(.dark)
        }
    }

    private var caption: some View {
        let line: String
        let color: Color
        switch model.phase {
        case .listening:
            line = model.text
            color = Theme.onDark.primary
        case .preparing:
            line = ""
            color = Theme.onDark.secondary
        case .busy(let label), .notice(let label):
            line = label
            color = Theme.onDark.secondary
        case .failed(let message):
            line = message
            color = Theme.onDark.secondary
        }
        return Text(line)
            .font(Theme.TypeScale.body)
            .foregroundStyle(color)
            .lineLimit(1)
            .truncationMode(.head)
    }
}

/// 五根白色电平竖条，高度跟着麦克风。
private struct VoiceLevelBars: View {
    var level: Double
    var reduceMotion: Bool

    private let weights: [Double] = [0.45, 0.75, 1, 0.62, 0.38]

    var body: some View {
        HStack(alignment: .center, spacing: 2) {
            ForEach(weights.indices, id: \.self) { i in
                Capsule(style: .continuous)
                    .fill(Theme.onDark.primary)
                    .frame(width: 3, height: 4 + 12 * CGFloat(min(1, level * weights[i] * 1.35)))
            }
        }
        .frame(width: 22, height: 16)
        .animation(reduceMotion ? nil : .easeOut(duration: 0.08), value: level)
        .accessibilityLabel(L("在听"))
    }
}

extension VoiceMode {
    /// 胶囊左边那一枚。识别、翻译、传译各一个。
    var icon: KIcon {
        switch self {
        case .recognize: return .mic
        case .translate: return .tr
        case .interpret: return .wave
        }
    }
}

