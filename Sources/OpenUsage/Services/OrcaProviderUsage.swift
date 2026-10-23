import Foundation

extension ClaudeProvider {
    func refreshOrcaUsage(slot: String) async -> ProviderSnapshot {
        do {
            let usage = try await OrcaUsageReader.shared.usage(family: "claude", slot: slot)
            var snapshot = await snapshotWithLocalUsage(
                mapped: ClaudeMappedUsage(plan: nil, lines: usage.lines), warning: usage.warning)
            snapshot.refreshedAt = usage.fetchedAt
            let auditPricing = await pricing()
            let entries = await logUsageScanner.entries(now: now(), strictOwnership: true)
            snapshot.quotaAudit = await QuotaAuditStore.shared.recordClaude(slot: slot,
                usage: usage, entries: entries, pricing: auditPricing, now: now())
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
            if let context = orcaHistoryContext {
                let auditPricing = await pricing()
                let events = await OrcaCodexHistory.shared.events(accountSlot: slot, context: context, now: now())
                snapshot.quotaAudit = await QuotaAuditStore.shared.recordCodex(slot: slot,
                    usage: usage, events: events, pricing: auditPricing, now: now())
            }
            return snapshot
        } catch {
            return ProviderSnapshot.error(provider: provider, error: error)
        }
    }
}
