import CryptoKit
import Darwin
import Foundation
import XCTest
@testable import WorkjetCore

final class RemoteWorkspaceTests: XCTestCase {
    private struct RepositoryFixture {
        let root: URL
        let repository: URL
    }

    private actor CapturingRunner: CommandRunning {
        private var commands: [CommandSpec] = []
        var response: CommandResult
        init(response: CommandResult) { self.response = response }
        func run(_ command: CommandSpec) async throws -> CommandResult { commands.append(command); return response }
        func recorded() -> [CommandSpec] { commands }
    }

    private actor BundleFailureRunner: CommandRunning {
        func run(_ command: CommandSpec) async throws -> CommandResult {
            if command.arguments.prefix(2) == ["bundle", "create"] { throw CommandRunError.launch("injected bundle failure") }
            return try await ProcessCommandRunner().run(command)
        }
    }

    private actor CleanupClient: RemoteHostCalling {
        private var requests: [RemoteHostRequest] = []
        func call(_ request: RemoteHostRequest) async throws -> RemoteHostResponse {
            requests.append(request)
            if request.operation == .stop { throw RemoteHostProtocolError.transport("injected stop failure") }
            return RemoteHostResponse(ok: true, runID: request.runID, state: .stopped, workspaceDisposition: request.workspaceDisposition)
        }
        func recorded() -> [RemoteHostRequest] { requests }
    }

    private func repository() throws -> RepositoryFixture {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("workjet-workspace-tests-\(UUID().uuidString)", isDirectory: true)
        let repository = root.appendingPathComponent("repo", isDirectory: true)
        try FileManager.default.createDirectory(at: repository, withIntermediateDirectories: true)
        _ = try git(["init"], cwd: repository)
        try Data("tracked original\n".utf8).write(to: repository.appendingPathComponent("tracked.txt"))
        try Data("delete me\n".utf8).write(to: repository.appendingPathComponent("deleted.txt"))
        try Data("ignored.txt\n".utf8).write(to: repository.appendingPathComponent(".gitignore"))
        _ = try git(["add", "."], cwd: repository)
        _ = try git(["commit", "-m", "initial"], cwd: repository)
        return RepositoryFixture(root: root, repository: repository)
    }

    private func git(_ arguments: [String], cwd: URL, input: Data = Data()) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = arguments
        process.currentDirectoryURL = cwd
        var environment = ProcessInfo.processInfo.environment
        environment["GIT_AUTHOR_NAME"] = "Workspace Fixture"
        environment["GIT_AUTHOR_EMAIL"] = "workspace@example.invalid"
        environment["GIT_COMMITTER_NAME"] = "Workspace Fixture"
        environment["GIT_COMMITTER_EMAIL"] = "workspace@example.invalid"
        environment["GIT_TERMINAL_PROMPT"] = "0"
        environment["LC_ALL"] = "C"
        process.environment = environment
        let stdin = Pipe(), stdout = Pipe(), stderr = Pipe()
        process.standardInput = stdin; process.standardOutput = stdout; process.standardError = stderr
        try process.run()
        stdin.fileHandleForWriting.write(input); try stdin.fileHandleForWriting.close()
        process.waitUntilExit()
        let output = stdout.fileHandleForReading.readDataToEndOfFile()
        let diagnostic = stderr.fileHandleForReading.readDataToEndOfFile()
        guard process.terminationStatus == 0 else {
            throw NSError(domain: "git", code: Int(process.terminationStatus), userInfo: [NSLocalizedDescriptionKey: String(decoding: diagnostic, as: UTF8.self)])
        }
        return String(decoding: output, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private struct RepositoryState: Equatable {
        var branch: String
        var head: String
        var index: Data
        var status: Data
        var tracked: Data
        var stash: String
        var refs: String
    }

    private func state(_ repository: URL) throws -> RepositoryState {
        let status = try commandData("/usr/bin/git", ["status", "--porcelain=v1", "-z", "--untracked-files=all"], cwd: repository)
        return RepositoryState(
            branch: try git(["symbolic-ref", "HEAD"], cwd: repository),
            head: try git(["rev-parse", "HEAD"], cwd: repository),
            index: try Data(contentsOf: repository.appendingPathComponent(".git/index")),
            status: status,
            tracked: try Data(contentsOf: repository.appendingPathComponent("tracked.txt")),
            stash: try git(["stash", "list", "--format=%H"], cwd: repository),
            refs: try git(["for-each-ref", "--format=%(refname) %(objectname)"], cwd: repository)
        )
    }

    private func commandData(_ executable: String, _ arguments: [String], cwd: URL? = nil) throws -> Data {
        let process = Process(); process.executableURL = URL(fileURLWithPath: executable); process.arguments = arguments; process.currentDirectoryURL = cwd
        let output = Pipe(), error = Pipe(); process.standardOutput = output; process.standardError = error
        try process.run(); process.waitUntilExit()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        let diagnostic = error.fileHandleForReading.readDataToEndOfFile()
        guard process.terminationStatus == 0 else { throw NSError(domain: "command", code: Int(process.terminationStatus), userInfo: [NSLocalizedDescriptionKey: String(decoding: diagnostic, as: UTF8.self)]) }
        return data
    }

    private func materialize(_ snapshot: WorkspaceSnapshot, under root: URL) throws -> URL {
        let bundle = root.appendingPathComponent("snapshot.bundle")
        let bare = root.appendingPathComponent("cache.git")
        let worktree = root.appendingPathComponent("materialized")
        try snapshot.bundle.write(to: bundle)
        _ = try git(["init", "--bare", bare.path], cwd: root)
        _ = try git(["--git-dir=\(bare.path)", "fetch", "--no-tags", bundle.path, snapshot.manifest.snapshotCommitOID], cwd: root)
        _ = try git(["--git-dir=\(bare.path)", "worktree", "add", "--detach", worktree.path, snapshot.manifest.snapshotCommitOID], cwd: root)
        return worktree
    }

    func testCleanAndDirtySnapshotsContainExactFilesWithoutMutatingCallerState() async throws {
        let fixture = try repository(); defer { try? FileManager.default.removeItem(at: fixture.root) }
        let preparer = GitWorkspaceSnapshotPreparer()

        let subdirectory = fixture.repository.appendingPathComponent("subdir").creatingDirectory()
        let cleanBefore = try state(fixture.repository)
        let clean = try await preparer.prepare(from: subdirectory)
        XCTAssertEqual(try state(fixture.repository), cleanBefore)
        XCTAssertEqual(clean.manifest.schemaVersion, 1)
        XCTAssertEqual(clean.manifest.byteSize, clean.bundle.count)
        XCTAssertEqual(clean.manifest.bundleSHA256, SHA256.hash(data: clean.bundle).map { String(format: "%02x", $0) }.joined())
        let cleanTree = try materialize(clean, under: fixture.root.appendingPathComponent("clean", isDirectory: true).creatingDirectory())
        XCTAssertEqual(try String(contentsOf: cleanTree.appendingPathComponent("tracked.txt"), encoding: .utf8), "tracked original\n")

        try Data("tracked dirty\n".utf8).write(to: fixture.repository.appendingPathComponent("tracked.txt"))
        try FileManager.default.removeItem(at: fixture.repository.appendingPathComponent("deleted.txt"))
        try Data("untracked\n".utf8).write(to: fixture.repository.appendingPathComponent("untracked.txt"))
        try Data("ignored secret\n".utf8).write(to: fixture.repository.appendingPathComponent("ignored.txt"))
        let dirtyBefore = try state(fixture.repository)
        let dirty = try await preparer.prepare(from: fixture.repository)
        XCTAssertEqual(try state(fixture.repository), dirtyBefore)
        XCTAssertFalse(String(data: try JSONEncoder().encode(dirty.manifest), encoding: .utf8)!.contains(fixture.repository.path))
        let dirtyTree = try materialize(dirty, under: fixture.root.appendingPathComponent("dirty", isDirectory: true).creatingDirectory())
        XCTAssertEqual(try String(contentsOf: dirtyTree.appendingPathComponent("tracked.txt"), encoding: .utf8), "tracked dirty\n")
        XCTAssertEqual(try String(contentsOf: dirtyTree.appendingPathComponent("untracked.txt"), encoding: .utf8), "untracked\n")
        XCTAssertFalse(FileManager.default.fileExists(atPath: dirtyTree.appendingPathComponent("deleted.txt").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: dirtyTree.appendingPathComponent("ignored.txt").path))
    }

    func testSnapshotIgnoresForeignGitRepositoryEnvironmentAndNeverTouchesIt() async throws {
        let repoA = try repository(); defer { try? FileManager.default.removeItem(at: repoA.root) }
        let repoB = try repository(); defer { try? FileManager.default.removeItem(at: repoB.root) }
        try Data("repository A only\n".utf8).write(to: repoA.repository.appendingPathComponent("tracked.txt"))
        try Data("repository B only\n".utf8).write(to: repoB.repository.appendingPathComponent("tracked.txt"))

        let previousGitDir = getenv("GIT_DIR").map { String(cString: $0) }
        let previousGitWorkTree = getenv("GIT_WORK_TREE").map { String(cString: $0) }
        let snapshot: WorkspaceSnapshot
        do {
            setenv("GIT_DIR", repoB.repository.appendingPathComponent(".git").path, 1)
            setenv("GIT_WORK_TREE", repoB.repository.path, 1)
            defer {
                restoreEnvironment("GIT_DIR", to: previousGitDir)
                restoreEnvironment("GIT_WORK_TREE", to: previousGitWorkTree)
            }
            snapshot = try await GitWorkspaceSnapshotPreparer().prepare(from: repoA.repository)
        }

        XCTAssertEqual(snapshot.sourceRepositoryRoot, repoA.repository.resolvingSymlinksInPath().standardizedFileURL)
        let materializedRoot = repoA.root.appendingPathComponent("foreign-environment-materialized", isDirectory: true).creatingDirectory()
        let worktree = try materialize(snapshot, under: materializedRoot)
        XCTAssertEqual(try String(contentsOf: worktree.appendingPathComponent("tracked.txt"), encoding: .utf8), "repository A only\n")
        XCTAssertFalse(try git(["for-each-ref", "--format=%(refname)", "refs/workjet"], cwd: repoB.repository).contains("refs/workjet"))
    }

    func testInjectedFailureRemovesTemporaryRefAndPreservesRepositoryExactly() async throws {
        let fixture = try repository(); defer { try? FileManager.default.removeItem(at: fixture.root) }
        try Data("dirty\n".utf8).write(to: fixture.repository.appendingPathComponent("tracked.txt"))
        let before = try state(fixture.repository)
        do {
            _ = try await GitWorkspaceSnapshotPreparer(runner: BundleFailureRunner()).prepare(from: fixture.repository)
            XCTFail("expected injected failure")
        } catch let error as WorkspaceSnapshotError {
            guard case .gitFailed = error else { return XCTFail("unexpected error \(error)") }
        }
        XCTAssertEqual(try state(fixture.repository), before)
        XCTAssertFalse(try git(["for-each-ref", "--format=%(refname)", "refs/workjet"], cwd: fixture.repository).contains("refs/workjet"))
    }

    func testSnapshotRejectsUnsupportedRepositoryShapesAndOversize() async throws {
        let nonGit = FileManager.default.temporaryDirectory.appendingPathComponent("not-git-\(UUID().uuidString)").creatingDirectory()
        defer { try? FileManager.default.removeItem(at: nonGit) }
        await assertSnapshotError(.notGitRepository, at: nonGit)

        let unborn = FileManager.default.temporaryDirectory.appendingPathComponent("unborn-\(UUID().uuidString)").creatingDirectory()
        defer { try? FileManager.default.removeItem(at: unborn) }
        _ = try git(["init"], cwd: unborn)
        await assertSnapshotError(.unbornRepository, at: unborn)

        let bare = FileManager.default.temporaryDirectory.appendingPathComponent("bare-\(UUID().uuidString)").creatingDirectory()
        defer { try? FileManager.default.removeItem(at: bare) }
        _ = try git(["init", "--bare"], cwd: bare)
        await assertSnapshotError(.bareRepository, at: bare)

        let nested = try repository(); defer { try? FileManager.default.removeItem(at: nested.root) }
        let nestedRepo = nested.repository.appendingPathComponent("nested").creatingDirectory()
        _ = try git(["init"], cwd: nestedRepo)
        await assertSnapshotCase(at: nested.repository) { if case .nestedRepository = $0 { return true }; return false }

        let lfs = try repository(); defer { try? FileManager.default.removeItem(at: lfs.root) }
        try Data("*.bin filter=lfs diff=lfs merge=lfs -text\n".utf8).write(to: lfs.repository.appendingPathComponent(".gitattributes"))
        try Data("payload".utf8).write(to: lfs.repository.appendingPathComponent("asset.bin"))
        await assertSnapshotCase(at: lfs.repository) { if case .lfsManaged = $0 { return true }; return false }

        let symlink = try repository(); defer { try? FileManager.default.removeItem(at: symlink.root) }
        try FileManager.default.createSymbolicLink(atPath: symlink.repository.appendingPathComponent("escape").path, withDestinationPath: "/etc/passwd")
        await assertSnapshotCase(at: symlink.repository) { if case .symlink = $0 { return true }; return false }

        let unsafe = try repository(); defer { try? FileManager.default.removeItem(at: unsafe.root) }
        try Data("unsafe".utf8).write(to: unsafe.repository.appendingPathComponent("line\nbreak.txt"))
        await assertSnapshotCase(at: unsafe.repository) { if case .unsafePath = $0 { return true }; return false }

        let oversized = try repository(); defer { try? FileManager.default.removeItem(at: oversized.root) }
        try Data((0..<4096).map { UInt8($0 % 251) }).write(to: oversized.repository.appendingPathComponent("large.bin"))
        do {
            _ = try await GitWorkspaceSnapshotPreparer(maximumBundleBytes: 128).prepare(from: oversized.repository)
            XCTFail("expected oversize rejection")
        } catch let error as WorkspaceSnapshotError {
            XCTAssertEqual(error, .bundleTooLarge(limit: 128))
        }

        let gitlink = try repository(); defer { try? FileManager.default.removeItem(at: gitlink.root) }
        let head = try git(["rev-parse", "HEAD"], cwd: gitlink.repository)
        _ = try git(["update-index", "--add", "--cacheinfo", "160000,\(head),submodule"], cwd: gitlink.repository)
        await assertSnapshotCase(at: gitlink.repository) { if case .gitlink = $0 { return true }; return false }
    }

    private func restoreEnvironment(_ name: String, to value: String?) {
        if let value { setenv(name, value, 1) }
        else { unsetenv(name) }
    }

    private func assertSnapshotError(_ expected: WorkspaceSnapshotError, at url: URL) async {
        do { _ = try await GitWorkspaceSnapshotPreparer().prepare(from: url); XCTFail("expected \(expected)") }
        catch let error as WorkspaceSnapshotError { XCTAssertEqual(error, expected) }
        catch { XCTFail("unexpected error \(error)") }
    }

    private func assertSnapshotCase(at url: URL, matches: (WorkspaceSnapshotError) -> Bool) async {
        do { _ = try await GitWorkspaceSnapshotPreparer().prepare(from: url); XCTFail("expected rejection") }
        catch let error as WorkspaceSnapshotError { XCTAssertTrue(matches(error), "unexpected \(error)") }
        catch { XCTFail("unexpected error \(error)") }
    }

    func testPersistenceFailureCleanupStopsThenAbandonsWithoutHidingStopFailure() async throws {
        let client = CleanupClient()
        let ownerID = "workjet-worker-00000000-0000-0000-0000-000000000444"
        await LocalWorkjetService.cleanupRemoteWorkspaceAfterPersistenceFailure(client: client, runID: "run-known", ownerID: ownerID)
        let requests = await client.recorded()
        XCTAssertEqual(requests.map(\.operation), [.stop, .workspaceFinalize])
        XCTAssertEqual(requests.map(\.runID), ["run-known", "run-known"])
        XCTAssertNil(requests[0].workspaceDisposition)
        XCTAssertEqual(requests[1].ownerID, ownerID)
        XCTAssertEqual(requests[1].workspaceDisposition, .abandoned)
    }

    func testClientTransfersRawBundleOverStrictSSHAndRequiresGitCapability() async throws {
        let manifest = WorkspaceSnapshotManifest(repoID: String(repeating: "a", count: 64), snapshotCommitOID: String(repeating: "b", count: 40), bundleSHA256: String(repeating: "c", count: 64), byteSize: 12)
        let snapshot = WorkspaceSnapshot(manifest: manifest, bundle: Data("raw\0bundle\n!".utf8))
        let response = RemoteHostResponse(ok: true)
        var line = try JSONEncoder().encode(response); line.append(0x0a)
        let runner = CapturingRunner(response: CommandResult(exitCode: 0, standardOutput: line))
        let computer = Computer(name: "host", transport: .ssh, host: "host.tailnet", user: "workjet", deploymentStatus: .installed, installedSidecarVersion: PiSidecarRuntime.version, knownHostsPath: "/private/workjet-known-hosts")
        _ = try await RemoteHostClient(computer: computer, runner: runner).importWorkspace(snapshot, verifiedCapabilities: ["workspace-git-v1"])
        let recorded = await runner.recorded()
        let command = try XCTUnwrap(recorded.first)
        XCTAssertEqual(command.executable, "/usr/bin/ssh")
        XCTAssertTrue(command.arguments.contains("StrictHostKeyChecking=yes"))
        XCTAssertTrue(command.arguments.contains("UserKnownHostsFile=\"/private/workjet-known-hosts\""))
        XCTAssertEqual(Array(command.standardInput.suffix(snapshot.bundle.count)), Array(snapshot.bundle))
        XCTAssertFalse(String(decoding: command.standardInput, as: UTF8.self).contains(snapshot.bundle.base64EncodedString()))
        XCTAssertFalse(String(decoding: command.standardInput, as: UTF8.self).localizedCaseInsensitiveContains("origin"))

        let missing = CapturingRunner(response: CommandResult(exitCode: 0, standardOutput: line))
        do {
            _ = try await RemoteHostClient(computer: computer, runner: missing).importWorkspace(snapshot, verifiedCapabilities: [])
            XCTFail("expected missing capability")
        } catch let error as RemoteHostProtocolError {
            XCTAssertEqual(error, .missingCapability("workspace-git-v1"))
        }
        let missingCommands = await missing.recorded()
        XCTAssertTrue(missingCommands.isEmpty)
    }

    func testGeneratedHostImportsBundleCreatesDistinctHarnessWorktreesAndRejectsTampering() async throws {
        let fixture = try repository(); defer { try? FileManager.default.removeItem(at: fixture.root) }
        try Data("dirty expected\n".utf8).write(to: fixture.repository.appendingPathComponent("tracked.txt"))
        try Data("new expected\n".utf8).write(to: fixture.repository.appendingPathComponent("new.txt"))
        let snapshot = try await GitWorkspaceSnapshotPreparer().prepare(from: fixture.repository)

        let home = fixture.root.appendingPathComponent("host-home").creatingDirectory()
        let release = fixture.root.appendingPathComponent(String(repeating: "d", count: 64)).creatingDirectory()
        let host = release.appendingPathComponent("workjet-host.mjs")
        try Data(RemotePiBootstrap.hostRuntimeSource.utf8).write(to: host)
        // The generated host intentionally prefers its Workjet-managed harness
        // installation over globally installed binaries and legacy user paths.
        // Put the fixture executable at that authoritative location so a real
        // Homebrew/npm harness on the test machine cannot escape the fixture.
        let bin = home.appendingPathComponent(".local/lib/workjet/harnesses/npm/bin").creatingDirectory()
        for name in ["claude", "codex", "opencode"] {
            let script = bin.appendingPathComponent(name)
            let output = home.appendingPathComponent("observed-\(name).txt")
            let body = "#!/bin/sh\nprintf '%s\\n' \"$PWD\" > '\(output.path)'\ncat tracked.txt >> '\(output.path)'\ncat new.txt >> '\(output.path)'\n"
            try Data(body.utf8).write(to: script)
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: script.path)
            _ = try commandData("/usr/bin/xattr", ["-c", script.path])
        }

        let probe = try hostCall(host: host, home: home, bin: bin, request: RemoteHostRequest(operation: .probe))
        XCTAssertTrue(probe.capabilities.contains("workspace-git-v1"))
        let imported = try hostImport(host: host, home: home, bin: bin, snapshot: snapshot)
        XCTAssertTrue(imported.ok)

        let route = RemoteProviderExecution(displayName: "No credential", candidates: [
            RemoteProviderExecutionCandidate(kind: .directAccount, providerID: UUID(), modelProvider: .openAI, displayName: "No credential", endpoint: "https://example.invalid/v1", authentication: .none, secret: nil)
        ])
        var runIDs: [String] = []
        for (harness, model, executable) in [("claude-code", "test", "claude"), ("codex-cli", "test", "codex"), ("opencode", "openai/test", "opencode")] {
            let launch = RemoteHarnessLaunch(harnessID: harness, model: model, reasoning: nil, sandbox: false, input: Data("brief".utf8), allowedTools: harness == "claude-code" ? ["Read", "Write", "Edit", "Grep", "Glob", "Bash"] : nil, workspace: snapshot.manifest.descriptor)
            let started = try hostCall(host: host, home: home, bin: bin, request: RemoteHostRequest(operation: .start, launch: launch, providerExecution: route))
            let runID = try XCTUnwrap(started.runID, started.error ?? "start rejected")
            runIDs.append(runID)
            let observation = home.appendingPathComponent("observed-\(executable).txt")
            let deadline = Date().addingTimeInterval(60)
            while !FileManager.default.fileExists(atPath: observation.path), Date() < deadline { try await Task.sleep(for: .milliseconds(50)) }
            XCTAssertTrue(FileManager.default.fileExists(atPath: observation.path), "\(harness) did not observe its cwd")
            let current = try hostCall(host: host, home: home, bin: bin, request: RemoteHostRequest(operation: .events, runID: runID, afterSequence: 0))
            if !current.state.isTerminal { _ = try hostCall(host: host, home: home, bin: bin, request: RemoteHostRequest(operation: .stop, runID: runID)) }
        }
        XCTAssertEqual(Set(runIDs).count, 3)
        for name in ["claude", "codex", "opencode"] {
            let observed = try String(contentsOf: home.appendingPathComponent("observed-\(name).txt"), encoding: .utf8)
            XCTAssertTrue(observed.contains("/.local/state/workjet/host/worktrees/"))
            XCTAssertTrue(observed.contains("dirty expected\nnew expected\n"))
        }
        for runID in runIDs {
            XCTAssertTrue(FileManager.default.fileExists(atPath: home.appendingPathComponent(".local/state/workjet/host/worktrees/\(runID)/tracked.txt").path), "terminal worktrees must be retained")
        }

        var badHash = snapshot
        badHash.manifest.bundleSHA256 = String(repeating: "0", count: 64)
        XCTAssertEqual(try hostImport(host: host, home: home, bin: bin, snapshot: badHash).error, "workspace_hash_mismatch")
        var badSize = snapshot
        badSize.manifest.byteSize -= 1
        XCTAssertEqual(try hostImport(host: host, home: home, bin: bin, snapshot: badSize).error, "workspace_size_mismatch")
        let malformedManifest: [String: Any] = [
            "schemaVersion": 1,
            "repoID": "../escape",
            "snapshotCommitOID": snapshot.manifest.snapshotCommitOID,
            "bundleSHA256": snapshot.manifest.bundleSHA256,
            "byteSize": snapshot.bundle.count
        ]
        var malformedInput = try JSONSerialization.data(withJSONObject: malformedManifest)
        malformedInput.append(0x0a); malformedInput.append(snapshot.bundle)
        XCTAssertEqual(try hostProcess(host: host, home: home, bin: bin, arguments: ["--workspace-import"], input: malformedInput).error, "workspace_manifest_invalid")

        let unsafeRepoID = String(repeating: "f", count: 64)
        let repos = home.appendingPathComponent(".local/state/workjet/host/repos")
        try FileManager.default.createSymbolicLink(at: repos.appendingPathComponent("\(unsafeRepoID).git"), withDestinationURL: repos.appendingPathComponent("\(snapshot.manifest.repoID).git"))
        let unsafeWorkspace = RemoteWorkspaceDescriptor(repoID: unsafeRepoID, snapshotCommitOID: snapshot.manifest.snapshotCommitOID)
        let unsafeLaunch = RemoteHarnessLaunch(harnessID: "claude-code", model: "test", reasoning: nil, sandbox: false, input: Data("brief".utf8), allowedTools: ["Read", "Write", "Edit", "Grep", "Glob", "Bash"], workspace: unsafeWorkspace)
        let unsafeStart = try hostCall(host: host, home: home, bin: bin, request: RemoteHostRequest(operation: .start, launch: unsafeLaunch, providerExecution: route))
        XCTAssertEqual(unsafeStart.error, "workspace_cache_missing")

        let marker = home.appendingPathComponent("release-fallback-marker")
        let noWorkspace = RemoteHarnessLaunch(harnessID: "claude-code", model: "test", reasoning: nil, sandbox: false, input: Data("brief".utf8), allowedTools: ["Read", "Write", "Edit", "Grep", "Glob", "Bash"])
        let rejected = try hostCall(host: host, home: home, bin: bin, request: RemoteHostRequest(operation: .start, launch: noWorkspace, providerExecution: route))
        XCTAssertEqual(rejected.error, "workspace_required")
        XCTAssertFalse(FileManager.default.fileExists(atPath: marker.path))

        let source = RemotePiBootstrap.hostRuntimeSource
        XCTAssertFalse(source.contains("git clone"))
        XCTAssertFalse(source.contains("git pull"))
        XCTAssertFalse(source.contains("remote fetch"))
        XCTAssertTrue(source.contains("GIT_TERMINAL_PROMPT: \"0\""))
    }

    func testHostCachesUnsafeSnapshotButRejectsItBeforeCreatingWorktree() throws {
        let fixture = try repository(); defer { try? FileManager.default.removeItem(at: fixture.root) }
        let escape = fixture.repository.appendingPathComponent("escape")
        try FileManager.default.createSymbolicLink(atPath: escape.path, withDestinationPath: "/etc/passwd")
        _ = try git(["add", "escape"], cwd: fixture.repository)
        _ = try git(["commit", "-m", "unsafe symlink tree"], cwd: fixture.repository)
        let commit = try git(["rev-parse", "HEAD"], cwd: fixture.repository)
        let branch = try git(["symbolic-ref", "--short", "HEAD"], cwd: fixture.repository)
        let bundleURL = fixture.root.appendingPathComponent("unsafe.bundle")
        _ = try git(["bundle", "create", bundleURL.path, branch], cwd: fixture.repository)
        let bundle = try Data(contentsOf: bundleURL)
        let repoID = SHA256.hash(data: Data(("unsafe-snapshot-" + commit).utf8)).map { String(format: "%02x", $0) }.joined()
        let snapshot = WorkspaceSnapshot(
            manifest: WorkspaceSnapshotManifest(
                repoID: repoID,
                snapshotCommitOID: commit,
                bundleSHA256: SHA256.hash(data: bundle).map { String(format: "%02x", $0) }.joined(),
                byteSize: bundle.count
            ),
            bundle: bundle
        )

        let home = fixture.root.appendingPathComponent("host-home").creatingDirectory()
        let release = fixture.root.appendingPathComponent(String(repeating: "7", count: 64)).creatingDirectory()
        let host = release.appendingPathComponent("workjet-host.mjs")
        try Data(RemotePiBootstrap.hostRuntimeSource.utf8).write(to: host)
        let bin = home.appendingPathComponent(".local/lib/workjet/harnesses/npm/bin").creatingDirectory()
        let claude = bin.appendingPathComponent("claude")
        try Data("#!/bin/sh\nexit 0\n".utf8).write(to: claude)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: claude.path)
        _ = try commandData("/usr/bin/xattr", ["-c", claude.path])

        XCTAssertTrue(try hostImport(host: host, home: home, bin: bin, snapshot: snapshot).ok)
        let cache = home.appendingPathComponent(".local/state/workjet/host/repos/\(repoID).git")
        XCTAssertTrue(FileManager.default.fileExists(atPath: cache.path), "validated bundle may be cached before start-time tree validation")
        let route = RemoteProviderExecution(displayName: "Offline", candidates: [
            RemoteProviderExecutionCandidate(kind: .directAccount, providerID: UUID(), modelProvider: .anthropic, displayName: "Offline", endpoint: "https://example.invalid/", authentication: .none, secret: nil)
        ])
        let launch = RemoteHarnessLaunch(harnessID: "claude-code", model: "test", reasoning: nil, sandbox: false, input: Data("brief".utf8), allowedTools: ["Read", "Write", "Edit", "Grep", "Glob", "Bash"], workspace: snapshot.manifest.descriptor)
        let rejected = try hostCall(host: host, home: home, bin: bin, request: RemoteHostRequest(operation: .start, launch: launch, providerExecution: route))
        XCTAssertEqual(rejected.error, "workspace_snapshot_tree_unsafe")
        let worktrees = home.appendingPathComponent(".local/state/workjet/host/worktrees")
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: worktrees.path), [], "unsafe tree must be rejected before git worktree add")
    }

    private func hostImport(host: URL, home: URL, bin: URL, snapshot: WorkspaceSnapshot) throws -> RemoteHostResponse {
        var input = try JSONEncoder().encode(snapshot.manifest); input.append(0x0a); input.append(snapshot.bundle)
        return try hostProcess(host: host, home: home, bin: bin, arguments: ["--workspace-import"], input: input)
    }

    private func hostCall(host: URL, home: URL, bin: URL, request: RemoteHostRequest) throws -> RemoteHostResponse {
        var input = try JSONEncoder().encode(request); input.append(0x0a)
        return try hostProcess(host: host, home: home, bin: bin, arguments: [], input: input)
    }

    private func hostProcess(host: URL, home: URL, bin: URL, arguments: [String], input: Data) throws -> RemoteHostResponse {
        let process = Process(); process.executableURL = URL(fileURLWithPath: "/usr/bin/env"); process.arguments = ["node", host.path] + arguments
        var environment = ProcessInfo.processInfo.environment; environment["HOME"] = home.path; environment["PATH"] = bin.path + ":" + (environment["PATH"] ?? "/usr/bin:/bin"); process.environment = environment
        let stdin = Pipe(), stdout = Pipe(), stderr = Pipe(); process.standardInput = stdin; process.standardOutput = stdout; process.standardError = stderr
        try process.run(); stdin.fileHandleForWriting.write(input); try stdin.fileHandleForWriting.close(); process.waitUntilExit()
        let data = stdout.fileHandleForReading.readDataToEndOfFile(); let diagnostic = stderr.fileHandleForReading.readDataToEndOfFile()
        XCTAssertEqual(process.terminationStatus, 0, String(decoding: diagnostic, as: UTF8.self))
        return try JSONDecoder().decode(RemoteHostResponse.self, from: data)
    }

    private func waitForTerminal(host: URL, home: URL, bin: URL, runID: String) throws -> RemoteHostResponse {
        let deadline = Date().addingTimeInterval(10)
        var response = RemoteHostResponse(ok: false)
        repeat {
            response = try hostCall(host: host, home: home, bin: bin, request: RemoteHostRequest(operation: .events, runID: runID, afterSequence: 0))
            if response.state.isTerminal { return response }
            Thread.sleep(forTimeInterval: 0.05)
        } while Date() < deadline
        return response
    }

    private func hostResult(host: URL, home: URL, bin: URL, request: RemoteWorkspaceResultRequest) throws -> WorkspaceResult {
        var input = try JSONEncoder().encode(request); input.append(0x0a)
        let process = Process(); process.executableURL = URL(fileURLWithPath: "/usr/bin/env"); process.arguments = ["node", host.path, "--workspace-result"]
        var environment = ProcessInfo.processInfo.environment; environment["HOME"] = home.path; environment["PATH"] = bin.path + ":" + (environment["PATH"] ?? "/usr/bin:/bin"); process.environment = environment
        let stdin = Pipe(), stdout = Pipe(), stderr = Pipe(); process.standardInput = stdin; process.standardOutput = stdout; process.standardError = stderr
        try process.run(); stdin.fileHandleForWriting.write(input); try stdin.fileHandleForWriting.close(); process.waitUntilExit()
        let output = stdout.fileHandleForReading.readDataToEndOfFile(); let diagnostic = stderr.fileHandleForReading.readDataToEndOfFile()
        XCTAssertEqual(process.terminationStatus, 0, String(decoding: diagnostic, as: UTF8.self))
        guard let newline = output.firstIndex(of: 0x0a) else { throw WorkspaceResultError.resultMalformed }
        let manifest = try JSONDecoder().decode(WorkspaceResultManifest.self, from: output.prefix(upTo: newline))
        return WorkspaceResult(manifest: manifest, bundle: Data(output.suffix(from: output.index(after: newline))))
    }

    private func hostResultFailure(host: URL, home: URL, bin: URL, request: RemoteWorkspaceResultRequest) throws -> String {
        var input = try JSONEncoder().encode(request); input.append(0x0a)
        let process = Process(); process.executableURL = URL(fileURLWithPath: "/usr/bin/env"); process.arguments = ["node", host.path, "--workspace-result"]
        var environment = ProcessInfo.processInfo.environment; environment["HOME"] = home.path; environment["PATH"] = bin.path + ":" + (environment["PATH"] ?? "/usr/bin:/bin"); process.environment = environment
        let stdin = Pipe(), stdout = Pipe(), stderr = Pipe(); process.standardInput = stdin; process.standardOutput = stdout; process.standardError = stderr
        try process.run(); stdin.fileHandleForWriting.write(input); try stdin.fileHandleForWriting.close(); process.waitUntilExit()
        XCTAssertNotEqual(process.terminationStatus, 0)
        XCTAssertTrue(stdout.fileHandleForReading.readDataToEndOfFile().isEmpty)
        return String(decoding: stderr.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func testTerminalRemoteResultRoundTripIsBinaryExactImmutableAndDoesNotTouchDirtyLocalCheckout() async throws {
        let fixture = try repository(); defer { try? FileManager.default.removeItem(at: fixture.root) }
        try Data("local dirty before snapshot\n".utf8).write(to: fixture.repository.appendingPathComponent("tracked.txt"))
        try Data("local untracked\n".utf8).write(to: fixture.repository.appendingPathComponent("local-only.txt"))
        _ = try git(["remote", "add", "origin", "ssh://credential-required@127.0.0.1:1/unreachable.git"], cwd: fixture.repository)
        let networkMarker = fixture.root.appendingPathComponent("network-invoked")
        _ = try git(["config", "core.sshCommand", "/bin/sh -c 'touch \(networkMarker.path); exit 99'"], cwd: fixture.repository)
        let snapshot = try await GitWorkspaceSnapshotPreparer().prepare(from: fixture.repository)

        let home = fixture.root.appendingPathComponent("host-home").creatingDirectory()
        let release = fixture.root.appendingPathComponent(String(repeating: "e", count: 64)).creatingDirectory()
        let host = release.appendingPathComponent("workjet-host.mjs")
        try Data(RemotePiBootstrap.hostRuntimeSource.utf8).write(to: host)
        let bin = home.appendingPathComponent(".local/lib/workjet/harnesses/npm/bin").creatingDirectory()
        let claude = bin.appendingPathComponent("claude")
        let script = "#!/bin/sh\nprintf 'remote tracked\\n' > tracked.txt\nrm -f deleted.txt\nprintf 'binary\\0line\\nend' > result.bin\nprintf 'remote created\\n' > created.txt\nprintf 'ignored remote\\n' > ignored.txt\nexec /usr/bin/true\n"
        try Data(script.utf8).write(to: claude); try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: claude.path)
        _ = try commandData("/usr/bin/xattr", ["-c", claude.path])
        _ = try hostImport(host: host, home: home, bin: bin, snapshot: snapshot)
        let ownerID = "workjet-worker-00000000-0000-0000-0000-000000000111"
        let route = RemoteProviderExecution(displayName: "Offline", candidates: [
            RemoteProviderExecutionCandidate(kind: .directAccount, providerID: UUID(), modelProvider: .anthropic, displayName: "Offline", endpoint: "https://example.invalid/", authentication: .none, secret: nil)
        ])
        let launch = RemoteHarnessLaunch(harnessID: "claude-code", model: "test", reasoning: nil, sandbox: false, input: Data("edit".utf8), allowedTools: ["Read", "Write", "Edit", "Grep", "Glob", "Bash"], workspace: snapshot.manifest.descriptor)
        let started = try hostCall(host: host, home: home, bin: bin, request: RemoteHostRequest(operation: .start, launch: launch, ownerID: ownerID, providerExecution: route))
        let runID = try XCTUnwrap(started.runID)
        let remoteWorktree = home.appendingPathComponent(".local/state/workjet/host/worktrees/\(runID)")
        let editDeadline = Date().addingTimeInterval(60)
        while !FileManager.default.fileExists(atPath: remoteWorktree.appendingPathComponent("result.bin").path), Date() < editDeadline { try await Task.sleep(for: .milliseconds(50)) }
        XCTAssertTrue(FileManager.default.fileExists(atPath: remoteWorktree.appendingPathComponent("result.bin").path))
        let terminalState = try hostCall(host: host, home: home, bin: bin, request: RemoteHostRequest(operation: .stop, runID: runID)).state
        XCTAssertTrue(terminalState.isTerminal)

        let hostStateFile = home.appendingPathComponent(".local/state/workjet/host/runs/\(runID)/state.json")
        var oldState = try JSONSerialization.jsonObject(with: Data(contentsOf: hostStateFile)) as! [String: Any]
        oldState["updatedAt"] = ISO8601DateFormatter().string(from: Date(timeIntervalSinceNow: -45 * 86_400))
        oldState["completedAt"] = oldState["updatedAt"]
        try JSONSerialization.data(withJSONObject: oldState).write(to: hostStateFile, options: .atomic)
        _ = try hostCall(host: host, home: home, bin: bin, request: RemoteHostRequest(operation: .probe))
        XCTAssertTrue(FileManager.default.fileExists(atPath: remoteWorktree.path), "unmarked terminal workspace must survive journal retention")

        let before = try state(fixture.repository)
        let request = RemoteWorkspaceResultRequest(runID: runID, ownerID: ownerID, repoID: snapshot.manifest.repoID, snapshotCommitOID: snapshot.manifest.snapshotCommitOID)
        let first = try hostResult(host: host, home: home, bin: bin, request: request)
        XCTAssertEqual(first.manifest.terminalState, terminalState)
        XCTAssertEqual(first.bundle.count, first.manifest.byteSize)
        try Data("mutation after capture\n".utf8).write(to: remoteWorktree.appendingPathComponent("created.txt"))
        let repeated = try hostResult(host: host, home: home, bin: bin, request: request)
        XCTAssertEqual(repeated, first, "captured result must remain immutable after later worktree mutation")

        let paths = WorkjetPaths(homeDirectory: fixture.root, stateDirectory: fixture.root.appendingPathComponent("local-state"))
        let store = RemoteWorkspaceRunStore(paths: paths)
        let record = try await store.create(runID: runID, sourceRepositoryRoot: fixture.repository, computerID: UUID(), ownerID: ownerID, manifest: snapshot.manifest)
        XCTAssertEqual(try RemoteWorkspaceRunStore(paths: paths).load(runID: runID), record, "mapping must survive a CLI/app restart")
        let recordFile = paths.remoteWorkspaceRunsDirectory.appendingPathComponent("\(runID).json")
        let permissions = (try FileManager.default.attributesOfItem(atPath: recordFile.path)[.posixPermissions] as? NSNumber)?.intValue
        XCTAssertEqual(permissions.map { $0 & 0o077 }, 0)
        XCTAssertFalse(String(decoding: try JSONEncoder().encode(first.manifest), as: UTF8.self).contains(record.sourceRepositoryRoot))
        var badHash = first; badHash.manifest.bundleSHA256 = String(repeating: "0", count: 64)
        do { _ = try await LocalWorkspaceResultImporter().importResult(badHash, for: record, temporaryRoot: paths.remoteWorkspaceImportsDirectory); XCTFail("expected hash rejection") }
        catch { XCTAssertEqual(error as? WorkspaceResultError, .resultMismatch) }
        var wrongIdentity = first; wrongIdentity.manifest.repoID = String(repeating: "9", count: 64)
        do { _ = try await LocalWorkspaceResultImporter().importResult(wrongIdentity, for: record, temporaryRoot: paths.remoteWorkspaceImportsDirectory); XCTFail("expected identity rejection") }
        catch { XCTAssertEqual(error as? WorkspaceResultError, .identityMismatch) }
        let targetRef = "refs/workjet/\(runID)"
        _ = try git(["update-ref", targetRef, "HEAD"], cwd: fixture.repository)
        do { _ = try await LocalWorkspaceResultImporter().importResult(first, for: record, temporaryRoot: paths.remoteWorkspaceImportsDirectory); XCTFail("expected conflicting ref rejection") }
        catch { XCTAssertEqual(error as? WorkspaceResultError, .conflictingRef) }
        _ = try git(["update-ref", "-d", targetRef], cwd: fixture.repository)
        let imported = try await LocalWorkspaceResultImporter().importResult(first, for: record, temporaryRoot: paths.remoteWorkspaceImportsDirectory)
        XCTAssertEqual(imported.resultRef, "refs/workjet/\(runID)")
        XCTAssertEqual(try git(["rev-parse", imported.resultRef], cwd: fixture.repository), first.manifest.resultCommitOID)
        XCTAssertEqual(try commandData("/usr/bin/git", ["show", "\(imported.resultRef):result.bin"], cwd: fixture.repository), Data([98,105,110,97,114,121,0,108,105,110,101,10,101,110,100]))
        XCTAssertEqual(try git(["show", "\(imported.resultRef):tracked.txt"], cwd: fixture.repository), "remote tracked")
        XCTAssertThrowsError(try git(["show", "\(imported.resultRef):deleted.txt"], cwd: fixture.repository))
        XCTAssertThrowsError(try git(["show", "\(imported.resultRef):ignored.txt"], cwd: fixture.repository))
        let after = try state(fixture.repository)
        XCTAssertEqual(after.branch, before.branch); XCTAssertEqual(after.head, before.head); XCTAssertEqual(after.index, before.index)
        XCTAssertEqual(after.status, before.status); XCTAssertEqual(after.tracked, before.tracked); XCTAssertEqual(after.stash, before.stash)
        XCTAssertFalse(FileManager.default.fileExists(atPath: networkMarker.path), "local import must not invoke origin or SSH credentials")
        _ = try await LocalWorkspaceResultImporter().importResult(first, for: record, temporaryRoot: paths.remoteWorkspaceImportsDirectory)

        let finalized = try hostCall(host: host, home: home, bin: bin, request: RemoteHostRequest(operation: .workspaceFinalize, runID: runID, ownerID: ownerID, workspaceDisposition: .integrated))
        XCTAssertEqual(finalized.workspaceDisposition, .integrated)
        XCTAssertFalse(FileManager.default.fileExists(atPath: remoteWorktree.path))
        let finalizedAgain = try hostCall(host: host, home: home, bin: bin, request: RemoteHostRequest(operation: .workspaceFinalize, runID: runID, ownerID: ownerID, workspaceDisposition: .integrated))
        XCTAssertEqual(finalizedAgain.workspaceDisposition, .integrated)
    }

    func testResultExportFailsClosedForRunningForeignAndSymlinkedWorkspaces() async throws {
        let fixture = try repository(); defer { try? FileManager.default.removeItem(at: fixture.root) }
        let snapshot = try await GitWorkspaceSnapshotPreparer().prepare(from: fixture.repository)
        let home = fixture.root.appendingPathComponent("host-home").creatingDirectory()
        let release = fixture.root.appendingPathComponent(String(repeating: "f", count: 64)).creatingDirectory()
        let host = release.appendingPathComponent("workjet-host.mjs"); try Data(RemotePiBootstrap.hostRuntimeSource.utf8).write(to: host)
        let bin = home.appendingPathComponent(".local/lib/workjet/harnesses/npm/bin").creatingDirectory(); let claude = bin.appendingPathComponent("claude")
        try Data("#!/bin/sh\nsleep 30\n".utf8).write(to: claude); try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: claude.path)
        _ = try commandData("/usr/bin/xattr", ["-c", claude.path])
        _ = try hostImport(host: host, home: home, bin: bin, snapshot: snapshot)
        let ownerID = "workjet-worker-00000000-0000-0000-0000-000000000222"
        let route = RemoteProviderExecution(displayName: "Offline", candidates: [RemoteProviderExecutionCandidate(kind: .directAccount, providerID: UUID(), modelProvider: .anthropic, displayName: "Offline", endpoint: "https://example.invalid/", authentication: .none, secret: nil)])
        let launch = RemoteHarnessLaunch(harnessID: "claude-code", model: "test", reasoning: nil, sandbox: false, input: Data("wait".utf8), allowedTools: ["Read", "Write", "Edit", "Grep", "Glob", "Bash"], workspace: snapshot.manifest.descriptor)
        let runID = try XCTUnwrap(hostCall(host: host, home: home, bin: bin, request: RemoteHostRequest(operation: .start, launch: launch, ownerID: ownerID, providerExecution: route)).runID)
        let request = RemoteWorkspaceResultRequest(runID: runID, ownerID: ownerID, repoID: snapshot.manifest.repoID, snapshotCommitOID: snapshot.manifest.snapshotCommitOID)
        XCTAssertEqual(try hostResultFailure(host: host, home: home, bin: bin, request: request), "workspace_run_not_terminal")
        var foreign = request; foreign.ownerID = "workjet-worker-00000000-0000-0000-0000-000000000333"
        _ = try hostCall(host: host, home: home, bin: bin, request: RemoteHostRequest(operation: .stop, runID: runID))
        XCTAssertEqual(try hostResultFailure(host: host, home: home, bin: bin, request: foreign), "workspace_run_not_owned")
        let worktree = home.appendingPathComponent(".local/state/workjet/host/worktrees/\(runID)")
        let oversized = worktree.appendingPathComponent("oversized.bin")
        try Data(repeating: 0x5a, count: LocalWorkspaceResultImporter.maximumBundleBytes + 1).write(to: oversized)
        XCTAssertTrue(try hostResultFailure(host: host, home: home, bin: bin, request: request).hasSuffix("workspace_result_objects_too_large"))
        try FileManager.default.removeItem(at: oversized)
        let unsafe = worktree.appendingPathComponent("unsafe")
        try FileManager.default.createSymbolicLink(atPath: unsafe.path, withDestinationPath: "/etc/passwd")
        XCTAssertEqual(try hostResultFailure(host: host, home: home, bin: bin, request: request), "workspace_symlink_rejected")
        try FileManager.default.removeItem(at: unsafe)
        let abandoned = try hostCall(host: host, home: home, bin: bin, request: RemoteHostRequest(operation: .workspaceFinalize, runID: runID, ownerID: ownerID, workspaceDisposition: .abandoned))
        XCTAssertEqual(abandoned.workspaceDisposition, .abandoned)
        XCTAssertFalse(FileManager.default.fileExists(atPath: worktree.path))
    }
}

private extension URL {
    @discardableResult
    func creatingDirectory() -> URL {
        try! FileManager.default.createDirectory(at: self, withIntermediateDirectories: true)
        return self
    }
}
