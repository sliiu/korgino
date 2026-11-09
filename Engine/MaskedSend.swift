import Foundation

/// 「把要发出去的内容遮住，必要时问一次」这一条路。
///
/// 翻译、快捷翻译、实时字幕、会议纪要、对话、词典和插件都走它；区别只在
/// 一次发几段、要不要弹确认。以前每处各写一遍，合并预览和「发送原文」的
/// 处理慢慢就不一样了。还原（SecretCover.restore）留在调用方，因为回来的
/// 字段形状各不相同。
enum MaskedSend {
    /// 遮住这几段。`confirm` 为假时照发占位符，不打扰用户（快捷翻译、实时字幕）。
    /// 命中的话只问一次，把全部段落合成一段预览给用户看。
    static func prepare(
        _ pieces: [String],
        destination: String,
        confirm: Bool = true
    ) async throws -> [String] {
        guard SecretCover.anythingOn() else { return pieces }
        var covered: [String] = []
        var hits: [MaskHit] = []
        for piece in pieces {
            let c = try SecretCover.cover(piece)
            covered.append(c.text)
            hits.append(contentsOf: c.hits)
        }
        guard !hits.isEmpty, confirm else { return covered }
        let choice = try await MaskSendConfirm.ask(
            masked: covered.joined(separator: "\n\n"),
            original: pieces.joined(separator: "\n\n"),
            hits: hits,
            destination: destination
        )
        // 选「发送原文」就把遮好的换回原文再发。
        return choice == .original ? pieces : covered
    }

    /// 单段版的便捷写法。
    static func prepare(_ piece: String, destination: String, confirm: Bool = true) async throws -> String {
        try await prepare([piece], destination: destination, confirm: confirm).first ?? piece
    }
}
