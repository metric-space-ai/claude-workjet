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
    public var promptFile: URL { homeDirectory.appendingPathComponent(".claude/workjet/AGENTS.md") }
    public var runIndexDirectory: URL { stateDirectory.appendingPathComponent("run-index", isDirectory: true) }
    public var runsDirectory: URL { stateDirectory.appendingPathComponent("runs", isDirectory: true) }
}

public enum LocalStateError: LocalizedError, Equatable {
    case corruptConfiguration(String)
    case unsupportedConfiguration(Int)
    case insecurePath(String)
    case wrongOwner(String)
    case promptMalformed(String)
    case promptHashMismatch
    case io(String)

    public var errorDescription: String? {
        switch self {
        case let .corruptConfiguration(detail): return "Konfiguration ist beschädigt: \(detail). Sie wird nicht überschrieben."
        case let .unsupportedConfiguration(version): return "Konfigurationsversion \(version) wird nicht unterstützt. Sie wird nicht überschrieben."
        case let .insecurePath(path): return "Sicherheitsprüfung verweigert einen symbolischen Link: \(path)"
        case let .wrongOwner(path): return "Sicherheitsprüfung verweigert eine Datei mit falschem Eigentümer: \(path)"
        case let .promptMalformed(detail): return "Der verwaltete Prompt-Block ist ungültig: \(detail)"
        case .promptHashMismatch: return "Der verwaltete Prompt-Block wurde außerhalb von Workjet verändert (SHA-256 stimmt nicht)."
        case let .io(detail): return "Lokaler Schreib-/Lesefehler: \(detail)"
        }
    }
}

public protocol ConfigurationStoring: Sendable {
    func load() throws -> WorkjetConfiguration?
    func save(_ configuration: WorkjetConfiguration) throws
}

public struct JSONConfigurationStore: ConfigurationStoring, Sendable {
    public let fileURL: URL
    public init(fileURL: URL) { self.fileURL = fileURL }

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
        do { return try JSONDecoder().decode(WorkjetConfiguration.self, from: data) }
        catch { throw LocalStateError.corruptConfiguration(error.localizedDescription) }
    }

    public func save(_ configuration: WorkjetConfiguration) throws {
        guard configuration.version == WorkjetConfiguration.currentVersion else {
            throw LocalStateError.unsupportedConfiguration(configuration.version)
        }
        if FileManager.default.fileExists(atPath: fileURL.path) {
            try SecureFile.checkRegularOwnedFile(at: fileURL)
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        do { try AtomicFile.write(encoder.encode(configuration), to: fileURL, directoryMode: 0o700, fileMode: 0o600) }
        catch let error as LocalStateError { throw error }
        catch { throw LocalStateError.io(error.localizedDescription) }
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
