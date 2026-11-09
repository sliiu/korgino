import Foundation

/// 隐私里的一类开关。密钥和个人信息平级，互不嵌套。
enum MaskKind: String, Codable, CaseIterable {
    case secrets, email, phone, idCard, bankCard
    case ssn, passport, iban, birthday, mac, serial
    case home, userHost, ip, bucket

    /// 确认框里给人看的中文名。
    var maskLabel: String {
        switch self {
        case .secrets: return L("密钥或密码")
        case .email: return L("邮箱")
        case .phone: return L("手机号")
        case .idCard: return L("身份证号")
        case .bankCard: return L("银行卡号")
        case .ssn: return L("社会安全号")
        case .passport: return L("护照号")
        case .iban: return L("银行账号")
        case .birthday: return L("生日")
        case .mac: return L("MAC 地址")
        case .serial: return L("序列号")
        case .home: return L("家庭目录")
        case .userHost: return L("用户名和主机")
        case .ip: return L("IP 地址")
        case .bucket: return L("存储桶")
        }
    }
}

/// 一处被换掉的内容。`kind` 为空表示命中的是自定义词表。
struct MaskHit: Sendable {
    var kind: MaskKind?
    var value: String

    var label: String { kind?.maskLabel ?? L("自定义词表") }

    /// 只露头尾，确认框里看得到遮了什么，又不至于把整段秘密再抄一遍。
    var sample: String {
        let chars = Array(value)
        guard chars.count > 10 else { return String(repeating: "•", count: max(chars.count, 3)) }
        return String(chars.prefix(4)) + "…" + String(chars.suffix(2))
    }
}

/// 「发送遮盖版 / 发送原文」的选择。取消另外抛 `MaskDeclined`。
enum MaskChoice: Sendable {
    case masked, original
}

/// 确认框里写的「发到哪里」。
enum MaskDestination {
    static func label(for targets: [TranslateTarget]) -> String {
        targets.map(entry).joined(separator: "、")
    }

    static func entry(_ target: TranslateTarget) -> String {
        switch target {
        case .builtin(let p):
            return String(format: L("%@（服务商服务器）"), p.displayName)
        case .ai(let p):
            let host = URL(string: p.baseURL)?.host ?? p.baseURL
            return host.isEmpty ? p.name : String(format: L("%@（%@）"), p.name, host)
        }
    }
}

/// 遮盖：翻译、释义、对话发出去之前，把命中的私密内容换成占位符，回来再填回。
/// 占位符和原文的对照只留在这次进程的内存里。这一类的开关关着时，原文照发。
struct SecretCoverError: LocalizedError {
    var errorDescription: String? { "遮盖没有完成，这句话没有发出去" }
}

enum SecretCover {
    #if SECRET_COVER_CHECK
    static var enabledOverride: Bool? = true
    #else
    static var enabledOverride: Bool?
    #endif

    private static let lock = NSLock()
    private static var values: [String: String] = [:] // placeholder → secret
    /// 插入顺序。占位符表是进程级的，长会话里只增不减；到头了就丢最早的那批。
    private static var order: [String] = []
    /// `restore` 每次都要按长度从长到短替换，排一次就够。
    private static var sortedCache: [(token: String, value: String)]?
    private static let maxEntries = 4096
    private static let hmacKey = Digest.randomBytes(32)
    private static let alphabet = Array("ABCDEFGHJKLMNPQRSTUVWXYZ234567")

    /// 记下一条占位符。调用方持有 `lock`。
    private static func store(_ token: String, _ value: String) {
        if values[token] == nil { order.append(token) }
        values[token] = value
        sortedCache = nil
        if order.count > maxEntries {
            let drop = order.count - maxEntries
            for old in order.prefix(drop) { values.removeValue(forKey: old) }
            order.removeFirst(drop)
        }
    }

    /// 清空。这一类的开关全关掉、或者用户要求重新开始时用。
    static func forgetAll() {
        lock.lock()
        values.removeAll()
        order.removeAll()
        sortedCache = nil
        lock.unlock()
    }

    struct Cover: Sendable {
        var text: String
        var changed: Bool
        /// Ranges in the original text that were replaced. Empty when nothing was covered.
        var ranges: [NSRange] = []
        /// 每一处命中的类别和原样。确认框拿它说清楚遮的是什么。
        var hits: [MaskHit] = []
    }

    private struct Rule {
        var kind: MaskKind
        var regex: NSRegularExpression
        var group: Int
        var ok: (String) -> Bool
        var contextOK: ((NSString, NSRange) -> Bool)? = nil
        var boundExtra: String = ""
        /// 每个捕获组各算一处，例如 user@host 里的用户名和主机名。
        var splitGroups: Bool = false
        var groupOK: ((Int, String) -> Bool)? = nil
        /// 把匹配收成真正的那一段；返回 nil 表示这处不算。
        var tighten: ((NSString, NSRange) -> NSRange?)? = nil
    }

    private static let rulesLock = NSLock()
    private static var compiled: [Rule]?

    static func mask(_ text: String) throws -> String {
        try cover(text).text
    }

    static func cover(_ text: String) throws -> Cover {
        guard anythingOn() else { return Cover(text: text, changed: false, ranges: []) }
        do {
            let (masked, ranges, hits) = try maskLocked(text)
            let changed = masked != text
            return Cover(text: masked, changed: changed, ranges: changed ? ranges : [], hits: changed ? hits : [])
        } catch {
            throw SecretCoverError()
        }
    }

    static func restore(_ text: String) -> String {
        lock.lock()
        let known: [(token: String, value: String)]
        if let cached = sortedCache {
            known = cached
        } else {
            // Longest first, so a token that contains another one is replaced whole.
            let sorted = values.sorted { $0.key.count > $1.key.count }.map { (token: $0.key, value: $0.value) }
            sortedCache = sorted
            known = sorted
        }
        lock.unlock()
        guard !known.isEmpty else { return text }
        var out = text
        for (token, value) in known {
            if token.hasPrefix("⟦") {
                if out.contains(token) {
                    out = out.replacingOccurrences(of: token, with: value)
                }
                let inner = innerToken(token)
                guard !inner.isEmpty else { continue }
                out = replacingBounded(inner, with: value, in: out)
            } else {
                out = out.replacingOccurrences(of: token, with: value)
            }
        }
        return out
    }

    static func anythingOn() -> Bool {
        if let enabledOverride { return enabledOverride }
        #if SECRET_COVER_CHECK
        return true
        #else
        return AppConfig.shared.maskPrefs.anythingOn
        #endif
    }

    private static func allows(_ kind: MaskKind) -> Bool {
        if let enabledOverride { return enabledOverride }
        #if SECRET_COVER_CHECK
        return true
        #else
        return AppConfig.shared.maskPrefs.allows(kind)
        #endif
    }

    private static func maskLocked(_ text: String) throws -> (String, [NSRange], [MaskHit]) {
        let ns = text as NSString
        let full = NSRange(location: 0, length: ns.length)
        var hits: [Hit] = []
        for rule in try compiledRules() where allows(rule.kind) {
            rule.regex.enumerateMatches(in: text, range: full) { match, _, _ in
                guard let match else { return }
                var picks: [(Int, NSRange)] = []
                if rule.splitGroups || rule.group < 0 {
                    for g in 1..<match.numberOfRanges {
                        let r = match.range(at: g)
                        guard r.location != NSNotFound, r.length > 0 else { continue }
                        picks.append((g, r))
                        if rule.group < 0, !rule.splitGroups { break }
                    }
                } else {
                    let r = match.range(at: rule.group)
                    if r.location != NSNotFound, r.length > 0 { picks = [(rule.group, r)] }
                }
                for (g, picked) in picks {
                    var range = picked
                    if let tighten = rule.tighten {
                        guard let next = tighten(ns, range) else { continue }
                        range = next
                    }
                    guard range.location != NSNotFound, range.length > 0,
                          range.location + range.length <= ns.length else { continue }
                    let value = ns.substring(with: range)
                    let accepted = rule.groupOK?(g, value) ?? rule.ok(value)
                    guard accepted, rule.contextOK?(ns, range) ?? true,
                          bounded(ns, range, extra: rule.boundExtra) else { continue }
                    hits.append(Hit(range: range, value: value, replacement: nil, kind: rule.kind))
                }
            }
        }
        hits.append(contentsOf: wordHits(ns))
        return render(ns, hits: hits)
    }

    private struct Hit {
        var range: NSRange
        var value: String
        var replacement: String?
        /// 自定义词表命中的没有类别。
        var kind: MaskKind?
    }

    private static func render(_ ns: NSString, hits: [Hit]) -> (String, [NSRange], [MaskHit]) {
        let ordered = hits.sorted { a, b in
            if a.range.location != b.range.location { return a.range.location < b.range.location }
            return a.range.length > b.range.length
        }
        var out = ""
        var ranges: [NSRange] = []
        var matched: [MaskHit] = []
        var cursor = 0
        for hit in ordered {
            if hit.range.location < cursor { continue }
            let end = hit.range.location + hit.range.length
            guard end <= ns.length else { continue }
            out += ns.substring(with: NSRange(location: cursor, length: hit.range.location - cursor))
            let stand = standIn(for: hit.value, preferred: hit.replacement)
            if stand != hit.value {
                ranges.append(hit.range)
                matched.append(MaskHit(kind: hit.kind, value: hit.value))
            }
            out += stand
            cursor = end
        }
        out += ns.substring(from: cursor)
        return (out, ranges, matched)
    }

    /// 留空用占位符。填了就用这段；这段已经被另一条原文占用时，后面加数字。
    private static func standIn(for value: String, preferred: String?) -> String {
        let wanted = preferred?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if wanted.isEmpty || wanted == value { return wanted.isEmpty ? placeholder(for: value) : value }
        lock.lock()
        var n = 1
        var candidate = wanted
        while n <= 20 {
            let owner = values[candidate]
            if owner == nil || owner == value {
                store(candidate, value)
                lock.unlock()
                return candidate
            }
            n += 1
            candidate = "\(wanted)\(n)"
        }
        lock.unlock()
        return placeholder(for: value)
    }

    private static func isTokenChar(_ c: unichar) -> Bool {
        (c >= 48 && c <= 57) || (c >= 65 && c <= 90) || (c >= 97 && c <= 122) || c == 95 || c == 45
    }

    private static func bounded(_ ns: NSString, _ range: NSRange, extra: String = "") -> Bool {
        let before = range.location > 0 ? ns.character(at: range.location - 1) : 0
        let afterIndex = range.location + range.length
        let after = afterIndex < ns.length ? ns.character(at: afterIndex) : 0
        func sticks(_ c: unichar) -> Bool {
            isTokenChar(c) || extra.utf16.contains(c)
        }
        if before != 0, sticks(before) { return false }
        if after != 0, sticks(after) { return false }
        return true
    }

    private static func placeholder(for value: String) -> String {
        let mac = Digest.hmacSHA256(Data(value.utf8), key: hmacKey)
        var token = "⟦"
        for byte in mac.prefix(8) {
            token.append(alphabet[Int(byte) % alphabet.count])
        }
        token.append("⟧")
        lock.lock()
        if let existing = values[token], existing != value {
            // 8 个字符撞上了另一条秘密：换一个仍由这条秘密决定的后缀。
            token = String(token.dropLast()) + "X⟧"
        }
        store(token, value)
        lock.unlock()
        return token
    }

    private static func innerToken(_ placeholder: String) -> String {
        guard placeholder.hasPrefix("⟦"), placeholder.hasSuffix("⟧"), placeholder.count > 2 else { return "" }
        return String(placeholder.dropFirst().dropLast())
    }

    /// 译文把括号弄丢时，仍按中间那段填回。只替换左右不是字母数字的那一处。
    private static func replacingBounded(_ token: String, with value: String, in text: String) -> String {
        var out = ""
        var rest = text[text.startIndex...]
        while let range = rest.range(of: token, options: .caseInsensitive) {
            let beforeOK = range.lowerBound == rest.startIndex || !isWord(rest[rest.index(before: range.lowerBound)])
            let afterOK = range.upperBound == rest.endIndex || !isWord(rest[range.upperBound])
            out += rest[..<range.lowerBound]
            if beforeOK && afterOK {
                out += value
            } else {
                out += token
            }
            rest = rest[range.upperBound...]
        }
        out += rest
        return out
    }

    private static func isWord(_ c: Character) -> Bool {
        c.isLetter || c.isNumber || c == "_"
    }

    private static func rules() throws -> [Rule] {
        let secret = #"[A-Za-z0-9_\-./+=~!@#%^&*]"#
        let patterns: [(MaskKind, String, Int, (String) -> Bool)] = [
            (.secrets, #"-----BEGIN (?:[A-Z0-9]+ )*PRIVATE KEY(?: BLOCK)?-----[\s\S]+?-----END (?:[A-Z0-9]+ )*PRIVATE KEY(?: BLOCK)?-----"#, 0, { _ in true }),
            (.secrets, #"sk-(?:ant-|proj-|or-|svcacct-|admin-)?[A-Za-z0-9_-]{20,}"#, 0, { _ in true }),
            (.secrets, #"[a-z]{2,4}_sk_[A-Za-z0-9_-]{20,}"#, 0, secretValue),
            (.secrets, #"(?:gh[pousr]_[A-Za-z0-9]{30,}|github_pat_[A-Za-z0-9_]{40,}|glpat-[A-Za-z0-9_-]{20,})"#, 0, { _ in true }),
            (.secrets, #"AIza[0-9A-Za-z_-]{35}"#, 0, { _ in true }),
            (.secrets, #"xox[abposr]-[0-9A-Za-z-]{10,}"#, 0, { _ in true }),
            (.secrets, #"(?:sk|rk)_live_[0-9A-Za-z]{20,}"#, 0, { _ in true }),
            (.secrets, #"(?:AKIA|ASIA)[0-9A-Z]{16}"#, 0, { _ in true }),
            (.secrets, #"(?:hf_[A-Za-z0-9]{30,}|gsk_[A-Za-z0-9]{40,}|xai-[A-Za-z0-9]{40,})"#, 0, { _ in true }),
            (.secrets, #"eyJ[A-Za-z0-9_-]{8,}\.eyJ[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]{8,}"#, 0, { _ in true }),
            (.secrets, "[A-Za-z][A-Za-z0-9+.-]*://[^\\s:@/?#\"']*:(" + secret + "{3,})@", 1, { !$0.hasPrefix("$") }),
            (.secrets, "(?i)(?:password|passwd|secret|token|api[_-]?key|access[_-]?key|private[_-]?key|credential)[ \\t]*[:=][ \\t]*['\"]?(" + secret + "{8,})", 1, secretValue),
            (.secrets, "(?:密码|密碼|口令|密钥|密鑰|秘钥|私钥|私鑰|令牌|金鑰)[ \\t]*[是为為:：=][ \\t]*['\"“]?(" + secret + "{4,64})", 1, { $0.count >= 4 && !$0.hasPrefix("$") }),
            (.email, #"[A-Za-z0-9._%+-]+@[A-Za-z0-9-]+(?:\.[A-Za-z0-9-]+)*\.[A-Za-z]{2,}"#, 0, realEmail),
            (.idCard, #"[1-9]\d{5}(?:18|19|20)\d{2}(?:0[1-9]|1[0-2])(?:0[1-9]|[12]\d|3[01])\d{3}[\dXx]"#, 0, chineseID),
            (.phone, #"(?:\+?86[- ]?)?1[3-9]\d{9}"#, 0, { _ in true }),
            (.bankCard, #"[3-6]\d{3}(?:[ -]?\d{4}){2,3}(?:[ -]?\d{1,3})?"#, 0, luhn),
        ]
        return try patterns.map { kind, pattern, group, ok in
            Rule(kind: kind, regex: try NSRegularExpression(pattern: pattern), group: group, ok: ok)
        } + (try moreRules())
    }

    private static func compiledRules() throws -> [Rule] {
        rulesLock.lock()
        defer { rulesLock.unlock() }
        if let compiled { return compiled }
        let built = try rules()
        compiled = built
        return built
    }

    private static func secretValue(_ value: String) -> Bool {
        let hasLetter = value.contains { $0.isLetter }
        let hasDigit = value.contains { $0.isNumber }
        return hasLetter && hasDigit && !value.hasPrefix("process.env") && !value.hasPrefix("os.")
    }

    private static func realEmail(_ value: String) -> Bool {
        guard let at = value.lastIndex(of: "@") else { return false }
        if value[..<at].caseInsensitiveCompare("git") == .orderedSame { return false }
        let host = value[value.index(after: at)...].lowercased()
        let blocked = ["example.com", "example.org", "example.net", "localhost"]
        if blocked.contains(host) { return false }
        for suffix in [".test", ".invalid", ".example"] where host.hasSuffix(suffix) || host == String(suffix.dropFirst()) {
            return false
        }
        let ext = host.split(separator: ".").last.map(String.init) ?? ""
        let files: Set<String> = ["png", "jpg", "jpeg", "gif", "webp", "svg", "pdf", "mp4", "json", "md", "txt"]
        if files.contains(ext) { return false }
        return !host.hasPrefix("noreply")
    }

    private static func chineseID(_ value: String) -> Bool {
        guard value.count == 18 else { return false }
        let chars = Array(value)
        let weights = [7, 9, 10, 5, 8, 4, 2, 1, 6, 3, 7, 9, 10, 5, 8, 4, 2]
        var sum = 0
        for i in 0..<17 {
            guard let n = chars[i].wholeNumberValue else { return false }
            sum += n * weights[i]
        }
        let check = Array("10X98765432")
        return String(chars[17]).uppercased() == String(check[sum % 11])
    }

    private static func luhn(_ value: String) -> Bool {
        let digits = value.compactMap(\.wholeNumberValue)
        guard (15...19).contains(digits.count) else { return false }
        var sum = 0
        for (i, d) in digits.reversed().enumerated() {
            var n = d
            if i % 2 == 1 {
                n *= 2
                if n > 9 { n -= 9 }
            }
            sum += n
        }
        return sum % 10 == 0
    }

    private static func wordHits(_ ns: NSString) -> [Hit] {
        #if SECRET_COVER_CHECK
        return []
        #else
        return customHitRanges(ns, entries: AppConfig.shared.maskPrefs.entries)
        #endif
    }

    static func customMatched(in text: String, entries: [MaskEntry]) -> [String] {
        let ns = text as NSString
        return customHitRanges(ns, entries: entries).map { ns.substring(with: $0.range) }
    }

    static func applyCustom(in text: String, entries: [MaskEntry]) -> String {
        let ns = text as NSString
        return render(ns, hits: customHitRanges(ns, entries: entries)).0
    }

    private static func customHitRanges(_ ns: NSString, entries: [MaskEntry]) -> [Hit] {
        let text = ns as String
        let full = NSRange(location: 0, length: ns.length)
        var hits: [Hit] = []
        for entry in entries {
            if let word = entry.literal {
                let ascii = word.unicodeScalars.allSatisfy(\.isASCII)
                let options: NSString.CompareOptions = entry.ignoreCase ? [.caseInsensitive] : []
                var search = full
                while search.length > 0 {
                    let found = ns.range(of: word, options: options, range: search)
                    if found.location == NSNotFound { break }
                    if !ascii || bounded(ns, found) {
                        hits.append(Hit(range: found, value: ns.substring(with: found), replacement: entry.standIn))
                    }
                    let next = found.location + max(found.length, 1)
                    if next >= ns.length { break }
                    search = NSRange(location: next, length: ns.length - next)
                }
            } else if let regex = entry.regex() {
                regex.enumerateMatches(in: text, range: full) { match, _, _ in
                    guard let match else { return }
                    let range = match.range
                    guard range.location != NSNotFound, range.length > 0 else { return }
                    hits.append(Hit(range: range, value: ns.substring(with: range), replacement: entry.standIn))
                }
            }
        }
        return hits
    }

    private static func moreRules() throws -> [Rule] {
        func make(_ kind: MaskKind, _ pattern: String, group: Int = 0, extra: String = "",
                  split: Bool = false, ok: @escaping (String) -> Bool = { _ in true },
                  groupOK: ((Int, String) -> Bool)? = nil,
                  context: ((NSString, NSRange) -> Bool)? = nil,
                  tighten: ((NSString, NSRange) -> NSRange?)? = nil) throws -> Rule {
            Rule(kind: kind,
                 regex: try NSRegularExpression(pattern: pattern),
                 group: group, ok: ok, contextOK: context, boundExtra: extra,
                 splitGroups: split, groupOK: groupOK, tighten: tighten)
        }
        let sep = #"["']?[ \t]*(?:[:#=：][ \t]*)?"#
        let months = #"(?i:jan|feb|mar|apr|may|jun|jul|aug|sep|oct|nov|dec)[a-z]*\.?"#
        let pathName = #"[^\s/\\:*?\"'<>|,;()\[\]{}$%]{1,64}"#
        let hostRe = #"[A-Za-z0-9][A-Za-z0-9-]{0,62}(?:\.[A-Za-z0-9-]{1,63})*"#
        let unixUser = #"[a-z_][a-z0-9_.-]{0,31}"#
        let lineUser = #"[A-Za-z0-9_][A-Za-z0-9._-]{0,31}"#
        let bucketRe = #"[A-Za-z0-9](?:[A-Za-z0-9._-]{0,61}[A-Za-z0-9])?"#
        let birthday = #"(?:(?i:\bdate[ \t]+of[ \t]+birth|\bbirth[ \t_-]?date|\bbirthday|\bdob\b|\bd\.o\.b\.?|\bborn(?:[ \t]+on)?|\bgeburtsdatum|\bgeboren(?:[ \t]+am)?)|生日|出生日期|出生年月日|出生于|出生於|出生|誕生日|生年月日)"# + sep + #"(?:(?i:is|was)[ \t]+|是[ \t]*|为[ \t]*|為[ \t]*|は[ \t]*)?["']?"# + #"(\d{4}[-/.]\d{1,2}[-/.]\d{1,2}|\d{4}[ \t]*年[ \t]*\d{1,2}[ \t]*月[ \t]*\d{1,2}[ \t]*日?|\d{1,2}[-/.]\d{1,2}[-/.]\d{4}|"# + months + #"[ \t]+\d{1,2}(?:st|nd|rd|th)?,?[ \t]+\d{4}|\d{1,2}(?:st|nd|rd|th)?[ \t]+"# + months + #",?[ \t]+\d{4})"#
        let passport = #"(?i:\bpassport(?:[ \t]*(?:no\.?|number|num|#))?|\breisepass(?:nummer)?)\#(sep)(?:(?i:is|was)[ \t]+)?["']?([A-Z0-9]{6,9})|(?:护照(?:号码|号)?|護照(?:號碼|号码|番号)?|パスポート(?:番号)?)[ \t]*(?:[:：=][ \t]*)?(?:是[ \t]*|は[ \t]*)?["']?([A-Z0-9]{6,9})"#
        let serial = #"(?i:\bserial[ \t_-]?(?:number|num|no\.?|#)?|\bs/n|\bsn)(?:[ \t]*\([^)\n]{1,20}\))?["']?[ \t]*[:#=：][ \t]*["']?([A-Za-z0-9][A-Za-z0-9-]{4,39})|(?:序列号|序列號|シリアル番号|(?i:seriennummer))[ \t]*[:：=]?[ \t]*["']?([A-Za-z0-9][A-Za-z0-9-]{4,39})"#
        let homeUnix = #"(?:^|[^A-Za-z0-9_.~/\\-])(?:file://)?(?:/mnt/[a-z])?/(?:Users|home)/(\#(pathName))"#
        let homeWin = #"(?i)(?:^|[^A-Za-z0-9])[A-Za-z]:(?:\\{1,4}|/)(?:users|documents and settings)(?:\\{1,4}|/)(?:([A-Za-z0-9._-]+(?: [A-Za-z0-9._-]+)+)(?:\\|/)|(\#(pathName)))"#
        let prompt = #"(?m)(?:^|[^A-Za-z0-9._%+-])(\#(unixUser))@(\#(hostRe))(?::[~/]|:[ \t]*$|[ \t]+[~/]|[ \t]*[$%#>][ \t]|[ \t]*[$%#>]$)"#
        let ssh = #"(?i:\b(?:ssh|scp|sftp|rsync|mosh|ssh-copy-id))\b[^\n@]{0,80}?[ \t"'](\#(unixUser))@(\#(hostRe))"#
        let hostLine = #"(?m)^[ \t]*["']?(?:(?i:host[ \t_-]?name|computer[ \t_-]?name|machine[ \t_-]?name|device[ \t_-]?name)|主机名|主機名|計算機名|コンピュータ名|コンピューター名)["']?[ \t]*[:=：][ \t]*(?:["'](\#(hostRe))["'][ \t]*[,;]?|(\#(hostRe)))[ \t]*$|^[ \t]+HostName[ \t]+(\#(hostRe))[ \t]*$"#
        let userLine = #"(?m)^[ \t]*["']?(?:(?i:user[ \t_-]?name|login[ \t_-]?name|user|login|logname)|用户名|用戶名|ユーザー名)["']?[ \t]*[:=：][ \t]*(?:["'](\#(lineUser))["'][ \t]*[,;]?|(\#(lineUser)))[ \t]*$|^[ \t]+User[ \t]+(\#(lineUser))[ \t]*$"#
        let bucketScheme = #"(?i:\b(?:s3a?|s3n|gs|oss|cosn?|obs|r2|ks3|bos|tos|az|azure|wasbs?|abfss?)://)(\#(bucketRe))(?:@([a-z0-9]{3,24})\.(?:blob|dfs)\.core\.windows\.net)?"#
        let bucketHost = #"(?:^|[^A-Za-z0-9.-])(\#(bucketRe))\.(?:s3(?:[.-](?:dualstack\.)?[a-z0-9-]+)?\.amazonaws\.com(?:\.cn)?|s3-accelerate\.amazonaws\.com|storage\.googleapis\.com|oss-[a-z0-9-]+\.aliyuncs\.com|cos\.[a-z0-9-]+\.myqcloud\.com|obs\.[a-z0-9-]+\.myhuaweicloud\.com|r2\.cloudflarestorage\.com|(?:blob|dfs)\.core\.windows\.net|[a-z0-9-]+\.digitaloceanspaces\.com|tos-[a-z0-9-]+\.volces\.com)"#
        let bucketPath = #"(?:^|[^A-Za-z0-9.-])(?:s3(?:[.-](?:dualstack\.)?[a-z0-9-]+)?\.amazonaws\.com(?:\.cn)?|storage\.googleapis\.com|storage\.cloud\.google\.com|[a-z0-9]{3,24}\.blob\.core\.windows\.net|oss-[a-z0-9-]+\.aliyuncs\.com|[a-z0-9-]+\.digitaloceanspaces\.com)/(\#(bucketRe))"#
        let pair: (Int, String) -> Bool = { i, v in i == 1 ? userOK(v) : hostOK(v) }
        return [
            try make(.ssn, #"\d{3}-\d{2}-\d{4}"#, extra: "-", ok: ssnOK),
            try make(.ssn, #"(?i:\bssn|\bsocial[ \t]+security(?:[ \t]+(?:number|no\.?|#))?)\#(sep)(?:(?i:is)[ \t]+)?["']?(\d{9}|\d{3} \d{2} \d{4})"#, group: 1, ok: ssnOK),
            try make(.passport, passport, group: -1, ok: passportOK),
            try make(.iban, #"[A-Z]{2}\d{2}(?:[A-Z0-9]{11,30}|(?: [A-Z0-9]{4}){2,7}(?: [A-Z0-9]{1,3})?)"#, tighten: ibanTighten),
            try make(.birthday, birthday, group: 1, ok: dateOK),
            try make(.mac, #"[0-9A-Fa-f]{2}(?::[0-9A-Fa-f]{2}){5}|[0-9A-Fa-f]{2}(?:-[0-9A-Fa-f]{2}){5}"#, extra: ":-", ok: macOK),
            try make(.serial, serial, group: -1, extra: "-", ok: serialOK),
            try make(.home, homeUnix, group: 1, tighten: homeTighten),
            try make(.home, homeWin, group: -1, tighten: homeTighten),
            try make(.userHost, prompt, split: true, groupOK: pair),
            try make(.userHost, ssh, split: true, groupOK: pair),
            try make(.userHost, hostLine, group: -1, ok: lineHostOK),
            try make(.userHost, userLine, group: -1, ok: lineUserOK),
            try make(.ip, #"(?:25[0-5]|2[0-4]\d|1\d\d|[1-9]?\d)(?:\.(?:25[0-5]|2[0-4]\d|1\d\d|[1-9]?\d)){3}"#, context: ipv4Context),
            try make(.ip, #"[0-9A-Fa-f]{1,4}(?::[0-9A-Fa-f]{0,4}){2,7}"#, extra: ":_", ok: ipv6OK),
            try make(.bucket, bucketScheme, split: true, groupOK: { _, v in bucketOK(v) }),
            try make(.bucket, bucketHost, group: 1, ok: bucketOK),
            try make(.bucket, bucketPath, group: 1, ok: bucketOK),
        ]
    }

    private static func ssnOK(_ value: String) -> Bool {
        let d = value.filter(\.isNumber)
        guard d.count == 9 else { return false }
        let area = d.prefix(3)
        let group = d.dropFirst(3).prefix(2)
        let serial = d.suffix(4)
        if area == "000" || area == "666" || d.first == "9" || group == "00" || serial == "0000" { return false }
        if ["123456789", "078051120", "219099999"].contains(d) { return false }
        return Set(d).count > 1
    }

    private static func passportOK(_ value: String) -> Bool {
        value.filter(\.isNumber).count >= 5 && Set(value).count > 1
    }

    private static let ibanLen: [String: Int] = [
        "AD": 24, "AE": 23, "AL": 28, "AT": 20, "AZ": 28, "BA": 20, "BE": 16, "BG": 22, "BH": 22, "BI": 27, "BR": 29, "BY": 28,
        "CH": 21, "CR": 22, "CY": 28, "CZ": 24, "DE": 22, "DJ": 27, "DK": 18, "DO": 28, "EE": 20, "EG": 29, "ES": 24, "FI": 18,
        "FK": 18, "FO": 18, "FR": 27, "GB": 22, "GE": 22, "GI": 23, "GL": 18, "GR": 27, "GT": 28, "HN": 28, "HR": 21, "HU": 28,
        "IE": 22, "IL": 23, "IQ": 23, "IS": 26, "IT": 27, "JO": 30, "KW": 30, "KZ": 20, "LB": 28, "LC": 32, "LI": 21, "LT": 20,
        "LU": 20, "LV": 21, "LY": 25, "MC": 27, "MD": 24, "ME": 22, "MK": 19, "MN": 20, "MR": 27, "MT": 31, "MU": 30, "NI": 28,
        "NL": 18, "NO": 15, "OM": 23, "PK": 24, "PL": 28, "PS": 29, "PT": 25, "QA": 29, "RO": 24, "RS": 22, "RU": 33, "SA": 24,
        "SC": 31, "SD": 18, "SE": 24, "SI": 19, "SK": 24, "SM": 27, "SO": 23, "ST": 25, "SV": 28, "TL": 23, "TN": 24, "TR": 26,
        "UA": 29, "VA": 22, "VG": 24, "XK": 20, "YE": 30,
    ]

    private static func ibanOK(_ raw: String) -> Bool {
        let v = raw.replacingOccurrences(of: " ", with: "")
        guard v.count >= 4, let n = ibanLen[String(v.prefix(2))], n == v.count else { return false }
        let moved = v.dropFirst(4) + v.prefix(4)
        var m = 0
        for c in moved.unicodeScalars {
            let u = c.value
            if u >= 48 && u <= 57 {
                m = (m * 10 + Int(u - 48)) % 97
            } else if u >= 65 && u <= 90 {
                m = (m * 100 + Int(u - 65) + 10) % 97
            } else {
                return false
            }
        }
        return m == 1
    }

    private static func ibanTighten(_ ns: NSString, _ range: NSRange) -> NSRange? {
        var end = range.location + range.length
        let start = range.location
        while end > start {
            let slice = ns.substring(with: NSRange(location: start, length: end - start))
            if ibanOK(slice) { return NSRange(location: start, length: end - start) }
            var i = end - 1
            var found = false
            while i > start {
                if ns.character(at: i) == 32 {
                    end = i
                    found = true
                    break
                }
                i -= 1
            }
            if !found { return nil }
        }
        return nil
    }

    private static func dateOK(_ value: String) -> Bool {
        let nums = value.split(whereSeparator: { !$0.isNumber }).compactMap { Int($0) }
        let yearAgo = Calendar.current.date(byAdding: .year, value: -1, to: Date()) ?? Date()
        func valid(_ y: Int, _ m: Int, _ d: Int) -> Bool {
            guard (1900...2099).contains(y), (1...12).contains(m), (1...31).contains(d) else { return false }
            var parts = DateComponents()
            parts.year = y
            parts.month = m
            parts.day = d
            guard let date = Calendar.current.date(from: parts) else { return false }
            let back = Calendar.current.dateComponents([.year, .month, .day], from: date)
            guard back.year == y, back.month == m, back.day == d else { return false }
            return date < yearAgo
        }
        if nums.count == 2 {
            let lower = value.lowercased()
            let names = ["jan", "feb", "mar", "apr", "may", "jun", "jul", "aug", "sep", "oct", "nov", "dec"]
            guard let month = names.firstIndex(where: { lower.contains($0) }) else { return false }
            var day = nums[0]
            var year = nums[1]
            if String(nums[0]).count == 4 { day = nums[1]; year = nums[0] }
            return valid(year, month + 1, day)
        }
        guard nums.count == 3 else { return false }
        if String(nums[0]).count == 4 { return valid(nums[0], nums[1], nums[2]) }
        return valid(nums[2], nums[0], nums[1]) || valid(nums[2], nums[1], nums[0])
    }

    private static func macOK(_ value: String) -> Bool {
        let l = value.lowercased().replacingOccurrences(of: "-", with: ":")
        let banned: Set<String> = [
            "00:00:00:00:00:00", "ff:ff:ff:ff:ff:ff", "00:11:22:33:44:55",
            "aa:bb:cc:dd:ee:ff", "01:23:45:67:89:ab", "12:34:56:78:9a:bc", "xx:xx:xx:xx:xx:xx",
        ]
        if banned.contains(l) { return false }
        return l.contains(where: { "abcdef".contains($0) })
    }

    private static func serialOK(_ value: String) -> Bool {
        value.count >= 6 && value.contains(where: \.isNumber) && Set(value).count > 1
    }

    private static let notNames: Set<String> = [
        "shared", "public", "guest", "default", "default user", "all users",
        "user", "username", "user_name", "yourname", "your-name", "your_name", "yourusername",
        "you", "me", "name", "example", "foo", "bar", "someone", "john", "jdoe",
        "runner", "node", "vscode", "codespace", "linuxbrew", "...",
    ]
    private static let notUsers: Set<String> = [
        "git", "root", "ec2-user", "ubuntu", "admin", "postgres", "www-data", "nobody",
        "centos", "debian", "fedora", "azureuser", "opc", "core", "vagrant", "docker",
        "str", "string", "int", "bool", "any", "none", "null", "nil", "true", "false",
        "undefined", "hi", "hello", "hey", "yes", "no", "ok", "okay", "thanks",
        "continue", "go", "stop", "help", "test", "y", "n",
    ]
    private static let chatWords: Set<String> = [
        "done", "why", "what", "how", "sure", "please", "retry", "next", "again",
        "great", "good", "nice", "cool", "fix", "go-ahead", "proceed", "lgtm",
        "required", "optional", "unknown", "anonymous", "guest", "current", "me",
    ]
    private static let codeObjects: Set<String> = [
        "self", "this", "os", "process", "request", "req", "ctx", "context",
        "config", "cfg", "conf", "settings", "env", "args", "opts", "options",
        "props", "params", "session", "socket", "platform", "window", "location", "url",
        "u", "r", "c", "s", "m", "p", "x", "data", "info", "user",
    ]
    private static let publicHosts: Set<String> = [
        "github.com", "gitlab.com", "bitbucket.org", "ssh.dev.azure.com", "vs-ssh.visualstudio.com",
        "localhost", "host", "hostname", "server", "remote", "example", "your-server",
        "str", "string", "none", "null", "true", "false", "undefined",
    ]
    private static let notBuckets: Set<String> = [
        "bucket", "my-bucket", "mybucket", "bucket-name", "bucketname", "my-bucket-name",
        "your-bucket", "your-bucket-name", "yourbucket", "example-bucket", "examplebucket",
        "amzn-s3-demo-bucket", "doc-example-bucket", "s3", "www", "storage", "container",
        "mycontainer", "my-container", "mystorageaccount", "account",
        "upload", "download", "batch", "b", "v1", "v2", "api",
    ]
    private static let resolvers: Set<String> = [
        "8.8.8.8", "8.8.4.4", "1.1.1.1", "1.0.0.1", "9.9.9.9", "149.112.112.112",
        "208.67.222.222", "208.67.220.220", "114.114.114.114", "223.5.5.5", "223.6.6.6",
        "119.29.29.29", "180.76.76.76", "2001:4860:4860::8888", "2001:4860:4860::8844",
        "2606:4700:4700::1111", "2606:4700:4700::1001",
    ]

    private static func homeTighten(_ ns: NSString, _ range: NSRange) -> NSRange? {
        var end = range.location + range.length
        while end > range.location, ns.character(at: end - 1) == 46 { end -= 1 }
        guard end > range.location else { return nil }
        let name = ns.substring(with: NSRange(location: range.location, length: end - range.location))
        if name.hasPrefix(".") || notNames.contains(name.lowercased()) { return nil }
        return NSRange(location: range.location, length: end - range.location)
    }

    private static func userOK(_ value: String) -> Bool {
        let l = value.lowercased()
        return value.count >= 2 && !notUsers.contains(l) && !notNames.contains(l)
    }

    private static func inCode(_ value: String) -> Bool {
        let lower = value.lowercased()
        guard let dot = lower.firstIndex(of: ".") else { return false }
        let first = String(lower[..<dot])
        let last = String(lower[lower.index(after: lower.lastIndex(of: ".")!)...])
        return codeObjects.contains(first) || notUsers.contains(last) || notNames.contains(last)
            || publicHosts.contains(last) || last == "login" || last == "username"
    }

    private static func hostOK(_ value: String) -> Bool {
        let l = value.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "."))
        if l.count < 2 || publicHosts.contains(l) || l.hasPrefix("process.") || l.hasPrefix("os.") || l.hasPrefix("env.") {
            return false
        }
        if publicIPv4(l) || l.contains(":") { return false }
        for ex in ["example.com", "example.org", "example.net", ".example", ".test", ".invalid", ".localhost"] {
            let bare = ex.hasPrefix(".") ? String(ex.dropFirst()) : ex
            if l == bare || l.hasSuffix(ex) { return false }
        }
        return true
    }

    private static func lineUserOK(_ value: String) -> Bool {
        userOK(value) && !inCode(value) && !chatWords.contains(value.lowercased())
    }

    private static func lineHostOK(_ value: String) -> Bool {
        hostOK(value) && !inCode(value)
    }

    private static func publicIPv4(_ s: String) -> Bool {
        let parts = s.split(separator: ".").compactMap { Int($0) }
        guard parts.count == 4, parts.allSatisfy({ (0...255).contains($0) }),
              s.split(separator: ".").count == 4 else { return false }
        let a = parts[0], b = parts[1], c = parts[2]
        if a == 0 || a == 10 || a == 127 { return false }
        if a == 172 && (16...31).contains(b) { return false }
        if a == 192 && b == 168 { return false }
        if a == 169 && b == 254 { return false }
        if a == 100 && (64...127).contains(b) { return false }
        if a == 192 && b == 0 && c == 0 { return false }
        if a == 192 && b == 0 && c == 2 { return false }
        if a == 198 && (18...19).contains(b) { return false }
        if a == 198 && b == 51 && c == 100 { return false }
        if a == 203 && b == 0 && c == 113 { return false }
        if a >= 224 { return false }
        return !resolvers.contains(parts.map(String.init).joined(separator: "."))
    }

    private static func ipv4Context(_ ns: NSString, _ range: NSRange) -> Bool {
        let glue = "._-=~^"
        if range.location > 0 {
            let c = ns.character(at: range.location - 1)
            if isTokenChar(c) || glue.utf16.contains(c) { return false }
            if c == 47, range.location >= 2 {
                let prev = ns.character(at: range.location - 2)
                if isTokenChar(prev) || "._-".utf16.contains(prev) { return false }
            }
        }
        let end = range.location + range.length
        if end < ns.length {
            let c = ns.character(at: end)
            if isTokenChar(c) { return false }
            if c == 46, end + 1 < ns.length {
                let n = ns.character(at: end + 1)
                if n >= 48 && n <= 57 { return false }
            }
        }
        let start = max(0, range.location - 16)
        var before = ns.substring(with: NSRange(location: start, length: range.location - start)).lowercased()
        while let last = before.last, " \t:=\"'".contains(last) { before.removeLast() }
        for w in ["version", "ver", "release", "build", "rev", "版本"] where before.hasSuffix(w) {
            if before.count == w.count { return false }
            let idx = before.index(before.endIndex, offsetBy: -(w.count + 1))
            let ch = before[idx]
            if !(ch.isLetter || ch.isNumber || ch == "_") { return false }
        }
        return publicIPv4(ns.substring(with: range))
    }

    private static func ipv6OK(_ value: String) -> Bool {
        let lower = value.lowercased()
        guard lower.filter({ $0 == ":" }).count >= 2,
              lower.allSatisfy({ $0.isHexDigit || $0 == ":" }) else { return false }
        if resolvers.contains(lower) || lower.hasPrefix("fe80") || lower.hasPrefix("2001:db8") { return false }
        let groups = lower.split(separator: ":", omittingEmptySubsequences: false).map(String.init)
        if groups.count == 6, groups.allSatisfy({ $0.count == 2 }) { return false }
        let compressed = lower.contains("::")
        if !compressed, groups.count != 8 { return false }
        if compressed, groups.count > 8 || lower.contains(":::") { return false }
        guard let head = groups.first, !head.isEmpty, let first = Int(head, radix: 16) else { return false }
        return first & 0xE000 == 0x2000
    }

    private static func bucketOK(_ value: String) -> Bool {
        let l = value.lowercased()
        return l.count >= 3 && !notBuckets.contains(l) && l.contains(where: { !$0.isNumber })
    }
}

#if SECRET_COVER_CHECK
@main
enum SecretCoverCheck {
    static func main() {
        func check(_ name: String, _ ok: Bool) {
            if ok { return }
            fputs("FAIL \(name)\n", stderr)
            exit(1)
        }
        do {
            let key = "sk-" + String(repeating: "ab12", count: 6)
            let masked = try SecretCover.mask("token \(key) end")
            check("key hidden", !masked.contains(key) && masked.contains("⟦"))
            check("key restored", SecretCover.restore(masked) == "token \(key) end")
            let open = masked.firstIndex(of: "⟦")!
            let close = masked[open...].firstIndex(of: "⟧")!
            let inner = String(masked[masked.index(after: open)..<close])
            check("bare restored", SecretCover.restore("see \(inner) now") == "see \(key) now")

            let mail = try SecretCover.mask("write ada@acme.com please")
            check("email hidden", !mail.contains("ada@acme.com"))
            check("example kept", try SecretCover.mask("ada@example.com") == "ada@example.com")
            check("git kept", try SecretCover.mask("git@github.com:o/r.git") == "git@github.com:o/r.git")

            let phone = try SecretCover.mask("call 13800138000 today")
            check("phone hidden", !phone.contains("13800138000"))
            check("long digits kept", try SecretCover.mask("13800138000123") == "13800138000123")

            // 110101199003078873 checksums; 11010119900307887X does not.
            let id = try SecretCover.mask("id 110101199003078873 ok")
            check("id hidden", !id.contains("110101199003078873"))
            check("bad id kept", try SecretCover.mask("11010119900307887X") == "11010119900307887X")

            let card = try SecretCover.mask("card 4111111111111111 end")
            check("card hidden", !card.contains("4111111111111111"))

            let zh = try SecretCover.mask("密码是 hunter2 别告诉人")
            check("zh password hidden", !zh.contains("hunter2"))
            check("zh restored", SecretCover.restore(zh).contains("hunter2"))

            let same = try SecretCover.mask(key)
            let again = try SecretCover.mask("again \(key)")
            check("stable token", again.contains(same))

            let plain = "今天天气不错，去公园走走。"
            check("plain kept", try SecretCover.mask(plain) == plain)

            let ssn = try SecretCover.mask("ssn 412-34-5678 end")
            check("ssn hidden", !ssn.contains("412-34-5678"))
            check("ssn example kept", try SecretCover.mask("123-45-6789") == "123-45-6789")

            let iban = try SecretCover.mask("pay GB82WEST12345698765432 now")
            check("iban hidden", !iban.contains("GB82WEST12345698765432"))

            let pass = try SecretCover.mask("护照 E12345678")
            check("passport hidden", !pass.contains("E12345678"))

            let bday = try SecretCover.mask("生日 1990-03-05")
            check("birthday hidden", !bday.contains("1990-03-05"))
            check("recent birthday kept", try SecretCover.mask("生日 2026-01-02") == "生日 2026-01-02")

            check("version ip kept", try SecretCover.mask("version 142.250.190.14") == "version 142.250.190.14")
            let ip = try SecretCover.mask("host 142.250.190.14 end")
            check("public ip hidden", !ip.contains("142.250.190.14"))
            check("resolver kept", try SecretCover.mask("dns 8.8.8.8") == "dns 8.8.8.8")

            let mac = try SecretCover.mask("mac b8:27:eb:1a:2b:3c end")
            check("mac hidden", !mac.contains("b8:27:eb:1a:2b:3c"))
            check("mac example kept", try SecretCover.mask("aa:bb:cc:dd:ee:ff") == "aa:bb:cc:dd:ee:ff")

            let home = try SecretCover.mask("path /Users/nightjar/code")
            check("home hidden", !home.contains("nightjar") && home.contains("/Users/") && home.contains("/code"))

            let prompt = try SecretCover.mask("pax@studio:~$")
            check("prompt user hidden", !prompt.contains("pax"))
            check("prompt host hidden", !prompt.contains("studio"))

            let ai = MaskEntry(kind: .literal, pattern: "ai", ignoreCase: false)
            check("literal bounded", SecretCover.customMatched(in: "email", entries: [ai]).isEmpty)
            check("literal cjk", SecretCover.customMatched(in: "见夜航", entries: [MaskEntry(kind: .literal, pattern: "夜航", ignoreCase: false)]) == ["夜航"])
            check("literal case", SecretCover.customMatched(in: "night", entries: [MaskEntry(kind: .literal, pattern: "Night", ignoreCase: true)]) == ["night"])
            check("regex hit", SecretCover.customMatched(in: "工号1234", entries: [MaskEntry(kind: .regex, pattern: #"工号\d{4}"#, ignoreCase: false)]) == ["工号1234"])
            check("regex inside", SecretCover.customMatched(in: "email", entries: [MaskEntry(kind: .regex, pattern: "ai", ignoreCase: false)]) == ["ai"])
            check("bad regex skipped", SecretCover.customMatched(in: "abc", entries: [MaskEntry(kind: .regex, pattern: "(", ignoreCase: false)]).isEmpty)
            check("empty regex skipped", SecretCover.customMatched(in: "abc", entries: [MaskEntry(kind: .regex, pattern: "a*", ignoreCase: false)]).isEmpty)
            check("regex case", SecretCover.customMatched(in: "ABC", entries: [MaskEntry(kind: .regex, pattern: "abc", ignoreCase: true)]) == ["ABC"])

            let old = #"{"secrets":false,"words":"夜航, ai","wordsIgnoreCase":true}"#
            let migrated = try JSONDecoder().decode(MaskPrefs.self, from: Data(old.utf8))
            check("migrated count", migrated.entries.count == 2)
            check("migrated case", migrated.entries.allSatisfy(\.ignoreCase))
            check("migrated kind", migrated.entries.allSatisfy { $0.kind == .literal })
            check("migrated secrets", migrated.secrets == false)

            let named = MaskEntry(kind: .literal, pattern: "张三", ignoreCase: false, replacement: "某人")
            let stood = SecretCover.applyCustom(in: "张三到了", entries: [named])
            check("custom stood in", !stood.contains("张三"))
            check("custom restored", SecretCover.restore(stood) == "张三到了")
            let stoodAgain = SecretCover.applyCustom(in: "又见张三", entries: [named])
            check("same stand-in", stoodAgain.contains(stood.replacingOccurrences(of: "到了", with: "")))
            let blank = MaskEntry(kind: .literal, pattern: "李四", ignoreCase: false, replacement: "  ")
            let tokened = SecretCover.applyCustom(in: "李四到了", entries: [blank])
            check("blank uses token", tokened.contains("⟦") && !tokened.contains("李四"))
            check("token restored", SecretCover.restore(tokened) == "李四到了")
            let pair = MaskEntry(kind: .regex, pattern: "甲|乙", ignoreCase: false, replacement: "丙")
            let both = SecretCover.applyCustom(in: "甲和乙", entries: [pair])
            check("pair hidden", !both.contains("甲") && !both.contains("乙") && both.contains("丙"))
            check("pair restored", SecretCover.restore(both) == "甲和乙")
            let oldEntry = #"{"id":"00000000-0000-0000-0000-000000000001","kind":"literal","pattern":"夜航","ignoreCase":false}"#
            let decoded = try JSONDecoder().decode(MaskEntry.self, from: Data(oldEntry.utf8))
            check("old entry replacement", decoded.replacement.isEmpty)

            SecretCover.enabledOverride = false
            check("off sends raw", try SecretCover.mask(key) == key)
            fputs("ok\n", stdout)
        } catch {
            fputs("throw \(error)\n", stderr)
            exit(1)
        }
    }
}
#endif
