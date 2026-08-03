import CryptoKit
import Darwin
import Foundation

public protocol ProcessProbing: Sendable {
    func identity(for pid: Int32) -> ProcessIdentity?
    func sendTERM(to pid: Int32) throws
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
}

public protocol RunTelemetryReading: Sendable {
    func scan(workers: [Worker]) -> [RunRecord]
    func stop(_ run: ActiveRun) throws
}

public struct RunTelemetryStore: RunTelemetryReading, Sendable {
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
        guard processStartMatches(identity.startToken, runStartedAt: startedAt) else {
            return RunRecord(sourceRunID: runID, state: .interrupted, diagnostic: "PID gehört zu einem später gestarteten Prozess")
        }
        let wrapper = boundedString(at: directory.appendingPathComponent("worker"), maximumBytes: 256)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let worker = matchWorker(wrapper: wrapper, workers: workers)
        let unknownName = wrapper.isEmpty ? "Unbekannter Worker" : "Unbekannter Worker (\(safeLabel(wrapper)))"
        let heartbeat = fileModificationDate(directory.appendingPathComponent("heartbeat"))
        let activity = safeActivity(directory: directory, runID: runID)
        let delivery = deliveryKind(directory: directory, worker: worker)
        let stableID = deterministicUUID(runID)
        let active = ActiveRun(id: stableID, sourceRunID: runID, workerID: worker?.id, workerName: worker?.name ?? unknownName, workerModel: worker?.model, activity: activity, startedAt: startedAt, observedAt: now(), lastHeartbeat: heartbeat, delivery: delivery, pid: pid, processIdentity: identity, runDirectory: directory, indexFile: indexFile)
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
        let piArtifacts = ["pi-response-events", "response-events.jsonl", "pi-events.jsonl"]
        if piArtifacts.contains(where: { fm.fileExists(atPath: directory.appendingPathComponent($0).path) }) { return .postHoc }
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

    private func safeLabel(_ value: String) -> String {
        value.replacingOccurrences(of: "\n", with: " ").replacingOccurrences(of: "\r", with: " ").unicodeScalars.filter { !CharacterSet.controlCharacters.contains($0) }.map(String.init).joined()
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
        case .pidMismatch: return "Stop verweigert: PID oder Prozessidentität gehört nicht mehr zu diesem Run."
        case .runAlreadyFinished: return "Der Run ist bereits beendet."
        }
    }
}
