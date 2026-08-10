import CryptoKit
import Darwin
import Foundation

public protocol ProcessProbing: Sendable {
    func identity(for pid: Int32) -> ProcessIdentity?
    func sendTERM(to pid: Int32) throws
    func sendKILL(to pid: Int32) throws
}

public struct SystemProcessProbe: ProcessProbing, Sendable {
    public init() {}

    public func identity(for pid: Int32) -> ProcessIdentity? {
        guard pid > 1, kill(pid, 0) == 0 || errno == EPERM else { return nil }
        var pathBuffer = [CChar](repeating: 0, count: 4096)
        let pathLength = proc_pidpath(pid, &pathBuffer, UInt32(pathBuffer.count))
        guard pathLength > 0 else { return nil }
        var info = proc_bsdinfo()
        let infoSize = MemoryLayout<proc_bsdinfo>.size
        guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, Int32(infoSize)) == infoSize else { return nil }
        let path = String(cString: pathBuffer)
        let startToken = String(format: "%lld.%06d", Int64(info.pbi_start_tvsec), Int32(info.pbi_start_tvusec))
        return ProcessIdentity(pid: pid, executablePath: path, startToken: startToken)
    }

    public func sendTERM(to pid: Int32) throws {
        guard pid > 1, kill(pid, SIGTERM) == 0 else { throw LocalStateError.io(String(cString: strerror(errno))) }
    }

    public func sendKILL(to pid: Int32) throws {
        guard pid > 1, kill(pid, SIGKILL) == 0 else { throw LocalStateError.io(String(cString: strerror(errno))) }
    }
}

public protocol RunTelemetryReading: Sendable {
    func scan(workers: [Worker]) -> [RunRecord]
    func stop(_ run: ActiveRun) throws
}

public struct RunTelemetryStore: RunTelemetryReading, Sendable {
    private struct CanonicalRunSnapshot: Decodable {
        var schemaVersion: Int
        var sequence: UInt64
        var state: String
        var heartbeatAt: String
        var model: String?
        var reasoning: String?
        var speed: String?
        var providerRoute: String?
    }

    private struct RecordedProcessIdentity: Decodable {
        var pid: Int32
        var executablePath: String
        var startToken: String

        var processIdentity: ProcessIdentity {
            ProcessIdentity(pid: pid, executablePath: executablePath, startToken: startToken)
        }
    }

    public let paths: WorkjetPaths
    public let processProbe: any ProcessProbing
    public let now: @Sendable () -> Date
    public let maximumRuns: Int

    public init(paths: WorkjetPaths, processProbe: any ProcessProbing = SystemProcessProbe(), now: @escaping @Sendable () -> Date = { Date() }, maximumRuns: Int = 200) {
        self.paths = paths
        self.processProbe = processProbe
        self.now = now
        self.maximumRuns = maximumRuns
    }

    public func scan(workers: [Worker]) -> [RunRecord] {
        let candidates = runCandidates().prefix(maximumRuns)
        return candidates.map { inspect(runID: $0.runID, directory: $0.directory, indexFile: $0.indexFile, workers: workers) }
    }

    /// Removes only old local run journals that can no longer belong to a
    /// live Workjet process. Cleanup is deliberately conservative: an
    /// identity-confirmed process, a fresh file, an unowned entry, a symlink,
    /// or an unreadable tree keeps the complete journal intact.
    public func cleanup(retentionDays: Int) {
        guard retentionDays > 0,
              isOwnedDirectory(paths.runsDirectory),
              isOwnedDirectory(paths.runIndexDirectory) else { return }
        let interval = TimeInterval(retentionDays) * 86_400
        guard interval.isFinite else { return }
        let cutoff = now().addingTimeInterval(-interval)
        let fm = FileManager.default
        let indexes = safeIndexEntries()

        let runDirectories = (try? fm.contentsOfDirectory(
            at: paths.runsDirectory,
            includingPropertiesForKeys: nil,
            options: []
        )) ?? []
        for directory in runDirectories {
            guard isDirectChild(directory, of: paths.runsDirectory),
                  isOwnedDirectory(directory),
                  safeTreeIsOlder(than: cutoff, at: directory),
                  canRemoveRunDirectory(directory) else { continue }
            let linkedIndexes = indexes.filter { $0.directory == directory.standardizedFileURL }
            do {
                // Remove discoverability entries before the journal itself so
                // observers never see a deleted run with a dangling index.
                // If journal removal then fails, the intact directory remains
                // discoverable through the runs directory fallback.
                for entry in linkedIndexes {
                    try fm.removeItem(at: entry.file)
                }
                try fm.removeItem(at: directory)
            } catch {
                continue
            }
        }

        // A crash can leave an index after its journal was never created or
        // was removed successfully. Only remove an old, bounded index whose
        // target is a direct child of Workjet's runs directory and is absent.
        for entry in safeIndexEntries() {
            guard isDirectChild(entry.directory, of: paths.runsDirectory),
                  !fm.fileExists(atPath: entry.directory.path),
                  safeTreeIsOlder(than: cutoff, at: entry.file) else { continue }
            try? fm.removeItem(at: entry.file)
        }
    }

    public func stop(_ run: ActiveRun) throws {
        guard !hasTerminalMarker(run.runDirectory) else { throw StopError.runAlreadyFinished }
        if let indexFile = run.indexFile {
            guard let indexedPath = boundedString(at: indexFile, maximumBytes: 4096),
                  URL(fileURLWithPath: indexedPath).standardizedFileURL == run.runDirectory.standardizedFileURL else {
                throw StopError.pidMismatch
            }
        }
        guard readPID(run.runDirectory.appendingPathComponent("pid")) == run.pid,
              let current = processProbe.identity(for: run.pid), current == run.processIdentity else {
            throw StopError.pidMismatch
        }
        try processProbe.sendTERM(to: run.pid)
        let termDeadline = Date().addingTimeInterval(2)
        while Date() < termDeadline {
            guard processProbe.identity(for: run.pid) == run.processIdentity else { return }
            Thread.sleep(forTimeInterval: 0.05)
        }
        guard processProbe.identity(for: run.pid) == run.processIdentity else { return }
        try processProbe.sendKILL(to: run.pid)
        let killDeadline = Date().addingTimeInterval(2)
        while Date() < killDeadline {
            guard processProbe.identity(for: run.pid) == run.processIdentity else { return }
            Thread.sleep(forTimeInterval: 0.05)
        }
        guard processProbe.identity(for: run.pid) == run.processIdentity else { return }
        throw LocalStateError.io("Der lokale Worker reagiert nicht auf das Stoppsignal.")
    }

    private func runCandidates() -> [(runID: String, directory: URL, indexFile: URL?)] {
        let fm = FileManager.default
        var result: [(String, URL, URL?)] = []
        var seen = Set<String>()
        if let entries = try? fm.contentsOfDirectory(at: paths.runIndexDirectory, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]) {
            for index in entries.sorted(by: { $0.lastPathComponent > $1.lastPathComponent }) {
                guard isOwnedRegularFile(index), let path = boundedString(at: index, maximumBytes: 4096), !path.isEmpty else { continue }
                let directory = URL(fileURLWithPath: path).standardizedFileURL
                let key = directory.path
                guard !seen.contains(key), isOwnedDirectory(directory) else { continue }
                seen.insert(key)
                result.append((index.lastPathComponent, directory, index))
            }
        }
        if let entries = try? fm.contentsOfDirectory(at: paths.runsDirectory, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]) {
            for directory in entries.sorted(by: { $0.lastPathComponent > $1.lastPathComponent }) where isOwnedDirectory(directory) {
                let key = directory.standardizedFileURL.path
                guard !seen.contains(key) else { continue }
                seen.insert(key)
                result.append((directory.lastPathComponent, directory, nil))
            }
        }
        return result
    }

    private func safeIndexEntries() -> [(file: URL, directory: URL)] {
        let entries = (try? FileManager.default.contentsOfDirectory(
            at: paths.runIndexDirectory,
            includingPropertiesForKeys: nil,
            options: []
        )) ?? []
        return entries.compactMap { file in
            guard isDirectChild(file, of: paths.runIndexDirectory),
                  isOwnedRegularFile(file),
                  let rawPath = boundedString(at: file, maximumBytes: 4096) else { return nil }
            let path = rawPath.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !path.isEmpty else { return nil }
            return (file, URL(fileURLWithPath: path).standardizedFileURL)
        }
    }

    private func canRemoveRunDirectory(_ directory: URL) -> Bool {
        guard let pid = readPID(directory.appendingPathComponent("pid")), pid > 1 else {
            return true
        }
        guard let current = processProbe.identity(for: pid) else { return true }
        if let recorded = readRecordedIdentity(directory.appendingPathComponent("process-identity.json")) {
            return recorded.processIdentity != current
        }
        if let startedAt = readDate(directory.appendingPathComponent("started-at")) {
            return !processStartMatches(current.startToken, runStartedAt: startedAt)
        }
        // A live PID without enough evidence to prove or disprove ownership is
        // ambiguous. Keeping its journal is safer than terminating visibility.
        return false
    }

    private func safeTreeIsOlder(than cutoff: Date, at url: URL) -> Bool {
        var info = stat()
        guard lstat(url.path, &info) == 0,
              info.st_uid == geteuid(),
              Date(timeIntervalSince1970: TimeInterval(info.st_mtimespec.tv_sec)) < cutoff else { return false }
        let type = info.st_mode & S_IFMT
        if type == S_IFREG { return true }
        guard type == S_IFDIR,
              let children = try? FileManager.default.contentsOfDirectory(
                  at: url,
                  includingPropertiesForKeys: nil,
                  options: []
              ) else { return false }
        return children.allSatisfy { safeTreeIsOlder(than: cutoff, at: $0) }
    }

    private func isDirectChild(_ url: URL, of directory: URL) -> Bool {
        url.standardizedFileURL.deletingLastPathComponent() == directory.standardizedFileURL
    }

    private func inspect(runID: String, directory: URL, indexFile: URL?, workers: [Worker]) -> RunRecord {
        if hasTerminalMarker(directory) { return RunRecord(sourceRunID: runID, state: .completed) }
        guard let pid = readPID(directory.appendingPathComponent("pid")), pid > 1 else {
            return RunRecord(sourceRunID: runID, state: .malformed, diagnostic: "PID fehlt oder ist ungültig")
        }
        guard let startedAt = readDate(directory.appendingPathComponent("started-at")) else {
            return RunRecord(sourceRunID: runID, state: .malformed, diagnostic: "Startzeit fehlt oder ist ungültig")
        }
        guard let identity = processProbe.identity(for: pid) else {
            return RunRecord(sourceRunID: runID, state: .interrupted, diagnostic: "Prozess ist ohne Terminalmarker beendet")
        }
        let recordedIdentity = readRecordedIdentity(directory.appendingPathComponent("process-identity.json"))
        guard recordedIdentity.map({ $0.processIdentity == identity })
            ?? processStartMatches(identity.startToken, runStartedAt: startedAt) else {
            return RunRecord(sourceRunID: runID, state: .interrupted, diagnostic: "PID gehört zu einem später gestarteten Prozess")
        }
        let snapshot = readSnapshot(directory.appendingPathComponent("run-state.json"))
        if let snapshot {
            guard snapshot.schemaVersion == 1, snapshot.sequence > 0 else {
                return RunRecord(sourceRunID: runID, state: .malformed, diagnostic: "Run-Snapshot hat eine unbekannte Version oder Sequenz")
            }
            guard snapshot.state == "running" else {
                return RunRecord(sourceRunID: runID, state: snapshot.state == "completed" ? .completed : .interrupted, diagnostic: "Run-Snapshot meldet \(snapshot.state)")
            }
            guard let heartbeatAt = ISO8601DateFormatter().date(from: snapshot.heartbeatAt),
                  abs(now().timeIntervalSince(heartbeatAt)) <= 45 else {
                return RunRecord(sourceRunID: runID, state: .interrupted, diagnostic: "Run-Heartbeat ist veraltet")
            }
        }
        let wrapper = boundedString(at: directory.appendingPathComponent("worker"), maximumBytes: 256)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let recordedWorkerID: UUID?
        if let value = boundedString(at: directory.appendingPathComponent("worker-id"), maximumBytes: 64) {
            recordedWorkerID = UUID(uuidString: value.trimmingCharacters(in: .whitespacesAndNewlines))
        } else {
            recordedWorkerID = nil
        }
        let worker = recordedWorkerID.flatMap { id in workers.first(where: { $0.id == id }) }
            ?? matchWorker(wrapper: wrapper, workers: workers)
        let wrapperName = URL(fileURLWithPath: wrapper).lastPathComponent
        let unmappedName = wrapperName.isEmpty
            ? "Nicht zugeordneter Prozess"
            : "\(wrapperName) · nicht konfiguriert"
        let heartbeat = snapshot.flatMap { ISO8601DateFormatter().date(from: $0.heartbeatAt) }
            ?? fileModificationDate(directory.appendingPathComponent("heartbeat"))
        let activity = safeActivity(directory: directory, runID: runID)
        let delivery = deliveryKind(directory: directory, worker: worker)
        let stableID = deterministicUUID(runID)
        let active = ActiveRun(
            id: stableID,
            sourceRunID: runID,
            workerID: worker?.id,
            workerName: worker?.name ?? unmappedName,
            workerModel: nil,
            effectiveModel: snapshot.flatMap { safeMetadata($0.model, maximumLength: 256) },
            effectiveReasoning: snapshot.flatMap { $0.reasoning.flatMap(ReasoningEffort.init(rawValue:)) },
            effectiveSpeed: snapshot.flatMap { $0.speed.flatMap(RunSpeed.init(rawValue:)) },
            effectiveProviderRoute: snapshot.flatMap { safeMetadata($0.providerRoute, maximumLength: 256) },
            activity: activity,
            startedAt: startedAt,
            observedAt: now(),
            lastHeartbeat: heartbeat,
            delivery: delivery,
            pid: pid,
            processIdentity: identity,
            runDirectory: directory,
            indexFile: indexFile
        )
        return RunRecord(sourceRunID: runID, state: .running, activeRun: active)
    }

    private func matchWorker(wrapper: String, workers: [Worker]) -> Worker? {
        let wrapperBase = URL(fileURLWithPath: wrapper).lastPathComponent
        return workers.first {
            let executableBase = URL(fileURLWithPath: ($0.invocation.executable as NSString).expandingTildeInPath).lastPathComponent
            return !$0.invocation.executable.isEmpty && (wrapper == $0.invocation.executable || wrapperBase == executableBase)
        } ?? workers.first { $0.name.caseInsensitiveCompare(wrapper) == .orderedSame }
    }

    private func safeActivity(directory: URL, runID: String) -> String {
        for name in ["title", "activity", "metadata-title"] {
            if let value = boundedString(at: directory.appendingPathComponent(name), maximumBytes: 512) {
                let clean = safeLabel(value)
                if !clean.isEmpty { return String(clean.prefix(160)) }
            }
        }
        return "Worker läuft"
    }

    private func processStartMatches(_ token: String, runStartedAt: Date, tolerance: TimeInterval = 5) -> Bool {
        guard let processEpoch = Double(token), processEpoch.isFinite, processEpoch > 0 else { return false }
        return abs(processEpoch - runStartedAt.timeIntervalSince1970) <= tolerance
    }

    private func deliveryKind(directory: URL, worker: Worker?) -> HarnessDelivery {
        let fm = FileManager.default
        let liveArtifacts = ["stream-json", "stream.jsonl", "claude-stream.jsonl"]
        if worker?.harness == .claudeCode && liveArtifacts.contains(where: { fm.fileExists(atPath: directory.appendingPathComponent($0).path) }) { return .live }
        if worker?.harness == .piSidecar {
            let piArtifacts = ["pi-response-events", "response-events.jsonl", "pi-events.jsonl"]
            if piArtifacts.contains(where: { fm.fileExists(atPath: directory.appendingPathComponent($0).path) }) { return .postHoc }
        }
        // Codex, Cursor, OpenCode and Grok have protocol-specific event
        // streams. Until Workjet has a decoder for those canonical events,
        // generic files must not be presented as live telemetry.
        return .unavailable
    }

    private func hasTerminalMarker(_ directory: URL) -> Bool {
        ["rc", "exit", "exit-code"].contains { FileManager.default.fileExists(atPath: directory.appendingPathComponent($0).path) }
    }

    private func boundedString(at url: URL, maximumBytes: Int) -> String? {
        guard isOwnedRegularFile(url), let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        guard let data = try? handle.read(upToCount: maximumBytes + 1), data.count <= maximumBytes else { return nil }
        return String(data: data, encoding: .utf8)
    }

    private func readPID(_ url: URL) -> Int32? {
        guard let value = boundedString(at: url, maximumBytes: 32)?.trimmingCharacters(in: .whitespacesAndNewlines), let pid = Int32(value) else { return nil }
        return pid
    }

    private func readDate(_ url: URL) -> Date? {
        guard let value = boundedString(at: url, maximumBytes: 128)?.trimmingCharacters(in: .whitespacesAndNewlines) else { return nil }
        return ISO8601DateFormatter().date(from: value)
    }

    private func fileModificationDate(_ url: URL) -> Date? {
        (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
    }

    private func readSnapshot(_ url: URL) -> CanonicalRunSnapshot? {
        guard isOwnedRegularFile(url), let data = try? Data(contentsOf: url), data.count <= 4_096 else { return nil }
        return try? JSONDecoder().decode(CanonicalRunSnapshot.self, from: data)
    }

    private func readRecordedIdentity(_ url: URL) -> RecordedProcessIdentity? {
        guard isOwnedRegularFile(url), let data = try? Data(contentsOf: url), data.count <= 4_096 else { return nil }
        return try? JSONDecoder().decode(RecordedProcessIdentity.self, from: data)
    }

    private func safeLabel(_ value: String) -> String {
        value.replacingOccurrences(of: "\n", with: " ").replacingOccurrences(of: "\r", with: " ").unicodeScalars.filter { !CharacterSet.controlCharacters.contains($0) }.map(String.init).joined()
    }

    private func safeMetadata(_ value: String?, maximumLength: Int) -> String? {
        guard let value else { return nil }
        let clean = safeLabel(value).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty, clean.count <= maximumLength else { return nil }
        return clean
    }

    private func deterministicUUID(_ text: String) -> UUID {
        var bytes = Array(SHA256.hash(data: Data(text.utf8)).prefix(16))
        bytes[6] = (bytes[6] & 0x0f) | 0x40; bytes[8] = (bytes[8] & 0x3f) | 0x80
        return UUID(uuid: (bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5], bytes[6], bytes[7], bytes[8], bytes[9], bytes[10], bytes[11], bytes[12], bytes[13], bytes[14], bytes[15]))
    }

    private func isOwnedDirectory(_ url: URL) -> Bool {
        var info = stat()
        return lstat(url.path, &info) == 0 && (info.st_mode & S_IFMT) == S_IFDIR && info.st_uid == geteuid()
    }

    private func isOwnedRegularFile(_ url: URL) -> Bool {
        var info = stat()
        return lstat(url.path, &info) == 0 && (info.st_mode & S_IFMT) == S_IFREG && info.st_uid == geteuid()
    }
}

public enum StopError: LocalizedError, Equatable {
    case pidMismatch
    case runAlreadyFinished
    public var errorDescription: String? {
        switch self {
        case .pidMismatch: return "Dieser Worker kann nicht mehr eindeutig zugeordnet werden. Aktualisiere die Anzeige."
        case .runAlreadyFinished: return "Dieser Worker ist bereits beendet."
        }
    }
}
