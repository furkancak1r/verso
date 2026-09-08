import Foundation
import SwiftData

/// SwiftData persistence for Verso notes.
///
/// The repository owns a real on-disk store in normal application use. Tests
/// must opt into an in-memory store or provide their own temporary URL.
@MainActor
public final class NoteRepository: Sendable {
    public enum StoreState {
        case notConfigured
        case ready
        case failed(Error)
    }

    public enum RepositoryError: LocalizedError {
        case storeNotOpen

        public var errorDescription: String? {
            switch self {
            case .storeNotOpen:
                return L("error.storeNotOpen")
            }
        }
    }

    public private(set) var state: StoreState = .notConfigured
    public private(set) var container: ModelContainer?
    public private(set) var context: ModelContext?
    public private(set) var lastError: Error?
    public let storeURL: URL

    /// The default Application Support location used only by the app.
    public static var defaultStoreURL: URL {
        let support = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first ?? URL(fileURLWithPath: "/Library/Application Support")
        return support
            .appendingPathComponent("Verso", isDirectory: true)
            .appendingPathComponent("WindowNotes.store", isDirectory: false)
    }

    public init(storeURL: URL? = nil) {
        self.storeURL = storeURL ?? Self.defaultStoreURL
    }

    /// Open the configured store. A failed open never changes to memory and
    /// never deletes or resets an existing store.
    @discardableResult
    public func openStore(inMemory: Bool = false) -> Bool {
        if case .ready = state { return true }

        do {
            let schema = Schema([WindowNote.self])
            let configuration: ModelConfiguration

            if inMemory {
                configuration = ModelConfiguration(
                    isStoredInMemoryOnly: true,
                    cloudKitDatabase: .none
                )
            } else {
                let parent = storeURL.deletingLastPathComponent()
                try FileManager.default.createDirectory(
                    at: parent,
                    withIntermediateDirectories: true
                )
                configuration = ModelConfiguration(
                    url: storeURL,
                    cloudKitDatabase: .none
                )
            }

            let newContainer = try ModelContainer(
                for: schema,
                configurations: configuration
            )
            let newContext = newContainer.mainContext
            newContext.autosaveEnabled = false

            container = newContainer
            context = newContext
            lastError = nil
            state = .ready
            return true
        } catch {
            // Keep any existing ready context intact. In the normal failed
            // startup case these are nil, and the caller disables triggering.
            lastError = error
            state = .failed(error)
            return false
        }
    }

    /// Retry the same store configuration after a visible startup failure.
    @discardableResult
    public func retryOpen(inMemory: Bool = false) -> Bool {
        switch state {
        case .ready:
            return true
        case .notConfigured, .failed:
            return openStore(inMemory: inMemory)
        }
    }

    /// Release the current context without touching the store on disk.
    public func close() {
        context = nil
        container = nil
        state = .notConfigured
    }

    public var isReady: Bool {
        if case .ready = state { return context != nil }
        return false
    }

    // MARK: - Fetch

    /// Fetch active notes. Read failures are retained in `lastError`; callers
    /// that need to distinguish a read failure should use the throwing method.
    public func fetchActiveNotes(forKey key: String) -> [WindowNote] {
        do {
            return try fetchActiveNotesThrowing(forKey: key)
        } catch {
            lastError = error
            return []
        }
    }

    public func fetchActiveNotesThrowing(forKey key: String) throws -> [WindowNote] {
        guard let context else { throw RepositoryError.storeNotOpen }
        return try context.fetch(WindowNote.fetchActive(forIdentityKey: key))
    }

    public func fetchArchivedNotes(forKey key: String) -> [WindowNote] {
        do {
            return try fetchArchivedNotesThrowing(forKey: key)
        } catch {
            lastError = error
            return []
        }
    }

    public func fetchArchivedNotesThrowing(forKey key: String) throws -> [WindowNote] {
        guard let context else { throw RepositoryError.storeNotOpen }
        return try context.fetch(WindowNote.fetchArchived(forIdentityKey: key))
    }

    /// Fetch active notes in the order used by the Recent library view.
    public func fetchActiveNotesThrowing() throws -> [WindowNote] {
        guard let context else { throw RepositoryError.storeNotOpen }
        return try context.fetch(FetchDescriptor<WindowNote>(
            predicate: #Predicate { note in !note.archived },
            sortBy: [
                SortDescriptor(\.lastOpenedAt, order: .reverse),
                SortDescriptor(\.updatedAt, order: .reverse)
            ]
        ))
    }

    public func fetchActiveNotes() -> [WindowNote] {
        do {
            return try fetchActiveNotesThrowing()
        } catch {
            lastError = error
            return []
        }
    }

    /// Fetch active pinned notes. Archived rows are intentionally excluded.
    public func fetchPinnedNotesThrowing() throws -> [WindowNote] {
        guard let context else { throw RepositoryError.storeNotOpen }
        return try context.fetch(FetchDescriptor<WindowNote>(
            predicate: #Predicate { note in note.pinned && !note.archived },
            sortBy: [
                SortDescriptor(\.lastOpenedAt, order: .reverse),
                SortDescriptor(\.updatedAt, order: .reverse)
            ]
        ))
    }

    public func fetchPinnedNotes() -> [WindowNote] {
        do {
            return try fetchPinnedNotesThrowing()
        } catch {
            lastError = error
            return []
        }
    }

    /// Fetch archived notes in the order used by the Archived library view.
    public func fetchArchivedNotesThrowing() throws -> [WindowNote] {
        guard let context else { throw RepositoryError.storeNotOpen }
        return try context.fetch(FetchDescriptor<WindowNote>(
            predicate: #Predicate { note in note.archived },
            sortBy: [
                SortDescriptor(\.updatedAt, order: .reverse),
                SortDescriptor(\.createdAt, order: .reverse)
            ]
        ))
    }

    public func fetchArchivedNotes() -> [WindowNote] {
        do {
            return try fetchArchivedNotesThrowing()
        } catch {
            lastError = error
            return []
        }
    }

    /// Fetch exactly one active candidate. Multiple rows intentionally return
    /// nil instead of selecting by recency.
    public func fetchSoleCandidate(forKey key: String) -> WindowNote? {
        do {
            let candidates = try fetchActiveNotesThrowing(forKey: key)
            return candidates.count == 1 ? candidates[0] : nil
        } catch {
            lastError = error
            return nil
        }
    }

    // MARK: - Mutation

    public func insert(_ note: WindowNote) {
        context?.insert(note)
    }

    /// Commit pending changes with autosave disabled. Failed saves leave the
    /// model and its latest text in the context for a later retry.
    @discardableResult
    public func save() -> (Bool, Error?) {
        guard let context else {
            let error = RepositoryError.storeNotOpen
            lastError = error
            return (false, error)
        }

        do {
            try context.save()
            lastError = nil
            return (true, nil)
        } catch {
            lastError = error
            return (false, error)
        }
    }

    public func delete(_ note: WindowNote) {
        context?.delete(note)
    }

    /// Undo a failed delete after the caller has flushed all other pending
    /// work. ModelContext has no per-model undo for a deletion; keeping this
    /// operation explicit prevents a later autosave from committing a delete
    /// that the user was told had failed.
    public func rollbackFailedDeletion() {
        context?.rollback()
    }
}
