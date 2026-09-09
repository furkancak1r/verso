import Foundation
import Testing
@testable import VersoCore

@MainActor
@Suite("NoteRepository")
struct NoteRepositoryTests {
    private func temporaryStore() -> (URL, URL) {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("VersoTests-\(UUID().uuidString)", isDirectory: true)
        return (directory, directory.appendingPathComponent("notes.store"))
    }

    @Test("In-memory store disables autosave and permits duplicate identity keys")
    func inMemoryDuplicates() {
        let repository = NoteRepository()
        #expect(repository.openStore(inMemory: true))
        #expect(repository.context?.autosaveEnabled == false)

        let first = WindowNote(
            identityKey: "same-key",
            confidence: .exact,
            bundleIdentifier: "com.example.editor",
            applicationName: "Editor",
            noteText: "one"
        )
        let second = WindowNote(
            identityKey: "same-key",
            confidence: .exact,
            bundleIdentifier: "com.example.editor",
            applicationName: "Editor",
            noteText: "two"
        )
        repository.insert(first)
        repository.insert(second)
        #expect(repository.save().0)
        #expect(repository.fetchActiveNotes(forKey: "same-key").count == 2)
        #expect(repository.fetchSoleCandidate(forKey: "same-key") == nil)
    }

    @Test("A unique temporary on-disk store reopens with text and metadata")
    func onDiskReopen() throws {
        let (directory, storeURL) = temporaryStore()
        defer { try? FileManager.default.removeItem(at: directory) }

        let id = UUID()
        let first = NoteRepository(storeURL: storeURL)
        #expect(first.openStore())
        let note = WindowNote(
            id: id,
            identityKey: "reopen-key",
            confidence: .exact,
            bundleIdentifier: "com.example.editor",
            applicationName: "Editor",
            windowTitle: "Draft",
            documentPath: "/tmp/Draft.md",
            noteText: "Unicode ✅ 你好",
            pinned: true
        )
        first.insert(note)
        #expect(first.save().0)
        first.close()

        let reopened = NoteRepository(storeURL: storeURL)
        #expect(reopened.openStore())
        let candidates = try reopened.fetchActiveNotesThrowing(forKey: "reopen-key")
        #expect(candidates.count == 1)
        #expect(candidates[0].id == id)
        #expect(candidates[0].noteText == "Unicode ✅ 你好")
        #expect(candidates[0].pinned)
        #expect(candidates[0].documentPath == "/tmp/Draft.md")

        candidates[0].archived = true
        #expect(reopened.save().0)
        #expect(reopened.fetchActiveNotes(forKey: "reopen-key").isEmpty)
        #expect(reopened.fetchArchivedNotes(forKey: "reopen-key").count == 1)
    }

    @Test("Archived rows do not become restore candidates")
    func archivedExcluded() {
        let repository = NoteRepository()
        #expect(repository.openStore(inMemory: true))
        let note = WindowNote(
            identityKey: "archive-key",
            confidence: .exact,
            bundleIdentifier: "com.example.editor",
            applicationName: "Editor",
            archived: true
        )
        repository.insert(note)
        #expect(repository.save().0)
        #expect(repository.fetchActiveNotes(forKey: "archive-key").isEmpty)
    }

    @Test("A failed open does not substitute an in-memory store")
    func failedOpenDoesNotFallback() {
        let repository = NoteRepository(
            storeURL: URL(fileURLWithPath: "/dev/null/verso-invalid.store")
        )
        #expect(!repository.openStore())
        #expect(!repository.isReady)
        if case .failed = repository.state {
            #expect(Bool(true))
        } else {
            #expect(Bool(false), "failed open did not retain its error state")
        }
    }

    @Test("Empty new drafts persist nothing on disk; raw blank rows are not bulk-cleaned")
    func emptyNewDraftsAbsentAfterReopen() throws {
        let (directory, storeURL) = temporaryStore()
        defer { try? FileManager.default.removeItem(at: directory) }
        let repository = NoteRepository(storeURL: storeURL)
        #expect(repository.openStore())

        let empty = WindowNote(
            identityKey: "empty-key",
            confidence: .exact,
            bundleIdentifier: "com.example.editor",
            applicationName: "Editor",
            noteText: ""
        )
        let whitespace = WindowNote(
            identityKey: "whitespace-key",
            confidence: .exact,
            bundleIdentifier: "com.example.editor",
            applicationName: "Editor",
            noteText: "  \n\t  "
        )
        let pinnedBlank = WindowNote(
            identityKey: "pinned-blank-key",
            confidence: .exact,
            bundleIdentifier: "com.example.editor",
            applicationName: "Editor",
            noteText: "   ",
            pinned: true
        )
        #expect(repository.saveDraft(empty).0)
        #expect(repository.saveDraft(whitespace).0)
        #expect(repository.saveDraft(pinnedBlank).0)
        // Metadata stays in the detached draft for Undo even though nothing is stored.
        #expect(empty.noteText.isEmpty)
        #expect(whitespace.noteText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        #expect(pinnedBlank.pinned)
        #expect(pinnedBlank.noteText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        repository.close()

        let reopened = NoteRepository(storeURL: storeURL)
        #expect(reopened.openStore())
        #expect(try reopened.fetchActiveNotesThrowing(forKey: "empty-key").isEmpty)
        #expect(try reopened.fetchActiveNotesThrowing(forKey: "whitespace-key").isEmpty)
        #expect(try reopened.fetchActiveNotesThrowing(forKey: "pinned-blank-key").isEmpty)
        #expect(reopened.fetchPinnedNotes().isEmpty)

        // Raw insert still seeds a legacy blank row, and saving another empty
        // draft for the same key removes only its own UUID row.
        let legacy = WindowNote(
            identityKey: "legacy-key",
            confidence: .exact,
            bundleIdentifier: "com.example.editor",
            applicationName: "Editor",
            noteText: ""
        )
        reopened.insert(legacy)
        #expect(reopened.save().0)
        #expect(try reopened.fetchActiveNotesThrowing(forKey: "legacy-key").count == 1)
        let otherEmpty = WindowNote(
            identityKey: "legacy-key",
            confidence: .exact,
            bundleIdentifier: "com.example.editor",
            applicationName: "Editor",
            noteText: " \n "
        )
        #expect(reopened.saveDraft(otherEmpty).0)
        let remaining = try reopened.fetchActiveNotesThrowing(forKey: "legacy-key")
        #expect(remaining.count == 1)
        #expect(remaining[0].id == legacy.id)
    }

    @Test("Nonblank draft persists exactly; clearing deletes; same draft restores same UUID")
    func nonblankDraftClearAndRestoreSameUUID() throws {
        let repository = NoteRepository()
        #expect(repository.openStore(inMemory: true))
        let originalText = "  hello ✅ 你好  \nworld  "
        let draft = WindowNote(
            identityKey: "roundtrip-key",
            confidence: .exact,
            bundleIdentifier: "com.example.editor",
            applicationName: "Editor",
            windowTitle: "Draft",
            documentPath: "/tmp/Draft.md",
            noteText: originalText,
            pinned: true
        )
        let copy = draft.detachedCopy()
        #expect(copy.id == draft.id)
        #expect(copy.identityKey == draft.identityKey)
        #expect(copy.confidenceRaw == draft.confidenceRaw)
        #expect(copy.bundleIdentifier == draft.bundleIdentifier)
        #expect(copy.applicationName == draft.applicationName)
        #expect(copy.windowTitle == draft.windowTitle)
        #expect(copy.documentPath == draft.documentPath)
        #expect(copy.noteText == draft.noteText)
        #expect(copy.createdAt == draft.createdAt)
        #expect(copy.updatedAt == draft.updatedAt)
        #expect(copy.lastOpenedAt == draft.lastOpenedAt)
        #expect(copy.pinned == draft.pinned)
        #expect(copy.archived == draft.archived)
        #expect(copy !== draft)

        #expect(repository.saveDraft(draft).0)
        var stored = try repository.fetchActiveNotesThrowing(forKey: "roundtrip-key")
        #expect(stored.count == 1)
        #expect(stored[0].id == draft.id)
        #expect(stored[0].noteText == originalText)
        #expect(stored[0].windowTitle == "Draft")
        #expect(stored[0].documentPath == "/tmp/Draft.md")
        #expect(stored[0].pinned)
        #expect(stored[0] !== draft)

        draft.noteText = ""
        #expect(repository.saveDraft(draft, save: { repository.save() }).0)
        #expect(repository.fetchActiveNotes(forKey: "roundtrip-key").isEmpty)
        #expect(draft.noteText.isEmpty)

        draft.noteText = originalText
        #expect(repository.saveDraft(draft).0)
        stored = try repository.fetchActiveNotesThrowing(forKey: "roundtrip-key")
        #expect(stored.count == 1)
        #expect(stored[0].id == draft.id)
        #expect(stored[0].noteText == originalText)
        #expect(stored[0].windowTitle == "Draft")
        #expect(stored[0].documentPath == "/tmp/Draft.md")
        #expect(stored[0].pinned)
    }

    @Test("Failed empty deletion keeps stored content and unrelated note; retry deletes")
    func failedEmptyDeletionKeepsStoredContent() throws {
        let repository = NoteRepository()
        #expect(repository.openStore(inMemory: true))
        let syntheticError: Error = NSError(domain: "VersoTests", code: 7, userInfo: nil)

        let draft = WindowNote(
            identityKey: "fail-key",
            confidence: .exact,
            bundleIdentifier: "com.example.editor",
            applicationName: "Editor",
            noteText: "keep me"
        )
        let unrelated = WindowNote(
            identityKey: "other-key",
            confidence: .exact,
            bundleIdentifier: "com.example.editor",
            applicationName: "Editor",
            noteText: "other"
        )
        #expect(repository.saveDraft(draft).0)
        #expect(repository.saveDraft(unrelated).0)

        draft.noteText = "  \n\t "
        let failed: (Bool, Error?) = repository.saveDraft(draft, save: { () -> (Bool, Error?) in (false, syntheticError) })
        #expect(!failed.0)
        #expect(failed.1 != nil)
        // The detached draft stays empty for retry while storage rolls back.
        #expect(draft.noteText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        #expect(try repository.fetchActiveNotesThrowing(forKey: "fail-key").count == 1)
        #expect(try repository.fetchActiveNotesThrowing(forKey: "fail-key")[0].noteText == "keep me")
        #expect(try repository.fetchActiveNotesThrowing(forKey: "other-key")[0].noteText == "other")

        // A later unrelated save must not commit the rolled-back deletion.
        let otherStored = try repository.fetchActiveNotesThrowing(forKey: "other-key")
        otherStored[0].noteText = "other v2"
        #expect(repository.save().0)
        #expect(try repository.fetchActiveNotesThrowing(forKey: "fail-key")[0].noteText == "keep me")
        #expect(try repository.fetchActiveNotesThrowing(forKey: "other-key")[0].noteText == "other v2")

        #expect(repository.saveDraft(draft).0)
        #expect(repository.fetchActiveNotes(forKey: "fail-key").isEmpty)
        #expect(draft.noteText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        #expect(try repository.fetchActiveNotesThrowing(forKey: "other-key")[0].noteText == "other v2")
    }

    @Test("Application notebooks group nonarchived notes by bundleIdentifier")
    func appNotebookGrouping() throws {
        let repository = NoteRepository()
        #expect(repository.openStore(inMemory: true))
        let first = WindowNote(
            identityKey: "k1", confidence: .exact,
            bundleIdentifier: "com.example.app", applicationName: "App",
            noteText: "one"
        )
        let second = WindowNote(
            identityKey: "k2", confidence: .exact,
            bundleIdentifier: "com.example.app", applicationName: "App",
            noteText: "two"
        )
        let archived = WindowNote(
            identityKey: "k3", confidence: .exact,
            bundleIdentifier: "com.example.app", applicationName: "App",
            noteText: "old", archived: true
        )
        let other = WindowNote(
            identityKey: "k4", confidence: .exact,
            bundleIdentifier: "com.example.other", applicationName: "Other",
            noteText: "other"
        )
        for note in [first, second, archived, other] {
            repository.insert(note)
        }
        #expect(repository.save().0)
        let appNotes = try repository.fetchAppNotesThrowing(forBundleIdentifier: "com.example.app")
        #expect(appNotes.count == 2)
        #expect(Set(appNotes.map(\.noteText)) == ["one", "two"])
        #expect(repository.fetchAppNotes(forBundleIdentifier: "com.example.other").count == 1)
        #expect(repository.fetchAppNotes(forBundleIdentifier: "com.example.missing").isEmpty)
    }
}
