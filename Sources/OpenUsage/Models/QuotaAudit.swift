import Foundation

/// Local evidence aligned to provider sample times; API dollar estimates are not subscription allowances.
struct QuotaAuditEvent: Sendable {
    var timestamp: Date
    var model: String
    var tokens: TokenBreakdown
    var totalTokens: Int
    var costUSD: Double?

    init(_ entry: ClaudeLogUsageScanner.Entry, pricing: ModelPricing) {
        timestamp = entry.timestamp
        model = (entry.model ?? ModelUsageEntry.unattributedModelName) + (entry.tokens.isFast ? " (Fast)" : "")
        tokens = entry.tokens
        totalTokens = entry.tokens.totalTokens
        costUSD = entry.costUSD ?? entry.model.flatMap { pricing.estimatedCostDollars(model: $0, tokens: entry.tokens) }
    }

    init(_ event: CodexLogUsageScanner.Event, pricing: ModelPricing) {
        timestamp = event.timestamp
        model = event.model + (event.isUltrafast ? " (Ultrafast)" : event.isFast ? " (Fast)" : "")
        tokens = TokenBreakdown(input: max(0, event.input - event.cached), cacheRead: event.cached, output: event.output)
        totalTokens = event.total
        let key = event.model == CodexUsagePricing.autoReviewModel ? event.model : event.pricingModel ?? event.model
        let resolution = CodexUsagePricing.resolveRates(pricing: pricing, model: key, at: event.timestamp)
        costUSD = resolution.rates.map {
            CodexLogUsageScanner.cost(rates: $0, event: event, model: resolution.rateModel,
                fastTier: resolution.isFastAlias ? resolution.hasBaseRates : event.isFast,
                ultrafastTier: event.isUltrafast && (!resolution.isFastAlias || resolution.hasBaseRates))
        }
    }
}

struct QuotaAuditTotals: Codable, Hashable, Sendable {
    var input = 0
    var output = 0
    var cacheRead = 0
    var cacheWrite = 0
    var totalTokens = 0
    var pricedUSD = 0.0
    var unpricedEvents = 0
    var events = 0
    var models: [String: Int] = [:]

    mutating func add(_ event: QuotaAuditEvent) {
        input += event.tokens.input
        output += event.tokens.output
        cacheRead += event.tokens.cacheRead
        cacheWrite += event.tokens.cacheWrite5m + event.tokens.cacheWrite1h
        totalTokens += event.totalTokens
        events += 1
        models[event.model, default: 0] += event.totalTokens
        if let cost = event.costUSD, cost.isFinite, cost >= 0 { pricedUSD += cost }
        else { unpricedEvents += 1 }
    }
}

struct QuotaAuditSample: Codable, Hashable, Sendable {
    var sourceAt: Date
    var observedAt: Date
    var session: Reading
    var weekly: Reading?
    var localUsage: QuotaAuditTotals? = nil

    struct Reading: Codable, Hashable, Sendable {
        var usedPercent: Double
        var resetAt: Date
        var duration: TimeInterval

        init?(_ window: OrcaUsageReader.Window?, defaultMinutes: Int) {
            guard let window, window.usedPercent.isFinite, (0...100).contains(window.usedPercent),
                  let reset = window.resetsAt, reset.isFinite, reset > 0 else { return nil }
            let minutes = window.windowMinutes ?? defaultMinutes
            guard minutes > 0, minutes <= 31 * 24 * 60 else { return nil }
            usedPercent = window.usedPercent
            resetAt = Date(timeIntervalSince1970: reset / 1000)
            duration = Double(minutes) * 60
        }
    }

    init?(_ usage: OrcaUsageReader.Usage, observedAt: Date) {
        guard usage.status == "ok", usage.error == nil, usage.updatedAt.isFinite,
              let session = Reading(usage.session, defaultMinutes: 300), session.duration == 5 * 3600,
              usage.fetchedAt <= observedAt.addingTimeInterval(60),
              usage.fetchedAt >= session.resetAt.addingTimeInterval(-session.duration - 60),
              usage.fetchedAt < session.resetAt else { return nil }
        sourceAt = usage.fetchedAt
        self.observedAt = observedAt
        self.session = session
        weekly = Reading(usage.weekly, defaultMinutes: 10080)
    }
}

struct QuotaAuditReport: Codable, Hashable, Sendable {
    var generatedAt: Date
    var latestSourceAt: Date?
    var windows: [Window]
    var notes: [String] = []

    struct Window: Codable, Hashable, Sendable, Identifiable {
        var id: Date { resetAt }
        var resetAt: Date
        var windowStart: Date
        var windowEnd: Date
        var observedFrom: Date
        var observedThrough: Date
        var firstPercent: Double
        var lastPercent: Double
        var samples: Int
        var readings: [QuotaAuditSample]
        var windowUsage: QuotaAuditTotals
        var matchedUsage: QuotaAuditTotals
        var notes: [String]
        var percentChange: Double { lastPercent - firstPercent }
        var estimatedUSDPer10Percent: Double? {
            guard samples >= 2, percentChange >= 10, notes.isEmpty,
                  matchedUsage.events > 0, matchedUsage.unpricedEvents == 0 else { return nil }
            return matchedUsage.pricedUSD / percentChange * 10
        }
    }

    static func build(samples: [QuotaAuditSample], events: [QuotaAuditEvent]?, now: Date) -> Self {
        // Orca's relative-date parser can add millisecond noise to an otherwise unchanged reset.
        let grouped = Dictionary(grouping: samples, by: {
            Date(timeIntervalSince1970: $0.session.resetAt.timeIntervalSince1970.rounded(.down))
        })
        let orderedEvents = (events ?? []).sorted { $0.timestamp < $1.timestamp }
        func lowerBound(_ date: Date) -> Int {
            var low = 0, high = orderedEvents.count
            while low < high {
                let mid = (low + high) / 2
                if orderedEvents[mid].timestamp < date { low = mid + 1 } else { high = mid }
            }
            return low
        }
        let resets = grouped.keys.sorted(by: >)
        let windows = resets.enumerated().map { index, reset -> Window in
            let readings = (grouped[reset] ?? []).sorted { $0.sourceAt < $1.sourceAt }
            let first = readings[0], last = readings[readings.count - 1]
            var whole = QuotaAuditTotals(), matched = QuotaAuditTotals()
            let start = reset.addingTimeInterval(-first.session.duration)
            let nextStart = index > 0 ? resets[index - 1].addingTimeInterval(-5 * 3600) : reset
            let end = min(reset, nextStart)
            let firstIndex = lowerBound(start), endIndex = lowerBound(end)
            for event in orderedEvents[firstIndex..<endIndex] where event.timestamp <= now {
                whole.add(event)
                if event.timestamp > first.sourceAt && event.timestamp <= last.sourceAt { matched.add(event) }
            }
            var notes: [String] = []
            if end < reset { notes.append("A newer reset shortened this window; its original reset time is retained.") }
            if start < now.addingTimeInterval(-30 * 86400) { notes.append("This window starts before local log retention.") }
            if first.sourceAt.timeIntervalSince(start) > 5 * 60 { notes.append("Observation started partway through this window.") }
            if readings.count < 2 { notes.append("Waiting for another distinct provider reading.") }
            for (previous, next) in zip(readings, readings.dropFirst()) {
                if next.sourceAt.timeIntervalSince(previous.sourceAt) > 10 * 60 {
                    notes.append("Provider readings have a gap over 10 minutes.")
                }
                if next.session.usedPercent < previous.session.usedPercent {
                    notes.append("Usage decreased within this reset window; it may have been corrected or reset.")
                }
            }
            if events == nil { notes.append("Account-owned local logs are unavailable.") }
            if last.observedAt.timeIntervalSince(last.sourceAt) > 15 * 60
                || (reset > now && now.timeIntervalSince(last.sourceAt) > 15 * 60) {
                notes.append("The latest provider reading is over 15 minutes old.")
            }
            if last.session.usedPercent < 100 && reset <= now { notes.append("No limit-reaching reading was observed before reset.") }
            if whole.unpricedEvents > 0 { notes.append("Some tokens have no known price; the dollar subtotal is partial.") }
            return Window(resetAt: reset, windowStart: start, windowEnd: end, observedFrom: first.sourceAt, observedThrough: last.sourceAt,
                firstPercent: first.session.usedPercent, lastPercent: last.session.usedPercent, samples: readings.count, readings: readings,
                windowUsage: whole, matchedUsage: matched, notes: Array(Set(notes)).sorted())
        }
        return Self(generatedAt: now, latestSourceAt: samples.map(\.sourceAt).max(), windows: windows,
            notes: ["Local account-owned logs only; web, other devices and unassigned sessions may be missing. Costs use API price estimates, not subscription billing. Model and cache mix can change the comparison."])
    }
}
