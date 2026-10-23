import Foundation

/// Coalesces all cards into one owner-managed refresh every five minutes; no provider login is copied.
actor OrcaUsageReader {
    static let shared = OrcaUsageReader(refresh: {
        try await Task.detached(priority: .utility) { try OrcaQuotaSocket().refresh() }.value
    })
    private let runner: ProcessRunning
    private let executable: String
    private let refresh: (@Sendable () async throws -> Payload)?
    private let now: @Sendable () -> Date
    private var lastRefreshError: ReadError?
    private var inFlight: Task<Payload, Error>?
    private var refreshWarning: String?
    private var cached: Payload?
    private var checkedAt = Date.distantPast

    init(runner: ProcessRunning = SystemProcessRunner(), executable: String? = nil,
         refresh: (@Sendable () async throws -> Payload)? = nil,
         now: @escaping @Sendable () -> Date = Date.init) {
        self.refresh = refresh
        self.now = now
        self.runner = runner
        self.executable = executable ?? ProcessInfo.processInfo.environment["ORCA_CLI_COMMAND"] ?? "/usr/local/bin/orca"
    }

    func usage(family: String, slot: String, workspace: String? = nil) async throws -> Usage {
        let payload = try await snapshot()
        var result = try payload.usage(family: family, slot: slot, workspace: workspace)
        result.refreshWarning = refreshWarning
        return result
    }

    func snapshot() async throws -> Payload {
        let interval: TimeInterval = refresh == nil ? 60 : 300
        if cached == nil, let lastRefreshError, now().timeIntervalSince(checkedAt) < interval {
            throw lastRefreshError
        }
        if cached == nil || now().timeIntervalSince(checkedAt) >= interval {
            if inFlight == nil {
                let runner = self.runner, executable = self.executable, refresh = self.refresh
                inFlight = Task {
                    if let refresh { return try await refresh() }
                    let reply = try runner.run(executable: executable, arguments: ["account", "list", "--json"],
                                               environment: [:], timeout: 15)
                    guard reply.succeeded, reply.stdout.utf8.count <= OrcaQuotaSocket.maximumFrameBytes else {
                        throw ReadError("Orca CLI could not read usage. Keep Orca running and retry.")
                    }
                    let envelope = try JSONDecoder().decode(Envelope.self, from: Data(reply.stdout.utf8))
                    guard envelope.ok else { throw ReadError("Orca CLI could not read the current accounts.") }
                    return envelope.result
                }
            }
            do {
                guard let task = inFlight else { throw ReadError("Orca usage is unavailable.") }
                let result = try await task.value
                cached = result
                checkedAt = now()
                refreshWarning = nil
                lastRefreshError = nil
                inFlight = nil
            } catch {
                inFlight = nil
                checkedAt = now()
                lastRefreshError = ReadError("Orca's live quota refresh failed. Keep Orca running; automatic retry follows the five-minute interval.")
                refreshWarning = "Live quota refresh failed; these are saved readings with their original timestamps."
                guard cached != nil else { throw lastRefreshError ?? ReadError("Orca usage is unavailable.") }
            }
        }
        guard let payload = cached else { throw ReadError("Orca usage is unavailable.") }
        return payload
    }

    struct ReadError: LocalizedError {
        let message: String
        init(_ message: String) { self.message = message }
        var errorDescription: String? { message }
    }
    struct Envelope: Decodable { var ok: Bool; var result: Payload }
    struct Payload: Decodable {
        var claude: Accounts
        var codex: Accounts
        var rateLimits: Limits

        func usage(family: String, slot: String, workspace: String?) throws -> Usage {
            let accounts = family == "claude" ? claude : codex
            guard let account = accounts.accounts.first(where: { $0.id == slot }),
                  workspace == nil || workspace == account.workspaceAccountId || workspace == account.providerAccountId
            else { throw ReadError("This account is no longer registered in Orca. Restart OpenUsage to update its cards.") }
            let target = family == "claude" ? rateLimits.claudeTarget : rateLimits.codexTarget
            let active = accounts.activeAccountIdsByRuntime?.host ?? accounts.activeAccountId
            let limits: Usage?
            if active == slot && target?.runtime == "host" {
                limits = family == "claude" ? rateLimits.claude : rateLimits.codex
            } else {
                let inactive = family == "claude" ? rateLimits.inactiveClaudeAccounts : rateLimits.inactiveCodexAccounts
                limits = inactive?.first(where: { $0.accountId == slot })?.rateLimits
            }
            guard let limits, limits.provider == family else {
                throw ReadError("Orca has no current quota reading for this saved account. Check its login in Orca.")
            }
            guard limits.status == "ok", limits.error == nil else {
                throw ReadError("Orca could not load this account's usage: " + (limits.error ?? limits.status ?? "unavailable"))
            }
            return limits
        }
    }
    struct Accounts: Decodable {
        var accounts: [Account]
        var activeAccountId: String?
        var activeAccountIdsByRuntime: RuntimeSelection?
    }
    struct RuntimeSelection: Decodable { var host: String? }
    struct Account: Decodable {
        var id: String
        var workspaceAccountId: String?
        var providerAccountId: String?
    }
    struct Target: Decodable { var runtime: String }
    struct Inactive: Decodable { var accountId: String; var rateLimits: Usage? }
    struct Limits: Decodable {
        var claude: Usage?
        var codex: Usage?
        var claudeTarget: Target?
        var codexTarget: Target?
        var inactiveClaudeAccounts: [Inactive]?
        var inactiveCodexAccounts: [Inactive]?
    }
    struct Window: Decodable {
        var usedPercent: Double
        var windowMinutes: Int?
        var resetsAt: Double?
        func line(_ label: String) -> MetricLine? {
            guard usedPercent.isFinite, (0...100).contains(usedPercent) else { return nil }
            return .progress(label: label, used: usedPercent, limit: 100, format: .percent,
                resetsAt: resetsAt.map { Date(timeIntervalSince1970: $0 / 1000) },
                periodDurationMs: windowMinutes.map { $0 * 60_000 })
        }
    }
    struct Usage: Decodable {
        var provider: String
        var session: Window?
        var weekly: Window?
        var fableWeekly: Window?
        var updatedAt: Double
        var status: String?
        var error: String?
        var refreshWarning: String? = nil
        var fetchedAt: Date { Date(timeIntervalSince1970: updatedAt / 1000) }
        var lines: [MetricLine] {
            [session?.line("Session"), weekly?.line("Weekly"), fableWeekly?.line("Fable")].compactMap { $0 }
        }
        var warning: String? {
            if let refreshWarning { return refreshWarning }
            return Date().timeIntervalSince(fetchedAt) > 15 * 60
                ? "Orca has not supplied a newer reading for this account. Its saved usage is over 15 minutes old." : nil
        }
    }
}
