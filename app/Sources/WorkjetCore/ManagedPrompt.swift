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
    public static let progressBoardStem = "<!-- WORKJET PROGRESS BOARD"
    public static let progressBoardBeginMarker = "\(progressBoardStem) BEGIN -->"
    public static let progressBoardEndMarker = "<!-- WORKJET PROGRESS BOARD END -->"

    public static func workerBody(
        configuration: WorkjetConfiguration,
        includeModelPrompts: Bool = true,
        includeWorkerInstructions: Bool = true
    ) -> Data {
        let computers = Dictionary(uniqueKeysWithValues: configuration.computers.map { ($0.id, $0) })
        let providers = Dictionary(uniqueKeysWithValues: configuration.providers.map { ($0.id, $0) })
        var lines = ["## Progress Board", "", progressBoardBeginMarker]
        let progressBoard = configuration.progressBoardRules?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !progressBoard.isEmpty { lines.append(safeMultilineInstructions(progressBoard)) }
        lines += [
            progressBoardEndMarker,
            "",
            "## Worker",
            ""
        ]
        var renderedModels = Set<String>()
        for worker in configuration.workers {
            lines += workerConfigurationLines(for: worker, computers: computers, providers: providers, configuration: configuration)
            lines.append("")
            if includeModelPrompts {
                let canonical = ModelPromptCatalog.canonicalName(for: worker.model)
                if !canonical.isEmpty,
                   renderedModels.insert(canonical).inserted,
                   let prompt = configuration.modelPrompts?[canonical]?.trimmingCharacters(in: .whitespacesAndNewlines),
                   !prompt.isEmpty {
                    lines += [
                        "#### Modellregeln · \(safeInline(canonical))",
                        "<!-- WORKJET MODEL PROMPT BEGIN \(safeInline(canonical)) -->",
                        safeMultilineInstructions(prompt),
                        "<!-- WORKJET MODEL PROMPT END \(safeInline(canonical)) -->",
                        ""
                    ]
                }
            }
            if includeWorkerInstructions {
                lines += [
                    "#### Aufgabe dieses Workers",
                    "<!-- WORKJET WORKER INSTRUCTIONS BEGIN \(worker.mentionTag) -->",
                    safeMultilineInstructions(worker.instructions),
                    "<!-- WORKJET WORKER INSTRUCTIONS END \(worker.mentionTag) -->",
                    ""
                ]
            }
        }
        lines += ["## Ad-hoc Learnings", ""]
        let learnings = configuration.adHocLearnings?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !learnings.isEmpty { lines += [safeMultilineInstructions(learnings), ""] }
        lines += ["## Technische Regeln", ""]
        let technical = configuration.technicalRules?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !technical.isEmpty { lines.append(safeMultilineInstructions(technical)) }
        return Data(lines.joined(separator: "\n").trimmingCharacters(in: .newlines).utf8)
    }

    /// Exact generated block inserted for this worker in the managed prompt.
    /// Settings renders this value verbatim so generated facts have a visible source.
    public static func generatedWorkerConfiguration(for worker: Worker, configuration: WorkjetConfiguration) -> String {
        let computers = Dictionary(uniqueKeysWithValues: configuration.computers.map { ($0.id, $0) })
        let providers = Dictionary(uniqueKeysWithValues: configuration.providers.map { ($0.id, $0) })
        return workerConfigurationLines(for: worker, computers: computers, providers: providers, configuration: configuration)
            .joined(separator: "\n")
    }

    private static func workerConfigurationLines(
        for worker: Worker,
        computers: [UUID: Computer],
        providers: [UUID: Provider],
        configuration: WorkjetConfiguration
    ) -> [String] {
        let adapter = HarnessAdapterRegistry.descriptor(for: worker.harness)
        let target = computers[worker.computerID]?.name ?? "Unbekannter Computer"
        let effort = worker.reasoningEffort?.rawValue ?? "automatisch"
        var lines = [
            "### \(worker.mentionTag) — \(safeInline(worker.name))",
            "- ID: `\(worker.id.uuidString.lowercased())`",
            "- Modell: `\(safeInline(worker.model))`",
            "- Reasoning: `\(effort)`",
            "- Harness: \(adapter.displayName)",
            "- Invocation-Protokoll: `\(adapter.invocationProtocol.rawValue)` (App-Fakt; nicht direkt ausführen)",
            "- Ziel-Computer: \(safeInline(target)) (`\(worker.computerID.uuidString.lowercased())`)",
            "- Anbieter/Zugangsroute: \(providerDescription(for: worker, providers: providers))",
            "- Fähigkeiten: \(worker.invocation.capabilities.isEmpty ? "Keine deklariert" : worker.invocation.capabilities.map(safeInline).joined(separator: "; "))",
            "- Skills (konfiguriert): \(safeInline(WorkerSkillCatalog.configuredDescription(for: worker)))",
            "- Skills (effektiv): \(safeInline(WorkerSkillCatalog.effectiveDescription(for: worker))) (Konfigurationsfakt; keine Aussage über Binärverfügbarkeit oder erfolgreiche Nutzung)",
            "- Executable: `\(safeInline(worker.invocation.executable))` (App-Fakt; nicht direkt ausführen)",
            "- Argumente: \(argumentDescription(worker.invocation.arguments)) (App-Fakt; nicht direkt ausführen)",
            "- Harness-Optionen: \(optionDescription(worker.invocation.options)) (App-Fakt; nicht direkt ausführen)"
        ]
        let runtime = runtimeNotes(for: worker, configuration: configuration)
        if !runtime.isEmpty { lines += ["", runtime] }
        return lines
    }

    /// Generated facts are derived exclusively from the editable Worker and
    /// Computer settings. They are exposed in the collapsed technical section
    /// of Settings and are never an invisible second policy source.
    public static func runtimeNotes(for worker: Worker, configuration: WorkjetConfiguration) -> String {
        guard worker.harness == .piSidecar else { return "" }
        guard let computer = configuration.computers.first(where: { $0.id == worker.computerID }) else {
            return "- Pi-Laufzeit: Ziel-Computer ist nicht verfügbar."
        }
        if computer.isLocal {
            return "- Pi-Laufzeit: Workjet fragt Ereignisse mit `workjet events` über einen exklusiven Sequenz-Cursor ab; das ist kein direkter Live-Stream und keine behauptete Host-Build-/Test-Autorität."
        }
        return [
            "- Remote-Status: \(remotePiTruth(computer))",
            "- Remote-Ausführung: Workjet prüft die Installation, löst die Anbieterroute auf, richtet bei Bedarf den laufbezogenen Gateway-Relay ein und startet Pi Code über den Remote-Adapter. Fable verwendet dafür ausschließlich `workjet run` und liest Ereignisse ausschließlich mit `workjet events`.",
            "- App-Remote-Fakten (sichtbar, nicht direkt ausführen): \(remotePiTechnicalFacts(computer))"
        ].joined(separator: "\n")
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

    private static func providerDescription(for worker: Worker, providers: [UUID: Provider]) -> String {
        switch worker.providerRoute {
        case let .account(id):
            guard let provider = providers[id] else {
                return "Nicht verfügbar (`\(id.uuidString.lowercased())`)"
            }
            let route = providerDescription(provider)
            if provider.modelProvider?.usesWebLogin == true, provider.kind.isLocalGateway {
                return "\(route). CLIProxy verwaltet diesen Zugang im gemeinsamen Gateway-Pool; Workjet kann keinen einzelnen OAuth-Account pro Anfrage pinnen."
            }
            return route
        case let .pool(modelProvider):
            let accounts = Provider.deterministicPool(Array(providers.values), for: modelProvider)
            guard !accounts.isEmpty else {
                return "Pool \(safeInline(modelProvider.rawValue)): nicht verfügbar (kein Zugang konfiguriert)."
            }
            let order = accounts.enumerated().map { index, account in
                "\(index + 1). \(safeInline(account.name)) (`\(account.id.uuidString.lowercased())`)"
            }.joined(separator: " → ")
            let directCount = accounts.count(where: { !$0.kind.isLocalGateway })
            let gatewayCount = accounts.count - directCount
            if directCount == 0 {
                return "Pool \(safeInline(modelProvider.rawValue)); \(gatewayCount) OAuth-Zugänge im gemeinsamen CLIProxy-Gateway-Pool: \(order). Die Liste ist Workjets stabile Konfigurationsansicht, nicht die Laufzeitreihenfolge. CLIProxy wählt und wechselt den Zugang nach seiner eigenen konfigurierten Routingstrategie; Workjet kann keinen einzelnen OAuth-Account pro Anfrage festlegen."
            }
            let gateway = gatewayCount == 0 ? "" : " Zusätzlich existiert genau ein proxyverwalteter Gateway-Pool ohne Account-Pinning."
            return "Pool \(safeInline(modelProvider.rawValue)); deterministische Reihenfolge der direkten Zugänge: \(order). Workjet wechselt einen direkten Zugang nur nach eindeutig erkanntem Auth-, Quota- oder Rate-Limit-Fehler; Task-, Transport-, Timeout- und generische Serverfehler wechseln den Zugang nicht.\(gateway)"
        case nil:
            return "Nicht konfiguriert"
        }
    }

    private static func providerDescription(_ provider: Provider) -> String {
        let endpoint = provider.endpoint.trimmingCharacters(in: .whitespacesAndNewlines)
        let route: String
        if let sanitizedEndpoint = safeEndpointDescription(endpoint) { route = "\(provider.kind.rawValue) über \(sanitizedEndpoint)" }
        else { route = provider.kind.rawValue }
        return "\(safeInline(provider.name)), \(route)"
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
            deployment = "Pi Code \(PiSidecarRuntime.version) ist als Inhalt `\(safeInline(hash))` bereitgestellt."
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
        return "\(deployment) \(sandbox) Für CLIProxy-Zugänge richtet Workjet pro Lauf einen Loopback-Relay mit flüchtigem Gateway-Schlüssel ein. Direkte API-Secrets werden flüchtig über die verschlüsselte Request-/Monitor-Pipe zugestellt. OAuth-Dateien, OAuth-Tokens, Keychain-Inhalte und Run-Secrets werden weder kopiert noch auf dem Remote-Computer gespeichert. Fable verwendet ausschließlich die Workjet-CLI und führt kein Transportprotokoll selbst aus. Ereignisse werden mit exklusivem Cursor abgefragt; es gibt keinen WebSocket- oder behaupteten Pi-Live-Stream. Fable bleibt für Integration und Verifikation verantwortlich."
    }

    private static func remotePiTechnicalFacts(_ computer: Computer) -> String {
        let sandbox = computer.sandboxEnabled
            ? "Der App-Runner `'node' '.local/lib/workjet/current/workjet-pi-turn.mjs' '--sandbox'` aktiviert `--sandbox` ausdrücklich und darf bei fehlendem Bubblewrap nicht unsandboxed weiterlaufen."
            : "Der App-Runner aktiviert keine OS-Sandbox; diese deaktivierte Grenze bleibt sichtbar."
        let transport = computer.transport == .ssh
            ? "Die App erzwingt beim SSH-Transport `StrictHostKeyChecking=yes` mit der privaten Known-Hosts-Datei."
            : "Die App verwendet den bestätigten Tailscale-Transport."
        return "\(sandbox) \(transport) Diese Fakten beschreiben ausschließlich die interne App-Ausführung."
    }

    private static func safeMultilineInstructions(_ value: String) -> String {
        value
            .replacingOccurrences(of: beginStem, with: "WORKJET-MANAGED-WORKERS-BEGIN")
            .replacingOccurrences(of: endMarker, with: "WORKJET-MANAGED-WORKERS-END")
            .replacingOccurrences(of: "<!-- WORKJET WORKER INSTRUCTIONS", with: "WORKJET-WORKER-INSTRUCTIONS")
            .replacingOccurrences(of: progressBoardStem, with: "WORKJET-PROGRESS-BOARD")
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

    private static func optionDescription(_ options: [String: String]) -> String {
        guard !options.isEmpty else { return "Keine" }
        return options.keys.sorted().map { key in
            "`\(safeInline(key))=\(safeInline(options[key] ?? ""))`"
        }.joined(separator: ", ")
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
