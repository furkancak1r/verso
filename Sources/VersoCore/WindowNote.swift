import Foundation
import SwiftData

/// Persistent note associated with a window identity.
///
/// UUID-unique. Minimal requested metadata only. No pixels, PID, AX
/// references, content logs, or dependencies. identityKey is intentionally
/// nonunique — multiple WindowNote rows can share an identity key (e.g.
/// archived vs active).
@Model
public final class WindowNote {
    /// Unique identifier for this note row.
    @Attribute(.unique) public var id: UUID

    /// Deterministic identity key from WindowIdentityResolver.
    /// Not unique: multiple rows (e.g. archived + active) can share a key.
    public var identityKey: String

    /// Confidence level of the identity at creation time.
    public var confidenceRaw: Int

    /// Source application bundle identifier.
    public var bundleIdentifier: String

    /// Display name of the source application.
    public var applicationName: String

    /// Window title at creation or last update.
    public var windowTitle: String

    /// Document path or URL if applicable (exact local path for high confidence).
    public var documentPath: String

    /// The note text content.
    public var noteText: String

    /// Creation timestamp.
    public var createdAt: Date

    /// Last content modification timestamp.
    public var updatedAt: Date

    /// Last time this note was opened/attached to a live window.
    public var lastOpenedAt: Date

    /// Whether this note is pinned (always visible in search/recent).
    public var pinned: Bool

    /// Whether this note is archived (hidden from normal view, restorable).
    public var archived: Bool

    // MARK: - Init

    public init(
        id: UUID = UUID(),
        identityKey: String,
        confidence: IdentityConfidence,
        bundleIdentifier: String,
        applicationName: String,
        windowTitle: String = "",
        documentPath: String = "",
        noteText: String = "",
        createdAt: Date = Date(),
        updatedAt: Date = Date(),
        lastOpenedAt: Date = Date(),
        pinned: Bool = false,
        archived: Bool = false
    ) {
        self.id = id
        self.identityKey = identityKey
        self.confidenceRaw = confidence.rawValue
        self.bundleIdentifier = bundleIdentifier
        self.applicationName = applicationName
        self.windowTitle = windowTitle
        self.documentPath = documentPath
        self.noteText = noteText
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.lastOpenedAt = lastOpenedAt
        self.pinned = pinned
        self.archived = archived
    }

    // MARK: - Computed

    public var hasContent: Bool {
        !noteText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// Editing and display copies survive deletion of the stored SwiftData row.
    public func detachedCopy() -> WindowNote {
        let copy = WindowNote(
            id: id, identityKey: identityKey, confidence: confidence,
            bundleIdentifier: bundleIdentifier, applicationName: applicationName,
            windowTitle: windowTitle, documentPath: documentPath, noteText: noteText,
            createdAt: createdAt, updatedAt: updatedAt, lastOpenedAt: lastOpenedAt,
            pinned: pinned, archived: archived
        )
        copy.confidenceRaw = confidenceRaw
        return copy
    }

    /// The confidence level.
    public var confidence: IdentityConfidence {
        get { IdentityConfidence(rawValue: confidenceRaw) ?? .sessionOnly }
        set { confidenceRaw = newValue.rawValue }
    }

    /// Mark as dirty (content changed).
    public func markUpdated(_ date: Date = Date()) {
        updatedAt = date
    }

    /// Mark as opened.
    public func markOpened(_ date: Date = Date()) {
        lastOpenedAt = date
    }

    // MARK: - Fetch descriptors

    /// Fetch non-archived notes for a given identity key.
    public static func fetchActive(
        forIdentityKey key: String
    ) -> FetchDescriptor<WindowNote> {
        FetchDescriptor<WindowNote>(
            predicate: #Predicate { note in
                note.identityKey == key && !note.archived
            },
            sortBy: [SortDescriptor(\.lastOpenedAt, order: .reverse)]
        )
    }

    /// Fetch candidates for identity resolution; callers enforce uniqueness.
    public static func fetchSoleCandidate(
        forIdentityKey key: String
    ) -> FetchDescriptor<WindowNote> {
        FetchDescriptor<WindowNote>(
            predicate: #Predicate { note in
                note.identityKey == key && !note.archived
            },
            sortBy: [SortDescriptor(\.lastOpenedAt, order: .reverse)]
        )
    }

    /// Fetch archived notes for a given identity key.
    public static func fetchArchived(
        forIdentityKey key: String
    ) -> FetchDescriptor<WindowNote> {
        FetchDescriptor<WindowNote>(
            predicate: #Predicate { note in
                note.identityKey == key && note.archived
            },
            sortBy: [SortDescriptor(\.updatedAt, order: .reverse)]
        )
    }
}
