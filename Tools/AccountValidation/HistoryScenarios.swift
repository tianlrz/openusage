import Foundation
@testable import OpenUsage

@MainActor
final class OrcaAccountHistoryTests: XCTestCase {
    func testActiveRegistryOverridesDeletedDirectoriesAndLegacyJSON() throws {
        let root = URL(fileURLWithPath: "/fixture/orca")
        let slot = "11111111-1111-1111-1111-111111111111"
        let path = root.appendingPathComponent("claude-profiles/\(slot)/home").path
        let files = FakeFiles([
            root.path + "/orca-profile-index.json": #"{"activeProfileId":"local-default"}"#,
            root.path + "/profiles/local-default/profile-state.db": "exists",
            root.path + "/profiles/local-default/orca-data.json": #"{"settings":{"claudeManagedAccounts":[]}}"#
        ])
        let settings = #"{"claudeManagedAccounts":[{"id":"\#(slot)","managedAuthPath":"\#(path)"}]}"#
        let homes = OrcaAccountDiscovery.registeredHomes(family: "claude", root: root, files: files,
            sqlite: RegistrySQLite(value: settings))
        XCTAssertEqual(homes, [slot: path])
        let unavailable = OrcaAccountDiscovery.registeredHomes(family: "claude", root: root, files: files,
            sqlite: RegistrySQLite(value: nil))
        XCTAssertEqual(unavailable, [:])
    }

    func testProfileClaudeReadsOnlyItsScopedKeychainAndStaysReadOnly() throws {
        let home = "/fixture/orca/claude-profiles/11111111-1111-1111-1111-111111111111/home"
        let account = OrcaClaudeAccount(slot: "11111111-1111-1111-1111-111111111111", home: home,
            identityKey: "user|org", organizationID: "org", label: "Account", profileHome: true)
        let keychain = ScopedClaudeKeychain()
        let store = ClaudeAuthStore(environment: FakeEnvironment(), files: FakeFiles(), keychain: keychain,
                                    orcaAccounts: [account])
        let state = try XCTUnwrap(store.loadCredentialCandidates().first)
        XCTAssertEqual(state.oauth.accessToken, "profile-token")
        XCTAssertNil(state.oauth.refreshToken)
        XCTAssertNil(state.fullData)
        XCTAssertEqual(state.source, .orcaManaged)
        XCTAssertTrue(keychain.readServices.allSatisfy { $0.hasPrefix("Claude Code-credentials-") })
        XCTAssertFalse(try store.save(state, ifUnchanged: store.credentialGeneration()))
    }

    func testHardlinkedHistoryIsUnassignedAcrossAccountsAndCountedOnceWithinAnAccount() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("openusage-hardlinks-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let a = root.appendingPathComponent("a")
        let b = root.appendingPathComponent("b")
        for home in [a, b] {
            try FileManager.default.createDirectory(at: home.appendingPathComponent("sessions"),
                                                    withIntermediateDirectories: true)
        }
        let now = Date()
        let stamp = ISO8601DateFormatter().string(from: now.addingTimeInterval(-60))
        func event(_ input: Int) -> String {
            #"{"timestamp":"\#(stamp)","type":"event_msg","payload":{"type":"token_count","info":{"model":"gpt-5.2","last_token_usage":{"input_tokens":\#(input),"output_tokens":10}}}}"# + "\n"
        }
        let shared = a.appendingPathComponent("sessions/shared.jsonl")
        try event(100).write(to: shared, atomically: true, encoding: .utf8)
        try FileManager.default.linkItem(at: shared, to: b.appendingPathComponent("sessions/shared.jsonl"))
        let unique = a.appendingPathComponent("sessions/unique.jsonl")
        try event(200).write(to: unique, atomically: true, encoding: .utf8)
        let scanner = CodexLogUsageScanner(environment: FakeEnvironment(),
            incrementalScanner: IncrementalJSONLScanner<CodexLogUsageScanner.Event>())
        let pricing = ModelPricing(supplement: PricingSupplement(),
            primary: PricingCatalog(entries: ["gpt-5.2": ModelRates(inputPerMillion: 1,
                outputPerMillion: 2, cacheWritePerMillion: 1, cacheReadPerMillion: 0.1)]),
            secondary: PricingCatalog(entries: [:]))
        let account = await scanner.scan(homes: CodexLogHomes(read: [a], foreign: [b], cache: [a, b]),
                                         now: now, pricing: pricing)
        XCTAssertEqual(account?.series.daily.reduce(0) { $0 + $1.totalTokens }, 210)
        let omitted = await scanner.omittedSharedFileCount
        XCTAssertEqual(omitted, 1)
        let sameAccount = await scanner.scan(homes: CodexLogHomes(read: [a, b], cache: [a, b]),
                                             now: now, pricing: pricing)
        XCTAssertEqual(sameAccount?.series.daily.reduce(0) { $0 + $1.totalTokens }, 320)
        let alias = root.appendingPathComponent("alias")
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: a)
        let aliased = await scanner.scan(homes: CodexLogHomes(read: [a], foreign: [alias], cache: [a]),
                                         now: now, pricing: pricing)
        XCTAssertEqual(aliased?.series.daily.reduce(0) { $0 + $1.totalTokens }, 320)
        try FileManager.default.removeItem(at: unique)
        let empty = await scanner.scan(homes: CodexLogHomes(read: [a], foreign: [b], cache: [a, b]),
                                       now: now, pricing: pricing)
        XCTAssertEqual(empty?.series.daily, [])
    }
}

private struct RegistrySQLite: SQLiteAccessing {
    var value: String?
    func queryValue(path: String, sql: String) throws -> String? { value }
    func execute(path: String, sql: String) throws { preconditionFailure("Read-only") }
}

private final class ScopedClaudeKeychain: KeychainAccessing, @unchecked Sendable {
    var readServices: [String] = []
    func readGenericPassword(service: String) throws -> String? {
        readServices.append(service)
        return service.hasPrefix("Claude Code-credentials-")
            ? #"{"claudeAiOauth":{"accessToken":"profile-token","refreshToken":"owner-refresh"}}"# : nil
    }
    func writeGenericPassword(service: String, value: String) throws { preconditionFailure("Read-only") }
}
