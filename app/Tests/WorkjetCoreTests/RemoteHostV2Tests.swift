import Darwin
import Foundation
import XCTest
@testable import WorkjetCore

final class RemoteHostV2Tests: XCTestCase {
    private struct Fixture {
        let root: URL
        let home: URL
        let host: URL
        let fakeClaude: URL
        let workspace: RemoteWorkspaceDescriptor
    }
    private var activeFixtures: [Fixture] = []

    override func tearDown() {
        activeFixtures.forEach(cleanup)
        activeFixtures.removeAll()
        super.tearDown()
    }

    private func fixtureProcessIDs(_ fixture: Fixture) -> [Int32] {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/ps")
        process.arguments = ["-axo", "pid=,command="]
        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return [] }
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        let listing = String(decoding: data, as: UTF8.self)
        return listing.split(separator: "\n").compactMap { line in
            let fields = line.split(maxSplits: 1, whereSeparator: \Character.isWhitespace)
            guard fields.count == 2,
                  fields[1].contains(fixture.root.path),
                  let pid = Int32(fields[0]),
                  pid != ProcessInfo.processInfo.processIdentifier else { return nil }
            return pid
        }
    }

    private func cleanup(_ fixture: Fixture) {
        let currentGroup = getpgrp()
        func signal(_ value: Int32) {
            let group = getpgid(value)
            if group == value, group != currentGroup {
                _ = Darwin.kill(-value, SIGTERM)
            } else {
                _ = Darwin.kill(value, SIGTERM)
            }
        }
        fixtureProcessIDs(fixture).forEach(signal)
        Thread.sleep(forTimeInterval: 0.1)
        for pid in fixtureProcessIDs(fixture) {
            let group = getpgid(pid)
            if group == pid, group != currentGroup {
                _ = Darwin.kill(-pid, SIGKILL)
            } else {
                _ = Darwin.kill(pid, SIGKILL)
            }
        }
        try? FileManager.default.removeItem(at: fixture.root)
    }

    private func compileExecutable(script: String, at url: URL) throws {
        let node = (ProcessInfo.processInfo.environment["PATH"] ?? "")
            .split(separator: ":")
            .map { URL(fileURLWithPath: String($0)).appendingPathComponent("node").path }
            .first(where: FileManager.default.isExecutableFile(atPath:))
        let executable = try XCTUnwrap(node, "Node is required for the remote-host fixture")
        let behavior = String(decoding: try JSONEncoder().encode(script), as: UTF8.self)
        let source = #"""
#!__NODE__
const behavior = __BEHAVIOR__;
const token = process.env.ANTHROPIC_AUTH_TOKEN ?? "";
const args = process.argv.slice(2);
const line = value => process.stdout.write(value + "\n");
const errorLine = value => process.stderr.write(value + "\n");
if (behavior === "sleep 30") setTimeout(() => process.exit(0), 30000);
else if (behavior === "echo unused") line("unused");
else if (behavior === "echo must-not-run") line("must-not-run");
else if (behavior.includes("ctx:%s:%s:%s:%s")) {
  line(`ctx:${process.env.WORKJET_MODEL}:${process.env.WORKJET_REASONING}:${process.env.WORKJET_SPEED}:${process.env.WORKJET_PROVIDER_ROUTE}`);
  line(token); errorLine(token);
} else if (behavior.includes("split-secret-")) {
  process.stdout.write("split-secret-");
  setTimeout(() => line("sentinel"), 1000);
} else if (behavior === "web-research-environment") {
  line(`web:${process.env.WORKJET_WEB_RESEARCH_BACKEND}:${process.env.WORKJET_WEB_RESEARCH_BASE_URL}:${process.env.WORKJET_WEB_RESEARCH_API_KEY}:${process.env.GREPPY_STORE_DIR}:${process.execPath}`);
} else if (behavior.includes("HTTP 429 rate limit")) {
  if (token === "first-secret") { errorLine("HTTP 429 rate limit"); process.exitCode = 1; } else line("used-second");
} else if (behavior.includes("tests failed")) {
  if (token === "first-secret") { errorLine("tests failed"); process.exitCode = 2; } else line("used-second");
} else if (behavior.includes("HTTP 503 upstream timeout")) {
  if (token === "first-secret") { errorLine("HTTP 503 upstream timeout"); process.exitCode = 1; } else line("used-second");
} else if (behavior.includes("while [ $i -lt 3000 ]")) {
  setTimeout(() => process.stdout.write("0123456789abcdef".repeat(12000)), 1000);
} else if (behavior.includes("term-trap-ready")) {
  process.on("SIGTERM", () => {}); line("term-trap-ready"); setInterval(() => {}, 1000);
} else if (behavior === "echo 'claude 1.2.3'") line("claude 1.2.3");
else if (behavior === "echo WORKJET_HEALTH_OK") line("WORKJET_HEALTH_OK");
else if (behavior.includes("OpenCode 1.2.3")) { if (args[0] !== "upgrade") line("OpenCode 1.2.3"); }
else if (behavior.includes("while [ $i -lt 10000 ]")) { process.stderr.write("x".repeat(10000)); process.exitCode = 7; }
else if (behavior.includes("managed target missing")) { errorLine("managed target missing"); process.exitCode = 78; }
else if (behavior.includes("greppy 0.3.1")) {
  if (args.length === 1 && args[0] === "--version") line("greppy 0.3.1");
  else if (args.length === 1 && args[0] === "--help") line("who-calls search-symbol bash-smart");
  else process.exitCode = 64;
} else { errorLine("unknown fixture behavior"); process.exitCode = 64; }
"""#
            .replacingOccurrences(of: "__NODE__", with: executable)
            .replacingOccurrences(of: "__BEHAVIOR__", with: behavior)
        try Data(source.utf8).write(to: url)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
    }

    private func compileShellExecutable(script: String, at url: URL) throws {
        try Data("#!/bin/sh\n\(script)\n".utf8).write(to: url)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
    }

    private func fixture(script: String, greppyScript: String? = nil, codexAvailable: Bool = false, allowManagedSkillsOnFixturePlatform: Bool = false, forceUnsupportedManagedSkillTarget: Bool = false) throws -> Fixture {
        let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
            .appendingPathComponent(".build/workjet-host-v2-fixtures/\(UUID().uuidString)", isDirectory: true)
        let home = root.appendingPathComponent("home")
        let release = root.appendingPathComponent(String(repeating: "a", count: 64))
        let bin = home.appendingPathComponent(".local/bin")
        let managedBin = home.appendingPathComponent(".local/lib/workjet/harnesses/npm/bin")
        let managedSkillsBin = home.appendingPathComponent(".local/lib/workjet/skills/bin")
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: release, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: managedBin, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: managedSkillsBin, withIntermediateDirectories: true)
        let host = release.appendingPathComponent("workjet-host.mjs")
        var hostSource = RemotePiBootstrap.hostRuntimeSource
        if allowManagedSkillsOnFixturePlatform {
            hostSource = hostSource.replacingOccurrences(of: #"process.platform !== "linux" || process.arch !== "x64""#, with: "false")
        } else if forceUnsupportedManagedSkillTarget {
            hostSource = hostSource.replacingOccurrences(of: #"process.platform !== "linux" || process.arch !== "x64""#, with: "true")
        }
        try Data(hostSource.utf8).write(to: host)
        try Data("export default {};\n".utf8).write(to: release.appendingPathComponent("ctox-pi-sidecar.mjs"))
        try Data("export default {};\n".utf8).write(to: release.appendingPathComponent("workjet-pi-turn.mjs"))
        let nodeLauncher = release.appendingPathComponent("workjet-node")
        try Data("#!/bin/sh\nexec node \"$@\"\n".utf8).write(to: nodeLauncher)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: nodeLauncher.path)
        let manifest: [String: Any] = ["schema": 1, "version": PiSidecarRuntime.version, "contentHash": String(repeating: "a", count: 64)]
        try JSONSerialization.data(withJSONObject: manifest).write(to: release.appendingPathComponent("manifest.json"))
        let fakeClaude = bin.appendingPathComponent("claude")
        try compileExecutable(script: script, at: fakeClaude)
        try FileManager.default.copyItem(at: fakeClaude, to: managedBin.appendingPathComponent("claude"))
        if codexAvailable {
            try FileManager.default.copyItem(at: fakeClaude, to: managedBin.appendingPathComponent("codex"))
        }
        let fakeOpenCode = bin.appendingPathComponent("opencode")
        try FileManager.default.copyItem(at: fakeClaude, to: fakeOpenCode)
        if let greppyScript {
            let fakeGreppy = managedSkillsBin.appendingPathComponent("greppy")
            try compileShellExecutable(script: greppyScript, at: fakeGreppy)
        }
        let nativeOpenCode = home.appendingPathComponent(".opencode/bin/opencode")
        try FileManager.default.createDirectory(at: nativeOpenCode.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: fakeClaude, to: nativeOpenCode)

        func git(_ arguments: [String], cwd: URL? = nil) throws -> String {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
            process.arguments = arguments
            process.currentDirectoryURL = cwd
            var environment = ProcessInfo.processInfo.environment
            environment["GIT_AUTHOR_NAME"] = "Fixture"
            environment["GIT_AUTHOR_EMAIL"] = "fixture@example.invalid"
            environment["GIT_COMMITTER_NAME"] = "Fixture"
            environment["GIT_COMMITTER_EMAIL"] = "fixture@example.invalid"
            process.environment = environment
            let output = Pipe(), error = Pipe()
            process.standardOutput = output
            process.standardError = error
            try process.run(); process.waitUntilExit()
            let diagnostic = String(decoding: error.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            guard process.terminationStatus == 0 else { throw NSError(domain: "fixture-git", code: Int(process.terminationStatus), userInfo: [NSLocalizedDescriptionKey: diagnostic]) }
            return String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        let repository = root.appendingPathComponent("repository")
        try FileManager.default.createDirectory(at: repository, withIntermediateDirectories: true)
        _ = try git(["init"], cwd: repository)
        try Data("fixture workspace\n".utf8).write(to: repository.appendingPathComponent("workspace.txt"))
        _ = try git(["add", "workspace.txt"], cwd: repository)
        _ = try git(["commit", "-m", "fixture"], cwd: repository)
        let commit = try git(["rev-parse", "HEAD"], cwd: repository)
        let repoID = String(repeating: "b", count: 64)
        let repos = home.appendingPathComponent(".local/state/workjet/host/repos")
        try FileManager.default.createDirectory(at: repos, withIntermediateDirectories: true)
        _ = try git(["clone", "--bare", repository.path, repos.appendingPathComponent("\(repoID).git").path])
        let workspace = RemoteWorkspaceDescriptor(repoID: repoID, snapshotCommitOID: commit)
        let fixture = Fixture(root: root, home: home, host: host, fakeClaude: fakeClaude, workspace: workspace)
        activeFixtures.append(fixture)
        return fixture
    }

    private func call(_ fixture: Fixture, _ request: RemoteHostRequest, timeout: TimeInterval = 90) throws -> RemoteHostResponse {
        var request = request
        if request.operation == .start, request.launch?.harnessID != "pi-code", request.launch?.healthProbe != true, request.launch?.workspace == nil {
            request.launch?.workspace = fixture.workspace
        }
        var payload = try JSONEncoder().encode(request)
        payload.append(0x0a)
        return try call(fixture, payload: payload, timeout: timeout)
    }

    private func call(_ fixture: Fixture, payload: Data, timeout: TimeInterval = 30) throws -> RemoteHostResponse {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["node", fixture.host.path]
        var environment = ProcessInfo.processInfo.environment
        environment["HOME"] = fixture.home.path
        environment["PATH"] = fixture.fakeClaude.deletingLastPathComponent().path + ":" + (environment["PATH"] ?? "/usr/bin:/bin")
        process.environment = environment
        let input = Pipe(), output = Pipe(), error = Pipe()
        process.standardInput = input
        process.standardOutput = output
        process.standardError = error
        try process.run()
        input.fileHandleForWriting.write(payload)
        try input.fileHandleForWriting.close()
        let deadline = Date().addingTimeInterval(timeout)
        while process.isRunning, Date() < deadline { Thread.sleep(forTimeInterval: 0.02) }
        if process.isRunning { process.terminate(); XCTFail("host call timed out") }
        process.waitUntilExit()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        let stderr = String(decoding: error.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        XCTAssertEqual(process.terminationStatus, 0, stderr)
        return try JSONDecoder().decode(RemoteHostResponse.self, from: data)
    }

    private func start(_ fixture: Fixture, owner: String = "app-before-restart") throws -> String {
        let launch = RemoteHarnessLaunch(harnessID: "claude-code", model: "test-model", reasoning: "low", sandbox: false, input: Data("test brief".utf8), allowedTools: ["Read", "Write", "Edit", "Grep", "Glob", "Bash"])
        let route = RemoteProviderExecution(displayName: "Test", candidates: [
            RemoteProviderExecutionCandidate(kind: .directAccount, providerID: UUID(), modelProvider: .anthropic, displayName: "Test", endpoint: "https://api.anthropic.com/", authentication: .none, secret: nil)
        ])
        let response = try call(fixture, RemoteHostRequest(operation: .start, launch: launch, ownerID: owner, providerExecution: route))
        return try XCTUnwrap(response.runID, response.error ?? "missing run id")
    }

    private func start(_ fixture: Fixture, route: RemoteProviderExecution, model: String = "test-model", reasoning: String = "high", fast: Bool = true) throws -> String {
        let launch = RemoteHarnessLaunch(harnessID: "claude-code", model: model, reasoning: reasoning, sandbox: false, input: Data("test brief".utf8), allowedTools: ["Read", "Write", "Edit", "Grep", "Glob", "Bash"], options: ["fastMode": fast ? "true" : "false"])
        let response = try call(fixture, RemoteHostRequest(operation: .start, launch: launch, ownerID: "secure-route-test", providerExecution: route))
        return try XCTUnwrap(response.runID, response.error ?? "missing run id")
    }

    private func runFiles(_ fixture: Fixture, runID: String) throws -> [URL] {
        let directory = fixture.home.appendingPathComponent(".local/state/workjet/host/runs/\(runID)")
        let enumerator = FileManager.default.enumerator(at: directory, includingPropertiesForKeys: [.isRegularFileKey])
        return try XCTUnwrap(enumerator?.allObjects as? [URL]).filter {
            (try? $0.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true
        }
    }

    private func waitForState(_ fixture: Fixture, runID: String, _ predicate: (RemoteHostResponse) -> Bool, timeout: TimeInterval = 60) throws -> RemoteHostResponse {
        let deadline = Date().addingTimeInterval(timeout)
        var response = RemoteHostResponse(ok: false)
        repeat {
            response = try call(fixture, RemoteHostRequest(operation: .events, runID: runID, afterSequence: 0))
            if predicate(response) { return response }
            Thread.sleep(forTimeInterval: 0.1)
        } while Date() < deadline
        XCTFail("state did not converge: \(response.state) events=\(response.events.map { "\($0.kind):\($0.text ?? "")" })")
        return response
    }

    func testAppRestartCanListAndAdoptSilentRunWithIndependentHeartbeat() throws {
        let fixture = try fixture(script: "sleep 30")
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let runID = try start(fixture)
        let running = try waitForState(fixture, runID: runID, { $0.state == .running && $0.heartbeatAt != nil })
        let firstHeartbeat = try XCTUnwrap(running.heartbeatAt)

        Thread.sleep(forTimeInterval: 4.5)
        let listed = try call(fixture, RemoteHostRequest(operation: .probe, wireOperation: "list"))
        let descriptor = try XCTUnwrap(listed.runs.first(where: { $0.runID == runID }))
        XCTAssertEqual(descriptor.state, .running)
        XCTAssertNotEqual(descriptor.heartbeatAt, firstHeartbeat, "silent children must heartbeat without stdout")

        let adopted = try call(fixture, RemoteHostRequest(operation: .events, runID: runID, ownerID: "app-after-restart", wireOperation: "adopt"))
        XCTAssertEqual(adopted.runID, runID)
        let relisted = try call(fixture, RemoteHostRequest(operation: .probe, ownerID: "app-after-restart", wireOperation: "list"))
        XCTAssertEqual(relisted.runs.map(\.runID), [runID])
        _ = try call(fixture, RemoteHostRequest(operation: .stop, runID: runID))
    }

    func testAcceptedRunMetadataSurvivesListAndAdoptWithoutConfigurationInference() throws {
        let fixture = try fixture(script: "sleep 30")
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let workerID = UUID()
        let ownerID = "workjet-worker-\(workerID.uuidString.lowercased())"
        let launch = RemoteHarnessLaunch(
            harnessID: "claude-code",
            model: "claude-sonnet-test",
            reasoning: "high",
            sandbox: false,
            input: Data("durable brief".utf8),
            allowedTools: ["Read", "Write", "Edit", "Grep", "Glob", "Bash"],
            options: ["fastMode": "true"]
        )
        let route = RemoteProviderExecution(displayName: "Anthropic Pool", candidates: [
            RemoteProviderExecutionCandidate(kind: .directAccount, providerID: UUID(), modelProvider: .anthropic, displayName: "work@example.test", endpoint: "https://api.anthropic.com/", authentication: .none, secret: nil)
        ])

        let started = try call(fixture, RemoteHostRequest(
            operation: .start,
            launch: launch,
            ownerID: ownerID,
            providerExecution: route,
            workerName: "Completion Engine"
        ))
        let runID = try XCTUnwrap(started.runID)
        XCTAssertEqual(started.metadata?.workerID, workerID)
        XCTAssertEqual(started.metadata?.workerName, "Completion Engine")
        XCTAssertEqual(started.metadata?.harnessID, "claude-code")
        XCTAssertEqual(started.metadata?.model, "claude-sonnet-test")
        XCTAssertEqual(started.metadata?.reasoning, "high")
        XCTAssertEqual(started.metadata?.speed, "fast")
        XCTAssertEqual(started.metadata?.providerRoute, "Anthropic Pool")
        XCTAssertEqual(started.metadata?.providerAccountLabel, "work@example.test")
        XCTAssertNotNil(started.metadata?.startedAt)

        _ = try waitForState(fixture, runID: runID, { $0.state == .running })
        let listed = try call(fixture, RemoteHostRequest(operation: .probe, ownerID: ownerID, wireOperation: "list"))
        let descriptor = try XCTUnwrap(listed.runs.first(where: { $0.runID == runID }))
        XCTAssertEqual(descriptor.metadata?.workerID, workerID)
        XCTAssertEqual(descriptor.metadata?.workerName, "Completion Engine")
        XCTAssertEqual(descriptor.metadata?.providerAccountLabel, "work@example.test")

        let adopted = try call(fixture, RemoteHostRequest(operation: .events, runID: runID, ownerID: ownerID, wireOperation: "adopt"))
        XCTAssertEqual(adopted.metadata, descriptor.metadata)
        let launchFile = fixture.home.appendingPathComponent(".local/state/workjet/host/runs/\(runID)/launch.json")
        let persisted = String(decoding: try Data(contentsOf: launchFile), as: UTF8.self)
        XCTAssertTrue(persisted.contains("Completion Engine"))
        XCTAssertTrue(persisted.contains("claude-sonnet-test"))
        _ = try call(fixture, RemoteHostRequest(operation: .stop, runID: runID))
    }

    func testRemoteWebResearchRequiresCodexAndInjectsGatewayIntoNormalClaudeHarness() throws {
        let fixture = try fixture(script: "web-research-environment", greppyScript: "exit 0", codexAvailable: true)
        let relay = RemoteGatewayRelay(id: UUID(), remotePort: 48123)
        let launch = RemoteHarnessLaunch(
            harnessID: "claude-code",
            model: "grok-4.5",
            reasoning: "medium",
            sandbox: false,
            input: Data("research".utf8),
            systemPrompt: "WEB RESEARCH SYSTEM PROMPT",
            allowedTools: ["Read", "Write", "Edit", "Grep", "Glob", "Bash"],
            webResearch: true,
            greppy: true
        )
        let route = RemoteProviderExecution(displayName: "xAI Gateway", candidates: [
            RemoteProviderExecutionCandidate(kind: .gatewayPool, providerID: nil, modelProvider: .xAI, displayName: "xAI Gateway", endpoint: "http://127.0.0.1:48123", authentication: .bearerToken, secret: "gateway-token", relay: relay)
        ])
        let started = try call(fixture, RemoteHostRequest(operation: .start, launch: launch, ownerID: "web-research-test", providerExecution: route))
        let runID = try XCTUnwrap(started.runID, started.error ?? "missing run")
        let terminal = try waitForState(fixture, runID: runID, { $0.state.isTerminal })
        let output = terminal.events.compactMap(\.text).joined()
        XCTAssertTrue(output.contains("web:codex:http://127.0.0.1:48123/v1:[REDACTED]"))
        XCTAssertTrue(output.contains(fixture.home.appendingPathComponent(".local/state/workjet/host/greppy").path))
        XCTAssertFalse(output.contains("gateway-token"))
    }

    func testRetentionRemovesOnlyOldOwnedTerminalAndDefinitelyDeadRuns() throws {
        let fixture = try fixture(script: "echo unused")
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let runs = fixture.home.appendingPathComponent(".local/state/workjet/host/runs")
        try FileManager.default.createDirectory(at: runs, withIntermediateDirectories: true)
        let old = ISO8601DateFormatter().string(from: Date(timeIntervalSinceNow: -45 * 86_400))
        let overflowAge = ISO8601DateFormatter().string(from: Date(timeIntervalSinceNow: -2 * 86_400))
        let fresh = ISO8601DateFormatter().string(from: Date())

        func makeRun(_ id: String, state: String, ownerID: String?, updatedAt: String, pid: Int? = nil, identity: String? = nil) throws -> URL {
            let directory = runs.appendingPathComponent(id)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            var value: [String: Any] = ["state": state, "updatedAt": updatedAt]
            value["ownerID"] = ownerID
            value["pid"] = pid
            value["pidIdentity"] = identity
            try JSONSerialization.data(withJSONObject: value).write(to: directory.appendingPathComponent("state.json"))
            try Data("[]".utf8).write(to: directory.appendingPathComponent("events.json"))
            try Data(#"{"cursor":0,"count":0,"bytes":2}"#.utf8).write(to: directory.appendingPathComponent("ledger.json"))
            return directory
        }

        let owner = "workjet-worker-\(UUID().uuidString.lowercased())"
        let oldTerminal = try makeRun("old-terminal", state: "completed", ownerID: owner, updatedAt: old)
        let oldDead = try makeRun("old-dead", state: "running", ownerID: owner, updatedAt: old, pid: 987_654_321, identity: "linux-proc-start:missing")
        let freshTerminal = try makeRun("fresh-terminal", state: "completed", ownerID: owner, updatedAt: fresh)
        let foreign = try makeRun("foreign", state: "completed", ownerID: "another-controller", updatedAt: old)
        let ambiguous = try makeRun("ambiguous", state: "running", ownerID: owner, updatedAt: old)
        let symlinked = try makeRun("symlinked", state: "completed", ownerID: owner, updatedAt: old)
        for index in 0..<130 {
            _ = try makeRun("overflow-\(index)", state: "completed", ownerID: owner, updatedAt: overflowAge)
        }
        let outside = fixture.root.appendingPathComponent("outside-retention-sentinel")
        try Data("keep".utf8).write(to: outside)
        try FileManager.default.createSymbolicLink(at: symlinked.appendingPathComponent("unsafe-link"), withDestinationURL: outside)

        let probe = try call(fixture, RemoteHostRequest(operation: .probe))
        XCTAssertTrue(probe.capabilities.contains("run-retention-v1"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: oldTerminal.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: oldDead.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: freshTerminal.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: foreign.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: ambiguous.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: symlinked.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: outside.path))
        let overflowRemaining = try FileManager.default.contentsOfDirectory(atPath: runs.path)
            .filter { $0.hasPrefix("overflow-") }
        XCTAssertEqual(overflowRemaining.count, 128, "old terminal journals are bounded even inside the retention window")
    }

    func testProviderCredentialIsEphemeralRedactedAndEffectiveContextIsVisible() throws {
        let sentinel = "workjet-secret-never-persist-43D2"
        let script = "printf 'ctx:%s:%s:%s:%s\\n' \"$WORKJET_MODEL\" \"$WORKJET_REASONING\" \"$WORKJET_SPEED\" \"$WORKJET_PROVIDER_ROUTE\"; printf '%s\\n' \"$ANTHROPIC_AUTH_TOKEN\"; printf '%s\\n' \"$ANTHROPIC_AUTH_TOKEN\" >&2"
        let fixture = try fixture(script: script)
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let route = RemoteProviderExecution(displayName: "Primary", candidates: [
            RemoteProviderExecutionCandidate(kind: .directAccount, providerID: UUID(), modelProvider: .anthropic, displayName: "Primary", endpoint: "https://api.anthropic.com/", authentication: .bearerToken, secret: sentinel)
        ])

        let runID = try start(fixture, route: route, model: "claude-test", reasoning: "high", fast: true)
        let completed = try waitForState(fixture, runID: runID, { $0.state == .completed })
        let visible = completed.events.compactMap(\.text).joined()
        XCTAssertTrue(visible.contains("ctx:claude-test:high:fast:Primary"), visible)
        XCTAssertTrue(visible.contains("[REDACTED]"))
        XCTAssertFalse(visible.contains(sentinel))
        for file in try runFiles(fixture, runID: runID) {
            XCTAssertFalse(String(decoding: try Data(contentsOf: file), as: UTF8.self).contains(sentinel), "secret persisted in \(file.lastPathComponent)")
        }
        let launch = String(decoding: try Data(contentsOf: fixture.home.appendingPathComponent(".local/state/workjet/host/runs/\(runID)/launch.json")), as: UTF8.self)
        XCTAssertFalse(launch.contains("\"secret\""))
    }

    func testPiTurnReceivesRunScopedProviderRelayWithoutPersistingItsSecret() throws {
        let fixture = try fixture(script: "echo unused")
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let release = fixture.host.deletingLastPathComponent()
        try Data(RemotePiBootstrap.turnRunnerSource.utf8).write(to: release.appendingPathComponent("workjet-pi-turn.mjs"))
        let daemon = #"""
import fs from "node:fs";
import net from "node:net";
import os from "node:os";
import path from "node:path";
import process from "node:process";
const socketPath = process.argv[2];
const resolvedSocket = typeof socketPath === "string" ? path.resolve(socketPath) : "";
const privateDirectory = path.resolve(os.tmpdir());
if (!resolvedSocket || path.dirname(resolvedSocket) !== privateDirectory || !path.basename(privateDirectory).startsWith("workjet-pi-") || path.basename(resolvedSocket) !== "turn.sock" || resolvedSocket === path.resolve(process.execPath)) process.exit(64);
try { fs.unlinkSync(socketPath); } catch {}
const server = net.createServer(socket => {
  let pending = "";
  socket.on("data", async chunk => {
    pending += chunk.toString("utf8");
    if (!pending.includes("\n")) return;
    const request = JSON.parse(pending);
    socket.end(JSON.stringify({baseUrl: request.model.baseUrl}) + "\n");
    server.close();
  });
});
server.listen(socketPath);
"""#
        try Data(daemon.utf8).write(to: release.appendingPathComponent("ctox-pi-sidecar.mjs"))
        let relay = RemoteGatewayRelay(id: UUID(), remotePort: 48123)
        let secret = "pi-relay-secret-never-persist"
        let route = RemoteProviderExecution(displayName: "Kimi Gateway", candidates: [
            RemoteProviderExecutionCandidate(
                kind: .gatewayPool,
                providerID: nil,
                modelProvider: .kimi,
                displayName: "Kimi Gateway",
                endpoint: "http://127.0.0.1:\(relay.remotePort)/v1",
                authentication: .bearerToken,
                secret: secret,
                relay: relay
            )
        ])
        let launch = RemoteHarnessLaunch(
            harnessID: "pi-code",
            model: "k3",
            reasoning: "high",
            sandbox: false,
            input: Data("{\"files\":[]}".utf8)
        )

        let started = try call(fixture, RemoteHostRequest(operation: .start, launch: launch, ownerID: "pi-relay", providerExecution: route))
        let runID = try XCTUnwrap(started.runID)
        let completed = try waitForState(fixture, runID: runID, { $0.state == .completed })
        let visible = completed.events.compactMap(\.text).joined(separator: "\n")
        XCTAssertTrue(visible.contains("baseUrl"))
        XCTAssertTrue(visible.contains("http://127.0.0.1:"), "Pi daemon must receive only the credential-free per-turn loopback gateway")
        XCTAssertFalse(visible.contains(secret))
        XCTAssertTrue(RemotePiBootstrap.turnRunnerSource.contains("incoming.headers.authorization !== sentinel"))
        XCTAssertTrue(RemotePiBootstrap.turnRunnerSource.contains("headers.authorization = `Bearer ${providerSecret}`"))
        for file in try runFiles(fixture, runID: runID) {
            XCTAssertFalse(String(decoding: try Data(contentsOf: file), as: UTF8.self).contains(secret), "secret persisted in \(file.lastPathComponent)")
        }
    }

    func testHostFailsClosedWhenNonPiLaunchClaimsSandbox() throws {
        let fixture = try fixture(script: "echo must-not-run")
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let route = RemoteProviderExecution(displayName: "Direct", candidates: [
            RemoteProviderExecutionCandidate(
                kind: .directAccount,
                providerID: UUID(),
                modelProvider: .anthropic,
                displayName: "Direct",
                endpoint: "https://api.anthropic.com/",
                authentication: .none,
                secret: nil
            )
        ])
        let launch = RemoteHarnessLaunch(
            harnessID: "claude-code",
            model: "test-model",
            reasoning: nil,
            sandbox: true,
            input: Data("brief".utf8),
            allowedTools: ["Read"]
        )

        let rejected = try call(fixture, RemoteHostRequest(operation: .start, launch: launch, providerExecution: route))
        XCTAssertFalse(rejected.ok)
        XCTAssertEqual(rejected.state, .error)
        XCTAssertEqual(rejected.error, "sandbox is unavailable for this harness")
        XCTAssertNil(rejected.runID, "invalid sandbox claims must be rejected before a run is allocated")
        let listed = try call(fixture, RemoteHostRequest(operation: .probe, wireOperation: "list"))
        XCTAssertTrue(listed.runs.isEmpty)
    }

    func testExactHealthProbeRunsWithoutRepositoryAndArbitraryBypassIsRejected() throws {
        let fixture = try fixture(script: "echo WORKJET_HEALTH_OK")
        let route = RemoteProviderExecution(displayName: "Health", candidates: [
            RemoteProviderExecutionCandidate(kind: .directAccount, providerID: UUID(), modelProvider: .anthropic, displayName: "Health", endpoint: "https://api.anthropic.com/", authentication: .none, secret: nil)
        ])
        let prompt = "WORKJET HEALTH PROBE V1. This is a real user health ping: hi. Do not inspect or edit files. Do not use tools. Do not spawn subagents. Reply exactly WORKJET_HEALTH_OK and exit."
        let launch = RemoteHarnessLaunch(harnessID: "claude-code", model: "test-model", reasoning: nil, sandbox: false, input: Data(prompt.utf8), allowedTools: ["Read"], healthProbe: true)

        let started = try call(fixture, RemoteHostRequest(operation: .start, launch: launch, ownerID: "health", providerExecution: route))
        let runID = try XCTUnwrap(started.runID, started.error ?? "missing run id")
        let completed = try waitForState(fixture, runID: runID, { $0.state == .completed })
        XCTAssertTrue(completed.events.contains(where: { $0.text?.contains("WORKJET_HEALTH_OK") == true }))

        let forged = RemoteHarnessLaunch(harnessID: "claude-code", model: "test-model", reasoning: nil, sandbox: false, input: Data("do arbitrary work".utf8), allowedTools: ["Read"], healthProbe: true)
        let rejected = try call(fixture, RemoteHostRequest(operation: .start, launch: forged, ownerID: "health", providerExecution: route))
        XCTAssertFalse(rejected.ok)
        XCTAssertEqual(rejected.error, "invalid health probe")
    }

    func testCredentialSplitAcrossOutputChunksIsStillNeverExposed() throws {
        let sentinel = "split-secret-sentinel"
        let script = "printf 'split-secret-'; sleep 1; printf 'sentinel\\n'"
        let fixture = try fixture(script: script)
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let route = RemoteProviderExecution(displayName: "Primary", candidates: [
            RemoteProviderExecutionCandidate(kind: .directAccount, providerID: UUID(), modelProvider: .anthropic, displayName: "Primary", endpoint: "https://api.anthropic.com/", authentication: .bearerToken, secret: sentinel)
        ])
        let runID = try start(fixture, route: route)
        let response = try waitForState(fixture, runID: runID, { $0.state == .completed }, timeout: 30)
        let visible = response.events.compactMap(\.text).joined(separator: "\n")
        XCTAssertFalse(visible.contains(sentinel))
        XCTAssertFalse(visible.contains("split-secret-"))
        XCTAssertTrue(visible.contains("[REDACTED]"))
    }

    func testProviderPoolFallsBackOnlyForRetryableProviderFailure() throws {
        let script = "if [ \"$ANTHROPIC_AUTH_TOKEN\" = first-secret ]; then echo 'HTTP 429 rate limit' >&2; exit 1; fi; echo used-second"
        let fixture = try fixture(script: script)
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let route = RemoteProviderExecution(displayName: "Anthropic Pool", candidates: [
            RemoteProviderExecutionCandidate(kind: .directAccount, providerID: UUID(), modelProvider: .anthropic, displayName: "First", endpoint: "https://api.anthropic.com/", authentication: .bearerToken, secret: "first-secret"),
            RemoteProviderExecutionCandidate(kind: .directAccount, providerID: UUID(), modelProvider: .anthropic, displayName: "Second", endpoint: "https://api.anthropic.com/", authentication: .bearerToken, secret: "second-secret")
        ])
        let runID = try start(fixture, route: route)
        let response = try waitForState(fixture, runID: runID, { $0.state == .completed })
        let events = response.events.compactMap(\.text)
        XCTAssertTrue(events.contains("provider fallback"))
        XCTAssertTrue(events.contains(where: { $0.contains("used-second") }))
        XCTAssertFalse(events.joined().contains("first-secret"))
        XCTAssertFalse(events.joined().contains("second-secret"))
    }

    func testProviderPoolDoesNotFallbackForTaskFailure() throws {
        let script = "if [ \"$ANTHROPIC_AUTH_TOKEN\" = first-secret ]; then echo 'tests failed' >&2; exit 2; fi; echo used-second"
        let fixture = try fixture(script: script)
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let route = RemoteProviderExecution(displayName: "Anthropic Pool", candidates: [
            RemoteProviderExecutionCandidate(kind: .directAccount, providerID: UUID(), modelProvider: .anthropic, displayName: "First", endpoint: "https://api.anthropic.com/", authentication: .bearerToken, secret: "first-secret"),
            RemoteProviderExecutionCandidate(kind: .directAccount, providerID: UUID(), modelProvider: .anthropic, displayName: "Second", endpoint: "https://api.anthropic.com/", authentication: .bearerToken, secret: "second-secret")
        ])
        let runID = try start(fixture, route: route)
        let response = try waitForState(fixture, runID: runID, { $0.state == .failed })
        let events = response.events.compactMap(\.text)
        XCTAssertFalse(events.contains("provider fallback"))
        XCTAssertFalse(events.contains(where: { $0.contains("used-second") }))
    }

    func testTurnTimeoutTerminatesRemoteWorkerAndNeverFallsBack() throws {
        let fixture = try fixture(script: "term-trap-ready")
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let route = RemoteProviderExecution(displayName: "Anthropic Pool", candidates: [
            RemoteProviderExecutionCandidate(kind: .directAccount, providerID: UUID(), modelProvider: .anthropic, displayName: "First", endpoint: "https://api.anthropic.com/", authentication: .none, secret: nil),
            RemoteProviderExecutionCandidate(kind: .directAccount, providerID: UUID(), modelProvider: .anthropic, displayName: "Second", endpoint: "https://api.anthropic.com/", authentication: .none, secret: nil)
        ])
        let launch = RemoteHarnessLaunch(harnessID: "claude-code", model: "test-model", reasoning: nil, sandbox: false, input: Data("timeout".utf8), allowedTools: ["Read", "Write", "Edit", "Grep", "Glob", "Bash"])
        let startedAt = Date()
        let started = try call(fixture, RemoteHostRequest(operation: .start, launch: launch, ownerID: "timeout-test", providerExecution: route, turnTimeoutSeconds: 1))
        let runID = try XCTUnwrap(started.runID)
        let terminal = try waitForState(fixture, runID: runID, { $0.state == .failed }, timeout: 8)
        XCTAssertLessThan(Date().timeIntervalSince(startedAt), 6)
        XCTAssertTrue(terminal.events.contains { $0.kind == "timeout" && $0.exitCode == 124 })
        XCTAssertFalse(terminal.events.contains { $0.text == "provider fallback" })
        let launchFile = fixture.home.appendingPathComponent(".local/state/workjet/host/runs/\(runID)/launch.json")
        XCTAssertTrue(String(decoding: try Data(contentsOf: launchFile), as: UTF8.self).contains("\"turnTimeoutSeconds\":1"))
    }

    func testProviderPoolDoesNotFallbackForTransportOrServerFailure() throws {
        let script = "if [ \"$ANTHROPIC_AUTH_TOKEN\" = first-secret ]; then echo 'HTTP 503 upstream timeout' >&2; exit 1; fi; echo used-second"
        let fixture = try fixture(script: script)
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let route = RemoteProviderExecution(displayName: "Anthropic Pool", candidates: [
            RemoteProviderExecutionCandidate(kind: .directAccount, providerID: UUID(), modelProvider: .anthropic, displayName: "First", endpoint: "https://api.anthropic.com/", authentication: .bearerToken, secret: "first-secret"),
            RemoteProviderExecutionCandidate(kind: .directAccount, providerID: UUID(), modelProvider: .anthropic, displayName: "Second", endpoint: "https://api.anthropic.com/", authentication: .bearerToken, secret: "second-secret")
        ])
        let runID = try start(fixture, route: route)
        let response = try waitForState(fixture, runID: runID, { $0.state == .failed })
        let events = response.events.compactMap(\.text)
        XCTAssertFalse(events.contains("provider fallback"))
        XCTAssertFalse(events.contains(where: { $0.contains("used-second") }))
    }

    func testMissingEphemeralCredentialDeliveryBecomesTypedTerminalError() throws {
        let fixture = try fixture(script: "echo unused")
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let runID = "run-missing-credentials"
        let directory = fixture.home.appendingPathComponent(".local/state/workjet/host/runs/\(runID)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data("[]".utf8).write(to: directory.appendingPathComponent("events.json"))
        try Data(#"{"cursor":0,"count":0,"bytes":2}"#.utf8).write(to: directory.appendingPathComponent("ledger.json"))
        let old = ISO8601DateFormatter().string(from: Date(timeIntervalSinceNow: -60))
        try Data("{\"state\":\"starting\",\"credentialDelivery\":\"required\",\"updatedAt\":\"\(old)\"}".utf8).write(to: directory.appendingPathComponent("state.json"))

        let response = try call(fixture, RemoteHostRequest(operation: .events, runID: runID, afterSequence: 0))
        XCTAssertEqual(response.state, .error)
        XCTAssertTrue(response.events.contains(where: { $0.kind == "error" && $0.text?.contains("credentials were not delivered") == true }))
    }

    func testProbeAdvertisesGreppyOnlyAfterVersionSurfaceAndRuntimeHealthCheck() throws {
        let missing = try fixture(script: "echo unused")
        defer { try? FileManager.default.removeItem(at: missing.root) }
        XCTAssertFalse(try call(missing, RemoteHostRequest(operation: .probe)).capabilities.contains(WorkerSkillCatalog.greppyCapability))

        let broken = try fixture(script: "echo unused", greppyScript: "printf 'managed target missing\\n' >&2; exit 78", allowManagedSkillsOnFixturePlatform: true)
        defer { try? FileManager.default.removeItem(at: broken.root) }
        XCTAssertTrue(FileManager.default.isExecutableFile(atPath: broken.home.appendingPathComponent(".local/lib/workjet/skills/bin/greppy").path))
        XCTAssertFalse(try call(broken, RemoteHostRequest(operation: .probe)).capabilities.contains(WorkerSkillCatalog.greppyCapability))

        let healthy = try fixture(
            script: "echo unused",
            greppyScript: "if [ \"$#\" -eq 1 ] && [ \"$1\" = \"--version\" ]; then printf 'greppy 0.3.1\\n'; elif [ \"$#\" -eq 1 ] && [ \"$1\" = \"--help\" ]; then i=0; while [ \"$i\" -lt 5000 ]; do printf x; i=$((i + 1)); done; printf ' who-calls search-symbol bash-smart\\n'; elif [ \"$#\" -eq 2 ] && [ \"$1\" = \"index\" ] && [ -f \"$2/runtime_probe.rs\" ]; then printf 'indexed runtime probe\\n'; else exit 64; fi",
            allowManagedSkillsOnFixturePlatform: true
        )
        defer { try? FileManager.default.removeItem(at: healthy.root) }
        let capabilities = try call(healthy, RemoteHostRequest(operation: .probe)).capabilities
        XCTAssertEqual(capabilities.filter { $0 == WorkerSkillCatalog.greppyCapability }.count, 1)
    }

    func testStartWithoutProviderExecutionIsRejectedAndProbeAdvertisesSecureRoute() throws {
        let fixture = try fixture(script: "echo unused")
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let probe = try call(fixture, RemoteHostRequest(operation: .probe))
        XCTAssertTrue(probe.capabilities.contains("provider-execution-v1"))
        XCTAssertTrue(probe.capabilities.contains("gateway-relay-v1"))
        XCTAssertTrue(probe.capabilities.contains("relay-loss-v1"))
        let launch = RemoteHarnessLaunch(harnessID: "claude-code", model: "test", reasoning: nil, sandbox: false, input: Data("brief".utf8), allowedTools: ["Read"])
        let response = try call(fixture, RemoteHostRequest(operation: .start, launch: launch))
        XCTAssertFalse(response.ok)
        XCTAssertEqual(response.error, "invalid provider route")
    }

    func testHostRejectsGatewayPoolWithoutVerifiedRelay() throws {
        let fixture = try fixture(script: "echo must-not-run")
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let route = RemoteProviderExecution(displayName: "Kimi Gateway", candidates: [
            RemoteProviderExecutionCandidate(kind: .gatewayPool, providerID: nil, modelProvider: .kimi, displayName: "Kimi Gateway", endpoint: "http://127.0.0.1:8317/v1", authentication: .bearerToken, secret: "gateway-token")
        ])
        let launch = RemoteHarnessLaunch(harnessID: "claude-code", model: "kimi", reasoning: nil, sandbox: false, input: Data("brief".utf8), allowedTools: ["Read"])
        let response = try call(fixture, RemoteHostRequest(operation: .start, launch: launch, providerExecution: route))
        XCTAssertFalse(response.ok)
        XCTAssertEqual(response.error, "gateway relay identity missing")
    }

    func testGatewayRelayMetadataIsNonSecretAndRelayLossOnlyTerminatesItsRun() throws {
        let fixture = try fixture(script: "sleep 30")
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let firstRelay = RemoteGatewayRelay(id: UUID(), remotePort: 48101)
        let secondRelay = RemoteGatewayRelay(id: UUID(), remotePort: 48102)
        let route: (RemoteGatewayRelay) -> RemoteProviderExecution = { relay in
            RemoteProviderExecution(displayName: "Kimi Gateway", candidates: [
                RemoteProviderExecutionCandidate(kind: .gatewayPool, providerID: nil, modelProvider: .kimi, displayName: "Kimi Gateway", endpoint: "http://127.0.0.1:\(relay.remotePort)/v1", authentication: .bearerToken, secret: "gateway-token", relay: relay)
            ])
        }
        let first = try start(fixture, route: route(firstRelay))
        let second = try start(fixture, route: route(secondRelay))
        _ = try waitForState(fixture, runID: first, { $0.state == .running })
        _ = try waitForState(fixture, runID: second, { $0.state == .running })

        let listed = try call(fixture, RemoteHostRequest(operation: .probe, wireOperation: "list"))
        XCTAssertEqual(listed.runs.first(where: { $0.runID == first })?.relayID, firstRelay.id)
        XCTAssertEqual(listed.runs.first(where: { $0.runID == second })?.relayID, secondRelay.id)
        let launch = String(decoding: try Data(contentsOf: fixture.home.appendingPathComponent(".local/state/workjet/host/runs/\(first)/launch.json")), as: UTF8.self)
        XCTAssertTrue(launch.lowercased().contains(firstRelay.id.uuidString.lowercased()))
        XCTAssertFalse(launch.contains("gateway-token"))

        let lost = try call(fixture, RemoteHostRequest(operation: .relayLost, runID: first))
        XCTAssertEqual(lost.state, .error)
        let firstEvents = try call(fixture, RemoteHostRequest(operation: .events, runID: first, afterSequence: 0))
        XCTAssertTrue(firstEvents.events.contains(where: { $0.kind == "error" && $0.text == "secure provider tunnel disconnected" }))
        let secondStillRunning = try call(fixture, RemoteHostRequest(operation: .events, runID: second, afterSequence: 0))
        XCTAssertEqual(secondStillRunning.state, .running)
        _ = try call(fixture, RemoteHostRequest(operation: .stop, runID: second))
    }

    func testPIDStartIdentityMismatchIsNotTreatedAsTheChild() throws {
        let fixture = try fixture(script: "sleep 30")
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let runID = try start(fixture)
        _ = try waitForState(fixture, runID: runID, { $0.state == .running })
        let stateFile = fixture.home.appendingPathComponent(".local/state/workjet/host/runs/\(runID)/state.json")
        var state = try JSONSerialization.jsonObject(with: Data(contentsOf: stateFile)) as! [String: Any]
        state["pidIdentity"] = "reused-pid-different-start"
        try JSONSerialization.data(withJSONObject: state).write(to: stateFile, options: .atomic)

        let observed = try call(fixture, RemoteHostRequest(operation: .events, runID: runID, afterSequence: 0))
        XCTAssertEqual(observed.state, .failed)
        let failedState = try JSONSerialization.jsonObject(with: Data(contentsOf: stateFile)) as! [String: Any]
        XCTAssertTrue((failedState["error"] as? String)?.contains("start identity") == true)
    }

    func testLargeOutputRotatesWithinBoundsAndReportsRecoverableCursorGap() async throws {
        let fixture = try fixture(script: "sleep 1; i=0; while [ $i -lt 3000 ]; do printf '0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef'; i=$((i+1)); done")
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let runID = try start(fixture)
        let completed = try waitForState(fixture, runID: runID, { $0.state.isTerminal })
        XCTAssertLessThanOrEqual(completed.events.count, 64)
        let eventsFile = fixture.home.appendingPathComponent(".local/state/workjet/host/runs/\(runID)/events.json")
        XCTAssertLessThanOrEqual(try Data(contentsOf: eventsFile).count, 256 * 1024)
        let oldest = try XCTUnwrap(completed.oldestSequence)
        XCTAssertGreaterThan(oldest, 1)
        XCTAssertEqual(completed.gapAfterSequence, 0)

        let host = ScriptedCaller(responses: [completed])
        let ledger = RemoteRunLedger(client: host)
        let snapshot = try await ledger.adopt(runID: runID, ownerID: "new-app")
        XCTAssertEqual(snapshot.cursor, completed.cursor)
        let lostThrough = await ledger.lostThroughSequence
        XCTAssertEqual(lostThrough, oldest - 1)
    }

    func testStopEscalatesFromTERMToKILL() throws {
        let fixture = try fixture(script: "trap '' TERM; printf 'term-trap-ready\\n'; while :; do sleep 1; done")
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let runID = try start(fixture)
        _ = try waitForState(fixture, runID: runID, {
            $0.state == .running && $0.events.contains(where: { $0.text?.contains("term-trap-ready") == true })
        })
        let started = Date()
        let stopped = try call(fixture, RemoteHostRequest(operation: .stop, runID: runID))
        XCTAssertEqual(stopped.state, .stopped)
        XCTAssertGreaterThanOrEqual(Date().timeIntervalSince(started), 2.0)
    }

    func testHarnessLifecycleRequestRoundTripsWithoutClientCommandSurfaceAndV1StillDecodes() throws {
        let request = RemoteHostRequest(harnessID: "claude-code", action: .update)
        let encoded = try JSONEncoder().encode(request)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        XCTAssertEqual(object["operation"] as? String, "harness-update")
        XCTAssertEqual(object["harnessID"] as? String, "claude-code")
        XCTAssertNil(object["executable"])
        XCTAssertNil(object["arguments"])
        XCTAssertEqual(try JSONDecoder().decode(RemoteHostRequest.self, from: encoded), request)

        let v1 = Data(#"{"operation":"probe"}"#.utf8)
        let decodedV1 = try JSONDecoder().decode(RemoteHostRequest.self, from: v1)
        XCTAssertEqual(decodedV1.protocolVersion, 1)
        XCTAssertEqual(decodedV1.operation, .probe)
        XCTAssertNil(decodedV1.harnessID)

        let oldResponse = Data(#"{"ok":true,"state":"unknown","cursor":0}"#.utf8)
        let decodedResponse = try JSONDecoder().decode(RemoteHostResponse.self, from: oldResponse)
        XCTAssertEqual(decodedResponse.protocolVersion, 1)
        XCTAssertNil(decodedResponse.harnessResult)
    }

    func testHarnessLifecycleRejectsUnknownHarnessAndClientSuppliedCommand() throws {
        let fixture = try fixture(script: "echo 'claude 1.2.3'")
        defer { try? FileManager.default.removeItem(at: fixture.root) }

        let unknown = try call(fixture, RemoteHostRequest(harnessID: "made-up", action: .inspect))
        XCTAssertFalse(unknown.ok)
        XCTAssertEqual(unknown.error, "unsupported harness")

        var forbidden = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(RemoteHostRequest(harnessID: "claude-code", action: .inspect))) as? [String: Any])
        forbidden["executable"] = "/bin/sh"
        forbidden["arguments"] = ["-c", "touch /tmp/pwned"]
        var payload = try JSONSerialization.data(withJSONObject: forbidden)
        payload.append(0x0a)
        let rejected = try call(fixture, payload: payload)
        XCTAssertFalse(rejected.ok)
        XCTAssertEqual(rejected.error, "client commands are forbidden")
        XCTAssertFalse(RemotePiBootstrap.hostRuntimeSource.contains("sh -c"))
        XCTAssertFalse(RemotePiBootstrap.hostRuntimeSource.contains("\"/bin/sh\""))
        XCTAssertFalse(RemotePiBootstrap.hostRuntimeSource.contains("\"/usr/bin/sh\""))
    }

    func testManagedSkillLifecycleRejectsCommandAndURLInjectionAndUnsupportedTargetFailsClosed() throws {
        let fixture = try fixture(script: "echo unused", forceUnsupportedManagedSkillTarget: true)
        defer { try? FileManager.default.removeItem(at: fixture.root) }

        let unsupported = try call(fixture, RemoteHostRequest(skillID: "greppy", action: .inspect))
        XCTAssertEqual(unsupported.managedSkillResult?.skillID, "greppy")
        XCTAssertEqual(unsupported.managedSkillResult?.state, .unavailable)
        XCTAssertTrue(unsupported.managedSkillResult?.detail?.contains("Linux x86_64") == true)

        var forbidden = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(RemoteHostRequest(skillID: "greppy", action: .install))) as? [String: Any])
        forbidden["url"] = "https://attacker.invalid/payload.tar.gz"
        forbidden["command"] = "/bin/sh"
        forbidden["arguments"] = ["-c", "touch /tmp/pwned"]
        var payload = try JSONSerialization.data(withJSONObject: forbidden)
        payload.append(0x0a)
        let rejected = try call(fixture, payload: payload)
        XCTAssertFalse(rejected.ok)
        XCTAssertEqual(rejected.error, "client commands and URLs are forbidden")
    }

    func testManagedGreppyArtifactRejectsUnsupportedTargetsAndBadDigest() {
        XCTAssertTrue(RemoteManagedSkillArtifact.supportsGreppy(os: "linux", architecture: "x86_64"))
        XCTAssertFalse(RemoteManagedSkillArtifact.supportsGreppy(os: "darwin", architecture: "arm64"))
        XCTAssertFalse(RemoteManagedSkillArtifact.supportsGreppy(os: "linux", architecture: "aarch64"))
        XCTAssertFalse(RemoteManagedSkillArtifact.validatesGreppySourceArchive(Data("not the pinned release".utf8)))
        XCTAssertEqual(RemoteManagedSkillArtifact.greppyVersion, "0.3.1")
        XCTAssertEqual(RemoteManagedSkillArtifact.greppyCommit, "547705051d2c69481955e218f62f404e75e974ed")
        XCTAssertEqual(RemoteManagedSkillArtifact.greppySourceSHA256, "4d23d1db0f5b9accc2066ac3b430c03c46a904437b6d7456edec21665231907d")
        XCTAssertTrue(RemotePiBootstrap.hostRuntimeSource.contains("cargo build failed"))
        XCTAssertTrue(RemotePiBootstrap.hostRuntimeSource.contains("--locked"))
        XCTAssertTrue(RemotePiBootstrap.hostRuntimeSource.contains("[\"build\", \"--quiet\", \"--manifest-path\""))
        XCTAssertTrue(RemotePiBootstrap.hostRuntimeSource.contains("3600000"))
        XCTAssertTrue(RemotePiBootstrap.hostRuntimeSource.contains(".cargo/bin/cargo"))
        XCTAssertTrue(RemotePiBootstrap.hostRuntimeSource.contains("path.dirname(cargo)"))
        XCTAssertTrue(RemotePiBootstrap.hostRuntimeSource.contains("MODEL_ASSETS.json"))
        XCTAssertTrue(RemotePiBootstrap.hostRuntimeSource.contains("model asset digest mismatch"))
        XCTAssertTrue(RemotePiBootstrap.hostRuntimeSource.contains("\"--bin\", \"greppy\""))
        XCTAssertTrue(RemotePiBootstrap.hostRuntimeSource.contains("verifyManagedGreppyRuntime"))
        XCTAssertTrue(RemotePiBootstrap.hostRuntimeSource.contains("greppy-runtime-probe.json"))
        XCTAssertTrue(RemotePiBootstrap.hostRuntimeSource.contains("eingebetteten Modell- und Index-Runtimepfad"))
    }

    func testHarnessInspectAndNativeUpdateUseFixedPlanAndReturnStructuredResult() throws {
        let script = #"if [ "$1" = "upgrade" ]; then exit 0; fi; echo 'OpenCode 1.2.3'"#
        let fixture = try fixture(script: script)
        defer { try? FileManager.default.removeItem(at: fixture.root) }

        let inspected = try call(fixture, RemoteHostRequest(harnessID: "opencode", action: .inspect))
        XCTAssertTrue(inspected.ok)
        XCTAssertEqual(inspected.harnessResult?.harnessID, "opencode")
        XCTAssertEqual(inspected.harnessResult?.action, .inspect)
        XCTAssertEqual(inspected.harnessResult?.state, .installed)
        XCTAssertEqual(inspected.harnessResult?.version, "1.2.3")

        let updated = try call(fixture, RemoteHostRequest(harnessID: "opencode", action: .update))
        XCTAssertTrue(updated.ok)
        XCTAssertEqual(updated.harnessResult?.action, .update)
        XCTAssertEqual(updated.harnessResult?.state, .installed)
        XCTAssertEqual(updated.harnessResult?.version, "1.2.3")
    }

    func testHarnessProbeOutputAndDiagnosticsAreBounded() throws {
        let fixture = try fixture(script: "i=0; while [ $i -lt 10000 ]; do printf x >&2; i=$((i+1)); done; exit 7")
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let response = try call(fixture, RemoteHostRequest(harnessID: "opencode", action: .inspect))
        XCTAssertEqual(response.harnessResult?.state, .broken)
        XCTAssertLessThanOrEqual(response.harnessResult?.detail?.utf8.count ?? .max, 4096)
    }

    func testPiLifecycleReportsContentAddressedDeploymentAndNeverGlobalMaintenance() throws {
        let fixture = try fixture(script: "echo unused")
        defer { try? FileManager.default.removeItem(at: fixture.root) }

        let inspected = try call(fixture, RemoteHostRequest(harnessID: "pi-code", action: .inspect))
        XCTAssertEqual(inspected.harnessResult?.state, .installed)
        XCTAssertEqual(inspected.harnessResult?.version, PiSidecarRuntime.version)
        XCTAssertEqual(inspected.harnessResult?.detail, "Pi Code ist eingerichtet und bereit.")

        for action in [RemoteHarnessMaintenanceAction.install, .update, .remove] {
            let response = try call(fixture, RemoteHostRequest(harnessID: "pi-code", action: action))
            XCTAssertEqual(response.harnessResult?.state, .unavailable)
            XCTAssertEqual(response.harnessResult?.detail, "Pi Code wird beim Einrichten des Computers von Workjet verwaltet.")
        }

        let cursor = try call(fixture, RemoteHostRequest(harnessID: "cursor-agent", action: .update))
        XCTAssertEqual(cursor.harnessResult?.state, .unavailable)
    }

    private actor ScriptedCaller: RemoteHostCalling {
        var responses: [RemoteHostResponse]
        init(responses: [RemoteHostResponse]) { self.responses = responses }
        func call(_ request: RemoteHostRequest) async throws -> RemoteHostResponse { responses.removeFirst() }
    }
}
