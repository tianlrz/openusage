import Foundation

/// Reuses the existing Codex spend tiles for events whose paying account is still unknown.
@MainActor
final class CodexUnassignedUsageProvider: ProviderRuntime {
    let provider = Provider(id: ProviderAccountID.make(family: "codex", identityKey: "orca:unassigned-local-history"),
                            displayName: "Codex — Unassigned Usage", icon: .providerMark("codex"))
    let context: OrcaCodexHistoryContext
    init(context: OrcaCodexHistoryContext) { self.context = context }
    var widgetDescriptors: [WidgetDescriptor] {
        // Unassigned consumption is local evidence, never an account-owned iCloud document.
        [.usageTrend(provider: provider)]
            + WidgetDescriptor.spendTiles(provider: provider)
    }
    func hasLocalCredentials() async -> Bool { !context.homes.isEmpty }
    func refresh() async -> ProviderSnapshot {
        let now = Date()
        let pricing = await ModelPricingStore.shared.current()
        let scan = await OrcaCodexHistory.shared.scan(accountSlot: nil, context: context, now: now,
            pricing: pricing, fallbackModel: CodexFallbackModelSetting.current())
        var lines: [MetricLine] = []
        let warning = await OrcaCodexHistory.shared.warning(accountSlot: nil)
        if let scan {
            SpendTileMapper.appendTokenUsage(scan.series, to: &lines, now: now,
                unknownModelsByDay: scan.unknownModelsByDay, modelUsage: scan.modelUsage,
                modelSourceNote: "Local Codex consumption awaiting account attribution",
                fallbackPricingModelsByDay: scan.fallbackPricingModelsByDay)
            SpendTileMapper.appendUsageTrend(scan.series, to: &lines, now: now,
                note: "Unverified ownership; events remain outside both account totals.")
        }
        MetricLine.appendNoDataIfNeeded(&lines)
        return ProviderSnapshot.make(provider: provider, plan: nil, lines: lines, refreshedAt: now,
            usageHistory: scan.map { ProviderUsageHistory(series: $0.series, modelUsage: $0.modelUsage,
                unknownModelsByDay: $0.unknownModelsByDay, fallbackPricingModelsByDay: $0.fallbackPricingModelsByDay) },
            warning: warning)
    }
}
