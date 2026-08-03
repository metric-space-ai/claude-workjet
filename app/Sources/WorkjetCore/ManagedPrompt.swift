import CryptoKit
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
        guard configuration.injectWorkerDeclarations else {
            return Data("Fable bleibt der einzige Orchestrator. Es sind derzeit keine verwalteten Worker-Deklarationen aktiviert.".utf8)
        }
        let computers = Dictionary(uniqueKeysWithValues: configuration.computers.map { ($0.id, $0) })
        var lines = [
            "## Verwaltete Workjet-Worker",
            "Fable (Claude Code) bleibt der einzige Orchestrator. Fable wählt und invokiert pro Delegation genau einen deklarierten Worker; die Workjet-App wählt keine Worker, baut keine Workflows und fällt niemals stillschweigend zurück.",
            ""
        ]
        for worker in configuration.workers {
            let computer = computers[worker.computerID]
            let target = computer?.name ?? "Unbekannter Computer"
            let capabilityTruth: String
            if computer?.isLocal == true && worker.harness == .claudeCode {
                capabilityTruth = "Lokaler Claude-Code-Wrapper; lokale Stream-Artefakte können live erkannt werden, sofern der Dispatcher sie schreibt."
            } else if worker.harness == .piSidecar {
                capabilityTruth = "Pi-Ereignisse sind derzeit nur post-hoc verfügbar; keine Live-Events und keine behauptete Host-Build-/Test-Autorität."
            } else {
                capabilityTruth = "Remote-Ausführung ist in dieser App nicht implementiert; keine Live-Events und keine behauptete Host-Build-/Test-Autorität."
            }
            lines += [
                "### \(safeInline(worker.name))",
                "- ID: `\(worker.id.uuidString.lowercased())`",
                "- Modell: `\(safeInline(worker.model))`",
                "- Harness: \(worker.harness.rawValue)",
                "- Ziel-Computer: \(safeInline(target)) (`\(worker.computerID.uuidString.lowercased())`)",
                "- Anweisungen: \(safeInline(worker.instructions))",
                "- Fähigkeiten: \(worker.invocation.capabilities.isEmpty ? "Keine deklariert" : worker.invocation.capabilities.map(safeInline).joined(separator: "; "))",
                "- Aktueller Status: \(capabilityTruth)",
                "- Invocation: ausführbare Datei `\(safeInline(worker.invocation.executable))` mit Argumenten \(argumentDescription(worker.invocation.arguments)); Brief ersetzt `<WORKJET_BRIEF>`, stdin ist `/dev/null`.",
                ""
            ]
        }
        return Data(lines.joined(separator: "\n").trimmingCharacters(in: .newlines).utf8)
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
    public init(fileURL: URL) { self.fileURL = fileURL }

    public func loadHandwrittenRules() throws -> String? {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return nil }
        try SecureFile.checkRegularOwnedFile(at: fileURL)
        return try ManagedPrompt.handwrittenContent(from: Data(contentsOf: fileURL))
    }

    public func synchronize(_ configuration: WorkjetConfiguration, handwrittenChanged: Bool) throws {
        let body = ManagedPrompt.workerBody(configuration: configuration)
        let original: Data
        if FileManager.default.fileExists(atPath: fileURL.path) {
            try SecureFile.checkRegularOwnedFile(at: fileURL)
            original = try Data(contentsOf: fileURL)
        } else {
            original = Data(configuration.skillRules.utf8)
        }
        let updated = handwrittenChanged
            ? try ManagedPrompt.replacingHandwrittenContent(in: original, rules: configuration.skillRules, body: body)
            : try ManagedPrompt.replacingManagedBlock(in: original, body: body)
        try AtomicFile.write(updated, to: fileURL, directoryMode: 0o700, fileMode: 0o600)
    }
}
