import XCTest
@testable import WorkjetCore

@MainActor
final class ProviderIdentityDedupTests: XCTestCase {
    func testRepeatedKimiLoginReusesOneAccount() async {
        let service = IdentityService(identity: .init(label: "Kimi Code", externalID: "kimi-one.json"))
        let model = WorkjetViewModel(configuration: baseConfiguration(), service: service, persistenceDelay: 0)

        let first = await model.connectNewAccount(.kimi)
        let second = await model.connectNewAccount(.kimi)

        XCTAssertEqual(model.providerAccounts(for: .kimi).count, 1)
        XCTAssertEqual(first?.id, second?.id)
        XCTAssertEqual(model.providerAccounts(for: .kimi).first?.externalCredentialID, "kimi-one.json")
    }

    func testFirstLoginAutomaticallySharesProviderWithMatchingUnboundWorkers() async {
        let service = IdentityService(identity: .init(label: "Kimi Code", externalID: "kimi-one.json"))
        var configuration = baseConfiguration()
        configuration.workers = [
            Worker(
                name: "Reviewer",
                harness: .claudeCode,
                model: "Kimi K3",
                computerID: WorkjetDefaults.localID,
                invocation: WorkerInvocation(executable: "claude")
            ),
            Worker(
                name: "Unrelated",
                harness: .claudeCode,
                model: "gpt-5.6-sol",
                computerID: WorkjetDefaults.localID,
                invocation: WorkerInvocation(executable: "claude")
            )
        ]
        let model = WorkjetViewModel(configuration: configuration, service: service, persistenceDelay: 0)

        _ = await model.connectNewAccount(.kimi)

        XCTAssertEqual(model.workers[0].providerRoute, .pool(.kimi))
        XCTAssertNil(model.workers[1].providerRoute)
        XCTAssertEqual(model.operationalStatus(for: model.workers[0]).state, .unverified)
    }

    func testTwoWorkersCanShareOneProviderAccount() {
        let provider = kimiProvider(id: UUID(), externalID: "kimi-one.json")
        let first = worker(name: "Reviewer", providerID: provider.id)
        let second = worker(name: "Designer", providerID: provider.id)
        var configuration = baseConfiguration()
        configuration.providers = [provider]
        configuration.workers = [first, second]

        let normalized = WorkjetBootstrap.normalized(configuration)

        XCTAssertEqual(normalized.providers.count, 1)
        XCTAssertTrue(normalized.workers.allSatisfy { $0.providerRoute == .pool(.kimi) })
    }

    func testLegacyDuplicateIdentityIsCollapsedAndWorkerRoutesAreRewritten() {
        let canonicalID = UUID(uuidString: "00000000-0000-0000-0000-000000000101")!
        let duplicateID = UUID(uuidString: "00000000-0000-0000-0000-000000000102")!
        var canonical = kimiProvider(id: canonicalID, externalID: "kimi-one.json")
        canonical.name = "Primary"
        canonical.routingPriority = 0
        canonical.modelIDs = ["k3[1m]"]
        var duplicate = kimiProvider(id: duplicateID, externalID: "kimi-one.json")
        duplicate.name = "Duplicate"
        duplicate.routingPriority = 1
        duplicate.modelIDs = ["kimi-k2.7-code"]
        var configuration = baseConfiguration()
        configuration.providers = [duplicate, canonical]
        configuration.workers = [
            worker(name: "One", providerID: canonicalID),
            worker(name: "Two", providerID: duplicateID)
        ]

        let normalized = WorkjetBootstrap.normalized(configuration)

        XCTAssertEqual(normalized.providers.count, 1)
        XCTAssertEqual(normalized.providers[0].id, canonicalID)
        XCTAssertEqual(Set(normalized.providers[0].modelIDs), Set(["k3[1m]", "kimi-k2.7-code"]))
        XCTAssertTrue(normalized.workers.allSatisfy { $0.providerRoute == .pool(.kimi) })
    }

    func testDistinctExternalIdentitiesRemainSeparate() {
        var configuration = baseConfiguration()
        configuration.providers = [
            kimiProvider(id: UUID(), externalID: "kimi-personal.json"),
            kimiProvider(id: UUID(), externalID: "kimi-work.json")
        ]

        XCTAssertEqual(WorkjetBootstrap.normalized(configuration).providers.count, 2)
    }

    func testLegacySharedOAuthWarningMigratesToUnverifiedWithoutInventingCapacity() {
        var provider = kimiProvider(id: UUID(), externalID: "kimi-one.json")
        provider.status = .degraded
        provider.statusDetail = "Verbunden. Dieser Zugang kann von mehreren Workern verwendet werden."
        provider.capacity = .measured(used: 5, limit: 10, unit: "requests", rateLimited: false)
        var configuration = baseConfiguration()
        configuration.providers = [provider]

        let migrated = WorkjetBootstrap.normalized(configuration).providers[0]

        XCTAssertEqual(migrated.status, .unverified)
        XCTAssertTrue(migrated.statusDetail.contains("nicht separat prüfbar"))
        XCTAssertNil(migrated.capacity.fraction)
    }

    func testKimiOAuthRecordsWithSameSubjectCollapseAndUnboundWorkersUseSharedPool() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let auth = root.appendingPathComponent(".cli-proxy-api", isDirectory: true)
        try FileManager.default.createDirectory(at: auth, withIntermediateDirectories: true)
        let payload = try JSONSerialization.data(withJSONObject: ["sub": "same-kimi-user", "user_id": "same-kimi-user"])
            .base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
        for suffix in ["first", "second"] {
            let record: [String: Any] = [
                "type": "kimi",
                "scope": "kimi-code",
                "access_token": "header.\(payload).signature",
                "device_id": suffix,
                "disabled": false
            ]
            let data = try JSONSerialization.data(withJSONObject: record)
            try data.write(to: auth.appendingPathComponent("kimi-\(suffix).json"))
        }

        let bootstrap = WorkjetBootstrap.live(paths: WorkjetPaths(homeDirectory: root))
        let kimiAccounts = bootstrap.configuration.providers.filter { $0.modelProvider == .kimi }
        let kimiWorkers = bootstrap.configuration.workers.filter { ModelProvider.inferred(from: $0.model) == .kimi }

        XCTAssertEqual(kimiAccounts.count, 1)
        XCTAssertEqual(kimiWorkers.count, 2)
        XCTAssertTrue(kimiWorkers.allSatisfy { $0.providerRoute == .pool(.kimi) })
    }

    func testOpaqueTimeNamedKimiRecordsCollapseWithoutClaimingDistinctSubscriptions() throws {
        let root = try authenticationHome()
        defer { try? FileManager.default.removeItem(at: root) }
        let auth = root.appendingPathComponent(".cli-proxy-api", isDirectory: true)
        for timestamp in ["1785829326952", "1785829999999"] {
            try writeJSON([
                "type": "kimi",
                "scope": "kimi-code",
                "timestamp": timestamp,
                "expired": "2026-08-05T00:00:00Z",
                "access_token": "opaque-token-\(timestamp)",
                "refresh_token": "opaque-refresh-\(timestamp)",
            ], to: auth.appendingPathComponent("kimi-\(timestamp).json"))
        }

        let accounts = CLIProxyAccountAuthenticator.availableAccounts(for: .kimi, homeDirectory: root)

        XCTAssertEqual(accounts.count, 1)
        XCTAssertEqual(accounts[0].label, "Kimi Code")
        XCTAssertEqual(accounts[0].externalID, "kimi-1785829326952.json")
        XCTAssertEqual(accounts[0].sourceRecordIDs, ["kimi-1785829326952.json", "kimi-1785829999999.json"])
        XCTAssertFalse(String(describing: accounts).contains("opaque-token"))
        XCTAssertFalse(String(describing: accounts).contains("opaque-refresh"))
    }

    func testKimiRecordsWithDistinctStableAccountIDsRemainSeparate() throws {
        let root = try authenticationHome()
        defer { try? FileManager.default.removeItem(at: root) }
        let auth = root.appendingPathComponent(".cli-proxy-api", isDirectory: true)
        try writeJSON([
            "type": "kimi", "scope": "kimi-code", "account_id": "kimi-personal",
        ], to: auth.appendingPathComponent("kimi-100.json"))
        try writeJSON([
            "type": "kimi", "scope": "kimi-code", "account_id": "kimi-work",
        ], to: auth.appendingPathComponent("kimi-200.json"))

        let accounts = CLIProxyAccountAuthenticator.availableAccounts(for: .kimi, homeDirectory: root)

        XCTAssertEqual(accounts.count, 2)
        XCTAssertEqual(Set(accounts.map(\.externalID)).count, 2)
        XCTAssertTrue(accounts.allSatisfy { !$0.label.isEmpty })
    }

    func testProviderMetadataIdentityCollapsesSameAccountButKeepsDifferentAccount() throws {
        let root = try authenticationHome()
        defer { try? FileManager.default.removeItem(at: root) }
        let auth = root.appendingPathComponent(".cli-proxy-api", isDirectory: true)
        try writeJSON([
            "account_id": "account-one",
            "email": "Owner@Example.com",
            "access_token": "must-not-escape",
        ], to: auth.appendingPathComponent("codex-a.json"))
        try writeJSON([
            "account": ["account_id": "account-one"],
            "email": "owner@example.com",
            "refresh_token": "must-not-escape",
        ], to: auth.appendingPathComponent("codex-b.json"))
        try writeJSON([
            "account_id": "account-two",
            "email": "owner@example.com",
        ], to: auth.appendingPathComponent("codex-c.json"))

        let accounts = CLIProxyAccountAuthenticator.availableAccounts(for: .openAI, homeDirectory: root)

        XCTAssertEqual(accounts.count, 2)
        XCTAssertEqual(Set(accounts.map(\.externalID)).count, 2)
        XCTAssertTrue(accounts.allSatisfy { $0.label == "owner@example.com" })
        XCTAssertEqual(accounts.map(\.sourceRecordIDs).sorted { $0.count > $1.count }.first?.count, 2)
        XCTAssertFalse(String(describing: accounts).contains("must-not-escape"))
    }

    func testExplicitAccountIdentityMigratesLegacyEmailIdentityWithoutDuplicateProvider() throws {
        let root = try authenticationHome()
        defer { try? FileManager.default.removeItem(at: root) }
        let authFile = root.appendingPathComponent(".cli-proxy-api/xai-account.json")
        try writeJSON(["email": "owner@example.com"], to: authFile)
        let legacyID = try XCTUnwrap(
            CLIProxyAccountAuthenticator.availableAccounts(for: .xAI, homeDirectory: root).first?.externalID
        )

        try writeJSON(["email": "owner@example.com", "sub": "stable-xai-account"], to: authFile)
        let identity = try XCTUnwrap(
            CLIProxyAccountAuthenticator.availableAccounts(for: .xAI, homeDirectory: root).first
        )
        XCTAssertNotEqual(identity.externalID, legacyID)
        XCTAssertTrue(identity.migrationAliases.contains(legacyID))

        let canonicalProviderID = UUID(uuidString: "00000000-0000-0000-0000-000000000201")!
        let legacyProviderID = UUID(uuidString: "00000000-0000-0000-0000-000000000202")!
        func provider(id: UUID, externalID: String, priority: Int) -> Provider {
            Provider(
                id: id,
                name: "xAI \(priority + 1)",
                kind: .cliProxyAPI,
                endpoint: "http://127.0.0.1:8317",
                authentication: .bearerToken,
                modelProvider: .xAI,
                accountLabel: "owner@example.com",
                externalCredentialID: externalID,
                credentialReference: CLIProxyGatewayCredentialStore.reference,
                routingPriority: priority
            )
        }
        var configuration = baseConfiguration()
        configuration.providers = [
            provider(id: canonicalProviderID, externalID: identity.externalID, priority: 0),
            provider(id: legacyProviderID, externalID: legacyID, priority: 1),
        ]
        configuration.workers = [
            Worker(name: "One", harness: .claudeCode, model: "grok-4.6", computerID: WorkjetDefaults.localID, providerID: canonicalProviderID),
            Worker(name: "Two", harness: .claudeCode, model: "grok-4.6", computerID: WorkjetDefaults.localID, providerID: legacyProviderID),
        ]
        let paths = WorkjetPaths(homeDirectory: root)
        try JSONConfigurationStore(fileURL: paths.configurationFile).save(configuration)

        let migrated = WorkjetBootstrap.live(paths: paths).configuration
        let xAIProviders = migrated.providers.filter { $0.modelProvider == .xAI }

        XCTAssertEqual(xAIProviders.count, 1)
        XCTAssertEqual(xAIProviders[0].id, canonicalProviderID)
        XCTAssertTrue(migrated.workers.allSatisfy { $0.providerRoute == .pool(.xAI) })
    }

    func testSuccessfulLoginWithoutNewOrChangedAuthRecordRejectsOldIdentity() async throws {
        let root = try authenticationHome()
        defer { try? FileManager.default.removeItem(at: root) }
        let auth = root.appendingPathComponent(".cli-proxy-api", isDirectory: true)
        try writeJSON(["email": "old@example.com"], to: auth.appendingPathComponent("codex-old.json"))
        let executable = try executableStub(in: root)
        let authenticator = CLIProxyAccountAuthenticator(
            runner: LoginMutationRunner {},
            homeDirectory: root,
            executableCandidates: [executable.path]
        )

        do {
            _ = try await authenticator.authenticate(.openAI, credentialReference: CLIProxyGatewayCredentialStore.reference)
            XCTFail("An unchanged old auth record must never be accepted as the result of a new login.")
        } catch {
            XCTAssertEqual(error as? CLIProxyAccountError, .loginFailed)
        }
    }

    func testSuccessfulLoginReturnsOnlyTheRecordChangedDuringThatLogin() async throws {
        let root = try authenticationHome()
        defer { try? FileManager.default.removeItem(at: root) }
        let auth = root.appendingPathComponent(".cli-proxy-api", isDirectory: true)
        let old = auth.appendingPathComponent("codex-old.json")
        let selected = auth.appendingPathComponent("codex-selected.json")
        try writeJSON(["email": "old@example.com"], to: old)
        try writeJSON(["account_id": "selected-account", "email": "selected@example.com", "revision": 1], to: selected)
        let executable = try executableStub(in: root)
        let authenticator = CLIProxyAccountAuthenticator(
            runner: LoginMutationRunner {
                try Self.writeJSON(
                    ["account_id": "selected-account", "email": "selected@example.com", "revision": 2],
                    to: selected
                )
            },
            homeDirectory: root,
            executableCandidates: [executable.path]
        )

        let identity = try await authenticator.authenticate(.openAI, credentialReference: CLIProxyGatewayCredentialStore.reference)

        XCTAssertEqual(identity.label, "selected@example.com")
        XCTAssertEqual(identity.sourceRecordIDs, [selected.lastPathComponent])
        XCTAssertFalse(identity.externalID.contains("selected-account"))
    }

    func testRepeatedOpaqueKimiLoginReturnsExistingCanonicalIdentity() async throws {
        let root = try authenticationHome()
        defer { try? FileManager.default.removeItem(at: root) }
        let auth = root.appendingPathComponent(".cli-proxy-api", isDirectory: true)
        try writeJSON([
            "type": "kimi", "scope": "kimi-code", "access_token": "opaque-old",
        ], to: auth.appendingPathComponent("kimi-100.json"))
        let executable = try executableStub(in: root)
        let authenticator = CLIProxyAccountAuthenticator(
            runner: LoginMutationRunner {
                try Self.writeJSON([
                    "type": "kimi", "scope": "kimi-code", "access_token": "opaque-new",
                ], to: auth.appendingPathComponent("kimi-200.json"))
            },
            homeDirectory: root,
            executableCandidates: [executable.path]
        )

        let identity = try await authenticator.authenticate(.kimi, credentialReference: CLIProxyGatewayCredentialStore.reference)

        XCTAssertEqual(identity.label, "Kimi Code")
        XCTAssertEqual(identity.externalID, "kimi-100.json")
        XCTAssertEqual(identity.sourceRecordIDs, ["kimi-100.json", "kimi-200.json"])
    }

    func testReachableOAuthGatewayMakesWorkerReadyDespitePinningCaveat() async throws {
        let service = IdentityService(identity: .init(label: "Kimi Code", externalID: "kimi-one.json"))
        let model = WorkjetViewModel(configuration: baseConfiguration(), service: service, persistenceDelay: 0)
        let connectedAccount = await model.connectNewAccount(.kimi)
        let account = try XCTUnwrap(connectedAccount)
        var value = worker(name: "Reviewer", providerID: account.id)
        model.upsertWorker(value)
        value = try XCTUnwrap(model.workers.first(where: { $0.name == "Reviewer" }))

        let status = model.operationalStatus(for: value)

        XCTAssertEqual(status.state, .unverified)
        XCTAssertEqual(status.label, "Harness nicht geprüft")
        XCTAssertTrue(model.providers[0].statusDetail.contains("nicht separat prüfbar"))
    }

    private func baseConfiguration() -> WorkjetConfiguration {
        WorkjetConfiguration(
            workers: [],
            computers: [WorkjetDefaults.localComputer],
            providers: [],
            selectedComputerID: WorkjetDefaults.localID,
            skillRules: "Rules"
        )
    }

    private func kimiProvider(id: UUID, externalID: String) -> Provider {
        Provider(
            id: id,
            name: "Kimi",
            kind: .cliProxyAPI,
            endpoint: "http://127.0.0.1:8317",
            modelProvider: .kimi,
            accountLabel: "Kimi Code",
            externalCredentialID: externalID,
            credentialReference: CLIProxyGatewayCredentialStore.reference
        )
    }

    private func worker(name: String, providerID: UUID) -> Worker {
        Worker(
            name: name,
            harness: .claudeCode,
            model: "k3[1m]",
            computerID: WorkjetDefaults.localID,
            providerID: providerID,
            invocation: WorkerInvocation(executable: "claude")
        )
    }

    private func authenticationHome() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root.appendingPathComponent(".cli-proxy-api"), withIntermediateDirectories: true)
        let secretDirectory = root.appendingPathComponent(".config/secrets", isDirectory: true)
        try FileManager.default.createDirectory(at: secretDirectory, withIntermediateDirectories: true)
        let gatewayKey = secretDirectory.appendingPathComponent("sol-key")
        try Data("test-gateway-key".utf8).write(to: gatewayKey)
        XCTAssertEqual(chmod(gatewayKey.path, 0o600), 0)
        return root
    }

    private func executableStub(in root: URL) throws -> URL {
        let executable = root.appendingPathComponent("cliproxyapi")
        try Data("#!/bin/sh\nexit 0\n".utf8).write(to: executable)
        XCTAssertEqual(chmod(executable.path, 0o700), 0)
        return executable
    }

    private static func writeJSON(_ value: [String: Any], to url: URL) throws {
        try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]).write(to: url)
    }

    private func writeJSON(_ value: [String: Any], to url: URL) throws {
        try Self.writeJSON(value, to: url)
    }
}

private struct LoginMutationRunner: CommandRunning, @unchecked Sendable {
    let mutation: () throws -> Void

    init(_ mutation: @escaping () throws -> Void) {
        self.mutation = mutation
    }

    func run(_ command: CommandSpec) async throws -> CommandResult {
        try mutation()
        return CommandResult(exitCode: 0)
    }
}

private final class IdentityService: WorkjetService, @unchecked Sendable {
    let identity: CLIProxyAuthenticatedAccount
    init(identity: CLIProxyAuthenticatedAccount) { self.identity = identity }

    func save(_ configuration: WorkjetConfiguration, handwrittenRulesChanged: Bool) throws {}
    func runs(workers: [Worker]) -> [RunRecord] { [] }
    func stop(_ run: ActiveRun) throws {}
    func inspectCLIProxy(_ configuration: CLIProxyConfiguration) async -> CLIProxyStatus {
        CLIProxyStatus(endpoint: configuration.endpoint, state: .reachable, detail: "OK", capacity: .unavailable(reason: "unknown"))
    }
    func inspectProvider(_ provider: Provider) async -> ProviderProbeResult {
        ProviderProbeResult(status: .connected, detail: "Gateway erreichbar", modelIDs: ["k3[1m]"])
    }
    func authenticateCLIProxyAccount(_ provider: ModelProvider, credentialReference: String) async throws -> CLIProxyAuthenticatedAccount {
        identity
    }
    func storeCredential(_ secret: Data, reference: String) throws {}
}
