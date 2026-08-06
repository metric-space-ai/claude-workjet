import Foundation

/// Coalesces UI mutations and performs all JSON/prompt I/O on one background queue.
public final class PersistenceCoordinator: @unchecked Sendable {
    public enum Outcome: Equatable, Sendable {
        case nothingPending
        case synchronized
        case failed(String)
    }

    private struct Pending {
        var configuration: WorkjetConfiguration
        var handwrittenChanged: Bool
    }

    private let service: any WorkjetService
    private let delay: TimeInterval
    private let queue: DispatchQueue
    private let lock = NSLock()
    private var pending: Pending?
    private var workItem: DispatchWorkItem?
    private let reportOutcome: @Sendable (Outcome) -> Void

    public init(service: any WorkjetService, delay: TimeInterval = 0.25, reportOutcome: @escaping @Sendable (Outcome) -> Void) {
        self.service = service
        self.delay = max(delay, 0)
        self.queue = DispatchQueue(label: "dev.workjet.persistence", qos: .utility)
        self.reportOutcome = reportOutcome
    }

    public func schedule(_ configuration: WorkjetConfiguration, handwrittenChanged: Bool) {
        lock.lock()
        let changed = (pending?.handwrittenChanged ?? false) || handwrittenChanged
        pending = Pending(configuration: configuration, handwrittenChanged: changed)
        workItem?.cancel()
        let item = DispatchWorkItem { [weak self] in self?.consumeAndSave() }
        workItem = item
        lock.unlock()
        queue.asyncAfter(deadline: .now() + delay, execute: item)
    }

    public func flush() async -> Outcome {
        cancelScheduledWorkItem()
        return await withCheckedContinuation { continuation in
            queue.async { [weak self] in
                continuation.resume(returning: self?.consumeAndSave() ?? .nothingPending)
            }
        }
    }

    private func cancelScheduledWorkItem() {
        lock.lock()
        workItem?.cancel()
        workItem = nil
        lock.unlock()
    }

    public func cancelPending() {
        lock.lock()
        workItem?.cancel()
        workItem = nil
        pending = nil
        lock.unlock()
    }

    @discardableResult
    private func consumeAndSave() -> Outcome {
        lock.lock()
        let value = pending
        pending = nil
        workItem = nil
        lock.unlock()
        guard let value else { return .nothingPending }
        let outcome: Outcome
        do {
            try service.save(value.configuration, handwrittenRulesChanged: value.handwrittenChanged)
            outcome = .synchronized
        } catch {
            outcome = .failed(error.localizedDescription)
        }
        reportOutcome(outcome)
        return outcome
    }
}
