import Foundation

public enum LegacyPromptMigration {
    public struct Result: Equatable, Sendable {
        public var generalRules: String
        public var modelPrompts: [String: String]
    }

    /// Splits the former monolithic Workjet prompt. It runs only when all
    /// three legacy model headings and the following review section exist.
    public static func split(_ rules: String) -> Result? {
        guard let agentsStart = rules.range(of: "You control these agents:"),
              let solStart = rules.range(of: "GPT-5.6 Sol", range: agentsStart.upperBound..<rules.endIndex),
              let miniStart = rules.range(of: "MiniMax-M3", range: solStart.upperBound..<rules.endIndex),
              let kimiStart = rules.range(of: "Kimi-K3", range: miniStart.upperBound..<rules.endIndex),
              let following = rules.range(of: "Review model (two tiers):", range: kimiStart.upperBound..<rules.endIndex) else {
            return nil
        }

        let sol = cleaned(String(rules[solStart.upperBound..<miniStart.lowerBound]))
        let mini = cleaned(String(rules[miniStart.upperBound..<kimiStart.lowerBound]))
        let kimi = cleaned(String(rules[kimiStart.upperBound..<following.lowerBound]))
        guard !sol.isEmpty, !mini.isEmpty, !kimi.isEmpty else { return nil }

        var general = String(rules[..<agentsStart.lowerBound])
        general += String(rules[following.lowerBound...])
        general = general.trimmingCharacters(in: .whitespacesAndNewlines)
        return Result(
            generalRules: general,
            modelPrompts: ["GPT-5.6 Sol": sol, "MiniMax M3": mini, "Kimi K3": kimi]
        )
    }

    /// The progress-board policy used to be shipped inside the handwritten
    /// general rules before it received its own visible source field. Remove
    /// only that exact Workjet-owned legacy block; arbitrary owner prose that
    /// happens to mention a progress board is never rewritten.
    public static func removingKnownProgressBoardDefault(from rules: String) -> String {
        guard let range = rules.range(of: legacyProgressBoardRules) else { return rules }
        var before = String(rules[..<range.lowerBound])
        var after = String(rules[range.upperBound...])
        while before.hasSuffix("\n") || before.hasSuffix("\r") { before.removeLast() }
        while after.hasPrefix("\n") || after.hasPrefix("\r") { after.removeFirst() }
        if before.isEmpty { return after }
        if after.isEmpty { return before }
        return before + "\n\n" + after
    }

    /// Corrects previously generated technical sentences whose runtime
    /// contract changed. Only exact Workjet defaults are recognized; arbitrary
    /// unmarked owner prose is never inferred or rewritten.
    public static func correctingKnownTechnicalDefaults(in rules: String) -> String {
        var value = rules
            .replacingOccurrences(of: legacySkillActivationSentence, with: currentSkillActivationSentence)
            .replacingOccurrences(of: legacyFallbackSentence, with: currentFallbackSentence)
        for paragraph in knownSupersededTechnicalParagraphs {
            value = value.replacingOccurrences(of: paragraph, with: "")
        }
        return value
    }

    /// Replaces every complete Workjet-owned technical block with the current
    /// default bytes. Text outside the explicit marker pairs is copied exactly.
    /// Missing blocks are appended once; duplicate complete blocks are removed.
    public static func synchronizingManagedTechnicalBlocks(in rules: String, defaults: String) -> String {
        var value = rules
        var missing: [String] = []
        for (begin, end) in managedTechnicalMarkers {
            guard let current = markedBlock(begin: begin, end: end, in: defaults) else { continue }
            let synchronized = synchronizingMarkedBlock(begin: begin, end: end, replacement: current, in: value)
            value = synchronized.value
            if !synchronized.found { missing.append(current) }
        }
        guard !missing.isEmpty else { return value }
        if !value.isEmpty, !value.hasSuffix("\n") { value.append("\n") }
        if !value.isEmpty { value.append("\n") }
        value.append(missing.joined(separator: "\n\n"))
        return value
    }

    /// Removes only the obsolete worker whose persisted execution fields match
    /// the complete known version-1 signature.
    public static func removingKnownLegacyStandardCodingTask(from workers: [Worker]) -> [Worker] {
        workers.filter { worker in
            !(worker.name == "Standard Coding Task"
                && worker.model == "grok-4.5"
                && worker.harness == .claudeCode
                && worker.instructions == "for standard high volume coding tasks"
                && worker.reasoningEffort == .high
                && worker.providerID == nil
                && worker.providerPool == .xAI
                && worker.skillOverrides.isEmpty
                && worker.invocation.executable == "~/.local/bin/claude-sol"
                && worker.invocation.arguments.isEmpty
                && worker.invocation.capabilities.isEmpty
                && worker.invocation.options.isEmpty)
        }
    }

    public static let cliExecutionContractBeginMarker = "<!-- WORKJET CLI EXECUTION CONTRACT BEGIN -->"
    public static let cliExecutionContractEndMarker = "<!-- WORKJET CLI EXECUTION CONTRACT END -->"
    public static let currentSkillActivationSentence = "Dieser vollständige, in der Workjet-App sichtbare Prompt ist die globale Workjet-Ergänzung für neue Claude-Code- und Claude-Desktop-Sitzungen. Workjet wird nicht per Slash-Command aktiviert."
    public static let currentFallbackSentence = "Direkte Anbieter-Pools werden deterministisch abgearbeitet und wechseln nur nach klassifizierten Auth-, Quota- oder Rate-Limit-Fehlern zum nächsten Zugang; Netzwerk-, Timeout-, 5xx- und Task-Fehler lösen keinen Fallback aus."

    private static let legacySkillActivationSentence = "Der Skill `/workjet` lädt ausschließlich diesen vollständigen, in der Workjet-App sichtbaren Prompt. Der Skill selbst fügt keine Routing- oder Worker-Regeln hinzu."
    private static let legacyFallbackSentence = "Direkte Anbieter-Pools werden deterministisch abgearbeitet und wechseln nur nach klassifizierten Auth-, Quota- oder Netzwerkfehlern zum nächsten Zugang; Task-Fehler lösen keinen Fallback aus."
    private static let knownSupersededTechnicalParagraphs = [
        "Workjet wählt keine Worker und baut keine Workflows; Fable bleibt der Orchestrator. Starte, beobachte und stoppe Worker ausschließlich mit `workjet workers list --json`, `workjet workers describe <exakter-name-oder-uuid> --json`, `workjet run <exakter-name-oder-uuid> --brief-file <pfad> --json`, `workjet events <run-id> --after <exklusive-sequenz> --json` und `workjet stop <run-id> --json`. Die sichtbaren Executable-, Argument-, Protokoll- und Harness-Fakten führt ausschließlich die Workjet-App aus; Fable startet weder SSH noch Harness-Prozesse direkt.",
        "\(currentFallbackSentence) CLIProxy-OAuth-Zugänge bilden einen proxyverwalteten gemeinsamen Gateway-Pool ohne Account-Pinning pro Anfrage. Ein Wechsel auf einen anderen Worker geschieht niemals automatisch.",
        "Remote startbar sind Claude Code, Pi Code, Codex CLI und OpenCode. Cursor Agent und Grok CLI sind ausschließlich prüf- und installierbar, nicht remote startbar. Workjet verwendet begrenztes Event-Polling mit exklusivem Sequenz-Cursor, keine t3code-Interoperabilität, keinen WebSocket-Stream und keinen behaupteten Pi-Live-Stream.",
        "Wenn die Orchestrierung wegen einer Workjet-Regel oder -Implementierung systematisch und reproduzierbar scheitert, halte daraus eine kurze, künftig handlungsleitende Regel mit `workjet learn --systematic \"…\"` fest. Keine einmaligen Fehler, flüchtigen Umgebungsprobleme oder gewöhnlichen Schwierigkeiten protokollieren.",
        "<!-- WORKJET TRANSPARENT RUNTIME PROMPTS V2 -->"
    ]
    private static var managedTechnicalMarkers: [(String, String)] {
        [
            (cliExecutionContractBeginMarker, cliExecutionContractEndMarker),
            ("<!-- WORKJET WORKER PREAMBLE BEGIN -->", "<!-- WORKJET WORKER PREAMBLE END -->"),
            ("<!-- WORKJET OPUS SYSTEM PROMPT BEGIN -->", "<!-- WORKJET OPUS SYSTEM PROMPT END -->"),
            ("<!-- WORKJET HEALTH PROBE PROMPT BEGIN -->", "<!-- WORKJET HEALTH PROBE PROMPT END -->"),
            ("<!-- WORKJET COMPLETION RECEIPT PROMPT BEGIN -->", "<!-- WORKJET COMPLETION RECEIPT PROMPT END -->"),
            (
                WorkerSkillCatalog.promptSourceBeginMarker(for: WorkerSkillCatalog.greppyID),
                WorkerSkillCatalog.promptSourceEndMarker(for: WorkerSkillCatalog.greppyID)
            )
        ]
    }
    private static let legacyProgressBoardRules = """
    ## Progress board (mandatory for every larger orchestrated task)

    Whenever orchestration is engaged for a larger task (multiple workers, multiple waves, or work spanning sessions), create and maintain an HTML progress board, published as an Artifact with a stable URL per project. It is the shared workflow picture: the user checks it instead of asking, and it survives context compaction.

    Structure: overall progress bar · milestone/wave table with worker assignment and state (done / in progress / review open / blocked) · a dynamic "now next" list that absorbs follow-up tasks and subtasks as they appear · decisions log (short, with dates) · findings/risks strip.

    Update duty is EVENT-driven, never time-driven: milestone done, worker landed, review verdict, decision taken, new subtask discovered → update the board immediately (edit the same file, republish to the same URL). A board that lags reality is worse than no board — it lies with authority. No board for single-delegation errands: there, the smallest useful pattern is the task list alone.
    """

    private static func synchronizingMarkedBlock(
        begin: String,
        end: String,
        replacement: String,
        in source: String
    ) -> (value: String, found: Bool) {
        var result = ""
        var cursor = source.startIndex
        var found = false
        while let beginRange = source.range(of: begin, range: cursor..<source.endIndex),
              let endRange = source.range(of: end, range: beginRange.upperBound..<source.endIndex) {
            result.append(contentsOf: source[cursor..<beginRange.lowerBound])
            if !found {
                result.append(replacement)
                found = true
            }
            cursor = endRange.upperBound
        }
        result.append(contentsOf: source[cursor..<source.endIndex])
        return (result, found)
    }

    private static func markedBlock(begin: String, end: String, in source: String) -> String? {
        guard let beginRange = source.range(of: begin),
              let endRange = source.range(of: end, range: beginRange.upperBound..<source.endIndex) else { return nil }
        return String(source[beginRange.lowerBound..<endRange.upperBound])
    }

    private static func cleaned(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
