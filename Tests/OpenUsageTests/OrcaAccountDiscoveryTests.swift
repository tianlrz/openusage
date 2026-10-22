import XCTest
@testable import OpenUsage

@MainActor
final class OrcaAccountDiscoveryTests: XCTestCase {
    private let home = CodexMultiAccountFixtures.home
    private let slotA = "11111111-1111-1111-1111-111111111111"
    private let slotB = "22222222-2222-2222-2222-222222222222"
    private let org = "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa"
    private var root: String { home.appendingPathComponent("Library/Application Support/orca").path }

    private func homes(_ family: String) -> [String: [String]] {
        [root + "/\(family)-accounts": [slotB, "../escape", slotA]]
    }

    private func fixtureFiles() -> FakeFiles {
        var records: [String: String] = [:]
        for (slot, email) in [(slotA, "a@test"), (slotB, "b@test")] {
            let codex = root + "/codex-accounts/\(slot)/home"
            records[codex + "/.orca-managed-home"] = slot
            records[codex + "/auth.json"] = CodexMultiAccountFixtures.codexAuth(accountID: slot, email: email)
            let claude = root + "/claude-accounts/\(slot)/auth"
            records[claude + "/.orca-managed-claude-auth"] = slot
            records[claude + "/oauth-account.json"] = #"{"accountUuid":"\#(slot)","organizationUuid":"\#(org)","emailAddress":"\#(email)"}"#
        }
        return FakeFiles(records)
    }

    func testDiscoversOnlyMarkedCodexHomesAndNoTraversalSlots() {
        let files = fixtureFiles()
        let directories = homes("codex")
        let scanner = CodexHomeScanner(environment: FakeEnvironment(), files: files,
            homeDirectory: { [home] in home }, listDirectories: { directories[$0] ?? [] })
        XCTAssertEqual(scanner.logins().count, 2)
        files.files.removeValue(forKey: root + "/codex-accounts/\(slotB)/home/.orca-managed-home")
        XCTAssertEqual(scanner.logins().map(\.identity.email), ["a@test"])
    }

    func testBothCodexAccountsHaveTheirOwnHomesAndReadOnlyCredentials() async throws {
        let files = fixtureFiles()
        let directories = homes("codex")
        let observer = DefaultAccountObserver(environment: FakeEnvironment(), files: files,
            keychain: FakeKeychain(), homeDirectory: { [home] in home })
        let assembly = await ProviderAccountAssembly.make(observer: observer,
            accountsStore: ProviderAccountsStore(defaults: makeScratchDefaults("Orca")),
            listCodexHomeDirectories: { directories[$0] ?? [] })
        XCTAssertEqual(assembly.codex.cards.count, 2)
        for card in assembly.codex.cards {
            XCTAssertEqual(card.authHomes.count, 1)
            let auth = CodexAuthStore(environment: FakeEnvironment(), files: files, keychain: FakeKeychain(),
                expectedIdentity: card.identity, additionalAuthHomes: card.authHomes,
                writableAuthHomes: Set(card.writableAuthHomes))
            let state = try XCTUnwrap(auth.loadAuthCandidates().first)
            XCTAssertTrue(state.readOnly)
            XCTAssertNil(state.auth.tokens?.refreshToken)
            XCTAssertEqual(CodexAccountIdentity(auth: state.auth), card.identity)
        }
    }

    func testManagedCodexHomeIsReadOnlyEvenWhenConfiguredAsTheDefault() throws {
        let path = root + "/codex-accounts/\(slotA)/home"
        let store = CodexAuthStore(environment: FakeEnvironment(["CODEX_HOME": path]),
            files: fixtureFiles(), keychain: FakeKeychain())
        let state = try XCTUnwrap(store.loadAuthCandidates().first)
        XCTAssertTrue(state.readOnly)
        XCTAssertNil(state.auth.tokens?.refreshToken)
    }

    func testManagedCodexCredentialCannotBypassTheExpectedAccount() throws {
        let path = root + "/codex-accounts/\(slotA)/home"
        let files = fixtureFiles()
        let other = try XCTUnwrap(CodexAuthStore.parseAuth(CodexMultiAccountFixtures.codexAuth(accountID: slotB, email: "b@test")))
        let store = CodexAuthStore(environment: FakeEnvironment(["CODEX_HOME": path]), files: files,
            keychain: FakeKeychain(), expectedIdentity: CodexAccountIdentity(auth: other))
        XCTAssertTrue(store.loadAuthCandidates().isEmpty)
    }

    func testClaudeAccountsDeduplicateTheDefaultLoginAndRemainStable() async throws {
        let files = fixtureFiles()
        files.files[home.path + "/.claude.json"] = #"{"oauthAccount":{"accountUuid":"\#(slotA)","organizationUuid":"\#(org)"}}"#
        let directories = homes("claude")
        let observer = DefaultAccountObserver(environment: FakeEnvironment(), files: files,
            keychain: FakeKeychain(), homeDirectory: { [home] in home })
        let store = ProviderAccountsStore(defaults: makeScratchDefaults("OrcaClaude"))
        let assembly = await ProviderAccountAssembly.make(observer: observer, accountsStore: store,
            listCodexHomeDirectories: { directories[$0] ?? [] })
        XCTAssertEqual(assembly.claudeCards.count, 2)
        XCTAssertTrue(assembly.claudeCards.allSatisfy { $0.orcaAccounts.count == 1 })
        XCTAssertTrue(assembly.claudeCards.allSatisfy { !$0.allowsUnattributedPiUsage })
        XCTAssertTrue(assembly.claudeCards.allSatisfy { $0.additionalLogDirectories.count == 2 })
        let again = await ProviderAccountAssembly.make(observer: observer, accountsStore: store,
            listCodexHomeDirectories: { directories[$0] ?? [] })
        XCTAssertEqual(assembly.claudeCards, again.claudeCards)
    }

    func testClaudeReadsTheSpecificKeychainSlotWithoutRotatingOrWriting() throws {
        let files = fixtureFiles()
        let directories = homes("claude")
        let accounts = OrcaClaudeAccount.discover(environment: FakeEnvironment(), files: files,
            home: home, listDirectories: { directories[$0] ?? [] })
        let keychain = OrcaFixtureKeychain(values: [slotA: credentials("token-a"), slotB: credentials("token-b")])
        for account in accounts {
            let store = ClaudeAuthStore(environment: FakeEnvironment(["CLAUDE_CODE_OAUTH_TOKEN": "foreign"]),
                files: files, keychain: keychain, expectedIdentityKey: account.identityKey, orcaAccounts: [account])
            let state = try XCTUnwrap(store.loadCredentialCandidates().first)
            XCTAssertEqual(state.oauth.accessToken, account.slot == slotA ? "token-a" : "token-b")
            XCTAssertNil(state.oauth.refreshToken)
            XCTAssertNil(state.fullData)
            XCTAssertEqual(state.source, .orcaManaged)
            XCTAssertFalse(try store.save(state, ifUnchanged: store.credentialGeneration()))
        }
        XCTAssertEqual(Set(keychain.accounts), Set([slotA, slotB]))
        XCTAssertEqual(keychain.writes, 0)
    }

    func testMissingClaudeCredentialNeverFallsBackToAnotherLogin() throws {
        let account = OrcaClaudeAccount(slot: slotA, home: "/managed/auth", identityKey: slotA + "|" + org,
            organizationID: org, label: "A")
        let store = ClaudeAuthStore(environment: FakeEnvironment(["CLAUDE_CODE_OAUTH_TOKEN": "foreign"]),
            files: FakeFiles(), keychain: OrcaFixtureKeychain(values: [:]), orcaAccounts: [account])
        XCTAssertTrue(store.loadCredentialCandidates().isEmpty)
    }

    private func credentials(_ token: String) -> String {
        #"{"claudeAiOauth":{"accessToken":"\#(token)","refreshToken":"never-rotate","expiresAt":4102444800000,"scopes":["user:profile"]}}"#
    }
}

private final class OrcaFixtureKeychain: KeychainAccessing, @unchecked Sendable {
    let values: [String: String]
    var accounts: [String] = []
    var writes = 0
    init(values: [String: String]) { self.values = values }
    func readGenericPassword(service: String) throws -> String? { nil }
    func readGenericPassword(service: String, account: String) throws -> String? {
        guard service == "Orca Claude Code Managed Credentials" else { return nil }
        accounts.append(account)
        return values[account]
    }
    func writeGenericPassword(service: String, value: String) throws { writes += 1 }
}
