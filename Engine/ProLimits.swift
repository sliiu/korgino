import Foundation

/// 免费档的上限。Mac 与 Windows 共用一套数字，改一处两边一起变。
/// 是否解锁由各平台的 `Pro` 决定，这里只管额度。
enum ProLimits {
    /// 同时启用的翻译服务数量（含 AI）。
    static let freeSimultaneous = 2
    /// 历史窗口里免费档能看到的条数。
    static let freeHistoryLimit = 50
    /// 免费档单份文件的原文上限，按 UTF-16 字符数算，中文一个字算一个。
    static let freeFileCharacters = 5000
    /// 免费档一份媒体字幕的时长上限。
    static let freeMediaSeconds: TimeInterval = 15 * 60
}
