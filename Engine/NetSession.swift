import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Shared URLSession that honors macOS system proxy or a custom HTTP(S)/SOCKS proxy from prefs.
enum NetSession {
    private static let lock = NSLock()
    private static var cached: URLSession?
    private static var cachedStream: URLSession?
    private static var cachedSignature: String = ""
    /// Keychain reads are slow; read the proxy password once per reload.
    private static var cachedPassword: String?

    static var shared: URLSession {
        lock.lock()
        defer { lock.unlock() }
        let sig = signature()
        if cached == nil || sig != cachedSignature {
            cached?.invalidateAndCancel()
            cached = makeSession()
            cachedStream?.finishTasksAndInvalidate()
            cachedStream = nil
            cachedSignature = sig
        }
        return cached!
    }

    /// Long-lived connections such as a 同传 WebSocket. Same proxy, no 60 s cap on the whole task.
    static var streaming: URLSession {
        _ = shared
        lock.lock()
        defer { lock.unlock() }
        if cachedStream == nil {
            cachedStream = makeSession(request: 120, resource: 6 * 3600)
        }
        return cachedStream!
    }

    /// Force rebuild after prefs change.
    static func reload() {
        lock.lock()
        defer { lock.unlock() }
        cached?.invalidateAndCancel()
        cached = nil
        cachedStream?.finishTasksAndInvalidate()
        cachedStream = nil
        cachedSignature = ""
        cachedPassword = nil
    }

    private static func proxyPassword() -> String {
        if let cachedPassword { return cachedPassword }
        let pass = Keychain.get("proxyPassword") ?? ""
        cachedPassword = pass
        return pass
    }

    private static func signature() -> String {
        let c = AppConfig.shared
        return [
            c.proxyMode.rawValue,
            c.proxyType.rawValue,
            c.proxyHost,
            String(c.proxyPort),
            c.proxyUsername,
            proxyPassword(),
        ].joined(separator: "|")
    }

    private static func makeSession(request: TimeInterval = 30, resource: TimeInterval = 60) -> URLSession {
        let cfg = URLSessionConfiguration.default
        cfg.timeoutIntervalForRequest = request
        cfg.timeoutIntervalForResource = resource
        #if os(macOS)
        cfg.waitsForConnectivity = true
        #endif
        cfg.httpAdditionalHeaders = [
            "User-Agent": chromeUA,
            "Accept-Language": "en-US,en;q=0.9,zh-CN;q=0.8,zh;q=0.7",
        ]

        #if os(macOS)
        switch AppConfig.shared.proxyMode {
        case .system:
            // nil → CFNetwork uses System Settings proxy (HTTP/HTTPS/SOCKS).
            cfg.connectionProxyDictionary = nil
        case .off:
            cfg.connectionProxyDictionary = [
                kCFNetworkProxiesHTTPEnable as String: false,
                kCFNetworkProxiesHTTPSEnable as String: false,
                kCFNetworkProxiesSOCKSEnable as String: false,
            ]
        case .custom:
            cfg.connectionProxyDictionary = customProxyDictionary()
        }
        #endif
        return URLSession(configuration: cfg)
    }

    #if os(macOS)
    private static func customProxyDictionary() -> [String: Any] {
        let c = AppConfig.shared
        let host = c.proxyHost.trimmingCharacters(in: .whitespacesAndNewlines)
        let port = c.proxyPort
        guard !host.isEmpty, (1...65535).contains(port) else {
            return [
                kCFNetworkProxiesHTTPEnable as String: false,
                kCFNetworkProxiesHTTPSEnable as String: false,
                kCFNetworkProxiesSOCKSEnable as String: false,
            ]
        }
        var dict: [String: Any] = [:]
        switch c.proxyType {
        case .http:
            dict[kCFNetworkProxiesHTTPEnable as String] = true
            dict[kCFNetworkProxiesHTTPProxy as String] = host
            dict[kCFNetworkProxiesHTTPPort as String] = port
            dict[kCFNetworkProxiesHTTPSEnable as String] = true
            dict[kCFNetworkProxiesHTTPSProxy as String] = host
            dict[kCFNetworkProxiesHTTPSPort as String] = port
            dict[kCFNetworkProxiesSOCKSEnable as String] = false
        case .socks5:
            dict[kCFNetworkProxiesSOCKSEnable as String] = true
            dict[kCFNetworkProxiesSOCKSProxy as String] = host
            dict[kCFNetworkProxiesSOCKSPort as String] = port
            dict[kCFNetworkProxiesHTTPEnable as String] = false
            dict[kCFNetworkProxiesHTTPSEnable as String] = false
        }
        let user = c.proxyUsername.trimmingCharacters(in: .whitespacesAndNewlines)
        let pass = proxyPassword().trimmingCharacters(in: .whitespacesAndNewlines)
        if !user.isEmpty {
            dict[kCFProxyUsernameKey as String] = user
            if !pass.isEmpty {
                dict[kCFProxyPasswordKey as String] = pass
            }
        }
        return dict
    }
    #endif

    static let chromeUA =
        "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.36"

    static func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        var req = request
        if req.value(forHTTPHeaderField: "User-Agent") == nil {
            req.setValue(chromeUA, forHTTPHeaderField: "User-Agent")
        }
        do {
            return try await shared.data(for: req)
        } catch {
            throw mapTransportError(error)
        }
    }

    static func mapTransportError(_ error: Error) -> Error {
        let ns = error as NSError
        if ns.domain == NSURLErrorDomain {
            switch ns.code {
            case NSURLErrorTimedOut:
                return TErr(L("网络超时。若在国内访问 Google，请在偏好设置开启系统代理或填写自定义代理（如 127.0.0.1:7890）。"))
            case NSURLErrorCannotConnectToHost, NSURLErrorNetworkConnectionLost, NSURLErrorNotConnectedToInternet:
                return TErr(String(format: L("无法连接网络（%@）。请检查代理是否已启动，或在偏好设置里调整「网络代理」。"), String(describing: ns.code)))
            default:
                break
            }
        }
        return error
    }
}
