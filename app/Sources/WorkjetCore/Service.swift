import Foundation

/// Seam for all side effects (persistence, process control, CLIProxy,
/// SSH/Tailscale, telemetry). The UI talks only to this protocol; real
/// system integration is added later behind this boundary.
public protocol WorkjetService {
    func persistWorker(_ worker: Worker)
    func persistComputer(_ computer: Computer)
    func persistProvider(_ provider: Provider)
    func stopRun(id: UUID)
}

/// No-op implementation used for previews and tests.
public struct NullWorkjetService: WorkjetService {
    public init() {}
    public func persistWorker(_ worker: Worker) {}
    public func persistComputer(_ computer: Computer) {}
    public func persistProvider(_ provider: Provider) {}
    public func stopRun(id: UUID) {}
}
