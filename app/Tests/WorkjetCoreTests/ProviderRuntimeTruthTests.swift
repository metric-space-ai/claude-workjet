import XCTest
@testable import WorkjetCore

@MainActor
final class ProviderRuntimeTruthTests: XCTestCase {
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
        XCTAssertTrue(prompt.contains("Automatischer Account-Fallback und konkretes OAuth-Pinning: nicht verfügbar"))
        XCTAssertFalse(prompt.contains("Anbieter/Zugangsroute: Nicht konfiguriert"))
    }

    func testProviderEditAndDeleteArePersistedAndWorkerRouteStaysExplicitlyBroken() async throws {
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
        service.credentials[account.credentialReference!] = Data("secret".utf8)
        let model = WorkjetViewModel(
            configuration: configuration(worker: worker, providers: [account]),
            service: service,
            persistenceDelay: 60
        )

        var edited = account
        edited.name = "Z.ai Arbeit"
        edited.routingPriority = 4
        model.updateProvider(edited)
        let editSaved = await model.flushPersistence()
        XCTAssertTrue(editSaved)
        XCTAssertEqual(service.saved.last?.providers.first?.name, "Z.ai Arbeit")
        XCTAssertEqual(service.saved.last?.providers.first?.routingPriority, 4)

        model.removeProvider(id: account.id)
        let deleteSaved = await model.flushPersistence()
        XCTAssertTrue(deleteSaved)
        XCTAssertTrue(service.saved.last?.providers.isEmpty == true)
        XCTAssertNil(service.credentials[account.credentialReference!])
        XCTAssertEqual(model.workers.first?.providerID, account.id)
        XCTAssertEqual(model.operationalStatus(for: model.workers[0]).label, "Anbieter fehlt")
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
        XCTAssertEqual(model.providers[0].status, .degraded, "OAuth gateway metadata must not claim a pinned account")
        XCTAssertEqual(model.providers[0].modelIDs, ["k3[1m]"])
        XCTAssertNil(model.providers[0].capacity.fraction)
        XCTAssertTrue(model.providers[0].capacity.reason?.contains("Account-Identität") == true)
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
        XCTAssertEqual(model.providers[0].status, .degraded)
        XCTAssertTrue(model.providers[0].statusDetail.contains("Account-Zuordnung"))
        XCTAssertNil(model.providers[0].capacity.fraction)
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

    func save(_ configuration: WorkjetConfiguration, handwrittenRulesChanged: Bool) throws {
        saved.append(configuration)
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
    func authenticateCLIProxyAccount(_ provider: ModelProvider, credentialReference: String) async throws {
        authenticatedProviders.append(provider)
        credentials[credentialReference] = Data("gateway".utf8)
    }
    func storeCredential(_ secret: Data, reference: String) throws { credentials[reference] = secret }
    func deleteCredential(reference: String) throws { credentials.removeValue(forKey: reference) }
    func hasCredential(reference: String) -> Bool { credentials[reference] != nil }
}
