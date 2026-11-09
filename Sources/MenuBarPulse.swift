import AppKit

/// 录音的时候，菜单栏那个小图标像跷跷板一样来回摆。
///
/// 图标是 template 图，系统只拿它的 alpha 上色；所以每一帧画的是同一张图绕中心转了个角度。
/// 不动 button 的 layer，因为开了「在菜单栏显示模式」时模式名就贴在图标右边，整块转起来字也会歪。
@MainActor
final class MenuBarPulse {
    static let shared = MenuBarPulse()

    /// 同时在响的来源。几个可以叠着开，全停了才收。
    enum Source: Hashable {
        /// 实时字幕 / 会议记录：`SystemAudioTranslateController` 在听。
        case liveCaptions
        /// 按住 Fn 的语音识别、翻译、传译：`FnDictate` 耳朵在。
        case dictate
    }

    private weak var button: NSStatusBarButton?
    private var base: NSImage?
    private var active: Set<Source> = []

    private var timer: Timer?
    private var startedAt: TimeInterval = 0
    /// 0…1 的起停包络，角度从这里长出来、再退回 0，停的时候不跳。
    private var envelope: CGFloat = 0
    private var angle: CGFloat = 0
    private var frames: [Int: NSImage] = [:]

    /// 最斜的角度。图标内容只有 13×6，绕中心转 12° 仍在 18×18 的框里，不裁角。
    private let amplitude: CGFloat = 12
    /// 一个来回。再快像发抖，再慢像没在动。
    private let period: TimeInterval = 1.15
    private let frameInterval: TimeInterval = 1.0 / 60.0
    /// 起步和收尾各占这么久，短按也能看到一小下。
    private let fade: TimeInterval = 0.2

    private init() {}

    func attach(_ button: NSStatusBarButton, image: NSImage?) {
        self.button = button
        setBase(image)
    }

    /// 换掉静止时那张图。正在摆的话先记下，摆完自然用新的。
    func setBase(_ image: NSImage?) {
        base = image
        frames.removeAll()
        apply()
    }

    func setActive(_ on: Bool, for source: Source) {
        let wasIdle = active.isEmpty
        if on {
            active.insert(source)
        } else {
            active.remove(source)
        }
        // 收尾交给 tick：包络降到 0 再停表，角度不会一下弹回直的。
        if !active.isEmpty, wasIdle { start() }
    }

    /// 菜单里换了模式、重写了标题之后调一下，别把正在摆的那一帧顶回静止图。
    func refresh() { apply() }

    // MARK: - 摆

    private func start() {
        guard timer == nil else { return }
        // 开了「减弱动态效果」就不摆，图标保持不动。
        guard !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else { return }
        startedAt = ProcessInfo.processInfo.systemUptime
        envelope = 0
        angle = 0
        let timer = Timer(timeInterval: frameInterval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        // 菜单拉下来时主线程在 tracking 模式里跑，只挂 .default 会冻住。
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    private func tick() {
        guard let button else {
            stopTimer()
            return
        }
        let now = ProcessInfo.processInfo.systemUptime
        let step = CGFloat(frameInterval / fade)
        envelope = active.isEmpty ? max(0, envelope - step) : min(1, envelope + step)
        // 正弦就是跷跷板：两头慢、中间快，到顶自然停一下再往下。
        let wave = CGFloat(sin(2 * .pi * (now - startedAt) / period))
        let eased = envelope * envelope * (3 - 2 * envelope)
        angle = amplitude * wave * eased
        apply()
        if active.isEmpty, envelope <= 0 {
            angle = 0
            stopTimer()
            button.image = base
        }
    }

    private func stopTimer() {
        timer?.invalidate()
        timer = nil
    }

    private func apply() {
        guard let button else { return }
        guard angle != 0, let turned = frameImage(degrees: angle) else {
            button.image = base
            return
        }
        button.image = turned
    }

    // MARK: - 画

    /// 按 0.5° 一格缓存。18pt 的图标上这点差别看不出来，省得每秒重画六十次。
    private func frameImage(degrees: CGFloat) -> NSImage? {
        guard let base else { return nil }
        let key = Int((degrees * 2).rounded())
        if let cached = frames[key] { return cached }
        let box = NSRect(x: 0, y: 0, width: 18, height: 18)
        guard let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: 36, pixelsHigh: 36,
            bitsPerSample: 8, samplesPerPixel: 4,
            hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0, bitsPerPixel: 0
        ) else { return nil }
        // 先定 size 再建 context：context 按 rep.size 建 2x 的 CTM，顺序反了 18pt 会画成 18px 缩在左下角。
        rep.size = box.size
        guard let context = NSGraphicsContext(bitmapImageRep: rep) else { return nil }

        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        context.imageInterpolation = .high
        context.shouldAntialias = true
        NSColor.clear.setFill()
        box.fill(using: .copy)

        let turn = NSAffineTransform()
        turn.translateX(by: box.midX, yBy: box.midY)
        turn.rotate(byDegrees: CGFloat(key) / 2)
        turn.translateX(by: -box.midX, yBy: -box.midY)
        turn.concat()
        base.draw(in: box)

        NSGraphicsContext.restoreGraphicsState()

        let image = NSImage(size: box.size)
        image.addRepresentation(rep)
        image.isTemplate = true
        frames[key] = image
        return image
    }
}
