import Foundation

/// Pure filtering for the worker list: search query + selected computer.
public enum WorkerFilter {
    public static func filtered(_ workers: [Worker], query: String, computerID: UUID?) -> [Worker] {
        workers.filter { worker in
            if let computerID, worker.computerID != computerID { return false }
            let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return true }
            return worker.name.range(of: trimmed, options: [.caseInsensitive, .diacriticInsensitive]) != nil
                || worker.model.range(of: trimmed, options: [.caseInsensitive, .diacriticInsensitive]) != nil
        }
    }
}

/// Compact duration strings for the "Aktiv" area.
public enum DurationFormatter {
    public static func string(for interval: TimeInterval) -> String {
        let seconds = max(Int(interval.rounded(.down)), 0)
        if seconds < 60 { return "\(seconds)s" }
        let minutes = seconds / 60
        if minutes < 60 { return "\(minutes)m \(seconds % 60)s" }
        return "\(minutes / 60)h \(minutes % 60)m"
    }
}

/// Composes the generated Workjet skill prompt: orchestrator rules plus
/// automatically appended worker declarations. Fable receives only
/// skill + worker declarations and handles the rest.
public enum SkillPrompt {
    /// Single sentence that must always be part of the preview so the
    /// boundary to Fable stays explicit.
    public static let fableStatement =
        "Fable erhält Skill + Worker-Deklarationen und übernimmt Zerlegung, Routing und Ausführung."

    public static func compose(
        rules: String,
        activation: SkillActivation,
        injectWorkers: Bool,
        workers: [Worker]
    ) -> String {
        var parts: [String] = []
        parts.append("# Workjet Skill\nAktivierung: \(activation.rawValue)")
        let trimmedRules = rules.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedRules.isEmpty {
            parts.append(trimmedRules)
        }
        if injectWorkers && !workers.isEmpty {
            let declarations = workers
                .map { "- \($0.name) — Modell: \($0.model), Harness: \($0.harness.rawValue)" }
                .joined(separator: "\n")
            parts.append("## Worker-Deklarationen\n\(declarations)")
        }
        parts.append(fableStatement)
        return parts.joined(separator: "\n\n")
    }
}
