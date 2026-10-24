import Foundation

/// Keeps only bounded account/session intervals; credential values and log contents are never saved.
actor OrcaClaudeUsageOwnership {
    static let shared = OrcaClaudeUsageOwnership()
    struct Snapshot: Sendable {
        var ledger: OrcaSessionOwnershipLedger
        var identities: [String: String]
        var warning: String?

        func owner(session: String, at date: Date) -> String? {
            ledger.owner(sessionID: session, at: date).flatMap { identities[$0] }
        }
    }
    private struct Document: Codable {
        var schema = 1
        var ledger = OrcaSessionOwnershipLedger()
        var identities: [String: String] = [:]
    }
    private var document = Document()
    private let reader: OrcaClaudeSessionReading
    private let url: URL
    private var context: OrcaClaudeUsageContext?
    private var checkedAt = Date.distantPast
    private var pending: Task<[OrcaSessionWriter], Error>?
    private var sampler: Task<Void, Never>?
    private var lease: SingleInstanceLock.Token?
    private var loaded = false
    private var corrupt = false
    private var warning: String?

    init(reader: OrcaClaudeSessionReading = OrcaClaudeSessionReader(), url: URL? = nil) {
        self.reader = reader
        self.url = url ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("OpenUsage/claude-session-ownership.json")
    }
    deinit { sampler?.cancel() }

    func snapshot(context: OrcaClaudeUsageContext, now: Date = Date(), startSampler: Bool = true) async -> Snapshot {
        self.context = context
        if !loaded { load() }
        if lease == nil {
            do {
                try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                if case .acquired(let token) = SingleInstanceLock.acquire(at: url.appendingPathExtension("lock")) {
                    lease = token
                    load()
                }
            } catch { warning = "Claude tracking storage is unavailable." }
            if lease == nil {
                load()
                return Snapshot(ledger: document.ledger, identities: document.identities, warning: warning)
            }
        }
        if startSampler, sampler == nil {
            sampler = Task { [weak self] in
                while !Task.isCancelled {
                    try? await Task.sleep(for: .seconds(30))
                    guard !Task.isCancelled else { break }
                    await self?.sample()
                }
            }
        }
        if now.timeIntervalSince(checkedAt) >= 15 {
            if pending == nil {
                let reader = self.reader
                pending = Task.detached(priority: .utility) { try reader.sessions(context: context, now: now) }
            }
            do {
                guard let task = pending else { throw OrcaUsageReader.ReadError("Claude ownership check is unavailable.") }
                let writers = try await task.value
                if now.timeIntervalSince(checkedAt) >= 15 {
                    for (slot, identity) in context.identities {
                        // A changed account identity must never relabel an older interval.
                        if document.identities[slot] == nil || document.identities[slot] == identity {
                            document.identities[slot] = identity
                        }
                    }
                    let valid = writers.filter { document.identities[$0.accountSlot] == context.identities[$0.accountSlot] }
                    let exclusive = Dictionary(grouping: valid, by: \.sessionID).values.flatMap { records -> [OrcaSessionWriter] in
                        if Set(records.map(\.accountSlot)).count == 1, Set(records.map(\.processKey)).count == 1 { return records }
                        guard let first = records.first else { return [] }
                        return [OrcaSessionWriter(sessionID: first.sessionID, accountSlot: "unassigned",
                            processKey: "ambiguous:" + first.sessionID, startedAt: records.compactMap(\.startedAt).min())]
                    }
                    document.identities["unassigned"] = "unassigned"
                    document.ledger.observe(exclusive, at: now)
                    document.ledger.boundSpanCount(4096)
                    warning = corrupt ? "Saved Claude session ownership could not be read; its original file was preserved." : nil
                    if !corrupt { save() }
                    checkedAt = now
                }
            } catch {
                document.ledger.observationFailed()
                warning = "Claude session ownership could not be verified; uncertain usage was excluded."
                checkedAt = now
                AppLog.warn(LogTag.plugin("claude"), "Scoped Claude session observation failed")
            }
            pending = nil
        }
        return Snapshot(ledger: document.ledger, identities: document.identities, warning: warning)
    }

    private func sample() async {
        guard let context else { return }
        _ = await snapshot(context: context)
    }
    private func load() {
        loaded = true
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        do {
            let handle = try FileHandle(forReadingFrom: url); defer { try? handle.close() }
            let data = try handle.read(upToCount: 2 * 1024 * 1024 + 1) ?? Data()
            guard data.count <= 2 * 1024 * 1024 else { throw OrcaUsageReader.ReadError("Ownership file is too large.") }
            let saved = try JSONDecoder().decode(Document.self, from: data)
            guard saved.schema == 1, saved.ledger.spans.count <= 4096, saved.identities.count <= 128 else {
                throw OrcaUsageReader.ReadError("Unsupported ownership data.")
            }
            document = saved
        } catch { corrupt = true; AppLog.warn(LogTag.plugin("claude"), "Saved Claude ownership evidence was left untouched") }
    }
    private func save() {
        guard lease != nil else { return }
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try JSONEncoder().encode(document).write(to: url, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        } catch {
            warning = "Claude account tracking could not be saved."
            AppLog.warn(LogTag.plugin("claude"), "Claude session ownership persistence failed")
        }
    }
}
