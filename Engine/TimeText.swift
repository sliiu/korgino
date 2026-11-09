import Foundation

/// 界面和导出共用的时间格式。以前每个文件各建一个 `DateFormatter`，
/// 同一套配置抄好几遍；`DateFormatter` 创建成本高，也不该在主线程反复建。
enum TimeText {
    /// 「2026年11月8日 21:34」这类中段时间，跟系统语言走。
    static let medium: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .short
        return f
    }()

    /// 文件名用的时间戳：`2026-11-08-2134`。固定 POSIX，避免用户地区改变排序。
    static let fileStamp: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd-HHmm"
        return f
    }()

    /// 会议文件夹：`2026-11-08-213405`。要秒，同名会话才不撞。
    static let folderStamp: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd-HHmmss"
        return f
    }()

    /// 列表里的「11-08 21:34」。固定 zh_CN，和历史上一直以来的显示一致。
    static let shortList: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "zh_CN")
        f.dateFormat = "MM-dd HH:mm"
        return f
    }()

    /// 签名用的 UTC 日期：`2026-11-08`。
    static let utcDay: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()
}
