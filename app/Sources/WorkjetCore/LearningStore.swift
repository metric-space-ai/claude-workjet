import Darwin
import Foundation

public enum AdHocLearningError: LocalizedError, Equatable {
    case invalidLength

    public var errorDescription: String? {
        "Der Eintrag darf nicht leer und höchstens 4 KB groß sein."
    }
}

public struct AdHocLearningStore: Sendable {
    public let fileURL: URL
    public var lockURL: URL { fileURL.deletingLastPathComponent().appendingPathComponent(".LEARNINGS.workjet.lock") }

    public init(fileURL: URL) { self.fileURL = fileURL }

    public func load() throws -> String? {
        try withLock {
            guard FileManager.default.fileExists(atPath: fileURL.path) else { return nil }
            let data = try SecureFile.readRegularOwnedFile(at: fileURL, maximumBytes: 1_048_576)
            guard let text = String(data: data, encoding: .utf8) else {
                throw LocalStateError.io("LEARNINGS.md ist nicht UTF-8.")
            }
            return text.trimmingCharacters(in: .whitespacesAndNewlines)
        }
    }

    public func replace(with text: String) throws {
        try withLock {
            let normalized = Self.normalized(text)
            try AtomicFile.write(Data(normalized.utf8), to: fileURL, directoryMode: 0o700, fileMode: 0o600)
        }
    }

    @discardableResult
    public func appendSystematic(_ entry: String) throws -> String {
        try withLock {
            let clean = try Self.validatedEntry(entry)
            let current: String
            if FileManager.default.fileExists(atPath: fileURL.path) {
                let data = try SecureFile.readRegularOwnedFile(at: fileURL, maximumBytes: 1_048_576)
                current = String(data: data, encoding: .utf8) ?? ""
            } else {
                current = ""
            }
            let bullet = clean.hasPrefix("-") ? clean : "- \(clean)"
            let existing = current.split(separator: "\n", omittingEmptySubsequences: true).map {
                String($0).trimmingCharacters(in: .whitespacesAndNewlines)
            }
            let updated = existing.contains(bullet) ? Self.normalized(current) : Self.normalized([current, bullet].filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }.joined(separator: "\n"))
            try AtomicFile.write(Data(updated.utf8), to: fileURL, directoryMode: 0o700, fileMode: 0o600)
            return updated.trimmingCharacters(in: .whitespacesAndNewlines)
        }
    }

    private static func validatedEntry(_ value: String) throws -> String {
        let clean = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty, clean.utf8.count <= 4_096 else { throw AdHocLearningError.invalidLength }
        return clean.replacingOccurrences(of: ManagedPrompt.beginStem, with: "WORKJET-MANAGED-WORKERS-BEGIN")
            .replacingOccurrences(of: ManagedPrompt.endMarker, with: "WORKJET-MANAGED-WORKERS-END")
    }

    private static func normalized(_ value: String) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "" : trimmed + "\n"
    }

    private func withLock<T>(_ body: () throws -> T) throws -> T {
        let directory = lockURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        _ = chmod(directory.path, 0o700)
        let fd = open(lockURL.path, O_RDWR | O_CREAT | O_NOFOLLOW, 0o600)
        guard fd >= 0 else { throw LocalStateError.io(String(cString: strerror(errno))) }
        defer { close(fd) }
        guard flock(fd, LOCK_EX) == 0 else { throw LocalStateError.io(String(cString: strerror(errno))) }
        defer { _ = flock(fd, LOCK_UN) }
        return try body()
    }
}
