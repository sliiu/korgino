import AppKit
import SwiftUI

/// 快捷翻译进行时，叠在划选或输入框上的那一层。不抢焦点，也不挡鼠标。
@MainActor
final class QuickOverlay {
    static let shared = QuickOverlay()

    private var panel: NSPanel?
    private let model = QuickOverlayModel()
    private var generation = 0

    private let pad: CGFloat = 3
    private let badgeRow: CGFloat = 28
    private let minWidth: CGFloat = 360

    /// `rect` 是辅助功能坐标：主屏左上角为原点。`language` 是这一次要译成的语言，写在供应商旁边。
    func begin(rect: CGRect?, provider: String, language: String? = nil) {
        generation += 1
        layout(rect)
        let hint = language?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let label = hint.isEmpty ? provider : (provider.isEmpty ? hint : "\(provider) · \(hint)")
        model.phase = .working(label)
        model.source = ""
        model.live = ""
        present()
    }

    /// 麦克风还没开。不要写成「在听」。
    func prepare(_ mode: String) {
        generation += 1
        layout(nil)
        model.phase = .busy(String(format: L("准备中 · %@"), mode))
        model.modeTitle = mode
        model.level = 0
        model.source = ""
        model.live = ""
        present()
    }

    /// 按住 Fn 时：在听，胶囊上写着当前模式，竖条跟着麦克风电平跳。
    func listen(_ mode: String) {
        generation += 1
        layout(nil)
        model.phase = .listening
        model.modeTitle = mode
        model.level = 0
        model.source = ""
        model.live = ""
        present()
    }

    /// 切换语音模式：只写出模式名，大约一秒后收起。
    func announce(_ title: String) {
        generation += 1
        layout(nil)
        model.phase = .notice(title)
        model.modeTitle = ""
        model.level = 0
        model.source = ""
        model.live = ""
        present()
        dismiss(after: 1)
    }

    /// 没写进输入框。字还留在浮层上，旁边标已记入历史。
    func kept(_ message: String) {
        guard panel?.isVisible == true else {
            announce(message)
            return
        }
        model.phase = .noted(message)
        dismiss(after: 1.4)
    }

    func generationToken() -> Int { generation }

    /// 这段时间里如果浮层已经换成别的内容，就不要把它收掉。
    func hideIfStill(_ token: Int) {
        guard generation == token else { return }
        hide()
    }

    /// 松开之后还在识别或翻译时，换成这一句，不重新摆位置。
    func busy(_ label: String) {
        guard panel?.isVisible == true else { return }
        model.phase = .busy(label)
    }

    func level(rms: Float) {
        guard model.phase == .listening else { return }
        let db = 20 * log10(Double(max(rms, 1e-7)))
        model.level = min(1, max(0, (db + 50) / 44))
    }

    func note(_ text: String) {
        note(source: "", text: text)
    }

    func note(source: String, text: String) {
        guard panel?.isVisible == true else { return }
        let src = source.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !src.isEmpty || !trimmed.isEmpty else { return }
        guard model.source != src || model.live != trimmed else { return }
        fitLive(source: src, text: trimmed)
        model.source = src
        model.live = trimmed
    }

    func succeed() {
        guard panel?.isVisible == true else { return }
        model.phase = .done
        dismiss(after: 0.55)
    }

    func hide() {
        generation += 1
        panel?.orderOut(nil)
    }

    func fail(_ message: String, rect: CGRect?) {
        generation += 1
        if panel?.isVisible != true || rect != nil { layout(rect) }
        model.phase = .failed(message)
        present()
        dismiss(after: 1.6)
    }

    private func layout(_ axRect: CGRect?) {
        let panel = ensurePanel()
        let primary = NSScreen.screens.first?.frame ?? .zero
        guard let axRect else {
            let mouse = NSEvent.mouseLocation
            model.target = nil
            model.badgeOrigin = .zero
            panel.setFrame(NSRect(x: mouse.x + 12, y: mouse.y - badgeRow - 10, width: minWidth, height: badgeRow), display: false)
            return
        }
        var target = OverlayPlacement.onScreen(axRect, primary: primary).insetBy(dx: -pad, dy: -pad)
        let screen = OverlayPlacement.screen(containing: target)
        if let visible = screen?.visibleFrame {
            let clipped = target.intersection(visible)
            if !clipped.isNull, clipped.width > 8, clipped.height > 8 { target = clipped }
        }
        let roomAbove = (screen?.visibleFrame.maxY ?? .greatestFiniteMagnitude) - target.maxY >= badgeRow
        let width = max(target.width, minWidth)
        let height = target.height + badgeRow
        let originY = roomAbove ? target.minY : target.minY - badgeRow
        panel.setFrame(NSRect(x: target.minX, y: originY, width: width, height: height), display: false)
        model.target = CGRect(x: 0, y: roomAbove ? badgeRow : 0, width: target.width, height: target.height)
        model.badgeOrigin = CGPoint(x: 0, y: roomAbove ? 0 : target.height + 4)
    }

    /// 听写浮层跟着字数变高，长句换行，不再裁成一行。
    private func fitLive(source: String, text: String) {
        guard model.target == nil, let panel else { return }
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { $0.frame.contains(mouse) } ?? NSScreen.main
        let visible = screen?.visibleFrame ?? panel.frame
        let width = min(minWidth, max(160, visible.width - 24))
        let font = NSFont.systemFont(ofSize: 12, weight: .medium)
        let textWidth = max(40, width - 46)
        let measure: (String) -> CGFloat = { line in
            guard !line.isEmpty else { return 0 }
            let box = (line as NSString).boundingRect(
                with: NSSize(width: textWidth, height: .greatestFiniteMagnitude),
                options: [.usesLineFragmentOrigin, .usesFontLeading],
                attributes: [.font: font]
            )
            return ceil(box.height)
        }
        let gap: CGFloat = source.isEmpty || text.isEmpty ? 0 : 4
        let maxH = max(badgeRow, visible.height - 24)
        let height = min(max(badgeRow, measure(source) + gap + measure(text) + 20), maxH)
        model.bandWidth = width
        let top = panel.frame.height > 1 ? panel.frame.maxY : mouse.y - 10
        var frame = NSRect(x: panel.frame.minX, y: top - height, width: width, height: height)
        if frame.maxX > visible.maxX { frame.origin.x = visible.maxX - width - 8 }
        if frame.minX < visible.minX { frame.origin.x = visible.minX + 8 }
        if frame.minY < visible.minY { frame.origin.y = visible.minY + 8 }
        if frame.maxY > visible.maxY { frame.origin.y = visible.maxY - height - 8 }
        panel.setFrame(frame, display: true)
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
                    ctx.duration = 0.22
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
            contentRect: NSRect(x: 0, y: 0, width: minWidth, height: badgeRow),
            style: .floating,
            content: NSHostingView(rootView: QuickOverlayView(model: model)),
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
final class QuickOverlayModel: ObservableObject {
    enum Phase: Equatable {
        case working(String)
        case listening
        case busy(String)
        case notice(String)
        case noted(String)
        case done
        case failed(String)
    }

    @Published var phase: Phase = .working("")
    @Published var modeTitle = ""
    @Published var level: Double = 0
    @Published var source = ""
    @Published var live = ""
    @Published var bandWidth: CGFloat = 360
    /// 面板里的坐标，左上角为原点。
    @Published var target: CGRect?
    @Published var badgeOrigin: CGPoint = .zero
}

private struct QuickOverlayView: View {
    @ObservedObject var model: QuickOverlayModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private let radius: CGFloat = 6

    var body: some View {
        ZStack(alignment: .topLeading) {
            if let target = model.target {
                highlight
                    .frame(width: target.width, height: target.height)
                    .offset(x: target.minX, y: target.minY)
            }
            badge
                .fixedSize(horizontal: model.source.isEmpty && model.live.isEmpty, vertical: true)
                .offset(x: model.badgeOrigin.x, y: model.badgeOrigin.y)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private var tint: Color {
        switch model.phase {
        case .working, .listening, .busy, .notice: return .accentColor
        case .done, .noted: return .green
        case .failed: return .red
        }
    }

    private var working: Bool {
        if case .working = model.phase { return true }
        return false
    }

    private var highlight: some View {
        let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
        let colorMotion: Animation? = reduceMotion ? nil : .easeOut(duration: 0.18)
        return shape
            .fill(tint.opacity(working ? 0.07 : 0.12))
            .animation(colorMotion, value: model.phase)
            .overlay {
                if working, !reduceMotion {
                    SelectionSweep(tint: tint).clipShape(shape)
                }
            }
            .overlay {
                shape
                    .strokeBorder(tint.opacity(0.85), lineWidth: 1.5)
                    .animation(colorMotion, value: model.phase)
            }
    }

    @ViewBuilder
    private var indicator: some View {
        if model.phase == .listening {
            LevelBars(level: model.level, reduceMotion: reduceMotion)
        } else {
            ProgressView()
                .controlSize(.mini)
        }
    }

    private var idleLabel: String {
        switch model.phase {
        case .working(let provider): return provider.isEmpty ? L("翻译中") : String(format: L("翻译中 · %@"), provider)
        case .listening:
            return model.modeTitle.isEmpty ? L("在听") : String(format: L("在听 · %@"), model.modeTitle)
        case .busy(let label): return label
        case .notice(let text): return text
        default: return ""
        }
    }

    private var badge: some View {
        HStack(alignment: model.source.isEmpty && model.live.isEmpty ? .center : .top, spacing: 8) {
            switch model.phase {
            case .working, .listening, .busy:
                if model.source.isEmpty && model.live.isEmpty {
                    indicator
                    Text(idleLabel)
                        .lineLimit(1)
                } else {
                    indicator
                        .padding(.top, 1)
                    VStack(alignment: .leading, spacing: 4) {
                        if !model.source.isEmpty {
                            Text(model.source)
                                .foregroundStyle(.secondary)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        if !model.live.isEmpty {
                            Text(model.live)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
            case .notice(let text):
                Text(text)
                    .lineLimit(1)
            case .noted(let message):
                notedBadge(message)
            case .done:
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                Text(L("已替换"))
            case .failed(let message):
                ErrorLine(text: message, lineLimit: 1)
                    .frame(maxWidth: 320, alignment: .leading)
            }
        }
        .font(.system(size: 12, weight: .medium))
        .padding(.horizontal, 10)
        .padding(.vertical, model.source.isEmpty && model.live.isEmpty ? 4 : 6)
        .frame(width: model.source.isEmpty && model.live.isEmpty ? nil : model.bandWidth, alignment: .topLeading)
        .background {
            if model.source.isEmpty && model.live.isEmpty {
                Capsule(style: .continuous).fill(.regularMaterial)
            } else {
                RoundedRectangle(cornerRadius: 10, style: .continuous).fill(.regularMaterial)
            }
        }
        .overlay {
            if model.source.isEmpty && model.live.isEmpty {
                Capsule(style: .continuous).strokeBorder(Color.primary.opacity(0.12), lineWidth: 0.5)
            } else {
                RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Color.primary.opacity(0.12), lineWidth: 0.5)
            }
        }
        .shadow(color: .black.opacity(0.12), radius: 3, y: 1)
    }

    private func notedBadge(_ message: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            if !model.source.isEmpty {
                Text(model.source)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if !model.live.isEmpty {
                Text(model.live)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack(spacing: 6) {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                Text(message)
                    .lineLimit(1)
            }
        }
    }
}

/// 一道斜光从左扫到右，1.2 秒一趟。一条重复的位移动画，不每帧刷新视图。
private struct SelectionSweep: View {
    var tint: Color

    var body: some View {
        GeometryReader { geo in
            let band = max(geo.size.width * 0.35, 60)
            let travel = geo.size.width + band * 2
            LinearGradient(
                colors: [tint.opacity(0), tint.opacity(0.28), tint.opacity(0)],
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
    }
}

/// 五根竖条，高度跟着麦克风电平。
private struct LevelBars: View {
    var level: Double
    var reduceMotion: Bool

    private let weights: [Double] = [0.55, 0.8, 1, 0.8, 0.55]

    var body: some View {
        HStack(alignment: .center, spacing: 2) {
            ForEach(weights.indices, id: \.self) { i in
                Capsule(style: .continuous)
                    .fill(Color.accentColor)
                    .frame(width: 2, height: 3 + 9 * CGFloat(min(1, level * weights[i] * 1.4)))
            }
        }
        .frame(width: 18, height: 12)
        .animation(reduceMotion ? nil : .easeOut(duration: 0.08), value: level)
        .accessibilityLabel(L("在听"))
    }
}
