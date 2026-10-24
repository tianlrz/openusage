import Foundation

struct OrcaSessionWriter: Equatable, Sendable {
    var sessionID: String
    var accountSlot: String
    var processKey: String
    var startedAt: Date? = nil
}

