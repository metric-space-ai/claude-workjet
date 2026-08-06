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
    /// contract changed. Exact-sentence replacement keeps all surrounding
    /// owner edits intact and makes the migration idempotent.
    public static func correctingKnownTechnicalDefaults(in rules: String) -> String {
        rules
            .replacingOccurrences(of: legacySkillActivationSentence, with: currentSkillActivationSentence)
            .replacingOccurrences(of: legacyFallbackSentence, with: currentFallbackSentence)
    }

    public static let currentSkillActivationSentence = "Dieser vollständige, in der Workjet-App sichtbare Prompt ist die globale Workjet-Ergänzung für neue Claude-Code- und Claude-Desktop-Sitzungen. Workjet wird nicht per Slash-Command aktiviert."
    public static let currentFallbackSentence = "Direkte Anbieter-Pools werden deterministisch abgearbeitet und wechseln nur nach klassifizierten Auth-, Quota- oder Rate-Limit-Fehlern zum nächsten Zugang; Netzwerk-, Timeout-, 5xx- und Task-Fehler lösen keinen Fallback aus."

    private static let legacySkillActivationSentence = "Der Skill `/workjet` lädt ausschließlich diesen vollständigen, in der Workjet-App sichtbaren Prompt. Der Skill selbst fügt keine Routing- oder Worker-Regeln hinzu."
    private static let legacyFallbackSentence = "Direkte Anbieter-Pools werden deterministisch abgearbeitet und wechseln nur nach klassifizierten Auth-, Quota- oder Netzwerkfehlern zum nächsten Zugang; Task-Fehler lösen keinen Fallback aus."
    private static let legacyProgressBoardRules = """
    ## Progress board (mandatory for every larger orchestrated task)

    Whenever orchestration is engaged for a larger task (multiple workers, multiple waves, or work spanning sessions), create and maintain an HTML progress board, published as an Artifact with a stable URL per project. It is the shared workflow picture: the user checks it instead of asking, and it survives context compaction.

    Structure: overall progress bar · milestone/wave table with worker assignment and state (done / in progress / review open / blocked) · a dynamic "now next" list that absorbs follow-up tasks and subtasks as they appear · decisions log (short, with dates) · findings/risks strip.

    Update duty is EVENT-driven, never time-driven: milestone done, worker landed, review verdict, decision taken, new subtask discovered → update the board immediately (edit the same file, republish to the same URL). A board that lags reality is worse than no board — it lies with authority. No board for single-delegation errands: there, the smallest useful pattern is the task list alone.
    """

    private static func cleaned(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
