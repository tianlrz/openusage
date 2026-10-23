import SwiftUI

/// The existing Session row owns the audit entry point; no new metric placement is introduced.
struct QuotaAuditControl: View {
    let report: QuotaAuditReport
    @Environment(\.reduceAnimations) private var reduceAnimations
    @State private var hover = HoverPopoverState()

    var body: some View {
        Button("5h History") {
            hover.setPinned(true)
            hover.isPresented = true
        }
        .buttonStyle(.plain)
        .font(.system(size: 11))
        .foregroundStyle(.secondary)
        .onContinuousHover { phase in
            if case .active = phase { hover.inlineHover(true) }
            else { hover.inlineHover(false) }
        }
        .motionAwareHoverPopover(
            isPresented: Binding(get: { hover.isPresented }, set: { if !$0 { hover.dismiss() } }),
            reduceAnimations: reduceAnimations
        ) {
            QuotaAuditDetail(report: report) { hover.detailHover($0) }
        }
    }
}

struct QuotaAuditDetail: View {
    let report: QuotaAuditReport
    var onHoverChange: (Bool) -> Void = { _ in }
    @State private var selectedReset: Date?

    private var windows: [QuotaAuditReport.Window] { Array(report.windows.prefix(24)) }
    private var selected: QuotaAuditReport.Window? {
        windows.first { $0.resetAt == selectedReset } ?? windows.first
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Five-Hour Audit").font(.system(size: 13, weight: .semibold))
            if let selected {
                Picker("Reset", selection: Binding(
                    get: { selectedReset ?? selected.resetAt }, set: { selectedReset = $0 }
                )) {
                    ForEach(windows) { window in
                        Text(window.resetAt.formatted(date: .abbreviated, time: .shortened)).tag(window.resetAt)
                    }
                }
                .pickerStyle(.menu)
                ScrollView {
                    VStack(alignment: .leading, spacing: 10) {
                        reading(selected)
                        Divider()
                        totals("Local Usage in Window", selected.windowUsage)
                        Divider()
                        totals("Between Provider Readings", selected.matchedUsage)
                        if let value = selected.estimatedUSDPer10Percent {
                            row("API Estimate / 10% Used", dollars(value))
                        }
                        if !selected.windowUsage.models.isEmpty {
                            Divider()
                            Text("Models").fontWeight(.medium)
                            ForEach(selected.windowUsage.models.keys.sorted(), id: \.self) { model in
                                row(model, tokens(selected.windowUsage.models[model] ?? 0))
                            }
                        }
                        ForEach(selected.notes, id: \.self) { note in PopoverSourceNote(text: note) }
                        ForEach(report.notes, id: \.self) { note in PopoverSourceNote(text: note) }
                    }
                }
                .frame(maxHeight: 360)
            } else {
                Text("Collecting Account Readings")
                Text("History starts when Orca supplies a five-hour reset time. Earlier windows cannot be reconstructed from today's percentage.")
                    .foregroundStyle(.secondary)
                ForEach(report.notes, id: \.self) { note in PopoverSourceNote(text: note) }
            }
        }
        .font(.system(size: 11))
        .padding(12)
        .frame(width: 330)
        .fixedSize(horizontal: false, vertical: true)
        .onContinuousHover { phase in
            if case .active = phase { onHoverChange(true) }
            else { onHoverChange(false) }
        }
    }

    private func reading(_ window: QuotaAuditReport.Window) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            row("Observed Usage", "\(percent(window.firstPercent)) → \(percent(window.lastPercent))")
            row("Distinct Readings", String(window.samples))
            row("First Reading", window.observedFrom.formatted(date: .abbreviated, time: .shortened))
            row("Last Reading", window.observedThrough.formatted(date: .abbreviated, time: .shortened))
            if let captured = window.readings.last?.localUsage {
                row("Local Tokens at Reading", tokens(captured.totalTokens))
                row(captured.unpricedEvents == 0 ? "API Estimate at Reading" : "Priced Subtotal at Reading", dollars(captured.pricedUSD))
            }
        }
    }

    private func totals(_ title: String, _ value: QuotaAuditTotals) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).fontWeight(.medium)
            if value.events == 0 {
                Text("No account-owned local events in this interval.").foregroundStyle(.secondary)
            } else {
                row("Total Tokens", tokens(value.totalTokens))
                row("Input / Output", "\(tokens(value.input)) / \(tokens(value.output))")
                row("Cache Read / Write", "\(tokens(value.cacheRead)) / \(tokens(value.cacheWrite))")
                row(value.unpricedEvents == 0 ? "API Cost Estimate" : "Priced Subtotal", dollars(value.pricedUSD))
            }
        }
    }

    private func row(_ label: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text(label).foregroundStyle(.secondary)
            Spacer(minLength: 6)
            Text(value).monospacedDigit().multilineTextAlignment(.trailing)
        }
    }

    private func tokens(_ value: Int) -> String { value.formatted() }
    private func percent(_ value: Double) -> String { value.formatted(.number.precision(.fractionLength(0...1))) + "%" }
    private func dollars(_ value: Double) -> String { value.formatted(.currency(code: "USD")) }
}
