import AppKit
import SwiftUI
@testable import OpenUsage

@MainActor
enum QuotaAuditRendering {
    static func render() throws {
        NSApplication.shared.setActivationPolicy(.prohibited)
        let now = Date(timeIntervalSince1970: 1_800_000_600)
        let reset = Date(timeIntervalSince1970: 1_800_018_000)
        let readings = [1.0, 11.0].enumerated().compactMap { index, percent -> QuotaAuditSample? in
            let usage = OrcaUsageReader.Usage(provider: "claude",
                session: .init(usedPercent: percent, windowMinutes: 300, resetsAt: reset.timeIntervalSince1970 * 1000),
                updatedAt: now.addingTimeInterval(Double(index - 1) * 300).timeIntervalSince1970 * 1000, status: "ok")
            return QuotaAuditSample(usage, observedAt: now)
        }
        var report = QuotaAuditReport.build(samples: readings, events: [], now: now)
        report.windows[0].windowUsage = QuotaAuditTotals(input: 12000, output: 3400, cacheRead: 800000,
            cacheWrite: 25000, totalTokens: 840400, pricedUSD: 0.84, events: 8,
            models: ["claude-sonnet-example": 840400])
        report.windows[0].matchedUsage = report.windows[0].windowUsage
        for (name, value) in [("window", report), ("empty", QuotaAuditReport.build(samples: [], events: nil, now: now))] {
            let view = QuotaAuditDetail(report: value).background(Color(nsColor: .windowBackgroundColor))
            let hosting = NSHostingView(rootView: view)
            let size = hosting.fittingSize
            let window = NSWindow(contentRect: NSRect(origin: .zero, size: size),
                styleMask: [.borderless], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.contentView = hosting
            hosting.frame = NSRect(origin: .zero, size: size)
            hosting.layoutSubtreeIfNeeded()
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
            hosting.layoutSubtreeIfNeeded()
            guard let bitmap = hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds) else {
                throw NSError(domain: "AuditRender", code: 1)
            }
            hosting.cacheDisplay(in: hosting.bounds, to: bitmap)
            guard let png = bitmap.representation(using: .png, properties: [:]) else {
                throw NSError(domain: "AuditRender", code: 2)
            }
            window.close()
            let url = URL(fileURLWithPath: "/tmp/openusage-quota-audit-\(name).png")
            try png.write(to: url)
            print("Rendered \(name): \(bitmap.pixelsWide) x \(bitmap.pixelsHigh), \(url.path)")
        }
    }
}
