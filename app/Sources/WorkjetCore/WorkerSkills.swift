import Foundation

/// Metadata for one centrally managed worker skill. Worker persistence stores
/// only sparse ID-based overrides, so extending this catalog does not change
/// the Worker schema.
public struct WorkerSkillDescriptor: Identifiable, Equatable, Sendable {
    public var id: String
    public var displayName: String
    public var description: String
    public var defaultEnabled: Bool
    public var compatibleHarnesses: [Harness]
    public var incompatibilityDescriptions: [Harness: String]

    public init(
        id: String,
        displayName: String,
        description: String,
        defaultEnabled: Bool,
        compatibleHarnesses: [Harness],
        incompatibilityDescriptions: [Harness: String] = [:]
    ) {
        self.id = id
        self.displayName = displayName
        self.description = description
        self.defaultEnabled = defaultEnabled
        self.compatibleHarnesses = compatibleHarnesses
        self.incompatibilityDescriptions = incompatibilityDescriptions
    }

    public func isCompatible(with harness: Harness) -> Bool {
        compatibleHarnesses.contains(harness)
    }

    public func configuredEnabled(overrides: [String: Bool]) -> Bool {
        overrides[id] ?? defaultEnabled
    }

    public func effectiveEnabled(overrides: [String: Bool], harness: Harness) -> Bool {
        isCompatible(with: harness) && configuredEnabled(overrides: overrides)
    }

    public func incompatibilityDescription(for harness: Harness) -> String {
        incompatibilityDescriptions[harness]
            ?? "Dieser Skill wird von \(harness.rawValue) derzeit nicht unterstützt."
    }
}

public enum WorkerSkillCatalog {
    public static let greppyID = "greppy"
    public static let greppyCapability = "greppy"
    public static let taskPromptBeginStem = "<!-- WORKJET WORKER SKILL BEGIN"
    public static let taskPromptEndStem = "<!-- WORKJET WORKER SKILL END"
    public static let promptSourceBeginStem = "<!-- WORKJET SKILL PROMPT SOURCE BEGIN"
    public static let promptSourceEndStem = "<!-- WORKJET SKILL PROMPT SOURCE END"

    public static let all: [WorkerSkillDescriptor] = [
        WorkerSkillDescriptor(
            id: greppyID,
            displayName: "Greppy",
            description: "Code-Navigation über Symbolgraph und lokalen semantischen Index.",
            defaultEnabled: true,
            compatibleHarnesses: [.claudeCode, .codexCLI, .openCode],
            incompatibilityDescriptions: [
                .piSidecar: "Pi Code besitzt in V1 keine Host-Shell und kein Host-Dateisystem.",
                .cursorAgent: "Workjet hat für Cursor Agent noch keinen verifizierten lokalen Repository- und Shell-Ausführungsvertrag.",
                .grokCLI: "Workjet hat für Grok CLI noch keinen verifizierten lokalen Repository- und Shell-Ausführungsvertrag."
            ]
        )
    ]

    public static func descriptor(for id: String) -> WorkerSkillDescriptor? {
        all.first(where: { $0.id == id })
    }

    public static func configuredSkills(for worker: Worker) -> [WorkerSkillDescriptor] {
        all.filter { $0.configuredEnabled(overrides: worker.skillOverrides) }
    }

    public static func effectiveSkills(for worker: Worker) -> [WorkerSkillDescriptor] {
        all.filter { $0.effectiveEnabled(overrides: worker.skillOverrides, harness: worker.harness) }
    }

    /// Skills configured for this harness and verified as launch-available on
    /// the concrete target. Availability is deliberately supplied by the
    /// caller so catalog defaults can never be mistaken for runtime truth.
    public static func launchAvailableSkills(
        for worker: Worker,
        availableSkillIDs: Set<String>
    ) -> [WorkerSkillDescriptor] {
        effectiveSkills(for: worker).filter { availableSkillIDs.contains($0.id) }
    }

    /// Maps only verified remote probe capabilities to known skill IDs. A
    /// capability name is target evidence, not a configured default.
    public static func availableSkillIDs(verifiedCapabilities: [String]) -> Set<String> {
        var available: Set<String> = []
        if verifiedCapabilities.contains(greppyCapability) {
            available.insert(greppyID)
        }
        return available
    }

    public static func setConfiguredEnabled(
        _ enabled: Bool,
        skill: WorkerSkillDescriptor,
        overrides: inout [String: Bool]
    ) {
        if enabled == skill.defaultEnabled {
            overrides.removeValue(forKey: skill.id)
        } else {
            overrides[skill.id] = enabled
        }
    }

    /// Appends each configured, compatible, and target-available skill's
    /// published prompt as one marked task-input block. Existing marked blocks
    /// are retained and not duplicated, which is required by the ViewModel ->
    /// service bridge's two-stage remote launch. Callers must explicitly supply
    /// both repository truth and skill IDs established for this exact target.
    public static func taskInput(
        for worker: Worker,
        input: Data,
        repositoryAvailable: Bool,
        availableSkillIDs: Set<String>,
        technicalRules: String
    ) -> Data {
        guard repositoryAvailable else { return input }
        let skills = launchAvailableSkills(for: worker, availableSkillIDs: availableSkillIDs)
        guard !skills.isEmpty else { return input }

        let sourced = skills.compactMap { skill in
            technicalPrompt(for: skill.id, in: technicalRules).map { (skill, $0) }
        }
        guard !sourced.isEmpty else { return input }

        let existing = String(data: input, encoding: .utf8) ?? ""
        let missing = sourced.filter { !existing.contains(taskPromptBlock(skillID: $0.0.id, prompt: $0.1)) }
        guard !missing.isEmpty else { return input }

        var result = input
        if !result.isEmpty {
            if result.last != 0x0A { result.append(0x0A) }
            result.append(0x0A)
        }
        for (index, source) in missing.enumerated() {
            if index > 0 { result.append(Data("\n\n".utf8)) }
            result.append(Data(taskPromptBlock(skillID: source.0.id, prompt: source.1).utf8))
        }
        return result
    }

    public static func beginMarker(for id: String) -> String {
        "\(taskPromptBeginStem) \(id) -->"
    }

    public static func endMarker(for id: String) -> String {
        "\(taskPromptEndStem) \(id) -->"
    }

    public static func promptSourceBeginMarker(for id: String) -> String {
        "\(promptSourceBeginStem) \(id) -->"
    }

    public static func promptSourceEndMarker(for id: String) -> String {
        "\(promptSourceEndStem) \(id) -->"
    }

    /// Returns the exact visible bytes between the source markers. Missing or
    /// malformed source fails closed: the skill is not injected.
    public static func technicalPrompt(for id: String, in technicalRules: String) -> String? {
        let begin = promptSourceBeginMarker(for: id) + "\n"
        let end = promptSourceEndMarker(for: id)
        guard let beginRange = technicalRules.range(of: begin) else { return nil }
        let suffix = technicalRules[beginRange.upperBound...]
        guard let endRange = suffix.range(of: end),
              endRange.lowerBound > suffix.startIndex,
              technicalRules[technicalRules.index(before: endRange.lowerBound)] == "\n" else { return nil }
        return String(technicalRules[beginRange.upperBound..<endRange.lowerBound])
    }

    public static func taskPromptBlock(skillID: String, prompt source: String) -> String {
        var prompt = source
        if !prompt.hasSuffix("\n") { prompt.append("\n") }
        return beginMarker(for: skillID) + "\n" + prompt + endMarker(for: skillID)
    }

    public static func configuredDescription(for worker: Worker) -> String {
        var values = all.map { skill in
            let enabled = skill.configuredEnabled(overrides: worker.skillOverrides)
            let source = worker.skillOverrides[skill.id] == nil ? "Katalogstandard" : "Worker-Override"
            return "\(skill.displayName): \(enabled ? "aktiviert" : "deaktiviert") (\(source))"
        }
        let knownIDs = Set(all.map(\.id))
        values += worker.skillOverrides.keys.filter { !knownIDs.contains($0) }.sorted().map { id in
            "\(id): \(worker.skillOverrides[id] == true ? "aktiviert" : "deaktiviert") (unbekannte Katalog-ID; Override bleibt erhalten)"
        }
        return values.isEmpty ? "Keine" : values.joined(separator: "; ")
    }

    public static func effectiveDescription(for worker: Worker) -> String {
        let effective = effectiveSkills(for: worker).map(\.displayName)
        guard !effective.isEmpty else {
            let configuredButIncompatible = all.filter {
                $0.configuredEnabled(overrides: worker.skillOverrides) && !$0.isCompatible(with: worker.harness)
            }.map { "\($0.displayName): für \(worker.harness.rawValue) nicht unterstützt" }
            return configuredButIncompatible.isEmpty ? "Keine" : "Keine (\(configuredButIncompatible.joined(separator: "; ")))"
        }
        return effective.joined(separator: ", ")
    }
}
