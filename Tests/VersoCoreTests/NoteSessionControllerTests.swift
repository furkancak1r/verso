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

    @Test("Untouched and whitespace-only sessions create no stored or recovery notes")
    func emptySessionsStayInMemory() throws {
        let (controller, repository) = controller()
        let target = target(axWindow: AXUIElementCreateApplication(getpid()))
        #expect(controller.beginSessionIfPossible(for: target) == "")
        let firstID = try #require(controller.activeSessionUUID)
        controller.closeSession(for: firstID)
        #expect(controller.recoveryDraftCount == 0)
        #expect(try repository.fetchActiveNotesThrowing().isEmpty)

        #expect(controller.beginSessionIfPossible(for: target) == "")
        let draft = try #require(controller.activeSession?.note)
        #expect(draft.modelContext == nil)
        controller.updateActiveTitle("Still blank")
        #expect(controller.commitAndSave(editorText: " \n\t ").0)
        #expect(controller.forceSaveAll())
        #expect(try repository.fetchActiveNotesThrowing().isEmpty)
        #expect(controller.commitAndSave(editorText: "  İçerik ✅  ").0)
        #expect(try repository.fetchActiveNotesThrowing().map(\.id) == [draft.id])
        #expect(controller.commitAndSave(editorText: "").0)
        #expect(try repository.fetchActiveNotesThrowing().isEmpty)
        #expect(controller.activeSession?.note === draft)
        #expect(controller.commitAndSave(editorText: "  İçerik ✅  ").0)
        let restored = try #require(repository.fetchActiveNotesThrowing().first)
        #expect(restored.id == draft.id)
        #expect(restored.noteText == "  İçerik ✅  ")
        #expect(restored.windowTitle == "Still blank")
    }

    // ponytail: APPLICATION grouping supersedes per-window reservation splits
    // for identified apps: same-app windows share one tab even when the AX
    // reservation reads dead, and the pending clear stays a shared draft.
    @Test("Same-app windows share one tab even when the reservation reads dead", arguments: [false, true])
    func deadClearedReservation(failClear: Bool) throws {
        let repository = NoteRepository()
        var fail = false
        let error = NSError(domain: "VersoTests", code: 25)
        let sessions = NoteSessionController(
            repository: repository, schedulerFactory: { _, _ in nil },
            reservationLiveness: { _, _ in .dead },
            repositorySave: { fail ? (false, error) : repository.save() }
        )
        #expect(sessions.openStore(inMemory: true))
        let first = target(axWindow: AXUIElementCreateApplication(getpid()))
        let second = target(axWindow: AXUIElementCreateSystemWide())
        #expect(sessions.beginSessionIfPossible(for: first) == "")
        #expect(sessions.commitAndSave(editorText: "Saved before closing").0)
        let oldID = try #require(sessions.activeSession?.note.id)
        sessions.editorTextDidChange("")
        sessions.endActiveSession()
        fail = failClear
        #expect(sessions.beginSessionIfPossible(for: second) == "")
        #expect(sessions.activeSession?.note.id == oldID)
        #expect(sessions.activeLiveSessionCount == 2)
        #expect(sessions.recoveryDraftCount == 0)
        #expect(try repository.fetchActiveNotesThrowing().count == 1)
        fail = false
        #expect(sessions.retryPendingSaves())
        #expect(sessions.recoveryDraftCount == 0)
        #expect(try repository.fetchActiveNotesThrowing().isEmpty)
    }

    // ponytail: APPLICATION grouping supersedes per-window identity: two live
    // windows of one app share a single note.
    @Test("Two live windows of one app share a single note")
    func samePathLiveCollision() {
        let (controller, repository) = controller()
        let pid = NSRunningApplication.current.processIdentifier
        let firstTarget = target(axWindow: AXUIElementCreateApplication(pid))
        let secondTarget = target(axWindow: AXUIElementCreateSystemWide())

        #expect(controller.beginSessionIfPossible(for: firstTarget) == "")
        #expect(controller.commitAndSave(editorText: "window one").0)
        controller.endActiveSession()

        #expect(controller.beginSessionIfPossible(for: secondTarget) == "window one")
        #expect(controller.activeTabNotes.count == 1)
        let key = controller.resolver.resolve(
            bundleIdentifier: firstTarget.metadata.bundleIdentifier,
            documentPath: firstTarget.metadata.documentPath,
            documentURL: nil,
            windowTitle: firstTarget.metadata.windowTitle
        ).identityKey
        #expect(repository.fetchActiveNotes(forKey: key).count == 1)
        #expect(controller.commitAndSave(editorText: "window two").0)
        #expect(repository.fetchActiveNotes(forKey: key).count == 1)
        #expect(repository.fetchActiveNotes(forKey: key).first?.noteText == "window two")
        #expect(controller.activeLiveSessionCount == 2)
    }

    // ponytail: APPLICATION grouping supersedes lazy reservation release for
    // identified apps; the second window joins the shared tab instead.
    @Test("Same-app windows join the shared tab instead of releasing it")
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
        #expect(controller.activeLiveSessionCount == 2)
        #expect(controller.activeTabNotes.count == 1)
        let key = controller.resolver.resolve(
            bundleIdentifier: first.metadata.bundleIdentifier,
            documentPath: first.metadata.documentPath,
            documentURL: nil,
            windowTitle: first.metadata.windowTitle
        ).identityKey
        #expect(repository.fetchActiveNotes(forKey: key).count == 1)
        #expect(controller.recoveryDraftCount == 0)
    }

    // ponytail: APPLICATION grouping supersedes reservation checks for
    // identified apps; sharing never consults AX liveness.
    @Test("Same-app sharing does not consult reservation liveness")
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

        #expect(controller.beginSessionIfPossible(for: second) == "reserved note")
        #expect(checks == 0)
        #expect(controller.activeLiveSessionCount == 2)
        #expect(controller.activeTabNotes.count == 1)
        let key = controller.resolver.resolve(
            bundleIdentifier: first.metadata.bundleIdentifier,
            documentPath: first.metadata.documentPath,
            documentURL: nil,
            windowTitle: first.metadata.windowTitle
        ).identityKey
        #expect(repository.fetchActiveNotes(forKey: key).count == 1)
        #expect(controller.commitAndSave(editorText: "separate draft").0)
        #expect(repository.fetchActiveNotes(forKey: key).count == 1)
        #expect(repository.fetchActiveNotes(forKey: key).first?.noteText == "separate draft")
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

    // ponytail: APPLICATION grouping supersedes identity-key uniqueness: every
    // existing nonarchived app note loads as a tab; no bulk rewrite happens.
    @Test("Existing app notes all load as tabs without rewriting", arguments: [1, 2])
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
        if candidateCount == 1 {
            #expect(controller.beginSessionIfPossible(for: target) == "saved 0")
        } else {
            let text = controller.beginSessionIfPossible(for: target)
            #expect(text == "saved 0" || text == "saved 1")
        }
        #expect(controller.activeTabNotes.count == candidateCount)
        #expect(repository.fetchActiveNotes(forKey: identity.identityKey).count == candidateCount)
    }

    @Test("Retry flushes a metadata-only recovery draft after its live session is released")
    func metadataOnlyRecoveryRetry() throws {
        let (controller, _) = controller()
        let target = target(axWindow: AXUIElementCreateApplication(getpid()))
        #expect(controller.beginSessionIfPossible(for: target) == "")
        #expect(controller.commitAndSave(editorText: "Saved note").0)
        controller.updateActiveTitle("Updated title")
        let sessionID = try #require(controller.activeSessionUUID)
        controller.closeSession(for: sessionID)
        #expect(controller.activeLiveSessionCount == 0)
        #expect(controller.recoveryDraftCount == 1)
        #expect(controller.retryPendingSaves())
        #expect(controller.recoveryDraftCount == 0)
    }

    // ponytail: APPLICATION grouping supersedes per-document notes: a document
    // change on one window keeps the selected app note.
    @Test("A document change on one window keeps the app note")
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

        #expect(controller.beginSessionIfPossible(for: second) == "note A")
        #expect(controller.activeSessionUUID == firstSession)
        #expect(controller.activeTabNotes.count == 1)
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
        #expect(controller.activeSession?.note.noteText == "")
        #expect(controller.commitAndSave(editorText: "current").0)
        #expect(controller.activeSession?.note.noteText == "current")
        // ponytail: the shared tab keeps its creation identity; it is not
        // re-keyed to the second window's document.
        let firstKey = controller.resolver.resolve(
            bundleIdentifier: first.metadata.bundleIdentifier,
            documentPath: first.metadata.documentPath,
            documentURL: nil,
            windowTitle: first.metadata.windowTitle
        ).identityKey
        let notes = repository.fetchActiveNotes(forKey: firstKey)
        #expect(notes.count == 1)
        #expect(notes.first?.noteText == "current")
        #expect(controller.activeTabNotes.count == 1)
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

    @Test("Different apps keep isolated notebooks and selections")
    func differentAppsIsolated() throws {
        let (controller, _) = controller()
        let pid = NSRunningApplication.current.processIdentifier
        let appA = target(
            axWindow: AXUIElementCreateApplication(pid),
            bundleIdentifier: "com.example.app-a", title: "A", path: "/tmp/A.md"
        )
        let appB = target(
            axWindow: AXUIElementCreateSystemWide(),
            bundleIdentifier: "com.example.app-b", title: "B", path: "/tmp/B.md"
        )
        #expect(controller.beginSessionIfPossible(for: appA) == "")
        #expect(controller.commitAndSave(editorText: "note A").0)
        #expect(controller.beginSessionIfPossible(for: appB) == "")
        #expect(controller.commitAndSave(editorText: "note B").0)
        #expect(controller.activeTabNotes.count == 1)
        #expect(controller.activeTabNotes.first?.noteText == "note B")
        #expect(controller.beginSessionIfPossible(for: appA) == "note A")
        #expect(controller.activeSession?.note.noteText == "note A")
        #expect(controller.activeTabNotes.first?.noteText == "note A")
    }

    @Test("Unidentified apps never merge into one empty-ID notebook")
    func unidentifiedAppsIsolated() throws {
        let (controller, repository) = controller()
        let pid = NSRunningApplication.current.processIdentifier
        let first = target(
            axWindow: AXUIElementCreateApplication(pid),
            bundleIdentifier: "", title: "Draft", path: "/tmp/Draft.md"
        )
        let second = target(
            axWindow: AXUIElementCreateSystemWide(),
            bundleIdentifier: "", title: "Draft", path: "/tmp/Draft.md"
        )
        #expect(controller.beginSessionIfPossible(for: first) == "")
        #expect(controller.commitAndSave(editorText: "window one").0)
        controller.endActiveSession()
        #expect(controller.beginSessionIfPossible(for: second) == "")
        #expect(controller.activeTabNotes.isEmpty)
        #expect(controller.commitAndSave(editorText: "window two").0)
        #expect(try repository.fetchActiveNotesThrowing().count == 2)
    }

    @Test("Existing app notes migrate as tabs in creation order with last-used selection")
    func existingNotesMigration() throws {
        let (controller, repository) = controller()
        let base = Date(timeIntervalSince1970: 1_700_000_000)
        let oldest = WindowNote(
            identityKey: "legacy-a", confidence: .exact,
            bundleIdentifier: "com.example.editor", applicationName: "Editor",
            noteText: "oldest", createdAt: base,
            updatedAt: base, lastOpenedAt: base
        )
        let newest = WindowNote(
            identityKey: "legacy-b", confidence: .exact,
            bundleIdentifier: "com.example.editor", applicationName: "Editor",
            noteText: "newest", createdAt: base.addingTimeInterval(20),
            updatedAt: base.addingTimeInterval(20),
            lastOpenedAt: base.addingTimeInterval(30)
        )
        let middle = WindowNote(
            identityKey: "legacy-c", confidence: .exact,
            bundleIdentifier: "com.example.editor", applicationName: "Editor",
            noteText: "middle", createdAt: base.addingTimeInterval(10),
            updatedAt: base.addingTimeInterval(10),
            lastOpenedAt: base.addingTimeInterval(60)
        )
        let otherApp = WindowNote(
            identityKey: "legacy-x", confidence: .exact,
            bundleIdentifier: "com.example.other", applicationName: "Other",
            noteText: "other"
        )
        let archived = WindowNote(
            identityKey: "legacy-z", confidence: .exact,
            bundleIdentifier: "com.example.editor", applicationName: "Editor",
            noteText: "gone", archived: true
        )
        for note in [oldest, newest, middle, otherApp, archived] {
            repository.insert(note)
        }
        #expect(repository.save().0)
        let window = target(axWindow: AXUIElementCreateApplication(getpid()))
        #expect(controller.beginSessionIfPossible(for: window) == "middle")
        let tabs = controller.activeTabNotes
        #expect(tabs.map(\.noteText) == ["oldest", "middle", "newest"])
        #expect(controller.activeSession?.note.noteText == "middle")
        #expect(tabs.allSatisfy({ $0.bundleIdentifier == "com.example.editor" }))
        #expect(try repository.fetchAppNotesThrowing(forBundleIdentifier: "com.example.editor").count == 3)
    }

    @Test("Tab roundtrip: add, select, archive-on-close, blank discard, last close renews")
    func tabRoundtrip() throws {
        let (controller, repository) = controller()
        let window = target(axWindow: AXUIElementCreateApplication(getpid()))
        #expect(controller.beginSessionIfPossible(for: window) == "")
        #expect(controller.commitAndSave(editorText: "first").0)
        let firstID = try #require(controller.activeSession?.note.id)
        #expect(controller.addTab(editorText: "first"))
        #expect(controller.activeTabNotes.count == 2)
        #expect(controller.activeSession?.note.noteText == "")
        #expect(controller.commitAndSave(editorText: "second").0)
        let secondID = try #require(controller.activeSession?.note.id)
        #expect(secondID != firstID)
        #expect(controller.selectTab(noteID: firstID, editorText: "second"))
        #expect(controller.activeSession?.note.noteText == "first")
        #expect(controller.selectTab(noteID: secondID, editorText: "first"))
        // Closing the nonblank first tab archives it and keeps the second.
        #expect(controller.closeTab(noteID: firstID, editorText: "second"))
        #expect(controller.activeTabNotes.map(\.id) == [secondID])
        #expect(try repository.fetchAppNotesThrowing(forBundleIdentifier: "com.example.editor").count == 1)
        #expect(repository.fetchArchivedNotes().contains { $0.id == firstID && $0.noteText == "first" })
        // Closing the blank-then-last tab discards and renews one empty tab.
        #expect(controller.commitAndSave(editorText: "").0)
        #expect(try repository.fetchAppNotesThrowing(forBundleIdentifier: "com.example.editor").isEmpty)
        let blankID = try #require(controller.activeSession?.note.id)
        #expect(controller.closeTab(noteID: blankID, editorText: ""))
        #expect(controller.activeTabNotes.count == 1)
        #expect(controller.activeSession?.note.noteText == "")
        #expect(controller.activeSession?.note.id != blankID)
    }

    @Test("Failed tab switch and close preserve current text and selection")
    func failedTabSwitchPreservesCurrent() throws {
        let repository = NoteRepository()
        var shouldFail = false
        let failure = NSError(domain: "VersoTests", code: 31)
        let controller = NoteSessionController(
            repository: repository, schedulerFactory: { _, _ in nil },
            reservationLiveness: { _, _ in .alive },
            repositorySave: {
                shouldFail ? (false, failure) : repository.save()
            }
        )
        #expect(controller.openStore(inMemory: true))
        let window = target(axWindow: AXUIElementCreateApplication(getpid()))
        #expect(controller.beginSessionIfPossible(for: window) == "")
        #expect(controller.commitAndSave(editorText: "first").0)
        let firstID = try #require(controller.activeSession?.note.id)
        #expect(controller.addTab(editorText: "first"))
        #expect(controller.commitAndSave(editorText: "second").0)
        let secondID = try #require(controller.activeSession?.note.id)
        shouldFail = true
        #expect(!controller.selectTab(noteID: firstID, editorText: "second edited"))
        #expect(controller.activeSession?.note.id == secondID)
        #expect(controller.activeSession?.note.noteText == "second edited")
        #expect(!controller.addTab(editorText: "second edited"))
        #expect(controller.activeTabNotes.count == 2)
        #expect(controller.activeSession?.note.id == secondID)
        #expect(!controller.closeTab(noteID: firstID, editorText: "second edited"))
        #expect(controller.activeTabNotes.count == 2)
        #expect(controller.activeSession?.note.id == secondID)
        shouldFail = false
        #expect(controller.selectTab(noteID: firstID, editorText: "second edited"))
        #expect(controller.activeSession?.note.noteText == "first")
    }

    @Test("Inactive tabs are saved, recovered, and library-edited without touching the active note")
    func inactiveTabCoverage() throws {
        let (controller, repository) = controller()
        let window = target(axWindow: AXUIElementCreateApplication(getpid()))
        #expect(controller.beginSessionIfPossible(for: window) == "")
        #expect(controller.commitAndSave(editorText: "active one").0)
        #expect(controller.addTab(editorText: "active one"))
        #expect(controller.commitAndSave(editorText: "inactive draft").0)
        let tabs = controller.activeTabNotes
        #expect(tabs.count == 2)
        let inactiveID = try #require(tabs.first?.id)
        let activeID = try #require(controller.activeSession?.note.id)
        #expect(inactiveID != activeID)
        // Background saves cover the inactive tab while the active note stays.
        controller.editorTextDidChange("active two")
        #expect(controller.forceSaveAll())
        #expect(controller.activeSession?.note.noteText == "active two")
        let stored = try repository.fetchAppNotesThrowing(forBundleIdentifier: "com.example.editor")
        #expect(Set(stored.map(\.noteText)) == ["active one", "active two"])
        // Library edits target the inactive tab by fixed ID.
        controller.endActiveSession()
        let start = try #require(controller.beginLibraryEditing(for: tabs[0]))
        controller.libraryEditorTextDidChange("inactive edited", token: start.token)
        #expect(controller.commitLibraryEditorAndSave(editorText: "inactive edited", token: start.token).0)
        #expect(controller.endLibraryEditing(token: start.token))
        #expect(controller.beginSessionIfPossible(for: window) == "active two")
        #expect(controller.selectTab(noteID: inactiveID, editorText: "active two"))
        #expect(controller.activeSession?.note.noteText == "inactive edited")
    }
}

extension NoteSessionControllerTests {
    @Test("Archive write failure keeps the tab, pin metadata and current selection")
    func failedTabArchiveMetadata() throws {
        let repository = NoteRepository()
        var writes = 0, failAt = Int.max
        let controller = NoteSessionController(repository: repository,
            schedulerFactory: { _, _ in nil }, reservationLiveness: { _, _ in .alive },
            repositorySave: {
                writes += 1
                return writes == failAt ? (false, NSError(domain: "SyntheticArchiveFailure", code: 1)) : repository.save()
            })
        #expect(controller.openStore(inMemory: true))
        #expect(controller.beginSessionIfPossible(for: target(axWindow: AXUIElementCreateApplication(getpid()))) == "")
        #expect(controller.commitAndSave(editorText: "first").0)
        #expect(controller.toggleActiveNotePin(editorText: "first").0)
        let first = try #require(controller.activeSession?.note.id)
        #expect(controller.addTab(editorText: "first"))
        #expect(controller.commitAndSave(editorText: "second").0)
        let second = try #require(controller.activeSession?.note.id)
        failAt = writes + 2 // active text saves, then the archive metadata write fails
        #expect(!controller.closeTab(noteID: first, editorText: "second"))
        #expect(controller.activeSession?.note.id == second)
        #expect(controller.activeTabNotes.count == 2)
        let retained = try #require(controller.activeTabNotes.first { $0.id == first })
        #expect(!retained.archived && retained.pinned && retained.noteText == "first")
        failAt = Int.max
        #expect(controller.closeTab(noteID: first, editorText: "second"))
        #expect(repository.fetchArchivedNotes().contains { $0.id == first && $0.pinned })
    }

    @Test("Inactive app tab targets the verified retained window after document changes")
    func inactiveTabLiveTarget() throws {
        let (controller, _) = controller()
        let window = AXUIElementCreateApplication(getpid())
        let original = target(axWindow: window, path: "/tmp/one.md")
        #expect(controller.beginSessionIfPossible(for: original) == "")
        #expect(controller.commitAndSave(editorText: "first").0)
        let first = try #require(controller.activeSession?.note.id)
        #expect(controller.addTab(editorText: "first"))
        #expect(controller.commitAndSave(editorText: "second").0)
        let changed = target(axWindow: window, path: "/tmp/two.md")
        #expect(controller.liveTarget(for: first) != nil)
        #expect(controller.liveTargetMatchesNote(noteID: first, target: changed))
        #expect(!controller.liveTargetMatchesNote(noteID: first, target: target(axWindow: AXUIElementCreateSystemWide())))
        #expect(!controller.liveTargetMatchesNote(noteID: first, target: target(axWindow: window, bundleIdentifier: "com.example.other")))
    }

    @Test("Closed note restores into app tabs and keeps later library edits")
    func restoredTabLibraryDraft() throws {
        let (controller, repository) = controller()
        let window = target(axWindow: AXUIElementCreateApplication(getpid()))
        #expect(controller.beginSessionIfPossible(for: window) == "")
        #expect(controller.commitAndSave(editorText: "archived text").0)
        let id = try #require(controller.activeSession?.note.id)
        #expect(controller.closeTab(noteID: id, editorText: "archived text"))
        controller.endActiveSession()
        let archived = try #require(repository.fetchArchivedNotes().first { $0.id == id })
        let edit = try #require(controller.beginLibraryEditing(for: archived))
        #expect(controller.restoreLibraryNote(noteID: id, editorText: "restored", token: edit.token).0)
        controller.libraryEditorTextDidChange("stale callback", token: edit.token)
        let restored = try #require(try repository.fetchActiveNotesThrowing().first { $0.id == id })
        let reopened = try #require(controller.beginLibraryEditing(for: restored))
        #expect(reopened.text == "restored")
        controller.libraryEditorTextDidChange("latest library text", token: reopened.token)
        #expect(controller.forceSaveAll())
        #expect(controller.endLibraryEditing(token: reopened.token))
        #expect(controller.beginSessionIfPossible(for: window) != nil)
        let selectedText = controller.activeSession!.note.noteText
        #expect(controller.selectTab(noteID: id, editorText: selectedText))
        #expect(controller.activeSession?.note.noteText == "latest library text")
        #expect(controller.forceSaveAll())
        #expect(try repository.fetchAppNotesThrowing(forBundleIdentifier: "com.example.editor").first { $0.id == id }?.noteText == "latest library text")
    }
}
