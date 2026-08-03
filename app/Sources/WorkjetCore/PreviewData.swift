import Foundation

public enum PreviewData {
    public static let localComputer = WorkjetDefaults.localComputer
    public static let devbox = Computer(id: UUID(uuidString: "00000000-0000-0000-0000-000000000002")!, name: "devbox", transport: .tailscale, host: "devbox.tailnet.ts.net", user: "mw", telemetryEnabled: true)
    public static let builder = Computer(id: UUID(uuidString: "00000000-0000-0000-0000-000000000003")!, name: "builder-2", transport: .ssh, host: "192.168.1.42", user: "workjet")
    public static var computers: [Computer] { [localComputer, devbox, builder] }
    public static var workers: [Worker] { WorkjetDefaults.configuration().workers }
    public static var providers: [Provider] {
        [Provider(name: "MiniMax Coding Plan", kind: .oauthSubscription, endpoint: "https://api.minimax.io/anthropic", status: .connected, capacity: .userConfigured(used: 87, limit: 100, unit: "%", rateLimited: true))]
    }
    public static func configuration() -> WorkjetConfiguration {
        var value = WorkjetDefaults.configuration()
        value.computers = computers
        value.providers = providers
        return value
    }
    @MainActor public static func makeViewModel(service: any WorkjetService = NullWorkjetService()) -> WorkjetViewModel {
        WorkjetViewModel(configuration: configuration(), service: service)
    }
}

public extension WorkjetViewModel {
    @MainActor static func preview() -> WorkjetViewModel { PreviewData.makeViewModel() }
}
