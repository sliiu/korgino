import Foundation

struct TErr: LocalizedError {
    let msg: String
    /// When true, UI should offer opening Apple language-pack download.
    let applePackMissing: Bool
    init(_ m: String, applePackMissing: Bool = false) {
        msg = m
        self.applePackMissing = applePackMissing
    }
    var errorDescription: String? { msg }
}
