import Foundation
import XCTest
@testable import OpenUsage

@MainActor
final class OrcaUsageReaderTests: XCTestCase {
    private func reply(target: String = "host") throws -> String {
        func usage(_ family: String, _ percent: Int) -> [String: Any] {
            ["provider": family, "session": ["usedPercent": percent, "windowMinutes": 300],
             "weekly": ["usedPercent": percent + 1, "windowMinutes": 10080],
             "updatedAt": Date().timeIntervalSince1970 * 1000, "status": "ok"]
        }
        let payload: [String: Any] = [
            "claude": ["accounts": [["id": "ca"], ["id": "cb"]], "activeAccountId": "ca"],
            "codex": ["accounts": [["id": "xa", "workspaceAccountId": "wa"],
                                     ["id": "xb", "workspaceAccountId": "wb"]],
                      "activeAccountId": "xa"],
            "rateLimits": ["claudeTarget": ["runtime": target], "codexTarget": ["runtime": target],
                "claude": usage("claude", 15), "codex": usage("codex", 70),
                "inactiveClaudeAccounts": [["accountId": "cb", "rateLimits": usage("claude", 35)]],
                "inactiveCodexAccounts": [["accountId": "xb", "rateLimits": usage("codex", 20)]]]
        ]
        return String(decoding: try JSONSerialization.data(withJSONObject: ["ok": true, "result": payload]), as: UTF8.self)
    }

    func testEachAccountReceivesItsOwnQuotaInsteadOfTheActiveAccountsQuota() throws {
        let payload = try JSONDecoder().decode(OrcaUsageReader.Envelope.self, from: Data(reply().utf8)).result
        XCTAssertEqual(try payload.usage(family: "claude", slot: "ca", workspace: nil).session?.usedPercent, 15)
        XCTAssertEqual(try payload.usage(family: "claude", slot: "cb", workspace: nil).session?.usedPercent, 35)
        XCTAssertEqual(try payload.usage(family: "codex", slot: "xa", workspace: "wa").session?.usedPercent, 70)
        XCTAssertEqual(try payload.usage(family: "codex", slot: "xb", workspace: "wb").session?.usedPercent, 20)
        var rejected = false
        do { _ = try payload.usage(family: "codex", slot: "xb", workspace: "wa") }
        catch { rejected = true }
        XCTAssertTrue(rejected)
        var deleted = false
        do { _ = try payload.usage(family: "claude", slot: "deleted", workspace: nil) }
        catch { deleted = true }
        XCTAssertTrue(deleted)
    }

    func testRemoteActiveQuotaNeverBecomesTheLocalAccountsQuota() throws {
        let payload = try JSONDecoder().decode(OrcaUsageReader.Envelope.self, from: Data(reply(target: "wsl").utf8)).result
        var rejected = false
        do { _ = try payload.usage(family: "codex", slot: "xa", workspace: "wa") }
        catch { rejected = true }
        XCTAssertTrue(rejected)
        XCTAssertEqual(try payload.usage(family: "codex", slot: "xb", workspace: "wb").session?.usedPercent, 20)
    }

    func testFourCardsShareOneReadOnlyCLIQuery() async throws {
        let runner = OrcaFixtureProcess(reply: try reply())
        let reader = OrcaUsageReader(runner: runner, executable: "/fixture/orca")
        _ = try await reader.usage(family: "claude", slot: "ca")
        _ = try await reader.usage(family: "claude", slot: "cb")
        _ = try await reader.usage(family: "codex", slot: "xa", workspace: "wa")
        _ = try await reader.usage(family: "codex", slot: "xb", workspace: "wb")
        XCTAssertEqual(runner.calls, 1)
        XCTAssertEqual(runner.arguments, ["account", "list", "--json"])
    }
}

private final class OrcaFixtureProcess: ProcessRunning, @unchecked Sendable {
    let reply: String
    var calls = 0
    var arguments: [String] = []
    init(reply: String) { self.reply = reply }
    func run(executable: String, arguments: [String], environment: [String: String], timeout: TimeInterval) throws -> ProcessResult {
        calls += 1
        self.arguments = arguments
        return ProcessResult(exitCode: 0, stdout: reply, stderr: "")
    }
}
