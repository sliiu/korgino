import Foundation

struct FavoriteEntry: Codable, Identifiable, Equatable, Sendable {
    var id: String
    var timestamp: Date
    var source: String
    var translation: String
    var direction: String
    var providerName: String
    var kind: String // select | clipboard | ocr | file | live | manual

    /// Stable key for dedupe / starred checks.
    var contentKey: String {
        Self.makeContentKey(source: source, translation: translation)
    }

    static func makeContentKey(source: String, translation: String) -> String {
        let s = source.trimmingCharacters(in: .whitespacesAndNewlines)
        let t = translation.trimmingCharacters(in: .whitespacesAndNewlines)
        return "\(s)\u{1e}\(t)"
    }
}

enum FavoritesStore {
    static let maxEntries = 500
    private static let lock = NSLock()
    /// contains() runs inside SwiftUI bodies; keep the starred keys in memory.
    private static var keys: Set<String>?

    private static var dir: URL {
        AppPaths.appSupport
    }

    static var fileURL: URL { dir.appendingPathComponent("favorites.json") }

    private static var encoder: JSONEncoder {
        let e = JSONEncoder()
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        e.dateEncodingStrategy = .iso8601
        return e
    }

    private static var decoder: JSONDecoder {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }

    static func load() -> [FavoriteEntry] {
        guard let data = try? Data(contentsOf: fileURL),
              let list = try? decoder.decode([FavoriteEntry].self, from: data) else { return [] }
        return list
    }

    static func save(_ entries: [FavoriteEntry]) {
        let trimmed = Array(entries.prefix(maxEntries))
        if let data = try? encoder.encode(trimmed) {
            try? data.write(to: fileURL, options: .atomic)
        }
        lock.lock()
        keys = Set(trimmed.map(\.contentKey))
        lock.unlock()
    }

    static func contains(source: String, translation: String) -> Bool {
        let key = FavoriteEntry.makeContentKey(source: source, translation: translation)
        lock.lock()
        if let keys {
            lock.unlock()
            return keys.contains(key)
        }
        lock.unlock()
        let loaded = Set(load().map(\.contentKey))
        lock.lock()
        keys = loaded
        lock.unlock()
        return loaded.contains(key)
    }

    @discardableResult
    static func add(
        source: String,
        translation: String,
        direction: String,
        providerName: String,
        kind: String
    ) -> FavoriteEntry? {
        let src = String(source.prefix(4000)).trimmingCharacters(in: .whitespacesAndNewlines)
        let tr = String(translation.prefix(8000)).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !src.isEmpty, !tr.isEmpty else { return nil }
        var list = load()
        let key = FavoriteEntry.makeContentKey(source: src, translation: tr)
        if let idx = list.firstIndex(where: { $0.contentKey == key }) {
            // Bump to top
            var existing = list.remove(at: idx)
            existing.timestamp = Date()
            existing.direction = direction
            existing.providerName = providerName
            existing.kind = kind
            list.insert(existing, at: 0)
            save(list)
            return existing
        }
        let entry = FavoriteEntry(
            id: UUID().uuidString,
            timestamp: Date(),
            source: src,
            translation: tr,
            direction: direction,
            providerName: providerName,
            kind: kind
        )
        list.insert(entry, at: 0)
        save(list)
        return entry
    }

    static func remove(id: String) {
        var list = load()
        list.removeAll { $0.id == id }
        save(list)
    }

    static func remove(source: String, translation: String) {
        let key = FavoriteEntry.makeContentKey(source: source, translation: translation)
        var list = load()
        list.removeAll { $0.contentKey == key }
        save(list)
    }

    static func clear() { save([]) }
}
