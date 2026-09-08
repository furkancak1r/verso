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
}
