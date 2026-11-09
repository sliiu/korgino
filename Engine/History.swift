import Foundation

struct HistoryProviderResult: Codable, Identifiable {
    var id: String
    var name: String
    var text: String?
    var error: String?
}

struct HistoryEntry: Codable, Identifiable {
    var id: String
    var timestamp: Date
    var source: String
    var direction: String
    var kind: String // select | clipboard | ocr | file | quick | voice | voiceTranslate | voiceInterpret
    var results: [HistoryProviderResult]
    /// Full path of a translated file. The list shows the last component.
    var filePath: String?
    /// 来源应用. Set for 划词, 快捷翻译, and voice that was written into a field.
    var appName: String?
    /// Bundle id of that app. The history row uses it to draw the icon.
    var bundleID: String?
}

enum HistoryStore {
    static let maxEntries = 200
    /// append is load → insert → save; callers come from several tasks at once.
    private static let lock = NSLock()

    private static var dir: URL {
        AppPaths.appSupport
    }
    static var fileURL: URL { dir.appendingPathComponent("history.json") }

    private static var encoder: JSONEncoder {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        return e
    }
    private static var decoder: JSONDecoder {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }

    static func load() -> [HistoryEntry] {
        guard let data = try? Data(contentsOf: fileURL),
              let list = try? decoder.decode([HistoryEntry].self, from: data) else { return [] }
        return list
    }

    static func save(_ entries: [HistoryEntry]) {
        lock.lock()
        defer { lock.unlock() }
        write(entries)
    }

    private static func write(_ entries: [HistoryEntry]) {
        let trimmed = Array(entries.prefix(maxEntries))
        if let data = try? encoder.encode(trimmed) {
            try? data.write(to: fileURL, options: .atomic)
        }
    }

    static func append(source: String, direction: String, kind: String,
                       results: [HistoryProviderResult], filePath: String? = nil,
                       appName: String? = nil, bundleID: String? = nil) {
        lock.lock()
        defer { lock.unlock() }
        var list = load()
        let path = kind == "file" ? nonempty(filePath) : nil
        let remembersApp = kind == "select" || kind == "quick" || kind == "voice" || kind == "voiceTranslate" || kind == "plugin"
        let app = remembersApp ? nonempty(appName) : nil
        let bundle = remembersApp ? nonempty(bundleID) : nil
        let kept = String(source.prefix(4000))
        let now = Date()
        list.removeAll { old in
            old.source == kept
                && now.timeIntervalSince(old.timestamp) < 60
                && (bundle ?? app).map { $0 == (old.bundleID ?? old.appName) } ?? (old.kind == kind && old.appName == nil)
        }
        list.insert(HistoryEntry(
            id: UUID().uuidString,
            timestamp: now,
            source: kept,
            direction: direction,
            kind: kind,
            results: results.map { r in
                var x = r
                if let t = x.text { x.text = String(t.prefix(8000)) }
                return x
            },
            filePath: path,
            appName: app,
            bundleID: bundle
        ), at: 0)
        write(list)
    }

    private static func nonempty(_ raw: String?) -> String? {
        let trimmed = raw?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? nil : trimmed
    }

    static func clear() { save([]) }
}

extension HistoryEntry {
    private enum CodingKeys: String, CodingKey {
        case id, timestamp, source, direction, kind, results, filePath, appName, bundleID
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        timestamp = try c.decode(Date.self, forKey: .timestamp)
        source = try c.decode(String.self, forKey: .source)
        direction = try c.decode(String.self, forKey: .direction)
        kind = try c.decode(String.self, forKey: .kind)
        results = try c.decodeIfPresent([HistoryProviderResult].self, forKey: .results) ?? []
        filePath = try c.decodeIfPresent(String.self, forKey: .filePath)
        appName = try c.decodeIfPresent(String.self, forKey: .appName)
        bundleID = try c.decodeIfPresent(String.self, forKey: .bundleID)
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(timestamp, forKey: .timestamp)
        try c.encode(source, forKey: .source)
        try c.encode(direction, forKey: .direction)
        try c.encode(kind, forKey: .kind)
        try c.encode(results, forKey: .results)
        try c.encodeIfPresent(filePath, forKey: .filePath)
        try c.encodeIfPresent(appName, forKey: .appName)
        try c.encodeIfPresent(bundleID, forKey: .bundleID)
    }
}
