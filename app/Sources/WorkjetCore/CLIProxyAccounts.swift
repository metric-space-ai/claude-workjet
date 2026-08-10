import Darwin
import CryptoKit
import Foundation

public enum CLIProxyAccountError: LocalizedError, Equatable {
    case unsupportedProvider
    case executableUnavailable
    case loginFailed
    case gatewayCredentialUnavailable
    case apiKeyRequired

    public var errorDescription: String? {
        switch self {
        case .unsupportedProvider: return "Dieser Anbieter verwendet einen API-Key statt Web-Login."
        case .executableUnavailable: return "Die Web-Anmeldung ist auf diesem Mac nicht eingerichtet."
        case .loginFailed: return "Die Web-Anmeldung wurde nicht abgeschlossen."
        case .gatewayCredentialUnavailable: return "Die Anmeldung wurde abgeschlossen, aber Workjet konnte den Zugang nicht übernehmen. Verbinde den Anbieter erneut."
        case .apiKeyRequired: return "Bitte einen API-Key eingeben."
        }
    }
}

public struct CLIProxyAuthenticatedAccount: Equatable, Sendable {
    public var label: String
    public var externalID: String
    public var sourceRecordIDs: [String]
    /// Previous non-secret identity derivations accepted only for migrating
    /// stored provider rows. They are never used as credentials or displayed.
    public var migrationAliases: [String]
    public init(label: String, externalID: String, sourceRecordID: String? = nil) {
        self.label = label
        self.externalID = externalID
        sourceRecordIDs = sourceRecordID.map { [$0] } ?? []
        migrationAliases = []
    }
}

private struct CLIProxyAuthRecord: Equatable, Sendable {
    var url: URL
    var contentDigest: String
}

/// Read-only access to CLIProxy's existing local gateway key. OAuth tokens stay
/// owned by CLIProxy in ~/.cli-proxy-api and are never copied into Workjet's
/// keychain or configuration.
public struct CLIProxyGatewayCredentialStore: CredentialStoring, Sendable {
    public static let reference = "cliproxy-local-gateway"
    public let homeDirectory: URL
    public init(homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser) {
        self.homeDirectory = homeDirectory
    }
    public func read(reference: String) throws -> Data? {
        guard reference == Self.reference else { return nil }
        return try CLIProxyAccountAuthenticator.loadGatewayKey(homeDirectory: homeDirectory)
    }
    public func write(_ secret: Data, reference: String) throws {
        throw CLIProxyAccountError.gatewayCredentialUnavailable
    }
    public func delete(reference: String) throws {}
}

public struct CLIProxyAccountAuthenticator: Sendable {
    public let runner: any CommandRunning
    public let credentials: any CredentialStoring
    public let homeDirectory: URL
    public let executableCandidates: [String]

    public init(
        runner: any CommandRunning = ProcessCommandRunner(),
        credentials: any CredentialStoring = PrivateFileCredentialStore(),
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser,
        executableCandidates: [String] = ["/opt/homebrew/bin/cliproxyapi", "/usr/local/bin/cliproxyapi"]
    ) {
        self.runner = runner
        self.credentials = credentials
        self.homeDirectory = homeDirectory
        self.executableCandidates = executableCandidates
    }

    public func authenticate(_ provider: ModelProvider, credentialReference: String) async throws -> CLIProxyAuthenticatedAccount {
        guard let flag = provider.cliProxyLoginFlag else { throw CLIProxyAccountError.unsupportedProvider }
        guard let executable = executableCandidates.first(where: { FileManager.default.isExecutableFile(atPath: $0) }) else {
            throw CLIProxyAccountError.executableUnavailable
        }
        let recordsBeforeLogin = try Self.authRecords(for: provider, homeDirectory: homeDirectory)
        let result = try await runner.run(CommandSpec(
            executable: executable,
            arguments: [flag],
            timeout: 600,
            stdoutLimit: 65_536,
            stderrLimit: 65_536
        ))
        guard result.exitCode == 0 else { throw CLIProxyAccountError.loginFailed }
        guard try Self.loadGatewayKey(homeDirectory: homeDirectory) != nil else { throw CLIProxyAccountError.gatewayCredentialUnavailable }
        guard let identity = try discoverIdentity(for: provider, recordsBeforeLogin: recordsBeforeLogin) else {
            throw CLIProxyAccountError.loginFailed
        }
        return identity
    }

    static func loadGatewayKey(homeDirectory: URL) throws -> Data? {
        let url = homeDirectory.appendingPathComponent(".config/secrets/sol-key")
        var info = stat()
        guard lstat(url.path, &info) == 0,
              info.st_uid == getuid(),
              info.st_mode & S_IFMT == S_IFREG,
              info.st_mode & 0o077 == 0,
              info.st_size > 0,
              info.st_size <= 4_096 else { return nil }
        let value = try Data(contentsOf: url, options: [.mappedIfSafe])
        let trimmed = String(decoding: value, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed != "CHANGE-ME" else { return nil }
        return Data(trimmed.utf8)
    }

    private func discoverIdentity(
        for provider: ModelProvider,
        recordsBeforeLogin: [String: CLIProxyAuthRecord]
    ) throws -> CLIProxyAuthenticatedAccount? {
        let recordsAfterLogin = try Self.authRecords(for: provider, homeDirectory: homeDirectory)
        let changedRecords = recordsAfterLogin.values.filter { record in
            recordsBeforeLogin[record.url.lastPathComponent]?.contentDigest != record.contentDigest
        }
        let changedAccounts = changedRecords
            .compactMap { Self.identity(from: $0.url, provider: provider) }
        if provider == .kimi, changedAccounts.contains(where: Self.isOpaqueKimiIdentity) {
            let allKimiAccounts = recordsAfterLogin.values
                .compactMap { Self.identity(from: $0.url, provider: provider) }
            return Self.mergedOpaqueKimiIdentity(allKimiAccounts.filter(Self.isOpaqueKimiIdentity))
        }
        let merged = Self.mergingSameIdentities(changedAccounts, provider: provider)
        guard merged.count == 1 else { return nil }
        return merged[0]
    }

    private static func authRecords(
        for provider: ModelProvider,
        homeDirectory: URL
    ) throws -> [String: CLIProxyAuthRecord] {
        guard let prefix = authRecordPrefix(for: provider) else { return [:] }
        let directory = homeDirectory.appendingPathComponent(".cli-proxy-api", isDirectory: true)
        guard FileManager.default.fileExists(atPath: directory.path) else { return [:] }
        let files = try FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        )
        return Dictionary(uniqueKeysWithValues: files.sorted { $0.lastPathComponent < $1.lastPathComponent }.compactMap { url in
            guard url.lastPathComponent.hasPrefix(prefix), url.pathExtension == "json" else { return nil }
            guard let values = try? url.resourceValues(forKeys: [.isRegularFileKey]),
                  values.isRegularFile == true,
                  (try? SecureFile.checkRegularOwnedFile(at: url)) != nil,
                  let data = try? SecureFile.readRegularOwnedFile(at: url, maximumBytes: 65_536) else { return nil }
            let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
            return (url.lastPathComponent, CLIProxyAuthRecord(url: url, contentDigest: digest))
        })
    }

    public static func availableAccounts(
        for provider: ModelProvider,
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> [CLIProxyAuthenticatedAccount] {
        guard let prefix = authRecordPrefix(for: provider) else { return [] }
        let directory = homeDirectory.appendingPathComponent(".cli-proxy-api", isDirectory: true)
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }
        let accounts: [CLIProxyAuthenticatedAccount] = files
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
            .compactMap { url in
            guard url.lastPathComponent.hasPrefix(prefix), url.pathExtension == "json",
                  let values = try? url.resourceValues(forKeys: [.isRegularFileKey]),
                  values.isRegularFile == true else { return nil }
            return identity(from: url, provider: provider)
        }
        return mergingSameIdentities(accounts, provider: provider)
    }

    private static func mergingSameIdentities(
        _ accounts: [CLIProxyAuthenticatedAccount],
        provider: ModelProvider
    ) -> [CLIProxyAuthenticatedAccount] {
        var accounts = accounts
        if provider == .kimi {
            let opaque = accounts.filter(isOpaqueKimiIdentity)
            accounts.removeAll(where: isOpaqueKimiIdentity)
            if let mergedOpaque = mergedOpaqueKimiIdentity(opaque) {
                accounts.append(mergedOpaque)
            }
        }
        var merged: [String: CLIProxyAuthenticatedAccount] = [:]
        for account in accounts {
            if var existing = merged[account.externalID] {
                existing.sourceRecordIDs = Array(Set(existing.sourceRecordIDs + account.sourceRecordIDs)).sorted()
                existing.migrationAliases = Array(Set(existing.migrationAliases + account.migrationAliases)).sorted()
                if preferredLabel(account.label, over: existing.label) {
                    existing.label = account.label
                }
                merged[account.externalID] = existing
            } else {
                merged[account.externalID] = account
            }
        }
        return Array(merged.values)
            .sorted {
                let labels = $0.label.localizedCaseInsensitiveCompare($1.label)
                if labels != .orderedSame { return labels == .orderedAscending }
                return $0.externalID < $1.externalID
            }
    }

    private static func isOpaqueKimiIdentity(_ account: CLIProxyAuthenticatedAccount) -> Bool {
        account.label == "Kimi Code" && account.sourceRecordIDs.contains(account.externalID)
    }

    /// Current CLIProxy Kimi records may contain only rotating tokens and a
    /// time-based filename. Those files do not prove distinct subscriptions.
    /// Treat all such records as one gateway identity, retaining every source
    /// filename as a migration alias. Stable metadata identities remain distinct.
    private static func mergedOpaqueKimiIdentity(
        _ accounts: [CLIProxyAuthenticatedAccount]
    ) -> CLIProxyAuthenticatedAccount? {
        let sourceRecordIDs = Array(Set(accounts.flatMap(\.sourceRecordIDs))).sorted()
        guard let canonicalRecordID = sourceRecordIDs.first else { return nil }
        var identity = CLIProxyAuthenticatedAccount(
            label: "Kimi Code",
            externalID: canonicalRecordID,
            sourceRecordID: canonicalRecordID
        )
        identity.sourceRecordIDs = sourceRecordIDs
        return identity
    }

    private static func identity(from url: URL, provider: ModelProvider) -> CLIProxyAuthenticatedAccount? {
        guard (try? SecureFile.checkRegularOwnedFile(at: url)) != nil,
              let data = try? Data(contentsOf: url, options: [.mappedIfSafe]),
              data.count <= 65_536,
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }

        if json["disabled"] as? Bool == true { return nil }

        let email = normalizedEmail(from: json)
        let explicitAccountID = explicitAccountIdentity(from: json)
        let tokenSubject = oauthSubject(from: json)
        if let stableIdentity = explicitAccountID ?? email ?? tokenSubject {
            var account = CLIProxyAuthenticatedAccount(
                label: email ?? displayLabel(from: json, provider: provider, stableIdentity: stableIdentity),
                externalID: stableIdentityID(provider: provider, identity: stableIdentity),
                sourceRecordID: url.lastPathComponent
            )
            if let email {
                let previousEmailIdentity = stableIdentityID(provider: provider, identity: email)
                if previousEmailIdentity != account.externalID {
                    account.migrationAliases.append(previousEmailIdentity)
                }
            }
            return account
        }

        // Kimi Code's OAuth record deliberately contains no user email. Its
        // provider type and scope are the non-secret proof of a completed login;
        // tokens, device IDs and the auth payload never enter Workjet config.
        if provider == .kimi,
           (json["type"] as? String)?.lowercased() == "kimi",
           (json["scope"] as? String)?.lowercased().contains("kimi") == true {
            return CLIProxyAuthenticatedAccount(
                label: "Kimi Code",
                externalID: url.lastPathComponent,
                sourceRecordID: url.lastPathComponent
            )
        }
        return nil
    }

    private static func authRecordPrefix(for provider: ModelProvider) -> String? {
        switch provider {
        case .openAI: return "codex-"
        case .xAI: return "xai-"
        case .kimi: return "kimi-"
        case .anthropic: return "claude-"
        case .antigravity: return "antigravity-"
        case .miniMax, .zAI: return nil
        }
    }

    private static func normalizedEmail(from json: [String: Any]) -> String? {
        for dictionary in identityDictionaries(from: json) {
            for key in ["email", "mail", "email_address"] {
                guard let value = normalizedString(dictionary[key]) else { continue }
                return value.lowercased()
            }
        }
        return nil
    }

    private static func explicitAccountIdentity(from json: [String: Any]) -> String? {
        for dictionary in identityDictionaries(from: json) {
            for key in ["account_id", "accountId", "user_id", "userId", "subject", "sub"] {
                guard let value = normalizedString(dictionary[key]) else { continue }
                return value
            }
        }
        return nil
    }

    private static func displayLabel(
        from json: [String: Any],
        provider: ModelProvider,
        stableIdentity: String
    ) -> String {
        for dictionary in identityDictionaries(from: json) {
            for key in ["account_name", "display_name", "username", "login", "name"] {
                if let value = normalizedString(dictionary[key]) { return value }
            }
        }
        let suffix = String(stableIdentity.suffix(6))
        return suffix.isEmpty ? provider.rawValue : "\(provider.rawValue) · …\(suffix)"
    }

    private static func identityDictionaries(from json: [String: Any]) -> [[String: Any]] {
        var values = [json]
        for key in ["account", "user", "profile", "metadata"] {
            if let nested = json[key] as? [String: Any] { values.append(nested) }
        }
        return values
    }

    private static func normalizedString(_ raw: Any?) -> String? {
        let value: String
        switch raw {
        case let string as String: value = string
        case let number as NSNumber: value = number.stringValue
        default: return nil
        }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func preferredLabel(_ candidate: String, over current: String) -> Bool {
        let candidateIsEmail = candidate.contains("@")
        let currentIsEmail = current.contains("@")
        if candidateIsEmail != currentIsEmail { return candidateIsEmail }
        return candidate.localizedCaseInsensitiveCompare(current) == .orderedAscending
    }

    private static func oauthSubject(from json: [String: Any]) -> String? {
        guard let token = json["access_token"] as? String else { return nil }
        let segments = token.split(separator: ".", omittingEmptySubsequences: false)
        guard segments.count >= 2 else { return nil }
        var encoded = String(segments[1]).replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        encoded += String(repeating: "=", count: (4 - encoded.count % 4) % 4)
        guard let data = Data(base64Encoded: encoded), data.count <= 16_384,
              let payload = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        for key in ["sub", "user_id"] {
            if let value = payload[key] as? String {
                let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty { return trimmed }
            }
        }
        return nil
    }

    private static func stableIdentityID(provider: ModelProvider, identity: String) -> String {
        let digest = SHA256.hash(data: Data("\(provider.rawValue)\u{0}\(identity)".utf8))
        return "account-" + digest.map { String(format: "%02x", $0) }.joined()
    }
}
