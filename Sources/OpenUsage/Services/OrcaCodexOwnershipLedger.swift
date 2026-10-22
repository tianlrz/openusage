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

/// Only continuously observed, unambiguous writers establish a time span. Gaps remain unassigned.
struct OrcaCodexOwnershipLedger: Codable, Sendable {
    struct Span: Codable, Sendable {
        var sessionID: String
        var accountSlot: String
        var processKey: String
        var start: Date
        var end: Date
    }
    private(set) var spans: [Span] = []
    private var lastObservedAt: Date?
    private var lastWriters: [String: OrcaCodexWriterState] = [:]
    private struct OrcaCodexWriterState: Codable, Equatable, Sendable {
        var account: String
        var process: String
    }

    mutating func observe(_ writers: [OrcaCodexWriter], at date: Date) {
        let grouped = Dictionary(grouping: writers, by: \.sessionID)
        var next: [String: OrcaCodexWriterState] = [:]
        for (session, records) in grouped {
            let accounts = Set(records.map(\.accountSlot))
            let processes = Set(records.map(\.processKey))
            guard accounts.count == 1, processes.count == 1, let first = records.first else { continue }
            let state = OrcaCodexWriterState(account: first.accountSlot, process: first.processKey)
            next[session] = state
            if lastWriters[session] == state, let previous = lastObservedAt,
               date >= previous, date.timeIntervalSince(previous) <= 45,
               let index = spans.lastIndex(where: {
                   $0.sessionID == session && $0.accountSlot == state.account
                       && $0.processKey == state.process && $0.end == previous
               }) {
                spans[index].end = date
            } else {
                spans.append(Span(sessionID: session, accountSlot: state.account,
                                  processKey: state.process, start: date, end: date))
            }
        }
        lastWriters = next
        lastObservedAt = date
        let oldest = date.addingTimeInterval(-32 * 86400)
        spans.removeAll { $0.end < oldest }
    }

    mutating func observationFailed() {
        lastWriters = [:]
        lastObservedAt = nil
    }

    func owner(sessionID: String?, at date: Date) -> String? {
        guard let sessionID else { return nil }
        let owners = Set(spans.filter { $0.sessionID == sessionID && date >= $0.start && date <= $0.end }
            .map(\.accountSlot))
        return owners.count == 1 ? owners.first : nil
    }

    /// Resolve duplicate events before splitting accounts, so copied logs never credit two owners.
    func partition(
        _ events: [CodexLogUsageScanner.Event], allocation: OrcaCodexHistoryAllocation?
    ) -> [String: [CodexLogUsageScanner.Event]] {
        var grouped: [CodexLogUsageScanner.EventKey: (CodexLogUsageScanner.Event, Set<String>)] = [:]
        for event in events {
            let owner: String
            if let allocation, event.timestamp.timeIntervalSince1970 <= allocation.historicalThrough {
                owner = allocation.historicalAccountSlot
            } else {
                owner = self.owner(sessionID: event.sessionID, at: event.timestamp) ?? "unassigned"
            }
            let key = CodexLogUsageScanner.EventKey(event)
            if var existing = grouped[key] {
                existing.1.insert(owner)
                grouped[key] = existing
            } else { grouped[key] = (event, [owner]) }
        }
        var result: [String: [CodexLogUsageScanner.Event]] = [:]
        for (_, value) in grouped {
            let owner = value.1.count == 1 ? (value.1.first ?? "unassigned") : "unassigned"
            result[owner, default: []].append(value.0)
        }
        return result
    }
}
