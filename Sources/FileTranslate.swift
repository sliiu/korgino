import AVFoundation
import Combine
import AppKit
import NaturalLanguage
import PDFKit
import Quartz
import SwiftUI
import UniformTypeIdentifiers
import WebKit

enum FileReader {
    static let textExtensions: Set<String> = [
        "txt", "md", "markdown", "csv", "tsv", "json", "html", "htm",
        "xml", "yaml", "yml", "log", "swift", "py", "js", "ts", "tsx",
        "jsx", "java", "go", "rs", "c", "cpp", "h", "css", "scss", "rtf", "srt", "vtt",
        "lrc", "ass", "ssa"
    ]

    static let timedExtensions: Set<String> = ["lrc", "srt", "vtt", "ass", "ssa"]

    static let officeExtensions: Set<String> = OfficeExtract.officeExtensions

    /// Extensions accepted by open panel / drag-drop / hotkey.
    static let allAcceptedExtensions: Set<String> = textExtensions
        .union(officeExtensions)
        .union(VisionFileReader.imageExtensions)

    static func read(url: URL) throws -> String {
        let ext = url.pathExtension.lowercased()
        if OfficeExtract.supports(ext) {
            return try OfficeExtract.extract(url: url)
        }
        if ext == "rtf" {
            let data = try Data(contentsOf: url)
            if let attr = try? NSAttributedString(
                data: data,
                options: [.documentType: NSAttributedString.DocumentType.rtf],
                documentAttributes: nil
            ) {
                return attr.string
            }
        }
        let data = try Data(contentsOf: url)
        if timedExtensions.contains(ext) { return try decodeTimed(data) }
        if let s = String(data: data, encoding: .utf8) { return s }
        if let s = String(data: data, encoding: .isoLatin1) { return s }
        if let s = String(data: data, encoding: .utf16) { return s }
        throw TErr(L("无法以文本编码读取文件"))
    }

    /// UTF-8 first. A file that is not UTF-8 is GB18030, unless NUL bytes mark UTF-16.
    private static func decodeTimed(_ data: Data) throws -> String {
        if let s = String(data: data, encoding: .utf8) { return s }
        if data.contains(0), let s = String(data: data, encoding: .utf16) { return s }
        let gb18030 = String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(
            CFStringEncoding(CFStringEncodings.GB_18030_2000.rawValue)))
        if let s = String(data: data, encoding: gb18030) { return s }
        throw TErr(L("无法以文本编码读取文件"))
    }

    static func defaultOutputURL(for input: URL) -> URL {
        let name = input.deletingPathExtension().lastPathComponent
        // Always save translation as markdown/text for office/pdf sources
        let ext = input.pathExtension.lowercased()
        let outExt: String
        if officeExtensions.contains(ext) || VisionFileReader.imageExtensions.contains(ext) {
            outExt = "md"
        } else if input.pathExtension.isEmpty {
            outExt = "txt"
        } else {
            outExt = input.pathExtension
        }
        return input.deletingLastPathComponent()
            .appendingPathComponent("\(name).translated.\(outExt)")
    }

    static func isAccepted(_ url: URL) -> Bool {
        let ext = url.pathExtension.lowercased()
        if ext.isEmpty { return true }
        if allAcceptedExtensions.contains(ext) { return true }
        return UTType(filenameExtension: ext)?.conforms(to: .text) == true
    }

    static func openPanelContentTypes() -> [UTType] {
        var types: [UTType] = [
            .plainText, .utf8PlainText, .commaSeparatedText, .json,
            .html, .xml, .sourceCode, .rtf, .pdf, .image
        ]
        let extras = [
            "md", "markdown", "yaml", "yml", "log", "csv", "tsv", "srt", "vtt", "lrc", "ass", "ssa",
            "docx", "doc", "xlsx", "xls", "pptx", "ppt",
            "odt", "ods", "odp"
        ]
        for ext in extras {
            if let t = UTType(filenameExtension: ext)
                ?? UTType(tag: ext, tagClass: .filenameExtension, conformingTo: .plainText) {
                types.append(t)
            }
        }
        // Broad office UTTypes when available
        if let t = UTType("org.openxmlformats.wordprocessingml.document") { types.append(t) }
        if let t = UTType("org.openxmlformats.spreadsheetml.sheet") { types.append(t) }
        if let t = UTType("org.openxmlformats.presentationml.presentation") { types.append(t) }
        if let t = UTType("com.microsoft.word.doc") { types.append(t) }
        if let t = UTType("com.microsoft.excel.xls") { types.append(t) }
        if let t = UTType("com.microsoft.powerpoint.ppt") { types.append(t) }
        return types
    }
}

/// Scanned PDF / image → text via the file-translation AI model (vision).
enum VisionFileReader {
    static let imageExtensions: Set<String> = [
        "png", "jpg", "jpeg", "heic", "heif", "tif", "tiff", "webp", "gif", "bmp"
    ]

    static func isImage(_ url: URL) -> Bool {
        imageExtensions.contains(url.pathExtension.lowercased())
    }

    static func supports(_ url: URL) -> Bool {
        isImage(url) || url.pathExtension.lowercased() == "pdf"
    }

    /// 图片算一页；PDF 打不开或没有页面时抛错。
    static func pageCount(url: URL) throws -> Int {
        if isImage(url) { return 1 }
        guard let doc = PDFDocument(url: url), doc.pageCount > 0 else {
            throw TErr(L("无法打开 PDF 文件"))
        }
        return doc.pageCount
    }

    static func transcribe(url: URL, onProgress: @escaping @Sendable (Int, Int) -> Void) async throws -> String {
        guard let profile = AppConfig.shared.preferredFileProfile() else {
            throw TErr(L("扫描件 / 图片需要识图 AI 模型，请先添加并启用 AI 提供商"))
        }
        let pages = try images(url: url)
        var outs: [String] = []
        for (i, image) in pages.enumerated() {
            try Task.checkCancellation()
            onProgress(i + 1, pages.count)
            outs.append(try await CloudOCR.aiVisionText(CloudOCR.pngData(image), profile: profile))
        }
        return outs.joined(separator: "\n\n")
    }

    /// 整页直读：一页一次调用，跳过 OCR 那一趟。版面、表格、分栏顺序因此不用经过
    /// 「压成一行行文字再还原」这一步。任何一页失败就整份失败，并说清是第几页，
    /// 免得交付一份少了页的译文。
    static func translateDirect(
        url: URL,
        profile: AIProfile,
        language: TargetLanguage,
        onProgress: @escaping @Sendable (Int, Int) -> Void
    ) async throws -> String {
        guard profile.supportsVision else {
            throw TErr(String(format: L("%@ 看不了图片，换一个视觉模型，或关闭「直读页面」"), String(describing: profile.name)))
        }
        let total = try pageCount(url: url)
        let system = directSystem(profile: profile, language: language)
        var outs: [String] = []
        let doc = isImage(url) ? nil : PDFDocument(url: url)
        for i in 0..<total {
            try Task.checkCancellation()
            onProgress(i + 1, total)
            guard let image = isImage(url) ? renderImage(url: url) : doc.flatMap({ render(doc: $0, index: i) }) else {
                throw TErr(String(format: L("第 %@ 页读不出来"), String(i + 1)))
            }
            let png = try CloudOCR.pngData(image)
            let prompt = total > 1
                ? "This is page \(i + 1) of \(total) of a document. Translate this page only."
                : "Translate this page."
            do {
                let page = try await Translator.openaiPageImage(png, profile: profile, system: system, instruction: prompt)
                if !page.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { outs.append(page) }
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                throw TErr(String(format: L("第 %@ 页直读失败：%@"), String(i + 1), String(describing: error.localizedDescription)))
            }
        }
        guard !outs.isEmpty else { throw TErr(L("一页都没读出来")) }
        return outs.joined(separator: "\n\n")
    }

    /// 直读时没有 <text> 段可标，术语表与占位符保护不适用，所以给一条只针对整页的提示。
    /// 用户自己写的系统提示仍然接在后面，偏好不会被悄悄丢掉。
    private static func directSystem(profile: AIProfile, language: TargetLanguage) -> String {
        var lines = [
            "You are a professional translation engine, not a tutor or assistant.",
            "The user sends one page image of a document. Translate every piece of text on the page into \(language.resolvedDestination.promptName).",
            "",
            "Rules:",
            "- Output ONLY the translation, as Markdown, in the page's natural reading order.",
            "- Keep the page's structure: headings, paragraphs, lists, footnotes, captions, headers and footers stay with what they belong to.",
            "- Render tables as Markdown tables with the same rows and columns, empty cells included.",
            "- Multi-column pages: read one column fully before the next one starts.",
            "- Leave numbers, dates, names, code, URLs, emails and formulas as they are.",
            "- Do not describe the page, do not summarize it, do not add commentary or a title the page does not have.",
            "- Do not add page numbers or running headers of your own.",
            "- Do not wrap the whole answer in a code fence.",
            "- If the page has no readable text, output nothing at all.",
        ]
        let custom = profile.systemPrompt.trimmingCharacters(in: .whitespacesAndNewlines)
        if !custom.isEmpty {
            lines.append("")
            lines.append("Additional instructions from the user:")
            lines.append(custom)
        }
        return lines.joined(separator: "\n")
    }

    private static func images(url: URL) throws -> [CGImage] {
        if isImage(url) {
            guard let cg = renderImage(url: url) else { throw TErr(L("无法读取图片")) }
            return [cg]
        }
        guard let doc = PDFDocument(url: url), doc.pageCount > 0 else {
            throw TErr(L("无法打开 PDF 文件"))
        }
        return (0..<doc.pageCount).compactMap { render(doc: doc, index: $0) }
    }

    private static func renderImage(url: URL) -> CGImage? {
        guard let img = NSImage(contentsOf: url) else { return nil }
        return img.cgImage(forProposedRect: nil, context: nil, hints: nil)
    }

    /// 长边缩到 2000px：再大模型也看不细，只多花 token。
    private static func render(doc: PDFDocument, index: Int) -> CGImage? {
        guard let page = doc.page(at: index) else { return nil }
        let box = page.bounds(for: .mediaBox).size
        let scale = 2000 / max(box.width, box.height, 1)
        let size = NSSize(width: box.width * scale, height: box.height * scale)
        return page.thumbnail(of: size, for: .mediaBox)
            .cgImage(forProposedRect: nil, context: nil, hints: nil)
    }
}

/// 文件窗口里的一页：一家翻译服务、一种目标语言，AI 时一个模型。只在这个窗口里，不写回设置。
struct FilePage: Identifiable {
    let id = UUID()
    var targetID: String
    var language: TargetLanguage
    /// 这一页换的模型。nil 是设置里的模型。
    var model: String?
    var text: String?
    var error: String?
    var loading = false
    var applePackMissing = false
    /// 分段进度。
    var progress = ""
    /// 这一页的译文是从哪段原文出的。
    var source: String?
    /// 这一次翻译。换了设置又翻时，旧的那次回来就丢掉。
    var run: UUID?

    mutating func clearResult() {
        text = nil
        error = nil
        loading = false
        applePackMissing = false
        progress = ""
        source = nil
        run = nil
    }
}

@MainActor
final class FileTranslateController: ObservableObject {
    static let shared = FileTranslateController()
    private var titleSub: AnyCancellable?

    @Published var isRunning = false
    @Published var progressLabel = ""
    @Published var lastError: String?
    /// 这份超出免费档的字符数，开始时没翻。
    @Published var overFreeLimit = false
    @Published var sourceURL: URL?
    @Published var sourcePreview = ""
    /// 译文区的几页，标签切换。
    @Published var pages: [FilePage] = []
    @Published var selectedPageID: UUID?
    /// 加过、关过页或改过一页之后，页不再跟着设置变。
    private var pagesTouched = false

    var selectedPage: FilePage? {
        pages.first { $0.id == selectedPageID } ?? pages.first
    }
    /// 正在看的那一页的译文。
    var translatedText: String { selectedPage?.text ?? "" }
    var chunkProgress: String { selectedPage?.progress ?? "" }
    var hasTranslation: Bool { pages.contains { $0.text != nil } }
    @Published var savedPath: String?
    @Published var isDropTargeted = false
    @Published var showChat = false
    @Published var dictExpanded = false
    @Published var dictQuery = ""
    @Published var dictEntry: DictionaryEntry?
    @Published var dictLoading = false
    @Published var dictError: String?
    /// Side-by-side source | translation.
    @Published var splitLayout: Bool = UserDefaults.standard.object(forKey: "file.splitLayout") as? Bool ?? true {
        didSet { UserDefaults.standard.set(splitLayout, forKey: "file.splitLayout") }
    }
    /// Keep source / translation scroll positions in sync (split mode).
    @Published var syncScroll: Bool = UserDefaults.standard.bool(forKey: "file.syncScroll") {
        didSet {
            UserDefaults.standard.set(syncScroll, forKey: "file.syncScroll")
            applyScrollSync()
        }
    }
    /// PDF / 图片整页交给视觉模型翻译，不先抽文字。对扫描件省掉那一趟 OCR，版面、表格、
    /// 分栏顺序也就不用经过「压成一行行文字再还原」。自带文字层的数字版 PDF 仍走抽文字：
    /// 那边更便宜，也能带术语表和占位符保护。存下来，下次拖进扫描件直接走这条路。
    @Published var directVision: Bool = UserDefaults.standard.bool(forKey: "file.directVision") {
        didSet {
            UserDefaults.standard.set(directVision, forKey: "file.directVision")
            guard oldValue != directVision, !isRunning else { return }
            clearPageResults()
            if directVision {
                // 打开直读：扫描件那份 OCR 文字要丢掉，否则翻译仍会走文字那条路。
                if !sourceHasTextLayer, let url = sourceURL, VisionFileReader.supports(url) {
                    sourcePreview = ""
                }
            } else {
                // 关掉：扫描件的原文还空着，把字补回来。
                Task { await self.ensureSourceText() }
            }
        }
    }

    /// 这份文件自己带文字层（数字版 PDF / 文本），不是扫描件。
    private var sourceHasTextLayer = true
    /// 直读时要补 OCR 的那一趟，同时几页要也只跑一遍。
    private var textTask: Task<String, Error>?

    /// 直读开关管得着这份文件：PDF / 图片，且这份文件自己不带文字层（扫描件）。
    /// 数字版 PDF 抽文字更便宜、也能带术语表和占位符，不往直读这条路上引。
    var canDirectVision: Bool {
        guard let url = sourceURL, VisionFileReader.supports(url), !sourceHasTextLayer else { return false }
        return pages.contains { target(for: $0)?.aiProfile != nil }
    }
    @Published var resultEditing: Bool = false
    enum SourceMode { case original, edit }
    @Published var sourceMode: SourceMode = .edit {
        didSet { applyScrollSync() }
    }

    var scrollSyncAvailable: Bool {
        sourceMode != .original || sourceURL?.pathExtension.lowercased() == "pdf"
    }

    func applyScrollSync() {
        scrollSync.enabled = syncScroll && scrollSyncAvailable
    }
    @Published var favoriteBump: Int = 0

    let chat = ChatSession()
    let scrollSync = ScrollSyncBroker()

    private var window: NSWindow?
    /// 每一页自己的翻译。
    private var tasks: [UUID: Task<Void, Never>] = [:]
    private var dictTask: Task<Void, Never>?

    /// Menu / hotkey entry:
    /// - If dialog already has source text → re-translate.
    /// - Else open the dialog for pick / drop.
    func pickAndTranslate() {
        lastError = nil

        // Dialog already has content → re-translate in place. 直读时原文是空的，也要能直接重翻。
        let hasSource = !sourcePreview.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || (directVision && canDirectVision)
        if hasSource {
            showWindow()
            if !isRunning {
                startTranslate()
            }
            return
        }

        if !hasTranslation && sourceURL == nil {
            progressLabel = L("选择或拖入要翻译的文件")
        }
        showWindow()
    }

    func chooseFile() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.allowedContentTypes = FileReader.openPanelContentTypes()
        panel.message = L("选择要翻译的文件（文本 / PDF / Word / Excel / PPT / 图片）")
        panel.prompt = L("选择")
        guard panel.runModal() == .OK, let url = panel.url else { return }
        loadSource(url: url)
    }

    func handleDrop(providers: [NSItemProvider]) -> Bool {
        for p in providers {
            if p.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
                p.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, _ in
                    let url: URL? = {
                        if let u = item as? URL { return u }
                        if let data = item as? Data {
                            return URL(dataRepresentation: data, relativeTo: nil)
                        }
                        if let s = item as? String { return URL(fileURLWithPath: s) }
                        return nil
                    }()
                    guard let url else { return }
                    Task { @MainActor in
                        self.loadSource(url: url)
                    }
                }
                return true
            }
        }
        return false
    }

    func loadSource(url: URL, autoStart: Bool = false) {
        if MediaDrop.looksLikeMedia(url) {
            MediaCaptionsController.shared.add(url)
            return
        }
        guard !isRunning else { return }
        progressLabel = String(format: L("正在读取：%@…"), String(describing: url.lastPathComponent))
        lastError = nil
        overFreeLimit = false
        showWindow()
        Task { @MainActor in
            let accessed = url.startAccessingSecurityScopedResource()
            defer { if accessed { url.stopAccessingSecurityScopedResource() } }
            do {
                guard FileReader.isAccepted(url) else {
                    throw TErr(String(format: L("不支持的文件类型：.%@"), String(describing: url.pathExtension)))
                }
                // PDF / OOXML unzip — never on MainActor.
                var text = ""
                do {
                    if !VisionFileReader.isImage(url) {
                        text = try await Background.runSync { try FileReader.read(url: url) }
                    }
                } catch where VisionFileReader.supports(url) {}
                let hasTextLayer = !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                // 直读时扫描件不进 OCR：译文由整页直接出，预览那栏没有原文可显示，model 一栏会落到「原文件」。
                let scanDirect = directVision && VisionFileReader.supports(url) && !hasTextLayer
                if VisionFileReader.supports(url), !hasTextLayer, !scanDirect {
                    let name = url.lastPathComponent
                    text = try await Background.run {
                        try await VisionFileReader.transcribe(url: url) { cur, total in
                            Task { @MainActor in
                                FileTranslateController.shared.progressLabel = String(format: L("正在识别：%@（%@/%@）…"), name, String(cur), String(total))
                            }
                        }
                    }
                }
                if !scanDirect {
                    guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                        throw TErr(L("文件为空"))
                    }
                }
                sourceURL = url
                sourceMode = FileReader.textExtensions.contains(url.pathExtension.lowercased()) ? .edit : .original
                // 文件自己有没有文字层。扫描件在直读模式下 text 是空的，所以不能用 text 判；
                // 关掉直读时要不要补 OCR，靠这个区分。
                sourceHasTextLayer = hasTextLayer
                sourcePageCount = VisionFileReader.supports(url) ? (try? VisionFileReader.pageCount(url: url)) ?? 0 : 0
                sourcePreview = text
                clearPageResults()
                savedPath = nil
                lastError = nil
                progressLabel = scanDirect
                    ? String(format: L("已选择：%@（整页直读）"), String(describing: url.lastPathComponent))
                    : String(format: L("已选择：%@"), String(describing: url.lastPathComponent))
                chat.reset(source: text, translations: [])
                showChat = false
                if autoStart {
                    startTranslate()
                }
            } catch {
                lastError = error.localizedDescription
                progressLabel = L("读取失败")
            }
        }
    }


    // MARK: - Pages

    func editTranslation(_ text: String) {
        guard let i = pageIndex(selectedPage?.id) else { return }
        pages[i].text = text
    }

    /// 这一页的服务还在不在目录里，AI 时带上这一页换的模型。
    func target(for page: FilePage) -> TranslateTarget? {
        guard let t = AppConfig.shared.catalogTargets().first(where: { $0.id == page.targetID }) else { return nil }
        if let m = page.model, let p = t.aiProfile { return .ai(p.withModel(m)) }
        return t
    }

    /// 标签上的名字。换过模型的 AI 写上模型。
    func pageName(_ page: FilePage) -> String {
        let base = AppConfig.shared.catalogTargets().first { $0.id == page.targetID }
        if let m = page.model, let p = base?.aiProfile { return "\(p.name) · \(m)" }
        return base?.displayName ?? page.targetID
    }

    /// 历史、对话、收藏里分得出是哪一页：名字加目标语言。
    func pageTitle(_ page: FilePage) -> String {
        "\(pageName(page)) → \(page.language.shortTitle)"
    }

    private func pageIndex(_ id: UUID?) -> Int? {
        guard let id else { return nil }
        return pages.firstIndex { $0.id == id }
    }

    /// 没动过页、也还没出译文时，页跟着设置：文件翻译的每一家一页。免费只留一页，用默认那一家。
    func ensurePages() {
        let defaults = AppConfig.shared.translateTargets(.file)
        if !Pro.unlocked, let first = pages.first,
           pages.count > 1 || first.model != nil || (defaults.first.map { $0.id != first.targetID } ?? false) {
            for p in pages { tasks[p.id]?.cancel(); tasks[p.id] = nil }
            pages = [FilePage(targetID: defaults.first?.id ?? first.targetID, language: first.language)]
            refreshRunning()
        }
        if pages.isEmpty || (!pagesTouched && !isRunning && !hasTranslation && pages.map(\.targetID) != defaults.map(\.id)) {
            let language = pages.first?.language ?? AppConfig.shared.appTargetLanguage(bundleID: nil)
            pages = defaults.map { FilePage(targetID: $0.id, language: language) }
        }
        if pageIndex(selectedPageID) == nil { selectedPageID = pages.first?.id }
    }

    func selectPage(_ id: UUID) {
        selectedPageID = id
        if showChat, selectedPage?.text != nil { configureChat() }
    }

    /// Pro：新开一页，用这一家和正在看的那一页的目标语言。窗口里已经翻过就马上翻这一页。
    func addPage(targetID: String) {
        guard Pro.unlocked else { return }
        let language = selectedPage?.language ?? AppConfig.shared.appTargetLanguage(bundleID: nil)
        let page = FilePage(targetID: targetID, language: language)
        let translated = hasTranslation || isRunning
        pages.append(page)
        selectedPageID = page.id
        pagesTouched = true
        if translated { translate(pageIDs: [page.id]) }
    }

    func closePage(_ id: UUID) {
        guard pages.count > 1, let i = pageIndex(id) else { return }
        tasks[id]?.cancel()
        tasks[id] = nil
        pages.remove(at: i)
        pagesTouched = true
        if selectedPageID == id { selectedPageID = pages[min(i, pages.count - 1)].id }
        refreshRunning()
        if !isRunning { finishRun(record: false) }
    }

    func setPageTarget(_ id: UUID, _ targetID: String) {
        guard Pro.unlocked else { return }
        updatePage(id) {
            $0.targetID = targetID
            $0.model = nil
        }
    }

    func setPageLanguage(_ id: UUID, _ language: TargetLanguage) {
        updatePage(id) { $0.language = language }
    }

    /// 选回设置里的模型就等于没换。
    func setPageModel(_ id: UUID, _ model: String?) {
        guard Pro.unlocked, let i = pageIndex(id),
              let profile = AppConfig.shared.catalogTargets().first(where: { $0.id == pages[i].targetID })?.aiProfile else { return }
        let m = model?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        updatePage(id) { $0.model = m.isEmpty || m == profile.model ? nil : m }
    }

    /// 改了一页的服务、语言或模型：这一页的译文作废。窗口里已经翻过就只重翻这一页。
    private func updatePage(_ id: UUID, _ change: (inout FilePage) -> Void) {
        guard let i = pageIndex(id) else { return }
        let before = pages[i]
        var after = before
        change(&after)
        guard after.targetID != before.targetID || after.language != before.language || after.model != before.model else { return }
        let retranslate = hasTranslation || isRunning
        tasks[id]?.cancel()
        tasks[id] = nil
        after.clearResult()
        pages[i] = after
        pagesTouched = true
        refreshRunning()
        if retranslate { translate(pageIDs: [id]) }
    }

    private func refreshRunning() {
        isRunning = pages.contains { $0.loading }
    }

    /// 对话用的几份译文。id 是页，同一家开了几页也分得开。
    private var chatTranslations: [ChatContextItem] {
        pages.compactMap { p in
            guard let t = p.text, !t.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
            return ChatContextItem(id: p.id.uuidString, name: pageTitle(p), text: t)
        }
    }

    func configureChat() {
        chat.configure(
            source: sourcePreview,
            translations: chatTranslations,
            primaryID: selectedPage?.id.uuidString,
            preferredProfileID: AppConfig.shared.fileAIProfileID.isEmpty ? nil : AppConfig.shared.fileAIProfileID
        )
    }

    /// 工具栏的翻译：每一页都翻。
    func startTranslate() {
        ensurePages()
        guard !pages.isEmpty else {
            let a = NSAlert()
            a.messageText = L("未启用翻译引擎")
            a.informativeText = L("请先在「偏好设置」里勾选至少一个翻译引擎（或添加并启用 AI 模型）。")
            a.runModal()
            return
        }
        translate(pageIDs: pages.map(\.id))
    }

    private func translate(pageIDs: [UUID]) {
        let text = sourcePreview
        let textEmpty = text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        // 只有扫描件（没有文字层）才走直读。数字版 PDF 抽文字更便宜，也能带术语表和占位符。
        let direct = directVision && !sourceHasTextLayer
            && (sourceURL.map { VisionFileReader.supports($0) } ?? false)
        guard !textEmpty || direct else {
            lastError = L("原文为空，请先选择文件或粘贴/编辑内容")
            return
        }
        // 直读时没有数得出的原文：按页估，一页当 1000 字符，免费档仍然有个数可依。
        let countable = textEmpty ? sourcePageCount * 1000 : (text as NSString).length
        overFreeLimit = !Pro.unlocked && countable > Pro.freeFileCharacters
        guard !overFreeLimit else {
            lastError = String(format: L("免费版单份最多 %@ 字符，这份有 %@ 字符"), String(Pro.freeFileCharacters), String(countable))
            return
        }
        lastError = nil
        savedPath = nil
        let timedKind = sourceURL.flatMap { TimedText.Kind.forExtension($0.pathExtension) }
        for id in pageIDs {
            guard let i = pageIndex(id) else { continue }
            tasks[id]?.cancel()
            let run = UUID()
            pages[i].clearResult()
            pages[i].run = run
            pages[i].source = text
            guard let target = target(for: pages[i]) else {
                pages[i].error = L("未启用翻译引擎")
                continue
            }
            // 这一页换的模型也在这里：target(for:) 已经把页上的模型带上了。
            let directProfile = direct ? target.aiProfile : nil
            let useDirect = directProfile?.supportsVision == true
            pages[i].loading = true
            let language = pages[i].language
            let name = pageName(pages[i])
            let url = sourceURL
            tasks[id] = Task { @MainActor in
                let result: Result<String, Error>
                do {
                    if useDirect, let profile = directProfile, let url {
                        result = .success(try await Background.run {
                            try await Self.withSecurityScope(url) {
                                try await VisionFileReader.translateDirect(
                                    url: url, profile: profile, language: language
                                ) { cur, total in
                                    Task { @MainActor in
                                        FileTranslateController.shared.setProgress(
                                            id, run: run,
                                            String(format: L("%@ 直读 %@/%@ 页"), name, String(cur), String(total))
                                        )
                                    }
                                }
                            }
                        })
                    } else {
                        // 这一页不能看图（Google / DeepL / 纯文本模型）：把扫描件补一趟 OCR，
                        // 后面几页要文字时也共用这一趟。
                        let plain = await self.ensureSourceText()
                        guard !plain.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                            throw TErr(L("原文为空，这一页需要文字才能翻译"))
                        }
                        result = .success(try await Background.run {
                            try await Translator.translateFileText(plain, target: target, timed: timedKind, language: language) { cur, total in
                                Task { @MainActor in
                                    FileTranslateController.shared.setProgress(id, run: run, String(format: L("%@ 分段 %@/%@"), name, String(cur), String(total)))
                                }
                            }
                        })
                    }
                } catch {
                    result = .failure(error)
                }
                self.finish(id, run: run, result)
            }
        }
        refreshRunning()
        if isRunning {
            progressLabel = String(format: L("同时翻译 %@ 个引擎…"), String(pages.filter(\.loading).count))
        } else {
            finishRun(record: true)
        }
        showWindow()
    }

    private func setProgress(_ id: UUID, run: UUID, _ text: String) {
        guard let i = pageIndex(id), pages[i].run == run, pages[i].loading else { return }
        pages[i].progress = text
    }

    /// 直读时没有原文可数字符：按页估，一页当 1000 字符。免费档仍然有个数可依。
    /// 页数在读取时就数好，翻译那一步不再在主线程上重开 PDF。
    private var sourcePageCount = 0

    /// 直读那一趟也要个 security-scoped 授权，和 loadSource 里一致。
    private static func withSecurityScope<T: Sendable>(
        _ url: URL,
        _ op: @Sendable () async throws -> T
    ) async throws -> T {
        let accessed = url.startAccessingSecurityScopedResource()
        defer { if accessed { url.stopAccessingSecurityScopedResource() } }
        return try await op()
    }

    /// 走文字路径的页要原文：扫描件在直读模式下跳过了 OCR，这里补一趟，几页共用。
    /// 已经有文字层就直接返回，不动 sourcePreview。
    @discardableResult
    private func ensureSourceText() async -> String {
        let existing = sourcePreview.trimmingCharacters(in: .whitespacesAndNewlines)
        if !existing.isEmpty { return sourcePreview }
        guard let url = sourceURL, VisionFileReader.supports(url) else { return sourcePreview }
        if let t = textTask {
            if let text = try? await t.value { return text }
            return sourcePreview
        }
        let name = url.lastPathComponent
        let task = Task<String, Error> {
            try await Self.withSecurityScope(url) {
                try await Background.run {
                    try await VisionFileReader.transcribe(url: url) { cur, total in
                        Task { @MainActor in
                            FileTranslateController.shared.progressLabel = String(format: L("正在识别：%@（%@/%@）…"), name, String(cur), String(total))
                        }
                    }
                }
            }
        }
        textTask = task
        defer { textTask = nil }
        do {
            let text = try await task.value
            if !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                sourcePreview = text
                // 文件自己仍然没有文字层：直读开关对它依然有效，只是多了份 OCR 文字给别的引擎用。
                progressLabel = String(format: L("已选择：%@"), String(describing: name))
            }
            return text
        } catch {
            lastError = error.localizedDescription
            return ""
        }
    }

    private func finish(_ id: UUID, run: UUID, _ result: Result<String, Error>) {
        guard let i = pageIndex(id), pages[i].run == run, pages[i].loading else { return }
        tasks[id] = nil
        pages[i].loading = false
        pages[i].progress = ""
        switch result {
        case .success(let s):
            pages[i].text = s
        case .failure(let e):
            pages[i].error = e.localizedDescription
            if let te = e as? TErr { pages[i].applePackMissing = te.applePackMissing }
        }
        refreshRunning()
        if isRunning {
            let done = pages.filter { !$0.loading }.count
            progressLabel = String(format: L("已完成 %@/%@"), String(done), String(pages.count))
        } else {
            finishRun(record: true)
        }
    }

    /// 几页都停下之后：底部状态、对话的上下文、历史。
    private func finishRun(record: Bool) {
        let name = sourceURL?.lastPathComponent ?? L("编辑原文")
        let ok = pages.filter { $0.text != nil }.count
        let fail = pages.filter { $0.error != nil }.count
        if ok == 0 {
            if fail > 0 {
                progressLabel = L("失败")
                lastError = pages.compactMap(\.error).first
            }
        } else {
            let failPart = fail > 0 ? String(format: L("，%@ 失败"), String(fail)) : ""
            progressLabel = String(format: L("翻译完成 — %@（%@/%@%@）"), name, String(ok), String(pages.count), failPart)
            lastError = nil
        }
        chat.reset(
            source: sourcePreview,
            translations: chatTranslations,
            primaryID: selectedPage?.id.uuidString,
            preferredProfileID: AppConfig.shared.preferredFileProfile()?.id
        )
        guard record, ok + fail > 0 else { return }

        let text = sourcePreview
        let shown = selectedPage?.text != nil ? selectedPage : pages.first { $0.text != nil }
        let plan = Lang.plan(text, target: shown?.language ?? pages.first?.language, mutual: true)
        // 直读时没有原文：历史里用文件名占位，别留一条空记录点不开。
        let histSource = text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? (sourceURL?.lastPathComponent ?? L("文件翻译"))
            : String(text.prefix(4000))
        let histPath = sourceURL?.path
        let histDir = plan.directionLabel
        // 同一家开了几页时，后面几页的 id 带「#2」，浮层里重开历史时分得开，图标照旧认得出。
        var seen: [String: Int] = [:]
        let histResults = pages.filter { $0.text != nil || $0.error != nil }.map { p -> HistoryProviderResult in
            let n = (seen[p.targetID] ?? 0) + 1
            seen[p.targetID] = n
            return HistoryProviderResult(id: n == 1 ? p.targetID : "\(p.targetID)#\(n)", name: pageTitle(p),
                                         text: p.text.map { String($0.prefix(2000)) },
                                         error: p.error)
        }
        // 同一份原文 60 秒内再记会盖掉上一条，加一页后历史里是几页的全份。
        Task.detached(priority: .utility) {
            HistoryStore.append(
                source: histSource,
                direction: histDir,
                kind: "file",
                results: histResults,
                filePath: histPath
            )
        }
    }

    func saveTranslated() {
        guard !translatedText.isEmpty else { return }
        let save = NSSavePanel()
        if let url = sourceURL {
            save.nameFieldStringValue = FileReader.defaultOutputURL(for: url).lastPathComponent
            save.directoryURL = url.deletingLastPathComponent()
        } else {
            save.nameFieldStringValue = "translated.md"
        }
        save.canCreateDirectories = true
        save.message = L("保存译文")
        save.allowedContentTypes = [.plainText, .utf8PlainText]
        if let md = UTType(filenameExtension: "md") {
            save.allowedContentTypes.append(md)
        }
        if let ext = sourceURL?.pathExtension.lowercased(),
           FileReader.timedExtensions.contains(ext),
           let timed = UTType(filenameExtension: ext)
            ?? UTType(tag: ext, tagClass: .filenameExtension, conformingTo: .plainText) {
            save.allowedContentTypes.append(timed)
        }
        guard save.runModal() == .OK, let dest = save.url else { return }
        do {
            try translatedText.write(to: dest, atomically: true, encoding: .utf8)
            savedPath = dest.path
            progressLabel = String(format: L("已保存：%@"), String(describing: dest.lastPathComponent))
            NSWorkspace.shared.activateFileViewerSelecting([dest])
        } catch {
            overFreeLimit = false
            lastError = String(format: L("保存失败：%@"), String(describing: error.localizedDescription))
        }
    }

    func clearAll() {
        guard !isRunning else { return }
        sourceURL = nil
        sourcePreview = ""
        sourceHasTextLayer = true
        sourcePageCount = 0
        textTask?.cancel()
        textTask = nil
        clearPageResults()
        savedPath = nil
        lastError = nil
        overFreeLimit = false
        progressLabel = L("选择或拖入要翻译的文件")
        chat.reset(source: "", translations: [])
        showChat = false
        dictTask?.cancel()
        dictExpanded = false
        dictQuery = ""
        dictEntry = nil
        dictLoading = false
        dictError = nil
    }

    func lookupDictionary() {
        let q = dictQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return }
        dictQuery = q
        dictExpanded = true
        dictTask?.cancel()
        dictLoading = true
        dictError = nil
        dictEntry = nil
        dictTask = Task { @MainActor in
            do {
                let entry = try await Background.run {
                    try await DictionaryLookup.lookup(q)
                }
                guard !Task.isCancelled else { return }
                dictEntry = entry
                dictLoading = false
            } catch {
                guard !Task.isCancelled else { return }
                dictLoading = false
                if error is MaskDeclined { return }
                dictError = error.localizedDescription
            }
        }
    }

    /// 换了文件或清除：几页留着，译文清掉。
    private func clearPageResults() {
        for (_, t) in tasks { t.cancel() }
        tasks = [:]
        for i in pages.indices { pages[i].clearResult() }
        isRunning = false
        ensurePages()
    }

    private func showWindow() {
        ensurePages()
        if window == nil {
            let root = FileTranslateView(model: self)
                .environmentObject(AppConfig.shared)
            let hc = NSHostingController(rootView: root)
            hc.sceneBridgingOptions = [.toolbars]
            let w = NSWindow(contentViewController: hc)
            w.title = L("翻译文件")
            titleSub = $sourceURL.sink { [weak w] url in
                w?.subtitle = url?.lastPathComponent ?? ""
            }
            w.styleMask = [.titled, .closable, .resizable, .miniaturizable, .fullSizeContentView]
            w.toolbarStyle = .unified
            w.isReleasedWhenClosed = false
            w.isMovableByWindowBackground = false
            w.setContentSize(NSSize(width: 980, height: 720))
            w.minSize = NSSize(width: 720, height: 480)
            w.center()
            NotificationCenter.default.addObserver(
                forName: NSWindow.willCloseNotification, object: w, queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated {
                    if self?.isRunning == true { self?.cancel() }
                }
            }
            window = w
        }
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func relocalize() {
        window?.title = L("翻译文件")
    }

    func closeWindow() {
        if isRunning { cancel() }
        window?.orderOut(nil)
    }

    func cancel() {
        for (_, t) in tasks { t.cancel() }
        tasks = [:]
        for i in pages.indices where pages[i].loading {
            pages[i].loading = false
            pages[i].progress = ""
            pages[i].run = nil
            if pages[i].text == nil { pages[i].error = L("已取消") }
        }
        isRunning = false
        if !hasTranslation {
            progressLabel = sourceURL.map { String(format: L("已选择：%@"), String(describing: $0.lastPathComponent)) } ?? L("已取消")
        } else {
            progressLabel = L("已取消（保留上次译文）")
        }
    }
}

// MARK: - Window UI

struct FileTranslateView: View {
    @ObservedObject var model: FileTranslateController
    @EnvironmentObject var config: AppConfig
    @ObservedObject private var pro = Pro.shared
    @State private var copiedID: String?

    var body: some View {
        VStack(spacing: 0) {
            if model.sourcePreview.isEmpty && model.sourceURL == nil && !model.isRunning {
                dropZone
            } else if chatVisible {
                if model.splitLayout {
                    HSplitView {
                        contentArea
                        chatPanel
                            .frame(minWidth: 240, idealWidth: 300, maxWidth: 560)
                            .padding(.top, 12)
                            .padding(.trailing, 16)
                            .padding(.bottom, 8)
                            .padding(.leading, 8)
                    }
                } else {
                    VSplitView {
                        contentArea
                        chatPanel
                            .frame(minHeight: 160, idealHeight: 240, maxHeight: 520)
                            .padding(.horizontal, 16)
                            .padding(.top, 8)
                            .padding(.bottom, 8)
                    }
                }
            } else {
                contentArea
            }
            if model.dictExpanded {
                PopupDictionarySection(
                    entry: model.dictEntry,
                    loading: model.dictLoading,
                    error: model.dictError,
                    expanded: $model.dictExpanded,
                    query: $model.dictQuery,
                    onSubmit: { model.lookupDictionary() }
                )
                .padding(.horizontal, 16)
                .padding(.bottom, 8)
            }
            Divider()
            footer
        }
        .frame(minWidth: 720, maxWidth: .infinity, minHeight: 480, maxHeight: .infinity)
        .background(Theme.windowFill)
        .toolbar { toolbarContent }
        .onAppear { model.applyScrollSync() }
        .controlSize(.small)
    }

    private var chatAllowed: Bool {
        let _ = pro.purchased
        let _ = pro.trialEnd
        #if KORGI_DEV
        let _ = pro.devUnlocked
        #endif
        return Pro.unlocked
    }

    private var chatVisible: Bool {
        chatAllowed && !model.translatedText.isEmpty && model.showChat
    }

    private var chatPanel: some View {
        TranslationChatView(session: model.chat, compact: false)
            .card()
    }

    @ViewBuilder
    private var contentArea: some View {
        Group {
            if model.splitLayout {
                HSplitView {
                    sourceEditor
                        .frame(minWidth: 280, idealWidth: 420)
                    resultPane
                        .frame(minWidth: 280, idealWidth: 420)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                VSplitView {
                    sourceEditor
                        .frame(minHeight: 160, idealHeight: 300)
                    resultPane
                        .frame(minHeight: 160, idealHeight: 300)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .onDrop(of: [UTType.fileURL], isTargeted: Binding(
            get: { model.isDropTargeted },
            set: { model.isDropTargeted = $0 }
        )) { providers in
            model.handleDrop(providers: providers)
        }
    }

    private var fileDrop: FileDropHandler {
        FileDropHandler(
            onTargeted: { model.isDropTargeted = $0 },
            onDrop: { model.loadSource(url: $0) }
        )
    }

    private func dropHighlight(_ radius: CGFloat = Theme.cardRadius) -> some View {
        RoundedRectangle(cornerRadius: radius, style: .continuous)
            .strokeBorder(Color.accentColor, lineWidth: 2)
            .opacity(model.isDropTargeted ? 1 : 0)
            .allowsHitTesting(false)
    }

    private var sourceEditor: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                SectionHeader(L("原文"))
                if let url = model.sourceURL {
                    Text((url.path as NSString).abbreviatingWithTildeInPath)
                        .font(.system(size: 11))
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .help(url.path)
                }
                Spacer(minLength: 8)
                if !model.sourcePreview.isEmpty {
                    SpeakButton(text: model.sourcePreview, help: L("朗读原文"), tag: "file.source")
                }
                if model.sourceURL != nil {
                    PillSegmented(
                        selection: $model.sourceMode,
                        options: [(.original, L("原文件")), (.edit, L("编辑"))]
                    )
                }
            }
            .padding(.leading, 4)
            Group {
                if model.sourceMode == .original, let url = model.sourceURL {
                    OriginalFileView(url: url, broker: model.scrollSync)
                        .card(fill: Color(nsColor: .textBackgroundColor))
                } else {
                    SyncableTextEditor(
                        text: $model.sourcePreview,
                        isEditable: !model.isRunning,
                        broker: model.scrollSync,
                        fileDrop: fileDrop
                    )
                    .padding(10)
                    .card(fill: Color(nsColor: .textBackgroundColor))
                }
            }
            .frame(maxHeight: .infinity)
            .overlay(dropHighlight())
        }
        .padding(.horizontal, 16)
        .padding(.top, 12)
        .padding(.bottom, 8)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItem(placement: .navigation) {
            IconButton(systemImage: "folder", help: L("选择文件…"), size: 12) {
                model.chooseFile()
            }
            .disabled(model.isRunning)
        }
        .korgiHideToolbarBackground()
        ToolbarItem(placement: .primaryAction) {
            IconButton(
                systemImage: model.splitLayout ? "rectangle.split.2x1" : "rectangle.split.1x2",
                help: model.splitLayout ? L("布局：左右") : L("布局：上下"),
                size: 12
            ) { model.splitLayout.toggle() }
        }
        .korgiHideToolbarBackground()
        ToolbarItem(placement: .primaryAction) {
            IconButton(
                systemImage: "doc.viewfinder",
                help: model.directVision
                    ? L("整页直读：已开启，扫描件/图片不先抽文字，直接交给视觉模型")
                    : L("整页直读：PDF / 图片整页交给视觉模型，跳过抽文字"),
                tint: model.directVision ? .accentColor : nil,
                size: 12
            ) { model.directVision.toggle() }
            .disabled(!model.canDirectVision || model.isRunning)
        }
        .korgiHideToolbarBackground()
        ToolbarItem(placement: .primaryAction) {
            IconButton(
                systemImage: "arrow.up.arrow.down",
                help: L("同步原文与译文滚动位置"),
                tint: model.syncScroll && model.scrollSyncAvailable ? .accentColor : nil,
                size: 12
            ) { model.syncScroll.toggle() }
            .disabled(!model.scrollSyncAvailable)
        }
        .korgiHideToolbarBackground()
        ToolbarItem(placement: .primaryAction) {
            if model.isRunning {
                IconButton(systemImage: "stop.fill", help: L("取消"), size: 12) {
                    model.cancel()
                }
            } else {
                Button {
                    model.startTranslate()
                } label: {
                    Label(
                        model.hasTranslation ? L("重新翻译") : L("翻译"),
                        systemImage: model.hasTranslation ? "arrow.clockwise" : "translate"
                    )
                    .labelStyle(.titleAndIcon)
                }
                .buttonStyle(ToolbarProminentButtonStyle())
                .disabled(model.sourcePreview.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                          && !(model.directVision && model.canDirectVision))
                .keyboardShortcut(.defaultAction)
                .help(L("用当前原文（可先编辑）调用已启用的翻译引擎"))
            }
        }
        .korgiHideToolbarBackground()
    }

    private var dropZone: some View {
        VStack(spacing: 14) {
            ZStack {
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .strokeBorder(
                        style: StrokeStyle(lineWidth: 1.5, dash: [7, 5])
                    )
                    .foregroundStyle(model.isDropTargeted ? Color.accentColor : Color.primary.opacity(0.15))
                    .background(
                        RoundedRectangle(cornerRadius: 16, style: .continuous)
                            .fill(model.isDropTargeted ? Color.accentColor.opacity(0.08) : Theme.cardFill)
                    )

                VStack(spacing: 12) {
                    Image(systemName: "doc.badge.arrow.up")
                        .font(.system(size: 40, weight: .light))
                        .foregroundStyle(model.isDropTargeted ? Color.accentColor : Color.secondary)
                    Text(L("拖入文件"))
                        .font(.system(size: 15, weight: .semibold))
                    Text("txt · md · pdf · docx · xlsx · pptx")
                        .font(.system(size: 12))
                        .foregroundStyle(.tertiary)
                    Button(L("选择文件…")) { model.chooseFile() }
                        .controlSize(.regular)
                        .padding(.top, 4)
                }
                .padding(24)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding(20)
            .onDrop(of: [UTType.fileURL], isTargeted: Binding(
                get: { model.isDropTargeted },
                set: { model.isDropTargeted = $0 }
            )) { providers in
                model.handleDrop(providers: providers)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var resultPane: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 6) {
                SectionHeader(L("译文"))
                    .padding(.top, 4)
                pageTabs
            }
            .padding(.leading, 20)
            .padding(.trailing, 16)
            .padding(.top, 12)

            if let page = model.selectedPage {
                pageBar(page)
                    .padding(.leading, 16)
                    .padding(.trailing, 16)
                pageBody(page)
            } else {
                translationBody("")
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// 一页一个标签：服务和目标语言。Pro 可以再开一页，同一家也能开几页。
    /// 放不下就折到下一行：横向滚动在 Mac 上鼠标拖不动、滚轮也不横着走，后面的标签就找不到了。
    private var pageTabs: some View {
        FlowTags(spacing: 4) {
            ForEach(model.pages) { page in
                pageTab(page)
            }
            newPageMenu
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func pageTab(_ page: FilePage) -> some View {
        let active = page.id == model.selectedPage?.id
        return HStack(spacing: 0) {
            Button {
                model.selectPage(page.id)
            } label: {
                HStack(spacing: 5) {
                    if page.loading {
                        ProgressView().controlSize(.mini)
                    } else if page.error != nil && page.text == nil {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .font(.system(size: 9))
                            .foregroundStyle(.red)
                    } else {
                        ProviderIconView(outcomeID: page.targetID, name: model.pageName(page), size: 11)
                    }
                    Text(model.pageName(page))
                        .lineLimit(1)
                        .frame(maxWidth: 140)
                    Text(page.language.shortTitle)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                .padding(.leading, 10)
                .padding(.trailing, model.pages.count > 1 ? 2 : 10)
                .padding(.vertical, 4)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(page.error ?? model.pageTitle(page))
            if model.pages.count > 1 {
                Button {
                    model.closePage(page.id)
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 9, weight: .medium))
                        .foregroundStyle(.secondary)
                        .frame(width: 20, height: 20)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(L("关闭标签"))
                .padding(.trailing, 2)
            }
        }
        .font(.system(size: 11, weight: active ? .semibold : .regular))
        .foregroundStyle(active ? Color.accentColor : Color.primary.opacity(0.75))
        .background(
            Capsule(style: .continuous)
                .fill(active ? Color.accentColor.opacity(0.14) : Color.primary.opacity(0.05))
        )
    }

    /// 新开一页时先挑一家。语言跟正在看的那一页，开了再改。
    private var newPageMenu: some View {
        HStack(spacing: 4) {
            Menu {
                if Pro.unlocked {
                    ForEach(config.catalogTargets()) { t in
                        Button(t.displayName) { model.addPage(targetID: t.id) }
                    }
                }
            } label: {
                Image(systemName: "plus")
                    .font(.system(size: 11, weight: .semibold))
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .disabled(!Pro.unlocked || config.catalogTargets().isEmpty)
            .help(Pro.unlocked ? L("新开一页，可以选同一家换个语言") : L("免费版不能再加"))
            if !Pro.unlocked {
                ProBadge(help: L("Pro 可以开几页，每页一家、一种语言"))
            }
        }
    }

    /// 这一页的设置：服务、目标语言、模型。只改这一页，不写回设置。
    private func pageBar(_ page: FilePage) -> some View {
        HStack(spacing: 4) {
            pageServiceMenu(page)
            Menu {
                Picker(L("目标语言"), selection: Binding(
                    get: { page.language },
                    set: { model.setPageLanguage(page.id, $0) }
                )) {
                    ForEach(TargetLanguage.specific) { lang in
                        Text(lang.shortTitle).tag(lang)
                    }
                }
                .pickerStyle(.inline)
                .labelsHidden()
            } label: {
                Text("→ \(page.language.shortTitle)")
                    .font(.system(size: 11, weight: .medium))
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.visible)
            .fixedSize()
            .help(L("这一页的目标语言，不改设置"))
            if let p = AppConfig.shared.catalogTargets().first(where: { $0.id == page.targetID })?.aiProfile {
                ModelOverrideMenu(profile: p, override: Binding(
                    get: { page.model },
                    set: { model.setPageModel(page.id, $0) }
                ))
                .padding(.leading, 2)
            }
            if page.loading {
                ProgressView()
                    .controlSize(.mini)
                    .padding(.leading, 4)
                if !page.progress.isEmpty {
                    Text(page.progress)
                        .font(.system(size: 11).monospacedDigit())
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                }
            }
            Spacer()
            if let text = page.text, !text.isEmpty {
                SpeakButton(text: text, language: Lang.plan(model.sourcePreview, target: page.language, mutual: true).tgt, tag: "file.translation")
                CopyMarkdownMenu(id: "file", text: text, copiedID: $copiedID)
            }
            PillSegmented(
                selection: $model.resultEditing,
                options: [(false, L("预览")), (true, L("编辑"))]
            )
        }
    }

    /// 这一页用哪一家。免费只有默认那一家。
    private func pageServiceMenu(_ page: FilePage) -> some View {
        Menu {
            ForEach(Pro.unlocked ? config.catalogTargets() : config.translateTargets(.file)) { t in
                Button {
                    model.setPageTarget(page.id, t.id)
                } label: {
                    if t.id == page.targetID {
                        Label(t.displayName, systemImage: "checkmark")
                    } else {
                        Text(t.displayName)
                    }
                }
            }
        } label: {
            HStack(spacing: 4) {
                ProviderIconView(outcomeID: page.targetID, name: model.pageName(page), size: 11)
                Text(model.pageName(page))
                    .font(.system(size: 11))
            }
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .help(Pro.unlocked ? L("这一页用的翻译服务，不改设置") : L("更换翻译服务"))
    }

    @ViewBuilder
    private func pageBody(_ page: FilePage) -> some View {
        if page.loading && page.text == nil {
            VStack {
                Spacer()
                ProgressView(String(format: L("%@ 翻译中…"), String(describing: model.pageName(page))))
                if !page.progress.isEmpty {
                    Text(page.progress).font(.system(size: 12)).foregroundStyle(.secondary)
                }
                Spacer()
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if let e = page.error, page.text == nil {
            VStack(alignment: .leading, spacing: 8) {
                ErrorLine(text: e)
                if page.applePackMissing {
                    Button(L("下载 Apple 语言包…")) {
                        AppleLangPack.presentDownloadPrompt(force: true)
                    }
                    .font(.system(size: 12))
                }
                Spacer()
            }
            .padding(.horizontal, 16)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        } else {
            translationBody(page.text ?? "")
        }
    }

    @ViewBuilder
    private func translationBody(_ text: String) -> some View {
        Group {
            if model.resultEditing {
                SyncableTextEditor(
                    text: Binding(get: { text }, set: { model.editTranslation($0) }),
                    isEditable: !model.isRunning,
                    broker: model.scrollSync,
                    fileDrop: fileDrop,
                    side: .right
                )
                .padding(10)
                .card(fill: Color(nsColor: .textBackgroundColor))
            } else {
                MarkdownPreview(text: text, broker: model.scrollSync, fileDrop: fileDrop)
            }
        }
        .overlay(dropHighlight())
        .padding(.horizontal, 16)
        .padding(.bottom, 12)
    }

    private var footer: some View {
        let starred = FavoritesStore.contains(
            source: model.sourcePreview,
            translation: model.translatedText
        )
        let _ = model.favoriteBump
        return HStack(spacing: 4) {
            Text(model.progressLabel)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .lineLimit(1)
            if let e = model.lastError {
                ErrorLine(text: e, lineLimit: 1)
                if model.overFreeLimit {
                    ProBadge(help: L("超过 5000 字符的文件需要 Pro"))
                }
            }
            Spacer(minLength: 12)
            IconButton(
                systemImage: "character.book.closed",
                help: model.dictExpanded ? L("收起释义") : L("查词"),
                tint: model.dictExpanded ? .accentColor : nil
            ) {
                model.dictExpanded.toggle()
            }
            if !model.translatedText.isEmpty {
                IconButton(
                    systemImage: "bubble.left.and.bubble.right",
                    help: chatAllowed
                        ? (model.showChat ? L("收起对话") : L("AI 对话"))
                        : L("继续对话需要 Pro"),
                    tint: model.showChat && chatAllowed ? .accentColor : nil
                ) {
                    if model.showChat {
                        model.showChat = false
                    } else if !chatAllowed {
                        Pro.shared.showOffer()
                    } else {
                        model.showChat = true
                        model.configureChat()
                    }
                }
                if !chatAllowed {
                    ProBadge(help: L("继续对话需要 Pro"))
                }
                IconButton(
                    systemImage: starred ? "star.fill" : "star",
                    help: L("收藏译文（历史和收藏 › 收藏）"),
                    tint: starred ? .yellow : nil
                ) {
                    let src = model.sourcePreview
                    let tr = model.translatedText
                    let page = model.selectedPage
                    let name = page.map { model.pageTitle($0) } ?? L("文件翻译")
                    if FavoritesStore.contains(source: src, translation: tr) {
                        FavoritesStore.remove(source: src, translation: tr)
                    } else {
                        FavoritesStore.add(
                            source: src,
                            translation: tr,
                            direction: Lang.plan(src, target: page?.language, mutual: true).directionLabel,
                            providerName: name,
                            kind: "file"
                        )
                    }
                    model.favoriteBump &+= 1
                }
                IconButton(systemImage: "square.and.arrow.down", help: L("另存为… ⌘S")) {
                    model.saveTranslated()
                }
                .keyboardShortcut("s", modifiers: [.command])
            }
            if model.sourceURL != nil || !model.translatedText.isEmpty {
                IconButton(systemImage: "xmark.circle", help: L("清除")) { model.clearAll() }
                    .disabled(model.isRunning)
            }
        }
        .padding(.leading, 16)
        .padding(.trailing, 10)
        .frame(height: 34)
    }
}

// MARK: - Markdown preview (WKWebView + improved HTML)

struct MarkdownPreview: View {
    let text: String
    var broker: ScrollSyncBroker? = nil
    var fileDrop: FileDropHandler? = nil
    var side: ScrollSyncSide = .right

    var body: some View {
        MarkdownWebView(markdown: text, broker: broker, fileDrop: fileDrop, side: side)
            .padding(4)
            .clipShape(RoundedRectangle(cornerRadius: Theme.cardRadius, style: .continuous))
            .card(fill: Color(nsColor: .textBackgroundColor))
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// Lightweight Markdown → HTML for preview. Handles CommonMark-ish + basic GFM tables.
enum SimpleMarkdownHTML {
    nonisolated static func convert(_ src: String) -> String {
        func esc(_ s: String) -> String {
            s.replacingOccurrences(of: "&", with: "&amp;")
                .replacingOccurrences(of: "<", with: "&lt;")
                .replacingOccurrences(of: ">", with: "&gt;")
        }
        let lines = src.replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .components(separatedBy: "\n")
        var out: [String] = []
        var inCode = false
        var codeLang = ""
        var codeBuf: [String] = []
        var listKind: String? = nil // "ul" | "ol"
        var listBuf: [String] = []
        var quoteBuf: [String] = []
        var paraBuf: [String] = []
        var tableRows: [[String]] = []

        func flushPara() {
            guard !paraBuf.isEmpty else { return }
            let joined = paraBuf.joined(separator: " ")
            out.append("<p>" + inline(esc(joined)) + "</p>")
            paraBuf.removeAll()
        }
        func flushList() {
            guard let kind = listKind, !listBuf.isEmpty else { return }
            out.append("<\(kind)>" + listBuf.map { "<li>\($0)</li>" }.joined() + "</\(kind)>")
            listBuf.removeAll()
            listKind = nil
        }
        func flushQuote() {
            guard !quoteBuf.isEmpty else { return }
            let inner = quoteBuf.map { inline(esc($0)) }.joined(separator: "<br/>")
            out.append("<blockquote><p>\(inner)</p></blockquote>")
            quoteBuf.removeAll()
        }
        func flushTable() {
            guard !tableRows.isEmpty else { return }
            // Drop GFM separator row (| --- | --- |)
            var rows = tableRows
            if rows.count >= 2, rows[1].allSatisfy({ cell in
                let c = cell.trimmingCharacters(in: .whitespaces)
                return !c.isEmpty && c.allSatisfy({ $0 == "-" || $0 == ":" || $0 == " " })
            }) {
                rows.remove(at: 1)
            }
            var html = "<table>"
            for (i, cols) in rows.enumerated() {
                let tag = i == 0 ? "th" : "td"
                html += "<tr>" + cols.map { "<\(tag)>" + inline(esc($0.trimmingCharacters(in: .whitespaces))) + "</\(tag)>" }.joined() + "</tr>"
            }
            html += "</table>"
            out.append(html)
            tableRows.removeAll()
        }
        func flushBlocks() {
            flushPara(); flushList(); flushQuote(); flushTable()
        }

        func parseTableRow(_ line: String) -> [String]? {
            let t = line.trimmingCharacters(in: .whitespaces)
            guard t.contains("|") else { return nil }
            var s = t
            if s.hasPrefix("|") { s = String(s.dropFirst()) }
            if s.hasSuffix("|") { s = String(s.dropLast()) }
            let cols = s.components(separatedBy: "|")
            guard cols.count >= 2 else { return nil }
            return cols
        }

        for line in lines {
            if line.hasPrefix("```") {
                if inCode {
                    flushBlocks()
                    let cls = codeLang.isEmpty ? "" : " class=\"language-\(esc(codeLang))\""
                    out.append("<pre><code\(cls)>" + esc(codeBuf.joined(separator: "\n")) + "</code></pre>")
                    codeBuf.removeAll()
                    codeLang = ""
                    inCode = false
                } else {
                    flushBlocks()
                    inCode = true
                    codeLang = String(line.dropFirst(3)).trimmingCharacters(in: .whitespaces)
                }
                continue
            }
            if inCode {
                codeBuf.append(line)
                continue
            }

            let trimmed = line.trimmingCharacters(in: .whitespaces)

            // Table
            if let cols = parseTableRow(line), trimmed.contains("|") {
                flushPara(); flushList(); flushQuote()
                tableRows.append(cols)
                continue
            } else if !tableRows.isEmpty {
                flushTable()
            }

            // Horizontal rule
            if trimmed == "---" || trimmed == "***" || trimmed == "___" {
                flushBlocks()
                out.append("<hr/>")
                continue
            }

            // Headings (# … ######)
            if trimmed.hasPrefix("#") {
                let hashes = trimmed.prefix(while: { $0 == "#" })
                let level = min(hashes.count, 6)
                if level > 0, trimmed.count > level, trimmed[trimmed.index(trimmed.startIndex, offsetBy: level)] == " " {
                    flushBlocks()
                    let content = String(trimmed.dropFirst(level + 1))
                    out.append("<h\(level)>" + inline(esc(content)) + "</h\(level)>")
                    continue
                }
            }

            // Blockquote
            if trimmed.hasPrefix("> ") || trimmed == ">" {
                flushPara(); flushList(); flushTable()
                quoteBuf.append(trimmed == ">" ? "" : String(trimmed.dropFirst(2)))
                continue
            } else if !quoteBuf.isEmpty {
                flushQuote()
            }

            // Unordered list
            if trimmed.hasPrefix("- ") || trimmed.hasPrefix("* ") || trimmed.hasPrefix("+ ") {
                flushPara(); flushQuote(); flushTable()
                if listKind != "ul" { flushList(); listKind = "ul" }
                listBuf.append(inline(esc(String(trimmed.dropFirst(2)))))
                continue
            }
            // Ordered list "1. "
            if let r = trimmed.range(of: #"^\d+\.\s+"#, options: .regularExpression) {
                flushPara(); flushQuote(); flushTable()
                if listKind != "ol" { flushList(); listKind = "ol" }
                listBuf.append(inline(esc(String(trimmed[r.upperBound...]))))
                continue
            }
            if listKind != nil, !trimmed.isEmpty {
                // continuation line of list item
                if let last = listBuf.popLast() {
                    listBuf.append(last + " " + inline(esc(trimmed)))
                    continue
                }
            } else if listKind != nil, trimmed.isEmpty {
                flushList()
                continue
            }

            if trimmed.isEmpty {
                flushPara()
                continue
            }
            paraBuf.append(line.trimmingCharacters(in: .whitespaces))
        }
        if inCode {
            out.append("<pre><code>" + esc(codeBuf.joined(separator: "\n")) + "</code></pre>")
        }
        flushBlocks()
        return out.joined(separator: "\n")
    }

    private static func inline(_ s: String) -> String {
        var r = s
        // images ![alt](url)
        if let re = RegexCache.cached(#"!\[([^\]]*)\]\(([^)\s]+)\)"#) {
            r = re.stringByReplacingMatches(in: r, range: NSRange(r.startIndex..., in: r),
                                            withTemplate: #"<img alt="$1" src="$2"/>"#)
        }
        // links [text](url)
        if let re = RegexCache.cached(#"\[([^\]]+)\]\(([^)\s]+)\)"#) {
            r = re.stringByReplacingMatches(in: r, range: NSRange(r.startIndex..., in: r),
                                            withTemplate: #"<a href="$2">$1</a>"#)
        }
        // bold **x** or __x__
        if let re = RegexCache.cached(#"\*\*(.+?)\*\*"#) {
            r = re.stringByReplacingMatches(in: r, range: NSRange(r.startIndex..., in: r), withTemplate: "<strong>$1</strong>")
        }
        if let re = RegexCache.cached(#"__(.+?)__"#) {
            r = re.stringByReplacingMatches(in: r, range: NSRange(r.startIndex..., in: r), withTemplate: "<strong>$1</strong>")
        }
        // italic *x* (single asterisks; run after bold so ** is already consumed)
        if let re = RegexCache.cached(#"\*([^*\n]+)\*"#) {
            r = re.stringByReplacingMatches(in: r, range: NSRange(r.startIndex..., in: r), withTemplate: "<em>$1</em>")
        }
        if let re = RegexCache.cached(#"_([^_\n]+)_"#) {
            r = re.stringByReplacingMatches(in: r, range: NSRange(r.startIndex..., in: r), withTemplate: "<em>$1</em>")
        }
        // inline code
        if let re = RegexCache.cached(#"`([^`]+)`"#) {
            r = re.stringByReplacingMatches(in: r, range: NSRange(r.startIndex..., in: r), withTemplate: "<code>$1</code>")
        }
        // strikethrough ~~x~~
        if let re = RegexCache.cached(#"~~(.+?)~~"#) {
            r = re.stringByReplacingMatches(in: r, range: NSRange(r.startIndex..., in: r), withTemplate: "<del>$1</del>")
        }
        return r
    }
}

struct MarkdownWebView: NSViewRepresentable {
    let markdown: String
    var broker: ScrollSyncBroker? = nil
    var fileDrop: FileDropHandler? = nil
    var side: ScrollSyncSide = .right

    private static let scrollScript = """
    window.__korgiScrollTo = function (r) {
      var m = document.documentElement.scrollHeight - window.innerHeight;
      window.scrollTo(0, r * Math.max(m, 0));
    };
    window.addEventListener('scroll', function () {
      var m = document.documentElement.scrollHeight - window.innerHeight;
      window.webkit.messageHandlers.korgiScroll.postMessage(m > 0 ? window.scrollY / m : 0);
    }, { passive: true });
    """

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> FileDropWebView {
        let conf = WKWebViewConfiguration()
        conf.suppressesIncrementalRendering = true
        conf.userContentController.addUserScript(
            WKUserScript(source: Self.scrollScript, injectionTime: .atDocumentEnd, forMainFrameOnly: true)
        )
        conf.userContentController.add(context.coordinator, name: "korgiScroll")
        let wv = FileDropWebView(frame: .zero, configuration: conf)
        wv.setValue(false, forKey: "drawsBackground")
        wv.navigationDelegate = context.coordinator
        wv.fileDrop = fileDrop
        context.coordinator.broker = broker
        context.coordinator.side = side
        broker?.attach(wv, side: side)
        return wv
    }

    func updateNSView(_ webView: FileDropWebView, context: Context) {
        webView.fileDrop = fileDrop
        context.coordinator.broker = broker
        context.coordinator.side = side
        broker?.attach(webView, side: side)
        let fingerprint = "\(markdown.count)|\(markdown.hashValue)"
        guard context.coordinator.lastFingerprint != fingerprint else { return }
        context.coordinator.lastFingerprint = fingerprint
        let md = markdown
        let coord = context.coordinator
        Task.detached(priority: .userInitiated) {
            let body = SimpleMarkdownHTML.convert(md)
    let html = """
            <!DOCTYPE html>
            <html><head><meta charset="utf-8"/>
            <meta name="viewport" content="width=device-width, initial-scale=1"/>
            <style>
              :root { color-scheme: light dark; }
              html, body { background: transparent; }
              ::-webkit-scrollbar { width: 6px; height: 6px; background: transparent; }
              ::-webkit-scrollbar-thumb { background: color-mix(in srgb, CanvasText 22%, transparent); border-radius: 3px; }
              ::-webkit-scrollbar-track, ::-webkit-scrollbar-corner { background: transparent; }
              body {
                font: 13px/1.55 -apple-system, BlinkMacSystemFont, "Helvetica Neue", sans-serif;
                padding: 12px 14px; margin: 0;
                color: CanvasText;
                word-wrap: break-word;
                overflow-wrap: anywhere;
              }
              h1,h2,h3,h4,h5,h6 { margin: 0.9em 0 0.4em; line-height: 1.3; font-weight: 650; }
              h1 { font-size: 1.45em; } h2 { font-size: 1.28em; } h3 { font-size: 1.12em; }
              h4,h5,h6 { font-size: 1.0em; }
              p { margin: 0.5em 0; }
              ul, ol { margin: 0.45em 0; padding-left: 1.5em; }
              li { margin: 0.2em 0; }
              pre, code { font-family: ui-monospace, SFMono-Regular, Menlo, monospace; font-size: 12px; }
              code { background: color-mix(in srgb, CanvasText 12%, transparent); padding: 0.1em 0.35em; border-radius: 4px; }
              pre { background: color-mix(in srgb, CanvasText 10%, transparent); padding: 10px 12px; border-radius: 8px; overflow-x: auto; }
              pre code { background: transparent; padding: 0; }
              blockquote {
                margin: 0.6em 0; padding: 0.2em 0 0.2em 0.9em;
                border-left: 3px solid color-mix(in srgb, CanvasText 35%, transparent);
                color: color-mix(in srgb, CanvasText 80%, transparent);
              }
              a { color: LinkText; }
              hr { border: none; border-top: 1px solid color-mix(in srgb, CanvasText 22%, transparent); margin: 1em 0; }
              table { border-collapse: collapse; margin: 0.7em 0; width: 100%; font-size: 12.5px; }
              th, td { border: 1px solid color-mix(in srgb, CanvasText 22%, transparent); padding: 6px 8px; text-align: left; vertical-align: top; }
              th { background: color-mix(in srgb, CanvasText 8%, transparent); font-weight: 600; }
              img { max-width: 100%; height: auto; }
              del { opacity: 0.75; }
            </style></head>
            <body>\(body)</body></html>
            """
                        await MainActor.run {
                webView.loadHTMLString(html, baseURL: nil)
            }
        }
    }

    final class Coordinator: NSObject, WKNavigationDelegate, WKScriptMessageHandler {
        var broker: ScrollSyncBroker?
        var side: ScrollSyncSide = .right
        var lastFingerprint: String = ""

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            MainActor.assumeIsolated { broker?.webDidLoad(side: side) }
        }

        func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
            guard let ratio = message.body as? Double else { return }
            MainActor.assumeIsolated { broker?.webScrolled(ratio, side: side) }
        }
    }
}

// MARK: - Speech

// MARK: - File drop onto editors

struct FileDropHandler {
    var onTargeted: (Bool) -> Void
    var onDrop: (URL) -> Void

    static func fileURL(_ info: NSDraggingInfo) -> URL? {
        (info.draggingPasteboard.readObjects(
            forClasses: [NSURL.self],
            options: [.urlReadingFileURLsOnly: true]
        ) as? [URL])?.first
    }
}

final class FileDropWebView: WKWebView {
    var fileDrop: FileDropHandler?

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        guard let fileDrop, FileDropHandler.fileURL(sender) != nil else { return super.draggingEntered(sender) }
        fileDrop.onTargeted(true)
        return .copy
    }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        guard fileDrop != nil, FileDropHandler.fileURL(sender) != nil else { return super.draggingUpdated(sender) }
        return .copy
    }

    override func draggingExited(_ sender: NSDraggingInfo?) {
        fileDrop?.onTargeted(false)
        super.draggingExited(sender)
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        guard let fileDrop, let url = FileDropHandler.fileURL(sender) else { return super.performDragOperation(sender) }
        fileDrop.onTargeted(false)
        fileDrop.onDrop(url)
        return true
    }
}

final class FileDropTextView: NSTextView {
    var fileDrop: FileDropHandler?

    override var acceptableDragTypes: [NSPasteboard.PasteboardType] {
        super.acceptableDragTypes + [.fileURL]
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        guard let fileDrop, FileDropHandler.fileURL(sender) != nil else { return super.draggingEntered(sender) }
        fileDrop.onTargeted(true)
        return .copy
    }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        guard fileDrop != nil, FileDropHandler.fileURL(sender) != nil else { return super.draggingUpdated(sender) }
        return .copy
    }

    override func draggingExited(_ sender: NSDraggingInfo?) {
        fileDrop?.onTargeted(false)
        super.draggingExited(sender)
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        guard let fileDrop, let url = FileDropHandler.fileURL(sender) else { return super.performDragOperation(sender) }
        fileDrop.onTargeted(false)
        fileDrop.onDrop(url)
        return true
    }
}

// MARK: - Split-pane scroll sync

enum ScrollSyncSide {
    case left, right
    var other: ScrollSyncSide { self == .left ? .right : .left }
}

@MainActor
final class ScrollSyncBroker {
    private final class Pane {
        weak var scroll: NSScrollView?
        weak var web: WKWebView?
        var observer: NSObjectProtocol?
        var webRatio: Double = 0
        var lastPush = Date.distantPast
    }

    private let panes: [ScrollSyncSide: Pane] = [.left: Pane(), .right: Pane()]
    var enabled = false {
        didSet { if enabled { changed(from: .left) } }
    }
    private var syncing = false

    func attach(_ scroll: NSScrollView, side: ScrollSyncSide) {
        let pane = panes[side]!
        pane.web = nil
        guard pane.scroll !== scroll else { return }
        pane.scroll = scroll
        if let o = pane.observer { NotificationCenter.default.removeObserver(o) }
        scroll.contentView.postsBoundsChangedNotifications = true
        pane.observer = NotificationCenter.default.addObserver(
            forName: NSView.boundsDidChangeNotification,
            object: scroll.contentView,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.changed(from: side) }
        }
    }

    func attach(_ web: WKWebView, side: ScrollSyncSide) {
        let pane = panes[side]!
        if pane.web !== web { pane.webRatio = 0 }
        pane.web = web
        pane.scroll = nil
        if let o = pane.observer { NotificationCenter.default.removeObserver(o) }
        pane.observer = nil
    }

    func webDidLoad(side: ScrollSyncSide) {
        if enabled { changed(from: side.other) }
    }

    func webScrolled(_ ratio: Double, side: ScrollSyncSide) {
        let pane = panes[side]!
        pane.webRatio = ratio
        guard Date().timeIntervalSince(pane.lastPush) > 0.2 else { return }
        changed(from: side)
    }

    private func ratio(of side: ScrollSyncSide) -> Double? {
        let pane = panes[side]!
        if let s = pane.scroll {
            let m = max((s.documentView?.bounds.height ?? 0) - s.contentView.bounds.height, 1)
            let r = min(max(s.contentView.bounds.origin.y / m, 0), 1)
            // PDFView 的文档不翻转，y 从底往上数。两边都按「从顶往下」算比例，滚动方向才一致。
            return Self.flipped(s) ? r : 1 - r
        }
        return pane.web != nil ? pane.webRatio : nil
    }

    private static func flipped(_ s: NSScrollView) -> Bool {
        s.documentView?.isFlipped ?? true
    }

    private func changed(from side: ScrollSyncSide) {
        guard enabled, !syncing, let r = ratio(of: side) else { return }
        let dst = panes[side.other]!
        if let s = dst.scroll {
            let m = max((s.documentView?.bounds.height ?? 0) - s.contentView.bounds.height, 0)
            syncing = true
            s.contentView.scroll(to: NSPoint(x: s.contentView.bounds.origin.x, y: (Self.flipped(s) ? r : 1 - r) * m))
            s.reflectScrolledClipView(s.contentView)
            syncing = false
        } else if let web = dst.web {
            dst.lastPush = Date()
            dst.webRatio = r
            web.evaluateJavaScript("window.__korgiScrollTo && window.__korgiScrollTo(\(r))")
        }
    }
}

struct OriginalFileView: NSViewRepresentable {
    let url: URL
    var broker: ScrollSyncBroker

    func makeNSView(context: Context) -> NSView { NSView() }

    func updateNSView(_ host: NSView, context: Context) {
        guard context.coordinator.url != url else { return }
        context.coordinator.url = url
        Self.dismantleNSView(host, coordinator: context.coordinator)
        let view: NSView
        if url.pathExtension.lowercased() == "pdf", let doc = PDFDocument(url: url) {
            let pdf = PDFView()
            pdf.document = doc
            pdf.autoScales = true
            pdf.displayMode = .singlePageContinuous
            pdf.backgroundColor = .clear
            view = pdf
            DispatchQueue.main.async {
                if let scroll = pdf.documentView?.enclosingScrollView { broker.attach(scroll, side: .left) }
            }
        } else {
            let ql = QLPreviewView(frame: host.bounds, style: .normal)!
            ql.previewItem = url as NSURL
            view = ql
        }
        view.frame = host.bounds
        view.autoresizingMask = [.width, .height]
        host.addSubview(view)
    }

    static func dismantleNSView(_ host: NSView, coordinator: Coordinator) {
        for v in host.subviews {
            (v as? QLPreviewView)?.close()
            v.removeFromSuperview()
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator {
        var url: URL?
    }
}

struct SyncableTextEditor: NSViewRepresentable {
    @Binding var text: String
    var isEditable: Bool
    var broker: ScrollSyncBroker
    var fileDrop: FileDropHandler? = nil
    var side: ScrollSyncSide = .left

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = false
        scroll.borderType = .noBorder
        scroll.drawsBackground = false
        UIChrome.configure(scroll)

        let tv = FileDropTextView()
        tv.fileDrop = fileDrop
        tv.isRichText = false
        tv.allowsUndo = true
        tv.isEditable = isEditable
        tv.isSelectable = true
        tv.font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
        tv.textContainerInset = NSSize(width: 4, height: 6)
        tv.backgroundColor = .clear
        tv.drawsBackground = false
        tv.isHorizontallyResizable = false
        tv.isVerticallyResizable = true
        tv.autoresizingMask = [.width]
        tv.textContainer?.widthTracksTextView = true
        tv.textContainer?.containerSize = NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude)
        tv.string = text
        tv.delegate = context.coordinator

        scroll.documentView = tv
        DispatchQueue.main.async { broker.attach(scroll, side: side) }
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        guard let tv = scroll.documentView as? FileDropTextView else { return }
        tv.fileDrop = fileDrop
        tv.isEditable = isEditable
        if tv.string != text {
            let selected = tv.selectedRanges
            tv.string = text
            tv.selectedRanges = selected
        }
        broker.attach(scroll, side: side)
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: SyncableTextEditor
        init(_ parent: SyncableTextEditor) { self.parent = parent }
        func textDidChange(_ notification: Notification) {
            guard let tv = notification.object as? NSTextView else { return }
            parent.text = tv.string
        }
    }
}

