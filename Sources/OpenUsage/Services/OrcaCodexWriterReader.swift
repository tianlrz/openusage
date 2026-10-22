import Foundation

struct OrcaCodexWriter: Equatable, Sendable {
    var sessionID: String
    var accountSlot: String
    var processKey: String
}

protocol OrcaCodexWriterReading: Sendable {
    func writers(homes: [String: String]) throws -> [OrcaCodexWriter]
}

/// Observes local writers, not the account selected for future launches. No credentials are retained.
struct OrcaCodexWriterReader: OrcaCodexWriterReading {
    var runner: ProcessRunning = SystemProcessRunner()

    func writers(homes: [String: String]) throws -> [OrcaCodexWriter] {
        let table = try run("/bin/ps", ["-axo", "pid=,comm="])
        var result: [OrcaCodexWriter] = []
        for line in table.split(separator: "\n") {
            let fields = line.split(maxSplits: 1, whereSeparator: \.isWhitespace)
            guard fields.count == 2, Int(fields[0]) != nil else { continue }
            let name = URL(fileURLWithPath: String(fields[1])).lastPathComponent
            guard name == "codex" || name == "codex-aarch64-apple-darwin"
                    || name == "codex-x86_64-apple-darwin" else { continue }
            let pid = String(fields[0])
            let environment = try run("/bin/ps", ["eww", "-p", pid, "-o", "command="])
            guard let home = Self.environmentHome(environment),
                  let slot = homes.first(where: {
                      URL(fileURLWithPath: $0.value).resolvingSymlinksInPath().path
                          == URL(fileURLWithPath: home).resolvingSymlinksInPath().path
                  })?.key else { continue }
            let start = try run("/bin/ps", ["-p", pid, "-o", "lstart="])
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !start.isEmpty else { continue }
            let opened = try runner.run(executable: "/usr/sbin/lsof",
                arguments: ["-a", "-p", pid, "-Ffan"], environment: [:], timeout: 5)
            // lsof exits 1 when the process disappeared; its absence is not a writer observation.
            guard opened.succeeded else { continue }
            result += Self.parseFiles(opened.stdout, account: slot, processKey: pid + "|" + start)
        }
        return result
    }

    static func environmentHome(_ text: String) -> String? {
        guard let expression = try? NSRegularExpression(
            pattern: #"(?:^|\s)CODEX_HOME=(.*?)(?=\s[A-Za-z_][A-Za-z0-9_]*=|$)"#,
            options: [.dotMatchesLineSeparators]),
              let match = expression.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              let range = Range(match.range(at: 1), in: text) else { return nil }
        return String(text[range]).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func parseFiles(_ text: String, account: String, processKey: String) -> [OrcaCodexWriter] {
        var access = ""
        var result: [OrcaCodexWriter] = []
        for line in text.split(separator: "\n") {
            if line.hasPrefix("f") { access = "" }
            else if line.hasPrefix("a") { access = String(line.dropFirst()) }
            else if line.hasPrefix("n"), access == "u" || access == "w" {
                let url = URL(fileURLWithPath: String(line.dropFirst()))
                guard url.pathExtension == "jsonl" else { continue }
                let id = String(url.deletingPathExtension().lastPathComponent.suffix(36)).lowercased()
                guard UUID(uuidString: id) != nil else { continue }
                result.append(OrcaCodexWriter(sessionID: id, accountSlot: account, processKey: processKey))
            }
        }
        return result
    }

    private func run(_ executable: String, _ arguments: [String]) throws -> String {
        let result = try runner.run(executable: executable, arguments: arguments, environment: [:], timeout: 5)
        guard result.succeeded else { throw OrcaUsageReader.ReadError("Local Codex writer observation failed.") }
        return result.stdout
    }
}
