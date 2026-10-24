import Foundation

struct OrcaCodexHistoryContext: Sendable {
    var homes: [String: String]
    var allHistoryHomes: [String]
}

/// One local log scan feeds all account cards; one lock owner records writer observations for app/CLI readers.
actor OrcaCodexHistory {
    static let shared = OrcaCodexHistory()
    private let scanner: CodexLogUsageScanner
    private let reader: OrcaCodexWriterReading
    private let ledgerURL: URL
    private let allocation: @Sendable () -> OrcaCodexHistoryAllocation?
    private var ledger = OrcaSessionOwnershipLedger()
    private var lease: SingleInstanceLock.Token?
    private var sampler: Task<Void, Never>?
    private var storageError: String?
    private var observationError: String?
    private var context: OrcaCodexHistoryContext?
    private var cachedEvents: [CodexLogUsageScanner.Event]?
    private var scannedAt = Date.distantPast
    private var scanTask: Task<[CodexLogUsageScanner.Event]?, Never>?

    init(scanner: CodexLogUsageScanner = CodexLogUsageScanner(),
         reader: OrcaCodexWriterReading = OrcaCodexWriterReader(), ledgerURL: URL? = nil,
         allocation: @escaping @Sendable () -> OrcaCodexHistoryAllocation? = { OrcaCodexHistoryAllocation.load() }) {
        self.scanner = scanner
        self.reader = reader
        self.allocation = allocation
        self.ledgerURL = ledgerURL ?? FileManager.default.urls(for: .applicationSupportDirectory,
            in: .userDomainMask)[0].appendingPathComponent("OpenUsage/codex-account-ownership.json")
    }

    deinit { sampler?.cancel() }

    func scan(accountSlot: String?, context: OrcaCodexHistoryContext, now: Date,
              pricing: ModelPricing, fallbackModel: String? = nil) async -> LogUsageScan? {
        guard let events = await events(accountSlot: accountSlot, context: context, now: now) else { return nil }
        return CodexLogUsageScanner.aggregate(events: events,
            since: JSONLScanning.sinceDate(daysBack: 30, now: now), pricing: pricing, fallbackModel: fallbackModel)
    }

    func events(accountSlot: String?, context: OrcaCodexHistoryContext, now: Date) async -> [CodexLogUsageScanner.Event]? {
        if self.context == nil {
            self.context = context
            captureWriters()
            sampler = Task { [weak self] in
                while !Task.isCancelled {
                    try? await Task.sleep(for: .seconds(15))
                    guard !Task.isCancelled else { break }
                    await self?.captureWriters()
                }
            }
        }
        if lease == nil { reloadLedger() }
        if cachedEvents == nil || now.timeIntervalSince(scannedAt) >= 5 {
            if scanTask == nil {
                let roots = context.allHistoryHomes.map { URL(fileURLWithPath: $0) }
                scanTask = Task { [scanner] in
                    await scanner.events(homes: CodexLogHomes(read: roots, cache: roots), now: now)
                }
            }
            let events = await scanTask?.value
            guard !Task.isCancelled else { return nil }
            cachedEvents = events
            scannedAt = now
            scanTask = nil
        }
        guard let cachedEvents else { return nil }
        var partitions = ledger.partition(cachedEvents, allocation: allocation())
        // A removed account must not make its observed usage disappear from the dashboard.
        for key in Array(partitions.keys) where key != "unassigned" && context.homes[key] == nil {
            partitions["unassigned", default: []] += partitions.removeValue(forKey: key) ?? []
        }
        return partitions[accountSlot ?? "unassigned"] ?? []
    }

    func warning(accountSlot: String?) -> String? {
        var notes: [String] = []
        if let storageError { notes.append(storageError) }
        if let observationError { notes.append(observationError) }
        if let accountSlot, let allocation = allocation(),
           allocation.historicalAccountSlot == accountSlot {
            notes.append("Earlier history was manually assigned to this account; new usage follows observed session writers.")
        } else if accountSlot == nil {
            notes.append("These log events have no continuously observed local account owner. They are retained here, not charged to either account.")
        }
        return notes.isEmpty ? nil : notes.joined(separator: " ")
    }

    private func captureWriters() {
        guard let context else { return }
        if lease == nil {
            switch SingleInstanceLock.acquire(at: ledgerURL.appendingPathExtension("lock")) {
            case .acquired(let token):
                lease = token
                reloadLedger()
            case .alreadyRunning:
                reloadLedger()
                return
            case .failed:
                observationError = "Local account tracking is unavailable; unverified usage remains unassigned."
                return
            }
        }
        do {
            let writers = try reader.writers(homes: context.homes)
            ledger.observe(writers, at: Date())
            observationError = nil
            if storageError == nil {
                let data = try JSONEncoder().encode(ledger)
                try data.write(to: ledgerURL, options: .atomic)
                try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: ledgerURL.path)
            }
        } catch {
            ledger.observationFailed()
            observationError = "A local writer check failed; unverified usage remains unassigned."
            AppLog.warn(LogTag.plugin("codex"), "Local Codex writer observation or persistence failed")
        }
    }

    private func reloadLedger() {
        guard FileManager.default.fileExists(atPath: ledgerURL.path) else { return }
        do { ledger = try JSONDecoder().decode(OrcaSessionOwnershipLedger.self, from: Data(contentsOf: ledgerURL)) }
        catch {
            storageError = "Saved account tracking could not be read; existing evidence was left untouched."
            AppLog.error(LogTag.plugin("codex"), "Codex account ownership ledger could not be read")
        }
    }
}
