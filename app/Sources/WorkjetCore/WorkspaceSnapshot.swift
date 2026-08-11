import CryptoKit
import Darwin
import Foundation

public struct RemoteWorkspaceDescriptor: Codable, Equatable, Sendable {
    public var repoID: String
    public var snapshotCommitOID: String

    public init(repoID: String, snapshotCommitOID: String) {
        self.repoID = repoID
        self.snapshotCommitOID = snapshotCommitOID
    }
}

public struct WorkspaceSnapshotSubmodule: Codable, Equatable, Sendable {
    public var path: String
    public var commitOID: String
    public var bundleRef: String

    public init(path: String, commitOID: String, bundleRef: String) {
        self.path = path
        self.commitOID = commitOID
        self.bundleRef = bundleRef
    }
}

public struct WorkspaceSnapshotManifest: Codable, Equatable, Sendable {
    public var schemaVersion: Int
    public var repoID: String
    public var snapshotCommitOID: String
    public var bundleSHA256: String
    public var byteSize: Int
    public var submodules: [WorkspaceSnapshotSubmodule]

    public init(schemaVersion: Int = 1, repoID: String, snapshotCommitOID: String, bundleSHA256: String, byteSize: Int, submodules: [WorkspaceSnapshotSubmodule] = []) {
        self.schemaVersion = schemaVersion
        self.repoID = repoID
        self.snapshotCommitOID = snapshotCommitOID
        self.bundleSHA256 = bundleSHA256
        self.byteSize = byteSize
        self.submodules = submodules
    }

    private enum CodingKeys: String, CodingKey {
        case schemaVersion, repoID, snapshotCommitOID, bundleSHA256, byteSize, submodules
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try values.decode(Int.self, forKey: .schemaVersion)
        repoID = try values.decode(String.self, forKey: .repoID)
        snapshotCommitOID = try values.decode(String.self, forKey: .snapshotCommitOID)
        bundleSHA256 = try values.decode(String.self, forKey: .bundleSHA256)
        byteSize = try values.decode(Int.self, forKey: .byteSize)
        submodules = try values.decodeIfPresent([WorkspaceSnapshotSubmodule].self, forKey: .submodules) ?? []
    }

    public func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(schemaVersion, forKey: .schemaVersion)
        try values.encode(repoID, forKey: .repoID)
        try values.encode(snapshotCommitOID, forKey: .snapshotCommitOID)
        try values.encode(bundleSHA256, forKey: .bundleSHA256)
        try values.encode(byteSize, forKey: .byteSize)
        if !submodules.isEmpty { try values.encode(submodules, forKey: .submodules) }
    }

    public var descriptor: RemoteWorkspaceDescriptor {
        RemoteWorkspaceDescriptor(repoID: repoID, snapshotCommitOID: snapshotCommitOID)
    }
}

public struct WorkspaceSnapshot: Equatable, Sendable {
    public var manifest: WorkspaceSnapshotManifest
    public var bundle: Data
    /// Canonical local-only source repository root. This is never encoded or
    /// transmitted to the remote host.
    public var sourceRepositoryRoot: URL?

    public init(manifest: WorkspaceSnapshotManifest, bundle: Data, sourceRepositoryRoot: URL? = nil) {
        self.manifest = manifest
        self.bundle = bundle
        self.sourceRepositoryRoot = sourceRepositoryRoot
    }
}

public enum WorkspaceSnapshotError: LocalizedError, Equatable, Sendable {
    case workingDirectoryMustBeAbsolute
    case notGitRepository
    case bareRepository
    case unbornRepository
    case unsafeRepositoryPath
    case unsafePath(String)
    case nestedRepository(String)
    case gitlink(String)
    case submoduleUnavailable(path: String, commitOID: String)
    case submoduleModified(String)
    case recursiveSubmodule(String)
    case lfsManaged(String)
    case symlink(String)
    case gitUnavailable
    case gitFailed(String)
    case bundleTooLarge(limit: Int)
    case malformedBundle

    public var errorDescription: String? {
        switch self {
        case .workingDirectoryMustBeAbsolute: return "Das Arbeitsverzeichnis muss ein absoluter Pfad sein."
        case .notGitRepository: return "Remote-Workspaces benötigen ein Git-Repository."
        case .bareRepository: return "Bare Git-Repositories werden für Remote-Workspaces nicht unterstützt."
        case .unbornRepository: return "Das Git-Repository braucht mindestens einen Commit."
        case .unsafeRepositoryPath: return "Das Git-Repository liegt an einem unsicheren Dateisystempfad."
        case .unsafePath: return "Das Git-Repository enthält einen unsicheren Pfad."
        case .nestedRepository: return "Nicht deklarierte verschachtelte Git-Repositories werden nicht unterstützt."
        case .gitlink: return "Dieser Gitlink kann nicht sicher als initialisiertes Submodule übernommen werden."
        case let .submoduleUnavailable(path, commitOID): return "Das Submodule \(path) ist nicht initialisiert oder der angeheftete Commit \(commitOID) fehlt lokal. Initialisiere es ohne den Commit zu ändern und versuche es erneut."
        case let .submoduleModified(path): return "Das Submodule \(path) enthält Änderungen oder ist nicht am angehefteten Commit ausgecheckt. Stelle einen sauberen Zustand her und versuche es erneut."
        case let .recursiveSubmodule(path): return "Rekursive Submodule werden noch nicht unterstützt (\(path))."
        case .lfsManaged: return "Git-LFS-Inhalte werden für Remote-Workspaces noch nicht unterstützt."
        case .symlink: return "Symlinks werden für Remote-Workspaces aus Sicherheitsgründen nicht übernommen."
        case .gitUnavailable: return "Git ist auf diesem Mac nicht verfügbar."
        case .gitFailed: return "Der unveränderliche Git-Snapshot konnte nicht erstellt werden."
        case let .bundleTooLarge(limit): return "Der Git-Snapshot überschreitet das Limit von \(limit / 1_048_576) MiB."
        case .malformedBundle: return "Der erzeugte Git-Snapshot ist ungültig."
        }
    }
}

public protocol WorkspaceSnapshotPreparing: Sendable {
    func prepare(from workingDirectory: URL) async throws -> WorkspaceSnapshot
}

/// Creates a commit and bundle from the caller's current Git worktree without
/// touching its branch, HEAD, primary index, stash, files, or durable refs.
/// Every snapshot schema deliberately caps the complete bundle at 64 MiB.
public struct GitWorkspaceSnapshotPreparer: WorkspaceSnapshotPreparing, Sendable {
    public static let maximumBundleBytes = 64 * 1_024 * 1_024

    private struct Gitlink: Equatable, Sendable {
        var path: String
        var commitOID: String
        var repository: URL
    }

    private let runner: any CommandRunning
    private let gitExecutable: String
    private let maximumBundleBytes: Int

    public init(runner: any CommandRunning = ProcessCommandRunner(), gitExecutable: String = "/usr/bin/git", maximumBundleBytes: Int = Self.maximumBundleBytes) {
        self.runner = runner
        self.gitExecutable = gitExecutable
        self.maximumBundleBytes = min(max(maximumBundleBytes, 1), Self.maximumBundleBytes)
    }

    public func prepare(from workingDirectory: URL) async throws -> WorkspaceSnapshot {
        guard workingDirectory.path.hasPrefix("/"), !workingDirectory.path.contains("\0") else {
            throw WorkspaceSnapshotError.workingDirectoryMustBeAbsolute
        }
        guard FileManager.default.isExecutableFile(atPath: gitExecutable) else { throw WorkspaceSnapshotError.gitUnavailable }
        let caller = workingDirectory.resolvingSymlinksInPath().standardizedFileURL
        guard isDirectory(caller) else { throw WorkspaceSnapshotError.unsafeRepositoryPath }

        let bareResult = try await gitRaw(["rev-parse", "--is-bare-repository"], cwd: caller.path, allowFailure: true)
        if bareResult.exitCode != 0 { throw WorkspaceSnapshotError.notGitRepository }
        if text(bareResult.standardOutput) == "true" { throw WorkspaceSnapshotError.bareRepository }

        let topResult = try await gitRaw(["rev-parse", "--show-toplevel"], cwd: caller.path, allowFailure: true)
        guard topResult.exitCode == 0 else { throw WorkspaceSnapshotError.notGitRepository }
        let topText = text(topResult.standardOutput)
        guard topText.hasPrefix("/"), !topText.contains("\0") else { throw WorkspaceSnapshotError.unsafeRepositoryPath }
        let root = URL(fileURLWithPath: topText, isDirectory: true).resolvingSymlinksInPath().standardizedFileURL
        guard isDirectory(root), caller.path == root.path || caller.path.hasPrefix(root.path + "/") else {
            throw WorkspaceSnapshotError.unsafeRepositoryPath
        }

        let headResult = try await gitRaw(["rev-parse", "--verify", "HEAD^{commit}"], cwd: root.path, allowFailure: true)
        guard headResult.exitCode == 0 else { throw WorkspaceSnapshotError.unbornRepository }
        let headOID = text(headResult.standardOutput)
        guard Self.validOID(headOID) else { throw WorkspaceSnapshotError.unbornRepository }

        let trackedGitlinks = try await gitlinks(root: root, environment: nil)
        let submodules = try await validateSubmodules(trackedGitlinks, root: root)
        try rejectNestedRepositories(in: root, allowedRepositories: Set(submodules.map(\.path)))
        let paths = try await repositoryPaths(root: root)
        try validatePaths(paths, root: root)
        try await rejectLFS(paths: paths, root: root)

        let temporary = FileManager.default.temporaryDirectory.appendingPathComponent("workjet-workspace-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: temporary) }
        let index = temporary.appendingPathComponent("index").path
        let bundleURL = temporary.appendingPathComponent("snapshot.bundle")
        let temporaryRef = "refs/workjet/input-\(UUID().uuidString.lowercased())"
        var environment = Self.gitEnvironment
        environment["GIT_INDEX_FILE"] = index
        environment["GIT_AUTHOR_NAME"] = "Workjet Snapshot"
        environment["GIT_AUTHOR_EMAIL"] = "snapshot@workjet.invalid"
        environment["GIT_COMMITTER_NAME"] = "Workjet Snapshot"
        environment["GIT_COMMITTER_EMAIL"] = "snapshot@workjet.invalid"
        let timestamp = try await git(["show", "-s", "--format=%ct", headOID], cwd: root.path, environment: environment)
        environment["GIT_AUTHOR_DATE"] = "@\(text(timestamp.standardOutput)) +0000"
        environment["GIT_COMMITTER_DATE"] = "@\(text(timestamp.standardOutput)) +0000"

        var createdRefs: [(ref: String, oid: String)] = []
        do {
            _ = try await git(["read-tree", headOID], cwd: root.path, environment: environment)
            _ = try await git(["add", "-A", "--", "."], cwd: root.path, environment: environment, timeout: 120)
            let stagedGitlinks = try await gitlinks(root: root, environment: environment)
            guard Dictionary(uniqueKeysWithValues: stagedGitlinks.map { ($0.path, $0.commitOID) })
                    == Dictionary(uniqueKeysWithValues: submodules.map { ($0.path, $0.commitOID) }) else {
                throw WorkspaceSnapshotError.gitlink("staged gitlink changed")
            }
            let tree = text(try await git(["write-tree"], cwd: root.path, environment: environment).standardOutput)
            guard Self.validOID(tree) else { throw WorkspaceSnapshotError.gitFailed("invalid tree") }
            let commit = text(try await git(["commit-tree", tree, "-p", headOID], cwd: root.path, environment: environment, input: Data("Workjet immutable workspace snapshot\n".utf8)).standardOutput)
            guard Self.validOID(commit) else { throw WorkspaceSnapshotError.gitFailed("invalid commit") }
            _ = try await git(["update-ref", temporaryRef, commit, String(repeating: "0", count: commit.count)], cwd: root.path, environment: environment)
            createdRefs.append((temporaryRef, commit))

            let namespace = UUID().uuidString.lowercased()
            var manifestSubmodules: [WorkspaceSnapshotSubmodule] = []
            for (index, submodule) in submodules.enumerated() {
                let bundleRef = "refs/workjet/submodules/\(namespace)/\(index)"
                _ = try await git(["fetch", "--no-write-fetch-head", "--no-tags", "--no-recurse-submodules", submodule.repository.path, "\(submodule.commitOID):\(bundleRef)"], cwd: root.path, environment: environment, timeout: 120)
                createdRefs.append((bundleRef, submodule.commitOID))
                manifestSubmodules.append(WorkspaceSnapshotSubmodule(path: submodule.path, commitOID: submodule.commitOID, bundleRef: bundleRef))
            }
            _ = try await git(["bundle", "create", bundleURL.path] + createdRefs.map(\.ref), cwd: root.path, environment: environment, timeout: 180)
            for created in createdRefs.reversed() { try await removeTemporaryRef(created.ref, root: root, oid: created.oid) }
            createdRefs.removeAll()

            let attributes = try FileManager.default.attributesOfItem(atPath: bundleURL.path)
            guard let number = attributes[.size] as? NSNumber else { throw WorkspaceSnapshotError.malformedBundle }
            let byteSize = number.intValue
            guard byteSize > 0 else { throw WorkspaceSnapshotError.malformedBundle }
            guard byteSize <= maximumBundleBytes else { throw WorkspaceSnapshotError.bundleTooLarge(limit: maximumBundleBytes) }
            let bundle = try Data(contentsOf: bundleURL, options: [.mappedIfSafe])
            guard bundle.count == byteSize else { throw WorkspaceSnapshotError.malformedBundle }
            let roots = text(try await git(["rev-list", "--max-parents=0", headOID], cwd: root.path, environment: environment).standardOutput)
                .split(whereSeparator: \.isNewline).map(String.init).sorted().joined(separator: "\n")
            guard !roots.isEmpty else { throw WorkspaceSnapshotError.unbornRepository }
            let repoID = Self.sha256(Data(("workjet-repo-v1\0" + roots).utf8))
            return WorkspaceSnapshot(
                manifest: WorkspaceSnapshotManifest(schemaVersion: manifestSubmodules.isEmpty ? 1 : 2, repoID: repoID, snapshotCommitOID: commit, bundleSHA256: Self.sha256(bundle), byteSize: byteSize, submodules: manifestSubmodules),
                bundle: bundle,
                sourceRepositoryRoot: root
            )
        } catch {
            for created in createdRefs.reversed() { try? await removeTemporaryRef(created.ref, root: root, oid: nil) }
            throw error
        }
    }

    private func repositoryPaths(root: URL) async throws -> [String] {
        let result = try await git(["ls-files", "-co", "--exclude-standard", "-z"], cwd: root.path, environment: nil, stdoutLimit: 16 * 1_024 * 1_024)
        return result.standardOutput.split(separator: 0, omittingEmptySubsequences: true).map { String(decoding: $0, as: UTF8.self) }
    }

    private func validatePaths(_ paths: [String], root: URL) throws {
        for path in paths {
            let components = path.split(separator: "/", omittingEmptySubsequences: false)
            guard !path.isEmpty, !path.hasPrefix("/"), !path.contains("\0"), !path.unicodeScalars.contains(where: { $0.value < 0x20 || $0.value == 0x7f }),
                  !components.contains(where: { $0.isEmpty || $0 == "." || $0 == ".." }) else {
                throw WorkspaceSnapshotError.unsafePath(path)
            }
            let item = root.appendingPathComponent(path)
            var info = stat()
            if lstat(item.path, &info) == 0, (info.st_mode & S_IFMT) == S_IFLNK {
                throw WorkspaceSnapshotError.symlink(path)
            }
        }
    }

    private func rejectNestedRepositories(in root: URL, allowedRepositories: Set<String>) throws {
        guard let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey], options: []) else {
            throw WorkspaceSnapshotError.unsafeRepositoryPath
        }
        while let item = enumerator.nextObject() as? URL {
            if item.lastPathComponent == ".git" {
                let parent = item.deletingLastPathComponent().resolvingSymlinksInPath().standardizedFileURL
                if parent == root { enumerator.skipDescendants(); continue }
                let relative = parent.path.hasPrefix(root.path + "/") ? String(parent.path.dropFirst(root.path.count + 1)) : ""
                if allowedRepositories.contains(relative) { enumerator.skipDescendants(); continue }
                throw WorkspaceSnapshotError.nestedRepository(item.path)
            }
            let values = try item.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            if values.isSymbolicLink == true { enumerator.skipDescendants(); continue }
        }
    }

    private func gitlinks(root: URL, environment: [String: String]?) async throws -> [Gitlink] {
        let result = try await git(["ls-files", "--stage", "-z"], cwd: root.path, environment: environment, stdoutLimit: 16 * 1_024 * 1_024)
        var links: [Gitlink] = []
        for entry in result.standardOutput.split(separator: 0) {
            let value = String(decoding: entry, as: UTF8.self)
            guard value.hasPrefix("160000 ") else { continue }
            let fields = value.split(separator: "\t", maxSplits: 1, omittingEmptySubsequences: false)
            guard fields.count == 2 else { throw WorkspaceSnapshotError.gitlink("malformed gitlink") }
            let metadata = fields[0].split(separator: " ")
            let path = String(fields[1])
            guard metadata.count == 3, metadata[0] == "160000", metadata[2] == "0", Self.validOID(String(metadata[1])) else {
                throw WorkspaceSnapshotError.gitlink(path)
            }
            let components = path.split(separator: "/", omittingEmptySubsequences: false)
            guard components.count == 1, !path.isEmpty, !path.hasPrefix("/"), !path.contains("\0"),
                  !path.unicodeScalars.contains(where: { $0.value < 0x20 || $0.value == 0x7f }),
                  !components.contains(where: { $0.isEmpty || $0 == "." || $0 == ".." }) else {
                throw WorkspaceSnapshotError.gitlink(path)
            }
            links.append(Gitlink(path: path, commitOID: String(metadata[1]), repository: root.appendingPathComponent(path, isDirectory: true).standardizedFileURL))
        }
        return links.sorted { $0.path < $1.path }
    }

    private func validateSubmodules(_ links: [Gitlink], root: URL) async throws -> [Gitlink] {
        guard links.count <= 256 else { throw WorkspaceSnapshotError.gitlink("too many top-level submodules") }
        for link in links {
            let repository = link.repository.resolvingSymlinksInPath().standardizedFileURL
            guard repository.path == root.appendingPathComponent(link.path, isDirectory: true).resolvingSymlinksInPath().standardizedFileURL.path,
                  repository.path.hasPrefix(root.path + "/"), isDirectory(repository) else {
                throw WorkspaceSnapshotError.submoduleUnavailable(path: link.path, commitOID: link.commitOID)
            }
            let top = try await gitRaw(["rev-parse", "--show-toplevel"], cwd: repository.path, allowFailure: true)
            let head = try await gitRaw(["rev-parse", "--verify", "HEAD^{commit}"], cwd: repository.path, allowFailure: true)
            let pinned = try await gitRaw(["cat-file", "-e", "\(link.commitOID)^{commit}"], cwd: repository.path, allowFailure: true)
            guard top.exitCode == 0, URL(fileURLWithPath: text(top.standardOutput), isDirectory: true).resolvingSymlinksInPath().standardizedFileURL == repository,
                  head.exitCode == 0, text(head.standardOutput) == link.commitOID, pinned.exitCode == 0 else {
                throw WorkspaceSnapshotError.submoduleUnavailable(path: link.path, commitOID: link.commitOID)
            }
            let status = try await git(["status", "--porcelain=v1", "-z", "--untracked-files=all"], cwd: repository.path, environment: nil, stdoutLimit: 16 * 1_024 * 1_024)
            guard status.standardOutput.isEmpty else { throw WorkspaceSnapshotError.submoduleModified(link.path) }
            let nested = try await gitlinks(root: repository, environment: nil)
            guard nested.isEmpty else { throw WorkspaceSnapshotError.recursiveSubmodule(link.path + "/" + nested[0].path) }
            let paths = try await repositoryPaths(root: repository)
            try validatePaths(paths, root: repository)
            try await rejectLFS(paths: paths, root: repository)
        }
        return links
    }

    private func rejectLFS(paths: [String], root: URL) async throws {
        guard !paths.isEmpty else { return }
        var input = Data()
        for path in paths { input.append(Data(path.utf8)); input.append(0) }
        let result = try await git(["check-attr", "-z", "--stdin", "filter"], cwd: root.path, environment: nil, input: input, stdoutLimit: 32 * 1_024 * 1_024)
        let fields = result.standardOutput.split(separator: 0, omittingEmptySubsequences: false)
        var index = 0
        while index + 2 < fields.count {
            let path = String(decoding: fields[index], as: UTF8.self)
            let value = String(decoding: fields[index + 2], as: UTF8.self)
            if value == "lfs" { throw WorkspaceSnapshotError.lfsManaged(path) }
            index += 3
        }
    }

    private func removeTemporaryRef(_ ref: String, root: URL, oid: String?) async throws {
        var arguments = ["update-ref", "-d", ref]
        if let oid { arguments.append(oid) }
        let command = CommandSpec(executable: gitExecutable, arguments: arguments, currentDirectory: root.path, environment: Self.gitEnvironment, timeout: 30, stdoutLimit: 65_536, stderrLimit: 65_536)
        let result = try await ProcessCommandRunner().run(command)
        guard result.exitCode == 0 else { throw WorkspaceSnapshotError.gitFailed("temporary ref cleanup") }
    }

    private func git(_ arguments: [String], cwd: String, environment: [String: String]?, input: Data = Data(), timeout: TimeInterval = 60, stdoutLimit: Int = 4 * 1_024 * 1_024) async throws -> CommandResult {
        let result = try await gitRaw(arguments, cwd: cwd, environment: environment, input: input, timeout: timeout, stdoutLimit: stdoutLimit, allowFailure: false)
        return result
    }

    private func gitRaw(_ arguments: [String], cwd: String, environment: [String: String]? = nil, input: Data = Data(), timeout: TimeInterval = 60, stdoutLimit: Int = 4 * 1_024 * 1_024, allowFailure: Bool) async throws -> CommandResult {
        let safeEnvironment = environment ?? Self.gitEnvironment
        let result: CommandResult
        do {
            result = try await runner.run(CommandSpec(executable: gitExecutable, arguments: arguments, standardInput: input, currentDirectory: cwd, environment: safeEnvironment, timeout: timeout, stdoutLimit: stdoutLimit, stderrLimit: 1_048_576))
        } catch {
            throw WorkspaceSnapshotError.gitFailed(error.localizedDescription)
        }
        guard !result.stdoutTruncated, !result.stderrTruncated else { throw WorkspaceSnapshotError.gitFailed("bounded git output exceeded") }
        if !allowFailure, result.exitCode != 0 {
            throw WorkspaceSnapshotError.gitFailed(String(decoding: result.standardError.prefix(2_048), as: UTF8.self))
        }
        return result
    }

    private func isDirectory(_ url: URL) -> Bool {
        var info = stat()
        return lstat(url.path, &info) == 0 && (info.st_mode & S_IFMT) == S_IFDIR
    }

    private func text(_ data: Data) -> String {
        String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Snapshot Git commands deliberately do not inherit the caller's Git
    /// repository selectors, config injection, credential helpers, or lazy-fetch
    /// settings. Repository selection is exclusively the validated cwd.
    private static let gitEnvironment = [
        "HOME": "/var/empty",
        "PATH": "/usr/bin:/bin",
        "LC_ALL": "C",
        "GIT_CONFIG_NOSYSTEM": "1",
        "GIT_CONFIG_GLOBAL": "/dev/null",
        "GIT_TERMINAL_PROMPT": "0",
        "GIT_OPTIONAL_LOCKS": "0",
        "GIT_NO_LAZY_FETCH": "1"
    ]

    private static func validOID(_ value: String) -> Bool {
        value.range(of: "^(?:[0-9a-f]{40}|[0-9a-f]{64})$", options: .regularExpression) != nil
    }

    private static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}

public struct WorkspaceResultManifest: Codable, Equatable, Sendable {
    public var schemaVersion: Int
    public var runID: String
    public var repoID: String
    public var snapshotCommitOID: String
    public var resultCommitOID: String
    public var bundleSHA256: String
    public var byteSize: Int
    public var terminalState: RemoteHostRunState?

    public init(schemaVersion: Int = 1, runID: String, repoID: String, snapshotCommitOID: String, resultCommitOID: String, bundleSHA256: String, byteSize: Int, terminalState: RemoteHostRunState? = nil) {
        self.schemaVersion = schemaVersion
        self.runID = runID
        self.repoID = repoID
        self.snapshotCommitOID = snapshotCommitOID
        self.resultCommitOID = resultCommitOID
        self.bundleSHA256 = bundleSHA256
        self.byteSize = byteSize
        self.terminalState = terminalState
    }
}

public struct WorkspaceResult: Equatable, Sendable {
    public var manifest: WorkspaceResultManifest
    public var bundle: Data

    public init(manifest: WorkspaceResultManifest, bundle: Data) {
        self.manifest = manifest
        self.bundle = bundle
    }
}

public enum RemoteWorkspaceLifecycle: String, Codable, Equatable, Sendable {
    case started
    case imported
    case integrated
    case abandoned
}

public struct GitRepositoryIdentity: Codable, Equatable, Sendable {
    public var rootDevice: UInt64
    public var rootInode: UInt64
    public var gitDirectory: String
    public var gitDevice: UInt64
    public var gitInode: UInt64

    public init(rootDevice: UInt64, rootInode: UInt64, gitDirectory: String, gitDevice: UInt64, gitInode: UInt64) {
        self.rootDevice = rootDevice
        self.rootInode = rootInode
        self.gitDirectory = gitDirectory
        self.gitDevice = gitDevice
        self.gitInode = gitInode
    }
}

public struct RemoteWorkspaceRunRecord: Codable, Equatable, Sendable {
    public var schemaVersion: Int
    public var runID: String
    public var sourceRepositoryRoot: String
    public var computerID: UUID
    public var ownerID: String
    public var repoID: String
    public var snapshotCommitOID: String
    public var repositoryIdentity: GitRepositoryIdentity
    public var lifecycle: RemoteWorkspaceLifecycle
    public var resultCommitOID: String?
    public var resultRef: String?
    public var terminalState: RemoteHostRunState?
    /// Present only for local repository runs. Older remote records decode
    /// without these fields and retain their existing lifecycle behavior.
    public var localWorktreePath: String?
    public var localRepositoryPath: String?

    public init(schemaVersion: Int = 1, runID: String, sourceRepositoryRoot: String, computerID: UUID, ownerID: String, repoID: String, snapshotCommitOID: String, repositoryIdentity: GitRepositoryIdentity, lifecycle: RemoteWorkspaceLifecycle = .started, resultCommitOID: String? = nil, resultRef: String? = nil, terminalState: RemoteHostRunState? = nil, localWorktreePath: String? = nil, localRepositoryPath: String? = nil) {
        self.schemaVersion = schemaVersion
        self.runID = runID
        self.sourceRepositoryRoot = sourceRepositoryRoot
        self.computerID = computerID
        self.ownerID = ownerID
        self.repoID = repoID
        self.snapshotCommitOID = snapshotCommitOID
        self.repositoryIdentity = repositoryIdentity
        self.lifecycle = lifecycle
        self.resultCommitOID = resultCommitOID
        self.resultRef = resultRef
        self.terminalState = terminalState
        self.localWorktreePath = localWorktreePath
        self.localRepositoryPath = localRepositoryPath
    }
}

public struct WorkspaceResultImportReceipt: Codable, Equatable, Sendable {
    public var runID: String
    public var resultRef: String
    public var resultCommitOID: String
    public var lifecycle: RemoteWorkspaceLifecycle
    public var terminalState: RemoteHostRunState?

    public init(runID: String, resultRef: String, resultCommitOID: String, lifecycle: RemoteWorkspaceLifecycle, terminalState: RemoteHostRunState? = nil) {
        self.runID = runID
        self.resultRef = resultRef
        self.resultCommitOID = resultCommitOID
        self.lifecycle = lifecycle
        self.terminalState = terminalState
    }
}

public struct WorkspaceLifecycleReceipt: Codable, Equatable, Sendable {
    public var runID: String
    public var lifecycle: RemoteWorkspaceLifecycle
    public var resultRef: String?
    public var resultCommitOID: String?
    public var terminalState: RemoteHostRunState

    public init(runID: String, lifecycle: RemoteWorkspaceLifecycle, resultRef: String? = nil, resultCommitOID: String? = nil, terminalState: RemoteHostRunState) {
        self.runID = runID
        self.lifecycle = lifecycle
        self.resultRef = resultRef
        self.resultCommitOID = resultCommitOID
        self.terminalState = terminalState
    }
}

public enum WorkspaceResultError: LocalizedError, Equatable, Sendable {
    case invalidRunID
    case recordNotFound
    case invalidRecord
    case repositoryChanged
    case repositoryUnsafe
    case identityMismatch
    case resultMalformed
    case resultTooLarge
    case resultMismatch
    case resultNotDescendant
    case conflictingRef
    case importFailed
    case runNotTerminal
    case integratedBeforeImport
    case dispositionConflict
    case submoduleChanged(String)
    case localPersistenceAfterRemoteCleanup

    public var errorDescription: String? {
        switch self {
        case .invalidRunID: return "Die Run-ID ist ungültig."
        case .recordNotFound: return "Für diesen Run ist kein lokales Remote-Workspace verzeichnet."
        case .invalidRecord: return "Der lokale Remote-Workspace-Datensatz ist ungültig."
        case .repositoryChanged: return "Das ursprüngliche lokale Git-Repository stimmt nicht mehr mit dem Run überein."
        case .repositoryUnsafe: return "Das ursprüngliche lokale Git-Repository ist nicht mehr sicher zugänglich."
        case .identityMismatch: return "Das Remote-Ergebnis gehört nicht zu diesem Run oder Repository."
        case .resultMalformed: return "Der Remote-Host hat kein gültiges Ergebnis-Bundle geliefert."
        case .resultTooLarge: return "Das Remote-Ergebnis überschreitet das Limit von 64 MiB."
        case .resultMismatch: return "Prüfsumme, Größe oder Commit des Remote-Ergebnisses stimmen nicht."
        case .resultNotDescendant: return "Der Ergebnis-Commit stammt nicht vom importierten Workspace-Snapshot ab."
        case .conflictingRef: return "Der lokale Workjet-Ergebnis-Ref zeigt bereits auf einen anderen Commit."
        case .importFailed: return "Das Remote-Ergebnis konnte nicht sicher in das lokale Repository importiert werden."
        case .runNotTerminal: return "Der Remote-Run ist noch nicht terminal."
        case .integratedBeforeImport: return "Ein Run kann erst nach einem verifizierten Ergebnis-Import als integriert markiert werden."
        case .dispositionConflict: return "Der Run wurde bereits mit einer anderen Lifecycle-Markierung abgeschlossen."
        case let .submoduleChanged(path): return "Das angeheftete Submodule \(path) wurde im Worker-Workspace verändert. Submodule sind schreibgeschützt; das Ergebnis wurde verworfen."
        case .localPersistenceAfterRemoteCleanup: return "Der Remote-Workspace wurde bereinigt, aber die lokale Lifecycle-Markierung konnte nicht gespeichert werden. Wiederhole den Befehl."
        }
    }
}

public struct GitRepositoryInspector: Sendable {
    private let runner: any CommandRunning
    private let gitExecutable = "/usr/bin/git"

    public init(runner: any CommandRunning = ProcessCommandRunner()) {
        self.runner = runner
    }

    public func inspect(root: URL, expectedRepoID: String) async throws -> GitRepositoryIdentity {
        guard root.path.hasPrefix("/"), !root.path.contains("\0"), Self.validDigest(expectedRepoID) else { throw WorkspaceResultError.repositoryUnsafe }
        guard let canonicalPath = realPath(root.path) else { throw WorkspaceResultError.repositoryUnsafe }
        guard let rootStat = safeDirectory(canonicalPath) else { throw WorkspaceResultError.repositoryUnsafe }
        let top = try await git(["rev-parse", "--show-toplevel"], cwd: canonicalPath)
        let topText = String(decoding: top.standardOutput, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        guard realPath(topText) == canonicalPath else { throw WorkspaceResultError.repositoryChanged }
        let bare = try await git(["rev-parse", "--is-bare-repository"], cwd: canonicalPath)
        guard text(bare.standardOutput) == "false" else { throw WorkspaceResultError.repositoryChanged }
        let inside = try await git(["rev-parse", "--is-inside-work-tree"], cwd: canonicalPath)
        guard text(inside.standardOutput) == "true" else { throw WorkspaceResultError.repositoryChanged }
        let gitDirectoryText = text(try await git(["rev-parse", "--absolute-git-dir"], cwd: canonicalPath).standardOutput)
        guard gitDirectoryText.hasPrefix("/"), !gitDirectoryText.contains("\0") else { throw WorkspaceResultError.repositoryUnsafe }
        guard let gitCanonicalPath = realPath(gitDirectoryText) else { throw WorkspaceResultError.repositoryUnsafe }
        let gitDirectory = URL(fileURLWithPath: gitCanonicalPath, isDirectory: true).standardizedFileURL
        guard let gitStat = safeDirectory(gitDirectory.path) else { throw WorkspaceResultError.repositoryUnsafe }
        let head = text(try await git(["rev-parse", "--verify", "HEAD^{commit}"], cwd: canonicalPath).standardOutput)
        guard Self.validOID(head) else { throw WorkspaceResultError.repositoryChanged }
        let roots = text(try await git(["rev-list", "--max-parents=0", head], cwd: canonicalPath, stdoutLimit: 1_048_576).standardOutput)
            .split(whereSeparator: \.isNewline).map(String.init).sorted().joined(separator: "\n")
        guard !roots.isEmpty, Self.sha256(Data(("workjet-repo-v1\0" + roots).utf8)) == expectedRepoID else { throw WorkspaceResultError.repositoryChanged }
        return GitRepositoryIdentity(
            rootDevice: UInt64(rootStat.st_dev), rootInode: UInt64(rootStat.st_ino),
            gitDirectory: gitDirectory.path, gitDevice: UInt64(gitStat.st_dev), gitInode: UInt64(gitStat.st_ino)
        )
    }

    public func validate(root: URL, expectedRepoID: String, identity: GitRepositoryIdentity) async throws {
        let current = try await inspect(root: root, expectedRepoID: expectedRepoID)
        guard current == identity else { throw WorkspaceResultError.repositoryChanged }
    }

    private func git(_ arguments: [String], cwd: String, stdoutLimit: Int = 65_536) async throws -> CommandResult {
        guard FileManager.default.isExecutableFile(atPath: gitExecutable) else { throw WorkspaceResultError.repositoryUnsafe }
        let result: CommandResult
        do {
            result = try await runner.run(CommandSpec(executable: gitExecutable, arguments: arguments, currentDirectory: cwd, environment: Self.gitEnvironment, timeout: 30, stdoutLimit: stdoutLimit, stderrLimit: 65_536))
        } catch { throw WorkspaceResultError.repositoryUnsafe }
        guard result.exitCode == 0, !result.stdoutTruncated, !result.stderrTruncated else { throw WorkspaceResultError.repositoryChanged }
        return result
    }

    private func realPath(_ path: String) -> String? {
        guard path.hasPrefix("/"), let pointer = Darwin.realpath(path, nil) else { return nil }
        defer { free(pointer) }
        return String(cString: pointer)
    }

    private func safeDirectory(_ path: String) -> stat? {
        var value = stat()
        guard lstat(path, &value) == 0, (value.st_mode & S_IFMT) == S_IFDIR, value.st_uid == geteuid() else { return nil }
        return value
    }

    private func text(_ data: Data) -> String { String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines) }
    static let gitEnvironment = ["HOME": "/var/empty", "PATH": "/usr/bin:/bin", "LC_ALL": "C", "GIT_TERMINAL_PROMPT": "0", "GIT_OPTIONAL_LOCKS": "0", "GIT_CONFIG_NOSYSTEM": "1", "GIT_NO_LAZY_FETCH": "1"]
    static func validOID(_ value: String) -> Bool { value.range(of: "^(?:[0-9a-f]{40}|[0-9a-f]{64})$", options: .regularExpression) != nil }
    static func validDigest(_ value: String) -> Bool { value.range(of: "^[0-9a-f]{64}$", options: .regularExpression) != nil }
    static func sha256(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
}

public struct LocalWorkspaceResultImporter: Sendable {
    public static let maximumBundleBytes = 64 * 1_024 * 1_024
    private let runner: any CommandRunning
    private let inspector: GitRepositoryInspector
    private let gitExecutable = "/usr/bin/git"

    public init(runner: any CommandRunning = ProcessCommandRunner()) {
        self.runner = runner
        self.inspector = GitRepositoryInspector(runner: runner)
    }

    public func importResult(_ result: WorkspaceResult, for record: RemoteWorkspaceRunRecord, temporaryRoot: URL) async throws -> WorkspaceResultImportReceipt {
        try validate(result.manifest, bundle: result.bundle, record: record)
        let root = URL(fileURLWithPath: record.sourceRepositoryRoot, isDirectory: true).standardizedFileURL
        try await inspector.validate(root: root, expectedRepoID: record.repoID, identity: record.repositoryIdentity)
        let targetRef = "refs/workjet/\(record.runID)"
        let existing = try await gitRaw(["show-ref", "--verify", "--hash", targetRef], cwd: root.path, allowFailure: true)
        let targetAlreadyMatches = existing.exitCode == 0
        if targetAlreadyMatches, text(existing.standardOutput) != result.manifest.resultCommitOID { throw WorkspaceResultError.conflictingRef }

        let temporary = temporaryRoot.appendingPathComponent("result-import-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: temporary) }
        let bundleURL = temporary.appendingPathComponent("result.bundle")
        try AtomicFile.write(result.bundle, to: bundleURL)
        let temporaryRef = "refs/workjet/imports/\(UUID().uuidString.lowercased())"
        var temporaryRefCreated = false
        do {
            _ = try await git(["bundle", "verify", bundleURL.path], cwd: root.path, timeout: 90)
            let heads = try await git(["bundle", "list-heads", bundleURL.path], cwd: root.path)
            let advertised = String(decoding: heads.standardOutput, as: UTF8.self).split(whereSeparator: \.isNewline).contains { $0.hasPrefix(result.manifest.resultCommitOID + " ") }
            guard advertised else { throw WorkspaceResultError.resultMismatch }
            if targetAlreadyMatches {
                let importedOID = text(try await git(["rev-parse", "--verify", "\(targetRef)^{commit}"], cwd: root.path).standardOutput)
                guard importedOID == result.manifest.resultCommitOID else { throw WorkspaceResultError.resultMismatch }
                let ancestor = try await gitRaw(["merge-base", "--is-ancestor", record.snapshotCommitOID, importedOID], cwd: root.path, allowFailure: true)
                guard ancestor.exitCode == 0 else { throw WorkspaceResultError.resultNotDescendant }
                return WorkspaceResultImportReceipt(runID: record.runID, resultRef: targetRef, resultCommitOID: importedOID, lifecycle: .imported, terminalState: result.manifest.terminalState)
            }
            _ = try await git(["fetch", "--no-write-fetch-head", "--no-tags", bundleURL.path, "\(result.manifest.resultCommitOID):\(temporaryRef)"], cwd: root.path, timeout: 120)
            temporaryRefCreated = true
            let importedOID = text(try await git(["rev-parse", "--verify", "\(temporaryRef)^{commit}"], cwd: root.path).standardOutput)
            guard importedOID == result.manifest.resultCommitOID else { throw WorkspaceResultError.resultMismatch }
            let ancestor = try await gitRaw(["merge-base", "--is-ancestor", record.snapshotCommitOID, importedOID], cwd: root.path, allowFailure: true)
            guard ancestor.exitCode == 0 else { throw WorkspaceResultError.resultNotDescendant }
            let create = try await gitRaw(["update-ref", targetRef, importedOID, String(repeating: "0", count: importedOID.count)], cwd: root.path, allowFailure: true)
            if create.exitCode != 0 {
                let raced = try await gitRaw(["show-ref", "--verify", "--hash", targetRef], cwd: root.path, allowFailure: true)
                guard raced.exitCode == 0, text(raced.standardOutput) == importedOID else { throw WorkspaceResultError.conflictingRef }
            }
            try await deleteRef(temporaryRef, oid: importedOID, cwd: root.path)
            temporaryRefCreated = false
            return WorkspaceResultImportReceipt(runID: record.runID, resultRef: targetRef, resultCommitOID: importedOID, lifecycle: .imported, terminalState: result.manifest.terminalState)
        } catch {
            if temporaryRefCreated { try? await deleteRef(temporaryRef, oid: nil, cwd: root.path) }
            if let typed = error as? WorkspaceResultError { throw typed }
            throw WorkspaceResultError.importFailed
        }
    }

    private func validate(_ manifest: WorkspaceResultManifest, bundle: Data, record: RemoteWorkspaceRunRecord) throws {
        guard manifest.schemaVersion == 1,
              Self.safeRunID(manifest.runID), GitRepositoryInspector.validDigest(manifest.repoID),
              GitRepositoryInspector.validOID(manifest.snapshotCommitOID), GitRepositoryInspector.validOID(manifest.resultCommitOID),
              GitRepositoryInspector.validDigest(manifest.bundleSHA256), manifest.byteSize > 0 else { throw WorkspaceResultError.resultMalformed }
        guard manifest.byteSize <= Self.maximumBundleBytes, bundle.count <= Self.maximumBundleBytes else { throw WorkspaceResultError.resultTooLarge }
        guard manifest.runID == record.runID, manifest.repoID == record.repoID, manifest.snapshotCommitOID == record.snapshotCommitOID else { throw WorkspaceResultError.identityMismatch }
        guard manifest.byteSize == bundle.count, manifest.bundleSHA256 == GitRepositoryInspector.sha256(bundle) else { throw WorkspaceResultError.resultMismatch }
        guard let state = manifest.terminalState, state.isTerminal else { throw WorkspaceResultError.runNotTerminal }
    }

    private func deleteRef(_ ref: String, oid: String?, cwd: String) async throws {
        var arguments = ["update-ref", "-d", ref]
        if let oid { arguments.append(oid) }
        let result = try await gitRaw(arguments, cwd: cwd, allowFailure: true)
        guard result.exitCode == 0 else { throw WorkspaceResultError.importFailed }
    }

    private func git(_ arguments: [String], cwd: String, timeout: TimeInterval = 60) async throws -> CommandResult {
        let result = try await gitRaw(arguments, cwd: cwd, timeout: timeout, allowFailure: false)
        return result
    }

    private func gitRaw(_ arguments: [String], cwd: String, timeout: TimeInterval = 60, allowFailure: Bool) async throws -> CommandResult {
        let result: CommandResult
        do {
            result = try await runner.run(CommandSpec(executable: gitExecutable, arguments: arguments, currentDirectory: cwd, environment: GitRepositoryInspector.gitEnvironment, timeout: timeout, stdoutLimit: 4 * 1_024 * 1_024, stderrLimit: 1_048_576))
        } catch { throw WorkspaceResultError.importFailed }
        guard !result.stdoutTruncated, !result.stderrTruncated else { throw WorkspaceResultError.importFailed }
        if !allowFailure, result.exitCode != 0 { throw WorkspaceResultError.importFailed }
        return result
    }

    private func text(_ data: Data) -> String { String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines) }
    public static func safeRunID(_ value: String) -> Bool {
        value.range(of: "^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$", options: .regularExpression) != nil
            && !value.contains("..") && !value.contains("@{") && !value.hasSuffix(".") && !value.hasSuffix(".lock")
    }
}
