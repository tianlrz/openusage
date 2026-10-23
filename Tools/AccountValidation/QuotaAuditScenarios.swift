import Foundation
@testable import OpenUsage

@MainActor
final class QuotaAuditTests: XCTestCase {
    private let base = Date(timeIntervalSince1970: 1_800_000_000)
    private var pricing: ModelPricing {
        ModelPricing(supplement: PricingSupplement(), primary: PricingCatalog(entries: [
            "known": ModelRates(inputPerMillion: 1, outputPerMillion: 2,
                cacheWritePerMillion: 1.25, cacheReadPerMillion: 0.1)
        ]), secondary: PricingCatalog(entries: [:]))
    }

    func testDistinctAccountsCachedReadingsAndRestart() async throws {
        let root = scratch(); defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("audit.json")
        let store = QuotaAuditStore(url: url)
        let now = base.addingTimeInterval(120)
        _ = await store.record(family: "claude", slot: "a", usage: usage(10, at: 60), events: [], now: now)
        _ = await store.record(family: "claude", slot: "b", usage: usage(80, at: 60), events: [], now: now)
        let evidence = [event(90, input: 100), event(130, input: 900)]
        let report = await store.record(family: "claude", slot: "a", usage: usage(20, at: 120), events: evidence, now: now)
        let duplicate = await store.record(family: "claude", slot: "a", usage: usage(20, at: 120), events: evidence,
            now: now.addingTimeInterval(60))
        XCTAssertEqual(report.windows.first?.samples, 2)
        XCTAssertEqual(duplicate.windows.first?.samples, 2)
        XCTAssertEqual(report.windows.first?.percentChange, 10)
        XCTAssertEqual(report.windows.first?.matchedUsage.totalTokens, 100)
        XCTAssertEqual(report.windows.first?.windowUsage.totalTokens, 100)
        XCTAssertEqual(report.windows.first?.estimatedUSDPer10Percent, 0.0001)
        let restored = QuotaAuditStore(url: url)
        let b = await restored.record(family: "claude", slot: "b", usage: usage(80, at: 60), events: [], now: now)
        XCTAssertEqual(b.windows.first?.samples, 1)
        XCTAssertEqual(b.windows.first?.firstPercent, 80)
        let document = try JSONDecoder().decode(QuotaAuditStore.Document.self, from: Data(contentsOf: url))
        XCTAssertEqual(document.accounts["claude:a"]?.count, 2)
        XCTAssertEqual(document.accounts["claude:b"]?.count, 1)
        XCTAssertEqual(document.accounts["claude:a"]?.first?.weekly?.usedPercent, 42)
        XCTAssertEqual(document.accounts["claude:a"]?.last?.localUsage?.totalTokens, 100)
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o600)
    }

    func testWindowsAndTimestampBoundariesNeverBorrowDailyTotals() throws {
        let samples = [try sample(10, at: 60), try sample(25, at: 180),
                       try sample(1, at: 18060, reset: 36000)]
        let evidence = [event(-1, input: 99), event(0, input: 10), event(60, input: 20),
                        event(61, input: 30), event(180, input: 40), event(181, input: 50),
                        event(18000, input: 60)]
        let report = QuotaAuditReport.build(samples: samples, events: evidence, now: base.addingTimeInterval(18100))
        XCTAssertEqual(report.windows.count, 2)
        XCTAssertEqual(report.windows[0].windowUsage.totalTokens, 60)
        XCTAssertEqual(report.windows[1].windowUsage.totalTokens, 150)
        XCTAssertEqual(report.windows[1].matchedUsage.totalTokens, 70)
        XCTAssertEqual(report.windows[1].readings.count, 2)
    }

    func testMillisecondResetNoiseKeepsOneWindowAndRawEvidence() throws {
        var a = usage(1, at: 60), b = usage(11, at: 120)
        let reset = base.addingTimeInterval(18000).timeIntervalSince1970 * 1000
        a.session?.resetsAt = reset + 123
        b.session?.resetsAt = reset + 987
        let first = try XCTUnwrap(QuotaAuditSample(a, observedAt: base.addingTimeInterval(60)))
        let last = try XCTUnwrap(QuotaAuditSample(b, observedAt: base.addingTimeInterval(120)))
        let report = QuotaAuditReport.build(samples: [first, last], events: [], now: base.addingTimeInterval(120))
        XCTAssertEqual(report.windows.count, 1)
        XCTAssertEqual(report.windows[0].samples, 2)
        XCTAssertEqual(report.windows[0].readings[0].session.resetAt, first.session.resetAt)
        XCTAssertEqual(report.windows[0].readings[1].session.resetAt, last.session.resetAt)
    }

    func testEarlyResetDoesNotCountOverlappingEventsTwice() throws {
        let samples = [try sample(10, at: 60), try sample(20, at: 120),
            try sample(1, at: 200, reset: 18180)]
        let report = QuotaAuditReport.build(samples: samples,
            events: [event(90, input: 100), event(180, input: 200)], now: base.addingTimeInterval(210))
        XCTAssertEqual(report.windows[0].windowUsage.totalTokens, 200)
        XCTAssertEqual(report.windows[1].windowUsage.totalTokens, 100)
        XCTAssertEqual(report.windows[1].windowEnd, base.addingTimeInterval(180))
        XCTAssertTrue(report.windows[1].notes.contains { $0.contains("shortened") })
        XCTAssertNil(report.windows[1].estimatedUSDPer10Percent)
    }

    func testUnknownPricesGapsAndCorrectionsPreventMisleadingComparisons() throws {
        let unknown = QuotaAuditReport.build(samples: [try sample(1, at: 60), try sample(11, at: 120)],
            events: [event(90, input: 100, model: "unknown")], now: base.addingTimeInterval(120))
        XCTAssertEqual(unknown.windows.first?.windowUsage.totalTokens, 100)
        XCTAssertEqual(unknown.windows.first?.windowUsage.unpricedEvents, 1)
        XCTAssertNil(unknown.windows.first?.estimatedUSDPer10Percent)
        let gap = QuotaAuditReport.build(samples: [try sample(1, at: 60), try sample(30, at: 900)],
            events: [event(90, input: 100)], now: base.addingTimeInterval(900))
        XCTAssertTrue(gap.windows[0].notes.contains { $0.contains("gap") })
        XCTAssertNil(gap.windows[0].estimatedUSDPer10Percent)
        let corrected = QuotaAuditReport.build(samples: [try sample(40, at: 60), try sample(10, at: 120),
            try sample(60, at: 180)], events: [event(90, input: 100)], now: base.addingTimeInterval(180))
        XCTAssertTrue(corrected.windows[0].notes.contains { $0.contains("decreased") })
        XCTAssertNil(corrected.windows[0].estimatedUSDPer10Percent)
        let missing = QuotaAuditReport.build(samples: [try sample(1, at: 60)], events: nil, now: base.addingTimeInterval(1200))
        XCTAssertTrue(missing.windows[0].notes.contains { $0.contains("unavailable") })
        XCTAssertTrue(missing.windows[0].notes.contains { $0.contains("15 minutes") })
    }

    func testMissingInvalidFutureAndReplayedSamplesDoNotInventReadings() async throws {
        let root = scratch(); defer { try? FileManager.default.removeItem(at: root) }
        let store = QuotaAuditStore(url: root.appendingPathComponent("audit.json"))
        let now = base.addingTimeInterval(120)
        var invalid = usage(10, at: 60)
        invalid.session?.resetsAt = nil
        var report = await store.record(family: "codex", slot: "a", usage: invalid, events: [], now: now)
        XCTAssertTrue(report.windows.isEmpty)
        invalid = usage(10, at: 60); invalid.session?.usedPercent = 101
        XCTAssertNil(QuotaAuditSample(invalid, observedAt: now))
        invalid = usage(10, at: 60); invalid.session?.windowMinutes = 60
        XCTAssertNil(QuotaAuditSample(invalid, observedAt: now))
        XCTAssertNil(QuotaAuditSample(usage(10, at: 1000), observedAt: now))
        _ = await store.record(family: "codex", slot: "a", usage: usage(10, at: 120), events: [], now: now)
        report = await store.record(family: "codex", slot: "a", usage: usage(1, at: 60), events: [], now: now)
        XCTAssertEqual(report.windows[0].samples, 1)
        XCTAssertEqual(report.windows[0].lastPercent, 10)
        report = await store.record(family: "codex", slot: "a", usage: usage(80, at: 120), events: [], now: now)
        XCTAssertEqual(report.windows[0].lastPercent, 10)
        XCTAssertTrue(report.notes.contains { $0.contains("without changing its timestamp") })
    }

    func testCorruptEvidenceAndConcurrentWriterArePreserved() async throws {
        let root = scratch(); defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let url = root.appendingPathComponent("audit.json")
        let damaged = Data("existing damaged evidence".utf8)
        try damaged.write(to: url)
        let store = QuotaAuditStore(url: url)
        let report = await store.record(family: "claude", slot: "a", usage: usage(10, at: 60), events: [],
            now: base.addingTimeInterval(120))
        XCTAssertEqual(try Data(contentsOf: url), damaged)
        XCTAssertTrue(report.notes.contains { $0.contains("left untouched") })
        try FileManager.default.removeItem(at: url)
        guard case .acquired(let lock) = SingleInstanceLock.acquire(at: url.appendingPathExtension("lock")) else {
            XCTAssertTrue(false); return
        }
        let blocked = await store.record(family: "claude", slot: "a", usage: usage(10, at: 60), events: [],
            now: base.addingTimeInterval(120))
        withExtendedLifetime(lock) {}
        XCTAssertTrue(blocked.windows.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
        XCTAssertTrue(blocked.notes.contains { $0.contains("read-only") })
    }

    func testAuditAPIKeepsAccountFiltersAndOriginalReadings() throws {
        let report = QuotaAuditReport.build(samples: [try sample(10, at: 60)], events: [], now: base.addingTimeInterval(120))
        var a = ProviderSnapshot(providerID: "claude", displayName: "A", lines: [])
        a.quotaAudit = report
        var b = ProviderSnapshot(providerID: "claude@12345678", displayName: "B", lines: [])
        b.quotaAudit = report
        let state = LocalUsageAPI.State(enabledOrderedIDs: [a.providerID, b.providerID],
            knownIDs: [a.providerID, b.providerID], snapshots: [a.providerID: a, b.providerID: b])
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        let response = LocalUsageAPI.respond(method: "GET", path: "/v1/audit/claude@12345678", state: state)
        let reports = try decoder.decode([String: QuotaAuditReport].self, from: XCTUnwrap(response.body))
        XCTAssertEqual(Set(reports.keys), [b.providerID])
        XCTAssertEqual(reports[b.providerID]?.windows.first?.readings.first?.sourceAt, base.addingTimeInterval(60))
        XCTAssertEqual(LocalUsageAPI.respond(method: "POST", path: "/v1/audit", state: state).status, 405)
        XCTAssertEqual(LocalUsageAPI.respond(method: "GET", path: "/v1/audit/missing", state: state).status, 404)
        XCTAssertEqual(try JSONDecoder().decode(ProviderSnapshot.self, from: JSONEncoder().encode(a)).quotaAudit, report)
        var old = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(a)) as? [String: Any])
        old.removeValue(forKey: "quotaAudit")
        XCTAssertNil(try JSONDecoder().decode(ProviderSnapshot.self, from: JSONSerialization.data(withJSONObject: old)).quotaAudit)
    }

    func testStrictClaudeAuditRejectsSelectedAccountFallbackAndSharesOwnershipRules() async throws {
        let root = scratch(); defer { try? FileManager.default.removeItem(at: root) }
        let config = root.appendingPathComponent(".claude/projects/test")
        try FileManager.default.createDirectory(at: config, withIntermediateDirectories: true)
        let stamp = OpenUsageISO8601.string(from: base.addingTimeInterval(90))
        let record = #"{"timestamp":"\#(stamp)","message":{"id":"msg","model":"known","usage":{"input_tokens":100,"output_tokens":10}}}"# + "\n"
        try record.write(to: config.appendingPathComponent("unowned.jsonl"), atomically: true, encoding: .utf8)
        let owned = #"{"type":"bridge-session","ownerOrganizationUuid":"org","ownerAccountUuid":"user"}"# + "\n" + record.replacingOccurrences(of: "msg", with: "owned")
        try owned.write(to: config.appendingPathComponent("owned.jsonl"), atomically: true, encoding: .utf8)
        for file in ["owned.jsonl", "unowned.jsonl"] {
            try FileManager.default.setAttributes([.modificationDate: base.addingTimeInterval(90)],
                ofItemAtPath: config.appendingPathComponent(file).path)
        }
        let scanner = ClaudeLogUsageScanner(environment: FakeEnvironment(), homeDirectory: { root },
            incrementalScanner: IncrementalJSONLScanner<ClaudeLogUsageScanner.Entry>(),
            accountUUID: "user", organizationUUID: "org", currentDefaultLoginIdentity: { "user|org" })
        let entries = await scanner.entries(now: base.addingTimeInterval(120), strictOwnership: true)
        XCTAssertEqual(entries?.count, 1)
        XCTAssertEqual(entries?.first?.messageID, "owned")
        let other = ClaudeLogUsageScanner(environment: FakeEnvironment(), homeDirectory: { root },
            incrementalScanner: IncrementalJSONLScanner<ClaudeLogUsageScanner.Entry>(),
            accountUUID: "other", organizationUUID: "other-org", currentDefaultLoginIdentity: { "other|other-org" })
        let otherEntries = await other.entries(now: base.addingTimeInterval(120), strictOwnership: true)
        XCTAssertNil(otherEntries)
    }

    func testTokenBucketsAndNativePricingAreReused() {
        let entry = ClaudeLogUsageScanner.Entry(timestamp: base, tokens: TokenBreakdown(input: 100,
            cacheWrite5m: 200, cacheWrite1h: 300, cacheRead: 400, output: 500), messageID: nil, requestID: nil,
            model: "known")
        let event = QuotaAuditEvent(entry, pricing: pricing)
        var totals = QuotaAuditTotals(); totals.add(event)
        XCTAssertEqual(totals.totalTokens, 1500)
        XCTAssertEqual(totals.cacheWrite, 500)
        XCTAssertEqual(totals.cacheRead, 400)
        XCTAssertEqual(event.costUSD, pricing.estimatedCostDollars(model: "known", tokens: entry.tokens))
        let codex = CodexLogUsageScanner.Event(timestamp: base, model: "unknown", input: 100,
            cached: 40, output: 20, reasoning: 10, total: 120)
        let native = QuotaAuditEvent(codex, pricing: pricing)
        XCTAssertEqual(native.tokens.input, 60)
        XCTAssertEqual(native.tokens.cacheRead, 40)
        XCTAssertEqual(native.totalTokens, 120)
        XCTAssertNil(native.costUSD)
    }

    private func scratch() -> URL { FileManager.default.temporaryDirectory.appendingPathComponent("quota-audit-\(UUID())") }
    private func usage(_ percent: Double, at offset: Double, reset: Double = 18000) -> OrcaUsageReader.Usage {
        OrcaUsageReader.Usage(provider: "claude",
            session: .init(usedPercent: percent, windowMinutes: 300, resetsAt: base.addingTimeInterval(reset).timeIntervalSince1970 * 1000),
            weekly: .init(usedPercent: 42, windowMinutes: 10080, resetsAt: base.addingTimeInterval(604800).timeIntervalSince1970 * 1000),
            updatedAt: base.addingTimeInterval(offset).timeIntervalSince1970 * 1000, status: "ok")
    }
    private func sample(_ percent: Double, at offset: Double, reset: Double = 18000) throws -> QuotaAuditSample {
        try XCTUnwrap(QuotaAuditSample(usage(percent, at: offset, reset: reset), observedAt: base.addingTimeInterval(offset)))
    }
    private func event(_ offset: Double, input: Int, model: String = "known") -> QuotaAuditEvent {
        QuotaAuditEvent(ClaudeLogUsageScanner.Entry(timestamp: base.addingTimeInterval(offset),
            tokens: TokenBreakdown(input: input), messageID: nil, requestID: nil, model: model), pricing: pricing)
    }
}
