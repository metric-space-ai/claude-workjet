import XCTest
@testable import WorkjetCore

final class RemoteHostOnboardingTests: XCTestCase {
    private actor Runner: CommandRunning {
        private var results: [CommandResult]
        private(set) var commands: [CommandSpec] = []

        init(_ results: [CommandResult]) { self.results = results }

        func run(_ command: CommandSpec) async throws -> CommandResult {
            commands.append(command)
            return results.removeFirst()
        }

        func recordedCommands() -> [CommandSpec] { commands }
    }

    private final class Store: KnownHostsStoring, @unchecked Sendable {
        private let lock = NSLock()
        private(set) var writes: [(String, URL)] = []

        func appendConfirmedHostKey(_ line: String, to url: URL) throws {
            lock.lock()
            writes.append((line, url))
            lock.unlock()
        }

        func recordedWrites() -> [(String, URL)] {
            lock.lock()
            defer { lock.unlock() }
            return writes
        }
    }

    private final class BootstrapService: WorkjetService, @unchecked Sendable {
        var bootstrapResult: Computer
        var bootstrapInputs: [Computer] = []
        var saveAttempts: [WorkjetConfiguration] = []
        var successfulSaves: [WorkjetConfiguration] = []
        var failNextSave = false

        init(bootstrapResult: Computer) { self.bootstrapResult = bootstrapResult }

        func save(_ configuration: WorkjetConfiguration, handwrittenRulesChanged: Bool) throws {
            saveAttempts.append(configuration)
            if failNextSave {
                failNextSave = false
                throw LocalStateError.io("Einmaliger Testfehler")
            }
            successfulSaves.append(configuration)
        }

        func runs(workers: [Worker]) -> [RunRecord] { [] }
        func stop(_ run: ActiveRun) throws {}
        func inspectCLIProxy(_ configuration: CLIProxyConfiguration) async -> CLIProxyStatus {
            CLIProxyStatus(endpoint: configuration.endpoint, state: .offline, detail: "test", capacity: .unavailable(reason: "test"))
        }
        func storeCredential(_ secret: Data, reference: String) throws {}
        func bootstrapRemotePi(_ computer: Computer) async -> Computer {
            bootstrapInputs.append(computer)
            return bootstrapResult
        }
    }

    private var keyBlob: String { Data(repeating: 0x2A, count: 32).base64EncodedString() }

    private var computer: Computer {
        Computer(
            name: "Pi",
            transport: .ssh,
            host: "pi.example.test",
            user: "workjet",
            port: 2222,
            deploymentStatus: .blocked,
            deploymentDetail: "SSH-Host-Key fehlt.",
            knownHostsPath: "/private/workjet/known_hosts"
        )
    }

    private var tailscaleComputer: Computer {
        var value = computer
        value.transport = .tailscale
        value.host = "pi.tailnet.ts.net"
        value.port = 22
        return value
    }

    func testScanDoesNotWriteBeforeExplicitConfirmationAndUsesFixedArgumentArray() async throws {
        let line = "[pi.example.test]:2222 ssh-ed25519 \(keyBlob)"
        let runner = Runner([CommandResult(exitCode: 0, standardOutput: Data((line + "\n").utf8))])
        let store = Store()
        let bootstrap = RemotePiBootstrap(runner: runner, knownHostsStore: store)

        let candidate = try await bootstrap.scanHostKey(for: computer)

        XCTAssertEqual(store.recordedWrites().count, 0)
        XCTAssertEqual(candidate.knownHostsLine, line)
        XCTAssertTrue(candidate.fingerprint.hasPrefix("SHA256:"))
        let commands = await runner.recordedCommands()
        XCTAssertEqual(commands.count, 1)
        XCTAssertEqual(commands[0].executable, "/usr/bin/ssh-keyscan")
        XCTAssertEqual(commands[0].arguments, ["-T", "10", "-t", "ed25519", "-p", "2222", "pi.example.test"])
        XCTAssertFalse(commands[0].arguments.contains("-c"))
    }

    func testConfirmationWritesExactlyScannedLineToConfiguredPrivatePath() async throws {
        let line = "[pi.example.test]:2222 ssh-ed25519 \(keyBlob)"
        let runner = Runner([CommandResult(exitCode: 0, standardOutput: Data((line + "\n").utf8))])
        let store = Store()
        let bootstrap = RemotePiBootstrap(runner: runner, knownHostsStore: store)
        let candidate = try await bootstrap.scanHostKey(for: computer)

        try bootstrap.confirmHostKey(candidate, for: computer)

        let writes = store.recordedWrites()
        XCTAssertEqual(writes.count, 1)
        XCTAssertEqual(writes[0].0, line)
        XCTAssertEqual(writes[0].1.path, "/private/workjet/known_hosts")
    }

    func testTailscaleUsesTheSameExplicitFingerprintConfirmationAndStrictOpenSSHTransport() async throws {
        let line = "pi.tailnet.ts.net ssh-ed25519 \(keyBlob)"
        let runner = Runner([CommandResult(exitCode: 0, standardOutput: Data((line + "\n").utf8))])
        let store = Store()
        let bootstrap = RemotePiBootstrap(runner: runner, knownHostsStore: store)

        let candidate = try await bootstrap.scanHostKey(for: tailscaleComputer)
        XCTAssertEqual(candidate.host, "pi.tailnet.ts.net")
        XCTAssertEqual(candidate.port, 22)
        XCTAssertTrue(store.recordedWrites().isEmpty)
        try bootstrap.confirmHostKey(candidate, for: tailscaleComputer)
        XCTAssertEqual(store.recordedWrites().map(\.0), [line])

        let command = try RemoteCommandBuilder.command(
            for: tailscaleComputer,
            tailscaleExecutable: "/usr/bin/tailscale",
            remoteExecutable: "node",
            remoteArguments: [".local/lib/workjet/current/workjet-host.mjs"],
            standardInput: Data(),
            timeout: 30
        )
        XCTAssertEqual(command.executable, "/usr/bin/ssh")
        XCTAssertTrue(command.arguments.contains("StrictHostKeyChecking=yes"))
        XCTAssertTrue(command.arguments.contains("UserKnownHostsFile=\"/private/workjet/known_hosts\""))
        XCTAssertFalse(command.arguments.contains("ssh"), "the Tailscale CLI must not become a second SSH policy")
    }

    func testHostKeyScanReportsRefusedSSHServiceAsActionableBlockedPrerequisite() async throws {
        let runner = Runner([
            CommandResult(exitCode: 1, standardError: Data("connect to host 100.87.204.48 port 22: Connection refused\n".utf8))
        ])
        let bootstrap = RemotePiBootstrap(runner: runner)
        var target = tailscaleComputer
        target.host = "100.87.204.48"

        do {
            _ = try await bootstrap.scanHostKey(for: target)
            XCTFail("Ein abgelehnter SSH-Port darf nicht als unspezifischer Identitätsfehler erscheinen.")
        } catch let error as RemotePiBootstrapError {
            XCTAssertEqual(error, .sshServiceUnavailable(host: "100.87.204.48", port: 22))
            XCTAssertTrue(error.isBlocked)
            XCTAssertTrue(error.localizedDescription.contains("kein SSH-Dienst"))
            XCTAssertTrue(error.localizedDescription.contains("tailscale set --ssh"))
        }
    }

    func testHostKeyScanClassifiesBrokenPipeAsUnavailableSSHService() async throws {
        let runner = Runner([
            CommandResult(exitCode: 1, standardError: Data("write (100.87.204.48): Broken pipe\n".utf8))
        ])
        let bootstrap = RemotePiBootstrap(runner: runner)
        var target = tailscaleComputer
        target.host = "100.87.204.48"

        do {
            _ = try await bootstrap.scanHostKey(for: target)
            XCTFail("Ein sofort geschlossener SSH-Port muss als fehlender SSH-Dienst erklärt werden.")
        } catch let error as RemotePiBootstrapError {
            XCTAssertEqual(error, .sshServiceUnavailable(host: "100.87.204.48", port: 22))
        }
    }

    func testComputerDraftPersistsSelectedSSHIdentity() throws {
        var original = computer
        original.identityFilePath = "/Users/test/.ssh/id_ed25519_workjet"

        let draft = ComputerDraft(computer: original)
        let reopened = try XCTUnwrap(draft.applied(to: original))

        XCTAssertEqual(draft.identityFilePath, original.identityFilePath)
        XCTAssertEqual(reopened.identityFilePath, original.identityFilePath)
    }

    func testNewComputerDefaultsReuseTheNewestInstalledComputerOnTheSameTransport() throws {
        var older = tailscaleComputer
        older.name = "gpu-old"
        older.user = "old-user"
        older.identityFilePath = "/Users/test/.ssh/old"
        older.deploymentStatus = .installed
        older.lastSuccessfulDeploymentAt = Date(timeIntervalSince1970: 100)
        var newest = older
        newest.id = UUID()
        newest.name = "gpu3-a4500"
        newest.user = "metricspace"
        newest.identityFilePath = "/Users/test/.ssh/id_ed25519_ctox"
        newest.lastSuccessfulDeploymentAt = Date(timeIntervalSince1970: 200)
        var wrongTransport = newest
        wrongTransport.id = UUID()
        wrongTransport.transport = .ssh
        wrongTransport.lastSuccessfulDeploymentAt = Date(timeIntervalSince1970: 300)

        let preferred = try XCTUnwrap(ComputerDraft.preferredConnectionDefaults(
            in: [WorkjetDefaults.localComputer, older, wrongTransport, newest],
            transport: .tailscale
        ))

        XCTAssertEqual(preferred.name, "gpu3-a4500")
        XCTAssertEqual(preferred.user, "metricspace")
        XCTAssertEqual(preferred.identityFilePath, "/Users/test/.ssh/id_ed25519_ctox")
    }

    func testConfirmingChangedKeyAtomicallyReplacesOnlyThatHostEntry() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("workjet-known-hosts-\(UUID().uuidString)")
        let file = directory.appendingPathComponent("known_hosts")
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let old = "[pi.example.test]:22 ssh-ed25519 \(Data(repeating: 0x11, count: 32).base64EncodedString())"
        let other = "other.example.test ssh-ed25519 \(Data(repeating: 0x22, count: 32).base64EncodedString())"
        let replacement = "pi.example.test ssh-ed25519 \(Data(repeating: 0x33, count: 32).base64EncodedString())"
        try Data("\(old)\n\(other)\n".utf8).write(to: file)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)

        try SecureKnownHostsStore().appendConfirmedHostKey(replacement, to: file)

        let result = String(decoding: try Data(contentsOf: file), as: UTF8.self)
        XCTAssertFalse(result.contains(old))
        XCTAssertTrue(result.contains(other))
        XCTAssertEqual(result.components(separatedBy: replacement).count - 1, 1)
        let permissions = try XCTUnwrap((try FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions]) as? NSNumber)
        XCTAssertEqual(permissions.intValue & 0o777, 0o600)
    }

    func testMalformedAndMultipleScanResultsAreRejectedWithoutWrite() async throws {
        let valid = "[pi.example.test]:2222 ssh-ed25519 \(keyBlob)"
        for output in [
            "[pi.example.test]:2222 ssh-rsa \(keyBlob)\n",
            "wrong.example.test ssh-ed25519 \(keyBlob)\n",
            valid + "\n" + valid + "\n"
        ] {
            let runner = Runner([CommandResult(exitCode: 0, standardOutput: Data(output.utf8))])
            let store = Store()
            let bootstrap = RemotePiBootstrap(runner: runner, knownHostsStore: store)
            do {
                _ = try await bootstrap.scanHostKey(for: computer)
                XCTFail("Ungültige Host-Key-Ausgabe wurde akzeptiert: \(output)")
            } catch {
                XCTAssertEqual(error as? RemotePiBootstrapError, .invalidHostKeyScan)
            }
            XCTAssertTrue(store.recordedWrites().isEmpty)
        }
    }

    @MainActor
    func testSuccessfulBootstrapStaysEditorLocalUntilExactDeployedComputerIsDurablySaved() async {
        var deployed = computer
        deployed.deploymentStatus = .installed
        deployed.deploymentDetail = "Remote-Computer ist eingerichtet."
        deployed.installedSidecarVersion = "test-version"
        deployed.installedContentHash = "test-hash"
        let service = BootstrapService(bootstrapResult: deployed)
        let model = WorkjetViewModel(configuration: WorkjetDefaults.configuration(), service: service, persistenceDelay: 60)
        let snapshot = model.configuration

        let result = await model.bootstrapRemoteComputer(computer)

        XCTAssertEqual(result, deployed)
        XCTAssertEqual(service.bootstrapInputs.count, 1)
        XCTAssertEqual(service.bootstrapInputs[0].deploymentStatus, .checking)
        XCTAssertEqual(service.bootstrapInputs[0].deploymentDetail, "Prüfung läuft …")
        XCTAssertEqual(model.configuration, snapshot, "Checking und Deployment-Ergebnis dürfen die gemeinsame Konfiguration nicht verändern.")
        XCTAssertTrue(service.saveAttempts.isEmpty)

        let persisted = await model.saveComputerDurably(result)

        XCTAssertEqual(persisted, .succeeded)
        XCTAssertEqual(model.computers.first(where: { $0.id == deployed.id }), deployed)
        XCTAssertEqual(service.successfulSaves.last?.computers.first(where: { $0.id == deployed.id }), deployed)
    }

    @MainActor
    func testInstalledBootstrapPersistenceFailureRollsBackExactlyAndSameDeploymentCanBeRetried() async {
        var configuration = WorkjetDefaults.configuration()
        let previousRemote = computer
        configuration.computers.append(previousRemote)
        configuration.selectedComputerID = previousRemote.id
        configuration.workers[0].computerID = previousRemote.id

        var deployed = previousRemote
        deployed.name = "Pi deployed"
        deployed.deploymentStatus = .installed
        deployed.deploymentDetail = "Remote-Computer ist eingerichtet."
        deployed.installedSidecarVersion = "test-version"
        deployed.installedContentHash = "test-hash"
        let service = BootstrapService(bootstrapResult: deployed)
        let model = WorkjetViewModel(configuration: configuration, service: service, persistenceDelay: 60)
        let snapshot = model.configuration

        let result = await model.bootstrapRemoteComputer(previousRemote)
        XCTAssertEqual(model.configuration, snapshot)
        service.failNextSave = true

        let failed = await model.saveComputerDurably(result)

        guard case let .failed(message) = failed else { return XCTFail("Expected persistence failure") }
        XCTAssertTrue(message.contains("vorherige Konfiguration wurde wiederhergestellt"))
        XCTAssertEqual(model.workers, snapshot.workers)
        XCTAssertEqual(model.computers, snapshot.computers)
        XCTAssertEqual(model.selectedComputerID, snapshot.selectedComputerID)
        XCTAssertEqual(model.configuration, snapshot)
        XCTAssertEqual(service.saveAttempts.count, 2)
        XCTAssertEqual(service.saveAttempts[0].computers.first(where: { $0.id == deployed.id }), deployed)
        XCTAssertEqual(service.saveAttempts[1], snapshot, "Der exakte vorherige Snapshot muss nach dem fehlgeschlagenen Installations-Save wieder gespeichert werden.")

        let retried = await model.saveComputerDurably(result)

        XCTAssertEqual(retried, .succeeded)
        XCTAssertEqual(service.bootstrapInputs.count, 1, "Ein reiner Persistenz-Retry darf die Remote-Bootstrap-Side-Effects nicht wiederholen.")
        XCTAssertEqual(model.computers.first(where: { $0.id == deployed.id }), deployed)
        XCTAssertEqual(service.successfulSaves.last, model.configuration)
    }

    @MainActor
    func testComputerBlockerTakesPriorityOverProviderRecovery() {
        var configuration = WorkjetDefaults.configuration()
        let blockedComputer = computer
        var worker = configuration.workers[0]
        worker.computerID = blockedComputer.id
        worker.providerRoute = nil
        configuration.computers.append(blockedComputer)
        configuration.workers = [worker]
        let model = WorkjetViewModel(configuration: configuration, service: NullWorkjetService())

        XCTAssertEqual(model.recoveryAction(for: worker), .computer(blockedComputer.id))

        var installed = blockedComputer
        installed.deploymentStatus = .installed
        model.upsertComputer(installed)
        guard case .provider = model.recoveryAction(for: worker) else {
            return XCTFail("Nach fertigem Computer muss die Anbieter-Recovery folgen.")
        }
    }
}
