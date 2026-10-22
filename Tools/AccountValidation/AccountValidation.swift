import Foundation
@testable import OpenUsage

@MainActor private var assertions = 0
@MainActor func XCTAssertTrue(_ value: Bool, file: StaticString = #fileID, line: UInt = #line) {
    assertions += 1
    if !value { FileHandle.standardError.write(Data("FAIL at \(file):\(line)\n".utf8)); exit(1) }
}
@MainActor func XCTAssertFalse(_ value: Bool) { XCTAssertTrue(!value) }
@MainActor func XCTAssertNil<T>(_ value: T?) { XCTAssertTrue(value == nil) }
@MainActor func XCTAssertEqual<T: Equatable>(_ a: T, _ b: T, file: StaticString = #fileID, line: UInt = #line) {
    if a != b { FileHandle.standardError.write(Data("Actual: \(a); expected: \(b)\n".utf8)) }
    XCTAssertTrue(a == b, file: file, line: line)
}
func XCTUnwrap<T>(_ value: T?) throws -> T {
    guard let value else { throw NSError(domain: "AccountValidation", code: 1) }
    return value
}
@MainActor class XCTestCase {
    private var suites: [String] = []
    func makeScratchDefaults(_ name: String) -> UserDefaults {
        let suite = "OpenUsageLocalValidation.\(name).\(UUID().uuidString)"
        suites.append(suite)
        return UserDefaults(suiteName: suite)!
    }
    func cleanup() { for suite in suites { UserDefaults.standard.removePersistentDomain(forName: suite) } }
}
@main enum AccountValidation {
    @MainActor static func main() async throws {
        if CommandLine.arguments.contains("--local-discovery") {
            let suite = "OpenUsageLocalDiscovery.\(UUID().uuidString)"
            let defaults = UserDefaults(suiteName: suite)!
            defer { defaults.removePersistentDomain(forName: suite) }
            let observer = DefaultAccountObserver(keychain: FakeKeychain())
            let assembly = await ProviderAccountAssembly.make(observer: observer,
                accountsStore: ProviderAccountsStore(defaults: defaults),
                desktop: ClaudeDesktopAuthStore(keyReader: NoDesktopKey()))
            print("Local metadata discovery (no network, no credential writes):")
            print("Claude cards: \(assembly.claudeCards.count); Orca logins: \(assembly.claudeCards.flatMap(\.orcaAccounts).count)")
            print("Codex cards: \(assembly.codex.cards.count); discovered homes: \(assembly.codex.historyHomes.homes.count)")
            return
        }
        let tests = OrcaAccountDiscoveryTests()
        defer { tests.cleanup() }
        tests.testDiscoversOnlyMarkedCodexHomesAndNoTraversalSlots()
        try await tests.testBothCodexAccountsHaveTheirOwnHomesAndReadOnlyCredentials()
        try tests.testManagedCodexHomeIsReadOnlyEvenWhenConfiguredAsTheDefault()
        try tests.testManagedCodexCredentialCannotBypassTheExpectedAccount()
        try await tests.testClaudeAccountsDeduplicateTheDefaultLoginAndRemainStable()
        try tests.testClaudeReadsTheSpecificKeychainSlotWithoutRotatingOrWriting()
        try tests.testMissingClaudeCredentialNeverFallsBackToAnotherLogin()
        let history = OrcaAccountHistoryTests()
        try history.testActiveRegistryOverridesDeletedDirectoriesAndLegacyJSON()
        try history.testProfileClaudeReadsOnlyItsScopedKeychainAndStaysReadOnly()
        try await history.testHardlinkedHistoryIsUnassignedAcrossAccountsAndCountedOnceWithinAnAccount()
        let cli = OrcaUsageReaderTests()
        try cli.testEachAccountReceivesItsOwnQuotaInsteadOfTheActiveAccountsQuota()
        try cli.testRemoteActiveQuotaNeverBecomesTheLocalAccountsQuota()
        try await cli.testFourCardsShareOneReadOnlyCLIQuery()
        print("PASS: 13 account-isolation regression scenarios; \(assertions) assertions. Standalone CLT runner, not XCTest.")
    }
}

private struct NoDesktopKey: ClaudeDesktopSafeStorageKeyReading {
    func readPassword(allowInteraction: Bool) throws -> String? { nil }
}
