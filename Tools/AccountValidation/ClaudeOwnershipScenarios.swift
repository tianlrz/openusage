import Foundation
import Synchronization
@testable import OpenUsage

@MainActor
final class OrcaClaudeOwnershipTests: XCTestCase {
    private let base = Date(timeIntervalSince1970: 1792824726)
    private let session = "11111111-1111-1111-1111-111111111111"

    func testScopedSessionReaderChecksLiveProcessHomeStartAndMetadataBounds() throws {
        let root = scratch(); defer { try? FileManager.default.removeItem(at: root) }
        let directory = root.appendingPathComponent("sessions")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let metadata = directory.appendingPathComponent("42.json")
        func write(start: Double? = nil) throws {
            let record: [String: Any] = ["pid": 42, "sessionId": session,
                "startedAt": (start ?? base.addingTimeInterval(2).timeIntervalSince1970) * 1000,
                "procStart": "Sat Oct 24 06:52:06 2026", "pidDomain": "darwin"]
            try JSONSerialization.data(withJSONObject: record).write(to: metadata)
        }
        try write()
        let context = OrcaClaudeUsageContext(homes: ["b": root.path], identities: ["b": "user-b|org-b"])
        let good = try OrcaClaudeSessionReader(runner: SessionProcessRunner(home: root.path)).sessions(context: context, now: base.addingTimeInterval(60))
        XCTAssertEqual(good.first?.sessionID, session)
        XCTAssertEqual(good.first?.accountSlot, "b")
        XCTAssertEqual(good.first?.startedAt, base.addingTimeInterval(2))
        for mode in ["wrong-home", "reused-pid", "not-claude", "exited"] {
            let values = try OrcaClaudeSessionReader(runner: SessionProcessRunner(home: root.path, mode: mode))
                .sessions(context: context, now: base.addingTimeInterval(60))
            XCTAssertTrue(values.isEmpty)
        }
        try write(start: base.addingTimeInterval(-30).timeIntervalSince1970)
        let backdated = try OrcaClaudeSessionReader(runner: SessionProcessRunner(home: root.path)).sessions(context: context, now: base.addingTimeInterval(60))
        XCTAssertTrue(backdated.isEmpty)
        try Data(repeating: 65, count: OrcaClaudeSessionReader.maximumMetadataBytes + 1).write(to: metadata)
        let oversized = try OrcaClaudeSessionReader(runner: SessionProcessRunner(home: root.path)).sessions(context: context, now: base.addingTimeInterval(60))
        XCTAssertTrue(oversized.isEmpty)
    }

    func testProvenProcessStartDoesNotBackfillObservationGaps() {
        var ledger = OrcaSessionOwnershipLedger()
        let writer = OrcaSessionWriter(sessionID: session, accountSlot: "b", processKey: "42|birth", startedAt: base)
        ledger.observe([writer], at: base.addingTimeInterval(10))
        XCTAssertEqual(ledger.owner(sessionID: session, at: base.addingTimeInterval(5)), "b")
        ledger.observationFailed()
        ledger.observe([writer], at: base.addingTimeInterval(100))
        XCTAssertNil(ledger.owner(sessionID: session, at: base.addingTimeInterval(50)))
        XCTAssertEqual(ledger.owner(sessionID: session, at: base.addingTimeInterval(100)), "b")
        ledger.boundSpanCount(1)
        XCTAssertEqual(ledger.spans.count, 1)
    }

    func testResumedClaudeHistoryAndAuditSplitAccountsWithoutMovingEarlierTokens() async throws {
        let root = scratch(); defer { try? FileManager.default.removeItem(at: root) }
        let directory = root.appendingPathComponent(".claude/projects/test")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let path = directory.appendingPathComponent(session + ".jsonl")
        func record(_ offset: Double, _ input: Int) -> String {
            let stamp = OpenUsageISO8601.string(from: base.addingTimeInterval(offset))
            return #"{"sessionId":"\#(session)","timestamp":"\#(stamp)","message":{"id":"msg-\#(input)","model":"known","usage":{"input_tokens":\#(input),"output_tokens":0}}}"# + "\n"
        }
        let bridge = #"{"type":"bridge-session","ownerAccountUuid":"user-a","ownerOrganizationUuid":"org-a"}"# + "\n"
        let streamStart = record(20, 50).replacingOccurrences(of: "msg-50", with: "stream")
        let streamFinal = record(70, 70).replacingOccurrences(of: "msg-70", with: "stream")
        try (bridge + record(10, 100) + record(60, 200) + streamStart + streamFinal)
            .write(to: path, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.modificationDate: base.addingTimeInterval(90)], ofItemAtPath: path.path)
        let writer = OrcaSessionWriter(sessionID: session, accountSlot: "b", processKey: "42|birth", startedAt: base.addingTimeInterval(50))
        let reader = FixedClaudeSessions(writers: [writer])
        let ownership = OrcaClaudeUsageOwnership(reader: reader, url: root.appendingPathComponent("ownership.json"))
        let context = OrcaClaudeUsageContext(homes: ["b": "/scoped/b"], identities: ["b": "user-b|org-b"])
        let parser = IncrementalJSONLScanner<ClaudeLogUsageScanner.Entry>()
        func scanner(_ user: String, _ org: String) -> ClaudeLogUsageScanner {
            ClaudeLogUsageScanner(environment: FakeEnvironment(), homeDirectory: { root }, incrementalScanner: parser,
                accountUUID: user, organizationUUID: org, currentDefaultLoginIdentity: { nil },
                orcaOwnershipContext: context, runtimeOwnership: ownership)
        }
        let a = scanner("user-a", "org-a"), b = scanner("user-b", "org-b")
        let first = await a.entries(now: base.addingTimeInterval(90))
        let second = await b.entries(now: base.addingTimeInterval(90))
        let audit = await b.entries(now: base.addingTimeInterval(90), strictOwnership: true)
        XCTAssertEqual(first?.map(\.tokens.input), [100])
        XCTAssertEqual(second?.map(\.tokens.input), [200, 70])
        XCTAssertEqual(audit, second)
        XCTAssertEqual(reader.calls.withLock { $0 }, 1)
        let restored = OrcaClaudeUsageOwnership(reader: FixedClaudeSessions(writers: []), url: root.appendingPathComponent("ownership.json"))
        let restoredState = await restored.snapshot(context: context, now: base.addingTimeInterval(90), startSampler: false)
        XCTAssertEqual(restoredState.owner(session: session, at: base.addingTimeInterval(60)), "user-b|org-b")
    }

    func testAmbiguousConcurrentProcessesAndMissingSessionIDsRemainUnassigned() async throws {
        let root = scratch(); defer { try? FileManager.default.removeItem(at: root) }
        let writers = ["b", "c"].enumerated().map { i, account in
            OrcaSessionWriter(sessionID: session, accountSlot: account, processKey: "\(i)|birth", startedAt: base)
        }
        let store = OrcaClaudeUsageOwnership(reader: FixedClaudeSessions(writers: writers), url: root.appendingPathComponent("ownership.json"))
        let context = OrcaClaudeUsageContext(homes: ["b": "/b", "c": "/c"], identities: ["b": "b|org", "c": "c|org"])
        let state = await store.snapshot(context: context, now: base.addingTimeInterval(10), startSampler: false)
        XCTAssertEqual(state.owner(session: session, at: base.addingTimeInterval(5)), "unassigned")
        let file = JSONLScanning.DiscoveredFile(path: root.appendingPathComponent(session + ".jsonl").path, size: 1, mtime: base)
        let filter = ClaudeSessionUsageFilter(files: [file], target: "b|org", ownership: state, historicalFiles: [file])
        let entry = ClaudeLogUsageScanner.Entry(timestamp: base.addingTimeInterval(5), tokens: TokenBreakdown(input: 100), messageID: "m", requestID: "r", model: "known", sessionID: session)
        XCTAssertTrue(filter.entries([entry]).isEmpty)
        var missing = entry; missing.sessionID = nil
        XCTAssertTrue(filter.entries([missing]).isEmpty)
    }

    func testOwnershipCorruptionIsPreservedAndObservationsCoalesce() async throws {
        let root = scratch(); defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let path = root.appendingPathComponent("ownership.json")
        let broken = Data("corrupt evidence".utf8); try broken.write(to: path)
        let reader = FixedClaudeSessions(writers: [])
        let store = OrcaClaudeUsageOwnership(reader: reader, url: path)
        let context = OrcaClaudeUsageContext(homes: [:], identities: [:])
        let now = base.addingTimeInterval(10)
        let states = await withTaskGroup(of: OrcaClaudeUsageOwnership.Snapshot.self) { group in
            for _ in 0..<20 { group.addTask { await store.snapshot(context: context, now: now, startSampler: false) } }
            var values: [OrcaClaudeUsageOwnership.Snapshot] = []
            for await value in group { values.append(value) }
            return values
        }
        XCTAssertEqual(reader.calls.withLock { $0 }, 1)
        XCTAssertTrue(states.allSatisfy { $0.warning != nil })
        XCTAssertEqual(try Data(contentsOf: path), broken)
    }

    private func scratch() -> URL { FileManager.default.temporaryDirectory.appendingPathComponent("ClaudeOwnership-\(UUID())") }
}

private final class FixedClaudeSessions: OrcaClaudeSessionReading, Sendable {
    let writers: [OrcaSessionWriter]
    let calls = Mutex(0)
    init(writers: [OrcaSessionWriter]) { self.writers = writers }
    func sessions(context: OrcaClaudeUsageContext, now: Date) throws -> [OrcaSessionWriter] {
        calls.withLock { $0 += 1 }; Thread.sleep(forTimeInterval: 0.02); return writers
    }
}

private final class SessionProcessRunner: ProcessRunning, Sendable {
    let home: String
    let mode: String
    let starts = Mutex(0)
    init(home: String, mode: String = "valid") { self.home = home; self.mode = mode }
    func run(executable: String, arguments: [String], environment: [String: String], timeout: TimeInterval) throws -> ProcessResult {
        XCTAssertEqualEnvironment.check(environment)
        if mode == "exited" { return ProcessResult(exitCode: 1, stdout: "", stderr: "") }
        let output: String
        if arguments.last == "comm=" { output = mode == "not-claude" ? "/bin/other" : "/bin/claude" }
        else if arguments.last == "lstart=" {
            let count = starts.withLock { $0 += 1; return $0 }
            output = mode == "reused-pid" && count > 1 ? "Sat Oct 24 06:52:07 2026" : "Sat Oct 24 06:52:06 2026"
        } else { output = "claude CLAUDE_CONFIG_DIR=\(mode == "wrong-home" ? "/other" : home) TOKEN=private-fixture" }
        return ProcessResult(exitCode: 0, stdout: output, stderr: "")
    }
}
private enum XCTAssertEqualEnvironment {
    static func check(_ environment: [String: String]) { precondition(environment["TZ"] == "UTC" && environment["LC_ALL"] == "C") }
}
