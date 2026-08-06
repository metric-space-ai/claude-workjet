import Foundation

public enum RemoteRunLedgerError: LocalizedError, Equatable {
    case missingRunID
    case sequenceGap(expected: UInt64, received: UInt64)
    case sequenceRegression(cursor: UInt64, received: UInt64)
    case runIDMismatch(expected: String, received: String)
    case terminalStateRegression(from: RemoteHostRunState, to: RemoteHostRunState)
    case malformedHeartbeat(String)
    case adoptionUnavailable(String)
    case metadataMismatch(String)

    public var errorDescription: String? {
        switch self {
        case .missingRunID: return "Der Remote-Worker konnte nicht gestartet werden."
        case .sequenceGap: return "Ein Teil der Aktivitätsdetails ist nicht mehr verfügbar."
        case .sequenceRegression: return "Die Aktivitätsanzeige dieses Workers ist nicht mehr aktuell. Verbindung wird neu aufgebaut."
        case .runIDMismatch: return "Die Antwort gehört nicht mehr zum aktuellen Worker-Lauf. Bitte erneut versuchen."
        case .terminalStateRegression, .malformedHeartbeat:
            return "Aktivitätsdetails konnten nicht aktualisiert werden. Prüfe den Computer."
        case .adoptionUnavailable: return "Der laufende Remote-Worker konnte nicht wieder verbunden werden."
        case .metadataMismatch: return "Die gespeicherten Ausführungsdetails dieses Remote-Workers sind widersprüchlich."
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
    public private(set) var lostThroughSequence: UInt64?
    public private(set) var metadata: RemoteRunMetadata?

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
        metadata = nil
        lostThroughSequence = nil
        lastError = nil
        try ingest(response, expectedRunID: runID)
        return runID
    }

    /// Re-attaches a fresh app ledger to a host-owned run after an app restart.
    @discardableResult
    public func adopt(runID: String, ownerID: String) async throws -> RemoteLedgerSnapshot {
        let response = try await client.call(RemoteHostRequest(operation: .events, runID: runID, ownerID: ownerID, wireOperation: "adopt"))
        guard response.runID == runID else { throw RemoteRunLedgerError.adoptionUnavailable(runID) }
        self.runID = runID
        cursor = 0
        state = .unknown
        events = []
        heartbeatAt = nil
        metadata = nil
        lostThroughSequence = nil
        lastError = nil
        try ingest(response, expectedRunID: runID)
        return snapshot()
    }

    public func list(ownerID: String? = nil) async throws -> [RemoteHostRunDescriptor] {
        try await client.call(RemoteHostRequest(operation: .probe, ownerID: ownerID, wireOperation: "list")).runs
    }

    @discardableResult
    public func replay() async throws -> [RemoteHostEvent] {
        guard let runID else { throw RemoteRunLedgerError.missingRunID }
        do {
            let requestedCursor = cursor
            let response = try await client.call(RemoteHostRequest(operation: .events, runID: runID, afterSequence: requestedCursor))
            let previousCount = events.count
            let previousLoss = lostThroughSequence
            try ingest(response, expectedRunID: runID)
            lastError = nil
            return lostThroughSequence != previousLoss ? events : Array(events.dropFirst(previousCount))
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
        RemoteLedgerSnapshot(runID: runID, state: state, cursor: cursor, events: events, heartbeatAt: heartbeatAt, lastError: lastError, metadata: metadata)
    }

    private func ingest(_ response: RemoteHostResponse, expectedRunID: String) throws {
        if let receivedRunID = response.runID, receivedRunID != expectedRunID {
            throw RemoteRunLedgerError.runIDMismatch(expected: expectedRunID, received: receivedRunID)
        }
        if state.isTerminal, response.state != state {
            throw RemoteRunLedgerError.terminalStateRegression(from: state, to: response.state)
        }
        if let heartbeat = response.heartbeatAt {
            let fractional = ISO8601DateFormatter()
            fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            guard let parsed = fractional.date(from: heartbeat) ?? ISO8601DateFormatter().date(from: heartbeat) else {
                throw RemoteRunLedgerError.malformedHeartbeat(heartbeat)
            }
            heartbeatAt = parsed
        }
        if let accepted = response.metadata {
            if let existing = metadata, existing != accepted {
                // The active provider account may legitimately advance after a
                // provider-pool fallback. All other accepted launch facts are
                // immutable for the lifetime of a run.
                var comparable = accepted
                comparable.providerAccountLabel = existing.providerAccountLabel
                var existingComparable = existing
                existingComparable.providerAccountLabel = existing.providerAccountLabel
                guard comparable == existingComparable else {
                    throw RemoteRunLedgerError.metadataMismatch(expectedRunID)
                }
            }
            metadata = accepted
        }
        if let oldest = response.oldestSequence, oldest > cursor + 1 {
            guard response.gapAfterSequence == cursor else {
                throw RemoteRunLedgerError.sequenceGap(expected: cursor + 1, received: oldest)
            }
            lostThroughSequence = oldest - 1
            cursor = oldest - 1
            events.removeAll(keepingCapacity: true)
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
