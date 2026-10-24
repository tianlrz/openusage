import Foundation

/// Resumed sessions keep their original bridge owner; verified runtime intervals override individual entries.
struct ClaudeSessionUsageFilter {
    var files: [JSONLScanning.DiscoveredFile] = []
    private var historicalSessions: Set<String> = []
    private var intervals: [String: [OrcaSessionOwnershipLedger.Span]]
    private let identities: [String: String]
    private let target: String

    init(files: [JSONLScanning.DiscoveredFile], target: String,
         ownership: OrcaClaudeUsageOwnership.Snapshot,
         historicalFiles: [JSONLScanning.DiscoveredFile]) {
        self.target = target
        self.identities = ownership.identities
        self.intervals = Dictionary(grouping: ownership.ledger.spans, by: \.sessionID)
        let indexed = Dictionary(files.map { ($0.path, $0) }, uniquingKeysWith: { first, _ in first })
        let historicalPaths = Set(historicalFiles.map { URL(fileURLWithPath: $0.path).resolvingSymlinksInPath().path })
        var seen: Set<String> = []
        for file in files {
            let path = URL(fileURLWithPath: file.path).resolvingSymlinksInPath().path
            guard seen.insert(path).inserted,
                  let parent = ClaudeLogUsageScanner.owningSessionFile(for: file, filesByPath: indexed) else { continue }
            let session = URL(fileURLWithPath: parent.path).deletingPathExtension().lastPathComponent.lowercased()
            let historical = historicalPaths.contains(path)
            if historical { historicalSessions.insert(session) }
            if historical || intervals[session]?.contains(where: { identities[$0.accountSlot] == target }) == true {
                self.files.append(file)
            }
        }
    }

    func entries(_ entries: [ClaudeLogUsageScanner.Entry]) -> [ClaudeLogUsageScanner.Entry] {
        entries.filter { entry in
            guard let session = entry.sessionID else { return false }
            if let spans = intervals[session], let first = spans.map(\.start).min(), entry.timestamp >= first {
                let owners = Set(spans.filter { entry.timestamp >= $0.start && entry.timestamp <= $0.end }
                    .compactMap { identities[$0.accountSlot] })
                return owners.count == 1 && owners.first == target
            }
            return historicalSessions.contains(session)
        }
    }
}
