import Foundation

/// Metadata for one centrally managed worker skill. Worker persistence stores
/// only sparse ID-based overrides, so extending this catalog does not change
/// the Worker schema.
public struct WorkerSkillDescriptor: Identifiable, Equatable, Sendable {
    public var id: String
    public var displayName: String
    public var version: String?
    public var description: String
    public var defaultEnabled: Bool
    public var compatibleHarnesses: [Harness]
    public var incompatibilityDescriptions: [Harness: String]
    public var requiresRepository: Bool
    public var usesManagedRemoteBinary: Bool
    public var systemPromptHarnesses: [Harness]

    public init(
        id: String,
        displayName: String,
        version: String? = nil,
        description: String,
        defaultEnabled: Bool,
        compatibleHarnesses: [Harness],
        incompatibilityDescriptions: [Harness: String] = [:],
        requiresRepository: Bool = false,
        usesManagedRemoteBinary: Bool = false,
        systemPromptHarnesses: [Harness] = []
    ) {
        self.id = id
        self.displayName = displayName
        self.version = version
        self.description = description
        self.defaultEnabled = defaultEnabled
        self.compatibleHarnesses = compatibleHarnesses
        self.incompatibilityDescriptions = incompatibilityDescriptions
        self.requiresRepository = requiresRepository
        self.usesManagedRemoteBinary = usesManagedRemoteBinary
        self.systemPromptHarnesses = systemPromptHarnesses
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
    public static let webResearchID = "web-research"
    public static let webResearchCapability = "codex-cli"
    public static let taskPromptBeginStem = "<!-- WORKJET WORKER SKILL BEGIN"
    public static let taskPromptEndStem = "<!-- WORKJET WORKER SKILL END"
    public static let promptSourceBeginStem = "<!-- WORKJET SKILL PROMPT SOURCE BEGIN"
    public static let promptSourceEndStem = "<!-- WORKJET SKILL PROMPT SOURCE END"

    public static let all: [WorkerSkillDescriptor] = [
        WorkerSkillDescriptor(
            id: greppyID,
            displayName: "Greppy",
            version: RemoteManagedSkillArtifact.greppyVersion,
            description: "Greppy 0.3.1 wird per Bash ausgeführt; Workjet hängt den festen Greppy-Prompt als echten Claude-Code-Systemprompt an.",
            defaultEnabled: true,
            compatibleHarnesses: [.claudeCode],
            incompatibilityDescriptions: [
                .piSidecar: "Pi Code besitzt in V1 keine Host-Shell und kein Host-Dateisystem.",
                .codexCLI: "Workjet kann den festen Greppy-Prompt für Codex CLI noch nicht als echten Harness-System-Prompt anhängen.",
                .openCode: "Workjet kann den festen Greppy-Prompt für OpenCode noch nicht als echten Harness-System-Prompt anhängen.",
                .cursorAgent: "Workjet hat für Cursor Agent noch keinen verifizierten lokalen Repository- und Shell-Ausführungsvertrag.",
                .grokCLI: "Workjet hat für Grok CLI noch keinen verifizierten lokalen Repository- und Shell-Ausführungsvertrag."
            ],
            requiresRepository: true,
            usesManagedRemoteBinary: true,
            systemPromptHarnesses: [.claudeCode]
        ),
        WorkerSkillDescriptor(
            id: webResearchID,
            displayName: "Web Research",
            description: "Ergänzt den Worker um echte Live-Suche und normalen Seitenabruf. Die vorhandenen Harness-Tools bleiben unverändert.",
            defaultEnabled: false,
            compatibleHarnesses: [.claudeCode, .codexCLI],
            incompatibilityDescriptions: [
                .piSidecar: "Pi Code besitzt in V1 keine verifizierte Web-Research-Schnittstelle.",
                .openCode: "Workjet hat für OpenCode noch keinen verifizierten Web-Research-Vertrag.",
                .cursorAgent: "Workjet hat für Cursor Agent noch keinen verifizierten Web-Research-Vertrag.",
                .grokCLI: "Workjet hat für Grok CLI noch keinen verifizierten Web-Research-Vertrag."
            ],
            systemPromptHarnesses: [.claudeCode]
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
        if verifiedCapabilities.contains(webResearchCapability) {
            available.insert(webResearchID)
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

    /// Builds the exact system-prompt appendix for configured, compatible, and
    /// target-verified skills. It is deliberately returned separately from the
    /// task input: a skill is effective only when the harness launch installs
    /// these bytes as a real system-prompt modification.
    public static func systemPrompt(
        for worker: Worker,
        repositoryAvailable: Bool,
        availableSkillIDs: Set<String>,
        technicalRules: String
    ) -> String? {
        let skills = launchAvailableSkills(for: worker, availableSkillIDs: availableSkillIDs).filter { skill in
            (!skill.requiresRepository || repositoryAvailable)
                && skill.systemPromptHarnesses.contains(worker.harness)
        }
        guard !skills.isEmpty else { return nil }

        let sourced = skills.compactMap { skill in
            technicalPrompt(for: skill.id, in: technicalRules).map { (skill, $0) }
        }
        guard !sourced.isEmpty else { return nil }
        return sourced.map { taskPromptBlock(skillID: $0.0.id, prompt: $0.1) }
            .joined(separator: "\n\n")
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

    /// Skill prompt sources are visible/editable configuration, but they are
    /// launch payloads for selected workers—not instructions for the global
    /// orchestrator. Remove only the catalog's exact managed source blocks.
    public static func removingPromptSources(from technicalRules: String) -> String {
        var result = technicalRules
        for skill in all {
            let begin = promptSourceBeginMarker(for: skill.id)
            let end = promptSourceEndMarker(for: skill.id)
            guard let beginRange = result.range(of: begin),
                  let endRange = result.range(of: end, range: beginRange.upperBound..<result.endIndex) else { continue }
            var removal = beginRange.lowerBound..<endRange.upperBound
            if removal.upperBound < result.endIndex, result[removal.upperBound] == "\n" {
                removal = removal.lowerBound..<result.index(after: removal.upperBound)
            }
            result.removeSubrange(removal)
        }
        return result
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
