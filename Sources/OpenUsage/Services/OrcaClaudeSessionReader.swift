import Foundation

struct OrcaClaudeUsageContext: Sendable {
    var homes: [String: String]
    var identities: [String: String]
}

protocol OrcaClaudeSessionReading: Sendable {
    func sessions(context: OrcaClaudeUsageContext, now: Date) throws -> [OrcaSessionWriter]
}

/// A scoped Claude registry plus the live process proves the resumed session's current account.
struct OrcaClaudeSessionReader: OrcaClaudeSessionReading {
    var runner: ProcessRunning = SystemProcessRunner()
    static let maximumMetadataBytes = 16 * 1024
    static let maximumProcesses = 32

    struct Metadata: Decodable {
        var pid: Int
        var sessionId: String
        var startedAt: Double
        var procStart: String
        var pidDomain: String?
    }

    func sessions(context: OrcaClaudeUsageContext, now: Date) throws -> [OrcaSessionWriter] {
        var result: [OrcaSessionWriter] = []
        var checked = 0
        let deadline = Date().addingTimeInterval(10)
        for (slot, home) in context.homes.sorted(by: { $0.key < $1.key }) {
            let directory = URL(fileURLWithPath: home).appendingPathComponent("sessions")
            guard FileManager.default.fileExists(atPath: directory.path) else { continue }
            guard let files = FileManager.default.enumerator(at: directory,
                includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey], options: [.skipsSubdirectoryDescendants]) else {
                throw OrcaUsageReader.ReadError("Claude session metadata could not be read.")
            }
            for case let file as URL in files {
                guard file.pathExtension == "json", Int(file.deletingPathExtension().lastPathComponent) != nil else { continue }
                guard Date() < deadline else { throw OrcaUsageReader.ReadError("Claude process verification timed out.") }
                checked += 1
                guard checked <= Self.maximumProcesses else { throw OrcaUsageReader.ReadError("Too many Claude session records to verify safely.") }
                let values = try file.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
                guard values.isRegularFile == true, values.isSymbolicLink != true else { continue }
                let handle = try FileHandle(forReadingFrom: file)
                let data: Data
                do { data = try handle.read(upToCount: Self.maximumMetadataBytes + 1) ?? Data(); try handle.close() }
                catch { try? handle.close(); throw error }
                guard data.count <= Self.maximumMetadataBytes,
                      let metadata = try? JSONDecoder().decode(Metadata.self, from: data),
                      metadata.pid > 0, String(metadata.pid) == file.deletingPathExtension().lastPathComponent,
                      UUID(uuidString: metadata.sessionId) != nil,
                      metadata.pidDomain == nil || metadata.pidDomain == "darwin",
                      metadata.startedAt.isFinite,
                      metadata.startedAt > 0, metadata.startedAt / 1000 <= now.timeIntervalSince1970 else { continue }
                guard let born = Self.processDate(metadata.procStart),
                      metadata.startedAt / 1000 >= born.timeIntervalSince1970 - 1 else { continue }
                let pid = String(metadata.pid)
                let command = try run(["-p", pid, "-o", "comm="])
                guard command.status == 0, URL(fileURLWithPath: command.text.trimmingCharacters(in: .whitespacesAndNewlines)).lastPathComponent == "claude" else { continue }
                let before = try run(["-p", pid, "-o", "lstart="])
                guard before.status == 0, Self.normalized(before.text) == Self.normalized(metadata.procStart) else { continue }
                let environment = try run(["eww", "-p", pid, "-o", "command="])
                guard environment.status == 0,
                      let actualHome = OrcaCodexWriterReader.environmentHome(environment.text, key: "CLAUDE_CONFIG_DIR"),
                      Self.canonical(actualHome) == Self.canonical(home) else { continue }
                let after = try run(["-p", pid, "-o", "lstart="])
                guard after.status == 0, Self.normalized(before.text) == Self.normalized(after.text) else { continue }
                result.append(OrcaSessionWriter(sessionID: metadata.sessionId.lowercased(), accountSlot: slot,
                    processKey: pid + "|" + Self.normalized(before.text),
                    startedAt: Date(timeIntervalSince1970: metadata.startedAt / 1000)))
            }
        }
        return result
    }

    private func run(_ arguments: [String]) throws -> (status: Int32, text: String) {
        let reply = try runner.run(executable: "/bin/ps", arguments: arguments,
            environment: ["TZ": "UTC", "LC_ALL": "C"], timeout: 3)
        guard reply.stdout.utf8.count <= 256 * 1024 else {
            throw OrcaUsageReader.ReadError("Claude process metadata exceeded the read limit.")
        }
        return (reply.exitCode, reply.stdout)
    }

    private static func processDate(_ text: String) -> Date? {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "EEE MMM d HH:mm:ss yyyy"
        return formatter.date(from: normalized(text))
    }
    private static func canonical(_ path: String) -> String {
        URL(fileURLWithPath: path).resolvingSymlinksInPath().standardizedFileURL.path
    }
    private static func normalized(_ text: String) -> String { text.split(whereSeparator: \.isWhitespace).joined(separator: " ") }
}
