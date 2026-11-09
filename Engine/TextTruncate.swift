import Foundation

extension String {
    /// 截到 `limit` 个字符，被截断时在末尾加省略号（省略号不计入 `limit`）。
    func truncated(to limit: Int) -> String {
        guard limit > 0, count > limit else { return self }
        return String(prefix(limit)) + "…"
    }

    /// 省略号算在 `limit` 里。窄处按这个截，总长正好是 limit。
    func truncatedInside(_ limit: Int) -> String {
        guard limit > 0, count > limit else { return self }
        return String(prefix(limit - 1)) + "…"
    }
}
