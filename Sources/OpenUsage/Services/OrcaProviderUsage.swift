import Foundation

extension ClaudeProvider {
    func refreshOrcaUsage(slot: String) async -> ProviderSnapshot {
        do {
            let usage = try await OrcaUsageReader.shared.usage(family: "claude", slot: slot)
            var snapshot = await snapshotWithLocalUsage(
                mapped: ClaudeMappedUsage(plan: nil, lines: usage.lines), warning: usage.warning)
            snapshot.refreshedAt = usage.fetchedAt
            return snapshot
        } catch {
            return ProviderSnapshot.error(provider: provider, error: error)
        }
    }
}

extension CodexProvider {
    func refreshOrcaUsage(slot: String) async -> ProviderSnapshot {
        do {
            let usage = try await OrcaUsageReader.shared.usage(family: "codex", slot: slot,
                workspace: authStore.expectedIdentity?.accountID)
            var snapshot = await snapshot(mapped: CodexMappedUsage(plan: nil, lines: usage.lines))
            snapshot.refreshedAt = usage.fetchedAt
            snapshot.warning = [usage.warning, snapshot.warning].compactMap { $0 }.joined(separator: " ").nilIfEmpty
            return snapshot
        } catch {
            return ProviderSnapshot.error(provider: provider, error: error)
        }
    }
}
