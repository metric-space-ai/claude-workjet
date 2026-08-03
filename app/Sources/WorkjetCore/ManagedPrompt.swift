import CryptoKit
import Darwin
import Foundation

public struct ManagedPromptDocument: Equatable, Sendable {
    public var prefix: Data
    public var body: Data?
    public var suffix: Data
    public var blockRange: Range<Data.Index>?
}

public enum ManagedPrompt {
    public static let beginStem = "<!-- WORKJET MANAGED WORKERS BEGIN"
    public static let endMarker = "<!-- WORKJET MANAGED WORKERS END v1 -->"

    public static func workerBody(configuration: WorkjetConfiguration) -> Data {
        let computers = Dictionary(uniqueKeysWithValues: configuration.computers.map { ($0.id, $0) })
        let providers = Dictionary(uniqueKeysWithValues: configuration.providers.map { ($0.id, $0) })
        var lines = [
            "## Verwaltete Workjet-Worker · automatisch erzeugt · nicht editierbar",
            "Fable (Claude Code) bleibt der einzige Orchestrator. Fable wählt und invokiert pro Delegation genau einen deklarierten Worker; die Workjet-App wählt keine Worker, baut keine Workflows und fällt niemals stillschweigend zurück.",
            "Infrastruktur: höchstens \(configuration.providerSlots) parallele Aufrufe je Provider; Probe-Timeout \(configuration.probeTimeoutSeconds) s; Turn-Timeout \(configuration.turnTimeoutSeconds) s; Degradation \(configuration.degradationAllowed ? "nur nach expliziter Freigabe zulässig" : "nicht zulässig").",
            ""
        ]
        for worker in configuration.workers {
            let computer = computers[worker.computerID]
            let target = computer?.name ?? "Unbekannter Computer"
            let providerRoute = providerDescription(worker.providerID, providers: providers)
            let capabilityTruth: String
            let invocationTruth: String
            if computer?.isLocal == true && worker.harness == .claudeCode {
                capabilityTruth = "Lokaler Claude-Code-Wrapper; lokale Stream-Artefakte können live erkannt werden, sofern der Dispatcher sie schreibt."
                invocationTruth = "Ausführbare Datei `\(safeInline(worker.invocation.executable))` mit Argumenten \(argumentDescription(worker.invocation.arguments)); Brief ersetzt `<WORKJET_BRIEF>`, stdin ist `/dev/null`."
            } else if worker.harness == .piSidecar, let computer, !computer.isLocal {
                capabilityTruth = remotePiTruth(computer)
                invocationTruth = remotePiInvocation(computer)
            } else if worker.harness == .piSidecar {
                capabilityTruth = "Pi-Code-Ereignisse sind derzeit nur post-hoc verfügbar; keine Live-Events und keine behauptete Host-Build-/Test-Autorität."
                invocationTruth = "Ausführbare Datei `\(safeInline(worker.invocation.executable))` mit Argumenten \(argumentDescription(worker.invocation.arguments))."
            } else {
                capabilityTruth = "Remote-Claude-Code-Ausführung ist in dieser App nicht implementiert; keine Live-Events und keine behauptete Host-Build-/Test-Autorität."
                invocationTruth = "Nicht verfügbar."
            }
            let effort = worker.reasoningEffort?.rawValue ?? "automatisch"
            let effortTruth = worker.reasoningEffort == nil
                ? "Kein fester Effort; Fable verwendet den Harness-Standard."
                : "Fable muss den konfigurierten Effort `\(effort)` beim Aufruf passend zum Harness weitergeben; Workjet verändert keine frei konfigurierten Executable-Argumente."
            lines += [
                "### \(worker.mentionTag) — \(safeInline(worker.name))",
                "- ID: `\(worker.id.uuidString.lowercased())`",
                "- Modell: `\(safeInline(worker.model))`",
                "- Reasoning: `\(effort)` — \(effortTruth)",
                "- Harness: \(worker.harness.rawValue)",
                "- Ziel-Computer: \(safeInline(target)) (`\(worker.computerID.uuidString.lowercased())`)",
                "- Anbieter/Zugangsroute: \(providerRoute)",
                "- Fähigkeiten: \(worker.invocation.capabilities.isEmpty ? "Keine deklariert" : worker.invocation.capabilities.map(safeInline).joined(separator: "; "))",
                "- Aktueller Status: \(capabilityTruth)",
                "- Invocation: \(invocationTruth)",
                "",
                "<!-- WORKJET WORKER INSTRUCTIONS BEGIN \(worker.mentionTag) -->",
                safeMultilineInstructions(worker.instructions),
                "<!-- WORKJET WORKER INSTRUCTIONS END \(worker.mentionTag) -->",
                ""
            ]
        }
        return Data(lines.joined(separator: "\n").trimmingCharacters(in: .newlines).utf8)
    }

    public static func unresolvedMentions(in instructions: String, workers: [Worker]) -> [String] {
        let known = Set(workers.map(\.mentionTag))
        guard let regex = try? NSRegularExpression(pattern: #"@[\p{L}\p{N}_-]+"#) else { return [] }
        let range = NSRange(instructions.startIndex..., in: instructions)
        var seen = Set<String>()
        return regex.matches(in: instructions, range: range).compactMap { match in
            guard let range = Range(match.range, in: instructions) else { return nil }
            let mention = String(instructions[range])
            guard !known.contains(mention), seen.insert(mention).inserted else { return nil }
            return mention
        }
    }

    public static func block(body: Data) -> Data {
        let hash = SHA256.hash(data: body).map { String(format: "%02x", $0) }.joined()
        var result = Data("<!-- WORKJET MANAGED WORKERS BEGIN v1 sha256=\(hash) -->\n".utf8)
        result.append(body)
        result.append(Data("\n\(endMarker)".utf8))
        return result
    }

    public static func parse(_ data: Data) throws -> ManagedPromptDocument {
        guard let text = String(data: data, encoding: .utf8) else { throw LocalStateError.promptMalformed("Datei ist nicht UTF-8") }
        let beginCount = text.components(separatedBy: beginStem).count - 1
        let endCount = text.components(separatedBy: endMarker).count - 1
        if beginCount == 0 && endCount == 0 { return ManagedPromptDocument(prefix: data, body: nil, suffix: Data(), blockRange: nil) }
        guard beginCount == 1, endCount == 1 else { throw LocalStateError.promptMalformed("doppelte, fehlende oder verschachtelte Marker") }
        guard let beginStemRange = text.range(of: beginStem), let beginLineEnd = text[beginStemRange.lowerBound...].firstIndex(of: "\n"), let endRange = text.range(of: endMarker), beginLineEnd < endRange.lowerBound else {
            throw LocalStateError.promptMalformed("Marker-Reihenfolge oder Zeilenform")
        }
        let beginOnOwnLine = beginStemRange.lowerBound == text.startIndex || text[text.index(before: beginStemRange.lowerBound)] == "\n"
        let endOnOwnLine = endRange.upperBound == text.endIndex || text[endRange.upperBound] == "\n"
        guard beginOnOwnLine, endOnOwnLine else { throw LocalStateError.promptMalformed("Marker müssen jeweils eine vollständige eigene Zeile bilden") }
        let beginLine = String(text[beginStemRange.lowerBound..<beginLineEnd])
        let pattern = #"^<!-- WORKJET MANAGED WORKERS BEGIN v1 sha256=([0-9a-f]{64}) -->$"#
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: beginLine, range: NSRange(beginLine.startIndex..., in: beginLine)),
              match.range.location != NSNotFound,
              let hashRange = Range(match.range(at: 1), in: beginLine) else {
            throw LocalStateError.promptMalformed("BEGIN-Marker hat nicht die exakte v1-Form")
        }
        guard endRange.lowerBound > text.startIndex, text[text.index(before: endRange.lowerBound)] == "\n" else {
            throw LocalStateError.promptMalformed("END-Marker muss auf eigener Zeile stehen")
        }
        let bodyStart = text.index(after: beginLineEnd)
        let bodyEnd = text.index(before: endRange.lowerBound)
        let body = Data(text[bodyStart..<bodyEnd].utf8)
        let actual = SHA256.hash(data: body).map { String(format: "%02x", $0) }.joined()
        guard actual == String(beginLine[hashRange]) else { throw LocalStateError.promptHashMismatch }
        let blockEnd = endRange.upperBound
        let prefix = Data(text[..<beginStemRange.lowerBound].utf8)
        let suffix = Data(text[blockEnd...].utf8)
        let startOffset = text.utf8.distance(from: text.utf8.startIndex, to: beginStemRange.lowerBound.samePosition(in: text.utf8)!)
        let endOffset = text.utf8.distance(from: text.utf8.startIndex, to: blockEnd.samePosition(in: text.utf8)!)
        return ManagedPromptDocument(prefix: prefix, body: body, suffix: suffix, blockRange: startOffset..<endOffset)
    }

    public static func replacingManagedBlock(in original: Data, body: Data) throws -> Data {
        let document = try parse(original)
        let generated = block(body: body)
        if let range = document.blockRange {
            var result = original
            result.replaceSubrange(range, with: generated)
            return result
        }
        var result = original
        if !result.isEmpty && result.last != 0x0A { result.append(0x0A) }
        if !result.isEmpty { result.append(0x0A) }
        result.append(generated)
        return result
    }

    public static func handwrittenContent(from data: Data) throws -> String {
        let document = try parse(data)
        var outside = document.prefix
        outside.append(document.suffix)
        guard let value = String(data: outside, encoding: .utf8) else { throw LocalStateError.promptMalformed("Handschriftlicher Inhalt ist nicht UTF-8") }
        return value.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    public static func replacingHandwrittenContent(in original: Data, rules: String, body: Data) throws -> Data {
        _ = try parse(original)
        guard !rules.contains(beginStem), !rules.contains(endMarker) else {
            throw LocalStateError.promptMalformed("Handschriftlicher Inhalt darf keine verwalteten Marker enthalten")
        }
        var result = Data(rules.trimmingCharacters(in: .whitespacesAndNewlines).utf8)
        if !result.isEmpty { result.append(Data("\n\n".utf8)) }
        result.append(block(body: body))
        return result
    }

    private static func providerDescription(_ id: UUID?, providers: [UUID: Provider]) -> String {
        guard let id else { return "Nicht konfiguriert (nicht verfügbar)." }
        guard let provider = providers[id] else {
            return "Referenz `\(id.uuidString.lowercased())` ist gelöscht oder nicht verfügbar; niemals automatisch ersetzen."
        }
        let endpoint = provider.endpoint.trimmingCharacters(in: .whitespacesAndNewlines)
        let route: String
        if let sanitizedEndpoint = safeEndpointDescription(endpoint) { route = "\(provider.kind.rawValue) über \(sanitizedEndpoint)" }
        else { route = provider.kind.rawValue }
        let authentication = provider.kind.isLocalGateway
            ? "OAuth/Abonnement wird im lokalen Gateway verwaltet."
            : "Ein optionaler API-Zugang bleibt ausschließlich in der lokalen Keychain."
        return "\(safeInline(provider.name)), \(route). \(authentication)"
    }

    private static func safeEndpointDescription(_ endpoint: String) -> String? {
        guard !endpoint.isEmpty, var components = URLComponents(string: endpoint), components.scheme != nil, components.host != nil else { return nil }
        components.user = nil
        components.password = nil
        components.query = nil
        components.fragment = nil
        return components.string.map(safeInline)
    }

    private static func remotePiTruth(_ computer: Computer) -> String {
        let deployment: String
        if computer.deploymentStatus == .installed,
           computer.installedSidecarVersion == PiSidecarRuntime.version,
           let hash = computer.installedContentHash {
            deployment = "Sidecar \(PiSidecarRuntime.version) ist als Inhalt `\(safeInline(hash))` bereitgestellt."
        } else {
            deployment = "Remote-Runner ist nicht bestätigt installiert (\(computer.deploymentStatus.rawValue)). Zuerst in Workjet „Prüfen & einrichten“ ausführen."
        }
        let sandbox: String
        if computer.sandboxEnabled {
            if let executable = computer.bubblewrapExecutablePath {
                sandbox = "Agent-Dateiwerkzeuge sehen nur den projizierten In-Memory-Snapshot; der Daemon läuft zusätzlich über die bestätigte Bubblewrap-OS-Sandbox `\(safeInline(executable))` mit read-only Host-Dateisystem und ausschließlich privatem Turn-Verzeichnis als beschreibbarem Arbeitsbereich. Netzwerk bleibt für Modell-Gateway-Zugriff verfügbar."
            } else {
                sandbox = "Minimal-Sandbox ist angefordert, aber noch kein ausführbares `bwrap` bestätigt; eine unsandboxed Ausführung ist nicht zulässig."
            }
        } else {
            sandbox = "Agent-Dateiwerkzeuge sehen nur den projizierten In-Memory-Snapshot. Die OS-Sandbox ist deaktiviert; der Daemon hat daher keine zusätzliche Betriebssystem-Dateisystemgrenze."
        }
        return "\(deployment) \(sandbox) Pi-Ereignisse kommen ausschließlich post-hoc in der finalen Antwort. Fable bleibt für lokale Integration und Verifikation verantwortlich. Remote-Echtmodell-Inferenz ist ohne separaten Loopback-Relay nicht verfügbar; es werden keine CLIProxy-, API-, OAuth- oder Keychain-Geheimnisse übertragen. Faux-/Offline-Turns sind zur Prüfung zulässig."
    }

    private static func remotePiInvocation(_ computer: Computer) -> String {
        guard computer.deploymentStatus == .installed,
              computer.installedSidecarVersion == PiSidecarRuntime.version,
              (!computer.sandboxEnabled || computer.bubblewrapExecutablePath?.hasPrefix("/") == true),
              (try? RemoteCommandBuilder.validate(computer)) != nil else {
            return "Nicht verfügbar, bis „Prüfen & einrichten“ eine gültige Installation und – falls aktiviert – ein ausführbares `bwrap` bestätigt hat."
        }
        var remoteRunner = ["node", ".local/lib/workjet/current/workjet-pi-turn.mjs"]
        if computer.sandboxEnabled { remoteRunner.append("--sandbox") }
        let tokens: [String]
        switch computer.transport {
        case .ssh:
            guard computer.knownHostsPath.hasPrefix("/") else { return "Nicht verfügbar: private known-hosts-Datei fehlt." }
            tokens = [
                "/usr/bin/ssh", "-o", "BatchMode=yes", "-o", "ConnectTimeout=10", "-o", "StrictHostKeyChecking=yes",
                "-o", "UserKnownHostsFile=\(computer.knownHostsPath)", "-o", "ClearAllForwardings=yes", "-p", String(computer.port),
                "-l", computer.user, "--", computer.host
            ] + remoteRunner
        case .tailscale:
            guard let executable = computer.tailscaleExecutablePath, AllowlistedTailscaleLocator.allowedPaths.contains(executable) else {
                return "Nicht verfügbar: das bestätigte Tailscale-Executable fehlt. Erneut „Prüfen & einrichten“ ausführen."
            }
            tokens = [executable, "ssh", "\(computer.user)@\(computer.host)"] + remoteRunner
        case .local:
            return "Nicht als Remote-Invocation verfügbar."
        }
        let transport = tokens.map(shellQuoted).joined(separator: " ")
        let sandbox = computer.sandboxEnabled
            ? "Die Invocation aktiviert `--sandbox` ausdrücklich; der Runner darf bei fehlendem Bubblewrap nicht unsandboxed degradieren."
            : "Die Invocation aktiviert keine OS-Sandbox; diese deaktivierte Grenze wird ausdrücklich beibehalten."
        return "Fable erzeugt den aktuellen `CtoxTurnRequest`-JSON-Snapshot als genau eine NDJSON-Zeile und leitet ihn über stdin an `\(transport)` weiter. \(sandbox) Genau eine finale NDJSON-Antwort wird über stdout empfangen; darin enthaltene Pi-Ereignisse sind post-hoc."
    }

    private static func shellQuoted(_ value: String) -> String {
        let singleLine = value.split(whereSeparator: \.isNewline).joined(separator: " ")
        return "'" + singleLine.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    private static func safeMultilineInstructions(_ value: String) -> String {
        value
            .replacingOccurrences(of: beginStem, with: "WORKJET-MANAGED-WORKERS-BEGIN")
            .replacingOccurrences(of: endMarker, with: "WORKJET-MANAGED-WORKERS-END")
    }

    private static func safeInline(_ value: String) -> String {
        value.split(whereSeparator: \.isNewline).joined(separator: " ")
            .replacingOccurrences(of: beginStem, with: "WORKJET-MANAGED-WORKERS-BEGIN")
            .replacingOccurrences(of: endMarker, with: "WORKJET-MANAGED-WORKERS-END")
            .replacingOccurrences(of: "`", with: "\\`")
            .trimmingCharacters(in: .whitespaces)
    }

    private static func argumentDescription(_ arguments: [String]) -> String {
        "[" + arguments.map { "`\(safeInline($0))`" }.joined(separator: ", ") + "]"
    }
}

public protocol PromptSynchronizing: Sendable {
    func loadHandwrittenRules() throws -> String?
    func synchronize(_ configuration: WorkjetConfiguration, handwrittenChanged: Bool) throws
}

public struct ManagedPromptStore: PromptSynchronizing, Sendable {
    public let fileURL: URL
    public var lockURL: URL { fileURL.deletingLastPathComponent().appendingPathComponent(".\(fileURL.lastPathComponent).workjet.lock") }
    public init(fileURL: URL) { self.fileURL = fileURL }

    public func loadHandwrittenRules() throws -> String? {
        try withLock {
            guard FileManager.default.fileExists(atPath: fileURL.path) else { return nil }
            return try ManagedPrompt.handwrittenContent(from: SecureFile.readRegularOwnedFile(at: fileURL))
        }
    }

    public func synchronize(_ configuration: WorkjetConfiguration, handwrittenChanged: Bool) throws {
        try withLock {
            let body = ManagedPrompt.workerBody(configuration: configuration)
            let original: Data
            if FileManager.default.fileExists(atPath: fileURL.path) {
                original = try SecureFile.readRegularOwnedFile(at: fileURL)
                _ = try ManagedPrompt.parse(original) // validate the current marker/hash while holding the stable lock
            } else {
                original = Data(configuration.skillRules.utf8)
            }
            let updated = handwrittenChanged
                ? try ManagedPrompt.replacingHandwrittenContent(in: original, rules: configuration.skillRules, body: body)
                : try ManagedPrompt.replacingManagedBlock(in: original, body: body)
            if FileManager.default.fileExists(atPath: fileURL.path) {
                try SecureFile.checkRegularOwnedFile(at: fileURL)
            }
            try AtomicFile.write(updated, to: fileURL, directoryMode: 0o700, fileMode: 0o600)
        }
    }

    private func withLock<T>(_ body: () throws -> T) throws -> T {
        let directory = lockURL.deletingLastPathComponent()
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            _ = chmod(directory.path, 0o700)
        } catch { throw LocalStateError.io(error.localizedDescription) }
        let fd = open(lockURL.path, O_RDWR | O_CREAT | O_NOFOLLOW, 0o600)
        guard fd >= 0 else {
            if errno == ELOOP { throw LocalStateError.insecurePath(lockURL.path) }
            throw LocalStateError.io(String(cString: strerror(errno)))
        }
        defer { close(fd) }
        var info = stat()
        guard fstat(fd, &info) == 0 else { throw LocalStateError.io(String(cString: strerror(errno))) }
        guard (info.st_mode & S_IFMT) == S_IFREG, (info.st_mode & 0o077) == 0 else { throw LocalStateError.insecurePath(lockURL.path) }
        guard info.st_uid == geteuid() else { throw LocalStateError.wrongOwner(lockURL.path) }
        guard flock(fd, LOCK_EX) == 0 else { throw LocalStateError.io(String(cString: strerror(errno))) }
        defer { _ = flock(fd, LOCK_UN) }
        // A path swap after open must not turn the stable lock into an attacker-controlled file.
        var pathInfo = stat()
        guard lstat(lockURL.path, &pathInfo) == 0,
              (pathInfo.st_mode & S_IFMT) == S_IFREG,
              (pathInfo.st_mode & 0o077) == 0,
              pathInfo.st_uid == geteuid(),
              pathInfo.st_dev == info.st_dev,
              pathInfo.st_ino == info.st_ino else {
            throw LocalStateError.insecurePath(lockURL.path)
        }
        return try body()
    }
}
