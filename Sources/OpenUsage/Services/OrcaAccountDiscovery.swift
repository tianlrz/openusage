import Foundation

/// Reads only account metadata; the owning tool remains responsible for refreshing logins.
enum OrcaAccountDiscovery {
    static func dataRoot(environment: EnvironmentReading, home: URL) -> URL {
        if let value = environment.value(for: "ORCA_USER_DATA_PATH")?.nilIfEmpty {
            return URL(fileURLWithPath: CodexHomeScanner.standardizedHome(value, homeDirectory: home))
        }
        return home.appendingPathComponent("Library/Application Support/orca")
    }

    static func homes(
        family: String, environment: EnvironmentReading, files: TextFileAccessing, home: URL,
        listDirectories: @Sendable (String) -> [String]
    ) -> [String: String] {
        let data = dataRoot(environment: environment, home: home)
        if let registered = registeredHomes(family: family, root: data, files: files) { return registered }
        let root = data.appendingPathComponent("\(family)-accounts")
        let leaf = family == "codex" ? "home" : "auth"
        let marker = family == "codex" ? ".orca-managed-home" : ".orca-managed-claude-auth"
        var result: [String: String] = [:]
        for slot in listDirectories(root.path).sorted() where UUID(uuidString: slot) != nil {
            let path = root.appendingPathComponent(slot).appendingPathComponent(leaf).path
            do {
                if try files.readTextIfPresent(path + "/" + marker)?
                    .trimmingCharacters(in: .whitespacesAndNewlines) == slot {
                    result[slot] = path
                }
            } catch {
                AppLog.warn(.config, "Orca account ownership marker could not be read")
            }
        }
        return result
    }

    /// SQLite is authoritative after Orca migrates; the old JSON and directories may be stale.
    static func registeredHomes(
        family: String, root: URL, files: TextFileAccessing, sqlite: SQLiteAccessing = SQLiteCLIAccessor()
    ) -> [String: String]? {
        let indexPath = root.appendingPathComponent("orca-profile-index.json").path
        guard files.exists(indexPath) else { return nil }
        do {
            let index = try JSONDecoder().decode(ProfileIndex.self, from: Data(files.readText(indexPath).utf8))
            guard index.activeProfileId == "local-default" || UUID(uuidString: index.activeProfileId) != nil else {
                return [:]
            }
            let profile = root.appendingPathComponent("profiles").appendingPathComponent(index.activeProfileId)
            let database = profile.appendingPathComponent("profile-state.db").path
            let text: String?
            if files.exists(database) {
                text = try sqlite.queryValue(path: database,
                    sql: "SELECT payload FROM profile_state_documents WHERE domain = 'settings' LIMIT 1;")
            } else if let legacy = try files.readTextIfPresent(profile.appendingPathComponent("orca-data.json").path) {
                let envelope = try JSONDecoder().decode(LegacySettings.self, from: Data(legacy.utf8))
                return validatedHomes(envelope.settings.accounts(family), family: family, root: root)
            } else {
                return [:]
            }
            guard let text else { return [:] }
            let settings = try JSONDecoder().decode(RegisteredSettings.self, from: Data(text.utf8))
            return validatedHomes(settings.accounts(family), family: family, root: root)
        } catch {
            AppLog.warn(.config, "Orca active account registry could not be read; stale directories were ignored")
            return [:]
        }
    }

    private struct ProfileIndex: Decodable { var activeProfileId: String }
    private struct LegacySettings: Decodable { var settings: RegisteredSettings }
    private struct RegisteredSettings: Decodable {
        var claudeManagedAccounts: [RegisteredAccount]?
        var codexManagedAccounts: [RegisteredAccount]?
        func accounts(_ family: String) -> [RegisteredAccount] {
            (family == "codex" ? codexManagedAccounts : claudeManagedAccounts) ?? []
        }
    }
    private struct RegisteredAccount: Decodable {
        var id: String
        var managedHomePath: String?
        var managedAuthPath: String?
    }

    private static func validatedHomes(
        _ accounts: [RegisteredAccount], family: String, root: URL
    ) -> [String: String] {
        var result: [String: String] = [:]
        for account in accounts where UUID(uuidString: account.id) != nil {
            guard let path = family == "codex" ? account.managedHomePath : account.managedAuthPath else { continue }
            let canonical = URL(fileURLWithPath: path).resolvingSymlinksInPath().standardizedFileURL.path
            let candidates = family == "codex"
                ? [("codex-accounts", "home")]
                : [("claude-accounts", "auth"), ("claude-profiles", "home")]
            if candidates.contains(where: { folder, leaf in
                canonical == root.appendingPathComponent(folder).appendingPathComponent(account.id)
                    .appendingPathComponent(leaf).resolvingSymlinksInPath().path
            }) { result[account.id] = canonical }
        }
        return result
    }

    static func ownsCodexHome(_ path: String, environment: EnvironmentReading, files: TextFileAccessing) -> Bool {
        let canonical = URL(fileURLWithPath: path).resolvingSymlinksInPath()
        let slot = canonical.deletingLastPathComponent().lastPathComponent
        guard canonical.lastPathComponent == "home", UUID(uuidString: slot) != nil else { return false }
        // The marker also protects configured/aliased managed homes outside the default data root.
        return (try? files.readTextIfPresent(canonical.appendingPathComponent(".orca-managed-home").path))?
            .trimmingCharacters(in: .whitespacesAndNewlines) == slot
    }
}

struct OrcaClaudeAccount: Equatable, Sendable {
    let slot: String
    let home: String
    let identityKey: String
    let organizationID: String
    let label: String
    var profileHome: Bool = false

    static func discover(
        environment: EnvironmentReading, files: TextFileAccessing, home: URL,
        listDirectories: @Sendable (String) -> [String]
    ) -> [Self] {
        OrcaAccountDiscovery.homes(family: "claude", environment: environment, files: files,
                                   home: home, listDirectories: listDirectories).sorted { $0.key < $1.key }.compactMap { slot, path in
            do {
                let profileHome = URL(fileURLWithPath: path).lastPathComponent == "home"
                let metadata = profileHome ? "/.claude.json" : "/oauth-account.json"
                guard let text = try files.readTextIfPresent(path + metadata) else { return nil }
                let account: DefaultAccountObserver.ClaudeStateFile.OAuthAccount
                if profileHome {
                    guard let oauth = try JSONDecoder().decode(DefaultAccountObserver.ClaudeStateFile.self,
                                                               from: Data(text.utf8)).oauthAccount else { return nil }
                    account = oauth
                } else {
                    account = try JSONDecoder().decode(DefaultAccountObserver.ClaudeStateFile.OAuthAccount.self,
                                                       from: Data(text.utf8))
                }
                guard let user = account.accountUuid.flatMap(UUID.init(uuidString:)),
                      let org = account.organizationUuid.flatMap(UUID.init(uuidString:)) else {
                    AppLog.warn(.config, "Orca Claude account has no valid user/workspace identity")
                    return nil
                }
                return Self(slot: slot, home: path,
                            identityKey: "\(user.uuidString.lowercased())|\(org.uuidString.lowercased())",
                            organizationID: org.uuidString.lowercased(),
                            label: DefaultAccountObserver.claudeIdentityLabel(account) ?? "Saved Account",
                            profileHome: profileHome)
            } catch {
                AppLog.warn(.config, "Orca Claude account metadata could not be read")
                return nil
            }
        }
    }
}

extension ClaudeAuthStore {
    func loadOrcaCredential(_ account: OrcaClaudeAccount) -> ClaudeCredentialState? {
        do {
            let text: String?
            if account.profileHome {
                guard let service = keychainServiceCandidates(scopedConfigDirectory: account.home).first else { return nil }
                text = try keychain.readGenericPasswordForCurrentUser(service: service)
                    ?? keychain.readGenericPassword(service: service)
                    ?? files.readTextIfPresent(account.home + "/.credentials.json")
            } else {
                text = try keychain.readGenericPassword(service: "Orca Claude Code Managed Credentials", account: account.slot)
            }
            guard let text, let parsed = Self.parseCredentials(text), var oauth = parsed.claudeAiOauth,
                  oauth.accessToken?.nilIfEmpty != nil else { return nil }
            oauth.refreshToken = nil
            return ClaudeCredentialState(oauth: oauth, source: .orcaManaged, fullData: nil, inferenceOnly: false)
        } catch {
            AppLog.warn(LogTag.auth("claude"), "Orca Claude login could not be read; allow Keychain access and refresh")
            return nil
        }
    }
}
