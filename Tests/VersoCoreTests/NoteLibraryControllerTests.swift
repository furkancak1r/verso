import AppKit
import ApplicationServices
import CoreGraphics
import Testing
@testable import Verso
@testable import VersoCore

@MainActor
@Suite("Note Library")
struct NoteLibraryControllerTests {
    private func temporaryStore() -> (URL, URL) {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("VersoLibraryTests-\(UUID().uuidString)", isDirectory: true)
        return (directory, directory.appendingPathComponent("notes.store"))
    }

    private func controller(
        repositorySave: NoteSessionController.RepositorySave? = nil
    ) -> (NoteSessionController, NoteRepository) {
        let repository = NoteRepository()
        let controller = NoteSessionController(
            repository: repository,
            schedulerFactory: { _, _ in nil },
            reservationLiveness: { _, _ in .alive },
            repositorySave: repositorySave
        )
        #expect(controller.openStore(inMemory: true))
        return (controller, repository)
    }

    private func target(
        axWindow: AXUIElement = AXUIElementCreateSystemWide(),
        path: String = "/tmp/library-note.md"
    ) -> AccessibilityWindowService.ResolvedTargetWindow {
        let application = NSRunningApplication.current
        let metadata = TargetWindowMetadata(
            pid: application.processIdentifier,
            bundleIdentifier: "com.example.library-editor",
            appName: "Synthetic Editor",
            windowTitle: "Library note",
            windowRole: TargetWindowMetadata.windowRole,
            windowSubrole: TargetWindowMetadata.standardWindowSubrole,
            documentPath: path,
            documentURL: nil,
            frame: CGRect(x: 20, y: 20, width: 800, height: 600)
        )
        return AccessibilityWindowService.ResolvedTargetWindow(
            metadata: metadata,
            evidence: HitTestEvidence(hitRole: TargetWindowMetadata.windowRole),
            axWindow: axWindow,
            axApplication: AXUIElementCreateApplication(
                application.processIdentifier
            ),
            runningApplication: application
        )
    }

    @Test("Search covers note, app, title, path, case and Unicode")
    func searchFields() {
        let note = WindowNote(
            identityKey: "identity-is-not-search-normalized",
            confidence: .exact,
            bundleIdentifier: "com.example.editor",
            applicationName: "Éditör",
            windowTitle: "Planning 你好",
            documentPath: "/tmp/Çalışma.md",
            noteText: "Résumé ✅"
        )

        #expect(NoteLibraryController.matches(note, query: "résumé"))
        #expect(NoteLibraryController.matches(note, query: "EDİTÖR"))
        #expect(NoteLibraryController.matches(note, query: "PLANNING 你好"))
        #expect(NoteLibraryController.matches(note, query: "çalışma.md"))
        #expect(NoteLibraryController.matches(note, query: "✅"))
        #expect(!NoteLibraryController.matches(note, query: "unrelated"))
        #expect(NoteLibraryController.matches(note, query: "   "))
        #expect(note.identityKey == "identity-is-not-search-normalized")
    }

    @Test("Repository categories preserve ordering and archive filtering")
    func categoryFetchesAndReopen() throws {
        let (directory, storeURL) = temporaryStore()
        defer { try? FileManager.default.removeItem(at: directory) }

        let first = NoteRepository(storeURL: storeURL)
        #expect(first.openStore())
        let old = Date(timeIntervalSince1970: 100)
        let middle = Date(timeIntervalSince1970: 200)
        let newest = Date(timeIntervalSince1970: 300)
        let recent = WindowNote(
            identityKey: "recent",
            confidence: .exact,
            bundleIdentifier: "com.example.editor",
            applicationName: "Editor",
            noteText: "recent",
            createdAt: old,
            updatedAt: middle,
            lastOpenedAt: newest
        )
        let pinned = WindowNote(
            identityKey: "pinned",
            confidence: .exact,
            bundleIdentifier: "com.example.editor",
            applicationName: "Editor",
            noteText: "pinned",
            createdAt: old,
            updatedAt: newest,
            lastOpenedAt: middle,
            pinned: true
        )
        let archived = WindowNote(
            identityKey: "archived",
            confidence: .exact,
            bundleIdentifier: "com.example.editor",
            applicationName: "Editor",
            noteText: "archived",
            createdAt: old,
            updatedAt: newest,
            lastOpenedAt: newest,
            archived: true
        )
        first.insert(recent)
        first.insert(pinned)
        first.insert(archived)
        #expect(first.save().0)
        let activeRows = try first.fetchActiveNotesThrowing()
        let pinnedRows = try first.fetchPinnedNotesThrowing()
        let archivedRows = try first.fetchArchivedNotesThrowing()
        #expect(activeRows.map(\.id) == [recent.id, pinned.id])
        #expect(pinnedRows.map(\.id) == [pinned.id])
        #expect(archivedRows.map(\.id) == [archived.id])

        first.close()
        let reopened = NoteRepository(storeURL: storeURL)
        #expect(reopened.openStore())
        let reopenedArchived = try #require(
            reopened.fetchArchivedNotesThrowing().first
        )
        reopenedArchived.archived = false
        #expect(reopened.save().0)
        let archivedAfterRestore = try reopened.fetchArchivedNotesThrowing()
        let activeAfterRestore = try reopened.fetchActiveNotesThrowing()
        #expect(archivedAfterRestore.isEmpty)
        #expect(activeAfterRestore.count == 3)
    }

    @Test("Library editor handoff rejects stale callbacks and reuses a live autosave")
    func editorGenerationAndLiveHandoff() throws {
        let (controller, repository) = controller()
        let first = WindowNote(
            identityKey: "library-first",
            confidence: .exact,
            bundleIdentifier: "com.example.editor",
            applicationName: "Editor",
            windowTitle: "First"
        )
        let second = WindowNote(
            identityKey: "library-second",
            confidence: .exact,
            bundleIdentifier: "com.example.editor",
            applicationName: "Editor",
            windowTitle: "Second"
        )
        repository.insert(first)
        repository.insert(second)
        #expect(repository.save().0)

        let firstStart = try #require(controller.beginLibraryEditing(for: first))
        controller.libraryEditorTextDidChange("first text", token: firstStart.token)
        // The existing editor must be explicitly committed before a switch.
        #expect(controller.beginLibraryEditing(for: second) == nil)
        #expect(controller.commitLibraryEditorAndSave(
            editorText: "first text",
            token: firstStart.token
        ).0)
        #expect(controller.endLibraryEditing(token: firstStart.token))

        let secondStart = try #require(controller.beginLibraryEditing(for: second))
        controller.libraryEditorTextDidChange("stale", token: firstStart.token)
        controller.libraryEditorTextDidChange("second text", token: secondStart.token)
        #expect(controller.commitLibraryEditorAndSave(
            editorText: "second text",
            token: secondStart.token
        ).0)
        #expect(controller.endLibraryEditing(token: secondStart.token))
        #expect(first.noteText == "first text")
        #expect(second.noteText == "second text")

        let liveTarget = target(path: "/tmp/live-library.md")
        #expect(controller.beginSessionIfPossible(for: liveTarget) == "")
        #expect(controller.commitAndSave(editorText: "live original").0)
        let liveNote = try #require(controller.activeSession?.note)
        controller.endActiveSession()
        let liveStart = try #require(controller.beginLibraryEditing(for: liveNote))
        #expect(liveStart.text == "live original")
        controller.libraryEditorTextDidChange("library update", token: liveStart.token)
        #expect(controller.commitLibraryEditorAndSave(
            editorText: "library update",
            token: liveStart.token
        ).0)
        #expect(controller.endLibraryEditing(token: liveStart.token))
        #expect(controller.beginSessionIfPossible(for: liveTarget) == "library update")
    }

    @Test("A failed library save keeps text and retries the same context")
    func failedLibrarySaveRetainsDraft() throws {
        let repository = NoteRepository()
        var shouldFail = true
        let failure = NSError(
            domain: "VersoLibraryTests",
            code: 1,
            userInfo: [NSLocalizedDescriptionKey: "synthetic library write failure"]
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
        let note = WindowNote(
            identityKey: "recoverable-library",
            confidence: .exact,
            bundleIdentifier: "com.example.editor",
            applicationName: "Editor"
        )
        repository.insert(note)
        #expect(repository.save().0)

        let start = try #require(controller.beginLibraryEditing(for: note))
        controller.libraryEditorTextDidChange("retained draft", token: start.token)
        #expect(!controller.commitLibraryEditorAndSave(
            editorText: "retained draft",
            token: start.token
        ).0)
        #expect(controller.libraryEditorToken == start.token)
        #expect(controller.libraryEditorText == "retained draft")
        #expect(controller.hasUnsavedLibraryChanges)
        #expect(!controller.forceSaveAll())

        shouldFail = false
        #expect(controller.retryPendingSaves())
        #expect(controller.forceSaveAll())
        #expect(!controller.hasUnsavedLibraryChanges)
        #expect(note.noteText == "retained draft")
    }

    @Test("Pin, archive and restore persist through reopening before delete")
    func persistentLibraryMutations() throws {
        let (directory, storeURL) = temporaryStore()
        defer { try? FileManager.default.removeItem(at: directory) }

        let repository = NoteRepository(storeURL: storeURL)
        #expect(repository.openStore())
        let controller = NoteSessionController(
            repository: repository,
            schedulerFactory: { _, _ in nil },
            reservationLiveness: { _, _ in .alive }
        )
        let note = WindowNote(
            identityKey: "persistent-library-actions",
            confidence: .exact,
            bundleIdentifier: "com.example.editor",
            applicationName: "Editor",
            windowTitle: "Persistent",
            noteText: "before actions"
        )
        repository.insert(note)
        #expect(repository.save().0)

        let pinStart = try #require(controller.beginLibraryEditing(for: note))
        #expect(controller.toggleLibraryPin(
            noteID: note.id,
            editorText: "pinned text",
            token: pinStart.token
        ).0)
        #expect(note.pinned)
        #expect(controller.endLibraryEditing(token: pinStart.token))

        let archiveStart = try #require(controller.beginLibraryEditing(for: note))
        #expect(controller.archiveLibraryNote(
            noteID: note.id,
            editorText: "archived text",
            token: archiveStart.token
        ).0)
        #expect(note.archived)

        repository.close()
        let reopened = NoteRepository(storeURL: storeURL)
        #expect(reopened.openStore())
        let archived = try #require(reopened.fetchArchivedNotesThrowing().first)
        #expect(archived.pinned)
        #expect(archived.noteText == "archived text")

        let reopenedController = NoteSessionController(
            repository: reopened,
            schedulerFactory: { _, _ in nil },
            reservationLiveness: { _, _ in .alive }
        )
        let restoreStart = try #require(
            reopenedController.beginLibraryEditing(for: archived)
        )
        #expect(reopenedController.restoreLibraryNote(
            noteID: archived.id,
            editorText: "restored text",
            token: restoreStart.token
        ).0)
        let active = try reopened.fetchActiveNotesThrowing()
        #expect(active.count == 1)
        #expect(active[0].noteText == "restored text")
        #expect(active[0].pinned)

        let deleteStart = try #require(
            reopenedController.beginLibraryEditing(for: active[0])
        )
        #expect(reopenedController.deleteLibraryNote(
            noteID: active[0].id,
            editorText: "restored text",
            token: deleteStart.token
        ).0)
        let afterDelete = try reopened.fetchActiveNotesThrowing()
        #expect(afterDelete.isEmpty)
        reopened.close()
        let finalOpen = NoteRepository(storeURL: storeURL)
        #expect(finalOpen.openStore())
        let finalRows = try finalOpen.fetchActiveNotesThrowing()
        #expect(finalRows.isEmpty)
    }

    @Test("A failed delete rolls back only the isolated deletion")
    func failedDeleteRecovery() throws {
        let repository = NoteRepository()
        var saveCall = 0
        let failure = NSError(
            domain: "VersoLibraryTests",
            code: 2,
            userInfo: [NSLocalizedDescriptionKey: "synthetic delete failure"]
        )
        let controller = NoteSessionController(
            repository: repository,
            schedulerFactory: { _, _ in nil },
            reservationLiveness: { _, _ in .alive },
            repositorySave: {
                saveCall += 1
                return saveCall == 3 ? (false, failure) : repository.save()
            }
        )
        #expect(controller.openStore(inMemory: true))
        let note = WindowNote(
            identityKey: "delete-recovery",
            confidence: .exact,
            bundleIdentifier: "com.example.editor",
            applicationName: "Editor",
            noteText: "keep this"
        )
        repository.insert(note)
        #expect(repository.save().0)
        let start = try #require(controller.beginLibraryEditing(for: note))

        let failed = controller.deleteLibraryNote(
            noteID: note.id,
            editorText: "keep this",
            token: start.token
        )
        #expect(!failed.0)
        #expect(controller.libraryEditorToken == start.token)
        let afterFailedDelete = try repository.fetchActiveNotesThrowing()
        #expect(afterFailedDelete.contains { $0.id == note.id })
        #expect(note.noteText == "keep this")

        #expect(controller.retryPendingSaves())
        let afterRetry = try repository.fetchActiveNotesThrowing()
        #expect(afterRetry.contains { $0.id == note.id })

        let deleted = controller.deleteLibraryNote(
            noteID: note.id,
            editorText: "keep this",
            token: start.token
        )
        #expect(deleted.0)
        let afterDelete = try repository.fetchActiveNotesThrowing()
        #expect(!afterDelete.contains { $0.id == note.id })
    }

    @Test("Show Window validation uses the retained target and rejects a changed document")
    func validatedShowWindowRouting() throws {
        let (controller, repository) = controller()
        let live = target(path: "/tmp/show-window-a.md")
        #expect(controller.beginSessionIfPossible(for: live) == "")
        #expect(controller.commitAndSave(editorText: "show me").0)
        let note = try #require(controller.activeSession?.note)
        controller.endActiveSession()

        var refreshCount = 0
        var raiseCount = 0
        let goodService = AccessibilityWindowService(
            refreshOverride: { target in
                refreshCount += 1
                return .current(target)
            },
            raiseOverride: { _ in
                raiseCount += 1
                return true
            }
        )
        let library = NoteLibraryController(
            noteSessionController: controller,
            accessibilityWindowService: goodService,
            prepareOverlayForLibrary: { true }
        )
        #expect(library.validatedLiveTarget(for: note) != nil)
        #expect(refreshCount == 1)
        let retained = try #require(controller.liveTarget(for: note.id))
        #expect(goodService.raiseTarget(retained))
        #expect(raiseCount == 1)

        let wrong = AccessibilityWindowService.ResolvedTargetWindow(
            metadata: TargetWindowMetadata(
                pid: live.metadata.pid,
                bundleIdentifier: live.metadata.bundleIdentifier,
                appName: live.metadata.appName,
                windowTitle: "Other document",
                windowRole: TargetWindowMetadata.windowRole,
                windowSubrole: TargetWindowMetadata.standardWindowSubrole,
                documentPath: "/tmp/show-window-b.md",
                documentURL: nil,
                frame: live.metadata.frame
            ),
            evidence: live.evidence,
            axWindow: live.axWindow,
            axApplication: live.axApplication,
            runningApplication: live.runningApplication
        )
        let wrongService = AccessibilityWindowService(
            refreshOverride: { _ in .current(wrong) },
            raiseOverride: { _ in
                Issue.record("Raise must not run for a different document")
                return true
            }
        )
        let wrongLibrary = NoteLibraryController(
            noteSessionController: controller,
            accessibilityWindowService: wrongService,
            prepareOverlayForLibrary: { true }
        )
        #expect(wrongLibrary.validatedLiveTarget(for: note) == nil)
        #expect(repository.fetchActiveNotes(forKey: note.identityKey).count == 1)
    }
}

@MainActor
extension NoteLibraryControllerTests {
    @Test("Native scoped search keeps archived and pinned notes searchable")
    func nativeScopedSearch() throws {
        _ = NSApplication.shared
        let (sessions, repository) = controller()
        for index in 0..<2 {
            let note = WindowNote(
                identityKey: "native-scope-\(index)", confidence: .sessionOnly,
                bundleIdentifier: "com.example.synthetic", applicationName: "Synthetic",
                windowTitle: "Match \(index)", pinned: index == 0, archived: index == 1
            )
            repository.insert(note)
        }
        #expect(repository.save().0)
        let library = NoteLibraryController(
            noteSessionController: sessions,
            accessibilityWindowService: AccessibilityWindowService(refreshOverride: { _ in .invalid }),
            prepareOverlayForLibrary: { true }
        )
        let view = library.loadContentView()
        let controls = descendants(view)
        let scope = try #require(controls.compactMap { $0 as? NSSegmentedControl }.first)
        let search = try #require(controls.compactMap { $0 as? NSSearchField }.first)
        for (segment, category, title) in [(3, NoteLibraryController.Category.archived, "Match 1"), (2, .pinned, "Match 0")] {
            scope.selectedSegment = segment
            #expect(NSApp.sendAction(try #require(scope.action), to: scope.target, from: scope))
            search.stringValue = title.lowercased()
            library.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification, object: search))
            #expect(library.currentCategory == category)
            #expect(library.displayedNotes.map(\.windowTitle) == [title])
        }
        #expect(library.forceSaveForQuit())
    }

    @Test("Native library editor fills available width at both supported sizes")
    func nativeLibraryLayout() throws {
        _ = NSApplication.shared
        let (sessions, repository) = controller()
        let note = WindowNote(identityKey: "native-layout", confidence: .sessionOnly,
                              bundleIdentifier: "com.example.synthetic", applicationName: "Synthetic", pinned: true)
        repository.insert(note)
        #expect(repository.save().0)
        let library = NoteLibraryController(
            noteSessionController: sessions,
            accessibilityWindowService: AccessibilityWindowService(refreshOverride: { _ in .invalid }),
            prepareOverlayForLibrary: { true }
        )
        let view = library.loadContentView()
        let scope = try #require(descendants(view).compactMap { $0 as? NSSegmentedControl }.first)
        scope.selectedSegment = 2
        #expect(NSApp.sendAction(try #require(scope.action), to: scope.target, from: scope))
        let editor = try #require(descendants(view).compactMap { $0 as? NativeNoteEditor }.first)
        let canvas = NSView(frame: NSRect(x: 0, y: 0, width: 860, height: 560))
        canvas.addSubview(view)
        NSLayoutConstraint.activate([
            view.leadingAnchor.constraint(equalTo: canvas.leadingAnchor),
            view.trailingAnchor.constraint(equalTo: canvas.trailingAnchor),
            view.topAnchor.constraint(equalTo: canvas.topAnchor),
            view.bottomAnchor.constraint(equalTo: canvas.bottomAnchor)
        ])
        for size in [NSSize(width: 860, height: 560), NSSize(width: 700, height: 440)] {
            canvas.setFrameSize(size)
            canvas.layoutSubtreeIfNeeded()
            let frame = view.convert(editor.bounds, from: editor)
            #expect(abs(frame.maxX - (size.width - 20)) < 1)
            #expect(frame.height > 180)
        }
        #expect(library.forceSaveForQuit())
    }

    private func descendants(_ view: NSView) -> [NSView] {
        view.subviews.flatMap { [$0] + descendants($0) }
    }

    @Test("Native autosave status and live handoff preserve the latest scheduled edit")
    func nativeAutosaveAndLiveHandoff() throws {
        _ = NSApplication.shared
        let repository = NoteRepository()
        var scheduled: [() -> Void] = []
        var fail = false
        let failure = NSError(domain: "VersoLibraryTests", code: 3,
                              userInfo: [NSLocalizedDescriptionKey: "Synthetic autosave failure"])
        let sessions = NoteSessionController(
            repository: repository,
            schedulerFactory: { _, callback in scheduled.append(callback); return nil },
            reservationLiveness: { _, _ in .alive },
            repositorySave: { fail ? (false, failure) : repository.save() }
        )
        #expect(sessions.openStore(inMemory: true))
        let live = target(path: "/tmp/native-library-handoff.md")
        #expect(sessions.beginSessionIfPossible(for: live) == "")
        #expect(sessions.toggleActiveNotePin(editorText: "original").0)
        #expect(sessions.yieldActiveOverlay(editorText: "original"))
        let library = NoteLibraryController(
            noteSessionController: sessions,
            accessibilityWindowService: AccessibilityWindowService(refreshOverride: { _ in .invalid }),
            prepareOverlayForLibrary: { true }
        )
        sessions.onSaveErrorChanged = { [weak library] _ in library?.saveStateDidChange() }
        let view = library.loadContentView()
        let controls = descendants(view)
        let scope = try #require(controls.compactMap { $0 as? NSSegmentedControl }.first)
        let editor = try #require(controls.compactMap { $0 as? NativeNoteEditor }.first)
        let retry = try #require(controls.compactMap { $0 as? NSButton }.first { $0.title == L("common.retry") })
        scope.selectedSegment = 2
        #expect(NSApp.sendAction(try #require(scope.action), to: scope.target, from: scope))
        fail = true
        editor.textView.string = "first library edit"
        editor.textDidChange(Notification(name: NSText.didChangeNotification, object: editor.textView))
        let oldCallback = try #require(scheduled.last)
        oldCallback()
        #expect(!retry.isHidden)
        #expect(controls.compactMap { $0 as? NSTextField }.contains {
            $0.stringValue.contains("Synthetic autosave failure")
        })
        fail = false
        editor.textView.string = "latest library edit ✅"
        editor.textDidChange(Notification(name: NSText.didChangeNotification, object: editor.textView))
        let latestCallback = try #require(scheduled.last)
        latestCallback()
        #expect(retry.isHidden)
        #expect(sessions.lastSaveError == nil)
        #expect(library.prepareForOverlay())
        #expect(sessions.beginSessionIfPossible(for: live) == "latest library edit ✅")
        oldCallback()
        #expect(sessions.activeSession?.note.noteText == "latest library edit ✅")
        #expect(sessions.forceSaveAll())
    }
}
