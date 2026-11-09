import AppKit
import Foundation
import PDFKit

/// Extract plain / lightly-structured Markdown text from common office & PDF files.
/// OOXML (.docx/.xlsx/.pptx) via /usr/bin/unzip + XML; PDF via PDFKit.
enum OfficeExtract {
    static let officeExtensions: Set<String> = [
        "docx", "doc", "pdf", "xlsx", "xls", "pptx", "ppt", "odt", "ods", "odp"
    ]

    static func supports(_ ext: String) -> Bool {
        officeExtensions.contains(ext.lowercased())
    }

    static func extract(url: URL) throws -> String {
        let ext = url.pathExtension.lowercased()
        switch ext {
        case "pdf":
            return try extractPDF(url: url)
        case "docx":
            return try extractDOCX(url: url)
        case "doc":
            return try extractLegacyWord(url: url)
        case "xlsx":
            return try extractXLSX(url: url)
        case "xls":
            throw TErr(L("暂不支持旧版 .xls，请在 Excel 中另存为 .xlsx 后再试"))
        case "pptx":
            return try extractPPTX(url: url)
        case "ppt":
            throw TErr(L("暂不支持旧版 .ppt，请在 PowerPoint 中另存为 .pptx 后再试"))
        case "odt", "ods", "odp":
            return try extractOpenDocument(url: url, ext: ext)
        default:
            throw TErr(String(format: L("不支持的办公格式：.%@"), String(describing: ext)))
        }
    }

    // MARK: - PDF

    private static func extractPDF(url: URL) throws -> String {
        guard let doc = PDFDocument(url: url) else {
            throw TErr(L("无法打开 PDF 文件"))
        }
        let count = doc.pageCount
        guard count > 0 else { throw TErr(L("PDF 没有页面")) }

        var parts: [String] = []
        for i in 0..<count {
            guard let page = doc.page(at: i) else { continue }
            let s = page.string?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            guard !s.isEmpty else { continue }
            if count > 1 {
                parts.append(String(format: L("## 第 %@ 页\n\n%@"), String(describing: i + 1), String(describing: s)))
            } else {
                parts.append(s)
            }
        }
        let text = parts.joined(separator: "\n\n").trimmingCharacters(in: .whitespacesAndNewlines)
        if text.isEmpty {
            throw TErr(L("该 PDF 未检测到可提取文字（可能是扫描件/纯图片）。请先 OCR，或用「框选 OCR」翻译后再粘贴。"))
        }
        return text
    }

    // MARK: - DOCX

    private static func extractDOCX(url: URL) throws -> String {
        let root = try unzipToTemp(url: url)
        defer { try? FileManager.default.removeItem(at: root) }
        let docXML = root.appendingPathComponent("word/document.xml")
        guard FileManager.default.fileExists(atPath: docXML.path) else {
            if let fb = try? attributedPlainText(url: url, type: .officeOpenXML),
               !fb.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return fb
            }
            throw TErr(L("无效的 .docx（缺少 word/document.xml）"))
        }
        let xml = try String(contentsOf: docXML, encoding: .utf8)
        let text = WordXMLParser.parse(xml).trimmingCharacters(in: .whitespacesAndNewlines)
        if text.isEmpty {
            if let fb = try? attributedPlainText(url: url, type: .officeOpenXML),
               !fb.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return fb
            }
            throw TErr(L("docx 中未找到文字内容"))
        }
        return text
    }

    private static func extractLegacyWord(url: URL) throws -> String {
        if let s = try? attributedPlainText(url: url, type: .docFormat),
           !s.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return s
        }
        if isZipFile(url) {
            return try extractDOCX(url: url)
        }
        throw TErr(L("无法读取 .doc。请用 Word / Pages 另存为 .docx 或 .txt 后再试"))
    }

    // MARK: - XLSX

    private static func extractXLSX(url: URL) throws -> String {
        let root = try unzipToTemp(url: url)
        defer { try? FileManager.default.removeItem(at: root) }

        let shared = SharedStringsParser.parse(
            xmlPath: root.appendingPathComponent("xl/sharedStrings.xml")
        )
        let names = WorkbookParser.sheetNames(
            xmlPath: root.appendingPathComponent("xl/workbook.xml")
        )
        let sheetsDir = root.appendingPathComponent("xl/worksheets")
        guard let sheets = try? FileManager.default.contentsOfDirectory(
            at: sheetsDir, includingPropertiesForKeys: nil
        )
        .filter({ $0.pathExtension.lowercased() == "xml" })
        .sorted(by: { $0.lastPathComponent < $1.lastPathComponent }),
              !sheets.isEmpty else {
            throw TErr(L("无效的 .xlsx（缺少工作表）"))
        }

        var out: [String] = []
        for (idx, sheetURL) in sheets.enumerated() {
            let title = idx < names.count ? names[idx] : "Sheet\(idx + 1)"
            if sheets.count > 1 {
                out.append("## \(title)")
                out.append("")
            }
            let xml = try String(contentsOf: sheetURL, encoding: .utf8)
            let rows = SheetParser.parse(xml: xml, shared: shared)
            if rows.isEmpty {
                out.append(L("_(空工作表)_"))
            } else {
                out.append(contentsOf: rows)
            }
            out.append("")
        }
        let text = out.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        if text.isEmpty { throw TErr(L("xlsx 中未找到文字内容")) }
        return text
    }

    // MARK: - PPTX

    private static func extractPPTX(url: URL) throws -> String {
        let root = try unzipToTemp(url: url)
        defer { try? FileManager.default.removeItem(at: root) }
        let slidesDir = root.appendingPathComponent("ppt/slides")
        guard let slides = try? FileManager.default.contentsOfDirectory(
            at: slidesDir, includingPropertiesForKeys: nil
        )
        .filter({
            let n = $0.lastPathComponent.lowercased()
            return n.hasPrefix("slide") && n.hasSuffix(".xml")
        })
        .sorted(by: { slideIndex($0) < slideIndex($1) }),
              !slides.isEmpty else {
            throw TErr(L("无效的 .pptx（缺少幻灯片）"))
        }

        var out: [String] = []
        var anyText = false
        for (i, slideURL) in slides.enumerated() {
            let xml = try String(contentsOf: slideURL, encoding: .utf8)
            let lines = DrawingMLText.paragraphs(from: xml)
            out.append(String(format: L("## 第 %@ 页"), String(describing: i + 1)))
            out.append("")
            if lines.isEmpty {
                out.append(L("_(无文字)_"))
            } else {
                anyText = true
                out.append(contentsOf: lines)
            }
            out.append("")
        }
        if !anyText { throw TErr(L("pptx 中未找到文字内容")) }
        return out.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func slideIndex(_ url: URL) -> Int {
        let digits = url.deletingPathExtension().lastPathComponent.filter(\.isNumber)
        return Int(digits) ?? 0
    }

    // MARK: - OpenDocument

    private static func extractOpenDocument(url: URL, ext: String) throws -> String {
        let root = try unzipToTemp(url: url)
        defer { try? FileManager.default.removeItem(at: root) }
        let content = root.appendingPathComponent("content.xml")
        guard FileManager.default.fileExists(atPath: content.path) else {
            throw TErr(String(format: L("无效的 .%@（缺少 content.xml）"), String(describing: ext)))
        }
        let xml = try String(contentsOf: content, encoding: .utf8)
        let text = ODFParser.parse(xml).trimmingCharacters(in: .whitespacesAndNewlines)
        if text.isEmpty { throw TErr(String(format: L(".%@ 中未找到文字内容"), String(describing: ext))) }
        return text
    }

    // MARK: - Helpers

    private static func attributedPlainText(url: URL, type: NSAttributedString.DocumentType) throws -> String {
        let data = try Data(contentsOf: url)
        let attr = try NSAttributedString(
            data: data,
            options: [.documentType: type, .characterEncoding: String.Encoding.utf8.rawValue],
            documentAttributes: nil
        )
        return attr.string
    }

    private static func isZipFile(_ url: URL) -> Bool {
        guard let fh = try? FileHandle(forReadingFrom: url) else { return false }
        defer { try? fh.close() }
        let head = fh.readData(ofLength: 4)
        return head.count >= 2 && head[0] == 0x50 && head[1] == 0x4B
    }

    private static func unzipToTemp(url: URL) throws -> URL {
        guard isZipFile(url) else {
            throw TErr(L("文件不是有效的 Office Open XML（ZIP）包"))
        }
        let fm = FileManager.default
        let dest = fm.temporaryDirectory
            .appendingPathComponent("korgi-office-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: dest, withIntermediateDirectories: true)

        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
        proc.arguments = ["-qq", "-o", url.path, "-d", dest.path]
        let errPipe = Pipe()
        proc.standardOutput = FileHandle.nullDevice
        proc.standardError = errPipe
        do {
            try proc.run()
            proc.waitUntilExit()
        } catch {
            try? fm.removeItem(at: dest)
            throw TErr(String(format: L("解压失败：%@"), String(describing: error.localizedDescription)))
        }
        if proc.terminationStatus != 0 {
            let errData = errPipe.fileHandleForReading.readDataToEndOfFile()
            let msg = String(data: errData, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            try? fm.removeItem(at: dest)
            throw TErr(msg.isEmpty ? L("解压失败") : String(format: L("解压失败：%@"), msg))
        }
        return dest
    }
}

// MARK: - Streaming XML helpers (local-name based, namespace-agnostic)

private final class WordXMLParser: NSObject, XMLParserDelegate {
    private var lines: [String] = []
    private var current = ""
    private var style = ""
    private var inT = false
    private var inStyleVal = false
    private var capturingStyle = false
    private var path: [String] = []

    static func parse(_ xml: String) -> String {
        let p = WordXMLParser()
        guard let data = xml.data(using: .utf8) else { return "" }
        let parser = XMLParser(data: data)
        parser.delegate = p
        parser.parse()
        return p.lines.joined(separator: "\n")
    }

    private func local(_ name: String) -> String {
        if let i = name.lastIndex(of: ":") {
            return String(name[name.index(after: i)...])
        }
        return name
    }

    func parser(_ parser: XMLParser, didStartElement elementName: String,
                namespaceURI: String?, qualifiedName: String?,
                attributes attributeDict: [String: String] = [:]) {
        let name = local(elementName)
        path.append(name)
        if name == "p" {
            current = ""
            style = ""
        } else if name == "pStyle" {
            style = attributeDict["w:val"]
                ?? attributeDict["val"]
                ?? attributeDict.values.first
                ?? ""
        } else if name == "t" {
            inT = true
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        if inT { current += string }
    }

    func parser(_ parser: XMLParser, didEndElement elementName: String,
                namespaceURI: String?, qualifiedName: String?) {
        let name = local(elementName)
        if name == "t" {
            inT = false
        } else if name == "p" {
            let trimmed = current.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty {
                lines.append("")
            } else {
                let lower = style.lowercased()
                if lower.contains("heading1") || lower == "title" || lower == "1" {
                    lines.append("# \(trimmed)")
                } else if lower.contains("heading2") || lower == "2" {
                    lines.append("## \(trimmed)")
                } else if lower.contains("heading3") || lower == "3" {
                    lines.append("### \(trimmed)")
                } else if lower.contains("list") || lower.contains("bullet") {
                    lines.append("- \(trimmed)")
                } else {
                    lines.append(trimmed)
                }
            }
            current = ""
            style = ""
        }
        if !path.isEmpty { path.removeLast() }
    }
}

private final class SharedStringsParser: NSObject, XMLParserDelegate {
    private var strings: [String] = []
    private var current = ""
    private var inT = false
    private var inSI = false

    static func parse(xmlPath: URL) -> [String] {
        guard let data = try? Data(contentsOf: xmlPath) else { return [] }
        let p = SharedStringsParser()
        let parser = XMLParser(data: data)
        parser.delegate = p
        parser.parse()
        return p.strings
    }

    private func local(_ name: String) -> String {
        if let i = name.lastIndex(of: ":") { return String(name[name.index(after: i)...]) }
        return name
    }

    func parser(_ parser: XMLParser, didStartElement elementName: String,
                namespaceURI: String?, qualifiedName: String?,
                attributes attributeDict: [String: String] = [:]) {
        let name = local(elementName)
        if name == "si" { inSI = true; current = "" }
        else if name == "t" && inSI { inT = true }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        if inT { current += string }
    }

    func parser(_ parser: XMLParser, didEndElement elementName: String,
                namespaceURI: String?, qualifiedName: String?) {
        let name = local(elementName)
        if name == "t" { inT = false }
        else if name == "si" {
            strings.append(current)
            inSI = false
            current = ""
        }
    }
}

private final class WorkbookParser: NSObject, XMLParserDelegate {
    private var names: [String] = []

    static func sheetNames(xmlPath: URL) -> [String] {
        guard let data = try? Data(contentsOf: xmlPath) else { return [] }
        let p = WorkbookParser()
        let parser = XMLParser(data: data)
        parser.delegate = p
        parser.parse()
        return p.names
    }

    private func local(_ name: String) -> String {
        if let i = name.lastIndex(of: ":") { return String(name[name.index(after: i)...]) }
        return name
    }

    func parser(_ parser: XMLParser, didStartElement elementName: String,
                namespaceURI: String?, qualifiedName: String?,
                attributes attributeDict: [String: String] = [:]) {
        if local(elementName) == "sheet" {
            if let n = attributeDict["name"] { names.append(n) }
        }
    }
}

private final class SheetParser: NSObject, XMLParserDelegate {
    private let shared: [String]
    private var rows: [String] = []
    private var cellVals: [String] = []
    private var cellType = ""
    private var inV = false
    private var inT = false
    private var inInline = false
    private var buf = ""

    static func parse(xml: String, shared: [String]) -> [String] {
        guard let data = xml.data(using: .utf8) else { return [] }
        let p = SheetParser(shared: shared)
        let parser = XMLParser(data: data)
        parser.delegate = p
        parser.parse()
        return p.rows
    }

    init(shared: [String]) { self.shared = shared }

    private func local(_ name: String) -> String {
        if let i = name.lastIndex(of: ":") { return String(name[name.index(after: i)...]) }
        return name
    }

    func parser(_ parser: XMLParser, didStartElement elementName: String,
                namespaceURI: String?, qualifiedName: String?,
                attributes attributeDict: [String: String] = [:]) {
        let name = local(elementName)
        switch name {
        case "row":
            cellVals = []
        case "c":
            cellType = attributeDict["t"] ?? ""
            buf = ""
            inInline = false
        case "v":
            inV = true
            buf = ""
        case "is":
            inInline = true
            buf = ""
        case "t":
            if inInline { inT = true }
        default: break
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        if inV || inT { buf += string }
    }

    func parser(_ parser: XMLParser, didEndElement elementName: String,
                namespaceURI: String?, qualifiedName: String?) {
        let name = local(elementName)
        switch name {
        case "v":
            inV = false
            var value = buf
            if cellType == "s", let idx = Int(buf), idx >= 0, idx < shared.count {
                value = shared[idx]
            } else if cellType.isEmpty || cellType == "n", let d = Double(buf) {
                value = String(format: "%.15g", d)
            }
            // defer append until </c> so inlineStr can win
            if cellType != "inlineStr" {
                // store temporarily in buf for </c>
            }
            buf = value
        case "t":
            inT = false
        case "is":
            inInline = false
        case "c":
            cellVals.append(buf.trimmingCharacters(in: .whitespacesAndNewlines))
            buf = ""
            cellType = ""
        case "row":
            if cellVals.contains(where: { !$0.isEmpty }) {
                var vals = cellVals
                while vals.last?.isEmpty == true { vals.removeLast() }
                rows.append(vals.joined(separator: "\t"))
            }
        default: break
        }
    }
}

private enum DrawingMLText {
    static func paragraphs(from xml: String) -> [String] {
        // Split on </a:p> boundaries and collect <a:t> inside each
        let parts = xml.components(separatedBy: "</a:p>")
        var lines: [String] = []
        let re = try? NSRegularExpression(pattern: #"<a:t(?:\s[^>]*)?>([^<]*)</a:t>"#)
        for part in parts {
            guard let re else { break }
            let ns = NSRange(part.startIndex..., in: part)
            let texts = re.matches(in: part, range: ns).compactMap { m -> String? in
                guard m.numberOfRanges > 1, let r = Range(m.range(at: 1), in: part) else { return nil }
                return String(part[r])
            }
            let line = texts.joined().trimmingCharacters(in: .whitespacesAndNewlines)
            if !line.isEmpty { lines.append(line) }
        }
        if lines.isEmpty, let re {
            let ns = NSRange(xml.startIndex..., in: xml)
            lines = re.matches(in: xml, range: ns).compactMap { m in
                guard m.numberOfRanges > 1, let r = Range(m.range(at: 1), in: xml) else { return nil }
                let s = String(xml[r]).trimmingCharacters(in: .whitespacesAndNewlines)
                return s.isEmpty ? nil : s
            }
        }
        return lines
    }
}

private final class ODFParser: NSObject, XMLParserDelegate {
    private var lines: [String] = []
    private var current = ""
    private var capture = false
    private var kind = "" // p / h / li
    private var headingLevel = 1
    private var inTableRow = false
    private var rowCells: [String] = []
    private var cellBuf = ""
    private var inCell = false

    static func parse(_ xml: String) -> String {
        guard let data = xml.data(using: .utf8) else { return "" }
        let p = ODFParser()
        let parser = XMLParser(data: data)
        parser.delegate = p
        parser.parse()
        return p.lines.joined(separator: "\n")
    }

    private func local(_ name: String) -> String {
        if let i = name.lastIndex(of: ":") { return String(name[name.index(after: i)...]) }
        return name
    }

    func parser(_ parser: XMLParser, didStartElement elementName: String,
                namespaceURI: String?, qualifiedName: String?,
                attributes attributeDict: [String: String] = [:]) {
        let name = local(elementName)
        switch name {
        case "h":
            kind = "h"
            capture = true
            current = ""
            headingLevel = Int(attributeDict["text:outline-level"]
                               ?? attributeDict["outline-level"]
                               ?? "1") ?? 1
        case "p":
            if inCell {
                // accumulate into cell
            } else if kind != "li" {
                kind = "p"
                capture = true
                current = ""
            }
        case "list-item":
            kind = "li"
            capture = true
            current = ""
        case "table-row":
            inTableRow = true
            rowCells = []
        case "table-cell", "covered-table-cell":
            inCell = true
            cellBuf = ""
        default: break
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        if inCell {
            cellBuf += string
        } else if capture {
            current += string
        }
    }

    func parser(_ parser: XMLParser, didEndElement elementName: String,
                namespaceURI: String?, qualifiedName: String?) {
        let name = local(elementName)
        switch name {
        case "h":
            let t = current.trimmingCharacters(in: .whitespacesAndNewlines)
            if !t.isEmpty {
                let hashes = String(repeating: "#", count: min(max(headingLevel, 1), 6))
                lines.append("\(hashes) \(t)")
            }
            capture = false; kind = ""; current = ""
        case "p":
            if inCell { break }
            if kind == "li" { break }
            let t = current.trimmingCharacters(in: .whitespacesAndNewlines)
            if !t.isEmpty { lines.append(t) }
            capture = false; kind = ""; current = ""
        case "list-item":
            let t = current.trimmingCharacters(in: .whitespacesAndNewlines)
            if !t.isEmpty { lines.append("- \(t)") }
            capture = false; kind = ""; current = ""
        case "table-cell", "covered-table-cell":
            rowCells.append(cellBuf.trimmingCharacters(in: .whitespacesAndNewlines))
            inCell = false
            cellBuf = ""
        case "table-row":
            if rowCells.contains(where: { !$0.isEmpty }) {
                lines.append(rowCells.joined(separator: " | "))
            }
            inTableRow = false
            rowCells = []
        default: break
        }
    }
}
