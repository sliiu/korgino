import Foundation

/// 一条自定义遮盖。普通按字面找，正则按表达式找。
struct MaskEntry: Codable, Equatable, Identifiable {
    enum Kind: String, Codable, CaseIterable {
        case literal, regex
    }

    var id: UUID
    var kind: Kind
    var pattern: String
    var ignoreCase: Bool
    /// 发出去时换成这段。空着则用占位符。
    var replacement: String

    init(id: UUID = UUID(), kind: Kind = .literal, pattern: String = "", ignoreCase: Bool = false, replacement: String = "") {
        self.id = id
        self.kind = kind
        self.pattern = pattern
        self.ignoreCase = ignoreCase
        self.replacement = replacement
    }

    private enum CodingKeys: String, CodingKey {
        case id, kind, pattern, ignoreCase, replacement
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        kind = try c.decode(Kind.self, forKey: .kind)
        pattern = try c.decode(String.self, forKey: .pattern)
        ignoreCase = try c.decodeIfPresent(Bool.self, forKey: .ignoreCase) ?? false
        replacement = try c.decodeIfPresent(String.self, forKey: .replacement) ?? ""
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(kind, forKey: .kind)
        try c.encode(pattern, forKey: .pattern)
        try c.encode(ignoreCase, forKey: .ignoreCase)
        try c.encode(replacement, forKey: .replacement)
    }

    var trimmed: String {
        pattern.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// 真正发出去的替换词。空着表示仍用占位符。
    var standIn: String? {
        let text = replacement.trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? nil : text
    }

    /// 普通条目里真正用来找的词。短于两个字的不算。
    var literal: String? {
        guard kind == .literal else { return nil }
        let text = trimmed
        guard text.count >= 2 else { return nil }
        return text
    }

    /// 能用的正则。写错、太长，或会匹配空字符串的，返回 nil。
    func regex() -> NSRegularExpression? {
        guard kind == .regex else { return nil }
        let text = trimmed
        guard !text.isEmpty, text.count <= 120 else { return nil }
        guard let compiled = try? NSRegularExpression(
            pattern: text,
            options: ignoreCase ? [.caseInsensitive] : []
        ) else { return nil }
        let empty = NSRange(location: 0, length: 0)
        if compiled.firstMatch(in: "", options: [], range: empty) != nil { return nil }
        return compiled
    }

    /// 给人看的错误。空着还没写，不算错。
    var problem: String? {
        let text = trimmed
        if text.isEmpty { return nil }
        switch kind {
        case .literal:
            return text.count < 2 ? "至少两个字" : nil
        case .regex:
            if text.count > 120 { return "太长" }
            if regex() != nil { return nil }
            if (try? NSRegularExpression(pattern: text)) == nil { return "正则写错了" }
            return "会匹配空字符串"
        }
    }
}

/// 隐私里每一类各自一个开关。旧的总开关关掉过，则这些默认开着的类保持关。
struct MaskPrefs: Codable, Equatable {
    var secrets = true
    var email = true
    var phone = true
    var idCard = true
    var bankCard = true
    var ssn = true
    var passport = true
    var iban = true
    var birthday = true
    var mac = true
    var serial = true
    var home = false
    var userHost = false
    var ip = false
    var bucket = false
    var entries: [MaskEntry] = []

    init() {}

    var anythingOn: Bool {
        MaskKind.allCases.contains(where: allows) || entries.contains { $0.literal != nil || $0.regex() != nil }
    }

    func allows(_ kind: MaskKind) -> Bool {
        switch kind {
        case .secrets: return secrets
        case .email: return email
        case .phone: return phone
        case .idCard: return idCard
        case .bankCard: return bankCard
        case .ssn: return ssn
        case .passport: return passport
        case .iban: return iban
        case .birthday: return birthday
        case .mac: return mac
        case .serial: return serial
        case .home: return home
        case .userHost: return userHost
        case .ip: return ip
        case .bucket: return bucket
        }
    }

    static func load(_ defaults: UserDefaults) -> MaskPrefs {
        if let data = defaults.data(forKey: "maskPrefs"),
           let saved = try? JSONDecoder().decode(MaskPrefs.self, from: data) {
            return saved
        }
        var prefs = MaskPrefs()
        if defaults.object(forKey: "maskSecrets") as? Bool == false {
            prefs.secrets = false
            prefs.email = false
            prefs.phone = false
            prefs.idCard = false
            prefs.bankCard = false
            prefs.ssn = false
            prefs.passport = false
            prefs.iban = false
            prefs.birthday = false
            prefs.mac = false
            prefs.serial = false
        }
        return prefs
    }

    private enum CodingKeys: String, CodingKey {
        case secrets, email, phone, idCard, bankCard, ssn, passport, iban, birthday, mac, serial
        case home, userHost, ip, bucket, entries, words, wordsIgnoreCase
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        func flag(_ key: CodingKeys, _ fallback: Bool) -> Bool {
            (try? c.decode(Bool.self, forKey: key)) ?? fallback
        }
        secrets = flag(.secrets, true)
        email = flag(.email, true)
        phone = flag(.phone, true)
        idCard = flag(.idCard, true)
        bankCard = flag(.bankCard, true)
        ssn = flag(.ssn, true)
        passport = flag(.passport, true)
        iban = flag(.iban, true)
        birthday = flag(.birthday, true)
        mac = flag(.mac, true)
        serial = flag(.serial, true)
        home = flag(.home, false)
        userHost = flag(.userHost, false)
        ip = flag(.ip, false)
        bucket = flag(.bucket, false)
        if let saved = try c.decodeIfPresent([MaskEntry].self, forKey: .entries) {
            entries = saved
        } else {
            let words = (try? c.decode(String.self, forKey: .words)) ?? ""
            let ignore = flag(.wordsIgnoreCase, false)
            entries = Self.literals(from: words, ignoreCase: ignore)
        }
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(secrets, forKey: .secrets)
        try c.encode(email, forKey: .email)
        try c.encode(phone, forKey: .phone)
        try c.encode(idCard, forKey: .idCard)
        try c.encode(bankCard, forKey: .bankCard)
        try c.encode(ssn, forKey: .ssn)
        try c.encode(passport, forKey: .passport)
        try c.encode(iban, forKey: .iban)
        try c.encode(birthday, forKey: .birthday)
        try c.encode(mac, forKey: .mac)
        try c.encode(serial, forKey: .serial)
        try c.encode(home, forKey: .home)
        try c.encode(userHost, forKey: .userHost)
        try c.encode(ip, forKey: .ip)
        try c.encode(bucket, forKey: .bucket)
        try c.encode(entries, forKey: .entries)
    }

    /// 旧的逗号分隔词，迁成一条条普通条目。
    private static func literals(from words: String, ignoreCase: Bool) -> [MaskEntry] {
        words.split { ",，;\n".contains($0) }
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { $0.count >= 2 }
            .map { MaskEntry(kind: .literal, pattern: $0, ignoreCase: ignoreCase) }
    }
}
