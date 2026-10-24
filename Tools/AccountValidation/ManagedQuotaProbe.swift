import Foundation
@testable import OpenUsage

@MainActor
enum ManagedQuotaProbe {
    static func run() async throws {
        KeychainAccessGuard.holdPopups()
        let suite = "OpenUsageQuotaProbe.\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        if let records = UserDefaults(suiteName: "com.robinebers.openusage")?.data(forKey: "openusage.providerAccounts.v1") {
            defaults.set(records, forKey: "openusage.providerAccounts.v1")
        }
        let assembly = await ProviderAccountAssembly.make(observer: DefaultAccountObserver(keychain: FakeKeychain()),
            accountsStore: ProviderAccountsStore(defaults: defaults), desktop: ClaudeDesktopAuthStore(keyReader: ProbeDesktopKey()))
        let providers = ProviderCatalog.make(defaults: defaults, claudeCards: assembly.claudeCards,
            codex: assembly.codex, claudeIdentityKeys: assembly.identityKeysByCard)
        for runtime in providers {
            do {
                if let claude = runtime as? ClaudeProvider, !claude.authStore.orcaAccounts.isEmpty {
                    let store = claude.authStore
                    guard let expected = store.expectedIdentityKey,
                          let account = store.orcaAccounts.first,
                          let state = await loadOffMainActor({ store.loadOrcaCredential(account) }),
                          let token = state.oauth.accessToken else {
                        print("\(runtime.provider.id): scoped credential unavailable (no popup, no login change)")
                        continue
                    }
                    let config = try store.oauthConfig()
                    let verification = try await claude.usageClient.verifyAccount(accessToken: token,
                        expectedIdentityKey: expected, config: config)
                    guard case .verified = verification else {
                        if case .failed(let reply) = verification { print("\(runtime.provider.id): profile HTTP \(reply.statusCode)") }
                        continue
                    }
                    let response = try await claude.usageClient.fetchUsage(accessToken: token, config: config)
                    print("\(runtime.provider.id): verified profile; usage HTTP \(response.statusCode)")
                    if (200..<300).contains(response.statusCode) {
                        let mapped = try ClaudeUsageMapper.mapUsageResponse(response, credentials: state.oauth)
                        readings(runtime.provider.id, mapped.lines)
                    }
                } else if let codex = runtime as? CodexProvider, codex.orcaAccountSlot != nil {
                    let store = codex.authStore
                    guard let credential = await loadOffMainActor({ store.loadAuthCandidates().first(where: \.hasUsableAccessToken) }),
                          let token = credential.auth.tokens?.accessToken else {
                        print("\(runtime.provider.id): scoped credential unavailable")
                        continue
                    }
                    let response = try await codex.usageClient.fetchUsage(accessToken: token, accountID: store.expectedIdentity?.accountID)
                    print("\(runtime.provider.id): scoped login; usage HTTP \(response.statusCode)")
                    if (200..<300).contains(response.statusCode) {
                        readings(runtime.provider.id, try CodexUsageMapper.mapUsageResponse(response).lines)
                    }
                }
            } catch {
                print("\(runtime.provider.id): read-only probe failed (\(String(describing: type(of: error))))")
            }
        }
    }

    static func claudeHistory() async throws {
        KeychainAccessGuard.holdPopups()
        let suite = "OpenUsageClaudeHistoryProbe.\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        if let records = UserDefaults(suiteName: "com.robinebers.openusage")?.data(forKey: "openusage.providerAccounts.v1") {
            defaults.set(records, forKey: "openusage.providerAccounts.v1")
        }
        let assembly = await ProviderAccountAssembly.make(observer: DefaultAccountObserver(keychain: FakeKeychain()),
            accountsStore: ProviderAccountsStore(defaults: defaults), desktop: ClaudeDesktopAuthStore(keyReader: ProbeDesktopKey()))
        let providers = ProviderCatalog.make(defaults: defaults, claudeCards: assembly.claudeCards,
            codex: assembly.codex, claudeIdentityKeys: assembly.identityKeysByCard)
        for provider in providers {
            guard let claude = provider as? ClaudeProvider else { continue }
            let entries = await claude.logUsageScanner.entries(strictOwnership: true) ?? []
            let today = Calendar.current.startOfDay(for: Date())
            let recent = entries.filter { $0.timestamp >= today }
            print("\(provider.provider.id): today \(recent.count) entries, \(recent.reduce(0) { $0 + $1.tokens.totalTokens }) tokens; \(entries.count) retained entries")
        }
        await ClaudeLogUsageScanner.flushPersistentCacheWrites()
        print("Probe RSS: \(try rssKiB()) KiB; no model requests or account changes")
    }

    static func ownerRefresh() async throws {
        let reader = OrcaUsageReader.shared
        let source = try await reader.snapshot()
        let requests = source.claude.accounts.map { ("claude", $0.id, Optional<String>.none) }
            + source.codex.accounts.map { ("codex", $0.id, $0.workspaceAccountId ?? $0.providerAccountId) }
        for (family, slot, workspace) in requests {
            do {
                let usage = try await reader.usage(family: family, slot: slot, workspace: workspace)
                print("\(family):\(slot.prefix(8)): source \(OpenUsageISO8601.string(from: usage.fetchedAt)); session \(usage.session?.usedPercent.description ?? "missing")")
            } catch {
                print("\(family):\(slot.prefix(8)): unavailable (owner reports this login needs attention)")
            }
        }
        let before = try rssKiB()
        for _ in 0..<100 {
            for (family, slot, workspace) in requests {
                _ = try? await reader.usage(family: family, slot: slot, workspace: workspace)
            }
        }
        let after = try rssKiB()
        print("Quota-reader process RSS after warm-up: \(before) KiB; after \(100 * requests.count) cached reads: \(after) KiB. Excludes application UI/history.")
    }

    private static func rssKiB() throws -> Int {
        let result = try SystemProcessRunner().run(executable: "/bin/ps",
            arguments: ["-o", "rss=", "-p", String(ProcessInfo.processInfo.processIdentifier)],
            environment: [:], timeout: 5)
        return Int(result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0
    }

    private static func readings(_ card: String, _ lines: [MetricLine]) {
        for line in lines {
            if case .progress(let label, let used, _, _, let reset, _, _) = line,
               label == "Session" || label == "Weekly" {
                print("\(card): \(label) \(used)% used; reset \(reset.map { OpenUsageISO8601.string(from: $0) } ?? "not supplied")")
            }
        }
    }
}

private struct ProbeDesktopKey: ClaudeDesktopSafeStorageKeyReading {
    func readPassword(allowInteraction: Bool) throws -> String? { nil }
}
