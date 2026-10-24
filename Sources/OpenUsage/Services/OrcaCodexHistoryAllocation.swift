import Foundation

struct OrcaCodexHistoryAllocation: Codable, Sendable {
    static let storageKey = "openusage.orcaCodexHistoryAllocation.v1"
    var historicalAccountSlot: String
    var historicalThrough: Double
    static func load(defaults: UserDefaults = .standard) -> Self? {
        guard let data = defaults.data(forKey: storageKey) else { return nil }
        return try? JSONDecoder().decode(Self.self, from: data)
    }
}

