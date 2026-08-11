import CryptoKit
import Foundation

public enum RemotePiBootstrapError: LocalizedError, Equatable {
    case localComputer
    case invalidHost
    case invalidUser
    case invalidPort
    case missingKnownHosts
    case hostKeyScanFailed(String)
    case sshServiceUnavailable(host: String, port: Int)
    case sshConnectionTimedOut(host: String, port: Int)
    case invalidHostKeyScan
    case hostKeyConfirmationMismatch
    case hostKeyUnknown
    case tailscaleUnavailable
    case invalidBundle(String)
    case commandFailed(String)
    case preflightBlocked(String)
    case invalidPreflight

    public var errorDescription: String? {
        switch self {
        case .localComputer: return "Der lokale Computer kann nicht als Remote-Ziel eingerichtet werden."
        case .invalidHost: return "Die Computeradresse fehlt oder ist ungültig."
        case .invalidUser: return "Der Benutzername fehlt oder ist ungültig."
        case .invalidPort: return "Der Verbindungsport ist ungültig."
        case .missingKnownHosts: return "Bestätige zuerst die Identität dieses Computers."
        case let .hostKeyScanFailed(detail):
            let cleanDetail = detail.trimmingCharacters(in: .whitespacesAndNewlines)
            return cleanDetail.isEmpty
                ? "Die SSH-Identität des Computers konnte nicht geladen werden."
                : "Die SSH-Identität des Computers konnte nicht geladen werden. Technischer Grund: \(cleanDetail)"
        case let .sshServiceUnavailable(host, port):
            return "\(host) ist erreichbar, aber auf Port \(port) antwortet kein SSH-Dienst. Aktiviere auf dem Ziel-Computer OpenSSH oder – bei einer Tailscale-Verbindung – Tailscale SSH (`sudo tailscale set --ssh`) und prüfe erneut."
        case let .sshConnectionTimedOut(host, port):
            return "SSH auf \(host):\(port) antwortet nicht. Prüfe den SSH-Dienst, die Tailscale-ACL und den eingestellten Port."
        case .invalidHostKeyScan: return "Die Identität des Computers konnte nicht sicher geprüft werden. Es wurde nichts gespeichert."
        case .hostKeyConfirmationMismatch: return "Die bestätigte Identität gehört nicht zu diesem Computer. Es wurde nichts gespeichert."
        case .hostKeyUnknown: return "Die Identität dieses Computers wurde noch nicht bestätigt. Bestätige sie und richte den Computer danach erneut ein."
        case .tailscaleUnavailable: return "Tailscale wurde auf diesem Mac nicht gefunden."
        case .invalidBundle: return "Die enthaltene Pi-Code-Komponente ist beschädigt. Installiere Workjet erneut."
        case let .commandFailed(detail): return detail
        case let .preflightBlocked(detail): return "Dieser Computer erfüllt noch nicht alle Voraussetzungen: \(detail)"
        case .invalidPreflight: return "Der Computer konnte nicht vollständig geprüft werden."
        }
    }
}

/// Immutable server-owned release metadata for the first managed worker skill.
/// The same values are embedded in the deployed host runtime; no client request
/// can replace the target, URL, version, or digest.
public enum RemoteManagedSkillArtifact {
    public static let greppyVersion = "0.3.1"
    public static let greppyCommit = "547705051d2c69481955e218f62f404e75e974ed"
    public static let greppySourceURL = "https://github.com/metric-space-ai/greppy/archive/547705051d2c69481955e218f62f404e75e974ed.tar.gz"
    public static let greppySourceSHA256 = "4d23d1db0f5b9accc2066ac3b430c03c46a904437b6d7456edec21665231907d"

    public static func supportsGreppy(os: String, architecture: String) -> Bool {
        os == "linux" && ["x86_64", "x64", "amd64"].contains(architecture.lowercased())
    }

    public static func validatesGreppySourceArchive(_ data: Data) -> Bool {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() == greppySourceSHA256
    }
}

public struct RemoteHostKeyCandidate: Equatable, Sendable {
    public let host: String
    public let port: Int
    public let knownHostsLine: String
    public let fingerprint: String

    public init(host: String, port: Int, knownHostsLine: String, fingerprint: String) {
        self.host = host
        self.port = port
        self.knownHostsLine = knownHostsLine
        self.fingerprint = fingerprint
    }
}

public protocol KnownHostsStoring: Sendable {
    func appendConfirmedHostKey(_ line: String, to url: URL) throws
}

public struct SecureKnownHostsStore: KnownHostsStoring, Sendable {
    public init() {}

    public func appendConfirmedHostKey(_ line: String, to url: URL) throws {
        guard url.path.hasPrefix("/"), !url.path.contains("\0"), !line.contains("\n"), !line.contains("\r") else {
            throw RemotePiBootstrapError.missingKnownHosts
        }
        let existing: Data
        if FileManager.default.fileExists(atPath: url.path) {
            try SecureFile.checkPrivateRegularOwnedFile(at: url)
            existing = try SecureFile.readRegularOwnedFile(at: url, maximumBytes: 1_024 * 1_024)
        } else {
            existing = Data()
        }
        let confirmedHost = line.split(whereSeparator: \.isWhitespace).first.map(String.init).map(Self.canonicalHostToken)
        guard let confirmedHost else { throw RemotePiBootstrapError.invalidHostKeyScan }
        let existingLines = String(decoding: existing, as: UTF8.self)
            .split(whereSeparator: \.isNewline)
            .map(String.init)
        if existingLines.contains(line) { return }

        // One private Workjet entry is authoritative for one host token. A
        // changed key is never appended beside the old key: explicit user
        // confirmation atomically replaces only that host's previous entry.
        let retained = existingLines.filter { existingLine in
            existingLine.split(whereSeparator: \.isWhitespace).first.map(String.init).map(Self.canonicalHostToken) != confirmedHost
        }
        let updated = Data((retained + [line]).joined(separator: "\n").appending("\n").utf8)
        try AtomicFile.write(updated, to: url, directoryMode: 0o700, fileMode: 0o600)
    }

    private static func canonicalHostToken(_ token: String) -> String {
        guard token.hasPrefix("["), token.hasSuffix("]:22") else { return token }
        return String(token.dropFirst().dropLast(4))
    }
}

public protocol OwnedFileReading: Sendable {
    func readOwnedRegularFile(at url: URL, maximumBytes: Int) throws -> Data
    func readPrivateOwnedRegularFile(at url: URL, maximumBytes: Int) throws -> Data
}

public extension OwnedFileReading {
    func readPrivateOwnedRegularFile(at url: URL, maximumBytes: Int) throws -> Data {
        try readOwnedRegularFile(at: url, maximumBytes: maximumBytes)
    }
}

public struct SecureOwnedFileReader: OwnedFileReading, Sendable {
    public init() {}
    public func readOwnedRegularFile(at url: URL, maximumBytes: Int) throws -> Data {
        try SecureFile.readRegularOwnedFile(at: url, maximumBytes: maximumBytes)
    }
    public func readPrivateOwnedRegularFile(at url: URL, maximumBytes: Int) throws -> Data {
        try SecureFile.checkPrivateRegularOwnedFile(at: url)
        return try SecureFile.readRegularOwnedFile(at: url, maximumBytes: maximumBytes)
    }
}

public protocol TailscaleLocating: Sendable {
    func executablePath() -> String?
}

public struct AllowlistedTailscaleLocator: TailscaleLocating, Sendable {
    public static let allowedPaths = [
        "/Applications/Tailscale.app/Contents/MacOS/Tailscale",
        "/opt/homebrew/bin/tailscale",
        "/usr/local/bin/tailscale",
        "/usr/bin/tailscale"
    ]
    public init() {}
    public func executablePath() -> String? {
        Self.allowedPaths.first { FileManager.default.isExecutableFile(atPath: $0) }
    }
}

public enum RemoteCommandBuilder {
    static func knownHostsOption(for path: String) throws -> String {
        guard !path.contains("\0"), !path.contains("\n"), !path.contains("\r") else {
            throw RemotePiBootstrapError.missingKnownHosts
        }
        // OpenSSH parses UserKnownHostsFile as a config token list even when
        // `-o` and its value are already separate process arguments. Preserve
        // paths such as macOS' "Application Support" by quoting the token for
        // OpenSSH's config parser (these quotes are intentionally part of the
        // argument, not shell quoting).
        let escaped = path
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        return "UserKnownHostsFile=\"\(escaped)\""
    }

    static func identityArguments(for computer: Computer) throws -> [String] {
        let path = computer.identityFilePath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !path.contains("\0") else { throw RemotePiBootstrapError.invalidHost }
        guard !path.isEmpty else { return [] }
        guard path.hasPrefix("/") else { throw RemotePiBootstrapError.commandFailed("Wähle einen gültigen SSH-Schlüssel.") }
        return ["-o", "IdentitiesOnly=yes", "-i", path]
    }

    public static func command(
        for computer: Computer,
        tailscaleExecutable: String?,
        remoteExecutable: String,
        remoteArguments: [String],
        standardInput: Data,
        timeout: TimeInterval,
        stdoutLimit: Int = 4 * 1_024 * 1_024
    ) throws -> CommandSpec {
        try validate(computer)
        guard remoteExecutable.hasPrefix("/")
                || remoteExecutable == "node"
                || remoteExecutable == ".local/lib/workjet/current/workjet-node" else {
            throw RemotePiBootstrapError.commandFailed("Der Vorgang wurde aus Sicherheitsgründen abgebrochen.")
        }
        // Tailscale supplies discovery and the encrypted network path. Workjet
        // deliberately uses the same strict OpenSSH transport for both remote
        // connection types so bootstrap, host RPC and reverse provider relays
        // all enforce the one explicitly confirmed private known_hosts file.
        _ = tailscaleExecutable
        switch computer.transport {
        case .local:
            throw RemotePiBootstrapError.localComputer
        case .ssh, .tailscale:
            let knownHosts = computer.knownHostsPath.trimmingCharacters(in: .whitespacesAndNewlines)
            guard knownHosts.hasPrefix("/") else { throw RemotePiBootstrapError.missingKnownHosts }
            var arguments = [
                "-o", "BatchMode=yes",
                "-o", "ConnectTimeout=10",
                "-o", "StrictHostKeyChecking=yes",
                "-o", try knownHostsOption(for: knownHosts),
                "-o", "ClearAllForwardings=yes",
                "-o", "ForwardAgent=no"
            ]
            arguments += try identityArguments(for: computer)
            arguments += [
                "-p", String(computer.port),
                "-l", computer.user,
                "--", computer.host,
                remoteExecutable
            ] + remoteArguments
            return CommandSpec(
                executable: "/usr/bin/ssh",
                arguments: arguments,
                standardInput: standardInput,
                timeout: timeout,
                stdoutLimit: stdoutLimit,
                stderrLimit: 1 * 1_024 * 1_024
            )
        }
    }

    public static func validate(_ computer: Computer) throws {
        guard !computer.isLocal else { throw RemotePiBootstrapError.localComputer }
        let hostPattern = #"^[A-Za-z0-9][A-Za-z0-9._:-]{0,254}$"#
        let userPattern = #"^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$"#
        guard computer.host.range(of: hostPattern, options: .regularExpression) != nil else { throw RemotePiBootstrapError.invalidHost }
        guard computer.user.range(of: userPattern, options: .regularExpression) != nil else { throw RemotePiBootstrapError.invalidUser }
        guard (1...65535).contains(computer.port) else { throw RemotePiBootstrapError.invalidPort }
    }
}

public struct RemotePiBootstrap: Sendable {
    private let runner: any CommandRunning
    private let files: any OwnedFileReading
    private let knownHostsStore: any KnownHostsStoring
    private let tailscaleLocator: any TailscaleLocating
    private let now: @Sendable () -> Date

    public init(
        runner: any CommandRunning = ProcessCommandRunner(),
        files: any OwnedFileReading = SecureOwnedFileReader(),
        knownHostsStore: any KnownHostsStoring = SecureKnownHostsStore(),
        tailscaleLocator: any TailscaleLocating = AllowlistedTailscaleLocator(),
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.runner = runner
        self.files = files
        self.knownHostsStore = knownHostsStore
        self.tailscaleLocator = tailscaleLocator
        self.now = now
    }

    public func scanHostKey(for computer: Computer) async throws -> RemoteHostKeyCandidate {
        try RemoteCommandBuilder.validate(computer)
        guard computer.transport == .ssh || computer.transport == .tailscale else {
            throw RemotePiBootstrapError.localComputer
        }
        let result = try await runner.run(CommandSpec(
            executable: "/usr/bin/ssh-keyscan",
            arguments: ["-T", "10", "-t", "ed25519", "-p", String(computer.port), computer.host],
            timeout: 15,
            stdoutLimit: 16_384,
            stderrLimit: 16_384
        ))
        guard result.exitCode == 0, !result.stdoutTruncated, !result.stderrTruncated else {
            let detail = String(decoding: result.standardError.prefix(2_048), as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let normalized = detail.lowercased()
            if normalized.contains("connection refused")
                || normalized.contains("broken pipe")
                || normalized.contains("connection reset")
                || normalized.contains("connection closed") {
                throw RemotePiBootstrapError.sshServiceUnavailable(host: computer.host, port: computer.port)
            }
            if normalized.contains("timed out")
                || normalized.contains("no route to host")
                || normalized.contains("network is unreachable") {
                throw RemotePiBootstrapError.sshConnectionTimedOut(host: computer.host, port: computer.port)
            }
            throw RemotePiBootstrapError.hostKeyScanFailed(detail.isEmpty ? "ssh-keyscan endete mit Status \(result.exitCode)." : detail)
        }
        return try Self.parseHostKeyScan(result.standardOutput, expectedHost: computer.host, expectedPort: computer.port)
    }

    public func confirmHostKey(_ candidate: RemoteHostKeyCandidate, for computer: Computer) throws {
        try RemoteCommandBuilder.validate(computer)
        guard (computer.transport == .ssh || computer.transport == .tailscale),
              candidate.host == computer.host,
              candidate.port == computer.port,
              try Self.parseHostKeyScan(Data((candidate.knownHostsLine + "\n").utf8), expectedHost: computer.host, expectedPort: computer.port) == candidate
        else { throw RemotePiBootstrapError.hostKeyConfirmationMismatch }
        let path = computer.knownHostsPath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard path.hasPrefix("/"), !path.contains("\0") else { throw RemotePiBootstrapError.missingKnownHosts }
        try knownHostsStore.appendConfirmedHostKey(candidate.knownHostsLine, to: URL(fileURLWithPath: path))
    }

    static func parseHostKeyScan(_ data: Data, expectedHost: String, expectedPort: Int) throws -> RemoteHostKeyCandidate {
        guard data.count <= 16_384, let output = String(data: data, encoding: .utf8) else {
            throw RemotePiBootstrapError.invalidHostKeyScan
        }
        let lines = output.split(whereSeparator: \.isNewline).map(String.init).filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("#") }
        guard lines.count == 1 else { throw RemotePiBootstrapError.invalidHostKeyScan }
        let fields = lines[0].split(whereSeparator: \.isWhitespace).map(String.init)
        guard fields.count == 3, fields[1] == "ssh-ed25519",
              let blob = Data(base64Encoded: fields[2]), blob.count >= 32, blob.count <= 8_192 else {
            throw RemotePiBootstrapError.invalidHostKeyScan
        }
        let expectedTokens = expectedPort == 22
            ? [expectedHost, "[\(expectedHost)]:22"]
            : ["[\(expectedHost)]:\(expectedPort)"]
        guard expectedTokens.contains(fields[0]) else { throw RemotePiBootstrapError.invalidHostKeyScan }
        let digest = Data(SHA256.hash(data: blob)).base64EncodedString().replacingOccurrences(of: "=", with: "")
        return RemoteHostKeyCandidate(host: expectedHost, port: expectedPort, knownHostsLine: lines[0], fingerprint: "SHA256:\(digest)")
    }

    public func deploy(_ input: Computer) async -> Computer {
        var computer = input
        computer.pinnedSidecarVersion = PiSidecarRuntime.version
        computer.bubblewrapExecutablePath = nil
        computer.deploymentStatus = .checking
        computer.deploymentDetail = "Der Computer wird geprüft."
        do {
            try RemoteCommandBuilder.validate(computer)
            let bundlePath = computer.sidecarBundlePath.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !bundlePath.isEmpty, bundlePath.hasPrefix("/"), !bundlePath.contains("\0") else { throw RemotePiBootstrapError.invalidBundle("Pfad muss absolut sein.") }
            let bundleURL = URL(fileURLWithPath: bundlePath)
            let bundle: Data
            do { bundle = try files.readOwnedRegularFile(at: bundleURL, maximumBytes: 32 * 1_024 * 1_024) }
            catch { throw RemotePiBootstrapError.invalidBundle(error.localizedDescription) }
            guard !bundle.isEmpty else { throw RemotePiBootstrapError.invalidBundle("Datei ist leer.") }

            let knownHostsPath = computer.knownHostsPath.trimmingCharacters(in: .whitespacesAndNewlines)
            guard knownHostsPath.hasPrefix("/"), !knownHostsPath.contains("\0") else { throw RemotePiBootstrapError.missingKnownHosts }
            do { _ = try files.readPrivateOwnedRegularFile(at: URL(fileURLWithPath: knownHostsPath), maximumBytes: 1_024 * 1_024) }
            catch { throw RemotePiBootstrapError.missingKnownHosts }
            let tailscaleExecutable = computer.transport == .tailscale ? tailscaleLocator.executablePath() : nil
            computer.tailscaleExecutablePath = tailscaleExecutable

            let runnerData = Data(Self.turnRunnerSource.utf8)
            let hostData = Data(Self.hostRuntimeSource.utf8)
            var releaseMaterial = Data(PiSidecarRuntime.version.utf8)
            releaseMaterial.append(0)
            releaseMaterial.append(bundle)
            releaseMaterial.append(0)
            releaseMaterial.append(runnerData)
            releaseMaterial.append(0)
            releaseMaterial.append(hostData)
            let contentHash = Self.sha256(releaseMaterial)
            let preflight = try await execute(
                computer: computer,
                tailscaleExecutable: tailscaleExecutable,
                remoteExecutable: "/bin/sh",
                remoteArguments: ["-s", "--"],
                input: Data(Self.preflightScript.utf8),
                timeout: 20
            )
            let facts = try parsePreflight(preflight.standardOutput)
            guard facts.os == "Linux" else { throw RemotePiBootstrapError.preflightBlocked("Workjet unterstützt hier derzeit nur Linux.") }
            guard ["aarch64", "arm64", "armv7l", "x86_64"].contains(facts.arch) else { throw RemotePiBootstrapError.preflightBlocked("Die Prozessorarchitektur wird nicht unterstützt.") }
            guard facts.homeWritable else { throw RemotePiBootstrapError.preflightBlocked("Workjet kann im Benutzerordner nicht arbeiten.") }
            guard facts.hasShell else { throw RemotePiBootstrapError.preflightBlocked("Eine benötigte Systemkomponente fehlt.") }
            guard facts.nodeMajor >= 20 else { throw RemotePiBootstrapError.preflightBlocked("Auf dem Computer wird eine neuere JavaScript-Laufzeit benötigt (Version 20 oder neuer).") }
            guard facts.shaTool == "sha256sum" || facts.shaTool == "shasum" else { throw RemotePiBootstrapError.preflightBlocked("Eine benötigte Prüffunktion fehlt.") }
            computer.bubblewrapExecutablePath = facts.bubblewrapExecutable
            if computer.sandboxEnabled {
                guard let executable = facts.bubblewrapExecutable else {
                    throw RemotePiBootstrapError.preflightBlocked("Die Minimal-Sandbox ist auf diesem Computer nicht verfügbar. Installiere sie dort oder deaktiviere die Minimal-Sandbox.")
                }
                guard executable.hasPrefix("/") else { throw RemotePiBootstrapError.invalidPreflight }
            }
            computer.lastSuccessfulPreflightAt = now()

            try await requireSuccess(computer: computer, tailscaleExecutable: tailscaleExecutable, script: Self.prepareScript, positional: [contentHash], timeout: 20)

            let bundleFileHash = Self.sha256(bundle)
            let runnerHash = Self.sha256(runnerData)
            let hostHash = Self.sha256(hostData)
            let manifestData = try Self.manifest(contentHash: contentHash, bundleHash: bundleFileHash, runnerHash: runnerHash, hostHash: hostHash, hostData: hostData, nodeExecutable: facts.nodeExecutable, sandboxEnabled: computer.sandboxEnabled, bubblewrapExecutable: computer.bubblewrapExecutablePath)
            let manifestHash = Self.sha256(manifestData)

            try await upload(bundle, named: "ctox-pi-sidecar.mjs", contentHash: contentHash, expectedHash: bundleFileHash, nodeExecutable: facts.nodeExecutable, computer: computer, tailscaleExecutable: tailscaleExecutable)
            try await upload(runnerData, named: "workjet-pi-turn.mjs", contentHash: contentHash, expectedHash: runnerHash, nodeExecutable: facts.nodeExecutable, computer: computer, tailscaleExecutable: tailscaleExecutable)
            try await upload(manifestData, named: "manifest.json", contentHash: contentHash, expectedHash: manifestHash, nodeExecutable: facts.nodeExecutable, computer: computer, tailscaleExecutable: tailscaleExecutable)

            try await requireSuccess(
                computer: computer,
                tailscaleExecutable: tailscaleExecutable,
                script: Self.finalizeScript,
                positional: [contentHash, bundleFileHash, runnerHash, hostHash, manifestHash, facts.nodeExecutable],
                timeout: 30
            )

            computer.deploymentStatus = .installed
            computer.deploymentDetail = "Pi Code wurde eingerichtet. Der Computer ist bereit."
            computer.installedContentHash = contentHash
            computer.installedSidecarVersion = PiSidecarRuntime.version
            computer.lastSuccessfulDeploymentAt = now()
            return computer
        } catch let error as RemotePiBootstrapError {
            computer.deploymentStatus = error.isBlocked ? .blocked : .failed
            computer.deploymentDetail = error.localizedDescription
            computer.installedContentHash = nil
            computer.installedSidecarVersion = nil
            return computer
        } catch {
            computer.deploymentStatus = .failed
            computer.deploymentDetail = "Der Computer konnte nicht eingerichtet werden. Prüfe Verbindung und Einstellungen."
            computer.installedContentHash = nil
            computer.installedSidecarVersion = nil
            return computer
        }
    }

    private func upload(_ data: Data, named name: String, contentHash: String, expectedHash: String, nodeExecutable: String, computer: Computer, tailscaleExecutable: String?) async throws {
        guard ["ctox-pi-sidecar.mjs", "workjet-pi-turn.mjs", "workjet-host.mjs", "manifest.json"].contains(name) else {
            throw RemotePiBootstrapError.commandFailed("Der Vorgang wurde aus Sicherheitsgründen abgebrochen.")
        }
        let input = Data(Self.uploadProgram(data: data).utf8)
        _ = try await execute(
            computer: computer,
            tailscaleExecutable: tailscaleExecutable,
            remoteExecutable: nodeExecutable,
            remoteArguments: ["--input-type=module", "-", contentHash, name, expectedHash],
            input: input,
            timeout: 60
        )
    }

    private func requireSuccess(computer: Computer, tailscaleExecutable: String?, script: String, positional: [String], timeout: TimeInterval) async throws {
        _ = try await execute(
            computer: computer,
            tailscaleExecutable: tailscaleExecutable,
            remoteExecutable: "/bin/sh",
            remoteArguments: ["-s", "--"] + positional,
            input: Data(script.utf8),
            timeout: timeout
        )
    }

    private func execute(computer: Computer, tailscaleExecutable: String?, remoteExecutable: String, remoteArguments: [String], input: Data, timeout: TimeInterval) async throws -> CommandResult {
        let command = try RemoteCommandBuilder.command(for: computer, tailscaleExecutable: tailscaleExecutable, remoteExecutable: remoteExecutable, remoteArguments: remoteArguments, standardInput: input, timeout: timeout)
        let result = try await runner.run(command)
        guard result.exitCode == 0 else {
            let stderr = String(decoding: result.standardError.prefix(2_048), as: UTF8.self)
            // Tailscale transports still use SSH underneath. A missing or changed
            // host key therefore needs the same guided confirmation flow as a
            // direct SSH connection instead of leaking the raw ssh diagnostic.
            if stderr.localizedCaseInsensitiveContains("host key verification failed")
                || stderr.localizedCaseInsensitiveContains("known hosts")
                || stderr.localizedCaseInsensitiveContains("no ed25519 host key is known") {
                throw RemotePiBootstrapError.hostKeyUnknown
            }
            if stderr.localizedCaseInsensitiveContains("permission denied")
                || stderr.localizedCaseInsensitiveContains("no identities")
                || stderr.localizedCaseInsensitiveContains("load key") {
                let selectedIdentity = computer.identityFilePath.trimmingCharacters(in: .whitespacesAndNewlines)
                let identityDescription = selectedIdentity.isEmpty
                    ? "der automatischen Schlüsselauswahl"
                    : "„\(URL(fileURLWithPath: selectedIdentity).lastPathComponent)“"
                throw RemotePiBootstrapError.commandFailed(
                    "SSH läuft, aber die Anmeldung als „\(computer.user)“ mit \(identityDescription) wurde abgelehnt. Wähle den richtigen Benutzer/Schlüssel oder hinterlege dessen öffentlichen Schlüssel auf dem Ziel-Computer."
                )
            }
            if stderr.localizedCaseInsensitiveContains("could not resolve hostname")
                || stderr.localizedCaseInsensitiveContains("connection timed out")
                || stderr.localizedCaseInsensitiveContains("no route to host") {
                throw RemotePiBootstrapError.commandFailed("Der Computer ist nicht erreichbar. Prüfe Host, Tailscale und SSH-Port.")
            }
            throw RemotePiBootstrapError.commandFailed("Verbindung fehlgeschlagen. Prüfe Benutzer, Erreichbarkeit und den bestätigten Computerschlüssel.")
        }
        guard !result.stdoutTruncated, !result.stderrTruncated else { throw RemotePiBootstrapError.commandFailed("Der Computer hat bei der Prüfung zu viele Daten gesendet.") }
        return result
    }

    private func parsePreflight(_ data: Data) throws -> PreflightFacts {
        let lines = String(decoding: data, as: UTF8.self).split(whereSeparator: \.isNewline)
        var values: [String: String] = [:]
        for line in lines {
            let parts = line.split(separator: "=", maxSplits: 1).map(String.init)
            if parts.count == 2 { values[parts[0]] = parts[1] }
        }
        guard let os = values["WORKJET_OS"], let arch = values["WORKJET_ARCH"], let node = values["WORKJET_NODE"], let nodeExecutable = values["WORKJET_NODE_PATH"], let bubblewrap = values["WORKJET_BWRAP"] else {
            throw RemotePiBootstrapError.invalidPreflight
        }
        let selectedNodeExecutable = nodeExecutable == "missing" ? "" : nodeExecutable
        guard selectedNodeExecutable.isEmpty || (selectedNodeExecutable.hasPrefix("/") && !selectedNodeExecutable.contains("\0") && !selectedNodeExecutable.contains("\n")) else {
            throw RemotePiBootstrapError.invalidPreflight
        }
        let major = Int(node.trimmingCharacters(in: CharacterSet(charactersIn: "vV")).split(separator: ".").first ?? "") ?? 0
        let bubblewrapExecutable = bubblewrap == "missing" ? nil : bubblewrap
        return PreflightFacts(os: os, arch: arch, homeWritable: values["WORKJET_HOME_WRITABLE"] == "1", hasShell: values["WORKJET_SH"] == "1", nodeVersion: node, nodeMajor: major, nodeExecutable: selectedNodeExecutable, shaTool: values["WORKJET_SHA"] ?? "", bubblewrapExecutable: bubblewrapExecutable)
    }

    private static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private static func manifest(contentHash: String, bundleHash: String, runnerHash: String, hostHash: String, hostData: Data, nodeExecutable: String, sandboxEnabled: Bool, bubblewrapExecutable: String?) throws -> Data {
        let value = DeploymentManifest(
            schema: 1,
            version: PiSidecarRuntime.version,
            contentHash: contentHash,
            files: [
                "ctox-pi-sidecar.mjs": bundleHash,
                "workjet-pi-turn.mjs": runnerHash,
                "workjet-host.mjs": hostHash
            ],
            hostRuntimeBase64: hostData.base64EncodedString(),
            nodeExecutable: nodeExecutable,
            inference: "ephemeral-provider-route-with-run-scoped-loopback-relay",
            events: "post-hoc-final-response",
            sandbox: sandboxEnabled ? "bubblewrap" : "disabled",
            bubblewrapExecutable: sandboxEnabled ? bubblewrapExecutable : nil
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(value)
    }

    private static func uploadProgram(data: Data) -> String {
        let encoded = data.base64EncodedString()
        return #"""
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import crypto from "node:crypto";
const [contentHash, name, expectedHash] = process.argv.slice(2);
if (!/^[0-9a-f]{64}$/.test(contentHash) || !/^[0-9a-f]{64}$/.test(expectedHash) || !["ctox-pi-sidecar.mjs", "workjet-pi-turn.mjs", "workjet-host.mjs", "manifest.json"].includes(name)) process.exit(64);
process.umask(0o077);
const home = os.homedir();
const directories = [path.join(home, ".local"), path.join(home, ".local", "lib"), path.join(home, ".local", "lib", "workjet"), path.join(home, ".local", "lib", "workjet", "releases")];
const release = path.join(directories[3], contentHash);
for (const directory of [...directories, release]) {
  const info = fs.lstatSync(directory);
  if (!info.isDirectory() || info.isSymbolicLink()) process.exit(73);
}
const payload = Buffer.from("\#(encoded)", "base64");
if (crypto.createHash("sha256").update(payload).digest("hex") !== expectedHash) process.exit(65);
const temporary = path.join(release, `.${name}.tmp-${process.pid}`);
fs.writeFileSync(temporary, payload, {mode: 0o600, flag: "wx"});
fs.renameSync(temporary, path.join(release, name));
"""#
    }

    public static let preflightScript = #"""
set -eu
umask 077
printf 'WORKJET_OS=%s\n' "$(uname -s)"
printf 'WORKJET_ARCH=%s\n' "$(uname -m)"
if [ -n "${HOME:-}" ] && [ -d "$HOME" ] && [ -w "$HOME" ]; then printf 'WORKJET_HOME_WRITABLE=1\n'; else printf 'WORKJET_HOME_WRITABLE=0\n'; fi
if command -v sh >/dev/null 2>&1; then printf 'WORKJET_SH=1\n'; else printf 'WORKJET_SH=0\n'; fi
node_path=""
node_version="missing"
node_major=0
for candidate in "$(command -v node 2>/dev/null || true)" "$HOME"/.local/node-v*/bin/node "$HOME/.local/bin/node"; do
  [ -n "$candidate" ] && [ -x "$candidate" ] || continue
  candidate_version="$($candidate --version 2>/dev/null || true)"
  candidate_major="$(printf '%s' "$candidate_version" | sed -n 's/^[vV]\([0-9][0-9]*\).*/\1/p')"
  case "$candidate_major" in ''|*[!0-9]*) continue;; esac
  if [ "$candidate_major" -gt "$node_major" ]; then node_path="$candidate"; node_version="$candidate_version"; node_major="$candidate_major"; fi
done
printf 'WORKJET_NODE=%s\n' "$node_version"
printf 'WORKJET_NODE_PATH=%s\n' "${node_path:-missing}"
if command -v sha256sum >/dev/null 2>&1; then printf 'WORKJET_SHA=sha256sum\n'; elif command -v shasum >/dev/null 2>&1; then printf 'WORKJET_SHA=shasum\n'; else printf 'WORKJET_SHA=missing\n'; fi
if command -v bwrap >/dev/null 2>&1; then bwrap_path="$(command -v bwrap)"; case "$bwrap_path" in /*) if [ -x "$bwrap_path" ]; then printf 'WORKJET_BWRAP=%s\n' "$bwrap_path"; else printf 'WORKJET_BWRAP=missing\n'; fi;; *) printf 'WORKJET_BWRAP=missing\n';; esac; else printf 'WORKJET_BWRAP=missing\n'; fi
"""#

    public static let prepareScript = #"""
set -eu
umask 077
hash="$1"
case "$hash" in *[!0-9a-f]*|'') exit 64;; esac
[ "${#hash}" -eq 64 ] || exit 64
local_root="$HOME/.local"
lib="$local_root/lib"
root="$lib/workjet"
releases="$root/releases"
release="$releases/$hash"
for directory in "$local_root" "$lib" "$root" "$releases" "$release"; do
  if [ -L "$directory" ] || { [ -e "$directory" ] && [ ! -d "$directory" ]; }; then exit 73; fi
done
mkdir -p "$release"
chmod 700 "$local_root" "$lib" "$root" "$releases" "$release"
"""#

    public static let finalizeScript = #"""
set -eu
umask 077
hash="$1"; bundle_hash="$2"; runner_hash="$3"; host_hash="$4"; manifest_hash="$5"; node_executable="$6"
for value in "$hash" "$bundle_hash" "$runner_hash" "$host_hash" "$manifest_hash"; do case "$value" in *[!0-9a-f]*|'') exit 64;; esac; [ "${#value}" -eq 64 ] || exit 64; done
case "$node_executable" in /*) ;; *) exit 64;; esac
case "$node_executable" in *[!A-Za-z0-9._/-]*) exit 64;; esac
[ -x "$node_executable" ] || exit 69
root="$HOME/.local/lib/workjet"
releases="$root/releases"
release="$releases/$hash"
for directory in "$HOME/.local" "$HOME/.local/lib" "$root" "$releases" "$release"; do [ -d "$directory" ] && [ ! -L "$directory" ] || exit 73; done
if command -v sha256sum >/dev/null 2>&1; then
  check() { [ "$(sha256sum "$1" | awk '{print $1}')" = "$2" ]; }
elif command -v shasum >/dev/null 2>&1; then
  check() { [ "$(shasum -a 256 "$1" | awk '{print $1}')" = "$2" ]; }
else
  exit 69
fi
check "$release/ctox-pi-sidecar.mjs" "$bundle_hash"
check "$release/workjet-pi-turn.mjs" "$runner_hash"
check "$release/manifest.json" "$manifest_hash"
"$node_executable" - "$release/manifest.json" "$release/workjet-host.mjs" <<'WORKJET_HOST'
const fs = require("node:fs");
const path = require("node:path");
const [manifestFile, hostFile] = process.argv.slice(2);
const manifest = JSON.parse(fs.readFileSync(manifestFile, "utf8"));
if (typeof manifest.hostRuntimeBase64 !== "string" || manifest.hostRuntimeBase64.length > 2000000) process.exit(65);
if (typeof manifest.nodeExecutable !== "string" || !/^\/[A-Za-z0-9._\/-]+$/.test(manifest.nodeExecutable)) process.exit(65);
try { fs.accessSync(manifest.nodeExecutable, fs.constants.X_OK); } catch { process.exit(69); }
const payload = Buffer.from(manifest.hostRuntimeBase64, "base64");
if (payload.length === 0 || payload.length > 1048576) process.exit(65);
const temporary = `${hostFile}.tmp-${process.pid}`;
fs.writeFileSync(temporary, payload, {mode: 0o600, flag: "wx"});
fs.renameSync(temporary, hostFile);
const launcher = `${path.dirname(hostFile)}/workjet-node`;
const launcherTemporary = `${launcher}.tmp-${process.pid}`;
fs.writeFileSync(launcherTemporary, `#!/bin/sh\nexec ${manifest.nodeExecutable} "$@"\n`, {mode: 0o700, flag: "wx"});
fs.renameSync(launcherTemporary, launcher);
WORKJET_HOST
check "$release/workjet-host.mjs" "$host_hash"
chmod 600 "$release/ctox-pi-sidecar.mjs" "$release/workjet-pi-turn.mjs" "$release/workjet-host.mjs" "$release/manifest.json"
chmod 700 "$release/workjet-node"
if { [ -e "$root/current" ] || [ -L "$root/current" ]; } && [ ! -L "$root/current" ]; then exit 73; fi
"$node_executable" - "$root" "$hash" <<'WORKJET_NODE'
const fs = require("node:fs");
const path = require("node:path");
const [root, hash] = process.argv.slice(2);
if (!/^[0-9a-f]{64}$/.test(hash)) process.exit(64);
const current = path.join(root, "current");
const temporary = path.join(root, `.current-${hash}-${process.pid}`);
try { fs.unlinkSync(temporary); } catch (error) { if (error.code !== "ENOENT") throw error; }
fs.symlinkSync(path.join("releases", hash), temporary);
fs.renameSync(temporary, current);
WORKJET_NODE
"""#

    /// Small persistent host runtime used through SSH/Tailscale. It never accepts
    /// an executable or argument vector from the client: the harness ID is
    /// resolved through this server-side registry before a process is started.
    public static let hostRuntimeSource = #"""
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import process from "node:process";
import crypto from "node:crypto";
import {execFileSync, spawn} from "node:child_process";

const PROTOCOL = 2;
const HOST_VERSION = "2";
const EVENT_LIMIT_COUNT = 64;
const EVENT_LIMIT_BYTES = 256 * 1024;
const HEARTBEAT_MS = 4000;
const STOP_GRACE_MS = 2500;
const RUN_RETENTION_MS = 30 * 24 * 60 * 60 * 1000;
const TERMINAL_OVERFLOW_MIN_AGE_MS = 24 * 60 * 60 * 1000;
const MAX_RETAINED_TERMINAL_RUNS = 128;
const release = fs.realpathSync(path.dirname(new URL(import.meta.url).pathname));
const stateRoot = path.join(os.homedir(), ".local", "state", "workjet", "host");
const runsRoot = path.join(stateRoot, "runs");
const reposRoot = path.join(stateRoot, "repos");
const worktreesRoot = path.join(stateRoot, "worktrees");
const importsRoot = path.join(stateRoot, "imports");
const harnessesRoot = path.join(os.homedir(), ".local", "lib", "workjet", "harnesses");
const managedNPMRoot = path.join(harnessesRoot, "npm");
const managedNPMBin = path.join(managedNPMRoot, "bin");
const managedSkillsRoot = path.join(os.homedir(), ".local", "lib", "workjet", "skills");
const managedSkillsBin = path.join(managedSkillsRoot, "bin");
const GREPPY_VERSION = "0.3.1";
const GREPPY_COMMIT = "547705051d2c69481955e218f62f404e75e974ed";
const GREPPY_SOURCE_URL = "https://github.com/metric-space-ai/greppy/archive/547705051d2c69481955e218f62f404e75e974ed.tar.gz";
const GREPPY_SOURCE_SHA256 = "4d23d1db0f5b9accc2066ac3b430c03c46a904437b6d7456edec21665231907d";
process.umask(0o077);
for (const directory of [stateRoot, runsRoot, reposRoot, worktreesRoot, importsRoot]) {
  fs.mkdirSync(directory, {recursive: true, mode: 0o700});
  const info = fs.lstatSync(directory);
  if (!info.isDirectory() || info.isSymbolicLink() || info.uid !== process.geteuid()) throw new Error("unsafe host state directory");
  fs.chmodSync(directory, 0o700);
}

const safeRunID = value => typeof value === "string" && /^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$/.test(value) && !value.includes("..") && !value.includes("@{") && !value.endsWith(".") && !value.endsWith(".lock");
const runDirectory = runID => path.join(runsRoot, runID);
const atomicJSON = (file, value) => {
  const temporary = `${file}.tmp-${process.pid}-${Math.random().toString(16).slice(2)}`;
  const handle = fs.openSync(temporary, "wx", 0o600);
  try { fs.writeFileSync(handle, JSON.stringify(value)); } finally { fs.closeSync(handle); }
  fs.renameSync(temporary, file);
};
const readJSON = file => JSON.parse(fs.readFileSync(file, "utf8"));
const response = value => process.stdout.write(JSON.stringify({protocolVersion: PROTOCOL, ok: true, state: "unknown", cursor: 0, events: [], capabilities: [], ...value}) + "\n");
const reject = message => { process.stdout.write(JSON.stringify({protocolVersion: PROTOCOL, ok: false, error: message, state: "error", cursor: 0, events: [], capabilities: []}) + "\n"); process.exit(0); };
const ledgerFile = directory => path.join(directory, "events.json");
const metadataFile = directory => path.join(directory, "ledger.json");
const readBoundedEvents = directory => {
  const file = ledgerFile(directory);
  let data;
  try {
    const size = fs.statSync(file).size;
    if (size > EVENT_LIMIT_BYTES) throw new Error("event store exceeds retention bound");
    data = fs.readFileSync(file, "utf8");
  } catch (error) { if (error.code === "ENOENT") return []; throw error; }
  const events = JSON.parse(data);
  if (!Array.isArray(events) || events.length > EVENT_LIMIT_COUNT) throw new Error("invalid bounded event store");
  return events;
};
const ledgerMetadata = directory => {
  const events = readBoundedEvents(directory);
  let stored = {};
  try { stored = readJSON(metadataFile(directory)); } catch {}
  const eventCursor = events.at(-1)?.sequence ?? 0;
  return {cursor: Math.max(Number(stored.cursor) || 0, eventCursor), oldestSequence: events[0]?.sequence, count: events.length};
};
const currentCursor = directory => Number(ledgerMetadata(directory).cursor) || 0;
const appendEvent = (directory, event) => {
  const sequence = currentCursor(directory) + 1;
  const next = {sequence, timestamp: new Date().toISOString(), ...event};
  const events = readBoundedEvents(directory);
  events.push(next);
  while (events.length > EVENT_LIMIT_COUNT || Buffer.byteLength(JSON.stringify(events)) > EVENT_LIMIT_BYTES) events.shift();
  if (events.length === 0) throw new Error("single event exceeds retention bound");
  atomicJSON(ledgerFile(directory), events);
  atomicJSON(metadataFile(directory), {cursor: sequence, oldestSequence: events[0].sequence, count: events.length, bytes: Buffer.byteLength(JSON.stringify(events))});
  return sequence;
};
const setState = (directory, state, extra = {}) => {
  let previous = {};
  try { previous = readJSON(path.join(directory, "state.json")); } catch {}
  atomicJSON(path.join(directory, "state.json"), {...previous, state, updatedAt: new Date().toISOString(), ...extra});
};
const readState = directory => readJSON(path.join(directory, "state.json"));
const workerIDFromOwner = ownerID => {
  const match = typeof ownerID === "string" ? /^workjet-worker-([0-9a-fA-F-]{36})$/.exec(ownerID) : null;
  return match ? match[1].toLowerCase() : undefined;
};
const persistedRunMetadata = (directory, state = {}) => {
  let launch;
  try { launch = readJSON(path.join(directory, "launch.json")); } catch { return undefined; }
  const providerRoute = typeof launch.providerRoute?.displayName === "string" ? launch.providerRoute.displayName : undefined;
  const providerAccountLabel = typeof state.providerRoute === "string" ? state.providerRoute : undefined;
  return {
    workerID: typeof launch.workerID === "string" ? launch.workerID : undefined,
    workerName: typeof launch.workerName === "string" ? launch.workerName : undefined,
    harnessID: typeof launch.harnessID === "string" ? launch.harnessID : undefined,
    model: typeof launch.model === "string" ? launch.model : undefined,
    reasoning: typeof launch.reasoning === "string" ? launch.reasoning : undefined,
    speed: launch.options?.fastMode === "true" ? "fast" : launch.options?.fastMode === "false" ? "normal" : typeof launch.options?.speed === "string" ? launch.options.speed : undefined,
    providerRoute,
    providerAccountLabel,
    startedAt: typeof launch.startedAt === "string" ? launch.startedAt : undefined,
    workspaceRepoID: validRepoID(launch.workspace?.repoID) ? launch.workspace.repoID : undefined,
    workspaceCommitOID: validOID(launch.workspace?.snapshotCommitOID) ? launch.workspace.snapshotCommitOID : undefined,
    workspaceRunID: validRepoID(launch.workspace?.repoID) ? path.basename(launch.hostWorkspace?.path ?? "") : undefined
  };
};
const treeContainsSymlink = directory => {
  const queue = [directory];
  while (queue.length) {
    const current = queue.pop();
    let entries;
    try { entries = fs.readdirSync(current, {withFileTypes: true}); } catch { return true; }
    for (const entry of entries) {
      const item = path.join(current, entry.name);
      let stat;
      try { stat = fs.lstatSync(item); } catch { return true; }
      if (stat.isSymbolicLink()) return true;
      if (stat.isDirectory()) queue.push(item);
    }
  }
  return false;
};
const cleanupRetainedRuns = (now = Date.now()) => {
  const terminal = [];
  let entries;
  try { entries = fs.readdirSync(runsRoot, {withFileTypes: true}); } catch { return; }
  for (const entry of entries) {
    if (!entry.isDirectory() || !safeRunID(entry.name)) continue;
    const directory = runDirectory(entry.name);
    let rootStat;
    try { rootStat = fs.lstatSync(directory); } catch { continue; }
    if (!rootStat.isDirectory() || rootStat.isSymbolicLink() || treeContainsSymlink(directory)) continue;
    let state;
    try { state = readState(directory); } catch { continue; }
    if (!workerIDFromOwner(state.ownerID)) continue;
    const updatedAt = Date.parse(state.workspaceFinalizedAt ?? state.completedAt ?? state.stoppedAt ?? state.updatedAt ?? "");
    if (!Number.isFinite(updatedAt)) continue;
    const age = now - updatedAt;
    const isTerminal = ["completed", "failed", "stopped", "error"].includes(state.state);
    let launch;
    try { launch = readJSON(path.join(directory, "launch.json")); } catch {}
    // A filesystem workspace is retained until an explicit integrated or
    // abandoned disposition has been durably recorded. Journal retention must
    // never orphan-delete an unmarked run's only ownership evidence.
    const unmarkedWorkspace = validRepoID(launch?.workspace?.repoID) && validOID(launch?.workspace?.snapshotCommitOID) && !["integrated", "abandoned"].includes(state.workspaceDisposition);
    if (unmarkedWorkspace) continue;
    const definitelyDead = ["starting", "running"].includes(state.state)
      && Number.isSafeInteger(Number(state.pid))
      && typeof state.pidIdentity === "string"
      && !childAlive(Number(state.pid), state.pidIdentity);
    if ((isTerminal || definitelyDead) && age >= RUN_RETENTION_MS) {
      try { fs.rmSync(directory, {recursive: true}); } catch {}
      continue;
    }
    if (isTerminal && age >= TERMINAL_OVERFLOW_MIN_AGE_MS) terminal.push({directory, updatedAt});
  }
  terminal.sort((left, right) => right.updatedAt - left.updatedAt);
  for (const value of terminal.slice(MAX_RETAINED_TERMINAL_RUNS)) {
    try { fs.rmSync(value.directory, {recursive: true}); } catch {}
  }
};
const processIdentity = pid => {
  if (!Number.isSafeInteger(pid) || pid <= 1) return null;
  try {
    const stat = fs.readFileSync(`/proc/${pid}/stat`, "utf8");
    const close = stat.lastIndexOf(")");
    const fields = stat.slice(close + 2).split(" ");
    return fields[19] ? `linux-proc-start:${fields[19]}` : null;
  } catch {
    try {
      const started = execFileSync("/bin/ps", ["-o", "lstart=", "-p", String(pid)], {encoding: "utf8", timeout: 1000}).trim();
      return started ? `ps-lstart:${started}` : null;
    } catch { return null; }
  }
};
const childAlive = (pid, identity) => {
  if (!identity || processIdentity(pid) !== identity) return false;
  try { process.kill(pid, 0); return true; } catch { return false; }
};
const processGroupAlive = pid => {
  try { process.kill(-pid, 0); return true; }
  catch (error) {
    // Darwin reports EPERM when a newly terminated group contains only
    // unreaped zombies. Such a group has no signalable work left.
    if (["ESRCH", "EPERM"].includes(error.code)) return false;
    throw error;
  }
};
const signalProcessGroup = (pid, signal) => {
  try { process.kill(-pid, signal); }
  catch (error) { if (!["ESRCH", "EPERM"].includes(error.code)) throw error; }
};
const sleep = milliseconds => new Promise(resolve => setTimeout(resolve, milliseconds));
const observedState = directory => {
  const state = readState(directory);
  if (state.state === "starting" && state.credentialDelivery === "required" && Date.now() - Date.parse(state.updatedAt ?? 0) > 15000) {
    const message = "provider credentials were not delivered to the run monitor";
    appendEvent(directory, {kind: "error", text: message});
    setState(directory, "error", {error: message});
    return readState(directory);
  }
  if (state.state === "running" && !childAlive(state.pid, state.pidIdentity)) {
    const currentIdentity = processIdentity(state.pid);
    const pidWasReused = currentIdentity !== null && currentIdentity !== state.pidIdentity;
    // The detached monitor records the terminal event and state immediately
    // after the child close callback. Under scheduler pressure a probe can land
    // in that narrow interval; allow the authoritative monitor a bounded grace
    // period before declaring an orphaned child. A live process with a different
    // start identity is definite PID reuse and must fail closed immediately.
    const lastObserved = Date.parse(state.updatedAt ?? state.heartbeatAt ?? "");
    if (!pidWasReused && Number.isFinite(lastObserved) && Date.now() - lastObserved < 15000) return state;
    const message = "child process is no longer alive with its recorded start identity";
    setState(directory, "failed", {error: message, pid: state.pid, pidIdentity: state.pidIdentity});
    return readState(directory);
  }
  return state;
};
const commandAvailable = command => {
  if (command.includes("/")) return fs.existsSync(command);
  return (process.env.PATH ?? "/usr/local/bin:/usr/bin:/bin").split(path.delimiter).some(directory => fs.existsSync(path.join(directory, command)));
};
const healthyCommandAvailable = (command, arguments_) => {
  if (typeof command !== "string" || command.length === 0 || command.includes("/")) return false;
  const searchPath = process.env.PATH ?? "/usr/local/bin:/usr/bin:/bin";
  const executable = searchPath.split(path.delimiter).map(directory => path.join(directory || process.cwd(), command)).find(candidate => {
    try { fs.accessSync(candidate, fs.constants.X_OK); return fs.statSync(candidate).isFile(); } catch { return false; }
  });
  if (!executable) return false;
  try {
    execFileSync(executable, arguments_, {
      encoding: "utf8",
      timeout: 5000,
      maxBuffer: 4096,
      env: {HOME: os.homedir(), PATH: searchPath},
      stdio: ["ignore", "pipe", "pipe"]
    });
    return true;
  } catch { return false; }
};
const gitExecutable = ["/usr/bin/git", "/usr/local/bin/git", "/opt/homebrew/bin/git"].find(candidate => {
  try { fs.accessSync(candidate, fs.constants.X_OK); return fs.lstatSync(candidate).isFile(); } catch { return false; }
});
const gitEnvironment = () => ({HOME: os.homedir(), PATH: process.env.PATH ?? "/usr/local/bin:/usr/bin:/bin", LC_ALL: "C", GIT_TERMINAL_PROMPT: "0", GIT_CONFIG_NOSYSTEM: "1", GIT_CONFIG_GLOBAL: "/dev/null", GIT_OPTIONAL_LOCKS: "0", GIT_NO_LAZY_FETCH: "1"});
const validRepoID = value => typeof value === "string" && /^[0-9a-f]{64}$/.test(value);
const validOID = value => typeof value === "string" && /^(?:[0-9a-f]{40}|[0-9a-f]{64})$/.test(value);
const safeOwnedDirectory = (directory, parent) => {
  const normalized = path.resolve(directory);
  if (path.dirname(normalized) !== path.resolve(parent)) return false;
  try {
    const info = fs.lstatSync(normalized);
    const real = fs.realpathSync(normalized);
    const realParent = fs.realpathSync(parent);
    return info.isDirectory() && !info.isSymbolicLink() && info.uid === process.geteuid() && path.dirname(real) === realParent && path.basename(real) === path.basename(normalized);
  } catch { return false; }
};
const safeOwnedDescendantDirectory = (directory, parent) => {
  const normalized = path.resolve(directory);
  const normalizedParent = path.resolve(parent);
  const relative = path.relative(normalizedParent, normalized);
  const parts = relative.split(path.sep);
  if (!relative || path.isAbsolute(relative) || parts.some(part => !part || part === "." || part === "..")) return false;
  try {
    const realParent = fs.realpathSync(normalizedParent);
    let candidate = normalizedParent;
    for (const part of parts) {
      candidate = path.join(candidate, part);
      const info = fs.lstatSync(candidate);
      if (!info.isDirectory() || info.isSymbolicLink() || info.uid !== process.geteuid()) return false;
    }
    const real = fs.realpathSync(normalized);
    return real.startsWith(`${realParent}${path.sep}`);
  } catch { return false; }
};
const ensurePrivateOwnedDirectory = (directory, parent, normalizePermissions = true) => {
  if (!fs.existsSync(directory)) fs.mkdirSync(directory, {mode: 0o700});
  if (!safeOwnedDirectory(directory, parent)) throw new Error("unsafe managed skill directory");
  const mode = fs.lstatSync(directory).mode & 0o777;
  if (!normalizePermissions && (mode & 0o022) !== 0) throw new Error("writable managed skill ancestor");
  if (normalizePermissions) fs.chmodSync(directory, 0o700);
};
const ensureManagedSkillDirectories = () => {
  const home = os.homedir();
  const local = path.join(home, ".local");
  const lib = path.join(local, "lib");
  const workjet = path.join(lib, "workjet");
  // Existing shared ancestors such as ~/.local may legitimately be 0755.
  // Validate them, but never rewrite permissions outside Workjet's skill root.
  ensurePrivateOwnedDirectory(local, home, false);
  ensurePrivateOwnedDirectory(lib, local, false);
  ensurePrivateOwnedDirectory(workjet, lib, false);
  ensurePrivateOwnedDirectory(managedSkillsRoot, workjet);
  ensurePrivateOwnedDirectory(managedSkillsBin, managedSkillsRoot);
};

const executableAt = candidates => candidates.find(candidate => {
  try { fs.accessSync(candidate, fs.constants.X_OK); return true; } catch { return false; }
});
const harnessDefinitions = {
  "claude-code": {
    candidates: [path.join(managedNPMBin, "claude"), "/opt/homebrew/bin/claude", "/usr/local/bin/claude", path.join(os.homedir(), ".local/bin/claude"), path.join(os.homedir(), ".bun/bin/claude"), path.join(os.homedir(), ".local/share/pnpm/claude"), path.join(os.homedir(), ".npm-global/bin/claude")],
    versionArguments: ["--version"], package: "@anthropic-ai/claude-code", nativeUpdate: ["update"]
  },
  "codex-cli": {
    candidates: [path.join(managedNPMBin, "codex"), "/opt/homebrew/bin/codex", "/usr/local/bin/codex", path.join(os.homedir(), ".local/bin/codex"), path.join(os.homedir(), ".bun/bin/codex"), path.join(os.homedir(), ".local/share/pnpm/codex"), path.join(os.homedir(), ".npm-global/bin/codex")],
    versionArguments: ["--version"], package: "@openai/codex"
  },
  "opencode": {
    candidates: [path.join(managedNPMBin, "opencode"), path.join(os.homedir(), ".opencode/bin/opencode"), "/opt/homebrew/bin/opencode", "/usr/local/bin/opencode", path.join(os.homedir(), ".local/bin/opencode"), path.join(os.homedir(), ".bun/bin/opencode"), path.join(os.homedir(), ".local/share/pnpm/opencode"), path.join(os.homedir(), ".npm-global/bin/opencode")],
    versionArguments: ["--version"], package: "opencode-ai", nativeUpdate: ["upgrade"]
  },
  "cursor-agent": {
    candidates: ["/opt/homebrew/bin/cursor-agent", "/usr/local/bin/cursor-agent", path.join(os.homedir(), ".local/bin/cursor-agent"), path.join(os.homedir(), ".bun/bin/cursor-agent"), path.join(os.homedir(), ".local/share/pnpm/cursor-agent"), path.join(os.homedir(), ".npm-global/bin/cursor-agent")],
    versionArguments: ["--version"], inspectOnly: true
  },
  "grok-cli": {
    candidates: ["/opt/homebrew/bin/grok", "/usr/local/bin/grok", path.join(os.homedir(), ".local/bin/grok"), path.join(os.homedir(), ".bun/bin/grok"), path.join(os.homedir(), ".local/share/pnpm/grok"), path.join(os.homedir(), ".npm-global/bin/grok")],
    versionArguments: ["--version"], inspectOnly: true
  }
};
const boundedText = (value, limit = 4096) => String(value ?? "").slice(0, limit);
const runLifecycleCommand = (executable, arguments_, timeout = 60000, extraEnvironment = {}, outputLimit = 4096, maxBuffer = 65536) => {
  try {
    const basePath = process.env.PATH ?? "/usr/local/bin:/usr/bin:/bin";
    const runtimePath = `${managedSkillsBin}${path.delimiter}${managedNPMBin}${path.delimiter}${path.dirname(process.execPath)}${path.delimiter}${basePath}`;
    const output = execFileSync(executable, arguments_, {encoding: "utf8", timeout, maxBuffer, env: {HOME: os.homedir(), PATH: runtimePath, ...extraEnvironment}});
    return {ok: true, output: boundedText(output, outputLimit)};
  } catch (error) {
    return {ok: false, output: boundedText(`${error.stdout ?? ""}\n${error.stderr ?? ""}`.trim() || error.message, outputLimit)};
  }
};
const parsedVersion = text => String(text ?? "").match(/(?:^|[^0-9])v?(\d+\.\d+(?:\.\d+)?(?:[-+][0-9A-Za-z.-]+)?)/i)?.[1];
const inspectPiDeployment = action => {
  try {
    const manifestFile = path.join(release, "manifest.json");
    if (fs.statSync(manifestFile).size > 2100000) throw new Error("deployment manifest exceeds limit");
    const manifest = readJSON(manifestFile);
    if (manifest.schema !== 1 || typeof manifest.version !== "string" || !/^[0-9A-Za-z._-]{1,64}$/.test(manifest.version) || typeof manifest.contentHash !== "string" || !/^[0-9a-f]{64}$/.test(manifest.contentHash)) throw new Error("invalid content-addressed deployment manifest");
    if (path.basename(release) !== manifest.contentHash) throw new Error("active release does not match its content hash");
    for (const name of ["ctox-pi-sidecar.mjs", "workjet-pi-turn.mjs", "workjet-host.mjs", "workjet-node"]) if (!fs.existsSync(path.join(release, name))) throw new Error(`deployment file missing: ${name}`);
    return {harnessID: "pi-code", action, state: "installed", version: manifest.version, detail: "Pi Code ist eingerichtet und bereit."};
  } catch (error) {
    return {harnessID: "pi-code", action, state: "broken", detail: "Pi Code muss auf diesem Computer erneut eingerichtet werden."};
  }
};
const inspectHarness = (harnessID, action = "inspect") => {
  if (harnessID === "pi-code") return inspectPiDeployment(action);
  const definition = harnessDefinitions[harnessID];
  if (!definition) return null;
  const executable = executableAt(definition.candidates);
  if (!executable) return {harnessID, action, state: "missing"};
  const result = runLifecycleCommand(executable, definition.versionArguments);
  if (!result.ok) return {harnessID, action, state: "broken", detail: "Die Installation konnte nicht geprüft werden."};
  return {harnessID, action, state: "installed", version: parsedVersion(result.output), detail: "Installiert und bereit."};
};
const packageManagers = [
  {channel: "npm", candidates: [path.join(path.dirname(process.execPath), "npm"), "/opt/homebrew/bin/npm", "/usr/local/bin/npm", "/usr/bin/npm"], install: package_ => ["install", "--global", "--prefix", managedNPMRoot, `${package_}@latest`], update: package_ => ["install", "--global", "--prefix", managedNPMRoot, `${package_}@latest`], remove: package_ => ["uninstall", "--global", "--prefix", managedNPMRoot, package_]},
  {channel: "bun", candidates: [path.join(os.homedir(), ".bun/bin/bun")], install: package_ => ["install", "-g", `${package_}@latest`], update: package_ => ["install", "-g", `${package_}@latest`], remove: package_ => ["remove", "-g", package_]},
  {channel: "pnpm", candidates: [path.join(os.homedir(), ".local/share/pnpm/pnpm"), "/opt/homebrew/bin/pnpm", "/usr/local/bin/pnpm"], install: package_ => ["add", "-g", `${package_}@latest`], update: package_ => ["add", "-g", `${package_}@latest`], remove: package_ => ["remove", "-g", package_]},
  {channel: "vite-plus", candidates: [path.join(os.homedir(), ".vite-plus/bin/vp")], install: package_ => ["install", "-g", package_], update: package_ => ["install", "-g", package_], remove: package_ => ["remove", "-g", package_]},
  {channel: "homebrew", candidates: ["/opt/homebrew/bin/brew", "/usr/local/bin/brew"], install: package_ => ["install", package_ === "@anthropic-ai/claude-code" ? "claude-code" : package_ === "@openai/codex" ? "codex" : "anomalyco/tap/opencode"], update: package_ => ["upgrade", package_ === "@anthropic-ai/claude-code" ? "claude-code" : package_ === "@openai/codex" ? "codex" : "anomalyco/tap/opencode"], remove: package_ => ["uninstall", package_ === "@anthropic-ai/claude-code" ? "claude-code" : package_ === "@openai/codex" ? "codex" : "anomalyco/tap/opencode"]}
];
const packageManagerForBinary = executable => {
  if (executable.startsWith(`${managedNPMRoot}${path.sep}`)) return packageManagers.find(value => value.channel === "npm");
  if (executable.includes("/.bun/bin/")) return packageManagers.find(value => value.channel === "bun");
  if (executable.includes("/.local/share/pnpm/") || executable.includes("/pnpm/global/")) return packageManagers.find(value => value.channel === "pnpm");
  if (executable.includes("/.vite-plus/bin/")) return packageManagers.find(value => value.channel === "vite-plus");
  if (executable.includes("/.npm-global/bin/") || executable.includes("/node_modules/.bin/") || executable.includes("/lib/node_modules/")) return packageManagers.find(value => value.channel === "npm");
  if (executable.startsWith("/opt/homebrew/bin/") || executable.startsWith("/usr/local/bin/")) return packageManagers.find(value => value.channel === "homebrew");
  return null;
};
const maintainHarness = (harnessID, action) => {
  if (harnessID === "pi-code") {
    if (action === "inspect") return inspectPiDeployment(action);
    return {harnessID, action, state: "unavailable", detail: "Pi Code wird beim Einrichten des Computers von Workjet verwaltet."};
  }
  const definition = harnessDefinitions[harnessID];
  if (!definition) return null;
  if (action === "inspect") return inspectHarness(harnessID, action);
  if (definition.inspectOnly) return {harnessID, action, state: "unavailable", detail: "Diese Installation kann hier nur geprüft werden."};
  const before = inspectHarness(harnessID, action);
  let executable;
  let arguments_;
  if (action === "install") {
    if (before.state === "broken") return before;
    if (before.state !== "missing") return {harnessID, action, state: "unavailable", version: before.version, detail: "Bereits installiert."};
    const available = packageManagers.map(manager => ({manager, executable: executableAt(manager.candidates)})).filter(value => value.executable);
    if (available.length !== 1) return {harnessID, action, state: "unavailable", detail: available.length === 0 ? "Die automatische Installation ist auf diesem Computer nicht verfügbar." : "Wähle zuerst eine eindeutige vorhandene Installation aus."};
    executable = available[0].executable;
    if (available[0].manager.channel === "npm") {
      for (const directory of [harnessesRoot, managedNPMRoot]) {
        fs.mkdirSync(directory, {recursive: true, mode: 0o700});
        const info = fs.lstatSync(directory);
        if (!info.isDirectory() || info.isSymbolicLink() || info.uid !== process.geteuid()) return {harnessID, action, state: "unavailable", detail: "Der verwaltete Installationsordner ist nicht sicher."};
        fs.chmodSync(directory, 0o700);
      }
    }
    arguments_ = available[0].manager.install(definition.package);
  } else {
    if (before.state !== "installed") return {harnessID, action, state: before.state, version: before.version, detail: before.detail};
    const installed = executableAt(definition.candidates);
    const native = harnessID === "claude-code" && installed === path.join(os.homedir(), ".local/bin/claude") || harnessID === "opencode" && installed === path.join(os.homedir(), ".opencode/bin/opencode");
    if (native) {
      if (action !== "update" || !definition.nativeUpdate) return {harnessID, action, state: "unavailable", version: before.version, detail: "Diese Aktion ist für die vorhandene Installation nicht verfügbar."};
      executable = installed;
      arguments_ = definition.nativeUpdate;
    } else {
      const manager = packageManagerForBinary(installed);
      const managerExecutable = manager && executableAt(manager.candidates);
      if (!manager || !managerExecutable) return {harnessID, action, state: "unavailable", version: before.version, detail: "Diese Installation kann nicht automatisch verwaltet werden."};
      executable = managerExecutable;
      arguments_ = action === "update" ? manager.update(definition.package) : manager.remove(definition.package);
    }
  }
  const mutation = runLifecycleCommand(executable, arguments_, 300000);
  if (!mutation.ok) return {harnessID, action, state: "broken", version: before.version, detail: "Die Aktion ist fehlgeschlagen. Prüfe die Installation und versuche es erneut."};
  const after = inspectHarness(harnessID, action);
  if (action === "remove" && after.state === "missing") return {harnessID, action, state: "missing"};
  if (after.state !== "installed") return {harnessID, action, state: "broken", version: after.version, detail: after.detail || "Die Installation konnte nach der Aktion nicht bestätigt werden."};
  return after;
};

const managedSkillDefinitions = {
  greppy: {
    version: GREPPY_VERSION,
    commit: GREPPY_COMMIT,
    sourceURL: GREPPY_SOURCE_URL,
    sourceSHA256: GREPPY_SOURCE_SHA256,
    executable: path.join(managedSkillsBin, "greppy"),
    versionArguments: ["--version"]
  }
};
const verifyManagedGreppyRuntime = (definition, executable) => {
  const executableInfo = fs.lstatSync(executable);
  const stampFile = path.join(managedSkillsRoot, "greppy-runtime-probe.json");
  try {
    const stampInfo = fs.lstatSync(stampFile);
    if (!stampInfo.isFile() || stampInfo.isSymbolicLink() || stampInfo.uid !== process.geteuid() || stampInfo.size > 4096) throw new Error("unsafe stamp");
    const stamp = readJSON(stampFile);
    if (stamp.schema === 1 && stamp.version === definition.version && stamp.binarySize === executableInfo.size && stamp.binaryMtimeMs === executableInfo.mtimeMs && stamp.runtimeReady === true) return true;
  } catch {}

  const probeRoot = path.join(managedSkillsRoot, "greppy-runtime-probe");
  try {
    if (fs.existsSync(probeRoot)) {
      if (!safeOwnedDirectory(probeRoot, managedSkillsRoot)) return false;
      fs.rmSync(probeRoot, {recursive: true, force: true});
    }
    const repository = path.join(probeRoot, "repository");
    const store = path.join(probeRoot, "store");
    fs.mkdirSync(repository, {recursive: true, mode: 0o700});
    fs.mkdirSync(store, {recursive: true, mode: 0o700});
    fs.writeFileSync(path.join(repository, "runtime_probe.rs"), "pub fn workjet_runtime_probe() -> bool { true }\n", {mode: 0o600});
    const indexed = runLifecycleCommand(executable, ["index", repository], 120000, {GREPPY_STORE_DIR: store}, 4096, 65536);
    if (!indexed.ok) return false;
    atomicJSON(stampFile, {schema: 1, version: definition.version, binarySize: executableInfo.size, binaryMtimeMs: executableInfo.mtimeMs, runtimeReady: true});
    return true;
  } catch {
    return false;
  }
};
const inspectManagedSkill = (skillID, action = "inspect") => {
  const definition = managedSkillDefinitions[skillID];
  if (!definition) return null;
  if (process.platform !== "linux" || process.arch !== "x64") {
    return {skillID, action, state: "unavailable", detail: "Greppy wird automatisch nur auf Linux x86_64 unterstützt."};
  }
  const executable = definition.executable;
  if (!fs.existsSync(executable)) return {skillID, action, state: "missing", detail: "Nicht installiert."};
  try {
    const info = fs.lstatSync(executable);
    if (!info.isFile() || info.isSymbolicLink() || info.uid !== process.geteuid()) throw new Error("unsafe executable");
    fs.accessSync(executable, fs.constants.X_OK);
  } catch {
    return {skillID, action, state: "broken", detail: "Die verwaltete Greppy-Datei ist nicht sicher oder nicht ausführbar."};
  }
  const result = runLifecycleCommand(executable, definition.versionArguments, 10000);
  const version = parsedVersion(result.output);
  if (!result.ok || version !== definition.version) {
    return {skillID, action, state: "broken", version, detail: `Erwartet wird Greppy ${definition.version}; die verwaltete Installation konnte nicht bestätigt werden.`};
  }
  // Greppy's real 0.3.1 help is larger than the generic 4 KiB lifecycle
  // preview. Inspect the complete bounded command surface; otherwise required
  // subcommands near the end are truncated and a healthy remote install is
  // reported as broken.
  const surface = runLifecycleCommand(executable, ["--help"], 10000, {}, 65536, 131072);
  if (!surface.ok || !["who-calls", "search-symbol", "bash-smart"].every(command => surface.output.includes(command))) {
    return {skillID, action, state: "broken", version, detail: `Greppy ${definition.version} meldet nicht die erwartete 0.3.1-Befehlsoberfläche.`};
  }
  if (!verifyManagedGreppyRuntime(definition, executable)) {
    return {skillID, action, state: "broken", version, detail: `Greppy ${definition.version} kann seinen eingebetteten Modell- und Index-Runtimepfad nicht ausführen.`};
  }
  return {skillID, action, state: "installed", version, detail: `Greppy ${version} ist verwaltet installiert und bereit.`};
};
const installManagedSkill = (skillID, action) => {
  const definition = managedSkillDefinitions[skillID];
  if (!definition) return null;
  if (process.platform !== "linux" || process.arch !== "x64") return inspectManagedSkill(skillID, action);
  const before = inspectManagedSkill(skillID, action);
  if (before.state === "installed") return before;
  // A safe, regular managed binary with the wrong pinned version must be
  // replaceable; otherwise upgrades are permanently blocked by inspection.
  const curl = executableAt(["/usr/bin/curl"]);
  const tar = executableAt(["/usr/bin/tar"]);
  if (!curl || !tar) return {skillID, action, state: "unavailable", detail: "Für die sichere Greppy-Installation fehlen /usr/bin/curl oder /usr/bin/tar."};
  let temporary;
  var phase = "Vorbereitung";
  try {
    ensureManagedSkillDirectories();
    temporary = fs.mkdtempSync(path.join(managedSkillsRoot, ".greppy-install-"));
    if (!safeOwnedDirectory(temporary, managedSkillsRoot)) throw new Error("unsafe temporary directory");
    const archive = path.join(temporary, "greppy-source.tar.gz");
    const sourceRoot = path.join(temporary, "source");
    fs.mkdirSync(sourceRoot, {mode: 0o700});
    if (!safeOwnedDirectory(sourceRoot, temporary)) throw new Error("unsafe source directory");
    phase = "Download";
    const download = runLifecycleCommand(curl, ["--disable", "--fail", "--location", "--proto", "=https", "--tlsv1.2", "--max-time", "120", "--max-filesize", "33554432", "--output", archive, definition.sourceURL], 130000);
    if (!download.ok) throw new Error("download failed");
    const archiveInfo = fs.lstatSync(archive);
    if (!archiveInfo.isFile() || archiveInfo.isSymbolicLink() || archiveInfo.uid !== process.geteuid() || archiveInfo.size < 1 || archiveInfo.size > 33554432) throw new Error("download invalid");
    const digest = crypto.createHash("sha256").update(fs.readFileSync(archive)).digest("hex");
    if (digest !== definition.sourceSHA256) throw new Error("digest mismatch");
    phase = "Archivprüfung";
    const listing = runLifecycleCommand(tar, ["-tzf", archive], 10000, {}, 1048576, 1048576);
    const archivePrefix = `greppy-${definition.commit}/`;
    const archiveEntries = listing.output.split(/\r?\n/).filter(Boolean);
    if (!listing.ok || archiveEntries.length === 0 || archiveEntries.some(entry => !entry.startsWith(archivePrefix) || entry.includes("\\") || entry.split("/").includes(".."))) throw new Error("archive layout invalid");
    const extraction = runLifecycleCommand(tar, ["-xzf", archive, "--strip-components=1", "--no-same-owner", "--no-same-permissions", "-C", sourceRoot], 30000);
    if (!extraction.ok || treeContainsSymlink(sourceRoot)) throw new Error("extraction failed");
    for (const required of ["Cargo.toml", "Cargo.lock", "crates/cli"]) if (!fs.existsSync(path.join(sourceRoot, required))) throw new Error("source contents invalid");
    const cargo = executableAt([path.join(os.homedir(), ".cargo/bin/cargo"), "/usr/bin/cargo"]);
    if (!cargo) throw new Error("cargo unavailable");
    const assetManifestPath = path.join(sourceRoot, "crates/cli/assets/MODEL_ASSETS.json");
    const sha256sum = executableAt(["/usr/bin/sha256sum"]);
    if (!sha256sum || !fs.existsSync(assetManifestPath)) throw new Error("model asset tooling unavailable");
    phase = "Modell-Assets";
    const assetManifest = JSON.parse(fs.readFileSync(assetManifestPath, "utf8"));
    const assetHost = typeof assetManifest.hf_host === "string" ? assetManifest.hf_host : "https://huggingface.co";
    if (assetHost !== "https://huggingface.co" || !Array.isArray(assetManifest.assets) || assetManifest.assets.length < 1 || assetManifest.assets.length > 8) throw new Error("model asset manifest invalid");
    for (const asset of assetManifest.assets) {
      const revision = asset.revision || assetManifest.revision;
      if (typeof asset.hf_repo !== "string" || !/^[A-Za-z0-9._-]+\/[A-Za-z0-9._-]+$/.test(asset.hf_repo)
          || typeof asset.hf_file !== "string" || !/^[A-Za-z0-9._-]+$/.test(asset.hf_file)
          || typeof revision !== "string" || !/^[0-9a-f]{40}$/.test(revision)
          || typeof asset.dest !== "string" || asset.dest.startsWith("/") || asset.dest.split("/").includes("..")
          || typeof asset.sha256 !== "string" || !/^[0-9a-f]{64}$/.test(asset.sha256)) throw new Error("model asset manifest invalid");
      const destination = path.resolve(sourceRoot, asset.dest);
      if (!destination.startsWith(sourceRoot + path.sep)) throw new Error("model asset path invalid");
      fs.mkdirSync(path.dirname(destination), {recursive: true, mode: 0o700});
      const assetURL = `${assetHost}/${asset.hf_repo}/resolve/${revision}/${asset.hf_file}`;
      const fetched = runLifecycleCommand(curl, ["--disable", "--fail", "--location", "--proto", "=https", "--tlsv1.2", "--max-time", "600", "--max-filesize", "2147483648", "--output", destination, assetURL], 610000);
      if (!fetched.ok) throw new Error("model asset download failed");
      const assetInfo = fs.lstatSync(destination);
      if (!assetInfo.isFile() || assetInfo.isSymbolicLink() || assetInfo.uid !== process.geteuid() || assetInfo.size < 1 || assetInfo.size > 2147483648) throw new Error("model asset download invalid");
      const assetDigest = runLifecycleCommand(sha256sum, [destination], 120000, {}, 4096, 4096);
      if (!assetDigest.ok || assetDigest.output.trim().split(/\s+/)[0] !== asset.sha256) throw new Error("model asset digest mismatch");
    }
    const cargoTarget = path.join(temporary, "cargo-target");
    const cargoHome = path.join(temporary, "cargo-home");
    fs.mkdirSync(cargoTarget, {mode: 0o700});
    fs.mkdirSync(cargoHome, {mode: 0o700});
    if (!safeOwnedDirectory(cargoTarget, temporary) || !safeOwnedDirectory(cargoHome, temporary)) throw new Error("unsafe cargo directory");
    phase = "Rust-Build";
    const compiled = runLifecycleCommand(
      cargo,
      // Cargo's normal progress stream can exceed execFileSync's bounded
      // capture buffer on a clean host and abort an otherwise healthy build.
      // Quiet mode keeps failures visible while making the managed install
      // independent of dependency count and terminal verbosity.
      ["build", "--quiet", "--manifest-path", path.join(sourceRoot, "Cargo.toml"), "--release", "--locked", "--target-dir", cargoTarget, "--bin", "greppy"],
      // A clean Linux CUDA build embeds both model payloads and compiles the
      // native kernels. On a busy worker this legitimately takes longer than
      // 15 minutes; timing it out discards a healthy build just before link.
      3600000,
      {
        CARGO_HOME: cargoHome,
        PATH: `${path.dirname(cargo)}${path.delimiter}${process.env.PATH ?? "/usr/local/bin:/usr/bin:/bin"}`
      }
    );
    if (!compiled.ok) throw new Error("cargo build failed");
    const source = path.join(cargoTarget, "release", "greppy");
    const sourceInfo = fs.lstatSync(source);
    if (!sourceInfo.isFile() || sourceInfo.isSymbolicLink() || sourceInfo.uid !== process.geteuid()) throw new Error("compiled executable invalid");
    fs.chmodSync(source, 0o700);
    const verification = runLifecycleCommand(source, definition.versionArguments, 5000);
    if (!verification.ok || parsedVersion(verification.output) !== definition.version) throw new Error("compiled version verification failed");
    phase = "Aktivierung";
    const staged = path.join(managedSkillsBin, `.greppy-${process.pid}-${Date.now()}`);
    fs.copyFileSync(source, staged, fs.constants.COPYFILE_EXCL);
    fs.chmodSync(staged, 0o700);
    const destination = definition.executable;
    if (fs.existsSync(destination)) {
      const existing = fs.lstatSync(destination);
      if (!existing.isFile() || existing.isSymbolicLink() || existing.uid !== process.geteuid()) throw new Error("unsafe destination");
    }
    fs.renameSync(staged, destination);
  } catch (error) {
    if (temporary) try { fs.rmSync(temporary, {recursive: true, force: true}); } catch {}
    const reason = error.message === "digest mismatch"
      ? "Der Greppy-Download hat nicht die erwartete SHA-256-Prüfsumme. Es wurde nichts aktiviert."
      : error.message === "cargo unavailable"
        ? "Greppy 0.3.1 muss auf Linux aus dem gepinnten Quellstand gebaut werden; eine Rustup-Cargo-Toolchain wurde nicht gefunden."
        : `Greppy 0.3.1 konnte in der Phase „${phase}“ nicht sicher installiert werden. Die bisherige Installation blieb unverändert.`;
    return {skillID, action, state: "broken", detail: reason};
  }
  if (temporary) try { fs.rmSync(temporary, {recursive: true, force: true}); } catch {}
  return inspectManagedSkill(skillID, action);
};
const maintainManagedSkill = (skillID, action) => action === "inspect"
  ? inspectManagedSkill(skillID, action)
  : installManagedSkill(skillID, action);

const resolveLaunch = launch => {
  if (!launch || typeof launch.inputBase64 !== "string" || launch.inputBase64.length > 1500000) throw new Error("invalid launch payload");
  const needsWorkspace = ["claude-code", "codex-cli", "opencode"].includes(launch.harnessID);
  const healthPrompt = "WORKJET HEALTH PROBE V1. This is a real user health ping: hi. Do not inspect or edit files. Do not use tools. Do not spawn subagents. Reply exactly WORKJET_HEALTH_OK and exit.";
  const healthProbe = launch.healthProbe === true;
  const webResearch = launch.webResearch === true;
  const greppy = launch.greppy === true;
  if (webResearch && !["claude-code", "codex-cli"].includes(launch.harnessID)) throw new Error("web research is unavailable for this harness");
  if (webResearch && healthProbe) throw new Error("health probes cannot enable web research");
  if (webResearch && !executableAt(harnessDefinitions["codex-cli"].candidates)) throw new Error("Web Research benötigt Codex CLI auf diesem Computer");
  if (greppy && !executableAt([managedSkillDefinitions.greppy.executable])) throw new Error("Greppy 0.3.1 ist auf diesem Computer nicht verwaltet installiert");
  if (healthProbe && (!needsWorkspace || launch.workspace != null || Buffer.from(launch.inputBase64, "base64").toString("utf8").trim() !== healthPrompt)) throw new Error("invalid health probe");
  if (needsWorkspace && !healthProbe && (!validRepoID(launch.workspace?.repoID) || !validOID(launch.workspace?.snapshotCommitOID))) throw new Error("workspace_required");
  if (launch.harnessID === "pi-code" && launch.workspace != null) throw new Error("pi-code does not accept a filesystem workspace");
  const input = Buffer.from(launch.inputBase64, "base64");
  if (input.length === 0 || input.length > 1048576) throw new Error("invalid launch input size");
  let systemPrompt = null;
  if (launch.systemPromptBase64 != null) {
    if (launch.harnessID !== "claude-code" || healthProbe || typeof launch.systemPromptBase64 !== "string" || !/^[A-Za-z0-9+/]*={0,2}$/.test(launch.systemPromptBase64)) throw new Error("invalid system prompt target");
    const decoded = Buffer.from(launch.systemPromptBase64, "base64");
    const canonical = decoded.toString("base64");
    if (decoded.length === 0 || decoded.length > 65536 || canonical !== launch.systemPromptBase64 || decoded.includes(0)) throw new Error("invalid system prompt");
    systemPrompt = decoded.toString("utf8");
    if (!Buffer.from(systemPrompt, "utf8").equals(decoded)) throw new Error("invalid system prompt encoding");
  }
  if (launch.sandbox === true && launch.harnessID !== "pi-code") throw new Error("sandbox is unavailable for this harness");
  if (launch.harnessID === "pi-code") {
    const text = input.toString("utf8");
    if (text.split(/\r?\n/).filter(Boolean).length !== 1) throw new Error("pi-code requires one NDJSON request");
    JSON.parse(text);
    return {command: process.execPath, arguments: [path.join(release, "workjet-pi-turn.mjs"), ...(launch.sandbox ? ["--sandbox"] : [])], input};
  }
  if (launch.harnessID === "claude-code") {
    if (typeof launch.model !== "string" || !/^[A-Za-z0-9._:[\]-]{1,128}$/.test(launch.model)) throw new Error("invalid model");
    if (!Array.isArray(launch.allowedTools) || launch.allowedTools.length === 0 || launch.allowedTools.length > 32 || launch.allowedTools.some(tool => typeof tool !== "string" || !/^[A-Za-z][A-Za-z0-9_-]{0,63}$/.test(tool))) throw new Error("invalid allowed tools");
    if (systemPrompt != null && !launch.allowedTools.includes("Bash")) throw new Error("system prompt requires Bash tool");
    if (webResearch && !launch.allowedTools.includes("Bash")) throw new Error("web research requires Bash tool");
    const brief = input.toString("utf8").trim();
    if (!brief) throw new Error("empty claude-code brief");
    const arguments_ = ["--bare", "--model", launch.model];
    if (typeof launch.reasoning === "string" && ["low", "medium", "high", "xhigh", "max", "ultra"].includes(launch.reasoning)) arguments_.push("--effort", launch.reasoning);
    arguments_.push("--allowedTools", launch.allowedTools.join(","));
    if (systemPrompt != null) arguments_.push("--append-system-prompt", systemPrompt);
    arguments_.push("-p", brief);
    const executable = executableAt(harnessDefinitions["claude-code"].candidates);
    if (!executable) throw new Error("Claude Code ist auf diesem Computer nicht installiert");
    return {command: executable, arguments: arguments_, input: Buffer.alloc(0)};
  }
  if (launch.harnessID === "codex-cli") {
    if (typeof launch.model !== "string" || !/^[A-Za-z0-9._:[\]-]{1,128}$/.test(launch.model)) throw new Error("invalid model");
    const brief = input.toString("utf8").trim();
    if (!brief) throw new Error("empty codex-cli brief");
    const executable = executableAt(harnessDefinitions["codex-cli"].candidates);
    if (!executable) throw new Error("Codex CLI ist auf diesem Computer nicht installiert");
    const arguments_ = [...(webResearch ? ["--search"] : []), "exec", "--json", "--model", launch.model];
    if (typeof launch.reasoning === "string" && ["low", "medium", "high", "xhigh"].includes(launch.reasoning)) {
      arguments_.push("-c", `model_reasoning_effort=${JSON.stringify(launch.reasoning)}`);
    }
    arguments_.push("-");
    return {command: executable, arguments: arguments_, input: Buffer.from(brief + "\n")};
  }
  if (launch.harnessID === "opencode") {
    if (typeof launch.model !== "string" || !/^[A-Za-z0-9._:/[\]-]{1,192}$/.test(launch.model)) throw new Error("invalid model");
    const brief = input.toString("utf8").trim();
    if (!brief || Buffer.byteLength(brief) > 32768) throw new Error("invalid opencode brief");
    const executable = executableAt(harnessDefinitions.opencode.candidates);
    if (!executable) throw new Error("OpenCode ist auf diesem Computer nicht installiert");
    const arguments_ = ["run", "--format", "json", "--model", launch.model];
    if (typeof launch.reasoning === "string" && ["low", "medium", "high", "xhigh", "max", "ultra"].includes(launch.reasoning)) arguments_.push("--variant", launch.reasoning);
    arguments_.push(brief);
    return {command: executable, arguments: arguments_, input: Buffer.alloc(0)};
  }
  throw new Error("unsupported harness");
};

const validateProviderExecution = value => {
  if (!value || typeof value.displayName !== "string" || value.displayName.length < 1 || value.displayName.length > 256 || !Array.isArray(value.candidates) || value.candidates.length < 1 || value.candidates.length > 8) throw new Error("invalid provider route");
  const candidates = value.candidates.map(candidate => {
    if (!candidate || !["directAccount", "gatewayPool"].includes(candidate.kind) || typeof candidate.displayName !== "string" || candidate.displayName.length < 1 || candidate.displayName.length > 256) throw new Error("invalid provider candidate");
    let endpoint;
    try { endpoint = new URL(candidate.endpoint); } catch { throw new Error("invalid provider endpoint"); }
    if (!["http:", "https:"].includes(endpoint.protocol) || endpoint.username || endpoint.password) throw new Error("invalid provider endpoint");
    if (!["Ohne Zugang", "Bearer-Token", "API-Key (x-api-key)"].includes(candidate.authentication)) throw new Error("invalid provider authentication");
    if (candidate.kind === "directAccount" && (typeof candidate.providerID !== "string" || !/^[0-9a-fA-F-]{36}$/.test(candidate.providerID))) throw new Error("direct provider identity missing");
    if (candidate.kind === "gatewayPool" && candidate.providerID != null) throw new Error("gateway pools cannot pin an account");
    if (candidate.kind === "directAccount" && candidate.relay != null) throw new Error("direct providers cannot use a gateway relay");
    if (candidate.kind === "gatewayPool") {
      if (!candidate.relay || typeof candidate.relay.id !== "string" || !/^[0-9a-fA-F-]{36}$/.test(candidate.relay.id) || !Number.isSafeInteger(candidate.relay.remotePort) || candidate.relay.remotePort < 1 || candidate.relay.remotePort > 65535) throw new Error("gateway relay identity missing");
      if (endpoint.protocol !== "http:" || endpoint.hostname !== "127.0.0.1" || Number(endpoint.port) !== candidate.relay.remotePort) throw new Error("gateway relay must use its allocated loopback port");
    }
    if (candidate.authentication === "Ohne Zugang" && candidate.secret != null) throw new Error("unexpected provider secret");
    if (candidate.authentication !== "Ohne Zugang" && (typeof candidate.secret !== "string" || candidate.secret.length < 1 || Buffer.byteLength(candidate.secret) > 65536)) throw new Error("provider credential missing");
    return {...candidate, endpoint: endpoint.toString()};
  });
  return {displayName: value.displayName, candidates};
};
const providerMetadata = route => ({displayName: route.displayName, candidates: route.candidates.map(({secret, ...candidate}) => candidate)});
const providerEnvironment = (harnessID, launch, candidate, secret) => {
  const source = process.env;
  const basePath = source.PATH ?? "/usr/local/bin:/usr/bin:/bin";
  const environment = {HOME: source.HOME ?? os.homedir(), PATH: `${managedSkillsBin}${path.delimiter}${managedNPMBin}${path.delimiter}${path.dirname(process.execPath)}${path.delimiter}${basePath}`};
  for (const key of ["LANG", "LC_ALL", "LC_CTYPE", "TMPDIR"]) if (typeof source[key] === "string") environment[key] = source[key];
  environment.WORKJET_MODEL = launch.model;
  environment.WORKJET_REASONING = typeof launch.reasoning === "string" ? launch.reasoning : "automatic";
  environment.WORKJET_SPEED = launch.options?.fastMode === "true" ? "fast" : "normal";
  environment.WORKJET_PROVIDER_ROUTE = candidate.displayName;
  environment.WORKJET_PROVIDER_ENDPOINT = candidate.endpoint;
  environment.WORKJET_PROVIDER_AUTHENTICATION = candidate.authentication;
  if (["claude-code", "pi-code", "cursor-agent"].includes(harnessID)) {
    environment.ANTHROPIC_BASE_URL = candidate.endpoint;
    if (candidate.authentication === "API-Key (x-api-key)") environment.ANTHROPIC_API_KEY = secret;
    else if (candidate.authentication === "Bearer-Token") environment.ANTHROPIC_AUTH_TOKEN = secret;
  } else if (["codex-cli", "opencode"].includes(harnessID)) {
    environment.OPENAI_BASE_URL = candidate.endpoint;
    if (candidate.authentication !== "Ohne Zugang") environment.OPENAI_API_KEY = secret;
  } else if (harnessID === "grok-cli") {
    environment.XAI_BASE_URL = candidate.endpoint;
    if (candidate.authentication !== "Ohne Zugang") environment.XAI_API_KEY = secret;
  }
  if (launch.webResearch === true) {
    if (candidate.kind !== "gatewayPool") throw new Error("Web Research benötigt auf diesem Computer eine Workjet-Gateway-Route");
    environment.WORKJET_WEB_RESEARCH_BASE_URL = webResearchBaseURL(candidate.endpoint);
    if (candidate.authentication !== "Ohne Zugang") environment.WORKJET_WEB_RESEARCH_API_KEY = secret;
    environment.WORKJET_WEB_RESEARCH_BACKEND = "codex";
  }
  if (launch.greppy === true) environment.GREPPY_STORE_DIR = path.join(stateRoot, "greppy");
  return environment;
};
const webResearchBaseURL = raw => {
  const value = new URL(raw);
  if (value.pathname === "" || value.pathname === "/") value.pathname = "/v1";
  return value.toString();
};
const workjetCodexProviderArguments = endpoint => [
  "-c", `model_provider="workjet"`,
  "-c", `model_providers.workjet.name="Workjet Web Research"`,
  "-c", `model_providers.workjet.base_url=${JSON.stringify(webResearchBaseURL(endpoint))}`,
  "-c", `model_providers.workjet.env_key="WORKJET_WEB_RESEARCH_API_KEY"`,
  "-c", `model_providers.workjet.wire_api="responses"`,
  "-c", "model_providers.workjet.requires_openai_auth=false",
  "-c", "model_providers.workjet.supports_websockets=false",
  "-c", "model_providers.workjet.supports_standalone_web_search=true",
];
const providerArguments = (resolved, launch, candidate) => {
  const arguments_ = [...resolved.arguments];
  if (launch.harnessID !== "codex-cli" || launch.webResearch !== true || candidate.kind !== "gatewayPool") return arguments_;
  const execIndex = arguments_.indexOf("exec");
  if (execIndex < 0) throw new Error("Codex CLI Web Research benötigt den exec-Aufruf");
  arguments_.splice(execIndex, 0, ...workjetCodexProviderArguments(candidate.endpoint));
  return arguments_;
};
const retryableProviderFailure = diagnostic => ["401", "403", "429", "unauthorized", "authentication", "invalid api key", "api key", "token expired", "rate limit", "rate-limit", "quota"].some(marker => diagnostic.toLowerCase().includes(marker));
const redactSecrets = (value, secrets) => secrets.reduce((text, secret) => secret ? text.split(secret).join("[REDACTED]") : text, String(value ?? ""));
const redactingRecorder = (kind, secrets, accept) => {
  let pending = "";
  const longest = Math.max(1, ...secrets.map(secret => secret.length));
  const emit = value => {
    const text = redactSecrets(value, secrets);
    if (text) accept(text);
  };
  return {
    push(chunk) {
      pending += chunk.toString("utf8");
      let cutoff = Math.max(0, pending.length - longest + 1);
      let changed = true;
      while (changed && cutoff > 0) {
        changed = false;
        for (const secret of secrets) {
          const start = pending.lastIndexOf(secret, cutoff - 1);
          if (start >= 0 && start < cutoff && start + secret.length > cutoff) {
            cutoff = start;
            changed = true;
          }
        }
      }
      if (cutoff > 0) {
        emit(pending.slice(0, cutoff));
        pending = pending.slice(cutoff);
      }
    },
    flush() { emit(pending); pending = ""; }
  };
};
const readEphemeralProviderExecution = async () => {
  let data = Buffer.alloc(0);
  for await (const chunk of process.stdin) {
    data = Buffer.concat([data, chunk]);
    if (data.length > 600000) throw new Error("provider credential delivery is too large");
  }
  if (!data.length) throw new Error("provider credentials were not delivered");
  return validateProviderExecution(JSON.parse(data.toString("utf8")));
};

const monitor = async runID => {
  if (!safeRunID(runID)) process.exit(64);
  const directory = runDirectory(runID);
  const launch = readJSON(path.join(directory, "launch.json"));
  let providerExecution;
  try {
    providerExecution = await readEphemeralProviderExecution();
    if (JSON.stringify(providerMetadata(providerExecution)) !== JSON.stringify(launch.providerRoute)) throw new Error("provider credential delivery does not match launch metadata");
  } catch (error) {
    const message = "provider credentials unavailable for this run";
    appendEvent(directory, {kind: "error", text: message});
    setState(directory, "error", {error: message, credentialDelivery: "missing"});
    process.exit(1);
  }
  let resolved;
  try { resolved = resolveLaunch(launch); } catch (error) {
    appendEvent(directory, {kind: "error", text: String(error.message)});
    setState(directory, "error", {error: String(error.message)});
    process.exit(1);
  }
  if (fs.existsSync(path.join(directory, "stop-requested"))) {
    appendEvent(directory, {kind: "stopped", text: "stopped before harness start"});
    setState(directory, "stopped");
    process.exit(0);
  }
  const secrets = providerExecution.candidates.map(candidate => candidate.secret).filter(Boolean);
  let finalExit = {code: 1, signal: null};
  let finalChild = null;
  let finalIdentity = null;
  for (let index = 0; index < providerExecution.candidates.length; index += 1) {
    const candidate = providerExecution.candidates[index];
    const healthProbe = launch.healthProbe === true;
    const turnTimeoutSeconds = Number.isSafeInteger(launch.turnTimeoutSeconds) && launch.turnTimeoutSeconds >= 1 && launch.turnTimeoutSeconds <= 10800 ? launch.turnTimeoutSeconds : 3600;
    const childCWD = launch.harnessID === "pi-code" || healthProbe ? release : launch.hostWorkspace?.path;
    if (launch.harnessID !== "pi-code" && !healthProbe && (!safeOwnedDirectory(childCWD, worktreesRoot) || path.basename(childCWD) !== runID)) {
      appendEvent(directory, {kind: "error", text: "workspace path is unavailable for this run"});
      setState(directory, "error", {error: "workspace path is unavailable for this run"});
      process.exit(1);
    }
    const child = spawn(resolved.command, providerArguments(resolved, launch, candidate), {cwd: childCWD, env: providerEnvironment(launch.harnessID, launch, candidate, candidate.secret), stdio: ["pipe", "pipe", "pipe"], detached: true});
    const pidIdentity = processIdentity(child.pid);
    if (!pidIdentity) {
      try { signalProcessGroup(child.pid, "SIGKILL"); } catch {}
      appendEvent(directory, {kind: "error", text: "cannot establish child start identity"});
      setState(directory, "error", {error: "cannot establish child start identity"});
      process.exit(1);
    }
    finalChild = child;
    finalIdentity = pidIdentity;
    setState(directory, "running", {pid: child.pid, pidIdentity, heartbeatAt: new Date().toISOString(), providerRoute: candidate.displayName, credentialDelivery: "ephemeral"});
    appendEvent(directory, {kind: "started", text: "process launched"});
    const heartbeat = setInterval(() => {
      if (childAlive(child.pid, pidIdentity)) setState(directory, "running", {pid: child.pid, pidIdentity, heartbeatAt: new Date().toISOString()});
    }, HEARTBEAT_MS);
    heartbeat.unref();
    let diagnostic = "";
    const recordText = kind => text => {
      if (kind === "stderr") diagnostic = (diagnostic + text).slice(-65536);
      const bytes = Buffer.from(text, "utf8");
      for (let offset = 0; offset < bytes.length; offset += 2048) appendEvent(directory, {kind, text: bytes.subarray(offset, offset + 2048).toString("utf8")});
    };
    const stdout = redactingRecorder("stdout", secrets, recordText("stdout"));
    const stderr = redactingRecorder("stderr", secrets, recordText("stderr"));
    child.stdout.on("data", chunk => stdout.push(chunk));
    child.stderr.on("data", chunk => stderr.push(chunk));
    child.on("error", error => { const text = redactSecrets(error.message, secrets); appendEvent(directory, {kind: "error", text}); setState(directory, "error", {error: text}); });
    child.stdin.end(resolved.input);
    let timedOut = false;
    let killTimer;
    const timeoutTimer = setTimeout(() => {
      if (!childAlive(child.pid, pidIdentity)) return;
      timedOut = true;
      const text = `worker turn timed out after ${turnTimeoutSeconds} seconds`;
      appendEvent(directory, {kind: "timeout", text, exitCode: 124});
      setState(directory, "running", {error: text, timedOut: true, heartbeatAt: new Date().toISOString()});
      try { signalProcessGroup(child.pid, "SIGTERM"); } catch {}
      killTimer = setTimeout(() => {
        if (childAlive(child.pid, pidIdentity)) {
          try { signalProcessGroup(child.pid, "SIGKILL"); } catch {}
        }
      }, STOP_GRACE_MS);
      killTimer.unref();
    }, turnTimeoutSeconds * 1000);
    timeoutTimer.unref();
    const exit = await new Promise(resolve => child.on("close", (code, signal) => resolve({code, signal})));
    clearTimeout(timeoutTimer);
    if (killTimer) clearTimeout(killTimer);
    stdout.flush();
    stderr.flush();
    clearInterval(heartbeat);
    finalExit = timedOut ? {code: 124, signal: exit.signal ?? "SIGTERM"} : exit;
    const stopped = fs.existsSync(path.join(directory, "stop-requested"));
    if (timedOut || stopped || exit.code === 0 || index + 1 >= providerExecution.candidates.length || !retryableProviderFailure(diagnostic)) break;
    appendEvent(directory, {kind: "lifecycle", text: "provider fallback"});
  }
  const stopRequested = fs.existsSync(path.join(directory, "stop-requested"));
  const finalState = stopRequested ? "stopped" : finalExit.code === 0 ? "completed" : "failed";
  appendEvent(directory, {kind: finalState, text: finalExit.signal ?? undefined, exitCode: Number.isInteger(finalExit.code) ? finalExit.code : undefined});
  setState(directory, finalState, {exitCode: Number.isInteger(finalExit.code) ? finalExit.code : null, signal: finalExit.signal ?? null, pid: finalChild?.pid, pidIdentity: finalIdentity, heartbeatAt: new Date().toISOString()});
  process.exit(finalExit.code === 0 || stopRequested ? 0 : 1);
};

if (process.argv[2] === "--monitor") await monitor(process.argv[3]);

const importWorkspace = async () => {
  if (!gitExecutable) reject("workspace_git_unavailable");
  const limit = 64 * 1024 * 1024;
  let input = Buffer.alloc(0);
  for await (const chunk of process.stdin) {
    input = Buffer.concat([input, chunk]);
    if (input.length > limit + 4096) reject("workspace_bundle_too_large");
  }
  const newline = input.indexOf(10);
  if (newline < 2 || newline > 4096) reject("workspace_manifest_invalid");
  let manifest;
  try { manifest = JSON.parse(input.subarray(0, newline).toString("utf8")); } catch { reject("workspace_manifest_invalid"); }
  const keys = Object.keys(manifest).sort().join(",");
  const baseKeys = "bundleSHA256,byteSize,repoID,schemaVersion,snapshotCommitOID";
  const gitlinkKeys = "bundleSHA256,byteSize,repoID,schemaVersion,snapshotCommitOID,submodules";
  const safeGitlinkPath = value => typeof value === "string" && value.length > 0 && safeGitPath(value);
  const submodules = Array.isArray(manifest.submodules) ? manifest.submodules : [];
  const validSubmodules = submodules.length > 0 && submodules.length <= 256 && submodules.every(value => {
    if (!value || Object.keys(value).sort().join(",") !== "bundleRef,commitOID,path" || !safeGitlinkPath(value.path) || !validOID(value.commitOID) || typeof value.bundleRef !== "string" || !/^refs\/workjet\/submodules\/[a-z0-9-]+\/[0-9]+$/.test(value.bundleRef)) return false;
    return true;
  }) && new Set(submodules.map(value => value.path)).size === submodules.length && new Set(submodules.map(value => value.bundleRef)).size === submodules.length;
  if (!validRepoID(manifest.repoID) || !validOID(manifest.snapshotCommitOID) || !/^[0-9a-f]{64}$/.test(manifest.bundleSHA256) || !Number.isSafeInteger(manifest.byteSize) || manifest.byteSize < 1 || manifest.byteSize > limit || !((keys === baseKeys && manifest.schemaVersion === 1) || (keys === gitlinkKeys && manifest.schemaVersion === 2 && validSubmodules))) reject("workspace_manifest_invalid");
  const bundle = input.subarray(newline + 1);
  if (bundle.length !== manifest.byteSize) reject("workspace_size_mismatch");
  if (crypto.createHash("sha256").update(bundle).digest("hex") !== manifest.bundleSHA256) reject("workspace_hash_mismatch");
  const cache = path.join(reposRoot, `${manifest.repoID}.git`);
  if (fs.existsSync(cache)) {
    if (!safeOwnedDirectory(cache, reposRoot)) reject("workspace_cache_unsafe");
  } else {
    try { execFileSync(gitExecutable, ["init", "--bare", cache], {env: gitEnvironment(), timeout: 30000, stdio: ["ignore", "ignore", "pipe"]}); }
    catch { reject("workspace_import_failed"); }
    if (!safeOwnedDirectory(cache, reposRoot)) reject("workspace_cache_unsafe");
  }
  const temporary = path.join(importsRoot, `${manifest.repoID}-${process.pid}-${Date.now()}.bundle`);
  let importError;
  try {
    fs.writeFileSync(temporary, bundle, {mode: 0o600, flag: "wx"});
    execFileSync(gitExecutable, ["bundle", "verify", temporary], {cwd: cache, env: gitEnvironment(), timeout: 60000, stdio: ["ignore", "ignore", "pipe"]});
    const heads = execFileSync(gitExecutable, ["bundle", "list-heads", temporary], {cwd: cache, env: gitEnvironment(), encoding: "utf8", timeout: 30000, maxBuffer: 65536});
    const advertised = new Map(heads.split(/\r?\n/).filter(Boolean).map(line => { const split = line.indexOf(" "); return split > 0 ? [line.slice(split + 1), line.slice(0, split)] : ["", ""]; }));
    const snapshotHead = [...advertised].find(([, oid]) => oid === manifest.snapshotCommitOID)?.[0];
    if (!snapshotHead || submodules.some(value => advertised.get(value.bundleRef) !== value.commitOID)) throw new Error("workspace_commit_not_in_bundle");
    const destination = `refs/workjet/snapshots/${manifest.snapshotCommitOID}`;
    const fetchArguments = ["fetch", "--no-tags", temporary, `${snapshotHead}:${destination}`];
    submodules.forEach((value, index) => fetchArguments.push(`${value.bundleRef}:refs/workjet/submodules/${manifest.snapshotCommitOID}/${index}`));
    execFileSync(gitExecutable, fetchArguments, {cwd: cache, env: gitEnvironment(), timeout: 120000, stdio: ["ignore", "ignore", "pipe"]});
    execFileSync(gitExecutable, ["cat-file", "-e", `${manifest.snapshotCommitOID}^{commit}`], {cwd: cache, env: gitEnvironment(), timeout: 30000, stdio: "ignore"});
    submodules.forEach(value => execFileSync(gitExecutable, ["cat-file", "-e", `${value.commitOID}^{commit}`], {cwd: cache, env: gitEnvironment(), timeout: 30000, stdio: "ignore"}));
    const importedGitlinks = snapshotGitlinks(cache, manifest.snapshotCommitOID);
    if (importedGitlinks.size !== submodules.length || submodules.some(value => importedGitlinks.get(value.path) !== value.commitOID)) throw new Error("workspace_gitlink_manifest_mismatch");
  } catch (error) {
    importError = ["workspace_commit_not_in_bundle", "workspace_gitlink_manifest_mismatch"].includes(error.message) ? error.message : "workspace_import_failed";
  } finally {
    try { fs.unlinkSync(temporary); } catch {}
  }
  if (importError) reject(importError);
  response({capabilities: ["workspace-git-v1", "workspace-gitlinks-v1"]});
};
const createRunWorkspace = (descriptor, runID) => {
  if (!gitExecutable || !validRepoID(descriptor?.repoID) || !validOID(descriptor?.snapshotCommitOID) || !safeRunID(runID)) throw new Error("workspace_required");
  const cache = path.join(reposRoot, `${descriptor.repoID}.git`);
  if (!safeOwnedDirectory(cache, reposRoot)) throw new Error("workspace_cache_missing");
  try { execFileSync(gitExecutable, ["cat-file", "-e", `${descriptor.snapshotCommitOID}^{commit}`], {cwd: cache, env: gitEnvironment(), timeout: 30000, stdio: "ignore"}); }
  catch { throw new Error("workspace_commit_missing"); }
  const gitlinks = validateSnapshotTree(cache, descriptor.snapshotCommitOID);
  const worktree = path.join(worktreesRoot, runID);
  if (fs.existsSync(worktree)) throw new Error("workspace_path_exists");
  const createdSubmodules = [];
  let parentCreated = false;
  try {
    execFileSync(gitExecutable, [`--git-dir=${cache}`, "worktree", "add", "--detach", worktree, descriptor.snapshotCommitOID], {env: gitEnvironment(), timeout: 120000, stdio: ["ignore", "ignore", "pipe"]});
    parentCreated = true;
    if (!safeOwnedDirectory(worktree, worktreesRoot) || path.basename(worktree) !== runID) throw new Error("workspace_path_unsafe");
    for (const [submodulePath, oid] of [...gitlinks].sort(([left], [right]) => left.localeCompare(right))) {
      const destination = path.join(worktree, submodulePath);
      const relative = path.relative(worktree, destination);
      if (!safeGitPath(relative) || path.isAbsolute(relative)) throw new Error("workspace_submodule_path_unsafe");
      if (fs.existsSync(destination)) {
        if (!safeOwnedDescendantDirectory(destination, worktree) || fs.readdirSync(destination).length !== 0) throw new Error("workspace_submodule_path_unsafe");
        fs.rmdirSync(destination);
      }
      execFileSync(gitExecutable, [`--git-dir=${cache}`, "worktree", "add", "--detach", destination, oid], {env: gitEnvironment(), timeout: 120000, stdio: ["ignore", "ignore", "pipe"]});
      createdSubmodules.push(destination);
      if (!safeOwnedDescendantDirectory(destination, worktree)) throw new Error("workspace_submodule_path_unsafe");
    }
  } catch (error) {
    for (const destination of createdSubmodules.reverse()) { try { execFileSync(gitExecutable, [`--git-dir=${cache}`, "worktree", "remove", "--force", destination], {env: gitEnvironment(), timeout: 120000, stdio: ["ignore", "ignore", "pipe"]}); } catch {} }
    if (parentCreated) { try { execFileSync(gitExecutable, [`--git-dir=${cache}`, "worktree", "remove", "--force", worktree], {env: gitEnvironment(), timeout: 120000, stdio: ["ignore", "ignore", "pipe"]}); } catch {} }
    throw error.message?.startsWith("workspace_") ? error : new Error("workspace_creation_failed");
  }
  return worktree;
};

const RESULT_LIMIT = 64 * 1024 * 1024;
const RESULT_TREE_ENTRY_LIMIT = 100000;
const resultReject = message => { process.stderr.write(String(message).slice(0, 256) + "\n"); process.exit(65); };
const safeGitPath = value => {
  if (typeof value !== "string" || !value || value.startsWith("/") || value.includes("\0")) return false;
  if ([...value].some(character => character.charCodeAt(0) < 0x20 || character.charCodeAt(0) === 0x7f)) return false;
  const parts = value.split("/");
  return parts.every(part => part && part !== "." && part !== "..");
};
const indexedGitlinks = staged => {
  const result = new Map();
  for (const value of staged.filter(entry => entry.startsWith("160000 "))) {
    const match = /^160000 ([0-9a-f]{40,64}) 0\t([^\0]+)$/.exec(value);
    if (!match || !safeGitPath(match[2]) || result.has(match[2])) throw new Error("workspace_result_tree_unsafe");
    result.set(match[2], match[1]);
  }
  return result;
};
const validateWorkspaceFilesystem = (worktree, runID, allowedGitlinks) => {
  if (!safeOwnedDirectory(worktree, worktreesRoot) || path.basename(worktree) !== runID) throw new Error("workspace_path_unsafe");
  const queue = [worktree];
  while (queue.length) {
    const current = queue.pop();
    const entries = fs.readdirSync(current, {withFileTypes: true});
    for (const entry of entries) {
      const item = path.join(current, entry.name);
      const relative = path.relative(worktree, item);
      const info = fs.lstatSync(item);
      if (info.isSymbolicLink()) throw new Error("workspace_symlink_rejected");
      if (entry.name === ".git") {
        const repositoryRelative = path.relative(worktree, current);
        if ((current !== worktree && !allowedGitlinks.has(repositoryRelative)) || !info.isFile()) throw new Error("workspace_nested_repository_rejected");
        continue;
      }
      if (!safeGitPath(relative)) throw new Error("workspace_path_rejected");
      if (info.isDirectory()) queue.push(item);
      else if (!info.isFile()) throw new Error("workspace_special_file_rejected");
    }
  }
};
const commitTreeEntries = (cache, commitOID, errorPrefix) => {
  const listing = execFileSync(gitExecutable, ["ls-tree", "-r", "-z", "--full-tree", commitOID], {cwd: cache, env: gitEnvironment(), timeout: 60000, maxBuffer: 16 * 1024 * 1024});
  return listing.toString("utf8").split("\0").filter(Boolean).map(entry => {
    const match = /^(\d{6}) ([a-z]+) ([0-9a-f]{40,64})\t([\s\S]+)$/.exec(entry);
    if (!match || !safeGitPath(match[4])) throw new Error(`${errorPrefix}_tree_unsafe`);
    return {mode: match[1], type: match[2], oid: match[3], path: match[4]};
  });
};
const validateCommitTree = (cache, commitOID, errorPrefix, allowedGitlinks = new Map(), budget = {entries: 0, bytes: 0}) => {
  const entries = commitTreeEntries(cache, commitOID, errorPrefix);
  budget.entries += entries.length;
  if (budget.entries > RESULT_TREE_ENTRY_LIMIT) throw new Error(`${errorPrefix}_tree_too_large`);
  const observedGitlinks = new Map();
  const blobs = [];
  for (const entry of entries) {
    if (entry.mode === "160000") {
      if (entry.type !== "commit" || allowedGitlinks.get(entry.path) !== entry.oid || observedGitlinks.has(entry.path)) throw new Error(`${errorPrefix}_tree_unsafe`);
      observedGitlinks.set(entry.path, entry.oid);
      continue;
    }
    if (entry.mode === "120000" || entry.type !== "blob") throw new Error(`${errorPrefix}_tree_unsafe`);
    blobs.push(entry);
  }
  const sizes = blobs.length === 0 ? [] : execFileSync(
    gitExecutable,
    ["cat-file", "--batch-check=%(objectname) %(objecttype) %(objectsize)"],
    {cwd: cache, env: gitEnvironment(), encoding: "utf8", input: blobs.map(entry => `${entry.oid}\n`).join(""), timeout: 60000, maxBuffer: 16 * 1024 * 1024}
  ).trimEnd().split("\n");
  if (sizes.length !== blobs.length) throw new Error(`${errorPrefix}_object_invalid`);
  for (let index = 0; index < blobs.length; index += 1) {
    const fields = sizes[index].split(" ");
    if (fields.length !== 3 || fields[0] !== blobs[index].oid || fields[1] !== "blob") throw new Error(`${errorPrefix}_object_invalid`);
    const size = Number(fields[2]);
    if (!Number.isSafeInteger(size) || size < 0) throw new Error(`${errorPrefix}_object_invalid`);
    budget.bytes += size;
    if (budget.bytes > RESULT_LIMIT) throw new Error(`${errorPrefix}_objects_too_large`);
  }
  if (observedGitlinks.size !== allowedGitlinks.size) throw new Error(`${errorPrefix}_tree_unsafe`);
  return budget;
};
const snapshotGitlinks = (cache, snapshotOID) => new Map(commitTreeEntries(cache, snapshotOID, "workspace_snapshot").filter(entry => entry.mode === "160000").map(entry => {
  if (entry.type !== "commit") throw new Error("workspace_snapshot_tree_unsafe");
  return [entry.path, entry.oid];
}));
const validateSnapshotTree = (cache, snapshotOID) => {
  const gitlinks = snapshotGitlinks(cache, snapshotOID);
  const budget = validateCommitTree(cache, snapshotOID, "workspace_snapshot", gitlinks);
  for (const oid of gitlinks.values()) validateCommitTree(cache, oid, "workspace_snapshot_submodule", new Map(), budget);
  return gitlinks;
};
const validateResultTree = (cache, snapshotOID, resultOID) => {
  try { execFileSync(gitExecutable, ["merge-base", "--is-ancestor", snapshotOID, resultOID], {cwd: cache, env: gitEnvironment(), timeout: 30000, stdio: "ignore"}); }
  catch { throw new Error("workspace_result_not_descendant"); }
  const gitlinks = snapshotGitlinks(cache, snapshotOID);
  validateCommitTree(cache, resultOID, "workspace_result", gitlinks);
};
const capturedWorkspaceResult = (request, directory, state, launch) => {
  const manifestFile = path.join(directory, "result.json");
  const bundleFile = path.join(directory, "result.bundle");
  if (fs.existsSync(manifestFile)) {
    const manifest = readJSON(manifestFile);
    const keys = Object.keys(manifest).sort().join(",");
    if (keys !== "bundleSHA256,byteSize,repoID,resultCommitOID,runID,schemaVersion,snapshotCommitOID,terminalState" || manifest.schemaVersion !== 1 || manifest.runID !== request.runID || manifest.repoID !== request.repoID || manifest.snapshotCommitOID !== request.snapshotCommitOID || !validOID(manifest.resultCommitOID) || !/^[0-9a-f]{64}$/.test(manifest.bundleSHA256) || !Number.isSafeInteger(manifest.byteSize) || manifest.byteSize < 1 || manifest.byteSize > RESULT_LIMIT || !["completed", "failed", "stopped", "error"].includes(manifest.terminalState)) throw new Error("workspace_result_record_invalid");
    const bundleInfo = fs.lstatSync(bundleFile);
    if (!bundleInfo.isFile() || bundleInfo.isSymbolicLink() || bundleInfo.uid !== process.geteuid() || bundleInfo.size !== manifest.byteSize) throw new Error("workspace_result_bundle_invalid");
    const bundle = fs.readFileSync(bundleFile);
    if (crypto.createHash("sha256").update(bundle).digest("hex") !== manifest.bundleSHA256) throw new Error("workspace_result_hash_mismatch");
    return {manifest, bundle};
  }
  try { fs.unlinkSync(bundleFile); } catch {}
  const worktree = path.join(worktreesRoot, request.runID);
  const cache = path.join(reposRoot, `${request.repoID}.git`);
  if (!safeOwnedDirectory(cache, reposRoot)) throw new Error("workspace_cache_missing");
  const gitlinks = snapshotGitlinks(cache, request.snapshotCommitOID);
  validateWorkspaceFilesystem(worktree, request.runID, gitlinks);
  const currentIndex = execFileSync(gitExecutable, ["ls-files", "--stage", "-z"], {cwd: worktree, env: gitEnvironment(), timeout: 60000, maxBuffer: 16 * 1024 * 1024}).toString("utf8").split("\0").filter(Boolean);
  const currentIndexGitlinks = indexedGitlinks(currentIndex);
  if (currentIndexGitlinks.size !== gitlinks.size || [...gitlinks].some(([submodulePath, oid]) => currentIndexGitlinks.get(submodulePath) !== oid)) throw new Error("workspace_result_submodule_changed");
  for (const [submodulePath, oid] of gitlinks) {
    const submodule = path.join(worktree, submodulePath);
    if (!safeGitPath(path.relative(worktree, submodule)) || !safeOwnedDescendantDirectory(submodule, worktree)) throw new Error("workspace_result_submodule_changed");
    let head, status;
    try {
      const gitFileInfo = fs.lstatSync(path.join(submodule, ".git"));
      if (!gitFileInfo.isFile() || gitFileInfo.isSymbolicLink() || gitFileInfo.uid !== process.geteuid()) throw new Error("unsafe git file");
      const gitDirectory = fs.realpathSync(execFileSync(gitExecutable, ["rev-parse", "--absolute-git-dir"], {cwd: submodule, env: gitEnvironment(), encoding: "utf8", timeout: 30000, maxBuffer: 4096}).trim());
      const metadataRoot = fs.realpathSync(path.join(cache, "worktrees"));
      const gitDirectoryInfo = fs.lstatSync(gitDirectory);
      if (path.dirname(gitDirectory) !== metadataRoot || !gitDirectoryInfo.isDirectory() || gitDirectoryInfo.isSymbolicLink() || gitDirectoryInfo.uid !== process.geteuid()) throw new Error("unsafe git directory");
      head = execFileSync(gitExecutable, ["rev-parse", "--verify", "HEAD^{commit}"], {cwd: submodule, env: gitEnvironment(), encoding: "utf8", timeout: 30000, maxBuffer: 1024}).trim();
      status = execFileSync(gitExecutable, ["status", "--porcelain=v1", "-z", "--untracked-files=all"], {cwd: submodule, env: gitEnvironment(), timeout: 60000, maxBuffer: 16 * 1024 * 1024});
    } catch { throw new Error("workspace_result_submodule_changed"); }
    if (head !== oid || status.length !== 0) throw new Error("workspace_result_submodule_changed");
  }
  const resultRef = `refs/workjet/results/${request.runID}`;
  let resultOID;
  try { resultOID = execFileSync(gitExecutable, ["rev-parse", "--verify", `${resultRef}^{commit}`], {cwd: cache, env: gitEnvironment(), encoding: "utf8", timeout: 30000, maxBuffer: 1024, stdio: ["ignore", "pipe", "pipe"]}).trim(); } catch {}
  const resultRefExists = validOID(resultOID);
  if (!resultRefExists) {
    const index = path.join(directory, `result-index-${process.pid}-${Date.now()}`);
    const environment = {...gitEnvironment(), GIT_INDEX_FILE: index, GIT_OPTIONAL_LOCKS: "0"};
    try {
      execFileSync(gitExecutable, ["read-tree", request.snapshotCommitOID], {cwd: worktree, env: environment, timeout: 30000, stdio: ["ignore", "ignore", "pipe"]});
      const paths = execFileSync(gitExecutable, ["ls-files", "-co", "--exclude-standard", "-z"], {cwd: worktree, env: environment, timeout: 60000, maxBuffer: 16 * 1024 * 1024}).toString("utf8").split("\0").filter(Boolean);
      if (paths.length > RESULT_TREE_ENTRY_LIMIT || paths.some(value => !safeGitPath(value))) throw new Error("workspace_result_paths_unsafe");
      execFileSync(gitExecutable, ["add", "-A", "--", "."], {cwd: worktree, env: environment, timeout: 120000, stdio: ["ignore", "ignore", "pipe"]});
      const staged = execFileSync(gitExecutable, ["ls-files", "--stage", "-z"], {cwd: worktree, env: environment, timeout: 60000, maxBuffer: 16 * 1024 * 1024}).toString("utf8").split("\0").filter(Boolean);
      if (staged.some(value => value.startsWith("120000 "))) throw new Error("workspace_result_tree_unsafe");
      const stagedGitlinks = indexedGitlinks(staged);
      if (stagedGitlinks.size !== gitlinks.size || [...gitlinks].some(([submodulePath, oid]) => stagedGitlinks.get(submodulePath) !== oid)) throw new Error("workspace_result_submodule_changed");
      const tree = execFileSync(gitExecutable, ["write-tree"], {cwd: worktree, env: environment, encoding: "utf8", timeout: 60000, maxBuffer: 1024}).trim();
      const snapshotTree = execFileSync(gitExecutable, ["rev-parse", `${request.snapshotCommitOID}^{tree}`], {cwd: cache, env: gitEnvironment(), encoding: "utf8", timeout: 30000, maxBuffer: 1024}).trim();
      if (tree === snapshotTree) resultOID = request.snapshotCommitOID;
      else {
        const timestamp = execFileSync(gitExecutable, ["show", "-s", "--format=%ct", request.snapshotCommitOID], {cwd: cache, env: gitEnvironment(), encoding: "utf8", timeout: 30000, maxBuffer: 1024}).trim();
        const commitEnvironment = {...environment, GIT_AUTHOR_NAME: "Workjet Result", GIT_AUTHOR_EMAIL: "result@workjet.invalid", GIT_COMMITTER_NAME: "Workjet Result", GIT_COMMITTER_EMAIL: "result@workjet.invalid", GIT_AUTHOR_DATE: `@${timestamp} +0000`, GIT_COMMITTER_DATE: `@${timestamp} +0000`};
        resultOID = execFileSync(gitExecutable, ["commit-tree", tree, "-p", request.snapshotCommitOID], {cwd: cache, env: commitEnvironment, input: Buffer.from(`Workjet immutable result ${request.runID}\n`), encoding: "utf8", timeout: 30000, maxBuffer: 1024}).trim();
      }
      if (!validOID(resultOID)) throw new Error("workspace_result_commit_invalid");
    } finally { try { fs.unlinkSync(index); } catch {} }
  }
  validateResultTree(cache, request.snapshotCommitOID, resultOID);
  const temporaryBundle = path.join(directory, `result-bundle-${process.pid}-${Date.now()}`);
  const stagingRef = `refs/workjet/result-staging/${request.runID}-${process.pid}`;
  const bundleRef = resultRefExists ? resultRef : stagingRef;
  let stagingCreated = false;
  try {
    if (!resultRefExists) {
      execFileSync(gitExecutable, ["update-ref", stagingRef, resultOID, "0".repeat(resultOID.length)], {cwd: cache, env: gitEnvironment(), timeout: 30000, stdio: ["ignore", "ignore", "pipe"]});
      stagingCreated = true;
    }
    execFileSync(gitExecutable, ["bundle", "create", temporaryBundle, bundleRef], {cwd: cache, env: gitEnvironment(), timeout: 120000, stdio: ["ignore", "ignore", "pipe"]});
    const info = fs.lstatSync(temporaryBundle);
    if (!info.isFile() || info.isSymbolicLink() || info.size < 1 || info.size > RESULT_LIMIT) throw new Error("workspace_result_bundle_too_large");
    fs.renameSync(temporaryBundle, bundleFile);
    fs.chmodSync(bundleFile, 0o600);
    if (!resultRefExists) execFileSync(gitExecutable, ["update-ref", resultRef, resultOID, "0".repeat(resultOID.length)], {cwd: cache, env: gitEnvironment(), timeout: 30000, stdio: ["ignore", "ignore", "pipe"]});
  } finally {
    try { fs.unlinkSync(temporaryBundle); } catch {}
    if (stagingCreated) { try { execFileSync(gitExecutable, ["update-ref", "-d", stagingRef, resultOID], {cwd: cache, env: gitEnvironment(), timeout: 30000, stdio: ["ignore", "ignore", "pipe"]}); } catch {} }
  }
  const bundle = fs.readFileSync(bundleFile);
  const manifest = {schemaVersion: 1, runID: request.runID, repoID: request.repoID, snapshotCommitOID: request.snapshotCommitOID, resultCommitOID: resultOID, bundleSHA256: crypto.createHash("sha256").update(bundle).digest("hex"), byteSize: bundle.length, terminalState: state.state};
  atomicJSON(manifestFile, manifest);
  return {manifest, bundle};
};
const exportWorkspaceResult = async () => {
  if (!gitExecutable) resultReject("workspace_result_unavailable");
  let input = Buffer.alloc(0);
  for await (const chunk of process.stdin) { input = Buffer.concat([input, chunk]); if (input.length > 4096) resultReject("workspace_result_request_too_large"); }
  const lines = input.toString("utf8").split(/\r?\n/).filter(Boolean);
  if (lines.length !== 1) resultReject("workspace_result_request_invalid");
  let request;
  try { request = JSON.parse(lines[0]); } catch { resultReject("workspace_result_request_invalid"); }
  const keys = Object.keys(request).sort().join(",");
  if (keys !== "ownerID,repoID,runID,schemaVersion,snapshotCommitOID" || request.schemaVersion !== 1 || !safeRunID(request.runID) || !validRepoID(request.repoID) || !validOID(request.snapshotCommitOID) || typeof request.ownerID !== "string" || !workerIDFromOwner(request.ownerID)) resultReject("workspace_result_request_invalid");
  const directory = runDirectory(request.runID);
  try {
    if (!safeOwnedDirectory(directory, runsRoot) || treeContainsSymlink(directory)) throw new Error("workspace_run_unsafe");
    const state = observedState(directory);
    if (!["completed", "failed", "stopped", "error"].includes(state.state)) throw new Error("workspace_run_not_terminal");
    if (state.ownerID !== request.ownerID) throw new Error("workspace_run_not_owned");
    if (state.workspaceDisposition) throw new Error("workspace_run_finalized");
    const launch = readJSON(path.join(directory, "launch.json"));
    if (!["claude-code", "codex-cli", "opencode"].includes(launch.harnessID) || launch.workspace?.repoID !== request.repoID || launch.workspace?.snapshotCommitOID !== request.snapshotCommitOID || launch.hostWorkspace?.path !== path.join(worktreesRoot, request.runID)) throw new Error("workspace_identity_mismatch");
    const lockFile = path.join(directory, "result.lock");
    let lock;
    try { lock = fs.openSync(lockFile, "wx", 0o600); } catch { throw new Error("workspace_result_busy"); }
    try {
      const result = capturedWorkspaceResult(request, directory, state, launch);
      fs.writeSync(1, Buffer.from(JSON.stringify(result.manifest) + "\n"));
      fs.writeSync(1, result.bundle);
    } finally { try { fs.closeSync(lock); } catch {}; try { fs.unlinkSync(lockFile); } catch {} }
  } catch (error) { resultReject(error.message); }
};

if (process.argv[2] === "--workspace-import") { await importWorkspace(); process.exit(0); }
if (process.argv[2] === "--workspace-result") { await exportWorkspaceResult(); process.exit(0); }

let requestData = Buffer.alloc(0);
for await (const chunk of process.stdin) {
  requestData = Buffer.concat([requestData, chunk]);
  if (requestData.length > 2097152) reject("request too large");
}
const requestLines = requestData.toString("utf8").split(/\r?\n/).filter(Boolean);
if (requestLines.length !== 1) reject("exactly one request is required");
let request;
try { request = JSON.parse(requestLines[0]); } catch { reject("invalid JSON"); }
if (![1, PROTOCOL].includes(request.protocolVersion)) reject("incompatible protocol");
cleanupRetainedRuns();

if (request.operation === "probe") {
  const capabilities = ["start", "provider-execution-v1", "gateway-relay-v1", "relay-loss-v1", "health-probe-v1", "events-after-exclusive-cursor", "bounded-events", "recoverable-cursor-gap", "child-heartbeat", "pid-start-identity", "term-kill-stop", "turn-timeout-v1", "list", "adopt", "run-metadata-v1", "run-retention-v1", "harness-lifecycle-v2", "managed-skill-lifecycle-v1", "pi-code"];
  if (executableAt(harnessDefinitions["claude-code"].candidates)) capabilities.push("claude-code");
  if (executableAt(harnessDefinitions["codex-cli"].candidates)) capabilities.push("codex-cli");
  if (executableAt(harnessDefinitions.opencode.candidates)) capabilities.push("opencode");
  if (inspectManagedSkill("greppy").state === "installed") capabilities.push("greppy");
  if (gitExecutable) capabilities.push("workspace-git-v1", "workspace-gitlinks-v1", "workspace-result-v1");
  response({hostVersion: HOST_VERSION, capabilities});
} else if (["harness-inspect", "harness-install", "harness-update", "harness-remove"].includes(request.operation)) {
  if (request.executable !== undefined || request.arguments !== undefined || request.argv !== undefined || request.command !== undefined) reject("client commands are forbidden");
  if (typeof request.harnessID !== "string" || !/^[a-z0-9-]{1,32}$/.test(request.harnessID)) reject("invalid harness id");
  const action = request.operation.slice("harness-".length);
  const harnessResult = maintainHarness(request.harnessID, action);
  if (!harnessResult) reject("unsupported harness");
  response({harnessResult});
} else if (["managed-skill-inspect", "managed-skill-install"].includes(request.operation)) {
  if (request.executable !== undefined || request.arguments !== undefined || request.argv !== undefined || request.command !== undefined || request.url !== undefined || request.downloadURL !== undefined) reject("client commands and URLs are forbidden");
  if (typeof request.skillID !== "string" || !/^[a-z0-9-]{1,32}$/.test(request.skillID)) reject("invalid managed skill id");
  const action = request.operation.slice("managed-skill-".length);
  const managedSkillResult = maintainManagedSkill(request.skillID, action);
  if (!managedSkillResult) reject("unsupported managed skill");
  response({managedSkillResult});
} else if (request.operation === "start") {
  try { resolveLaunch(request.launch); } catch (error) { reject(error.message); }
  if (request.turnTimeoutSeconds !== undefined && (!Number.isSafeInteger(request.turnTimeoutSeconds) || request.turnTimeoutSeconds < 1 || request.turnTimeoutSeconds > 10800)) reject("invalid turn timeout");
  const turnTimeoutSeconds = request.launch.healthProbe === true ? 3600 : (request.turnTimeoutSeconds ?? 3600);
  let providerExecution;
  try { providerExecution = validateProviderExecution(request.providerExecution); } catch (error) { reject(error.message); }
  const workerID = workerIDFromOwner(request.ownerID);
  if (request.workerName !== undefined && (!workerID || typeof request.workerName !== "string" || request.workerName.trim().length < 1 || Buffer.byteLength(request.workerName) > 256)) reject("invalid worker identity");
  const runID = `run-${Date.now()}-${process.pid}-${Math.random().toString(16).slice(2, 10)}`;
  let hostWorkspace;
  if (request.launch.harnessID !== "pi-code" && request.launch.healthProbe !== true) {
    try { hostWorkspace = {path: createRunWorkspace(request.launch.workspace, runID)}; }
    catch (error) { reject(error.message); }
  }
  const directory = runDirectory(runID);
  fs.mkdirSync(directory, {mode: 0o700});
  const startedAt = new Date().toISOString();
  atomicJSON(path.join(directory, "launch.json"), {...request.launch, hostWorkspace, providerRoute: providerMetadata(providerExecution), workerID, workerName: request.workerName?.trim(), turnTimeoutSeconds, startedAt});
  atomicJSON(ledgerFile(directory), []);
  atomicJSON(metadataFile(directory), {cursor: 0, count: 0, bytes: 2});
  setState(directory, "starting", {
    ownerID: typeof request.ownerID === "string" ? request.ownerID : null,
    providerRoute: providerExecution.candidates[0].displayName,
    credentialDelivery: "required"
  });
  const monitorBasePath = process.env.PATH ?? "/usr/local/bin:/usr/bin:/bin";
  const monitorProcess = spawn(process.execPath, [process.argv[1], "--monitor", runID], {cwd: release, detached: true, stdio: ["pipe", "ignore", "ignore"], env: {HOME: process.env.HOME ?? "", PATH: `${managedSkillsBin}${path.delimiter}${managedNPMBin}${path.delimiter}${monitorBasePath}`}});
  monitorProcess.stdin.end(JSON.stringify(providerExecution));
  monitorProcess.unref();
  response({runID, state: "starting", cursor: 0, metadata: persistedRunMetadata(directory, readState(directory))});
} else if (request.operation === "events") {
  if (!safeRunID(request.runID)) reject("invalid run id");
  const directory = runDirectory(request.runID);
  if (!fs.existsSync(directory)) reject("unknown run");
  const after = Number.isSafeInteger(request.afterSequence) && request.afterSequence >= 0 ? request.afterSequence : 0;
  const state = observedState(directory);
  const allEvents = readBoundedEvents(directory);
  const events = allEvents.filter(event => event.sequence > after).slice(0, 16);
  const metadata = ledgerMetadata(directory);
  const oldestSequence = allEvents[0]?.sequence;
  const gapAfterSequence = oldestSequence && after < oldestSequence - 1 ? after : undefined;
  response({runID: request.runID, state: state.state ?? "unknown", cursor: events.at(-1)?.sequence ?? Math.min(after, metadata.cursor ?? after), oldestSequence, gapAfterSequence, heartbeatAt: state.heartbeatAt, events, metadata: persistedRunMetadata(directory, state)});
} else if (request.operation === "list") {
  const runs = [];
  for (const runID of fs.readdirSync(runsRoot).filter(safeRunID)) {
    const directory = runDirectory(runID);
    try {
      const state = observedState(directory);
      if (request.ownerID && state.ownerID !== request.ownerID) continue;
      const metadata = ledgerMetadata(directory);
      let relayID;
      try {
        const launch = readJSON(path.join(directory, "launch.json"));
        relayID = launch.providerRoute?.candidates?.find(candidate => candidate.kind === "gatewayPool")?.relay?.id;
      } catch {}
      runs.push({runID, state: state.state ?? "unknown", cursor: metadata.cursor ?? 0, oldestSequence: metadata.oldestSequence, heartbeatAt: state.heartbeatAt, ownerID: state.ownerID, relayID, metadata: persistedRunMetadata(directory, state)});
    } catch {}
  }
  response({runs});
} else if (request.operation === "adopt") {
  if (!safeRunID(request.runID) || typeof request.ownerID !== "string" || !/^[A-Za-z0-9._-]{1,128}$/.test(request.ownerID)) reject("invalid adoption");
  const directory = runDirectory(request.runID);
  if (!fs.existsSync(directory)) reject("unknown run");
  const state = observedState(directory);
  atomicJSON(path.join(directory, "state.json"), {...state, ownerID: request.ownerID, adoptedAt: new Date().toISOString()});
  const metadata = ledgerMetadata(directory);
  response({runID: request.runID, state: state.state ?? "unknown", cursor: 0, heartbeatAt: state.heartbeatAt, metadata: persistedRunMetadata(directory, state)});
} else if (request.operation === "workspace-finalize") {
  if (!safeRunID(request.runID) || typeof request.ownerID !== "string" || !workerIDFromOwner(request.ownerID) || !["integrated", "abandoned"].includes(request.workspaceDisposition)) reject("invalid workspace finalization");
  const directory = runDirectory(request.runID);
  if (!safeOwnedDirectory(directory, runsRoot) || treeContainsSymlink(directory)) reject("workspace run unsafe");
  const state = observedState(directory);
  if (!["completed", "failed", "stopped", "error"].includes(state.state)) reject("workspace run is not terminal");
  if (state.ownerID !== request.ownerID) reject("workspace run is not owned");
  if (state.workspaceDisposition && state.workspaceDisposition !== request.workspaceDisposition) reject("workspace disposition conflict");
  let launch;
  try { launch = readJSON(path.join(directory, "launch.json")); } catch { reject("workspace launch missing"); }
  if (!["claude-code", "codex-cli", "opencode"].includes(launch.harnessID) || !validRepoID(launch.workspace?.repoID) || !validOID(launch.workspace?.snapshotCommitOID) || launch.hostWorkspace?.path !== path.join(worktreesRoot, request.runID)) reject("workspace identity mismatch");
  const worktree = path.join(worktreesRoot, request.runID);
  if (fs.existsSync(worktree)) {
    if (!safeOwnedDirectory(worktree, worktreesRoot) || path.basename(worktree) !== request.runID) reject("workspace path unsafe");
    const cache = path.join(reposRoot, `${launch.workspace.repoID}.git`);
    if (!safeOwnedDirectory(cache, reposRoot)) reject("workspace cache missing");
    try {
      const gitlinks = snapshotGitlinks(cache, launch.workspace.snapshotCommitOID);
      for (const submodulePath of [...gitlinks.keys()].sort().reverse()) {
        const submodule = path.join(worktree, submodulePath);
        if (!safeGitPath(path.relative(worktree, submodule))) throw new Error("unsafe submodule path");
        if (fs.existsSync(submodule)) {
          if (!safeOwnedDescendantDirectory(submodule, worktree)) throw new Error("unsafe submodule checkout");
          execFileSync(gitExecutable, [`--git-dir=${cache}`, "worktree", "remove", "--force", submodule], {env: gitEnvironment(), timeout: 120000, stdio: ["ignore", "ignore", "pipe"]});
        }
      }
      execFileSync(gitExecutable, [`--git-dir=${cache}`, "worktree", "remove", "--force", worktree], {env: gitEnvironment(), timeout: 120000, stdio: ["ignore", "ignore", "pipe"]});
    } catch { reject("workspace cleanup failed"); }
    if (fs.existsSync(worktree)) reject("workspace cleanup incomplete");
  }
  if (!state.workspaceDisposition) setState(directory, state.state, {workspaceDisposition: request.workspaceDisposition, workspaceFinalizedAt: new Date().toISOString()});
  response({runID: request.runID, state: state.state, cursor: currentCursor(directory), heartbeatAt: state.heartbeatAt, metadata: persistedRunMetadata(directory, readState(directory)), workspaceDisposition: request.workspaceDisposition});
} else if (request.operation === "relay-lost") {
  if (!safeRunID(request.runID)) reject("invalid run id");
  const directory = runDirectory(request.runID);
  if (!fs.existsSync(directory)) reject("unknown run");
  const state = observedState(directory);
  if (!["starting", "running"].includes(state.state)) response({runID: request.runID, state: state.state, cursor: currentCursor(directory), heartbeatAt: state.heartbeatAt, metadata: persistedRunMetadata(directory, state)});
  else {
    fs.writeFileSync(path.join(directory, "stop-requested"), new Date().toISOString(), {mode: 0o600});
    if (state.pid) {
      const pid = Number(state.pid);
      if (!childAlive(pid, state.pidIdentity)) reject("run child identity is no longer alive");
      try { signalProcessGroup(pid, "SIGTERM"); } catch (error) { reject(`relay-loss stop failed: ${error.message}`); }
      const deadline = Date.now() + STOP_GRACE_MS;
      while (Date.now() < deadline && processGroupAlive(pid)) await sleep(50);
      if (processGroupAlive(pid)) {
        try { signalProcessGroup(pid, "SIGKILL"); } catch (error) { reject(`relay-loss kill failed: ${error.message}`); }
      }
      const settleDeadline = Date.now() + 1000;
      while (Date.now() < settleDeadline && processGroupAlive(pid)) await sleep(25);
      if (processGroupAlive(pid)) reject("child process group survived SIGKILL after relay loss");
    }
    const message = "secure provider tunnel disconnected";
    appendEvent(directory, {kind: "error", text: message});
    setState(directory, "error", {pid: state.pid, pidIdentity: state.pidIdentity, heartbeatAt: state.heartbeatAt, error: message, relayLostAt: new Date().toISOString()});
    response({runID: request.runID, state: "error", cursor: currentCursor(directory), heartbeatAt: state.heartbeatAt, metadata: persistedRunMetadata(directory, readState(directory))});
  }
} else if (request.operation === "stop") {
  if (!safeRunID(request.runID)) reject("invalid run id");
  const directory = runDirectory(request.runID);
  if (!fs.existsSync(directory)) reject("unknown run");
  const state = observedState(directory);
  if (!["starting", "running"].includes(state.state)) response({runID: request.runID, state: state.state, cursor: currentCursor(directory), heartbeatAt: state.heartbeatAt, metadata: persistedRunMetadata(directory, state)});
  else {
    fs.writeFileSync(path.join(directory, "stop-requested"), new Date().toISOString(), {mode: 0o600});
    if (!state.pid) response({runID: request.runID, state: "starting", cursor: currentCursor(directory), heartbeatAt: state.heartbeatAt, metadata: persistedRunMetadata(directory, state)});
    else {
      const pid = Number(state.pid);
      if (!childAlive(pid, state.pidIdentity)) reject("run child identity is no longer alive");
      try { signalProcessGroup(pid, "SIGTERM"); } catch (error) { reject(`stop failed: ${error.message}`); }
      const deadline = Date.now() + STOP_GRACE_MS;
      while (Date.now() < deadline && processGroupAlive(pid)) await sleep(50);
      if (processGroupAlive(pid)) {
        try { signalProcessGroup(pid, "SIGKILL"); } catch (error) { reject(`kill failed: ${error.message}`); }
      }
      const settleDeadline = Date.now() + 1000;
      while (Date.now() < settleDeadline && processGroupAlive(pid)) await sleep(25);
      if (processGroupAlive(pid)) reject("child process group survived SIGKILL");
      setState(directory, "stopped", {pid, pidIdentity: state.pidIdentity, heartbeatAt: state.heartbeatAt, stoppedAt: new Date().toISOString()});
      response({runID: request.runID, state: "stopped", cursor: currentCursor(directory), heartbeatAt: state.heartbeatAt, metadata: persistedRunMetadata(directory, readState(directory))});
    }
  }
} else reject("unsupported operation");
"""#

    public static let turnRunnerSource = #"""
import fs from "node:fs";
import http from "node:http";
import https from "node:https";
import net from "node:net";
import os from "node:os";
import path from "node:path";
import process from "node:process";
import {spawn} from "node:child_process";
const REQUEST_LIMIT = 1024 * 1024;
const RESPONSE_LIMIT = 4 * 1024 * 1024;
const TIMEOUT_MS = 120000;
const release = path.dirname(new URL(import.meta.url).pathname);
const daemonFile = path.join(release, "ctox-pi-sidecar.mjs");
const manifestFile = path.join(release, "manifest.json");
const invocationArguments = process.argv.slice(2);
if (invocationArguments.length > 1 || (invocationArguments.length === 1 && invocationArguments[0] !== "--sandbox")) {
  process.stderr.write("workjet-pi-turn: only --sandbox is accepted\n");
  process.exit(64);
}
const sandboxRequested = invocationArguments[0] === "--sandbox";
const manifest = JSON.parse(fs.readFileSync(manifestFile, "utf8"));
const privateDirectory = fs.realpathSync(fs.mkdtempSync(path.join(os.tmpdir(), "workjet-pi-")));
fs.chmodSync(privateDirectory, 0o700);
const socketPath = path.join(privateDirectory, "turn.sock");
let daemon;
let socket;
let providerGateway;
const daemonRunning = () => daemon && daemon.exitCode === null && daemon.signalCode === null;
const stopDaemon = async (signal, timeout) => {
  if (!daemonRunning()) return true;
  const exited = new Promise(resolve => {
    const onExit = () => { clearTimeout(timer); resolve(true); };
    const timer = setTimeout(() => { daemon.off("exit", onExit); resolve(false); }, timeout);
    daemon.once("exit", onExit);
  });
  daemon.kill(signal);
  return await exited;
};
const cleanup = async () => {
  if (socket) socket.destroy();
  if (daemonRunning()) {
    await stopDaemon("SIGTERM", 1000);
    if (daemonRunning()) {
      await stopDaemon("SIGKILL", 1000);
    }
  }
  if (providerGateway) {
    providerGateway.closeAllConnections?.();
    providerGateway.close();
  }
  try { fs.rmSync(privateDirectory, {recursive: true, force: true}); } catch {}
};
const fail = async message => { await cleanup(); process.stderr.write(`workjet-pi-turn: ${message}\n`); process.exit(1); };
const hardTimer = setTimeout(() => { void fail("execution timeout"); }, TIMEOUT_MS);
let request = Buffer.alloc(0);
for await (const chunk of process.stdin) {
  request = Buffer.concat([request, chunk]);
  if (request.length > REQUEST_LIMIT) await fail("request limit exceeded");
}
const lines = request.toString("utf8").split(/\r?\n/).filter(Boolean);
if (lines.length !== 1) await fail("exactly one NDJSON request is required");
let turnRequest;
try { turnRequest = JSON.parse(lines[0]); } catch { await fail("request is not JSON"); }
const providerEndpoint = process.env.WORKJET_PROVIDER_ENDPOINT;
const providerAuthentication = process.env.WORKJET_PROVIDER_AUTHENTICATION;
let target;
try { target = new URL(providerEndpoint); } catch { await fail("provider endpoint is unavailable"); }
if (!['http:', 'https:'].includes(target.protocol) || target.username || target.password) await fail("provider endpoint is invalid");
if (!["Ohne Zugang", "Bearer-Token", "API-Key (x-api-key)"].includes(providerAuthentication)) await fail("provider authentication is invalid");
const providerSecret = providerAuthentication === "API-Key (x-api-key)" ? process.env.ANTHROPIC_API_KEY : process.env.ANTHROPIC_AUTH_TOKEN;
if (providerAuthentication !== "Ohne Zugang" && !providerSecret) await fail("provider credential is unavailable");
const sentinel = "Bearer ctox-loopback-public-sentinel";
const blockedHeaders = new Set(["authorization", "connection", "host", "proxy-authorization", "proxy-connection", "te", "trailer", "transfer-encoding", "upgrade", "x-api-key"]);
const gatewayPath = target.pathname.replace(/\/+$/, "");
providerGateway = http.createServer((incoming, outgoing) => {
  if (incoming.headers.authorization !== sentinel || !["GET", "POST"].includes(incoming.method ?? "")) {
    outgoing.writeHead(403, {"content-type": "application/json"});
    outgoing.end('{"error":"forbidden"}');
    return;
  }
  let incomingURL;
  try { incomingURL = new URL(incoming.url ?? "/", "http://127.0.0.1"); }
  catch { outgoing.writeHead(400); outgoing.end(); return; }
  if (gatewayPath && incomingURL.pathname !== gatewayPath && !incomingURL.pathname.startsWith(gatewayPath + "/")) {
    outgoing.writeHead(404); outgoing.end(); return;
  }
  const headers = {};
  for (const [key, value] of Object.entries(incoming.headers)) if (!blockedHeaders.has(key) && value !== undefined) headers[key] = value;
  headers.host = target.host;
  if (providerAuthentication === "Bearer-Token") headers.authorization = `Bearer ${providerSecret}`;
  if (providerAuthentication === "API-Key (x-api-key)") headers["x-api-key"] = providerSecret;
  const transport = target.protocol === "https:" ? https : http;
  const forwarded = transport.request({
    protocol: target.protocol,
    hostname: target.hostname,
    port: target.port || undefined,
    method: incoming.method,
    path: incomingURL.pathname + incomingURL.search,
    headers
  }, response => {
    const responseHeaders = {};
    for (const [key, value] of Object.entries(response.headers)) if (!blockedHeaders.has(key) && value !== undefined) responseHeaders[key] = value;
    outgoing.writeHead(response.statusCode ?? 502, responseHeaders);
    response.pipe(outgoing);
  });
  forwarded.setTimeout(TIMEOUT_MS, () => forwarded.destroy(new Error("provider timeout")));
  forwarded.on("error", () => { if (!outgoing.headersSent) outgoing.writeHead(502); outgoing.end(); });
  incoming.pipe(forwarded);
});
providerGateway.maxHeadersCount = 64;
providerGateway.headersTimeout = 10000;
providerGateway.requestTimeout = TIMEOUT_MS;
await new Promise((resolve, reject) => { providerGateway.once("error", reject); providerGateway.listen(0, "127.0.0.1", resolve); });
const gatewayAddress = providerGateway.address();
if (!gatewayAddress || typeof gatewayAddress === "string") await fail("provider gateway did not start");
turnRequest.model = {
  ...(turnRequest.model ?? {}),
  id: process.env.WORKJET_MODEL,
  provider: "ctox-gateway",
  api: "openai-responses",
  baseUrl: `http://127.0.0.1:${gatewayAddress.port}${gatewayPath || "/"}`
};
const requestLine = JSON.stringify(turnRequest);
const cleanEnvironment = {HOME: process.env.HOME ?? "", PATH: process.env.PATH ?? "/usr/bin:/bin", TMPDIR: privateDirectory};
if (sandboxRequested) {
  const sandboxExecutable = manifest.bubblewrapExecutable;
  if (manifest.sandbox !== "bubblewrap" || typeof sandboxExecutable !== "string" || !path.isAbsolute(sandboxExecutable)) {
    await fail("sandbox was requested but no verified bubblewrap executable is recorded");
  }
  try { fs.accessSync(sandboxExecutable, fs.constants.X_OK); } catch { await fail("recorded bubblewrap executable is unavailable"); }
  const sandboxArguments = [
    "--die-with-parent", "--new-session", "--unshare-pid", "--unshare-ipc", "--unshare-uts",
    "--ro-bind", "/", "/", "--bind", privateDirectory, privateDirectory,
    "--proc", "/proc", "--dev", "/dev", "--chdir", release,
    process.execPath, daemonFile, socketPath
  ];
  // Network is intentionally not unshared because the model gateway must remain reachable.
  daemon = spawn(sandboxExecutable, sandboxArguments, {cwd: release, env: cleanEnvironment, stdio: ["ignore", "ignore", "ignore"]});
} else {
  daemon = spawn(process.execPath, [daemonFile, socketPath], {cwd: release, env: cleanEnvironment, stdio: ["ignore", "ignore", "ignore"]});
}
const deadline = Date.now() + 5000;
while (!fs.existsSync(socketPath)) {
  if (daemon.exitCode !== null) await fail("sidecar exited before socket became ready");
  if (Date.now() >= deadline) await fail("sidecar socket timeout");
  await new Promise(resolve => setTimeout(resolve, 25));
}
socket = net.createConnection(socketPath);
await new Promise((resolve, reject) => { socket.once("connect", resolve); socket.once("error", reject); });
socket.write(requestLine + "\n");
let response = Buffer.alloc(0);
const timer = setTimeout(() => socket.destroy(new Error("turn timeout")), TIMEOUT_MS);
try {
  for await (const chunk of socket) {
    response = Buffer.concat([response, chunk]);
    if (response.length > RESPONSE_LIMIT) throw new Error("response limit exceeded");
    const newline = response.indexOf(10);
    if (newline >= 0) { response = response.subarray(0, newline); break; }
  }
  JSON.parse(response.toString("utf8"));
  process.stdout.write(response);
  process.stdout.write("\n");
} catch (error) {
  clearTimeout(timer);
  await fail(error.message);
}
clearTimeout(timer);
clearTimeout(hardTimer);
await cleanup();
"""#
}

private struct DeploymentManifest: Codable {
    var schema: Int
    var version: String
    var contentHash: String
    var files: [String: String]
    var hostRuntimeBase64: String
    var nodeExecutable: String
    var inference: String
    var events: String
    var sandbox: String
    var bubblewrapExecutable: String?
}

private struct PreflightFacts {
    var os: String
    var arch: String
    var homeWritable: Bool
    var hasShell: Bool
    var nodeVersion: String
    var nodeMajor: Int
    var nodeExecutable: String
    var shaTool: String
    var bubblewrapExecutable: String?
}

public extension RemotePiBootstrapError {
    var isBlocked: Bool {
        switch self {
        case .preflightBlocked, .tailscaleUnavailable, .missingKnownHosts, .sshServiceUnavailable, .sshConnectionTimedOut: return true
        default: return false
        }
    }
}
