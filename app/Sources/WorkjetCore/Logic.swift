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
