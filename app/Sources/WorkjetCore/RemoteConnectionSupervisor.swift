import Foundation

public struct RemoteReconnectPolicy: Equatable, Sendable {
    public var attempts: Int
    public var initialDelayMilliseconds: UInt64

    public init(attempts: Int = 3, initialDelayMilliseconds: UInt64 = 100) {
        self.attempts = max(attempts, 1)
        self.initialDelayMilliseconds = initialDelayMilliseconds
    }
}

public actor RemoteConnectionSupervisor {
    public private(set) var connectionError: String?
    private let ledger: RemoteRunLedger
    private let policy: RemoteReconnectPolicy

    public init(ledger: RemoteRunLedger, policy: RemoteReconnectPolicy = .init()) {
        self.ledger = ledger
        self.policy = policy
    }

    @discardableResult
    public func reconnectAndReplay() async throws -> [RemoteHostEvent] {
        var last: Error?
        for attempt in 0..<policy.attempts {
            do {
                let result = try await ledger.replay()
                connectionError = nil
                return result
            } catch let error as RemoteRunLedgerError {
                connectionError = error.localizedDescription
                throw error // Protocol gaps are authoritative and must never be retried away.
            } catch {
                last = error
                connectionError = error.localizedDescription
                guard attempt + 1 < policy.attempts else { break }
                let multiplier = UInt64(1) << UInt64(attempt)
                try await Task.sleep(for: .milliseconds(policy.initialDelayMilliseconds * multiplier))
            }
        }
        throw last ?? RemoteHostProtocolError.transport("Reconnect ohne konkrete Fehlerursache fehlgeschlagen.")
    }

    /// Polls from the durable exclusive cursor, then requests cleanup for an
    /// explicitly stale run heartbeat. The cursor is never reset on retries.
    @discardableResult
    public func refreshAndReapGhosts(staleAfter: TimeInterval = 45) async throws -> [RemoteHostEvent] {
        let fresh = try await reconnectAndReplay()
        _ = try await ledger.reapStaleGhost(olderThan: staleAfter)
        return fresh
    }
}
