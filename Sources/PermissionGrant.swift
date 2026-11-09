import AppKit
import ApplicationServices
import CoreGraphics
import QuartzCore

/// Privacy panes that the user finishes by dropping this app into the list and turning it on.
enum PrivacyPane {
    case accessibility
    case screenCapture
    case inputMonitoring

    var anchor: String {
        switch self {
        case .accessibility: return "Privacy_Accessibility"
        case .screenCapture: return "Privacy_ScreenCapture"
        case .inputMonitoring: return "Privacy_ListenEvent"
        }
    }

    /// Name of the pane in System Settings, used in the banner title.
    var paneTitle: String {
        switch self {
        case .accessibility: return L("辅助功能")
        case .screenCapture: return L("录屏与系统录音")
        case .inputMonitoring: return L("输入监视")
        }
    }

    var isGranted: Bool {
        switch self {
        case .accessibility: return AXIsProcessTrusted()
        case .screenCapture: return CGPreflightScreenCaptureAccess()
        case .inputMonitoring: return CGPreflightListenEventAccess()
        }
    }
}

/// Banner pinned to the bottom of System Settings while a privacy toggle is still off.
/// The icon is a drag source for this app bundle, which the privacy list accepts as a drop.
@MainActor
final class PermissionGrantController: NSObject {
    static let shared = PermissionGrantController()

    private var panel: NSPanel?
    private var banner: GrantBannerView?
    private var pane: PrivacyPane?
    private var timer: Timer?
    private var displayLink: CADisplayLink?
    private var trackedWindowID: CGWindowID = 0
    /// Distance from the System Settings window's left edge to the permission list.
    /// Measured on macOS 26: sidebar ends at the splitter, about 223pt in.
    private var listPaneLeading: CGFloat = 223
    private var placedWidth: CGFloat = 0
    private var listed = false
    private var dropped = false
    private var sawSettings = false
    private var axNodesChecked = 0
    private var lastListCheck = Date.distantPast

    private var appName: String {
        let bundle = Bundle.main
        let display = bundle.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String
        let name = bundle.object(forInfoDictionaryKey: "CFBundleName") as? String
        return display ?? name ?? "Korgino"
    }

    /// Open the privacy pane. Show the banner only while access is still off.
    func prompt(_ pane: PrivacyPane) {
        if pane.isGranted {
            openSettings(pane)
            return
        }
        self.pane = pane
        listed = false
        dropped = false
        sawSettings = false
        showBanner(for: pane)
        openSettings(pane)
        startTracking()
    }

    func openSettings(_ pane: PrivacyPane) {
        let modern = "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?\(pane.anchor)"
        let legacy = "x-apple.systempreferences:com.apple.preference.security?\(pane.anchor)"
        for raw in [modern, legacy] {
            guard let url = URL(string: raw) else { continue }
            if NSWorkspace.shared.open(url) {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                    NSRunningApplication.runningApplications(
                        withBundleIdentifier: "com.apple.systempreferences"
                    ).first?.activate(options: [])
                }
                return
            }
        }
    }

    func dismiss() {
        timer?.invalidate()
        timer = nil
        displayLink?.invalidate()
        displayLink = nil
        trackedWindowID = 0
        panel?.orderOut(nil)
        panel = nil
        banner = nil
        pane = nil
    }

    func noteDropAccepted() {
        dropped = true
        refreshCopy()
    }

    @objc private func closeFromButton() {
        dismiss()
    }

    private func showBanner(for pane: PrivacyPane) {
        let view = banner ?? GrantBannerView(target: self, action: #selector(closeFromButton))
        banner = view
        refreshCopy()

        let panel = self.panel ?? makePanel()
        self.panel = panel
        if panel.contentView !== view {
            panel.contentView = view
        }
        place(view, on: panel)
        panel.alphaValue = 0
        panel.orderOut(nil)
    }

    private func makePanel() -> NSPanel {
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 480, height: 76),
            styleMask: [.borderless, .nonactivatingPanel, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.collectionBehavior = [.fullScreenAuxiliary, .ignoresCycle]
        panel.hidesOnDeactivate = false
        panel.isMovable = false
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        panel.isExcludedFromWindowsMenu = true
        panel.becomesKeyOnlyIfNeeded = true
        panel.worksWhenModal = true
        panel.animationBehavior = .none
        return panel
    }

    private func startTracking() {
        timer?.invalidate()
        displayLink?.invalidate()
        placedWidth = 0
        let timer = Timer(timeInterval: 0.4, repeats: true) { _ in
            MainActor.assumeIsolated {
                PermissionGrantController.shared.slowTick()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer

        let screen = NSScreen.main ?? NSScreen.screens.first
        guard let link = screen?.displayLink(target: self, selector: #selector(onDisplayLink(_:))) else { return }
        link.preferredFrameRateRange = CAFrameRateRange(minimum: 60, maximum: 120, preferred: 60)
        link.add(to: .main, forMode: .common)
        displayLink = link
    }

    @objc private func onDisplayLink(_ link: CADisplayLink) {
        followWindow()
    }

    /// Position only. Runs every frame so the banner stays glued to the window while it is dragged.
    private func followWindow() {
        guard let panel, let banner, let settings = settingsApp() else { return }
        guard let window = settingsWindowFrame(pid: settings.processIdentifier) else { return }
        let margin: CGFloat = 14
        let width = max(280, window.width - listPaneLeading - margin * 2)
        let origin = NSPoint(x: window.minX + listPaneLeading + margin, y: window.minY + margin)
        if abs(width - placedWidth) > 0.5 {
            let height = banner.preferredHeight(forWidth: width)
            placedWidth = width
            let frame = NSRect(x: origin.x, y: origin.y, width: width, height: height)
            panel.setFrame(frame, display: false, animate: false)
            banner.frame = NSRect(origin: .zero, size: frame.size)
            banner.needsLayout = true
        } else if abs(panel.frame.origin.x - origin.x) > 0.25 || abs(panel.frame.origin.y - origin.y) > 0.25 {
            panel.setFrameOrigin(origin)
        }
    }

    /// Grant checks and visibility. Kept off the frame callback so dragging stays smooth.
    private func slowTick() {
        guard let pane, let panel else { return }
        if pane.isGranted {
            dismiss()
            return
        }
        guard let settings = settingsApp() else {
            if sawSettings { dismiss() }
            return
        }
        sawSettings = true
        guard let window = settingsWindowFrame(pid: settings.processIdentifier) else {
            panel.orderOut(nil)
            return
        }
        if AXIsProcessTrusted(), let leading = axListPaneLeading(pid: settings.processIdentifier, windowFrame: window) {
            if abs(leading - listPaneLeading) > 1 {
                listPaneLeading = leading
                placedWidth = 0
            }
        }
        if settings.isActive {
            if panel.alphaValue < 1 || !panel.isVisible {
                panel.alphaValue = 1
                panel.orderFrontRegardless()
            }
        } else if panel.isVisible {
            panel.orderOut(nil)
        }
        if AXIsProcessTrusted(), !listed, Date().timeIntervalSince(lastListCheck) > 1 {
            lastListCheck = Date()
            listed = settingsListContainsApp(pid: settings.processIdentifier, name: appName)
            if listed {
                refreshCopy()
                placedWidth = 0
            }
        }
    }

    private func refreshCopy() {
        guard let pane, let banner else { return }
        let app = appName
        banner.title = String(format: L("在「%1$@」中允许 %2$@"), pane.paneTitle, app)
        if listed || dropped {
            banner.subtitle = String(format: L("打开 %1$@ 的开关即可完成。"), app)
        } else {
            banner.subtitle = String(format: L("把 %1$@ 图标拖进列表，然后打开开关。"), app)
        }
        banner.needsLayout = true
        placedWidth = 0
    }

    private func place(_ banner: GrantBannerView, on panel: NSPanel) {
        let width: CGFloat = 420
        let height = banner.preferredHeight(forWidth: width)
        let screen = NSScreen.main?.visibleFrame ?? NSScreen.screens.first?.visibleFrame
        guard let screen else { return }
        let frame = CGRect(
            x: screen.midX - width / 2,
            y: screen.minY + 28,
            width: width,
            height: height
        )
        panel.setFrame(frame, display: false, animate: false)
        banner.frame = NSRect(origin: .zero, size: frame.size)
        banner.needsLayout = true
        placedWidth = width
    }

    private func settingsApp() -> NSRunningApplication? {
        NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.systempreferences").first
    }

    /// Largest on-screen System Settings window, in AppKit coordinates.
    private func settingsWindowFrame(pid: pid_t) -> CGRect? {
        if trackedWindowID != 0, let frame = frameOfTrackedWindow() {
            return frame
        }
        return captureTrackedWindow(pid: pid)
    }

    private func captureTrackedWindow(pid: pid_t) -> CGRect? {
        guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else {
            return nil
        }
        var bestID: CGWindowID = 0
        var best: CGRect?
        var bestArea: CGFloat = 0
        for info in list {
            guard intValue(info[kCGWindowOwnerPID as String]) == Int(pid) else { continue }
            guard (intValue(info[kCGWindowLayer as String]) ?? 0) == 0 else { continue }
            guard let frame = appKitFrame(info) else { continue }
            guard frame.width > 240, frame.height > 200 else { continue }
            let area = frame.width * frame.height
            if area > bestArea, let id = intValue(info[kCGWindowNumber as String]) {
                bestArea = area
                best = frame
                bestID = CGWindowID(id)
            }
        }
        if bestID != 0 { trackedWindowID = bestID }
        return best
    }

    private func frameOfTrackedWindow() -> CGRect? {
        guard let list = CGWindowListCopyWindowInfo(.optionIncludingWindow, trackedWindowID) as? [[String: Any]],
              let info = list.first,
              let frame = appKitFrame(info),
              frame.width > 200, frame.height > 200 else {
            trackedWindowID = 0
            return nil
        }
        return frame
    }

    private func appKitFrame(_ info: [String: Any]) -> CGRect? {
        guard let dict = info[kCGWindowBounds as String] as? NSDictionary else { return nil }
        var quartz = CGRect.zero
        guard CGRectMakeWithDictionaryRepresentation(dict, &quartz) else { return nil }
        let primaryHeight = NSScreen.screens.first { $0.frame.origin == .zero }?.frame.height
            ?? NSScreen.main?.frame.height
            ?? 0
        return CGRect(
            x: quartz.origin.x,
            y: primaryHeight - quartz.origin.y - quartz.height,
            width: quartz.width,
            height: quartz.height
        )
    }

    /// How far the permission list starts from the left edge of the settings window.
    private func axListPaneLeading(pid: pid_t, windowFrame: CGRect) -> CGFloat? {
        let app = AXUIElementCreateApplication(pid)
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(app, kAXWindowsAttribute as CFString, &value) == .success,
              let windows = value as? [AXUIElement] else { return nil }
        for window in windows {
            guard let frame = axElementFrame(window), abs(frame.width - windowFrame.width) < 30 else { continue }
            if let leading = splitterLeading(in: window, windowFrame: frame, depth: 0) {
                return leading
            }
        }
        return nil
    }

    private func splitterLeading(in element: AXUIElement, windowFrame: CGRect, depth: Int) -> CGFloat? {
        if depth > 7 { return nil }
        var role: CFTypeRef?
        if AXUIElementCopyAttributeValue(element, kAXRoleAttribute as CFString, &role) == .success,
           (role as? String) == "AXSplitter",
           let frame = axElementFrame(element) {
            let leading = frame.minX - windowFrame.minX
            if leading > 120, leading < windowFrame.width * 0.55 {
                return leading
            }
        }
        var children: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &children) == .success,
              let kids = children as? [AXUIElement] else { return nil }
        for kid in kids {
            if let found = splitterLeading(in: kid, windowFrame: windowFrame, depth: depth + 1) {
                return found
            }
        }
        return nil
    }


    private func axElementFrame(_ element: AXUIElement) -> CGRect? {
        var posRef: CFTypeRef?
        var sizeRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXPositionAttribute as CFString, &posRef) == .success,
              AXUIElementCopyAttributeValue(element, kAXSizeAttribute as CFString, &sizeRef) == .success,
              let posRef, let sizeRef else { return nil }
        guard let point = axPoint(posRef), let size = axSize(sizeRef) else { return nil }
        return CGRect(origin: point, size: size)
    }

    private func axPoint(_ value: CFTypeRef) -> CGPoint? {
        guard CFGetTypeID(value) == AXValueGetTypeID() else { return nil }
        var point = CGPoint.zero
        guard AXValueGetValue(value as! AXValue, .cgPoint, &point) else { return nil }
        return point
    }

    private func axSize(_ value: CFTypeRef) -> CGSize? {
        guard CFGetTypeID(value) == AXValueGetTypeID() else { return nil }
        var size = CGSize.zero
        guard AXValueGetValue(value as! AXValue, .cgSize, &size) else { return nil }
        return size
    }

    private func intValue(_ raw: Any?) -> Int? {
        switch raw {
        case let number as NSNumber: return number.intValue
        case let value as Int: return value
        default: return nil
        }
    }

    /// Whether the System Settings accessibility tree already shows this app.
    private func settingsListContainsApp(pid: pid_t, name: String) -> Bool {
        let app = AXUIElementCreateApplication(pid)
        axNodesChecked = 0
        return axTreeContains(app, needle: name, depth: 0)
    }

    private func axTreeContains(_ element: AXUIElement, needle: String, depth: Int) -> Bool {
        if depth > 10 || axNodesChecked > 500 { return false }
        axNodesChecked += 1
        for attr in [kAXTitleAttribute, kAXValueAttribute, kAXDescriptionAttribute] {
            var value: CFTypeRef?
            if AXUIElementCopyAttributeValue(element, attr as CFString, &value) == .success,
               let text = value as? String,
               text.localizedCaseInsensitiveContains(needle) {
                return true
            }
        }
        var children: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &children) == .success,
              let kids = children as? [AXUIElement] else { return false }
        for kid in kids where axTreeContains(kid, needle: needle, depth: depth + 1) {
            return true
        }
        return false
    }
}

// MARK: - Banner view

@MainActor
final class GrantBannerView: NSView {
    var title: String = "" {
        didSet { titleField.stringValue = title }
    }
    var subtitle: String = "" {
        didSet { subtitleField.stringValue = subtitle }
    }

    private let icon = AppIconDragView()
    private let titleField = NSTextField(labelWithString: "")
    private let subtitleField = NSTextField(labelWithString: "")
    private let closeButton: NSButton

    init(target: AnyObject, action: Selector) {
        let button = FirstMouseButton()
        closeButton = button
        super.init(frame: NSRect(x: 0, y: 0, width: 480, height: 76))
        wantsLayer = true
        layer?.cornerRadius = 16
        layer?.backgroundColor = NSColor(srgbRed: 0.11, green: 0.11, blue: 0.12, alpha: 0.97).cgColor
        layer?.borderWidth = 1
        layer?.borderColor = NSColor.white.withAlphaComponent(0.10).cgColor

        icon.toolTip = L("把应用图标拖进列表")
        icon.setAccessibilityLabel(L("应用图标，拖进列表"))
        addSubview(icon)

        configure(titleField, size: 13, weight: .semibold, alpha: 1)
        configure(subtitleField, size: 11, weight: .regular, alpha: 0.62)
        addSubview(titleField)
        addSubview(subtitleField)

        closeButton.isBordered = false
        closeButton.bezelStyle = .inline
        closeButton.image = NSImage(systemSymbolName: "xmark", accessibilityDescription: L("关闭授权提示"))
        closeButton.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 11, weight: .semibold)
        closeButton.contentTintColor = NSColor.white.withAlphaComponent(0.72)
        closeButton.target = target
        closeButton.action = action
        closeButton.toolTip = L("关闭授权提示")
        addSubview(closeButton)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    func preferredHeight(forWidth width: CGFloat) -> CGFloat {
        let textWidth = max(80, width - 66 - 44)
        let titleHeight = measuredHeight(titleField, width: textWidth)
        let subtitleHeight = measuredHeight(subtitleField, width: textWidth)
        return max(72, titleHeight + subtitleHeight + 26)
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func layout() {
        super.layout()
        let height = bounds.height
        icon.frame = NSRect(x: 14, y: (height - 40) / 2, width: 40, height: 40)
        closeButton.frame = NSRect(x: bounds.width - 16 - 22, y: (height - 22) / 2, width: 22, height: 22)
        let textX: CGFloat = 66
        let textWidth = max(40, closeButton.frame.minX - 8 - textX)
        let titleHeight = measuredHeight(titleField, width: textWidth)
        let subtitleHeight = measuredHeight(subtitleField, width: textWidth)
        let block = titleHeight + 2 + subtitleHeight
        let textY = (height - block) / 2
        subtitleField.frame = NSRect(x: textX, y: textY, width: textWidth, height: subtitleHeight)
        titleField.frame = NSRect(x: textX, y: textY + subtitleHeight + 2, width: textWidth, height: titleHeight)
    }

    private func configure(_ field: NSTextField, size: CGFloat, weight: NSFont.Weight, alpha: CGFloat) {
        field.font = .systemFont(ofSize: size, weight: weight)
        field.textColor = NSColor.white.withAlphaComponent(alpha)
        field.lineBreakMode = .byWordWrapping
        field.maximumNumberOfLines = 2
        field.cell?.wraps = true
        field.cell?.isScrollable = false
        field.drawsBackground = false
        field.isBezeled = false
        field.isEditable = false
        field.isSelectable = false
    }

    private func measuredHeight(_ field: NSTextField, width: CGFloat) -> CGFloat {
        field.preferredMaxLayoutWidth = width
        let size = field.cell?.cellSize(forBounds: NSRect(x: 0, y: 0, width: width, height: 400)) ?? NSSize(width: width, height: 16)
        return ceil(size.height)
    }
}

@MainActor
final class AppIconDragView: NSView, NSDraggingSource {
    override var isFlipped: Bool { false }

    override func draw(_ dirtyRect: NSRect) {
        let icon = NSWorkspace.shared.icon(forFile: Bundle.main.bundleURL.path)
        icon.draw(in: bounds)
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .openHand)
    }

    override func mouseDown(with event: NSEvent) {
        let url = Bundle.main.bundleURL
        let writer = AppBundlePasteboardWriter(url: url)
        let item = NSDraggingItem(pasteboardWriter: writer)
        let icon = NSWorkspace.shared.icon(forFile: url.path)
        item.setDraggingFrame(bounds, contents: icon)
        beginDraggingSession(with: [item], event: event, source: self)
    }

    func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        .copy
    }

    func draggingSession(_ session: NSDraggingSession, endedAt screenPoint: NSPoint, operation: NSDragOperation) {
        guard operation != [] else { return }
        Task { @MainActor in
            PermissionGrantController.shared.noteDropAccepted()
        }
    }
}

private final class FirstMouseButton: NSButton {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

/// File URL plus the legacy filename list System Settings still reads on drop.
final class AppBundlePasteboardWriter: NSObject, NSPasteboardWriting {
    let url: URL
    init(url: URL) { self.url = url }

    func writableTypes(for pasteboard: NSPasteboard) -> [NSPasteboard.PasteboardType] {
        [.fileURL, .string, NSPasteboard.PasteboardType("NSFilenamesPboardType")]
    }

    func pasteboardPropertyList(forType type: NSPasteboard.PasteboardType) -> Any? {
        switch type {
        case .fileURL:
            return url.absoluteString
        case .string:
            return url.path
        case NSPasteboard.PasteboardType("NSFilenamesPboardType"):
            return [url.path]
        default:
            return nil
        }
    }
}
