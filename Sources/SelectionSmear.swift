import AppKit

/// Paint locked to the frozen screenshot. Moving the selection does not move the ink.
@MainActor
final class SelectionSmear {
    let original: CGImage
    private let context: CGContext
    private(set) var image: CGImage
    private var undoStack: [CGImage] = []

    /// 画笔半径，按视图点算。滚轮可调，范围见 `minBrushRadius` / `maxBrushRadius`。
    var brushRadius: CGFloat = 8
    static let minBrushRadius: CGFloat = 3
    static let maxBrushRadius: CGFloat = 40

    var canUndo: Bool { !undoStack.isEmpty }

    init?(image: CGImage) {
        guard let context = Self.makeClearContext(width: image.width, height: image.height) else { return nil }
        original = image
        self.context = context
        guard let blank = context.makeImage() else { return nil }
        self.image = blank
    }

    func beginStroke() {
        guard let shot = context.makeImage() else { return }
        undoStack.append(shot)
        if undoStack.count > 8 { undoStack.removeFirst() }
    }

    func undo() {
        guard let shot = undoStack.popLast() else { return }
        let full = CGRect(x: 0, y: 0, width: original.width, height: original.height)
        context.clear(full)
        context.draw(shot, in: full)
        publish()
    }

    func clear() {
        beginStroke()
        context.clear(CGRect(x: 0, y: 0, width: original.width, height: original.height))
        publish()
    }

    /// `last` and the returned point are in image pixels, origin bottom-left, same as the view.
    func stamp(from last: CGPoint?, to viewPoint: CGPoint, viewSize: CGSize, selection: CGRect, erasing: Bool) -> CGPoint {
        guard viewSize.width > 1, viewSize.height > 1 else { return viewPoint }
        let sx = CGFloat(original.width) / viewSize.width
        let sy = CGFloat(original.height) / viewSize.height
        let here = CGPoint(x: viewPoint.x * sx, y: viewPoint.y * sy)
        // 半径按视图点给，进图像像素时随缩放放大，这样 2× 屏上看到多粗就涂多粗。
        let radius = max(2, brushRadius * max(sx, sy))
        let clip = CGRect(
            x: selection.minX * sx,
            y: selection.minY * sy,
            width: selection.width * sx,
            height: selection.height * sy
        )
        context.saveGState()
        context.clip(to: clip)
        // clip(to:) 之后路径里还留着裁剪矩形，不清掉会把整个裁剪框一起描出来，笔迹反而没了。
        context.beginPath()
        context.setShouldAntialias(true)
        context.setLineCap(.round)
        context.setLineJoin(.round)
        context.setLineWidth(radius * 2)
        if erasing { context.setBlendMode(.clear) }
        let ink = CGColor(red: 0, green: 0, blue: 0, alpha: 1)
        context.setStrokeColor(ink)
        context.setFillColor(ink)
        if let last {
            // 一段圆头描边就是一笔，比逐点叠圆更顺，转弯处也不会出现锯齿。
            context.move(to: last)
            context.addLine(to: here)
            context.strokePath()
        } else {
            // 落笔的第一下没有上一段，补一个圆点，否则点一下不出墨。
            context.fillEllipse(in: CGRect(x: here.x - radius, y: here.y - radius, width: radius * 2, height: radius * 2))
        }
        if erasing { context.setBlendMode(.normal) }
        context.restoreGState()
        publish()
        return here
    }

    static func crop(_ image: CGImage, selection: CGRect, viewSize: CGSize) -> CGImage? {
        guard viewSize.width > 1, viewSize.height > 1 else { return nil }
        let pixelW = CGFloat(image.width)
        let pixelH = CGFloat(image.height)
        let rect = CGRect(
            x: selection.minX / viewSize.width * pixelW,
            y: (viewSize.height - selection.maxY) / viewSize.height * pixelH,
            width: selection.width / viewSize.width * pixelW,
            height: selection.height / viewSize.height * pixelH
        ).integral.intersection(CGRect(x: 0, y: 0, width: pixelW, height: pixelH))
        guard rect.width >= 2, rect.height >= 2 else { return nil }
        return image.cropping(to: rect)
    }

    private func publish() {
        if let made = context.makeImage() {
            image = made
        }
    }

    static func composite(base: CGImage, paint: CGImage) -> CGImage? {
        let w = base.width
        let h = base.height
        guard w > 0, h > 0 else { return nil }
        guard let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: w,
            pixelsHigh: h,
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        ) else { return nil }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        let baseSize = NSSize(width: w, height: h)
        NSImage(cgImage: base, size: baseSize).draw(in: NSRect(origin: .zero, size: baseSize))
        let paintSize = NSSize(width: paint.width, height: paint.height)
        NSImage(cgImage: paint, size: paintSize).draw(in: NSRect(origin: .zero, size: baseSize))
        NSGraphicsContext.restoreGraphicsState()
        return rep.cgImage
    }

    private static func makeClearContext(width: Int, height: Int) -> CGContext? {
        let info = CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
        guard let ctx = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: info
        ) else { return nil }
        ctx.clear(CGRect(x: 0, y: 0, width: width, height: height))
        return ctx
    }
}

enum SmearTool {
    case adjust, paint, erase
}

/// Tools sitting on the selection, the way screenshot apps do.
@MainActor
final class SelectionToolbar: NSView {
    var onPaint: () -> Void = {}
    var onErase: () -> Void = {}
    var onUndo: () -> Void = {}
    var onClear: () -> Void = {}
    var onRecognize: () -> Void = {}
    var onCancel: () -> Void = {}

    static let height: CGFloat = 42

    private let glass = GlassPlate()
    // 图标按「一眼知道做什么」挑：涂抹用记号笔、识别用取词框，
    // 撤销/清除/取消用最通用的那几个，不自创符号。
    private let paintButton = ToolbarButton(symbol: "highlighter", label: L("涂抹"))
    private let eraseButton = ToolbarButton(symbol: "eraser", label: L("橡皮"))
    private let undoButton = ToolbarButton(symbol: "arrow.uturn.backward", label: L("撤销"))
    private let clearButton = ToolbarButton(symbol: "trash", label: L("清除"))
    private let recognize = ToolbarButton(symbol: "text.viewfinder", label: L("识别"), round: false)
    private let cancel = ToolbarButton(symbol: nil, label: L("取消"), handDrawn: .cross)

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.shadowColor = NSColor.black.cgColor
        layer?.shadowOpacity = 0.45
        layer?.shadowRadius = 16
        layer?.shadowOffset = CGSize(width: 0, height: 5)

        addSubview(glass)

        recognize.isProminent = true
        cancel.isDestructive = true

        let sep = NSView()
        sep.wantsLayer = true
        sep.layer?.cornerRadius = 0.5
        sep.layer?.backgroundColor = NSColor.white.withAlphaComponent(0.18).cgColor

        var x: CGFloat = 6
        let diameter: CGFloat = 28
        for button in [paintButton, eraseButton, undoButton, clearButton] {
            button.frame = CGRect(x: x, y: 7, width: diameter, height: diameter)
            addSubview(button)
            x += diameter + 2
        }
        x += 2
        sep.frame = CGRect(x: x, y: 13, width: 1, height: 16)
        addSubview(sep)
        x += 1 + 7
        recognize.frame = CGRect(x: x, y: 7, width: diameter, height: diameter)
        addSubview(recognize)
        x += diameter + 3
        cancel.frame = CGRect(x: x, y: 7, width: diameter, height: diameter)
        addSubview(cancel)
        x += diameter + 6

        paintButton.target = self
        paintButton.action = #selector(didPaint)
        eraseButton.target = self
        eraseButton.action = #selector(didErase)
        undoButton.target = self
        undoButton.action = #selector(didUndo)
        clearButton.target = self
        clearButton.action = #selector(didClear)
        recognize.target = self
        recognize.action = #selector(didRecognize)
        cancel.target = self
        cancel.action = #selector(didCancel)

        self.frame.size = NSSize(width: x, height: Self.height)
        reflect(tool: .adjust, canUndo: false)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { return nil }

    override func layout() {
        super.layout()
        glass.frame = bounds
        glass.layer?.cornerRadius = bounds.height / 2
        for b in [paintButton, eraseButton, undoButton, clearButton, cancel] as [ToolbarButton] {
            b.cornerRadius = b.bounds.height / 2
        }
    }

    /// 浮层窗口弹出时不是 key，第一下点击会被系统拿去激活窗口。这里认下这一下，
    /// 让按钮一次点亮。
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    func reflect(tool: SmearTool, canUndo: Bool, paintEnabled: Bool = true) {
        paintButton.isChosen = tool == .paint
        eraseButton.isChosen = tool == .erase
        // 没拿到冻结截图时涂抹没有落笔的底，点亮了也画不出来，索性置灰。
        paintButton.isEnabled = paintEnabled
        eraseButton.isEnabled = paintEnabled
        undoButton.isEnabled = canUndo
        clearButton.isEnabled = canUndo
    }

    @objc private func didPaint() { onPaint() }
    @objc private func didErase() { onErase() }
    @objc private func didUndo() { onUndo() }
    @objc private func didClear() { onClear() }
    @objc private func didRecognize() { onRecognize() }
    @objc private func didCancel() { onCancel() }
}

/// 工具条的玻璃底：磨砂 + 顶边高光 + 细描边。模糊的是本窗口里已经画好的冻结截图，
/// 所以隔着工具条也能看见下面被框住的画面。
@MainActor
final class GlassPlate: NSVisualEffectView {
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        material = .hudWindow
        blendingMode = .withinWindow
        state = .active
        wantsLayer = true
        layer?.masksToBounds = true
        layer?.borderWidth = 1
        layer?.borderColor = NSColor.white.withAlphaComponent(0.22).cgColor
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { return nil }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        // 顶部一道极淡的白色渐变，做出玻璃的厚度感。
        let path = NSBezierPath(roundedRect: bounds, xRadius: bounds.height / 2, yRadius: bounds.height / 2)
        let gradient = NSGradient(colors: [
            NSColor.white.withAlphaComponent(0.16),
            NSColor.white.withAlphaComponent(0.02),
        ])
        path.addClip()
        gradient?.draw(in: bounds, angle: -90)
    }
}

/// 工具条上的一个圆钮：悬停浮一层，按下再深一档，选中填主题色，禁用只剩半透明图标。
@MainActor
final class ToolbarButton: NSButton {
    var isProminent = false { didSet { restyle() } }
    var isChosen = false { didSet { restyle() } }
    /// 取消这类「退出」动作悬停时泛红，和确认区分开。
    var isDestructive = false { didSet { restyle() } }
    /// 圆钮用直径的一半，文字钮用固定胶囊圆角。
    var cornerRadius: CGFloat = 14 { didSet { layer?.cornerRadius = cornerRadius } }

    private var hovering = false
    private var pressed = false
    private var tracking: NSTrackingArea?

    private let glyph: NSImage?
    /// 自绘字形。SF Symbols 的 xmark 字形框比同类图标小一圈，在圆钮里怎么排都显得偏。
    private let handDrawn: HandDrawn?

    enum HandDrawn { case cross }

    init(symbol: String?, label: String, round: Bool = true, pointSize: CGFloat = 14,
         weight: NSFont.Weight = .medium, handDrawn: HandDrawn? = nil) {
        let image = symbol.flatMap {
            NSImage(systemSymbolName: $0, accessibilityDescription: label)?
                .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: pointSize, weight: weight))
        }
        glyph = image
        self.handDrawn = handDrawn
        super.init(frame: .zero)
        isBordered = false
        imagePosition = .imageOnly
        imageScaling = .scaleProportionallyDown
        self.image = image
        image?.isTemplate = true
        // NSButton 默认标题就是「Button」；不清掉会压在图标上。
        // 自绘图标没有 image，同样要把标题清掉，否则文字会和叉号叠在一起。
        title = (image == nil && handDrawn == nil) ? label : ""
        toolTip = label
        setAccessibilityLabel(label)
        refusesFirstResponder = true
        wantsLayer = true
        layer?.cornerCurve = .continuous
        layer?.cornerRadius = round ? 14 : 10
        restyle()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { return nil }

    /// 浮层窗口弹出时不是 key，第一下点击本会被系统拿去激活窗口。
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override var isEnabled: Bool {
        didSet { restyle() }
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        tracking = area
    }

    override func mouseEntered(with event: NSEvent) {
        hovering = true
        restyle()
    }

    override func mouseExited(with event: NSEvent) {
        hovering = false
        pressed = false
        restyle()
    }

    override func mouseDown(with event: NSEvent) {
        pressed = true
        restyle()
        super.mouseDown(with: event)
        // super 在跟踪循环里运行，回来后无论是否命中都算已松开。
        pressed = false
        restyle()
    }

    private var ink: NSColor {
        if isProminent {
            return NSColor.black.withAlphaComponent(isEnabled ? 0.85 : 0.3)
        }
        return NSColor.white.withAlphaComponent(isEnabled ? (hovering || isChosen ? 1 : 0.9) : 0.3)
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        if let handDrawn {
            drawHandDrawn(handDrawn)
        }
    }

    /// 自绘图标：长度和粗细细调过，几何中心严格对齐按钮中心。
    private func drawHandDrawn(_ shape: HandDrawn) {
        switch shape {
        case .cross:
            let inset: CGFloat = 8.5
            let a = NSPoint(x: inset, y: inset)
            let b = NSPoint(x: bounds.width - inset, y: bounds.height - inset)
            let path = NSBezierPath()
            path.move(to: a)
            path.line(to: b)
            path.move(to: NSPoint(x: b.x, y: a.y))
            path.line(to: NSPoint(x: a.x, y: b.y))
            path.lineWidth = 1.8
            path.lineCapStyle = .round
            ink.setStroke()
            path.stroke()
        }
    }

    private func restyle() {
        if isProminent {
            // 主按钮用浅色实心胶囊，深色图标；比高饱和的蓝块安静，但依然是整条最亮的一处。
            layer?.backgroundColor = NSColor.white.withAlphaComponent(isEnabled ? (pressed ? 0.78 : 0.94) : 0.3).cgColor
        } else if isChosen {
            // 选中的工具只浮一层淡白，不再填主题色。
            layer?.backgroundColor = NSColor.white
                .withAlphaComponent(isEnabled ? (pressed ? 0.34 : 0.24) : 0.08).cgColor
        } else if !isEnabled {
            layer?.backgroundColor = NSColor.clear.cgColor
        } else if isDestructive && hovering {
            layer?.backgroundColor = NSColor.systemRed.withAlphaComponent(pressed ? 0.36 : 0.22).cgColor
        } else {
            layer?.backgroundColor = NSColor.white
                .withAlphaComponent(pressed ? 0.26 : (hovering ? 0.16 : 0.0)).cgColor
        }
        contentTintColor = ink
        guard !title.isEmpty else { return }
        let para = NSMutableParagraphStyle()
        para.alignment = .center
        attributedTitle = NSAttributedString(
            string: title,
            attributes: [
                .font: Theme.TypeScale.nsLabel,
                .foregroundColor: ink,
                .paragraphStyle: para,
            ]
        )
    }
}
