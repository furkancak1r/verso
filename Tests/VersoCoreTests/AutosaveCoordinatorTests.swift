import Foundation
import Testing
@testable import VersoCore

@MainActor
@Suite("AutosaveCoordinator")
struct AutosaveCoordinatorTests {
    @Test("Debounce replaces an earlier callback and uses approximately 400ms")
    func debounceReplacement() {
        var delays: [TimeInterval] = []
        var callbacks: [@MainActor () -> Void] = []
        var saved: [String] = []
        let coordinator = AutosaveCoordinator(
            scheduler: { delay, callback in
                delays.append(delay)
                callbacks.append(callback)
                return nil
            },
            saveClosure: { text in
                saved.append(text)
                return .success
            }
        )

        coordinator.load("initial")
        coordinator.textDidChange("one")
        coordinator.textDidChange("two")

        #expect(delays == [0.4, 0.4])
        #expect(callbacks.count == 2)
        callbacks[0]()
        #expect(saved.isEmpty)
        callbacks[1]()
        #expect(saved == ["two"])
        #expect(!coordinator.isDirty)
    }

    @Test("Force flush cancels the pending debounce and persists the latest text")
    func forceFlush() {
        var callbacks: [@MainActor () -> Void] = []
        var saved: [String] = []
        let coordinator = AutosaveCoordinator(
            scheduler: { _, callback in
                callbacks.append(callback)
                return nil
            },
            saveClosure: { text in
                saved.append(text)
                return .success
            }
        )

        coordinator.load("")
        coordinator.textDidChange("latest")
        if case .failure = coordinator.forceFlush() {
            #expect(Bool(false), "forced save unexpectedly failed")
        }
        callbacks[0]()

        #expect(saved == ["latest"])
        #expect(!coordinator.isDebounceScheduled)
    }

    @Test("A failed write retains the draft and retry reuses it")
    func failureAndRetry() {
        var shouldFail = true
        var saved: [String] = []
        let coordinator = AutosaveCoordinator(
            scheduler: { _, callback in callback(); return nil },
            saveClosure: { text in
                guard !shouldFail else {
                    return .failure(NSError(
                        domain: "VersoTests",
                        code: 1,
                        userInfo: [NSLocalizedDescriptionKey: "synthetic write failure"]
                    ))
                }
                saved.append(text)
                return .success
            }
        )

        coordinator.load("saved")
        coordinator.textDidChange("draft")
        #expect(coordinator.hasFailedSave)
        #expect(coordinator.currentText == "draft")
        #expect(coordinator.isDirty)

        shouldFail = false
        if case .failure = coordinator.retrySave() {
            #expect(Bool(false), "retry unexpectedly failed")
        }
        #expect(saved == ["draft"])
        #expect(!coordinator.isDirty)
    }

    @Test("Save completion observes cleared error state after a successful retry")
    func completionRunsAfterStateUpdate() {
        var shouldFail = true
        var observations: [(failed: Bool, dirty: Bool)] = []
        var coordinator: AutosaveCoordinator!
        coordinator = AutosaveCoordinator(
            scheduler: { _, callback in
                callback()
                return nil
            },
            saveClosure: { _ in
                if shouldFail {
                    return .failure(NSError(
                        domain: "VersoTests",
                        code: 2,
                        userInfo: [NSLocalizedDescriptionKey: "synthetic write failure"]
                    ))
                }
                return .success
            },
            saveCompletion: { _ in
                observations.append((
                    failed: coordinator.hasFailedSave,
                    dirty: coordinator.isDirty
                ))
            }
        )

        coordinator.load("saved")
        coordinator.textDidChange("draft")
        #expect(observations.count == 1)
        #expect(observations[0].failed)
        #expect(observations[0].dirty)

        shouldFail = false
        _ = coordinator.retrySave()
        #expect(observations.count == 2)
        #expect(!observations[1].failed)
        #expect(!observations[1].dirty)
    }
}
