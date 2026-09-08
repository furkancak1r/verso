import Foundation

/// Owns the small debounce window between editor changes and a persistence
/// closure. The latest text remains in memory when a write fails.
@MainActor
public final class AutosaveCoordinator {
    public enum SaveResult {
        case success
        case failure(Error)
    }

    /// The scheduler is deliberately just a closure so tests can fire it
    /// deterministically without introducing a clock framework.
    public typealias Scheduler = @MainActor (
        _ delay: TimeInterval,
        _ callback: @escaping @MainActor () -> Void
    ) -> Any?

    public typealias SaveClosure = @MainActor (_ text: String) -> SaveResult
    public typealias SaveCompletion = @MainActor (_ result: SaveResult) -> Void

    public nonisolated static let defaultDebounceInterval: TimeInterval = 0.4

    public private(set) var currentText = ""
    public private(set) var lastError: Error?
    public private(set) var isDebounceScheduled = false

    /// A failed write is dirty even when the text matches the last successful
    /// text, because the pending model change still needs a retry.
    public var isDirty: Bool {
        currentText != lastSavedText || lastError != nil
    }

    public var hasFailedSave: Bool { lastError != nil }

    private var lastSavedText = ""
    private var scheduledWork: Any?
    private var scheduleGeneration: UInt64 = 0
    private let debounceInterval: TimeInterval
    private let scheduler: Scheduler
    private let saveClosure: SaveClosure
    private let saveCompletion: SaveCompletion?

    public init(
        debounceInterval: TimeInterval = 0.4,
        scheduler: @escaping Scheduler,
        saveClosure: @escaping SaveClosure,
        saveCompletion: SaveCompletion? = nil
    ) {
        self.debounceInterval = debounceInterval
        self.scheduler = scheduler
        self.saveClosure = saveClosure
        self.saveCompletion = saveCompletion
    }

    /// Load a persisted value and discard any old pending debounce.
    public func load(_ text: String) {
        cancelDebounce()
        currentText = text
        lastSavedText = text
        lastError = nil
    }

    /// Record the actual editor value and schedule one replacement debounce.
    public func textDidChange(_ text: String) {
        currentText = text
        guard isDirty else { return }
        scheduleDebounce()
    }

    /// Cancel a pending debounce and synchronously attempt the latest value.
    @discardableResult
    public func forceFlush() -> SaveResult {
        cancelDebounce()
        return performSave()
    }

    /// Retry the same dirty context; the text and model are not recreated.
    @discardableResult
    public func retrySave() -> SaveResult {
        guard isDirty else { return .success }
        return forceFlush()
    }

    public func cancelDebounce() {
        scheduleGeneration &+= 1
        if let work = scheduledWork as? DispatchWorkItem {
            work.cancel()
        }
        scheduledWork = nil
        isDebounceScheduled = false
    }

    /// Mark a value saved after a caller commits additional model metadata.
    public func markSaved(_ text: String? = nil) {
        lastSavedText = text ?? currentText
        lastError = nil
    }

    private func scheduleDebounce() {
        cancelDebounce()
        let generation = scheduleGeneration
        isDebounceScheduled = true
        scheduledWork = scheduler(debounceInterval) { [weak self] in
            guard let self,
                  self.scheduleGeneration == generation,
                  self.isDebounceScheduled else {
                return
            }
            self.scheduledWork = nil
            self.isDebounceScheduled = false
            guard self.isDirty else { return }
            _ = self.performSave()
        }
    }

    @discardableResult
    private func performSave() -> SaveResult {
        let textToSave = currentText
        let result = saveClosure(textToSave)
        switch result {
        case .success:
            lastSavedText = textToSave
            lastError = nil
        case .failure(let error):
            lastError = error
        }
        // Notify only after the coordinator has updated its dirty/error state.
        saveCompletion?(result)
        return result
    }
}
