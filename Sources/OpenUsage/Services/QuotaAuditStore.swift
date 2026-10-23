import Foundation

/// Independent account keys and original timestamps prevent cached or switched accounts from fabricating samples.
actor QuotaAuditStore {
    static let shared = QuotaAuditStore()
    private let url: URL

    struct Document: Codable, Sendable {
        var schema = "openusage.quota-audit.v1"
        var accounts: [String: [QuotaAuditSample]] = [:]
    }

    init(url: URL? = nil) {
        self.url = url ?? FileManager.default.urls(for: .applicationSupportDirectory,
            in: .userDomainMask)[0].appendingPathComponent("OpenUsage/quota-window-audit.json")
    }

    func record(family: String, slot: String, usage: OrcaUsageReader.Usage,
                events: [QuotaAuditEvent]?, now: Date) -> QuotaAuditReport {
        let key = family + ":" + slot
        var document = Document()
        var notices: [String] = []
        let lease: SingleInstanceLock.Token?
        switch SingleInstanceLock.acquire(at: url.appendingPathExtension("lock")) {
        case .acquired(let token): lease = token
        case .alreadyRunning:
            lease = nil
            notices.append("Another process is saving audit readings; this refresh is read-only.")
        case .failed:
            lease = nil
            notices.append("Audit storage could not be locked; this reading was not saved.")
        }
        defer { withExtendedLifetime(lease) {} }
        do {
            if FileManager.default.fileExists(atPath: url.path) {
                document = try JSONDecoder().decode(Document.self, from: Data(contentsOf: url))
                guard document.schema == "openusage.quota-audit.v1" else {
                    throw OrcaUsageReader.ReadError("Unsupported audit format.")
                }
            }
            if lease != nil {
                let oldest = now.addingTimeInterval(-30 * 86400)
                for account in Array(document.accounts.keys) {
                    document.accounts[account]?.removeAll { $0.sourceAt < oldest }
                }
                if var sample = QuotaAuditSample(usage, observedAt: now) {
                    let last = document.accounts[key]?.last
                    if last.map({ sample.sourceAt > $0.sourceAt }) ?? true {
                        if let events {
                            var total = QuotaAuditTotals()
                            let start = sample.session.resetAt.addingTimeInterval(-sample.session.duration)
                            for event in events where event.timestamp >= start && event.timestamp <= sample.sourceAt {
                                total.add(event)
                            }
                            sample.localUsage = total
                        }
                        document.accounts[key, default: []].append(sample)
                    } else if let last, sample.sourceAt == last.sourceAt,
                              sample.session != last.session || sample.weekly != last.weekly {
                        notices.append("The provider changed a reading without changing its timestamp; it was not appended.")
                    }
                } else {
                    notices.append("No valid five-hour window and reset time were supplied by Orca.")
                }
                try JSONEncoder().encode(document).write(to: url, options: .atomic)
                try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
            }
        } catch {
            notices.append("Saved audit evidence could not be read or written; existing evidence was left untouched.")
            AppLog.error(LogTag.plugin(family), "Quota audit storage failed")
        }
        var report = QuotaAuditReport.build(samples: document.accounts[key] ?? [], events: events, now: now)
        report.notes += notices
        return report
    }
}
