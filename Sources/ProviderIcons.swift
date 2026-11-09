import SwiftUI

enum ProviderIcon {
    static func systemImage(for id: ProviderID) -> String {
        switch id {
        case .googleFree, .googleCloud: return "globe"
        case .deepl: return "d.circle.fill"
        case .apple: return "apple.logo"
        case .microsoft: return "m.circle.fill"
        case .baidu: return "b.circle.fill"
        case .youdao: return "y.circle.fill"
        case .caiyun: return "cloud.fill"
        case .mymemory: return "books.vertical"
        case .libreTranslate: return "character.book.closed"
        case .lingva: return "globe.badge.chevron.backward"
        }
    }

    /// 内置翻译有品牌图的，对应 `Assets/ProviderIcons` 里的文件名。有道、彩云还没有，仍用字母。
    static func logoKey(for id: ProviderID) -> String? {
        switch id {
        case .googleFree, .googleCloud: return "google"
        case .deepl: return "deepl"
        case .microsoft: return "microsoft"
        case .baidu: return "baidu"
        default: return nil
        }
    }

    static func logoKey(for id: OCRProviderID) -> String? {
        switch id {
        case .baidu, .baiduAccurate: return "baidu"
        case .tencent: return "tencent"
        case .googleVision: return "google"
        case .azure: return "azure"
        default: return nil
        }
    }

    static func logo(for id: ProviderID) -> Logo? { logoKey(for: id).flatMap(loadLogo) }
    static func logo(for id: OCRProviderID) -> Logo? { logoKey(for: id).flatMap(loadLogo) }

    static func systemImage(aiPreset: String, name: String = "") -> String {
        let key = aiPreset.lowercased()
        let n = name.lowercased()
        switch key {
        case "openai", "azure-openai": return "sparkles"
        case "gemini": return "sparkle"
        case "anthropic": return "a.circle.fill"
        case "mistral": return "wind"
        case "groq": return "hare"
        case "xai": return "x.circle.fill"
        case "deepseek": return "brain.head.profile"
        case "moonshot", "moonshot-intl": return "moon.stars"
        case "zhipu": return "z.circle.fill"
        case "qwen", "qwen-intl": return "q.circle.fill"
        case "doubao": return "leaf.fill"
        case "hunyuan": return "h.circle.fill"
        case "qianfan": return "fan.fill"
        case "baichuan": return "mountain.2.fill"
        case "yi": return "y.circle"
        case "stepfun": return "figure.step.training"
        case "minimax": return "waveform"
        case "elevenlabs": return "waveform"
        case "azure": return "m.circle.fill"
        case "google": return "globe"
        case "deepgram": return "dot.radiowaves.left.and.right"
        case "local": return "desktopcomputer"
        case "custom": return "square.and.pencil"
        case "modelscope": return "scope"
        case "openrouter": return "arrow.triangle.branch"
        case "siliconflow": return "drop.fill"
        case "together": return "person.3.fill"
        case "fireworks": return "flame.fill"
        case "deepinfra": return "server.rack"
        case "novita": return "n.circle.fill"
        case "github-models": return "chevron.left.forwardslash.chevron.right"
        case "perplexity": return "magnifyingglass"
        case "cohere": return "c.circle.fill"
        case "cerebras": return "cpu"
        case "sambanova": return "s.circle.fill"
        case "nvidia": return "memorychip"
        case "ollama": return "desktopcomputer"
        case "lmstudio", "lm-studio": return "laptopcomputer"
        default:
            if n.contains("ollama") { return "desktopcomputer" }
            if n.contains("openai") { return "sparkles" }
            if n.contains("claude") || n.contains("anthropic") { return "a.circle.fill" }
            if n.contains("gemini") { return "sparkle" }
            return "sparkles"
        }
    }

    /// Resolve from ProviderOutcome.id (`ProviderID.rawValue` or `ai:<profileId>`).
    static func systemImage(outcomeID raw: String, name: String = "") -> String {
        let outcomeID = baseID(raw)
        if let (preset, n) = aiPreset(outcomeID: outcomeID, name: name) {
            return systemImage(aiPreset: preset, name: n)
        }
        if let p = ProviderID(rawValue: outcomeID) {
            return systemImage(for: p)
        }
        return "shippingbox"
    }

    /// 文件窗口里同一家开了几页，历史里后面几页的 id 带「#2」。认图标时去掉。
    static func baseID(_ outcomeID: String) -> String {
        outcomeID.split(separator: "#", maxSplits: 1).first.map(String.init) ?? outcomeID
    }

    static func aiPreset(outcomeID raw: String, name: String) -> (String, String)? {
        let outcomeID = baseID(raw)
        guard outcomeID.hasPrefix("ai:") else { return nil }
        let pid = String(outcomeID.dropFirst(3))
        if let p = AppConfig.shared.aiProfiles.first(where: { $0.id == pid }) {
            return (p.preset.isEmpty ? p.name : p.preset, p.name)
        }
        return (name, name)
    }

    struct Logo {
        let image: NSImage
        /// 深色界面用的图。黑墨或深色为主的标才有，见 `darkInkVariant`。
        let darkImage: NSImage?
        let isTemplate: Bool

        func image(for scheme: ColorScheme) -> NSImage {
            if scheme == .dark, let darkImage { return darkImage }
            return image
        }
    }

    nonisolated(unsafe) private static var logoCache: [String: Logo?] = [:]

    static func logo(aiPreset: String, name: String = "") -> Logo? {
        let n = name.lowercased()
        let aliases = [("ollama", "ollama"), ("openai", "openai"), ("claude", "claude"),
                       ("anthropic", "anthropic"), ("gemini", "gemini"), ("deepseek", "deepseek")]
        let keys = [aiPreset.lowercased()] + aliases.filter { n.contains($0.0) }.map(\.1)
        return keys.lazy.compactMap(loadLogo).first
    }

    private static func loadLogo(_ key: String) -> Logo? {
        if let hit = logoCache[key] { return hit }
        let res: Logo?
        if let url = Bundle.main.url(forResource: key, withExtension: "png", subdirectory: "ProviderIcons"),
           let img = NSImage(contentsOf: url) {
            res = Logo(image: img, darkImage: darkInkVariant(img), isTemplate: false)
        } else if let url = Bundle.main.url(forResource: "\(key).template", withExtension: "png", subdirectory: "ProviderIcons"),
                  let img = NSImage(contentsOf: url) {
            res = Logo(image: img, darkImage: nil, isTemplate: true)
        } else {
            res = nil
        }
        logoCache[key] = res
        return res
    }

    /// 深色界面里看不清的标：大半是黑墨（Kimi、零一），或深蓝、深紫、深绿（DeepInfra、Fireworks、Cohere）。
    /// 给它们做一张深色用的图：黑墨改成白，深色彩往白里提亮到看得清，色相不变；本来就亮的颜色不动。
    private static func darkInkVariant(_ image: NSImage) -> NSImage? {
        var proposed = CGRect(origin: .zero, size: image.size)
        guard let cg = image.cgImage(forProposedRect: &proposed, context: nil, hints: nil) else { return nil }
        let width = cg.width
        let height = cg.height
        guard let ctx = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width * 4,
            space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: width, height: height))
        guard let base = ctx.data else { return nil }
        let pixels = base.bindMemory(to: UInt8.self, capacity: width * height * 4)
        let count = width * height

        func linear(_ v: Double) -> Double { v <= 0.04045 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4) }
        func luminance(_ r: Double, _ g: Double, _ b: Double) -> Double {
            0.2126 * linear(r) + 0.7152 * linear(g) + 0.0722 * linear(b)
        }
        func unpremultiplied(_ offset: Int) -> (r: Double, g: Double, b: Double, a: Int)? {
            let a = Int(pixels[offset + 3])
            if a < 20 { return nil }
            let k = 255.0 / Double(a)
            return (min(1, Double(pixels[offset]) * k / 255), min(1, Double(pixels[offset + 1]) * k / 255),
                    min(1, Double(pixels[offset + 2]) * k / 255), a)
        }

        // 深色底约 #1E1E1E。亮度到 0.2 左右，对比度才过 3:1。
        // 很艳的颜色（通义的蓝）亮度低也看得清，不动。
        let target = 0.2
        func needsLift(_ px: (r: Double, g: Double, b: Double, a: Int)) -> Bool {
            luminance(px.r, px.g, px.b) < 0.13 && max(px.r, px.g, px.b) - min(px.r, px.g, px.b) < 0.8
        }
        var opaque = 0
        var dark = 0
        for i in 0..<count {
            guard let px = unpremultiplied(i * 4) else { continue }
            opaque += 1
            if needsLift(px) { dark += 1 }
        }
        guard opaque > 32, dark * 100 / opaque >= 40 else { return nil }

        for i in 0..<count {
            let offset = i * 4
            guard let px = unpremultiplied(offset), needsLift(px) else { continue }
            let chroma = max(px.r, px.g, px.b) - min(px.r, px.g, px.b)
            var out = (r: 1.0, g: 1.0, b: 1.0)
            if chroma > 0.11 {
                // 往白里混，二分找刚好够亮的那一点，留住色相。
                var lo = 0.0, hi = 1.0
                for _ in 0..<10 {
                    let t = (lo + hi) / 2
                    let l = luminance(px.r + (1 - px.r) * t, px.g + (1 - px.g) * t, px.b + (1 - px.b) * t)
                    if l < target { lo = t } else { hi = t }
                }
                out = (px.r + (1 - px.r) * hi, px.g + (1 - px.g) * hi, px.b + (1 - px.b) * hi)
            }
            let a = Double(px.a)
            pixels[offset] = UInt8((out.r * a).rounded())
            pixels[offset + 1] = UInt8((out.g * a).rounded())
            pixels[offset + 2] = UInt8((out.b * a).rounded())
        }
        guard let out = ctx.makeImage() else { return nil }
        return NSImage(cgImage: out, size: image.size)
    }
}

struct ProviderIconView: View {
    @Environment(\.colorScheme) private var colorScheme
    let systemName: String
    var logo: ProviderIcon.Logo?
    var size: CGFloat = 12
    var body: some View {
        Group {
            if let logo {
                Image(nsImage: logo.image(for: colorScheme))
                    .renderingMode(logo.isTemplate ? .template : .original)
                    .resizable()
                    .interpolation(.high)
                    .scaledToFit()
                    .foregroundStyle(.primary)
            } else {
                Image(systemName: systemName)
                    .font(size >= 15 ? Theme.TypeScale.reading : (size >= 13 ? Theme.TypeScale.body : (size >= 12 ? Theme.TypeScale.label : (size >= 11 ? Theme.TypeScale.caption : Theme.TypeScale.micro)))).fontWeight(.semibold)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(width: size + 2, height: size + 2)
        .accessibilityHidden(true)
    }

    init(provider: ProviderID, size: CGFloat = 12) {
        self.systemName = ProviderIcon.systemImage(for: provider)
        self.logo = ProviderIcon.logo(for: provider)
        self.size = size
    }

    init(ocr: OCRProviderID, size: CGFloat = 12) {
        self.systemName = ocr.systemImage
        self.logo = ProviderIcon.logo(for: ocr)
        self.size = size
    }

    init(outcomeID: String, name: String = "", size: CGFloat = 12) {
        self.systemName = ProviderIcon.systemImage(outcomeID: outcomeID, name: name)
        if let (preset, n) = ProviderIcon.aiPreset(outcomeID: outcomeID, name: name) {
            self.logo = ProviderIcon.logo(aiPreset: preset, name: n)
        } else if let p = ProviderID(rawValue: ProviderIcon.baseID(outcomeID)) {
            self.logo = ProviderIcon.logo(for: p)
        }
        self.size = size
    }

    init(aiPreset: String, name: String = "", size: CGFloat = 12) {
        self.systemName = ProviderIcon.systemImage(aiPreset: aiPreset, name: name)
        self.logo = ProviderIcon.logo(aiPreset: aiPreset, name: name)
        self.size = size
    }
}
