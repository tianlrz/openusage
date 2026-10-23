import Foundation
import XCTest
@testable import OpenUsage

@MainActor
final class QuotaSnapshotPersistenceTests: XCTestCase {
    func testResetCreditsUseExistingRowAndRejectMissingOrNegativeCounts() throws {
        func usage(_ resets: String) throws -> OrcaUsageReader.Usage {
            let json = "{\"provider\":\"codex\",\"updatedAt\":1800000000000,\"rateLimitResetCredits\":" + resets + "}"
            return try JSONDecoder().decode(OrcaUsageReader.Usage.self, from: Data(json.utf8))
        }
        let credits = try usage(#"{"availableCount":2,"credits":[{"status":"consumed","expiresAt":1800000003000},{"status":"available","expiresAt":1800000002000},{"status":"available","expiresAt":1800000001000}]}"#)
        XCTAssertEqual(credits.lines, [CodexUsageMapper.resetCreditsLine(count: 2, expiries: [
            Date(timeIntervalSince1970: 1800000001), Date(timeIntervalSince1970: 1800000002)
        ])])
        let zero = try usage(#"{"availableCount":0}"#)
        XCTAssertEqual(zero.lines, [CodexUsageMapper.resetCreditsLine(count: 0, expiries: [])])
        let missing = try usage("null")
        XCTAssertTrue(missing.lines.isEmpty)
        let negative = try usage(#"{"availableCount":-1}"#)
        XCTAssertTrue(negative.lines.isEmpty)
    }

    func testExpiredLoginAndRelaunchKeepResetStateUntilSameAccountRecovers() async throws {
        let suite = "QuotaSnapshotPersistence.\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let provider = CodexProvider.makeProvider()
        let runtime = SavedQuotaRuntime(provider: provider)
        let identity = [provider.id: "codex:account-a"]
        func cache() -> ProviderSnapshotCache {
            ProviderSnapshotCache(userDefaults: defaults, storageKey: "quota")
        }
        func store(_ cache: ProviderSnapshotCache) -> WidgetDataStore {
            WidgetDataStore(registry: WidgetRegistry(providers: [provider], descriptors: []),
                            providers: [runtime], cache: cache, defaults: defaults,
                            providerIdentityKeys: identity)
        }
        let originalDate = Date(timeIntervalSince1970: 1800000000)
        let resetDate = originalDate.addingTimeInterval(300)
        let lines: [MetricLine] = [
            .progress(label: "Session", used: 99, limit: 100, format: .percent, resetsAt: resetDate),
            CodexUsageMapper.resetCreditsLine(count: 2, expiries: [resetDate])
        ]
        runtime.snapshot = ProviderSnapshot(providerID: provider.id, displayName: "Codex", lines: lines, refreshedAt: originalDate)
        let first = store(cache())
        await first.refreshAll(force: true)
        runtime.snapshot = .error(provider: provider, message: "Login expired")
        await first.refreshAll(force: true)
        XCTAssertEqual(first.localSnapshots[provider.id]?.lines, lines)
        XCTAssertEqual(first.localSnapshots[provider.id]?.refreshedAt, originalDate)
        XCTAssertEqual(first.errorMessage(for: provider.id), "Login expired")

        let disk = cache()
        let relaunched = store(disk)
        XCTAssertEqual(relaunched.localSnapshots[provider.id]?.lines, lines)
        XCTAssertNil(disk.snapshot(providerID: provider.id))
        XCTAssertTrue(disk.hasStaleAccountStamp(providerID: provider.id, currentIdentityKey: "codex:account-b"))
        await relaunched.refreshAll(force: true)
        XCTAssertEqual(relaunched.localSnapshots[provider.id]?.refreshedAt, originalDate)
        runtime.snapshot = ProviderSnapshot(providerID: provider.id, displayName: "Codex",
            lines: [CodexUsageMapper.resetCreditsLine(count: 0, expiries: [])], refreshedAt: resetDate)
        await relaunched.refreshAll(force: true)
        XCTAssertNil(relaunched.errorMessage(for: provider.id))
        XCTAssertEqual(relaunched.localSnapshots[provider.id]?.lines, runtime.snapshot.lines)
        XCTAssertEqual(cache().loadSnapshots(providerIDs: [provider.id])[provider.id]?.refreshedAt, resetDate)
    }
}

@MainActor
private final class SavedQuotaRuntime: ProviderRuntime {
    let provider: Provider
    let widgetDescriptors: [WidgetDescriptor] = []
    var snapshot: ProviderSnapshot
    init(provider: Provider) {
        self.provider = provider
        self.snapshot = .error(provider: provider, message: "Not loaded")
    }
    func refresh() async -> ProviderSnapshot { snapshot }
    func hasLocalCredentials() async -> Bool { true }
}
