import Foundation

public protocol WorkjetService: AnyObject, Sendable {
    func save(_ configuration: WorkjetConfiguration, handwrittenRulesChanged: Bool) throws
    func runs(workers: [Worker]) -> [RunRecord]
    func stop(_ run: ActiveRun) throws
    func inspectCLIProxy(_ configuration: CLIProxyConfiguration) async -> CLIProxyStatus
    func inspectProvider(_ provider: Provider) async -> ProviderProbeResult
    func discoverTailscaleDevices() async throws -> [TailscaleDevice]
    func bootstrapRemotePi(_ computer: Computer) async -> Computer
    func storeCredential(_ secret: Data, reference: String) throws
    func deleteCredential(reference: String) throws
    func hasCredential(reference: String) -> Bool
}

public extension WorkjetService {
    func inspectProvider(_ provider: Provider) async -> ProviderProbeResult {
        ProviderProbeResult(status: .unverified, detail: "Dieser Dienst prüft keine Anbieter.")
    }
    func discoverTailscaleDevices() async throws -> [TailscaleDevice] { throw TailscaleDeviceError.unavailable }
    func deleteCredential(reference: String) throws {}
    func hasCredential(reference: String) -> Bool { false }
    func bootstrapRemotePi(_ computer: Computer) async -> Computer {
        var value = computer
        value.deploymentStatus = .failed
        value.deploymentDetail = "Dieser Dienst unterstützt keine Remote-Pi-Einrichtung."
        return value
    }
}

public final class NullWorkjetService: WorkjetService, @unchecked Sendable {
    public init() {}
    public func save(_ configuration: WorkjetConfiguration, handwrittenRulesChanged: Bool) throws {}
    public func runs(workers: [Worker]) -> [RunRecord] { [] }
    public func stop(_ run: ActiveRun) throws {}
    public func inspectCLIProxy(_ configuration: CLIProxyConfiguration) async -> CLIProxyStatus {
        CLIProxyStatus(endpoint: configuration.endpoint, state: .unverified, detail: "Vorschau prüft keine lokalen Dienste.", capacity: .unavailable(reason: "CLIProxy wurde in der Vorschau nicht geprüft."))
    }
    public func bootstrapRemotePi(_ computer: Computer) async -> Computer {
        var value = computer
        value.deploymentStatus = .failed
        value.deploymentDetail = "Vorschau führt keine Remote-Befehle aus."
        return value
    }
    public func storeCredential(_ secret: Data, reference: String) throws {}
}

public final class LocalWorkjetService: WorkjetService, @unchecked Sendable {
    private let configurationStore: any ConfigurationStoring
    private let promptStore: any PromptSynchronizing
    private let telemetryStore: any RunTelemetryReading
    private let cliProxyInspector: CLIProxyInspector
    private let providerInspector: ProviderInspector
    private let credentialStore: any CredentialStoring
    private let tailscaleDiscovery: TailscaleDeviceDiscovery
    private let remoteBootstrap: RemotePiBootstrap
    private let persistenceBlock: Error?

    public init(configurationStore: any ConfigurationStoring, promptStore: any PromptSynchronizing, telemetryStore: any RunTelemetryReading, cliProxyInspector: CLIProxyInspector, providerInspector: ProviderInspector? = nil, credentialStore: any CredentialStoring, tailscaleDiscovery: TailscaleDeviceDiscovery = TailscaleDeviceDiscovery(), remoteBootstrap: RemotePiBootstrap = RemotePiBootstrap(), persistenceBlock: Error? = nil) {
        self.configurationStore = configurationStore
        self.promptStore = promptStore
        self.telemetryStore = telemetryStore
        self.cliProxyInspector = cliProxyInspector
        self.providerInspector = providerInspector ?? ProviderInspector(credentials: credentialStore)
        self.credentialStore = credentialStore
        self.tailscaleDiscovery = tailscaleDiscovery
        self.remoteBootstrap = remoteBootstrap
        self.persistenceBlock = persistenceBlock
    }

    public func save(_ configuration: WorkjetConfiguration, handwrittenRulesChanged: Bool) throws {
        if let persistenceBlock { throw persistenceBlock }
        try configurationStore.save(configuration)
        try promptStore.synchronize(configuration, handwrittenChanged: handwrittenRulesChanged)
    }

    public func runs(workers: [Worker]) -> [RunRecord] { telemetryStore.scan(workers: workers) }
    public func stop(_ run: ActiveRun) throws { try telemetryStore.stop(run) }
    public func inspectCLIProxy(_ configuration: CLIProxyConfiguration) async -> CLIProxyStatus { await cliProxyInspector.inspect(configuration) }
    public func inspectProvider(_ provider: Provider) async -> ProviderProbeResult { await providerInspector.inspect(provider) }
    public func discoverTailscaleDevices() async throws -> [TailscaleDevice] { try await tailscaleDiscovery.discover() }
    public func bootstrapRemotePi(_ computer: Computer) async -> Computer { await remoteBootstrap.deploy(computer) }
    public func storeCredential(_ secret: Data, reference: String) throws { try credentialStore.write(secret, reference: reference) }
    public func deleteCredential(reference: String) throws { try credentialStore.delete(reference: reference) }
    public func hasCredential(reference: String) -> Bool { (try? credentialStore.read(reference: reference)) != nil }
}

public struct WorkjetBootstrap {
    public var configuration: WorkjetConfiguration
    public var service: any WorkjetService
    public var messages: [String]

    public static func live(paths: WorkjetPaths = .live) -> WorkjetBootstrap {
        let configStore = JSONConfigurationStore(fileURL: paths.configurationFile)
        let promptStore = ManagedPromptStore(fileURL: paths.promptFile)
        let credentials = KeychainCredentialStore()
        var messages: [String] = []
        var block: Error?
        var configuration: WorkjetConfiguration
        do {
            if let loaded = try configStore.load() { configuration = normalized(loaded) }
            else { configuration = WorkjetDefaults.configuration() }
        } catch {
            configuration = WorkjetDefaults.configuration()
            block = error
            messages.append(error.localizedDescription)
        }
        do {
            if let handwritten = try promptStore.loadHandwrittenRules(), !handwritten.isEmpty { configuration.skillRules = handwritten }
        } catch { messages.append(error.localizedDescription) }
        let service = LocalWorkjetService(configurationStore: configStore, promptStore: promptStore, telemetryStore: RunTelemetryStore(paths: paths), cliProxyInspector: CLIProxyInspector(credentials: credentials), credentialStore: credentials, persistenceBlock: block)
        if block == nil {
            do { try service.save(configuration, handwrittenRulesChanged: false) }
            catch { messages.append(error.localizedDescription) }
        }
        return WorkjetBootstrap(configuration: configuration, service: service, messages: messages)
    }

    public static func normalized(_ configuration: WorkjetConfiguration) -> WorkjetConfiguration {
        var value = configuration
        // Workjet is deliberately skill-only. Older config files may still
        // contain the removed, never-wired global UI option.
        value.skillActivation = .skillOnly
        value.injectWorkerDeclarations = true
        value.providerSlots = min(max(value.providerSlots, 1), 3)
        value.probeTimeoutSeconds = min(max(value.probeTimeoutSeconds, 5), 600)
        value.turnTimeoutSeconds = min(max(value.turnTimeoutSeconds, 60), 10_800)
        let legacyCLIProxy = value.cliProxy
        let hasLegacyCLIProxy = legacyCLIProxy.inferenceCredentialReference != nil
            || legacyCLIProxy.managementCredentialReference != nil
            || legacyCLIProxy.endpoint != CLIProxyConfiguration().endpoint
        if hasLegacyCLIProxy, !value.providers.contains(where: { $0.kind == .cliProxyAPI }) {
            let id = UUID(uuidString: "00000000-0000-0000-0000-00000000c1a0")!
            value.providers.append(Provider(
                id: id,
                name: "CLIProxyAPI",
                kind: .cliProxyAPI,
                endpoint: legacyCLIProxy.endpoint,
                credentialReference: legacyCLIProxy.inferenceCredentialReference
            ))
        }
        if hasLegacyCLIProxy { value.cliProxy = CLIProxyConfiguration() }
        let local: Computer
        if let existing = value.computers.first(where: \.isLocal) { local = existing }
        else { local = WorkjetDefaults.localComputer; value.computers.insert(local, at: 0) }
        if !value.computers.contains(where: { $0.id == value.selectedComputerID }) { value.selectedComputerID = local.id }
        for index in value.computers.indices {
            value.computers[index].pinnedSidecarVersion = PiSidecarRuntime.version
            if !value.computers[index].isLocal,
               value.computers[index].sandboxEnabled,
               value.computers[index].deploymentStatus == .installed,
               value.computers[index].bubblewrapExecutablePath?.hasPrefix("/") != true {
                value.computers[index].deploymentStatus = .notConfigured
                value.computers[index].deploymentDetail = "Die aktivierte Minimal-Sandbox hat noch kein verifiziertes Bubblewrap-Executable; erneut prüfen und einrichten."
                value.computers[index].installedContentHash = nil
                value.computers[index].installedSidecarVersion = nil
            }
        }
        return value
    }
}
