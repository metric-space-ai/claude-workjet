import Darwin
import Foundation

public struct WorkjetPaths: Equatable, Sendable {
    public var homeDirectory: URL
    public var applicationSupportDirectory: URL
    public var stateDirectory: URL

    public init(homeDirectory: URL, applicationSupportDirectory: URL? = nil, stateDirectory: URL? = nil) {
        self.homeDirectory = homeDirectory
        self.applicationSupportDirectory = applicationSupportDirectory ?? homeDirectory.appendingPathComponent("Library/Application Support/Workjet", isDirectory: true)
        self.stateDirectory = stateDirectory ?? homeDirectory.appendingPathComponent(".local/state/workjet", isDirectory: true)
    }

    public static var live: WorkjetPaths {
        WorkjetPaths(homeDirectory: FileManager.default.homeDirectoryForCurrentUser)
    }

    public var configurationFile: URL { applicationSupportDirectory.appendingPathComponent("config.v1.json") }
    public var globalClaudeFile: URL { homeDirectory.appendingPathComponent(".claude/CLAUDE.md") }
    public var promptFile: URL { homeDirectory.appendingPathComponent(".claude/workjet/AGENTS.md") }
    /// Legacy opt-in loader retained only so older installations can be
    /// recognized and removed by the release installer.
    public var workjetSkillLoaderFile: URL { homeDirectory.appendingPathComponent(".claude/skills/workjet/SKILL.md") }
    public var learningsFile: URL { homeDirectory.appendingPathComponent(".claude/workjet/LEARNINGS.md") }
    public var runIndexDirectory: URL { stateDirectory.appendingPathComponent("run-index", isDirectory: true) }
    public var runsDirectory: URL { stateDirectory.appendingPathComponent("runs", isDirectory: true) }
    public var healthProbeDirectory: URL { stateDirectory.appendingPathComponent("health-probe", isDirectory: true) }
    public var remoteWorkspaceRunsDirectory: URL { stateDirectory.appendingPathComponent("remote-workspaces", isDirectory: true) }
    public var remoteWorkspaceImportsDirectory: URL { stateDirectory.appendingPathComponent("remote-workspace-imports", isDirectory: true) }
    public var localWorkspaceRepositoriesDirectory: URL { stateDirectory.appendingPathComponent("workspace-repositories", isDirectory: true) }
    public var localWorktreesDirectory: URL { stateDirectory.appendingPathComponent("worktrees", isDirectory: true) }
}

public enum WorkjetActivationState: String, Equatable, Sendable {
    case checking
    case ready
    case outOfDate
    case missing
    case failed
}

public struct WorkjetActivationStatus: Equatable, Sendable {
    public var state: WorkjetActivationState
    public var detail: String
    /// Truth about the generated file on disk. Activation remains a separate
    /// fact because a current AGENTS.md is ineffective without the global
    /// include in CLAUDE.md.
    public var promptStatus: PromptSyncStatus?

    public init(state: WorkjetActivationState, detail: String, promptStatus: PromptSyncStatus? = nil) {
        self.state = state
        self.detail = detail
        self.promptStatus = promptStatus
    }

    public static let checking = WorkjetActivationStatus(
        state: .checking,
        detail: "Workjet-Installation wird geprüft."
    )
}

public struct WorkjetActivationStore: Sendable {
    public static let includeBegin = "<!-- WORKJET GLOBAL INCLUDE BEGIN -->"
    public static let includeEnd = "<!-- WORKJET GLOBAL INCLUDE END -->"
    public static let includeTarget = "@workjet/AGENTS.md"

    public static var includeBlock: String {
        "\(includeBegin)\n\(includeTarget)\n\(includeEnd)"
    }

    /// Compatibility rendering for the legacy skill file shipped in older
    /// releases. It is not part of activation and is never installed by the
    /// current activation store or release installer.
    public static func loaderDocument(instructions: String) -> String {
        let body = instructions.trimmingCharacters(in: .whitespacesAndNewlines)
        return """
        ---
        name: workjet
        description: Legacy-Hinweis für frühere Workjet-Installationen.
        ---

        \(body)
        """ + "\n"
    }

    public static var loader: String {
        loaderDocument(instructions: WorkjetDefaults.skillLoaderInstructions)
    }

    public let paths: WorkjetPaths

    public init(paths: WorkjetPaths) { self.paths = paths }

    public func inspect(configuration: WorkjetConfiguration) -> WorkjetActivationStatus {
        let promptStatus = inspectPrompt(configuration: configuration)
        guard FileManager.default.fileExists(atPath: paths.globalClaudeFile.path) else {
            return WorkjetActivationStatus(state: .missing, detail: "Der globale Workjet-Include in `~/.claude/CLAUDE.md` fehlt.", promptStatus: promptStatus)
        }
        guard FileManager.default.fileExists(atPath: paths.promptFile.path) else {
            return WorkjetActivationStatus(state: .missing, detail: "Die verwaltete Datei `~/.claude/workjet/AGENTS.md` fehlt.", promptStatus: promptStatus)
        }
        do {
            let globalClaude = try SecureFile.readRegularOwnedFile(at: paths.globalClaudeFile, maximumBytes: 32 * 1_024 * 1_024)
            guard try Self.hasCurrentGlobalInclude(in: globalClaude) else {
                return WorkjetActivationStatus(state: .outOfDate, detail: "Der verwaltete Workjet-Include in `~/.claude/CLAUDE.md` fehlt oder wurde verändert.", promptStatus: promptStatus)
            }
            let prompt = try SecureFile.readRegularOwnedFile(at: paths.promptFile, maximumBytes: 32 * 1_024 * 1_024)
            let parsed: ManagedPromptDocument
            do { parsed = try ManagedPrompt.parse(prompt) }
            catch {
                return WorkjetActivationStatus(state: .outOfDate, detail: "Der verwaltete AGENTS-Block ist beschädigt oder seine SHA-256-Prüfsumme stimmt nicht.", promptStatus: promptStatus)
            }
            guard let body = parsed.body else {
                return WorkjetActivationStatus(state: .outOfDate, detail: "In AGENTS.md fehlt der verwaltete Workjet-Block.", promptStatus: promptStatus)
            }
            let handwritten = try ManagedPrompt.handwrittenContent(from: prompt)
            guard body == ManagedPrompt.workerBody(configuration: configuration),
                  handwritten == configuration.skillRules.trimmingCharacters(in: .whitespacesAndNewlines) else {
                return WorkjetActivationStatus(state: .outOfDate, detail: "AGENTS.md entspricht nicht der aktuellen Workjet-Konfiguration.", promptStatus: promptStatus)
            }
            return WorkjetActivationStatus(
                state: .ready,
                detail: "Workjet ist auf Datenträger aktuell und global installiert. Neue Claude-Code- und Claude-Desktop-Sitzungen laden diesen Prompt; den Promptzustand bereits laufender Sitzungen kann Workjet nicht beobachten.",
                promptStatus: promptStatus
            )
        } catch {
            return WorkjetActivationStatus(state: .failed, detail: error.localizedDescription, promptStatus: promptStatus)
        }
    }

    public func inspectPrompt(configuration: WorkjetConfiguration) -> PromptSyncStatus {
        guard FileManager.default.fileExists(atPath: paths.promptFile.path) else {
            return .failed("Die verwaltete Datei `~/.claude/workjet/AGENTS.md` fehlt.")
        }
        do {
            let prompt = try SecureFile.readRegularOwnedFile(at: paths.promptFile, maximumBytes: 32 * 1_024 * 1_024)
            let parsed = try ManagedPrompt.parse(prompt)
            guard parsed.body == ManagedPrompt.workerBody(configuration: configuration),
                  try ManagedPrompt.handwrittenContent(from: prompt) == configuration.skillRules.trimmingCharacters(in: .whitespacesAndNewlines) else {
                return .failed("AGENTS.md entspricht nicht der aktuellen Workjet-Konfiguration.")
            }
            let values = try paths.promptFile.resourceValues(forKeys: [.contentModificationDateKey])
            return .synchronized(values.contentModificationDate ?? Date())
        } catch {
            return .failed(error.localizedDescription)
        }
    }

    public func installOrRepair(configuration: WorkjetConfiguration) throws {
        try installOrRepair(configuration: configuration) {}
    }

    /// Writes prompt and global include as one rollback unit, then runs the
    /// caller's commit while the previous prompt/include snapshots are still
    /// available. A failed commit restores the exact previous owner bytes.
    public func installOrRepair(configuration: WorkjetConfiguration, commit: () throws -> Void) throws {
        let prompt = try ManagedPrompt.replacingManagedBlock(
            in: Data(configuration.skillRules.utf8),
            body: ManagedPrompt.workerBody(configuration: configuration)
        )
        for url in [paths.promptFile, paths.globalClaudeFile] where FileManager.default.fileExists(atPath: url.path) {
            try SecureFile.checkRegularOwnedFile(at: url)
        }
        let previousPrompt = try snapshot(paths.promptFile)
        let previousGlobal = try snapshot(paths.globalClaudeFile)
        let globalClaude = try Self.installingGlobalInclude(in: previousGlobal.data ?? Data())
        do {
            if previousPrompt.data != prompt {
                try AtomicFile.write(prompt, to: paths.promptFile, directoryMode: 0o700, fileMode: 0o600)
            }
            if previousGlobal.data != globalClaude {
                try AtomicFile.write(globalClaude, to: paths.globalClaudeFile, directoryMode: 0o700, fileMode: 0o600)
            }
            try commit()
        } catch {
            do {
                try restore(previousPrompt, at: paths.promptFile)
                try restore(previousGlobal, at: paths.globalClaudeFile)
            } catch {
                throw LocalStateError.io("Workjet konnte eine fehlgeschlagene Aktivierung nicht vollständig zurückrollen.")
            }
            throw error
        }
    }

    /// Removes only Workjet's marked include. The managed prompt and all
    /// unrelated global Claude instructions remain untouched.
    public func uninstallGlobalInclude() throws {
        guard FileManager.default.fileExists(atPath: paths.globalClaudeFile.path) else { return }
        try SecureFile.checkRegularOwnedFile(at: paths.globalClaudeFile)
        let existing = try SecureFile.readRegularOwnedFile(at: paths.globalClaudeFile, maximumBytes: 32 * 1_024 * 1_024)
        let updated = try Self.removingGlobalInclude(from: existing)
        guard updated != existing else { return }
        try AtomicFile.write(updated, to: paths.globalClaudeFile, directoryMode: 0o700, fileMode: 0o600)
    }

    public static func installingGlobalInclude(in existing: Data) throws -> Data {
        let withoutManagedBlock = try removingGlobalInclude(from: existing)
        var output = withoutManagedBlock
        if !output.isEmpty {
            if output.last == 0x0A { output.append(0x0A) }
            else { output.append(contentsOf: [0x0A, 0x0A]) }
        }
        output.append(Data(includeBlock.utf8))
        output.append(0x0A)
        return output
    }

    public static func removingGlobalInclude(from existing: Data) throws -> Data {
        guard let range = try managedIncludeRange(in: existing) else { return existing }
        var removal = range
        if removal.lowerBound > existing.startIndex,
           existing[existing.index(before: removal.lowerBound)] == 0x0A,
           existing.distance(from: existing.startIndex, to: removal.lowerBound) >= 2 {
            let twoBefore = existing.index(removal.lowerBound, offsetBy: -2)
            if existing[twoBefore] == 0x0A {
                removal = existing.index(before: removal.lowerBound)..<removal.upperBound
            }
        }
        if removal.upperBound < existing.endIndex, existing[removal.upperBound] == 0x0A {
            removal = removal.lowerBound..<existing.index(after: removal.upperBound)
        }
        var output = existing
        output.removeSubrange(removal)
        return output
    }

    public static func hasCurrentGlobalInclude(in existing: Data) throws -> Bool {
        guard let range = try managedIncludeRange(in: existing) else { return false }
        return existing.subdata(in: range) == Data(includeBlock.utf8)
    }

    private static func managedIncludeRange(in data: Data) throws -> Range<Data.Index>? {
        let begin = Data(includeBegin.utf8)
        let end = Data(includeEnd.utf8)
        let beginRange = data.range(of: begin)
        let endRange = data.range(of: end)
        guard beginRange != nil || endRange != nil else { return nil }
        guard let beginRange, let endRange, beginRange.upperBound <= endRange.lowerBound else {
            throw LocalStateError.promptMalformed("Der globale Workjet-Include ist unvollständig.")
        }
        let remainderStart = endRange.upperBound
        if data[beginRange.upperBound...].range(of: begin) != nil ||
            (remainderStart < data.endIndex && data[remainderStart...].range(of: end) != nil) {
            throw LocalStateError.promptMalformed("Der globale Workjet-Include ist mehrfach vorhanden.")
        }
        return beginRange.lowerBound..<endRange.upperBound
    }

    private struct Snapshot {
        var existed: Bool
        var data: Data?
    }

    private func snapshot(_ url: URL) throws -> Snapshot {
        guard FileManager.default.fileExists(atPath: url.path) else { return Snapshot(existed: false, data: nil) }
        return Snapshot(existed: true, data: try SecureFile.readRegularOwnedFile(at: url, maximumBytes: 32 * 1_024 * 1_024))
    }

    private func restore(_ snapshot: Snapshot, at url: URL) throws {
        if let data = snapshot.data {
            try AtomicFile.write(data, to: url, directoryMode: 0o700, fileMode: 0o600)
        } else if !snapshot.existed {
            guard FileManager.default.fileExists(atPath: url.path) else { return }
            try SecureFile.checkRegularOwnedFile(at: url)
            try FileManager.default.removeItem(at: url)
        }
    }
}

public enum LocalStateError: LocalizedError, Equatable {
    case corruptConfiguration(String)
    case unsupportedConfiguration(Int)
    case migrationFailed
    case insecurePath(String)
    case wrongOwner(String)
    case promptMalformed(String)
    case promptHashMismatch
    case io(String)

    public var errorDescription: String? {
        switch self {
        case .corruptConfiguration: return "Die Workjet-Konfiguration ist beschädigt und wurde nicht überschrieben."
        case let .unsupportedConfiguration(version): return "Konfigurationsversion \(version) wird nicht unterstützt. Sie wird nicht überschrieben."
        case .migrationFailed: return "Die Workjet-Konfiguration konnte nicht sicher aktualisiert werden. Die bisherige Konfiguration bleibt erhalten."
        case .insecurePath: return "Eine Workjet-Datei verweist auf einen unsicheren Speicherort."
        case .wrongOwner: return "Eine Workjet-Datei gehört einem anderen Benutzer und kann nicht verwendet werden."
        case .promptMalformed: return "Der Workjet-Prompt ist beschädigt. Öffne Workjet, um ihn zu reparieren."
        case .promptHashMismatch: return "Der Workjet-Prompt wurde außerhalb der App verändert."
        case .io: return "Eine Workjet-Datei konnte nicht gelesen oder gespeichert werden."
        }
    }
}

public protocol ConfigurationStoring: Sendable {
    func load() throws -> WorkjetConfiguration?
    func save(_ configuration: WorkjetConfiguration) throws
    func snapshot() throws -> ConfigurationStoreSnapshot
    func restore(_ snapshot: ConfigurationStoreSnapshot) throws
}

public struct ConfigurationStoreSnapshot: Equatable, Sendable {
    public var existed: Bool
    public var data: Data?

    public init(existed: Bool, data: Data?) {
        self.existed = existed
        self.data = data
    }
}

public struct JSONConfigurationStore: ConfigurationStoring, Sendable {
    public let fileURL: URL
    private let backupRetentionCount: Int
    private let now: @Sendable () -> Date
    private let migrate: @Sendable (WorkjetConfiguration) throws -> WorkjetConfiguration

    public init(fileURL: URL) {
        self.init(
            fileURL: fileURL,
            backupRetentionCount: 5,
            now: { Date() },
            migrate: { WorkjetBootstrap.normalized($0) }
        )
    }

    init(
        fileURL: URL,
        backupRetentionCount: Int,
        now: @escaping @Sendable () -> Date,
        migrate: @escaping @Sendable (WorkjetConfiguration) throws -> WorkjetConfiguration
    ) {
        self.fileURL = fileURL
        self.backupRetentionCount = max(backupRetentionCount, 1)
        self.now = now
        self.migrate = migrate
    }

    public func load() throws -> WorkjetConfiguration? {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return nil }
        try SecureFile.checkRegularOwnedFile(at: fileURL)
        let data: Data
        do { data = try Data(contentsOf: fileURL) }
        catch { throw LocalStateError.io(error.localizedDescription) }
        let version: Int
        do {
            let object = try JSONSerialization.jsonObject(with: data)
            guard let dictionary = object as? [String: Any], let value = dictionary["version"] as? NSNumber else {
                throw LocalStateError.corruptConfiguration("Versionsfeld fehlt")
            }
            version = value.intValue
        } catch let error as LocalStateError { throw error }
        catch { throw LocalStateError.corruptConfiguration(error.localizedDescription) }
        guard version == WorkjetConfiguration.currentVersion else { throw LocalStateError.unsupportedConfiguration(version) }
        let decoded: WorkjetConfiguration
        do { decoded = try JSONDecoder().decode(WorkjetConfiguration.self, from: data) }
        catch { throw LocalStateError.corruptConfiguration(error.localizedDescription) }

        let migrated: WorkjetConfiguration
        let migratedData: Data
        do {
            migrated = try migrate(decoded)
            guard migrated.version == WorkjetConfiguration.currentVersion else {
                throw LocalStateError.migrationFailed
            }
            migratedData = try encoded(migrated)
            guard try JSONDecoder().decode(WorkjetConfiguration.self, from: migratedData) == migrated else {
                throw LocalStateError.migrationFailed
            }
        } catch {
            throw LocalStateError.migrationFailed
        }

        guard migrated != decoded else { return decoded }

        let backupData: Data
        do { backupData = try encoded(decoded) }
        catch { throw LocalStateError.migrationFailed }
        let backupURL = migrationBackupURL(sourceVersion: decoded.version)
        do {
            try prepareMigrationBackupSlot()
            try AtomicFile.write(backupData, to: backupURL, directoryMode: 0o700, fileMode: 0o600)
            try AtomicFile.write(migratedData, to: fileURL, directoryMode: 0o700, fileMode: 0o600)
        } catch let error as LocalStateError {
            throw error
        } catch {
            throw LocalStateError.io(error.localizedDescription)
        }
        return migrated
    }

    public func save(_ configuration: WorkjetConfiguration) throws {
        guard configuration.version == WorkjetConfiguration.currentVersion else {
            throw LocalStateError.unsupportedConfiguration(configuration.version)
        }
        if FileManager.default.fileExists(atPath: fileURL.path) {
            try SecureFile.checkRegularOwnedFile(at: fileURL)
        }
        do { try AtomicFile.write(encoded(configuration), to: fileURL, directoryMode: 0o700, fileMode: 0o600) }
        catch let error as LocalStateError { throw error }
        catch { throw LocalStateError.io(error.localizedDescription) }
    }

    public func snapshot() throws -> ConfigurationStoreSnapshot {
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            return ConfigurationStoreSnapshot(existed: false, data: nil)
        }
        return ConfigurationStoreSnapshot(
            existed: true,
            data: try SecureFile.readRegularOwnedFile(at: fileURL, maximumBytes: 32 * 1_024 * 1_024)
        )
    }

    public func restore(_ snapshot: ConfigurationStoreSnapshot) throws {
        if let data = snapshot.data {
            try AtomicFile.write(data, to: fileURL, directoryMode: 0o700, fileMode: 0o600)
            return
        }
        guard !snapshot.existed, FileManager.default.fileExists(atPath: fileURL.path) else { return }
        try SecureFile.checkRegularOwnedFile(at: fileURL)
        try FileManager.default.removeItem(at: fileURL)
    }

    private func encoded(_ configuration: WorkjetConfiguration) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(configuration)
    }

    private func migrationBackupURL(sourceVersion: Int) -> URL {
        let milliseconds = Int64(now().timeIntervalSince1970 * 1_000)
        let name = "\(fileURL.lastPathComponent).backup-v\(sourceVersion)-\(milliseconds)-\(UUID().uuidString.lowercased()).json"
        return fileURL.deletingLastPathComponent().appendingPathComponent(name)
    }

    private func prepareMigrationBackupSlot() throws {
        let directory = fileURL.deletingLastPathComponent()
        let prefix = "\(fileURL.lastPathComponent).backup-v"
        let backups = try FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        )
        .filter { $0.lastPathComponent.hasPrefix(prefix) && $0.pathExtension == "json" }
        .sorted { $0.lastPathComponent > $1.lastPathComponent }
        for expired in backups.dropFirst(backupRetentionCount - 1) {
            try SecureFile.checkPrivateRegularOwnedFile(at: expired)
            try FileManager.default.removeItem(at: expired)
        }
    }
}

public enum AtomicFile {
    public static func write(_ data: Data, to destination: URL, directoryMode: mode_t = 0o700, fileMode: mode_t = 0o600) throws {
        let directory = destination.deletingLastPathComponent()
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            _ = chmod(directory.path, directoryMode)
        } catch { throw LocalStateError.io(error.localizedDescription) }
        let temp = directory.appendingPathComponent(".\(destination.lastPathComponent).tmp.\(UUID().uuidString)")
        let fd = open(temp.path, O_WRONLY | O_CREAT | O_EXCL, fileMode)
        guard fd >= 0 else { throw LocalStateError.io(String(cString: strerror(errno))) }
        var writeError: String?
        data.withUnsafeBytes { raw in
            guard let base = raw.baseAddress else { return }
            var written = 0
            while written < raw.count {
                let result = Darwin.write(fd, base.advanced(by: written), raw.count - written)
                if result <= 0 { writeError = result == 0 ? "Temporärer Dateischreibvorgang blieb stehen." : String(cString: strerror(errno)); break }
                written += result
            }
        }
        if fsync(fd) != 0 && writeError == nil { writeError = String(cString: strerror(errno)) }
        close(fd)
        if let writeError { unlink(temp.path); throw LocalStateError.io(writeError) }
        _ = chmod(temp.path, fileMode)
        guard rename(temp.path, destination.path) == 0 else {
            let message = String(cString: strerror(errno)); unlink(temp.path); throw LocalStateError.io(message)
        }
        let dirFD = open(directory.path, O_RDONLY)
        if dirFD >= 0 { _ = fsync(dirFD); close(dirFD) }
    }
}

public enum SecureFile {
    public static func checkRegularOwnedFile(at url: URL) throws {
        var info = stat()
        guard lstat(url.path, &info) == 0 else { throw LocalStateError.io(String(cString: strerror(errno))) }
        if (info.st_mode & S_IFMT) == S_IFLNK { throw LocalStateError.insecurePath(url.path) }
        guard (info.st_mode & S_IFMT) == S_IFREG else { throw LocalStateError.insecurePath(url.path) }
        guard info.st_uid == geteuid() else { throw LocalStateError.wrongOwner(url.path) }
    }

    public static func checkPrivateRegularOwnedFile(at url: URL) throws {
        try checkRegularOwnedFile(at: url)
        var info = stat()
        guard lstat(url.path, &info) == 0 else { throw LocalStateError.io(String(cString: strerror(errno))) }
        guard (info.st_mode & 0o077) == 0 else { throw LocalStateError.insecurePath(url.path) }
    }

    public static func readRegularOwnedFile(at url: URL, maximumBytes: Int = 32 * 1_024 * 1_024) throws -> Data {
        let fd = open(url.path, O_RDONLY | O_NOFOLLOW)
        guard fd >= 0 else {
            if errno == ELOOP { throw LocalStateError.insecurePath(url.path) }
            throw LocalStateError.io(String(cString: strerror(errno)))
        }
        defer { close(fd) }
        var info = stat()
        guard fstat(fd, &info) == 0 else { throw LocalStateError.io(String(cString: strerror(errno))) }
        guard (info.st_mode & S_IFMT) == S_IFREG else { throw LocalStateError.insecurePath(url.path) }
        guard info.st_uid == geteuid() else { throw LocalStateError.wrongOwner(url.path) }
        guard info.st_size >= 0, info.st_size <= maximumBytes else { throw LocalStateError.io("Datei überschreitet das erlaubte Größenlimit.") }
        var data = Data()
        data.reserveCapacity(Int(info.st_size))
        var buffer = [UInt8](repeating: 0, count: 16_384)
        while true {
            let count = Darwin.read(fd, &buffer, buffer.count)
            if count == 0 { break }
            guard count > 0 else {
                if errno == EINTR { continue }
                throw LocalStateError.io(String(cString: strerror(errno)))
            }
            guard data.count + count <= maximumBytes else { throw LocalStateError.io("Datei überschreitet das erlaubte Größenlimit.") }
            data.append(buffer, count: count)
        }
        return data
    }
}

public final class RemoteWorkspaceRunStore: @unchecked Sendable {
    public let paths: WorkjetPaths
    private let lock = NSLock()

    public init(paths: WorkjetPaths = .live) {
        self.paths = paths
    }

    public func load(runID: String) throws -> RemoteWorkspaceRunRecord {
        guard LocalWorkspaceResultImporter.safeRunID(runID) else { throw WorkspaceResultError.invalidRunID }
        return try lock.withLock {
            try ensurePrivateDirectory(paths.remoteWorkspaceRunsDirectory)
            let file = recordFile(runID)
            guard FileManager.default.fileExists(atPath: file.path) else { throw WorkspaceResultError.recordNotFound }
            try SecureFile.checkPrivateRegularOwnedFile(at: file)
            let data = try SecureFile.readRegularOwnedFile(at: file, maximumBytes: 64 * 1_024)
            guard let record = try? JSONDecoder().decode(RemoteWorkspaceRunRecord.self, from: data),
                  record.schemaVersion == 1, record.runID == runID,
                  LocalWorkspaceResultImporter.safeRunID(record.runID), record.sourceRepositoryRoot.hasPrefix("/"),
                  !record.sourceRepositoryRoot.contains("\0"), GitRepositoryInspector.validDigest(record.repoID),
                  GitRepositoryInspector.validOID(record.snapshotCommitOID),
                  record.ownerID.range(of: "^[A-Za-z0-9._-]{1,128}$", options: .regularExpression) != nil,
                  Self.validLocalWorkspacePaths(record.localWorktreePath, record.localRepositoryPath) else {
                throw WorkspaceResultError.invalidRecord
            }
            return record
        }
    }

    public func save(_ record: RemoteWorkspaceRunRecord) throws {
        guard record.schemaVersion == 1, LocalWorkspaceResultImporter.safeRunID(record.runID),
              record.sourceRepositoryRoot.hasPrefix("/"), !record.sourceRepositoryRoot.contains("\0"),
              GitRepositoryInspector.validDigest(record.repoID), GitRepositoryInspector.validOID(record.snapshotCommitOID),
              record.ownerID.range(of: "^[A-Za-z0-9._-]{1,128}$", options: .regularExpression) != nil,
              record.resultCommitOID.map(GitRepositoryInspector.validOID) ?? true,
              record.resultRef.map({ $0 == "refs/workjet/\(record.runID)" }) ?? true,
              Self.validLocalWorkspacePaths(record.localWorktreePath, record.localRepositoryPath) else {
            throw WorkspaceResultError.invalidRecord
        }
        try lock.withLock {
            try ensurePrivateDirectory(paths.remoteWorkspaceRunsDirectory)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            try AtomicFile.write(try encoder.encode(record), to: recordFile(record.runID), directoryMode: 0o700, fileMode: 0o600)
            try SecureFile.checkPrivateRegularOwnedFile(at: recordFile(record.runID))
        }
    }

    public func create(runID: String, sourceRepositoryRoot: URL, computerID: UUID, ownerID: String, manifest: WorkspaceSnapshotManifest, inspector: GitRepositoryInspector = GitRepositoryInspector()) async throws -> RemoteWorkspaceRunRecord {
        guard LocalWorkspaceResultImporter.safeRunID(runID) else { throw WorkspaceResultError.invalidRunID }
        guard let pointer = Darwin.realpath(sourceRepositoryRoot.path, nil) else { throw WorkspaceResultError.repositoryUnsafe }
        let canonicalPath = String(cString: pointer)
        free(pointer)
        let canonical = URL(fileURLWithPath: canonicalPath, isDirectory: true)
        let identity = try await inspector.inspect(root: canonical, expectedRepoID: manifest.repoID)
        let record = RemoteWorkspaceRunRecord(
            runID: runID,
            sourceRepositoryRoot: canonicalPath,
            computerID: computerID,
            ownerID: ownerID,
            repoID: manifest.repoID,
            snapshotCommitOID: manifest.snapshotCommitOID,
            repositoryIdentity: identity
        )
        try save(record)
        return record
    }

    private func recordFile(_ runID: String) -> URL {
        paths.remoteWorkspaceRunsDirectory.appendingPathComponent("\(runID).json")
    }

    private static func validLocalWorkspacePaths(_ worktree: String?, _ repository: String?) -> Bool {
        switch (worktree, repository) {
        case (nil, nil): return true
        case let (.some(worktree), .some(repository)):
            return [worktree, repository].allSatisfy { $0.hasPrefix("/") && !$0.contains("\0") }
        default: return false
        }
    }

    private func ensurePrivateDirectory(_ directory: URL) throws {
        let canonicalState = paths.stateDirectory.resolvingSymlinksInPath().standardizedFileURL
        guard paths.stateDirectory.standardizedFileURL.path == canonicalState.path, canonicalState.path.hasPrefix("/") else {
            throw LocalStateError.insecurePath(paths.stateDirectory.path)
        }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        for value in [canonicalState, directory] {
            var info = stat()
            guard lstat(value.path, &info) == 0, (info.st_mode & S_IFMT) == S_IFDIR,
                  info.st_uid == geteuid() else {
                throw LocalStateError.insecurePath(value.path)
            }
            _ = chmod(value.path, 0o700)
            guard lstat(value.path, &info) == 0, (info.st_mode & 0o077) == 0 else {
                throw LocalStateError.insecurePath(value.path)
            }
        }
    }
}
