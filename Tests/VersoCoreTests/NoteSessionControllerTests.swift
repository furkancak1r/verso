import AppKit
import ApplicationServices
import CoreGraphics
import Testing
@testable import Verso
@testable import VersoCore

@MainActor
@Suite("NoteSessionController")
struct NoteSessionControllerTests {
    private func controller(
        reservationLiveness: @escaping NoteSessionController.ReservationLivenessCheck = {
            _, _ in .alive
        }
    ) -> (NoteSessionController, NoteRepository) {
        let repository = NoteRepository()
        let scheduler: AutosaveCoordinator.Scheduler = { _, _ in nil }
        let controller = NoteSessionController(
            repository: repository,
            schedulerFactory: scheduler,
            reservationLiveness: reservationLiveness
        )
        #expect(controller.openStore(inMemory: true))
        return (controller, repository)
    }

    private func target(
        axWindow: AXUIElement,
        bundleIdentifier: String = "com.example.editor",
        title: String = "Draft",
        path: String? = "/tmp/Draft.md"
    ) -> AccessibilityWindowService.ResolvedTargetWindow {
        let runningApplication = NSRunningApplication.current
        let metadata = TargetWindowMetadata(
            pid: runningApplication.processIdentifier,
            bundleIdentifier: bundleIdentifier,
            appName: "Synthetic Editor",
            windowTitle: title,
            windowRole: TargetWindowMetadata.windowRole,
            windowSubrole: TargetWindowMetadata.standardWindowSubrole,
            documentPath: path,
            documentURL: nil,
            frame: CGRect(x: 20, y: 20, width: 800, height: 600)
        )
        return AccessibilityWindowService.ResolvedTargetWindow(
            metadata: metadata,
            evidence: HitTestEvidence(hitRole: "AXWindow"),
            axWindow: axWindow,
            axApplication: AXUIElementCreateApplication(
                runningApplication.processIdentifier
            ),
            runningApplication: runningApplication
        )
    }

    @Test("Two live windows with one exact path receive separate notes")
    func samePathLiveCollision() {
        let (controller, repository) = controller()
        let pid = NSRunningApplication.current.processIdentifier
        let firstTarget = target(axWindow: AXUIElementCreateApplication(pid))
        let secondTarget = target(axWindow: AXUIElementCreateSystemWide())

        #expect(controller.beginSessionIfPossible(for: firstTarget) == "")
        #expect(controller.commitAndSave(editorText: "window one").0)
        controller.endActiveSession()

        #expect(controller.beginSessionIfPossible(for: secondTarget) == "")
        let key = controller.resolver.resolve(
            bundleIdentifier: firstTarget.metadata.bundleIdentifier,
            documentPath: firstTarget.metadata.documentPath,
            documentURL: nil,
            windowTitle: firstTarget.metadata.windowTitle
        ).identityKey
        #expect(repository.fetchActiveNotes(forKey: key).count == 2)
        #expect(controller.activeLiveSessionCount == 2)
    }

    @Test("A proven-dead reservation is released lazily for exact restore")
    func deadReservationIsReleased() {
        let (controller, repository) = controller(
            reservationLiveness: { _, _ in .dead }
        )
        let pid = NSRunningApplication.current.processIdentifier
        let first = target(axWindow: AXUIElementCreateApplication(pid))
        let second = target(axWindow: AXUIElementCreateSystemWide())

        #expect(controller.beginSessionIfPossible(for: first) == "")
        #expect(controller.commitAndSave(editorText: "released note").0)
        controller.endActiveSession()

        #expect(controller.beginSessionIfPossible(for: second) == "released note")
        #expect(controller.activeLiveSessionCount == 1)
        let key = controller.resolver.resolve(
            bundleIdentifier: first.metadata.bundleIdentifier,
            documentPath: first.metadata.documentPath,
            documentURL: nil,
            windowTitle: first.metadata.windowTitle
        ).identityKey
        #expect(repository.fetchActiveNotes(forKey: key).count == 1)
        #expect(controller.recoveryDraftCount == 0)
    }

    @Test("An ambiguous reservation liveness result stays reserved")
    func ambiguousReservationStaysReserved() {
        var checks = 0
        let (controller, repository) = controller(
            reservationLiveness: { _, _ in
                checks += 1
                return .unknown
            }
        )
        let pid = NSRunningApplication.current.processIdentifier
        let first = target(axWindow: AXUIElementCreateApplication(pid))
        let second = target(axWindow: AXUIElementCreateSystemWide())

        #expect(controller.beginSessionIfPossible(for: first) == "")
        #expect(controller.commitAndSave(editorText: "reserved note").0)
        controller.endActiveSession()

        #expect(controller.beginSessionIfPossible(for: second) == "")
        #expect(checks == 1)
        #expect(controller.activeLiveSessionCount == 2)
        let key = controller.resolver.resolve(
            bundleIdentifier: first.metadata.bundleIdentifier,
            documentPath: first.metadata.documentPath,
            documentURL: nil,
            windowTitle: first.metadata.windowTitle
        ).identityKey
        #expect(repository.fetchActiveNotes(forKey: key).count == 2)
    }

    @Test("Browser title changes retain one live note for one AX window")
    func browserTitleChange() {
        let (controller, repository) = controller()
        let ax = AXUIElementCreateApplication(
            NSRunningApplication.current.processIdentifier
        )
        let first = target(
            axWindow: ax,
            bundleIdentifier: "com.apple.Safari",
            title: "Tab A",
            path: nil
        )
        let second = target(
            axWindow: ax,
            bundleIdentifier: "com.apple.Safari",
            title: "Tab B",
            path: nil
        )

        #expect(controller.beginSessionIfPossible(for: first) == "")
        #expect(controller.commitAndSave(editorText: "browser note").0)
        let sessionID = controller.activeSessionUUID
        controller.endActiveSession()

        #expect(controller.beginSessionIfPossible(for: second) == "browser note")
        #expect(controller.activeSessionUUID == sessionID)
        #expect(controller.activeLiveSessionCount == 1)
        let key = controller.resolver.resolve(
            bundleIdentifier: "com.apple.Safari",
            documentPath: nil,
            documentURL: nil,
            windowTitle: "Tab B",
            sessionID: sessionID
        ).identityKey
        #expect(repository.fetchActiveNotes(forKey: key).count == 1)
    }

    @Test("Saved exact notes restore only when the candidate is unique", arguments: [1, 2])
    func persistedCandidateUniqueness(candidateCount: Int) {
        let (controller, repository) = controller()
        let target = target(axWindow: AXUIElementCreateApplication(getpid()))
        let identity = controller.resolver.resolve(
            bundleIdentifier: target.metadata.bundleIdentifier,
            documentPath: target.metadata.documentPath,
            documentURL: nil,
            windowTitle: target.metadata.windowTitle
        )
        for index in 0..<candidateCount {
            repository.insert(WindowNote(
                identityKey: identity.identityKey, confidence: .exact,
                bundleIdentifier: "com.example.editor", applicationName: "Editor",
                noteText: "saved \(index)"
            ))
        }
        #expect(repository.save().0)
        #expect(controller.beginSessionIfPossible(for: target) == (candidateCount == 1 ? "saved 0" : ""))
        #expect(repository.fetchActiveNotes(forKey: identity.identityKey).count == (candidateCount == 1 ? 1 : 3))
    }

    @Test("Retry flushes a metadata-only recovery draft after its live session is released")
    func metadataOnlyRecoveryRetry() throws {
        let (controller, _) = controller()
        let target = target(axWindow: AXUIElementCreateApplication(getpid()))
        #expect(controller.beginSessionIfPossible(for: target) == "")
        let sessionID = try #require(controller.activeSessionUUID)
        controller.closeSession(for: sessionID)
        #expect(controller.activeLiveSessionCount == 0)
        #expect(controller.recoveryDraftCount == 1)
        #expect(controller.retryPendingSaves())
        #expect(controller.recoveryDraftCount == 0)
    }

    @Test("An exact document change on one AX window preserves A and opens B")
    func documentChange() {
        let (controller, repository) = controller()
        let ax = AXUIElementCreateApplication(
            NSRunningApplication.current.processIdentifier
        )
        let first = target(axWindow: ax, title: "A", path: "/tmp/A.md")
        let second = target(axWindow: ax, title: "B", path: "/tmp/B.md")
        let firstIdentity = controller.resolver.resolve(
            bundleIdentifier: first.metadata.bundleIdentifier,
            documentPath: first.metadata.documentPath,
            documentURL: nil,
            windowTitle: first.metadata.windowTitle
        )

        #expect(controller.beginSessionIfPossible(for: first) == "")
        let firstSession = controller.activeSessionUUID
        #expect(controller.commitAndSave(editorText: "note A").0)

        #expect(controller.beginSessionIfPossible(for: second) == "")
        #expect(controller.activeSessionUUID != firstSession)
        let savedA = repository.fetchActiveNotes(
            forKey: firstIdentity.identityKey
        )
        #expect(savedA.count == 1)
        #expect(savedA[0].noteText == "note A")
        #expect(controller.activeLiveSessionCount == 1)
    }

    @Test("A callback from an old editor cannot modify the newly selected note")
    func staleEditorCallbackIgnored() {
        let (controller, repository) = controller()
        let first = target(
            axWindow: AXUIElementCreateApplication(
                NSRunningApplication.current.processIdentifier
            ),
            path: "/tmp/first.md"
        )
        let second = target(
            axWindow: AXUIElementCreateSystemWide(),
            path: "/tmp/second.md"
        )

        #expect(controller.beginSessionIfPossible(for: first) == "")
        let oldSession = controller.activeSessionUUID
        #expect(controller.beginSessionIfPossible(for: second) == "")
        let secondSession = controller.activeSessionUUID
        #expect(oldSession != secondSession)

        controller.editorTextDidChange("stale", sessionID: oldSession)
        #expect(controller.commitAndSave(editorText: "current").0)
        let key = controller.resolver.resolve(
            bundleIdentifier: second.metadata.bundleIdentifier,
            documentPath: second.metadata.documentPath,
            documentURL: nil,
            windowTitle: second.metadata.windowTitle
        ).identityKey
        let notes = repository.fetchActiveNotes(forKey: key)
        #expect(notes.count == 1)
        #expect(notes[0].noteText == "current")
    }

    @Test("An initially untitled live draft is not replaced when a path appears")
    func untitledDraftPreserved() {
        let (controller, repository) = controller()
        let ax = AXUIElementCreateApplication(
            NSRunningApplication.current.processIdentifier
        )
        let untitled = target(axWindow: ax, title: "Untitled", path: nil)
        let pathTarget = target(
            axWindow: ax,
            title: "Draft",
            path: "/tmp/appeared.md"
        )

        #expect(controller.beginSessionIfPossible(for: untitled) == "")
        let sessionID = controller.activeSessionUUID
        #expect(controller.commitAndSave(editorText: "live draft").0)
        #expect(controller.beginSessionIfPossible(for: pathTarget) == "live draft")
        #expect(controller.activeSessionUUID == sessionID)
        let key = controller.resolver.resolve(
            bundleIdentifier: untitled.metadata.bundleIdentifier,
            documentPath: nil,
            documentURL: nil,
            windowTitle: untitled.metadata.windowTitle
        ).identityKey
        let notes = repository.fetchActiveNotes(forKey: key)
        #expect(notes.count == 1)
        #expect(notes[0].documentPath.isEmpty)
        #expect(notes[0].noteText == "live draft")
    }

    @Test("Pin and archive failures preserve the active draft")
    func metadataFailurePreservesDraft() {
        let repository = NoteRepository()
        var saveCall = 0
        let failure = NSError(
            domain: "VersoTests",
            code: 20,
            userInfo: [NSLocalizedDescriptionKey: "synthetic metadata failure"]
        )
        let controller = NoteSessionController(
            repository: repository,
            schedulerFactory: { _, _ in nil },
            reservationLiveness: { _, _ in .alive },
            repositorySave: {
                saveCall += 1
                if saveCall == 3 || saveCall == 5 {
                    return (false, failure)
                }
                return repository.save()
            }
        )
        #expect(controller.openStore(inMemory: true))
        let target = target(
            axWindow: AXUIElementCreateApplication(
                NSRunningApplication.current.processIdentifier
            )
        )
        #expect(controller.beginSessionIfPossible(for: target) == "")
        #expect(controller.commitAndSave(editorText: "draft").0)

        let pin = controller.toggleActiveNotePin(editorText: "draft")
        #expect(!pin.0)
        #expect(controller.activeSessionUUID != nil)
        #expect(controller.activeSession?.note.pinned == false)
        #expect(controller.activeSession?.note.noteText == "draft")
        let archive = controller.archiveActiveNote(editorText: "draft")
        #expect(!archive.0)
        #expect(controller.activeSessionUUID != nil)
        #expect(controller.activeSession?.note.archived == false)
        #expect(controller.activeSession?.note.noteText == "draft")
        #expect(controller.lastSaveError != nil)
    }

    @Test("Active pin toggle updates membership, survives reopen, rolls back failed unpin")
    func activePinToggleMembership() throws {
        let repository = NoteRepository()
        var saveCall = 0
        let failure = NSError(
            domain: "VersoTests",
            code: 23,
            userInfo: [NSLocalizedDescriptionKey: "synthetic toggle failure"]
        )
        let controller = NoteSessionController(
            repository: repository,
            schedulerFactory: { _, _ in nil },
            reservationLiveness: { _, _ in .alive },
            repositorySave: {
                saveCall += 1
                // Saves 1-4 succeed (initial commit, pin commit, pin metadata,
                // unpin-attempt commit); save 5 is the unpin metadata write.
                if saveCall == 5 {
                    return (false, failure)
                }
                return repository.save()
            }
        )
        #expect(controller.openStore(inMemory: true))
        let target = target(
            axWindow: AXUIElementCreateApplication(
                NSRunningApplication.current.processIdentifier
            )
        )
        #expect(controller.beginSessionIfPossible(for: target) == "")
        #expect(controller.commitAndSave(editorText: "toggle draft").0)
        let noteID = try #require(controller.activeSession?.note.id)

        #expect(controller.toggleActiveNotePin(editorText: "toggle draft").0)
        #expect(controller.activeSession?.note.pinned == true)
        #expect(try repository.fetchPinnedNotesThrowing().map(\.id).contains(noteID))

        // Failed unpin keeps the old persisted value and list membership.
        let failedUnpin = controller.toggleActiveNotePin(editorText: "toggle draft")
        #expect(!failedUnpin.0)
        #expect(controller.activeSession?.note.pinned == true)
        #expect(controller.activeSession?.note.noteText == "toggle draft")
        #expect(try repository.fetchPinnedNotesThrowing().map(\.id).contains(noteID))
        #expect(controller.lastSaveError != nil)

        #expect(controller.toggleActiveNotePin(editorText: "toggle draft").0)
        #expect(controller.activeSession?.note.pinned == false)
        #expect(!(try repository.fetchPinnedNotesThrowing().map(\.id).contains(noteID)))
        #expect(controller.lastSaveError == nil)

        // Reopened session observes the persisted unpinned value, and a new
        // pin survives a second reopen.
        controller.endActiveSession()
        #expect(controller.beginSessionIfPossible(for: target) == "toggle draft")
        #expect(controller.activeSession?.note.pinned == false)
        #expect(controller.toggleActiveNotePin(editorText: "toggle draft").0)
        controller.endActiveSession()
        #expect(controller.beginSessionIfPossible(for: target) == "toggle draft")
        #expect(controller.activeSession?.note.pinned == true)
    }

    @Test("A failed context save survives process pruning and retries the orphan draft")
    func orphanedDraftFailureAndRecovery() {
        let repository = NoteRepository()
        var shouldFail = true
        let failure = NSError(
            domain: "VersoTests",
            code: 21,
            userInfo: [NSLocalizedDescriptionKey: "synthetic context failure"]
        )
        let controller = NoteSessionController(
            repository: repository,
            schedulerFactory: { _, _ in nil },
            reservationLiveness: { _, _ in .alive },
            repositorySave: {
                shouldFail ? (false, failure) : repository.save()
            }
        )
        #expect(controller.openStore(inMemory: true))
        let target = target(
            axWindow: AXUIElementCreateApplication(
                NSRunningApplication.current.processIdentifier
            )
        )
        #expect(controller.beginSessionIfPossible(for: target) == "")
        let originalContext = repository.context
        controller.editorTextDidChange("orphan draft")
        #expect(controller.activeSession?.note.noteText == "orphan draft")

        controller.pruneStaleReferences(for: target.runningApplication)
        #expect(controller.activeLiveSessionCount == 0)
        #expect(controller.recoveryDraftCount == 1)
        #expect(controller.lastSaveError != nil)
        #expect(repository.context === originalContext)
        #expect(!controller.forceSaveAll())
        #expect(controller.recoveryDraftCount == 1)

        shouldFail = false
        #expect(controller.retryPendingSaves())
        #expect(controller.recoveryDraftCount == 0)
        let key = controller.resolver.resolve(
            bundleIdentifier: target.metadata.bundleIdentifier,
            documentPath: target.metadata.documentPath,
            documentURL: nil,
            windowTitle: target.metadata.windowTitle
        ).identityKey
        let notes = repository.fetchActiveNotes(forKey: key)
        #expect(notes.count == 1)
        #expect(notes[0].noteText == "orphan draft")
    }

    @Test("Autosave failure and recovery publish immediate status changes")
    func saveStatusNotifications() {
        let repository = NoteRepository()
        var shouldFail = true
        var callbacks: [@MainActor () -> Void] = []
        let failure = NSError(
            domain: "VersoTests",
            code: 22,
            userInfo: [NSLocalizedDescriptionKey: "synthetic notification failure"]
        )
        let controller = NoteSessionController(
            repository: repository,
            schedulerFactory: { _, callback in callbacks.append(callback); return nil },
            reservationLiveness: { _, _ in .alive },
            repositorySave: {
                shouldFail ? (false, failure) : repository.save()
            }
        )
        #expect(controller.openStore(inMemory: true))
        var hasError: [Bool] = []
        controller.onSaveErrorChanged = { hasError.append($0 != nil) }
        let target = target(
            axWindow: AXUIElementCreateApplication(
                NSRunningApplication.current.processIdentifier
            )
        )
        #expect(controller.beginSessionIfPossible(for: target) == "")

        controller.editorTextDidChange("draft")
        callbacks.last?()
        #expect(hasError.last == true)

        shouldFail = false
        controller.editorTextDidChange("updated draft")
        callbacks.last?()
        #expect(hasError.last == false)
    }
}
