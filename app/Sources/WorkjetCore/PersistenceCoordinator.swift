import Foundation

/// Coalesces UI mutations and performs all JSON/prompt I/O on one background queue.
public final class PersistenceCoordinator: @unchecked Sendable {
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
    private let reportError: @Sendable (Error) -> Void

    public init(service: any WorkjetService, delay: TimeInterval = 0.25, reportError: @escaping @Sendable (Error) -> Void) {
        self.service = service
        self.delay = max(delay, 0)
        self.queue = DispatchQueue(label: "dev.workjet.persistence", qos: .utility)
        self.reportError = reportError
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

    public func flush() async {
        cancelScheduledWorkItem()
        await withCheckedContinuation { continuation in
            queue.async { [weak self] in
                self?.consumeAndSave()
                continuation.resume()
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

    private func consumeAndSave() {
        lock.lock()
        let value = pending
        pending = nil
        workItem = nil
        lock.unlock()
        guard let value else { return }
        do { try service.save(value.configuration, handwrittenRulesChanged: value.handwrittenChanged) }
        catch { reportError(error) }
    }
}
