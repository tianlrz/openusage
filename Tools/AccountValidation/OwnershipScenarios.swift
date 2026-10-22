import Foundation
@testable import OpenUsage

@MainActor
final class OrcaCodexOwnershipTests: XCTestCase {
    private let base = Date(timeIntervalSince1970: 1_800_000_000)
    private let a = "11111111-1111-1111-1111-111111111111"
    private let b = "22222222-2222-2222-2222-222222222222"

    func testWriterReaderUsesWritableFilesAndHandlesSpacesWithoutRetainingCredentials() {
        let environment = "codex PATH=/bin CODEX_HOME=/fixture/Application Support/orca/home TOKEN=private-fixture"
        XCTAssertEqual(OrcaCodexWriterReader.environmentHome(environment), "/fixture/Application Support/orca/home")
        let files = "f1\nar\nn/fixture/rollout-\(a).jsonl\nf2\nau\nn/fixture/rollout-\(b).jsonl\nf3\naw\nn/fixture/not-a-session.jsonl\n"
        let writers = OrcaCodexWriterReader.parseFiles(files, account: a, processKey: "42|start")
        XCTAssertEqual(writers.count, 1)
        XCTAssertEqual(writers.first?.sessionID, b)
        XCTAssertEqual(writers.first?.accountSlot, a)
    }

    func testConcurrentSessionsFollowTheirOwnWriters() {
        var ledger = OrcaCodexOwnershipLedger()
        let writers = [writer(a, account: a, process: "1|old"), writer(b, account: b, process: "2|old")]
        ledger.observe(writers, at: base)
        ledger.observe(writers, at: base.addingTimeInterval(15))
        XCTAssertEqual(ledger.owner(sessionID: a, at: base.addingTimeInterval(5)), a)
        XCTAssertEqual(ledger.owner(sessionID: b, at: base.addingTimeInterval(5)), b)
        XCTAssertNil(ledger.owner(sessionID: nil, at: base.addingTimeInterval(5)))
    }

    func testSwitchingAResumedSessionDoesNotMoveEarlierUsage() throws {
        var ledger = OrcaCodexOwnershipLedger()
        ledger.observe([writer(a, account: a, process: "1|old")], at: base)
        ledger.observe([writer(a, account: a, process: "1|old")], at: base.addingTimeInterval(15))
        ledger.observe([writer(a, account: b, process: "2|new")], at: base.addingTimeInterval(20))
        ledger.observe([writer(a, account: b, process: "2|new")], at: base.addingTimeInterval(35))
        let restored = try JSONDecoder().decode(OrcaCodexOwnershipLedger.self, from: JSONEncoder().encode(ledger))
        XCTAssertEqual(restored.owner(sessionID: a, at: base.addingTimeInterval(5)), a)
        XCTAssertNil(restored.owner(sessionID: a, at: base.addingTimeInterval(18)))
        XCTAssertEqual(restored.owner(sessionID: a, at: base.addingTimeInterval(25)), b)
    }

    func testGapsFailuresAndReusedPIDsDoNotInventOwnership() {
        var ledger = OrcaCodexOwnershipLedger()
        ledger.observe([writer(a, account: a, process: "1|old")], at: base)
        ledger.observe([writer(a, account: a, process: "1|old")], at: base.addingTimeInterval(90))
        XCTAssertNil(ledger.owner(sessionID: a, at: base.addingTimeInterval(30)))
        ledger.observationFailed()
        ledger.observe([writer(a, account: a, process: "1|old")], at: base.addingTimeInterval(100))
        XCTAssertNil(ledger.owner(sessionID: a, at: base.addingTimeInterval(95)))
        ledger.observe([writer(a, account: b, process: "1|new")], at: base.addingTimeInterval(110))
        XCTAssertNil(ledger.owner(sessionID: a, at: base.addingTimeInterval(105)))
    }

    func testHistoricalAllocationAndFuturePartitionsConserveUniqueEvents() {
        var ledger = OrcaCodexOwnershipLedger()
        let writers = [writer(a, account: a, process: "1"), writer(b, account: b, process: "2")]
        ledger.observe(writers, at: base)
        ledger.observe(writers, at: base.addingTimeInterval(15))
        let old = event(a, offset: -5, tokens: 100)
        let ea = event(a, offset: 5, tokens: 200)
        let eb = event(b, offset: 6, tokens: 300)
        let pending = event(nil, offset: 7, tokens: 400)
        let allocation = OrcaCodexHistoryAllocation(historicalAccountSlot: b,
                                                   historicalThrough: base.timeIntervalSince1970)
        let partitions = ledger.partition([old, old, ea, eb, pending], allocation: allocation)
        XCTAssertEqual(total(partitions[a]), 200)
        XCTAssertEqual(total(partitions[b]), 400)
        XCTAssertEqual(total(partitions["unassigned"]), 400)
        XCTAssertEqual(partitions.values.flatMap { $0 }.reduce(0) { $0 + $1.total }, 1000)
        let conflict = ledger.partition([ea, event(b, offset: 5, tokens: 200)], allocation: nil)
        XCTAssertEqual(total(conflict["unassigned"]), 200)
        XCTAssertEqual(total(conflict[a]), 0)
        XCTAssertEqual(total(conflict[b]), 0)
    }

    func testSessionIdentitySurvivesIncrementalParserBatches() {
        var parser = CodexLogFileParser()
        _ = parser.parse(Data(#"{"type":"session_meta","payload":{"id":"\#(a)"}}"#.utf8))
        let line = #"{"type":"event_msg","timestamp":"2027-01-15T08:00:00Z","payload":{"type":"token_count","info":{"model":"gpt-5.2","last_token_usage":{"input_tokens":5,"output_tokens":2}}}}"#
        let events = parser.parse(Data(line.utf8))
        XCTAssertEqual(events.count, 1)
        XCTAssertEqual(events.first?.sessionID, a)
        XCTAssertEqual(events.first?.total, 7)
    }

    func testSharedFileIsCountedOnceAndHistoricalOwnerReceivesTheWholeBaseline() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("ownership-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let first = root.appendingPathComponent("a/sessions")
        let second = root.appendingPathComponent("b/sessions")
        try FileManager.default.createDirectory(at: first, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: second, withIntermediateDirectories: true)
        let stamp = ISO8601DateFormatter().string(from: Date().addingTimeInterval(-60))
        let contents = #"{"type":"session_meta","payload":{"id":"\#(a)"}}"# + "\n"
            + #"{"type":"event_msg","timestamp":"\#(stamp)","payload":{"type":"token_count","info":{"model":"gpt-5.2","last_token_usage":{"input_tokens":100,"output_tokens":20}}}}"# + "\n"
        let log = first.appendingPathComponent("rollout-\(a).jsonl")
        try contents.write(to: log, atomically: true, encoding: .utf8)
        try FileManager.default.linkItem(at: log, to: second.appendingPathComponent(log.lastPathComponent))
        let context = OrcaCodexHistoryContext(homes: [a: first.deletingLastPathComponent().path,
            b: second.deletingLastPathComponent().path], allHistoryHomes: [
                first.deletingLastPathComponent().path, second.deletingLastPathComponent().path])
        let policy = OrcaCodexHistoryAllocation(historicalAccountSlot: b, historicalThrough: Date().timeIntervalSince1970)
        let scanner = CodexLogUsageScanner(incrementalScanner: IncrementalJSONLScanner<CodexLogUsageScanner.Event>())
        let store = OrcaCodexHistory(scanner: scanner, reader: NoOwnershipWriters(),
            ledgerURL: root.appendingPathComponent("ledger.json"), allocation: { policy })
        let pricing = ModelPricing(supplement: PricingSupplement(), primary: PricingCatalog(entries: [
            "gpt-5.2": ModelRates(inputPerMillion: 1, outputPerMillion: 2,
                cacheWritePerMillion: 1, cacheReadPerMillion: 0.1)]), secondary: PricingCatalog(entries: [:]))
        let now = Date()
        let owner = await store.scan(accountSlot: b, context: context, now: now, pricing: pricing)
        let other = await store.scan(accountSlot: a, context: context, now: now, pricing: pricing)
        let pending = await store.scan(accountSlot: nil, context: context, now: now, pricing: pricing)
        XCTAssertEqual(owner?.series.daily.reduce(0) { $0 + $1.totalTokens }, 120)
        XCTAssertEqual(other?.series.daily.reduce(0) { $0 + $1.totalTokens }, 0)
        XCTAssertEqual(pending?.series.daily.reduce(0) { $0 + $1.totalTokens }, 0)
    }

    func testUnassignedUsageNeverExportsAsAnAccountOwnedHistory() {
        let provider = CodexUnassignedUsageProvider(context: OrcaCodexHistoryContext(homes: [:], allHistoryHomes: []))
        XCTAssertTrue(provider.widgetDescriptors.allSatisfy { $0.historyResource == nil })
        XCTAssertTrue(provider.widgetDescriptors.allSatisfy { $0.limitResources.isEmpty })
        XCTAssertTrue(provider.provider.id.range(of: #"^codex@[a-f0-9]{8}$"#, options: .regularExpression) != nil)
    }

    private func writer(_ session: String, account: String, process: String) -> OrcaCodexWriter {
        OrcaCodexWriter(sessionID: session, accountSlot: account, processKey: process)
    }
    private func event(_ session: String?, offset: Double, tokens: Int) -> CodexLogUsageScanner.Event {
        CodexLogUsageScanner.Event(timestamp: base.addingTimeInterval(offset), model: "gpt-5.2",
            input: tokens, cached: 0, output: 0, reasoning: 0, total: tokens, sessionID: session)
    }
    private func total(_ events: [CodexLogUsageScanner.Event]?) -> Int {
        (events ?? []).reduce(0) { $0 + $1.total }
    }
}

private struct NoOwnershipWriters: OrcaCodexWriterReading {
    func writers(homes: [String: String]) throws -> [OrcaCodexWriter] { [] }
}
