import QuartzCore
import AppKit
@preconcurrency import Vision
import ScreenCaptureKit

struct OCRCaptureResult: Sendable {
    var text: String
    var links: [DetectedLink]
}

@MainActor
enum OCRCapture {
    static func captureRegionText() async throws -> String {
        try await captureRegion().0.text
    }

    /// Freeze the screens, let the user pick a region and smear on it, then OCR.
    static func captureRegion() async throws -> (OCRCaptureResult, CGImage) {
        let painted = try await RegionSelector.selectImage()
        guard painted.width > 2, painted.height > 2 else { throw TErr(L("选区太小")) }
        let provider = AppConfig.shared.ocrProvider
        let result = try await Task.detached(priority: .userInitiated) { () -> OCRCaptureResult in
            async let qrTask = LinkQRDetector.barcodes(in: painted)
            var text = ""
            var ocrError: Error?
            do {
                text = try await CloudOCR.recognizeText(cgImage: painted, provider: provider)
            } catch {
                ocrError = error
                if provider != .appleVision {
                    text = (try? await OCRCapture.recognize(painted)) ?? ""
                }
            }
            let qr = await qrTask
            var links = LinkQRDetector.links(in: text)
            var seen = Set(links.map(\.label))
            for q in qr where seen.insert(q.label).inserted {
                links.append(q)
            }
            if text.isEmpty && links.isEmpty {
                if let ocrError { throw ocrError }
                throw TErr(L("未识别到文字、链接或二维码"))
            }
            return OCRCaptureResult(text: text, links: links)
        }.value
        return (result, painted)
    }


    /// Full-screen shots taken before the overlay exists, so the overlay is not in the picture.
    static func freezeScreens() async throws -> [FrozenScreen] {
        let content: SCShareableContent
        do {
            content = try await Task.detached(priority: .userInitiated) {
                try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
            }.value
        } catch {
            throw screenCaptureDenied(error)
        }
        var shots: [FrozenScreen] = []
        for screen in NSScreen.screens {
            // SCDisplay.frame 是左上角原点（CG 坐标），NSScreen.frame 是左下角原点（Cocoa 坐标），
            // 副屏在主屏上下方时纵坐标对不上，所以先按 displayID 对应，frame 匹配只作兜底。
            let screenID = (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value
            let display = content.displays.first { $0.displayID == screenID }
                ?? content.displays.first { framesMatch($0.frame, screen.frame) }
                ?? content.displays
                    .filter { overlap($0.frame, screen.frame) > 0 }
                    .max { overlap($0.frame, screen.frame) < overlap($1.frame, screen.frame) }
            guard let display else { continue }
            do {
                let image = try await captureDisplay(display, screen: screen)
                shots.append(FrozenScreen(frame: screen.frame, image: image))
            } catch {
                throw screenCaptureDenied(error)
            }
        }
        if shots.isEmpty { throw TErr(L("找不到显示器")) }
        return shots
    }

    private static func captureDisplay(_ display: SCDisplay, screen: NSScreen) async throws -> CGImage {
        let filter = SCContentFilter(display: display, excludingWindows: [])
        let scale = screen.backingScaleFactor
        // Entire display, SDR. Setting a stream sourceRect here was coming back black.
        let width = max(1, Int((CGFloat(display.width) * scale).rounded()))
        let height = max(1, Int((CGFloat(display.height) * scale).rounded()))
        // `SCScreenshotConfiguration` 和 `captureScreenshot` 是 26 才有的；老系统退回
        // 14 起就提供的 `captureImage`，参数都靠 `SCStreamConfiguration` 给。
        if #available(macOS 26.0, *) {
            let config = SCScreenshotConfiguration()
            config.width = width
            config.height = height
            config.showsCursor = false
            config.dynamicRange = .sdr
            config.displayIntent = .local
            let output = try await SCScreenshotManager.captureScreenshot(contentFilter: filter, configuration: config)
            guard let image = output.sdrImage else { throw TErr(L("无法读取图片")) }
            return image
        } else {
            let config = SCStreamConfiguration()
            config.width = width
            config.height = height
            config.showsCursor = false
            return try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
        }
    }

    private static func screenCaptureDenied(_ error: Error) -> Error {
        if !CGPreflightScreenCaptureAccess() {
            Onboarding.showPermissions(pane: .screenCapture)
        }
        return TErr(String(format: L("OCR 截图翻译需要屏幕录制权限：系统设置 › 隐私与安全性 › 屏幕录制 › 允许 Korgino（%@）"), error.localizedDescription))
    }

    private static func overlap(_ a: CGRect, _ b: CGRect) -> CGFloat {
        let r = a.intersection(b)
        return r.width * r.height
    }

    nonisolated static func recognize(_ image: CGImage) async throws -> String {
        try await withCheckedThrowingContinuation { cont in
            let req = VNRecognizeTextRequest()
            req.recognitionLevel = .accurate
            req.recognitionLanguages = ["zh-Hans", "en-US"]
            req.usesLanguageCorrection = true
            let handler = VNImageRequestHandler(cgImage: image, options: [:])
            do {
                try handler.perform([req])
                let observations = req.results ?? []
                let lines = observations.compactMap { $0.topCandidates(1).first?.string }
                let text = lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
                if text.isEmpty {
                    cont.resume(throwing: TErr(L("未识别到文字")))
                } else {
                    cont.resume(returning: text)
                }
            } catch {
                cont.resume(throwing: error)
            }
        }
    }

    static func recognizeFile(path: String) async throws -> String {
        guard let img = NSImage(contentsOfFile: path),
              let cg = img.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            throw TErr(L("无法读取图片"))
        }
        return try await recognize(cg)
    }
}


struct FrozenScreen: Sendable {
    var frame: CGRect
    var image: CGImage
}

func framesMatch(_ a: CGRect, _ b: CGRect) -> Bool {
    abs(a.minX - b.minX) < 2 && abs(a.minY - b.minY) < 2
        && abs(a.width - b.width) < 2 && abs(a.height - b.height) < 2
}

@MainActor
enum RegionSelector {
    /// Retained while the overlay is up (continuation closure alone may release the window).
    private static var active: RegionOverlayController?

    static func selectImage() async throws -> CGImage {
        let shots = try await OCRCapture.freezeScreens()
        return try await withCheckedThrowingContinuation { cont in
            let ctl = RegionOverlayController()
            active = ctl
            ctl.begin(shots: shots) { result in
                active = nil
                switch result {
                case .success(let image): cont.resume(returning: image)
                case .failure(let e): cont.resume(throwing: e)
                }
            }
        }
    }
}

// MARK: - Interactive region overlay (visible + adjustable)

@MainActor
final class RegionOverlayController {
    private var windows: [RegionOverlayWindow] = []
    private var completion: ((Result<CGImage, Error>) -> Void)?
    /// Selection in global Cocoa coordinates (bottom-left origin, points).
    private(set) var selectionGlobal: CGRect?

    func begin(shots: [FrozenScreen], _ completion: @escaping (Result<CGImage, Error>) -> Void) {
        self.completion = completion
        // One overlay window per screen so dimming + hit-testing stay correct on multi-monitor.
        for screen in NSScreen.screens {
            let shot = shots.first { framesMatch($0.frame, screen.frame) }
            let w = RegionOverlayWindow(screenFrame: screen.frame, image: shot?.image, controller: self)
            w.orderFrontRegardless()
            windows.append(w)
        }
        // 先激活再置 key，否则第一下点击只会用来激活 App，工具条按钮不响应。
        NSApp.activate(ignoringOtherApps: true)
        windows.first?.makeKey()
    }

    func updateSelectionGlobal(_ rect: CGRect?) {
        selectionGlobal = rect
        // 跨屏拖选时每块屏都有一份选区切片，但工具条、尺寸标签、手柄只该出现一次，
        // 否则屏幕上会同时浮出好几条一模一样的工具条。挑重叠面积最大的那块当宿主。
        var host: RegionSelectView?
        var best: CGFloat = 0
        for w in windows {
            w.selectView.setSelectionFromGlobal(rect)
            guard let rect else { continue }
            let r = w.frame.intersection(rect)
            let area = max(0, r.width) * max(0, r.height)
            if area > best {
                best = area
                host = w.selectView
            }
        }
        for w in windows {
            w.selectView.showsChrome = (w.selectView === host)
        }
    }

    func confirm() {
        guard let r = selectionGlobal, r.width >= 4, r.height >= 4 else {
            cancel(message: L("选区太小"))
            return
        }
        guard let image = windows.lazy.compactMap({ $0.selectView.paintedCrop() }).first else {
            cancel(message: L("无法生成涂抹后的图片"))
            return
        }
        finish(.success(image))
    }

    func cancel(message: String = L("已取消")) {
        finish(.failure(TErr(message)))
    }

    private func finish(_ result: Result<CGImage, Error>) {
        for w in windows { w.orderOut(nil) }
        windows.removeAll()
        let cb = completion
        completion = nil
        cb?(result)
    }
}

@MainActor
final class RegionOverlayWindow: NSWindow {
    let selectView: RegionSelectView

    init(screenFrame: CGRect, image: CGImage?, controller: RegionOverlayController) {
        let view = RegionSelectView(frame: NSRect(origin: .zero, size: screenFrame.size))
        view.controller = controller
        view.loadFrozenImage(image)
        self.selectView = view
        super.init(
            contentRect: screenFrame,
            styleMask: .borderless,
            backing: .buffered,
            defer: false
        )
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        level = .screenSaver
        ignoresMouseEvents = false
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        acceptsMouseMovedEvents = true
        contentView = view
        // Ensure the view fills the window on Retina / scaled displays.
        view.autoresizingMask = [.width, .height]
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

@MainActor
final class RegionSelectView: NSView {
    weak var controller: RegionOverlayController?

    private enum Mode: Equatable {
        case idle
        case creating
        case moving
        case resizing(Handle)
        case painting
    }

    private enum Handle: CaseIterable, Equatable {
        case n, s, e, w, ne, nw, se, sw
    }

    /// Selection in this view's bounds (bottom-left origin).
    private var selection: CGRect?
    private var mode: Mode = .idle
    private var tool: SmearTool = .adjust
    private var dragStart: NSPoint = .zero
    private var selectionAtDragStart: CGRect = .zero
    private var lastPaint: CGPoint?
    /// 指针在视图里的位置，涂抹时用来画笔刷圈。
    private var brushPoint: CGPoint?
    private var sourceImage: CGImage?
    private var smear: SelectionSmear?
    private var toolbar: SelectionToolbar?
    private let handleSize: CGFloat = 9
    private let minSize: CGFloat = 8
    /// 只有承载选区的这块屏幕画工具条、尺寸标签和手柄，多屏时不重复。
    var showsChrome = true

    func loadFrozenImage(_ image: CGImage?) {
        sourceImage = image
        if let image { smear = SelectionSmear(image: image) }
        needsDisplay = true
    }

    /// Crop of this view's selection, including paint locked to those pixels.
    func paintedCrop() -> CGImage? {
        guard let sel = selection, sel.width >= 4, sel.height >= 4 else { return nil }
        guard bounds.insetBy(dx: -1, dy: -1).contains(sel) else { return nil }
        guard let source = sourceImage else { return nil }
        guard let base = SelectionSmear.crop(source, selection: sel, viewSize: bounds.size) else { return nil }
        guard let paint = smear?.image,
              let paintCrop = SelectionSmear.crop(paint, selection: sel, viewSize: bounds.size),
              let merged = SelectionSmear.composite(base: base, paint: paintCrop) else {
            return base
        }
        return merged
    }

    override var isFlipped: Bool { false }
    override var acceptsFirstResponder: Bool { true }

    /// App 刚被激活时，落在浮层上的第一下点击只用来激活窗口，不论点的是选区、手柄还是工具条。
    /// 认下这一下，拖选和点按都一次就生效。
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window != nil { ensureToolbar() }
        window?.makeFirstResponder(self)
        needsLayout = true
    }

    func setSelectionFromGlobal(_ global: CGRect?) {
        guard let global else {
            selection = nil
            needsDisplay = true
            needsLayout = true
            return
        }
        guard let w = window else { return }
        // Global → window/view coordinates.
        let originInWindow = w.convertPoint(fromScreen: NSPoint(x: global.minX, y: global.minY))
        let local = CGRect(x: originInWindow.x, y: originInWindow.y, width: global.width, height: global.height)
        let vis = local.intersection(bounds)
        selection = (vis.width >= 1 && vis.height >= 1) ? vis : nil
        needsDisplay = true
        needsLayout = true
    }

    private func publishSelection() {
        guard let selection, let w = window else {
            controller?.updateSelectionGlobal(nil)
            return
        }
        let bl = w.convertPoint(toScreen: NSPoint(x: selection.minX, y: selection.minY))
        let tr = w.convertPoint(toScreen: NSPoint(x: selection.maxX, y: selection.maxY))
        let g = CGRect(
            x: min(bl.x, tr.x),
            y: min(bl.y, tr.y),
            width: abs(tr.x - bl.x),
            height: abs(tr.y - bl.y)
        )
        controller?.updateSelectionGlobal(g)
    }

    // MARK: Drawing

    override func layout() {
        super.layout()
        placeToolbar()
    }

    override func draw(_ dirtyRect: NSRect) {
        drawFrozen(sourceImage)
        drawFrozen(smear?.image)

        // Dim whole view with a clear cutout for the selection (highly visible).
        let dim = NSBezierPath(rect: bounds)
        if let sel = selection, sel.width > 1, sel.height > 1 {
            dim.append(NSBezierPath(rect: sel))
            dim.windingRule = .evenOdd
        }
        NSColor.black.withAlphaComponent(0.55).setFill()
        dim.fill()

        // Hint banner
        let hint = hintText()
        let attrs: [NSAttributedString.Key: Any] = [
            .font: Theme.TypeScale.nsBodyMedium,
            .foregroundColor: NSColor.white,
        ]
        let size = hint.size(withAttributes: attrs)
        let pad: CGFloat = 12
        let banner = CGRect(
            x: bounds.midX - size.width / 2 - pad,
            y: bounds.maxY - size.height - 30,
            width: size.width + pad * 2,
            height: size.height + 10
        )
        NSColor.black.withAlphaComponent(0.62).setFill()
        NSBezierPath(roundedRect: banner, xRadius: 10, yRadius: 10).fill()
        NSColor.white.withAlphaComponent(0.12).setStroke()
        let bannerEdge = NSBezierPath(roundedRect: banner.insetBy(dx: 0.5, dy: 0.5), xRadius: 10, yRadius: 10)
        bannerEdge.lineWidth = 1
        bannerEdge.stroke()
        hint.draw(at: NSPoint(x: banner.minX + pad, y: banner.minY + 5), withAttributes: attrs)

        guard let sel = selection, sel.width > 1, sel.height > 1 else { return }

        let accent = NSColor.controlAccentColor

        // 选中区域里再亮一点，边界更清楚；外侧压一层柔和暗角。
        if sel.width > 4, sel.height > 4 {
            NSColor.white.withAlphaComponent(0.04).setFill()
            NSBezierPath(rect: sel).fill()
        }

        // 现代取景框的画法：不再画整圈边框，改成四角括号 + 四边胶囊滑块。
        // 整圈线会把画面压得很重，括号只交代四角，中间留给内容。
        let cornerLen: CGFloat = 18
        let cornerInset: CGFloat = 1
        var corners: [NSBezierPath] = []
        let x0 = sel.minX + cornerInset, x1 = sel.maxX - cornerInset
        let y0 = sel.minY + cornerInset, y1 = sel.maxY - cornerInset
        for (cx, cy, sx, sy) in [
            (x0, y1, 1.0, -1.0), (x1, y1, -1.0, -1.0),
            (x0, y0, 1.0, 1.0), (x1, y0, -1.0, 1.0),
        ] as [(CGFloat, CGFloat, CGFloat, CGFloat)] {
            let path = NSBezierPath()
            path.move(to: NSPoint(x: cx, y: cy + sy * cornerLen))
            path.line(to: NSPoint(x: cx, y: cy))
            path.line(to: NSPoint(x: cx + sx * cornerLen, y: cy))
            path.lineCapStyle = .round
            path.lineJoinStyle = .round
            corners.append(path)
        }
        // 深色垫底让括号在亮画面上也立得住，亮色线才是本体。
        NSColor.black.withAlphaComponent(0.4).setStroke()
        for path in corners { path.lineWidth = 4.5; path.stroke() }
        NSColor.white.setStroke()
        for path in corners { path.lineWidth = 2.5; path.stroke() }

        // 四条边中点的胶囊滑块，比圆点更现代，也不会被误认成「标记」。
        let gripLong: CGFloat = 22
        let gripThick: CGFloat = 4
        let grips: [CGRect] = [
            CGRect(x: sel.midX - gripLong / 2, y: sel.maxY - gripThick / 2, width: gripLong, height: gripThick),
            CGRect(x: sel.midX - gripLong / 2, y: sel.minY - gripThick / 2, width: gripLong, height: gripThick),
            CGRect(x: sel.minX - gripThick / 2, y: sel.midY - gripLong / 2, width: gripThick, height: gripLong),
            CGRect(x: sel.maxX - gripThick / 2, y: sel.midY - gripLong / 2, width: gripThick, height: gripLong),
        ]
        if tool == .adjust {
            for r in grips {
                NSColor.black.withAlphaComponent(0.4).setFill()
                NSBezierPath(roundedRect: r.insetBy(dx: -1, dy: -1), xRadius: 3, yRadius: 3).fill()
                NSColor.white.setFill()
                NSBezierPath(roundedRect: r, xRadius: 2, yRadius: 2).fill()
            }
        }

        guard showsChrome else { return }

        // Size label：玻璃胶囊，和工具条同一个材质语言。
        let dims = String(
            format: "%@ × %@",
            String(describing: Int(sel.width.rounded())),
            String(describing: Int(sel.height.rounded()))
        )
        let hintText = String(format: L("  ·  %@"), L("回车识别"))
        let labAttrs: [NSAttributedString.Key: Any] = [
            .font: Theme.TypeScale.nsCaption,
            .foregroundColor: NSColor.white,
        ]
        let hintAttrs: [NSAttributedString.Key: Any] = [
            .font: Theme.TypeScale.nsMicro,
            .foregroundColor: NSColor.white.withAlphaComponent(0.6),
        ]
        let dimsW = dims.size(withAttributes: labAttrs).width
        let hintW = hintText.size(withAttributes: hintAttrs).width
        let labH: CGFloat = 24
        var labRect = CGRect(x: sel.minX, y: sel.maxY + 9, width: dimsW + hintW + 20, height: labH)
        if sizeLabelGoesBelow(sel) {
            labRect.origin.y = sel.minY - labH - 9
        }
        labRect.origin.x = min(max(8, labRect.origin.x), bounds.maxX - labRect.width - 8)
        NSColor.black.withAlphaComponent(0.62).setFill()
        NSBezierPath(roundedRect: labRect, xRadius: labH / 2, yRadius: labH / 2).fill()
        NSColor.white.withAlphaComponent(0.14).setStroke()
        let labEdge = NSBezierPath(
            roundedRect: labRect.insetBy(dx: 0.5, dy: 0.5),
            xRadius: (labH - 1) / 2, yRadius: (labH - 1) / 2
        )
        labEdge.lineWidth = 1
        labEdge.stroke()
        let textY = labRect.midY - 6.5
        dims.draw(at: NSPoint(x: labRect.minX + 10, y: textY), withAttributes: labAttrs)
        hintText.draw(at: NSPoint(x: labRect.minX + 10 + dimsW, y: textY + 0.5), withAttributes: hintAttrs)

        // 涂抹时在指针处画一个笔刷圈，看得见自己涂多粗。
        if tool != .adjust, let p = brushPoint, sel.contains(p) {
            let radius = smear?.brushRadius ?? 8
            NSColor.white.withAlphaComponent(0.9).setStroke()
            let ring = NSBezierPath(ovalIn: CGRect(x: p.x - radius, y: p.y - radius, width: radius * 2, height: radius * 2))
            ring.lineWidth = 1
            ring.stroke()
            NSColor.black.withAlphaComponent(0.5).setStroke()
            let inner = NSBezierPath(ovalIn: CGRect(x: p.x - radius + 1, y: p.y - radius + 1, width: radius * 2 - 2, height: radius * 2 - 2))
            inner.lineWidth = 1
            inner.stroke()
        }
    }

    private func hintText() -> String {
        if selection == nil {
            return L("拖拽选择截图区域  ·  Esc 取消")
        }
        switch tool {
        case .paint:
            return L("在选区内涂掉隐私  ·  回车识别  ·  Esc 取消")
        case .erase:
            return L("在选区内擦掉涂抹  ·  回车识别  ·  Esc 取消")
        case .adjust:
            return L("拖动选区或手柄调整  ·  可涂抹  ·  回车识别  ·  Esc 取消")
        }
    }

    // MARK: Handles geometry

    private func handleRect(_ h: Handle, in sel: CGRect) -> CGRect {
        let s = handleSize
        let midX = sel.midX - s / 2
        let midY = sel.midY - s / 2
        switch h {
        case .n:  return CGRect(x: midX, y: sel.maxY - s / 2, width: s, height: s)
        case .s:  return CGRect(x: midX, y: sel.minY - s / 2, width: s, height: s)
        case .e:  return CGRect(x: sel.maxX - s / 2, y: midY, width: s, height: s)
        case .w:  return CGRect(x: sel.minX - s / 2, y: midY, width: s, height: s)
        case .ne: return CGRect(x: sel.maxX - s / 2, y: sel.maxY - s / 2, width: s, height: s)
        case .nw: return CGRect(x: sel.minX - s / 2, y: sel.maxY - s / 2, width: s, height: s)
        case .se: return CGRect(x: sel.maxX - s / 2, y: sel.minY - s / 2, width: s, height: s)
        case .sw: return CGRect(x: sel.minX - s / 2, y: sel.minY - s / 2, width: s, height: s)
        }
    }

    private func hitHandle(at p: NSPoint) -> Handle? {
        guard let sel = selection else { return nil }
        // Inflate hit area
        for h in Handle.allCases {
            if handleRect(h, in: sel).insetBy(dx: -4, dy: -4).contains(p) { return h }
        }
        return nil
    }

    private func cursor(for h: Handle) -> NSCursor {
        switch h {
        case .n, .s: return .resizeUpDown
        case .e, .w: return .resizeLeftRight
        case .ne: return NSCursor.frameResize(position: .topRight, directions: .all)
        case .nw: return NSCursor.frameResize(position: .topLeft, directions: .all)
        case .se: return NSCursor.frameResize(position: .bottomRight, directions: .all)
        case .sw: return NSCursor.frameResize(position: .bottomLeft, directions: .all)
        }
    }

    // MARK: Mouse

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        let p = convert(event.locationInWindow, from: nil)
        dragStart = p
        if let bar = toolbar, !bar.isHidden, bar.frame.contains(p) { return }
        // 选了涂抹/橡皮时，选区边缘那一圈也算涂抹，不再让手柄抢点击。
        // 要拉伸就切回「调整」(V)，提示条里写着。
        if let sel = selection, sel.contains(p), tool != .adjust, smear != nil {
            mode = .painting
            smear?.beginStroke()
            lastPaint = nil
            paint(at: p)
            return
        }
        if let h = hitHandle(at: p), let sel = selection {
            mode = .resizing(h)
            selectionAtDragStart = sel
            return
        }
        if let sel = selection, sel.contains(p) {
            mode = .moving
            selectionAtDragStart = sel
            return
        }
        // Start a new selection
        mode = .creating
        selection = CGRect(origin: p, size: .zero)
        selectionAtDragStart = selection!
        needsDisplay = true
        needsLayout = true
        publishSelection()
    }

    override func mouseDragged(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        switch mode {
        case .painting:
            paint(at: p)
            return
        case .creating:
            let s = dragStart
            selection = CGRect(
                x: min(s.x, p.x),
                y: min(s.y, p.y),
                width: abs(p.x - s.x),
                height: abs(p.y - s.y)
            ).intersection(bounds)
        case .moving:
            var r = selectionAtDragStart
            r.origin.x += p.x - dragStart.x
            r.origin.y += p.y - dragStart.y
            // Clamp inside view
            r.origin.x = min(max(0, r.origin.x), bounds.width - r.width)
            r.origin.y = min(max(0, r.origin.y), bounds.height - r.height)
            selection = r
        case .resizing(let h):
            selection = resized(selectionAtDragStart, handle: h, to: p)
        case .idle:
            break
        }
        needsDisplay = true
        needsLayout = true
        publishSelection()
    }

    override func mouseUp(with event: NSEvent) {
        if case .painting = mode {
            mode = .idle
            lastPaint = nil
            needsDisplay = true
            needsLayout = true
            return
        }
        if case .creating = mode {
            if let sel = selection, (sel.width < minSize || sel.height < minSize) {
                selection = nil
                publishSelection()
            }
        }
        mode = .idle
        needsDisplay = true
        needsLayout = true
        publishSelection()
        NSCursor.arrow.set()
    }

    override func mouseMoved(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        if let bar = toolbar, !bar.isHidden, bar.frame.contains(p) {
            setBrushPoint(nil)
            NSCursor.arrow.set()
            return
        }
        setBrushPoint(tool == .adjust ? nil : p)
        // 涂抹时手柄不画也不响应，光标自然也不该是拉伸箭头。
        if tool == .adjust, let h = hitHandle(at: p) {
            cursor(for: h).set()
        } else if let sel = selection, sel.contains(p) {
            if tool == .adjust {
                NSCursor.openHand.set()
            } else {
                NSCursor.crosshair.set()
            }
        } else {
            NSCursor.crosshair.set()
        }
    }

    private func setBrushPoint(_ p: CGPoint?) {
        guard brushPoint != p else { return }
        brushPoint = p
        needsDisplay = true
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        for a in trackingAreas { removeTrackingArea(a) }
        addTrackingArea(NSTrackingArea(
            rect: bounds,
            options: [.activeAlways, .mouseMoved, .mouseEnteredAndExited, .inVisibleRect],
            owner: self,
            userInfo: nil
        ))
    }

    private func resized(_ original: CGRect, handle: Handle, to p: NSPoint) -> CGRect {
        var left = original.minX
        var right = original.maxX
        var bottom = original.minY
        var top = original.maxY
        let clamped = NSPoint(
            x: min(max(0, p.x), bounds.width),
            y: min(max(0, p.y), bounds.height)
        )
        switch handle {
        case .n:  top = max(bottom + minSize, clamped.y)
        case .s:  bottom = min(top - minSize, clamped.y)
        case .e:  right = max(left + minSize, clamped.x)
        case .w:  left = min(right - minSize, clamped.x)
        case .ne: top = max(bottom + minSize, clamped.y); right = max(left + minSize, clamped.x)
        case .nw: top = max(bottom + minSize, clamped.y); left = min(right - minSize, clamped.x)
        case .se: bottom = min(top - minSize, clamped.y); right = max(left + minSize, clamped.x)
        case .sw: bottom = min(top - minSize, clamped.y); left = min(right - minSize, clamped.x)
        }
        return CGRect(x: left, y: bottom, width: right - left, height: top - bottom)
    }

    // MARK: Keyboard

    override func keyDown(with event: NSEvent) {
        // Return / keypad Enter
        if event.keyCode == 36 || event.keyCode == 76 {
            controller?.confirm()
            return
        }
        // Esc
        if event.keyCode == 53 {
            controller?.cancel()
            return
        }
        // ⌘Z 撤销涂抹
        let plain = event.charactersIgnoringModifiers?.lowercased()
        let command = event.modifierFlags.contains(.command)
        if command, plain == "z" {
            smear?.undo()
            toolbar?.reflect(tool: tool, canUndo: smear?.canUndo ?? false, paintEnabled: smear != nil)
            needsDisplay = true
            return
        }
        // P 涂抹 · E 橡皮 · V 调整，都不带修饰键
        if !command {
            switch plain {
            case "p": toggleTool(.paint); return
            case "e": toggleTool(.erase); return
            case "v": toggleTool(.adjust); return
            default: break
            }
        }
        super.keyDown(with: event)
    }

    override func scrollWheel(with event: NSEvent) {
        guard let smear, tool != .adjust, event.scrollingDeltaY != 0 else {
            super.scrollWheel(with: event)
            return
        }
        let step: CGFloat = event.scrollingDeltaY > 0 ? 1.5 : -1.5
        smear.brushRadius = min(
            max(SelectionSmear.minBrushRadius, smear.brushRadius + step),
            SelectionSmear.maxBrushRadius
        )
        needsDisplay = true
    }

    override func mouseExited(with event: NSEvent) {
        if brushPoint != nil {
            brushPoint = nil
            needsDisplay = true
        }
        super.mouseExited(with: event)
    }

    override func cancelOperation(_ sender: Any?) {
        controller?.cancel()
    }

    private func drawFrozen(_ image: CGImage?) {
        guard let image else { return }
        let size = NSSize(width: image.width, height: image.height)
        NSImage(cgImage: image, size: size).draw(
            in: bounds,
            from: NSRect(origin: .zero, size: size),
            operation: .sourceOver,
            fraction: 1,
            respectFlipped: false,
            hints: [.interpolation: NSImageInterpolation.high]
        )
    }

    private func paint(at p: NSPoint) {
        guard let sel = selection, let smear else { return }
        lastPaint = smear.stamp(from: lastPaint, to: p, viewSize: bounds.size, selection: sel, erasing: tool == .erase)
        toolbar?.reflect(tool: tool, canUndo: smear.canUndo, paintEnabled: true)
        needsDisplay = true
    }

    private func toggleTool(_ next: SmearTool) {
        tool = (tool == next) ? .adjust : next
        toolbar?.reflect(tool: tool, canUndo: smear?.canUndo ?? false, paintEnabled: smear != nil)
        window?.makeFirstResponder(self)
        needsDisplay = true
    }

    private func ensureToolbar() {
        guard toolbar == nil else { return }
        let bar = SelectionToolbar(frame: .zero)
        bar.onPaint = { [weak self] in self?.toggleTool(.paint) }
        bar.onErase = { [weak self] in self?.toggleTool(.erase) }
        bar.onUndo = { [weak self] in
            self?.smear?.undo()
            self?.toolbar?.reflect(tool: self?.tool ?? .adjust, canUndo: self?.smear?.canUndo ?? false, paintEnabled: self?.smear != nil)
            self?.needsDisplay = true
            self?.window?.makeFirstResponder(self)
        }
        bar.onClear = { [weak self] in
            self?.smear?.clear()
            self?.toolbar?.reflect(tool: self?.tool ?? .adjust, canUndo: self?.smear?.canUndo ?? false, paintEnabled: self?.smear != nil)
            self?.needsDisplay = true
            self?.window?.makeFirstResponder(self)
        }
        bar.onRecognize = { [weak self] in self?.controller?.confirm() }
        bar.onCancel = { [weak self] in self?.controller?.cancel() }
        addSubview(bar)
        toolbar = bar
    }

    private func placeToolbar() {
        guard let bar = toolbar else { return }
        let resizing: Bool
        if case .resizing = mode { resizing = true } else { resizing = false }
        let show = showsChrome
            && selection != nil
            && (selection?.width ?? 0) >= minSize
            && (selection?.height ?? 0) >= minSize
            && mode != .creating
            && mode != .moving
            && !resizing
        bar.isHidden = !show
        guard show, let sel = selection else { return }
        bar.reflect(tool: tool, canUndo: smear?.canUndo ?? false, paintEnabled: smear != nil)
        let size = bar.frame.size
        bar.frame = CGRect(origin: toolbarOrigin(selection: sel, size: size), size: size)
    }

    /// 尺寸标签的高度，含上下留白。画标签和摆工具条都用它，两边不会对不上。
    private let sizeLabelBand: CGFloat = 24

    /// 选区顶上放不下标签时，标签翻到选区下面。
    private func sizeLabelGoesBelow(_ sel: CGRect) -> Bool {
        sel.maxY + 8 + sizeLabelBand > bounds.maxY - 8
    }

    private func toolbarOrigin(selection sel: CGRect, size: CGSize) -> CGPoint {
        let margin: CGFloat = 8
        var x = sel.maxX - size.width
        x = min(max(margin, x), max(margin, bounds.width - size.width - margin))
        let belowY = sel.minY - size.height - margin
        let aboveY = sel.maxY + margin + sizeLabelBand
        // 和尺寸标签分开放，先选没有标签的那一边。
        if sizeLabelGoesBelow(sel) {
            if aboveY + size.height <= bounds.height - margin { return CGPoint(x: x, y: aboveY) }
            if belowY - sizeLabelBand >= margin { return CGPoint(x: x, y: belowY - sizeLabelBand) }
        } else {
            if belowY >= margin { return CGPoint(x: x, y: belowY) }
            if aboveY + size.height <= bounds.height - margin { return CGPoint(x: x, y: aboveY) }
        }
        // 两边都挤：挪进选区里，贴着底边。
        return CGPoint(x: x, y: max(margin, sel.minY + margin))
    }
}

