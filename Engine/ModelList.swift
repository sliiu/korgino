import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Fetch & cache OpenAI-compatible `/models` lists per AI profile.
enum ModelListFetcher {
    struct CacheEntry: Codable {
        var models: [String]
        var fetchedAt: Date
        var baseURL: String
    }

    private static let defaultsKey = "aiModelListCache_v1"
    /// 下拉每渲染一次就要问一遍，别每次都把整份 JSON 解一遍。
    private static let lock = NSLock()
    private static var memory: [String: CacheEntry]?

    private static func loadAll() -> [String: CacheEntry] {
        lock.lock()
        defer { lock.unlock() }
        if let memory { return memory }
        let map: [String: CacheEntry]
        if let data = UserDefaults.standard.data(forKey: defaultsKey),
           let decoded = try? JSONDecoder().decode([String: CacheEntry].self, from: data) {
            map = decoded
        } else {
            map = [:]
        }
        memory = map
        return map
    }

    private static func saveAll(_ map: [String: CacheEntry]) {
        lock.lock()
        memory = map
        lock.unlock()
        if let data = try? JSONEncoder().encode(map) {
            UserDefaults.standard.set(data, forKey: defaultsKey)
        }
    }

    static func cached(profileID: String) -> [String] {
        loadAll()[profileID]?.models ?? []
    }

    static func cachedEntry(profileID: String) -> CacheEntry? {
        loadAll()[profileID]
    }

    static func store(profileID: String, baseURL: String, models: [String]) {
        var map = loadAll()
        map[profileID] = CacheEntry(models: models, fetchedAt: Date(), baseURL: baseURL)
        saveAll(map)
    }

    static func clear(profileID: String) {
        var map = loadAll()
        map.removeValue(forKey: profileID)
        saveAll(map)
    }

    /// Normalize base so we can append `/models`.
    static func modelsURL(from baseURL: String) -> URL? {
        var base = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        while base.hasSuffix("/") { base.removeLast() }
        guard !base.isEmpty else { return nil }
        // Some users paste full chat path; strip trailing /chat/completions
        if base.lowercased().hasSuffix("/chat/completions") {
            base = String(base.dropLast("/chat/completions".count))
            while base.hasSuffix("/") { base.removeLast() }
        }
        return URL(string: base + "/models")
    }

    /// GET `{base}/models` with optional Bearer key. Returns sorted unique model ids.
    static func fetch(baseURL: String, apiKey: String, allowEmptyKey: Bool) async throws -> [String] {
        guard let url = modelsURL(from: baseURL) else {
            throw TErr(L("无效的 Base URL"))
        }
        let key = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        if key.isEmpty && !allowEmptyKey {
            throw TErr(L("请先填写 API Key"))
        }
        var req = URLRequest(url: url)
        req.httpMethod = "GET"
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        req.timeoutInterval = 25
        if !key.isEmpty {
            req.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        }
        let (data, resp) = try await NetSession.data(for: req)
        let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
        guard code == 200 else {
            let msg = String(data: data, encoding: .utf8) ?? ""
            throw TErr(String(format: L("拉取模型失败 (%@): %@"), String(describing: code), String(describing: msg.prefix(180))))
        }
        return try parseModelsJSON(data)
    }

    static func parseModelsJSON(_ data: Data) throws -> [String] {
        // OpenAI: { "data": [ { "id": "…" }, … ] }
        // Ollama tags (if someone hits /api/tags): { "models": [ { "name": "…" } ] }
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw TErr(L("模型列表 JSON 无效"))
        }
        var ids: [String] = []
        if let arr = json["data"] as? [[String: Any]] {
            for item in arr {
                if let id = item["id"] as? String, !id.isEmpty { ids.append(id) }
            }
        } else if let arr = json["models"] as? [[String: Any]] {
            for item in arr {
                if let id = item["id"] as? String, !id.isEmpty {
                    ids.append(id)
                } else if let name = item["name"] as? String, !name.isEmpty {
                    ids.append(name)
                }
            }
        } else if let arr = json["data"] as? [String] {
            ids = arr.filter { !$0.isEmpty }
        }
        if ids.isEmpty {
            throw TErr(L("未解析到任何模型（接口可能不兼容 /models）"))
        }
        // Unique, stable sort: prefer shorter / common first then alpha
        var seen = Set<String>()
        var unique: [String] = []
        for id in ids {
            if seen.insert(id).inserted { unique.append(id) }
        }
        return unique.sorted { a, b in
            a.localizedCaseInsensitiveCompare(b) == .orderedAscending
        }
    }
}
