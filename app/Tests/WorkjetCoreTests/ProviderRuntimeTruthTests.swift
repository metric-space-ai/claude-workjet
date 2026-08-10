import XCTest
@testable import WorkjetCore

@MainActor
final class ProviderRuntimeTruthTests: XCTestCase {
    func testOnlyRealWorkerProbeCanTurnProviderPoolGreen() async {
        let provider = Provider(
            name: "Z.ai",
            kind: .directAPI,
            endpoint: "https://api.z.ai/api/anthropic",
            authentication: .none,
            modelProvider: .zAI
        )
        let worker = Worker(
            name: "Prototype C",
            harness: .claudeCode,
            model: "glm-5.2",
            computerID: WorkjetDefaults.localID,
            providerPool: .zAI,
            invocation: WorkerInvocation(executable: "/usr/bin/true")
        )
        let service = ProviderRuntimeService()
        service.healthResults = [WorkjetCLIWorkerHealth(
            workerID: worker.id,
            workerName: worker.name,
            model: worker.model,
            computerName: "Local",
            providerRoute: "Z.ai",
            status: "ready",
            latencyMilliseconds: 42,
            runID: "health-1",
            responseTokenObserved: true,
            error: nil,
            message: nil
        )]
        let model = WorkjetViewModel(
            configuration: configuration(worker: worker, providers: [provider]),
            service: service,
            persistenceDelay: 60
        )

        XCTAssertEqual(model.providerPoolPresentation(for: .zAI).tone, .neutral)
        await model.probeAllWorkersNow()
        XCTAssertEqual(model.providerPoolPresentation(for: .zAI).tone, .connected)
        XCTAssertEqual(model.providerPoolPresentation(for: .zAI).state, "Nutzbar · 42 ms")
        XCTAssertEqual(model.workerHealth[worker.id]?.responseTokenObserved, true)
    }

    func testManagedPromptRendersDeterministicPoolAndUnavailableFallbackTruth() throws {
        let later = Provider(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000902")!,
            name: "Arbeit",
            kind: .cliProxyAPI,
            endpoint: "http://127.0.0.1:8317",
            modelProvider: .openAI,
            routingPriority: 2
        )
        let first = Provider(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000901")!,
            name: "Privat",
            kind: .cliProxyAPI,
            endpoint: "http://127.0.0.1:8317",
            modelProvider: .openAI,
            routingPriority: 0
        )
        let worker = Worker(
            name: "Completion Engine",
            harness: .claudeCode,
            model: "gpt-5.6-sol",
            computerID: WorkjetDefaults.localID,
            providerPool: .openAI,
            invocation: WorkerInvocation(executable: "/usr/bin/true")
        )
        let configuration = WorkjetConfiguration(
            workers: [worker],
            computers: [WorkjetDefaults.localComputer],
            providers: [later, first],
            selectedComputerID: WorkjetDefaults.localID,
            skillRules: "Rules"
        )

        let prompt = try XCTUnwrap(String(data: ManagedPrompt.workerBody(configuration: configuration), encoding: .utf8))
        let firstRange = try XCTUnwrap(prompt.range(of: "1. Privat"))
        let secondRange = try XCTUnwrap(prompt.range(of: "2. Arbeit"))
        XCTAssertLessThan(firstRange.lowerBound, secondRange.lowerBound)
        XCTAssertTrue(prompt.contains("stabile Konfigurationsansicht, nicht die Laufzeitreihenfolge"))
        XCTAssertTrue(prompt.contains("CLIProxy wählt und wechselt den Zugang nach seiner eigenen konfigurierten Routingstrategie"))
        XCTAssertTrue(prompt.contains("Workjet kann keinen einzelnen OAuth-Account pro Anfrage festlegen"))
        XCTAssertFalse(prompt.contains("Anbieter/Zugangsroute: Nicht konfiguriert"))
    }

    func testManagedPromptMatchesDirectPoolFallbackContract() throws {
        let first = Provider(name: "Primär", kind: .directAPI, endpoint: "https://primary.example.test/v1", authentication: .none, modelProvider: .zAI, routingPriority: 0)
        let second = Provider(name: "Reserve", kind: .directAPI, endpoint: "https://reserve.example.test/v1", authentication: .none, modelProvider: .zAI, routingPriority: 1)
        let worker = Worker(name: "Bulk", harness: .codexCLI, model: "glm-5.2", computerID: WorkjetDefaults.localID, providerPool: .zAI, invocation: WorkerInvocation(executable: "/usr/bin/true"))
        let prompt = try XCTUnwrap(String(data: ManagedPrompt.workerBody(configuration: configuration(worker: worker, providers: [second, first])), encoding: .utf8))

        XCTAssertTrue(prompt.contains("deterministische Reihenfolge der direkten Zugänge: 1. Primär"))
        XCTAssertTrue(prompt.contains("Workjet wechselt einen direkten Zugang nur nach eindeutig erkanntem Auth-, Quota- oder Rate-Limit-Fehler"))
        XCTAssertTrue(prompt.contains("Task-, Transport-, Timeout- und generische Serverfehler wechseln den Zugang nicht"))
        XCTAssertFalse(prompt.contains("Netzwerkfehlern"))
    }

    func testProviderDraftMutationsStayLocalUntilSuccessfulSaveAndDeleteKeepsWorkerRouteExplicitlyBroken() async throws {
        let account = Provider(
            name: "Z.ai alt",
            kind: .directAPI,
            endpoint: "https://api.z.ai/v1",
            modelProvider: .zAI
        )
        let worker = Worker(
            name: "Bulk",
            harness: .claudeCode,
            model: "glm-5.2",
            computerID: WorkjetDefaults.localID,
            providerID: account.id,
            invocation: WorkerInvocation(executable: "/usr/bin/true")
        )
        let service = ProviderRuntimeService()
        service.credentials[account.credentialReference!] = Data("old-secret".utf8)
        service.probes[account.id] = ProviderProbeResult(
            status: .connected,
            detail: "Geprüft und verbunden",
            modelIDs: ["glm-5.2", "glm-5.3"]
        )
        let model = WorkjetViewModel(
            configuration: configuration(worker: worker, providers: [account]),
            service: service,
            persistenceDelay: 60
        )

        var draft = account
        draft.name = "Z.ai Arbeit"
        draft.endpoint = "https://work.example.test/v1"
        draft.routingPriority = 4
        draft.authentication = .apiKeyHeader
        draft.modelIDs = ["draft-model"]
        draft.loginExecutable = "/usr/bin/legacy-login"
        draft.loginArguments = ["--profile", "work"]

        XCTAssertEqual(model.providers, [account], "Editing and canceling a local draft must not mutate the model.")
        XCTAssertTrue(service.saved.isEmpty)
        XCTAssertEqual(service.credentials[account.credentialReference!], Data("old-secret".utf8))

        let result = await model.saveAndTestProviderDurably(draft, secret: "new-secret")

        guard case let .saved(saved) = result else { return XCTFail("Expected successful durable provider save") }
        XCTAssertEqual(saved.name, "Z.ai Arbeit")
        XCTAssertEqual(saved.endpoint, "https://work.example.test/v1")
        XCTAssertEqual(saved.routingPriority, 4)
        XCTAssertEqual(saved.authentication, .apiKeyHeader)
        XCTAssertEqual(saved.modelIDs, ["glm-5.2", "glm-5.3"])
        XCTAssertEqual(saved.loginExecutable, "/usr/bin/legacy-login")
        XCTAssertEqual(saved.loginArguments, ["--profile", "work"])
        XCTAssertEqual(saved.status, .connected)
        XCTAssertEqual(service.saved.last?.providers.first, saved)
        XCTAssertEqual(service.credentials[saved.credentialReference!], Data("new-secret".utf8))
        XCTAssertNil(service.credentials[account.credentialReference!], "Der alte exklusive Schlüssel muss erst nach dem dauerhaften Umschalten bereinigt werden.")
        XCTAssertFalse(service.credentials.keys.contains { $0.hasPrefix("provider-edit-") })

        let deletion = await model.deleteProviderDurably(id: account.id)
        XCTAssertEqual(deletion, .deleted)
        XCTAssertTrue(service.saved.last?.providers.isEmpty == true)
        XCTAssertNil(service.credentials[saved.credentialReference!])
        XCTAssertEqual(model.workers.first?.providerID, account.id)
        XCTAssertEqual(model.operationalStatus(for: model.workers[0]).label, "Anbieter fehlt")
    }

    func testProviderSavePersistenceFailureRollsBackExactConfigurationAccessAndCredential() async {
        let reference = "transactional-provider-secret"
        let account = Provider(
            name: "Transactional API",
            kind: .directAPI,
            endpoint: "https://old.example.test/v1",
            authentication: .bearerToken,
            credentialReference: reference
        )
        let remote = Computer(name: "Selected Remote", transport: .tailscale, host: "selected-remote", user: "workjet")
        let worker = Worker(
            name: "Pinned Worker",
            harness: .claudeCode,
            model: "transactional-model",
            computerID: remote.id,
            providerID: account.id,
            invocation: WorkerInvocation(executable: "/usr/bin/true")
        )
        let initial = WorkjetConfiguration(
            workers: [worker],
            computers: [WorkjetDefaults.localComputer, remote],
            providers: [account],
            selectedComputerID: remote.id,
            skillRules: "Rules"
        )
        let service = ProviderRuntimeService()
        let oldSecret = Data("old-secret".utf8)
        service.credentials[reference] = oldSecret
        service.probes[account.id] = ProviderProbeResult(status: .connected, detail: "Probe succeeded")
        service.failNextSave = true
        let model = WorkjetViewModel(configuration: initial, service: service, persistenceDelay: 60)
        let providersBefore = model.providers
        let accessBefore = model.providerAccessStored
        let workersBefore = model.workers
        let computersBefore = model.computers
        let selectionBefore = model.selectedComputerID
        var draft = account
        draft.name = "Must Roll Back"
        draft.endpoint = "https://new.example.test/v1"
        draft.routingPriority = 9
        draft.loginExecutable = "/tmp/new-login"

        let result = await model.saveAndTestProviderDurably(draft, secret: "new-secret")

        guard case let .failed(message) = result else { return XCTFail("Expected durable provider save failure") }
        XCTAssertTrue(message.contains("vorherige Konfiguration"))
        XCTAssertEqual(model.providers, providersBefore)
        XCTAssertEqual(model.providerAccessStored, accessBefore)
        XCTAssertEqual(model.workers, workersBefore)
        XCTAssertEqual(model.computers, computersBefore)
        XCTAssertEqual(model.selectedComputerID, selectionBefore)
        XCTAssertEqual(service.credentials, [reference: oldSecret])
        XCTAssertEqual(service.saved.last?.providers, providersBefore)
        XCTAssertFalse(service.credentials.keys.contains { $0.hasPrefix("provider-edit-") })
    }

    func testProviderProbeFailureIsTypedAndPersistedOnlyAfterConfigurationAndCredentialCommit() async {
        let account = Provider(
            name: "Offline API",
            kind: .directAPI,
            endpoint: "https://old.example.test/v1",
            authentication: .bearerToken,
            credentialReference: "offline-provider-secret"
        )
        let service = ProviderRuntimeService()
        service.probes[account.id] = ProviderProbeResult(status: .offline, detail: "401: API-Key abgelehnt")
        let model = WorkjetViewModel(
            configuration: configuration(worker: nil, providers: [account]),
            service: service,
            persistenceDelay: 60
        )
        var draft = account
        draft.endpoint = "https://new.example.test/v1"

        let result = await model.saveAndTestProviderDurably(draft, secret: "intended-secret")

        guard case let .savedWithProbeFailure(saved, message) = result else {
            return XCTFail("Expected a typed, durably committed probe failure")
        }
        XCTAssertEqual(message, "401: API-Key abgelehnt")
        XCTAssertEqual(saved.status, .offline)
        XCTAssertEqual(saved.endpoint, "https://new.example.test/v1")
        XCTAssertEqual(model.providers, [saved])
        XCTAssertEqual(service.saved.last?.providers, [saved])
        XCTAssertEqual(service.credentials[saved.credentialReference!], Data("intended-secret".utf8))
        XCTAssertTrue(model.providerAccessStored.contains(saved.id))
    }

    func testSwitchingToNoAuthenticationIgnoresTypedSecretAndDeletesExclusiveOldCredentialOnlyAfterCommit() async {
        let reference = "exclusive-auth-secret"
        let account = Provider(
            name: "Optional Auth API",
            kind: .directAPI,
            endpoint: "https://example.test/v1",
            authentication: .bearerToken,
            credentialReference: reference
        )
        let oldSecret = Data("old-secret".utf8)
        let service = ProviderRuntimeService()
        service.credentials[reference] = oldSecret
        service.probes[account.id] = ProviderProbeResult(status: .connected, detail: "Anonymous endpoint connected")
        service.failNextSave = true
        let model = WorkjetViewModel(
            configuration: configuration(worker: nil, providers: [account]),
            service: service,
            persistenceDelay: 60
        )
        var draft = account
        draft.authentication = .none

        let failed = await model.saveAndTestProviderDurably(draft, secret: "must-never-be-stored")

        guard case .failed = failed else { return XCTFail("Expected the first durable save to fail") }
        XCTAssertEqual(model.providers, [account])
        XCTAssertEqual(service.credentials, [reference: oldSecret])
        XCTAssertFalse(service.events.contains("delete:\(reference)"))

        let retried = await model.saveAndTestProviderDurably(draft, secret: "must-never-be-stored")

        guard case let .saved(saved) = retried else { return XCTFail("Expected no-auth retry to save") }
        XCTAssertEqual(saved.authentication, .none)
        XCTAssertNil(saved.credentialReference)
        XCTAssertFalse(model.providerAccessStored.contains(saved.id))
        XCTAssertTrue(service.credentials.isEmpty)
        XCTAssertFalse(service.credentials.keys.contains { $0.hasPrefix("provider-") })
        let finalSave = try? XCTUnwrap(service.events.lastIndex(where: { $0 == "save:1" }))
        let deletion = try? XCTUnwrap(service.events.lastIndex(of: "delete:\(reference)"))
        XCTAssertNotNil(finalSave)
        XCTAssertNotNil(deletion)
        if let finalSave, let deletion { XCTAssertLessThan(finalSave, deletion) }
    }

    func testReplacingSharedOrCLIProxyCredentialDetachesProviderWithoutOverwritingOwners() async {
        let sharedReference = "shared-provider-secret"
        let edited = Provider(name: "Edited", kind: .directAPI, endpoint: "https://edited.example.test", credentialReference: sharedReference)
        let shared = Provider(name: "Shared", kind: .directAPI, endpoint: "https://shared.example.test", credentialReference: sharedReference)
        let cliOwned = Provider(
            name: "CLI-owned direct",
            kind: .directAPI,
            endpoint: "https://cli-owned.example.test",
            credentialReference: CLIProxyGatewayCredentialStore.reference
        )
        let service = ProviderRuntimeService()
        service.credentials[sharedReference] = Data("shared-secret".utf8)
        service.credentials[CLIProxyGatewayCredentialStore.reference] = Data("cli-secret".utf8)
        service.probes[edited.id] = ProviderProbeResult(status: .connected, detail: "Edited connected")
        service.probes[cliOwned.id] = ProviderProbeResult(status: .connected, detail: "CLI-owned connected")
        let model = WorkjetViewModel(
            configuration: configuration(worker: nil, providers: [edited, shared, cliOwned]),
            service: service,
            persistenceDelay: 60
        )

        let sharedResult = await model.saveAndTestProviderDurably(edited, secret: "edited-secret")
        let cliResult = await model.saveAndTestProviderDurably(cliOwned, secret: "detached-secret")

        guard case let .saved(savedShared) = sharedResult,
              case let .saved(savedCLI) = cliResult else {
            return XCTFail("Expected both protected-reference edits to save")
        }
        XCTAssertNotEqual(savedShared.credentialReference, sharedReference)
        XCTAssertNotEqual(savedCLI.credentialReference, CLIProxyGatewayCredentialStore.reference)
        XCTAssertEqual(service.credentials[sharedReference], Data("shared-secret".utf8))
        XCTAssertEqual(service.credentials[CLIProxyGatewayCredentialStore.reference], Data("cli-secret".utf8))
        XCTAssertEqual(service.credentials[savedShared.credentialReference!], Data("edited-secret".utf8))
        XCTAssertEqual(service.credentials[savedCLI.credentialReference!], Data("detached-secret".utf8))
    }

    func testDurableProviderDeleteRollsBackExactStateAndSecretThenRetryCleansUpAfterSave() async {
        let reference = "exclusive-direct-secret"
        let account = Provider(
            name: "Transactional API",
            kind: .directAPI,
            endpoint: "https://example.test/v1",
            authentication: .bearerToken,
            credentialReference: reference
        )
        let remote = Computer(name: "Selected Remote", transport: .tailscale, host: "selected-remote", user: "workjet")
        let worker = Worker(
            name: "Pinned Worker",
            harness: .claudeCode,
            model: "transactional-model",
            computerID: remote.id,
            providerID: account.id,
            invocation: WorkerInvocation(executable: "/usr/bin/true")
        )
        let configuration = WorkjetConfiguration(
            workers: [worker],
            computers: [WorkjetDefaults.localComputer, remote],
            providers: [account],
            selectedComputerID: remote.id,
            skillRules: "Rules"
        )
        let service = ProviderRuntimeService()
        let secret = Data("exact-secret".utf8)
        service.credentials[reference] = secret
        service.failNextSave = true
        let model = WorkjetViewModel(configuration: configuration, service: service, persistenceDelay: 60)
        let providersBefore = model.providers
        let accessBefore = model.providerAccessStored
        let workersBefore = model.workers
        let selectionBefore = model.selectedComputerID

        let failed = await model.deleteProviderDurably(id: account.id)

        guard case let .failed(message) = failed else { return XCTFail("Expected provider persistence failure") }
        XCTAssertTrue(message.contains("versuche es erneut"))
        XCTAssertEqual(model.providers, providersBefore)
        XCTAssertEqual(model.providerAccessStored, accessBefore)
        XCTAssertEqual(model.workers, workersBefore)
        XCTAssertEqual(model.selectedComputerID, selectionBefore)
        XCTAssertEqual(service.credentials[reference], secret)
        XCTAssertEqual(service.saved.last?.providers, providersBefore)
        XCTAssertFalse(service.events.contains("delete:\(reference)"))

        let retried = await model.deleteProviderDurably(id: account.id)

        XCTAssertEqual(retried, .deleted)
        XCTAssertTrue(model.providers.isEmpty)
        XCTAssertFalse(model.providerAccessStored.contains(account.id))
        XCTAssertEqual(model.workers, workersBefore, "Provider IDs on workers intentionally survive deletion.")
        XCTAssertEqual(model.selectedComputerID, selectionBefore)
        XCTAssertNil(service.credentials[reference])
        XCTAssertEqual(Array(service.events.suffix(2)), ["save:0", "delete:\(reference)"])
    }

    func testDisconnectNeverDeletesCLIProxyOwnedLegacyOrStillSharedCredentials() async {
        let gateway = Provider(
            name: "Kimi",
            kind: .cliProxyAPI,
            endpoint: "http://127.0.0.1:8317",
            modelProvider: .kimi,
            credentialReference: CLIProxyGatewayCredentialStore.reference
        )
        let sharedReference = "shared-direct-secret"
        let legacyReference = "legacy-cliproxy-secret"
        let first = Provider(name: "API 1", kind: .directAPI, endpoint: "https://example.test/v1", credentialReference: sharedReference)
        let second = Provider(name: "API 2", kind: .directAPI, endpoint: "https://example.test/v1", credentialReference: sharedReference)
        let legacy = Provider(name: "Legacy", kind: .directAPI, endpoint: "https://legacy.example.test/v1", credentialReference: legacyReference)
        let service = ProviderRuntimeService()
        service.credentials[CLIProxyGatewayCredentialStore.reference] = Data("gateway".utf8)
        service.credentials[sharedReference] = Data("direct".utf8)
        service.credentials[legacyReference] = Data("legacy".utf8)
        let model = WorkjetViewModel(
            configuration: configuration(worker: nil, providers: [gateway, first, second, legacy]),
            service: service,
            persistenceDelay: 60
        )
        model.cliProxyConfiguration.inferenceCredentialReference = legacyReference

        let gatewayDeletion = await model.deleteProviderDurably(id: gateway.id)
        let sharedDeletion = await model.deleteProviderDurably(id: first.id)
        let legacyDeletion = await model.deleteProviderDurably(id: legacy.id)

        XCTAssertEqual(gatewayDeletion, .deleted)
        XCTAssertEqual(sharedDeletion, .deleted)
        XCTAssertEqual(legacyDeletion, .deleted)
        XCTAssertNotNil(service.credentials[CLIProxyGatewayCredentialStore.reference])
        XCTAssertNotNil(service.credentials[sharedReference])
        XCTAssertNotNil(service.credentials[legacyReference])
        XCTAssertEqual(model.providers.map(\.id), [second.id])
    }

    func testCredentialCleanupFailureWarnsWithoutRestoringPersistedProvider() async {
        let reference = "cleanup-failure-secret"
        let account = Provider(
            name: "Cleanup Failure API",
            kind: .directAPI,
            endpoint: "https://example.test/v1",
            credentialReference: reference
        )
        let service = ProviderRuntimeService()
        service.credentials[reference] = Data("keep-after-failure".utf8)
        service.deleteCredentialError = LocalStateError.io("Keychain cleanup failed")
        let model = WorkjetViewModel(
            configuration: configuration(worker: nil, providers: [account]),
            service: service,
            persistenceDelay: 60
        )

        let result = await model.deleteProviderDurably(id: account.id)

        guard case let .deletedWithWarning(warning) = result else { return XCTFail("Expected cleanup warning") }
        XCTAssertTrue(warning.contains("wurde gelöscht"))
        XCTAssertTrue(warning.contains("~/.config/workjet/credentials/"))
        XCTAssertTrue(model.providers.isEmpty)
        XCTAssertFalse(model.providerAccessStored.contains(account.id))
        XCTAssertTrue(service.saved.last?.providers.isEmpty == true)
        XCTAssertNotNil(service.credentials[reference])
        XCTAssertEqual(Array(service.events.suffix(2)), ["save:0", "delete:\(reference)"])
        XCTAssertTrue(model.statusMessages.contains(warning))
    }

    func testRefreshUsesRealProbeAndNeverTurnsGlobalOrStaleCapacityIntoAccountCapacity() async {
        var measured = Provider(
            name: "Kimi Subscription",
            kind: .cliProxyAPI,
            endpoint: "http://127.0.0.1:8317",
            modelProvider: .kimi,
            capacity: .measured(used: 10, limit: 100, unit: "requests", rateLimited: false)
        )
        measured.status = .connected
        let service = ProviderRuntimeService()
        service.probes[measured.id] = ProviderProbeResult(status: .connected, detail: "2 Modelle", modelIDs: ["k3[1m]"])
        let model = WorkjetViewModel(
            configuration: configuration(worker: nil, providers: [measured]),
            service: service,
            persistenceDelay: 60
        )

        await model.refreshProvidersNow()

        XCTAssertEqual(service.inspectedIDs, [measured.id])
        XCTAssertEqual(model.providers[0].status, .unverified)
        XCTAssertEqual(model.providers[0].modelIDs, ["k3[1m]"])
        XCTAssertNil(model.providers[0].capacity.fraction)
        XCTAssertEqual(model.providers[0].capacity.reason, "Für diesen Zugang sind keine Nutzungsdaten verfügbar.")
    }

    func testBackgroundRefreshNeverReadsOrProbesAuthenticatedDirectProvider() async {
        let direct = Provider(
            name: "MiniMax API",
            kind: .directAPI,
            endpoint: "https://api.minimax.io/v1",
            authentication: .bearerToken,
            modelProvider: .miniMax,
            credentialReference: "provider-secret"
        )
        let service = ProviderRuntimeService()
        let model = WorkjetViewModel(
            configuration: configuration(worker: nil, providers: [direct]),
            service: service,
            persistenceDelay: 60
        )

        await model.refreshProvidersNow()
        model.refreshProviderCredentialStatus()

        XCTAssertTrue(service.inspectedIDs.isEmpty)
        XCTAssertEqual(service.credentialChecks, 0)
        XCTAssertTrue(model.providerAccessStored.contains(direct.id))
    }

    func testStartingAppPollingDoesNotTouchAuthenticatedDirectProviderCredentials() async throws {
        let direct = Provider(
            name: "Z.ai API",
            kind: .directAPI,
            endpoint: "https://api.z.ai/v1",
            authentication: .bearerToken,
            modelProvider: .zAI,
            credentialReference: "provider-secret"
        )
        let service = ProviderRuntimeService()
        let model = WorkjetViewModel(
            configuration: configuration(worker: nil, providers: [direct]),
            service: service,
            persistenceDelay: 60
        )

        model.startPolling()
        try await Task.sleep(for: .milliseconds(100))
        model.stopPolling()

        XCTAssertTrue(service.inspectedIDs.isEmpty)
        XCTAssertEqual(service.credentialChecks, 0)
    }

    func testReauthenticationIsExposedButDoesNotClaimConcreteOAuthPinning() async {
        let account = Provider(
            name: "OpenAI Privat",
            kind: .cliProxyAPI,
            endpoint: "http://127.0.0.1:8317",
            modelProvider: .openAI
        )
        let service = ProviderRuntimeService()
        service.probes[account.id] = ProviderProbeResult(status: .connected, detail: "Gateway verbunden", modelIDs: ["gpt-5.6-sol"])
        let model = WorkjetViewModel(
            configuration: configuration(worker: nil, providers: [account]),
            service: service,
            persistenceDelay: 60
        )

        await model.reauthenticateProvider(id: account.id)

        XCTAssertEqual(service.authenticatedProviders, [.openAI])
        XCTAssertEqual(model.providers[0].status, .unverified)
        XCTAssertTrue(model.providers[0].statusDetail.contains("nicht separat prüfbar"))
        XCTAssertNil(model.providers[0].capacity.fraction)
    }

    func testSuccessfulReauthenticationImmediatelyRefreshesAffectedWorkerEvidence() async {
        let account = Provider(
            name: "xAI",
            kind: .cliProxyAPI,
            endpoint: "http://127.0.0.1:8317",
            modelProvider: .xAI
        )
        let worker = Worker(
            name: "Remote prototype",
            harness: .claudeCode,
            model: "grok-4.5",
            computerID: WorkjetDefaults.localID,
            providerPool: .xAI,
            invocation: WorkerInvocation(executable: "/usr/bin/true")
        )
        let service = ProviderRuntimeService()
        service.probes[account.id] = ProviderProbeResult(status: .connected, detail: "Gateway verbunden")
        service.healthResults = [WorkjetCLIWorkerHealth(
            workerID: worker.id,
            workerName: worker.name,
            model: worker.model,
            computerName: "Local",
            providerRoute: "xAI Gateway-Pool",
            status: "ready",
            latencyMilliseconds: 37,
            runID: "health-after-login",
            responseTokenObserved: true,
            error: nil,
            message: nil
        )]
        let model = WorkjetViewModel(
            configuration: configuration(worker: worker, providers: [account]),
            service: service,
            persistenceDelay: 60
        )

        await model.reauthenticateProvider(id: account.id)

        XCTAssertEqual(model.workerHealth[worker.id]?.status, "ready")
        XCTAssertNil(model.workerHealthProbeError)
    }

    private func configuration(worker: Worker?, providers: [Provider]) -> WorkjetConfiguration {
        WorkjetConfiguration(
            workers: worker.map { [$0] } ?? [],
            computers: [WorkjetDefaults.localComputer],
            providers: providers,
            selectedComputerID: WorkjetDefaults.localID,
            skillRules: "Rules"
        )
    }
}

private final class ProviderRuntimeService: WorkjetService, @unchecked Sendable {
    var saved: [WorkjetConfiguration] = []
    var probes: [UUID: ProviderProbeResult] = [:]
    var inspectedIDs: [UUID] = []
    var credentials: [String: Data] = [:]
    var authenticatedProviders: [ModelProvider] = []
    var credentialChecks = 0
    var failNextSave = false
    var deleteCredentialError: Error?
    var events: [String] = []
    var healthResults: [WorkjetCLIWorkerHealth] = []

    func save(_ configuration: WorkjetConfiguration, handwrittenRulesChanged: Bool) throws {
        if failNextSave {
            failNextSave = false
            throw LocalStateError.io("Provider persistence failed")
        }
        saved.append(configuration)
        events.append("save:\(configuration.providers.count)")
    }
    func runs(workers: [Worker]) -> [RunRecord] { [] }
    func stop(_ run: ActiveRun) throws {}
    func inspectCLIProxy(_ configuration: CLIProxyConfiguration) async -> CLIProxyStatus {
        CLIProxyStatus(endpoint: configuration.endpoint, state: .unverified, detail: "not used", capacity: .unavailable(reason: "not used"))
    }
    func inspectProvider(_ provider: Provider) async -> ProviderProbeResult {
        inspectedIDs.append(provider.id)
        return probes[provider.id] ?? ProviderProbeResult(status: .unverified, detail: "Keine Probe")
    }
    func probeConfiguredWorkers(timeoutSeconds: Int) async throws -> [WorkjetCLIWorkerHealth] {
        healthResults
    }
    func authenticateCLIProxyAccount(_ provider: ModelProvider, credentialReference: String) async throws -> CLIProxyAuthenticatedAccount {
        authenticatedProviders.append(provider)
        credentials[credentialReference] = Data("gateway".utf8)
        return CLIProxyAuthenticatedAccount(label: "account@example.com", externalID: "test-auth.json")
    }
    func storeCredential(_ secret: Data, reference: String) throws { credentials[reference] = secret }
    func deleteCredential(reference: String) throws {
        events.append("delete:\(reference)")
        if let deleteCredentialError { throw deleteCredentialError }
        credentials.removeValue(forKey: reference)
    }
    func hasCredential(reference: String) -> Bool {
        credentialChecks += 1
        return credentials[reference] != nil
    }
}
