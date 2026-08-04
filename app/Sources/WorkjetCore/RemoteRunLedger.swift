import Foundation

public enum RemoteRunLedgerError: LocalizedError, Equatable {
    case missingRunID
    case sequenceGap(expected: UInt64, received: UInt64)
    case sequenceRegression(cursor: UInt64, received: UInt64)
    case runIDMismatch(expected: String, received: String)
    case terminalStateRegression(from: RemoteHostRunState, to: RemoteHostRunState)
    case malformedHeartbeat(String)

    public var errorDescription: String? {
        switch self {
        case .missingRunID: return "Remote-Host lieferte keine Run-ID."
        case let .sequenceGap(expected, received): return "Remote-Event-Lücke: erwartet \(expected), erhalten \(received)."
        case let .sequenceRegression(cursor, received): return "Remote-Event-Sequenz ist hinter Cursor \(cursor) auf \(received) zurückgefallen."
        case let .runIDMismatch(expected, received): return "Remote-Host antwortete für Run \(received) statt \(expected)."
        case let .terminalStateRegression(from, to): return "Terminaler Remote-Zustand \(from.rawValue) darf nicht auf \(to.rawValue) zurückfallen."
        case let .malformedHeartbeat(value): return "Remote-Host lieferte keinen gültigen ISO-8601-Heartbeat: \(value)."
        }
    }
}

public actor RemoteRunLedger {
    public private(set) var runID: String?
    public private(set) var cursor: UInt64 = 0
    public private(set) var state: RemoteHostRunState = .unknown
    public private(set) var events: [RemoteHostEvent] = []
    public private(set) var lastError: String?
    public private(set) var heartbeatAt: Date?

    private let client: any RemoteHostCalling
    private let now: @Sendable () -> Date

    public init(client: any RemoteHostCalling, now: @escaping @Sendable () -> Date = { Date() }) {
        self.client = client
        self.now = now
    }

    @discardableResult
    public func start(_ request: RemoteHostRequest) async throws -> String {
        let response = try await client.call(request)
        guard let runID = response.runID, !runID.isEmpty else { throw RemoteRunLedgerError.missingRunID }
        self.runID = runID
        cursor = 0
        state = .unknown
        events = []
        heartbeatAt = nil
        lastError = nil
        try ingest(response, expectedRunID: runID)
        return runID
    }

    @discardableResult
    public func replay() async throws -> [RemoteHostEvent] {
        guard let runID else { throw RemoteRunLedgerError.missingRunID }
        do {
            let requestedCursor = cursor
            let response = try await client.call(RemoteHostRequest(operation: .events, runID: runID, afterSequence: requestedCursor))
            let previousCount = events.count
            try ingest(response, expectedRunID: runID)
            lastError = nil
            return Array(events.dropFirst(previousCount))
        } catch let error as RemoteRunLedgerError {
            state = .error
            lastError = error.localizedDescription
            throw error
        } catch {
            lastError = error.localizedDescription
            throw error
        }
    }

    public func stop() async throws {
        guard let runID else { throw RemoteRunLedgerError.missingRunID }
        let response = try await client.call(RemoteHostRequest(operation: .stop, runID: runID))
        try ingest(response, expectedRunID: runID)
        lastError = nil
    }

    /// Requests cleanup only when the host supplied an explicit child-process
    /// heartbeat. Quiet output and a merely reachable host are not liveness.
    @discardableResult
    public func reapStaleGhost(olderThan maxAge: TimeInterval) async throws -> Bool {
        guard !state.isTerminal, let heartbeatAt,
              now().timeIntervalSince(heartbeatAt) > max(maxAge, 0) else { return false }
        try await stop()
        return true
    }

    public func snapshot() -> RemoteLedgerSnapshot {
        RemoteLedgerSnapshot(runID: runID, state: state, cursor: cursor, events: events, heartbeatAt: heartbeatAt, lastError: lastError)
    }

    private func ingest(_ response: RemoteHostResponse, expectedRunID: String) throws {
        if let receivedRunID = response.runID, receivedRunID != expectedRunID {
            throw RemoteRunLedgerError.runIDMismatch(expected: expectedRunID, received: receivedRunID)
        }
        if state.isTerminal, response.state != state {
            throw RemoteRunLedgerError.terminalStateRegression(from: state, to: response.state)
        }
        if let heartbeat = response.heartbeatAt {
            guard let parsed = ISO8601DateFormatter().date(from: heartbeat) else {
                throw RemoteRunLedgerError.malformedHeartbeat(heartbeat)
            }
            heartbeatAt = parsed
        }
        if let oldest = response.oldestSequence, oldest > cursor + 1 {
            throw RemoteRunLedgerError.sequenceGap(expected: cursor + 1, received: oldest)
        }

        var appended: [RemoteHostEvent] = []
        for event in response.events {
            if event.sequence <= cursor {
                guard events.first(where: { $0.sequence == event.sequence }) == event else {
                    throw RemoteRunLedgerError.sequenceRegression(cursor: cursor, received: event.sequence)
                }
                continue
            }
            let expected = cursor + 1
            guard event.sequence == expected else {
                throw RemoteRunLedgerError.sequenceGap(expected: expected, received: event.sequence)
            }
            cursor = event.sequence
            appended.append(event)
        }
        events.append(contentsOf: appended)
        guard response.cursor >= cursor else {
            throw RemoteRunLedgerError.sequenceRegression(cursor: cursor, received: response.cursor)
        }
        guard response.cursor == cursor else {
            throw RemoteRunLedgerError.sequenceGap(expected: cursor + 1, received: response.cursor)
        }
        state = response.state
    }
}
