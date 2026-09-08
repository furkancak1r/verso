import AppKit
import ApplicationServices
import Foundation

#if SWIFT_PACKAGE
import VersoCore
#endif

/// Owns ephemeral AX-window bindings and the persistent note behind them.
/// Bindings deliberately outlive the overlay window, while dirty notes also
/// have an AX-free recovery path after a process or overlay disappears.
@MainActor
final class NoteSessionController {
    enum ReservationLiveness {
        case alive
        case dead
        case unknown
    }

    typealias ReservationLivenessCheck = @MainActor (
        _ application: NSRunningApplication,
        _ axWindow: AXUIElement
    ) -> ReservationLiveness

    typealias RepositorySave = @MainActor () -> (Bool, Error?)

    @MainActor
    final class LiveSession {
        let sessionUUID: UUID
        let runningApplication: NSRunningApplication
        let axWindow: AXUIElement
        let axApplication: AXUIElement
        let evidence: HitTestEvidence
        var identity: WindowIdentityResolver.Identity
        let note: WindowNote
        var metadata: TargetWindowMetadata
        var autosave: AutosaveCoordinator!
        var requiresRepositorySave = true

        var hasUnsavedChanges: Bool {
            requiresRepositorySave || autosave?.isDirty == true
        }

        init(
            sessionUUID: UUID,
            runningApplication: NSRunningApplication,
            axWindow: AXUIElement,
            axApplication: AXUIElement,
            evidence: HitTestEvidence,
            identity: WindowIdentityResolver.Identity,
            note: WindowNote,
            metadata: TargetWindowMetadata
        ) {
            self.sessionUUID = sessionUUID
            self.runningApplication = runningApplication
            self.axWindow = axWindow
            self.axApplication = axApplication
            self.evidence = evidence
            self.identity = identity
            self.note = note
            self.metadata = metadata
        }
    }

    /// A dirty note retained without an AX element after process termination.
    @MainActor
    private final class RecoveryDraft {
        let note: WindowNote
        let autosave: AutosaveCoordinator

        init(note: WindowNote, autosave: AutosaveCoordinator) {
            self.note = note
            self.autosave = autosave
        }
    }

    private enum RestoreResult {
        case note(WindowNote?)
        case failure(Error)
    }

    enum ObservedMetadataResult {
        case unchanged
        case documentChanged
        case documentChangedSaveFailed
    }

    struct LibraryEditorToken: Equatable {
        let noteID: UUID
        let generation: UInt64
    }

    struct LibraryEditorStart {
        let text: String
        let token: LibraryEditorToken
    }

    @MainActor
    private final class LibraryEditing {
        let note: WindowNote
        let autosave: AutosaveCoordinator
        let token: LibraryEditorToken
        var requiresRepositorySave = false

        init(
            note: WindowNote,
            autosave: AutosaveCoordinator,
            token: LibraryEditorToken
        ) {
            self.note = note
            self.autosave = autosave
            self.token = token
        }

        var hasUnsavedChanges: Bool {
            requiresRepositorySave || autosave.isDirty
        }
    }

    private var liveSessions: [LiveSession] = []
    private var recoveryDrafts: [UUID: RecoveryDraft] = [:]
    private var libraryEditing: LibraryEditing?
    private var libraryGeneration: UInt64 = 0

    let resolver = WindowIdentityResolver()
    let repository: NoteRepository
    private(set) var activeSession: LiveSession?
    private(set) var isStoreDisabled = false
    private(set) var lastSaveError: Error?
    private(set) var lastBeginSucceeded = false

    private let schedulerFactory: AutosaveCoordinator.Scheduler
    private let reservationLiveness: ReservationLivenessCheck
    private let repositorySaveOverride: RepositorySave?

    /// AppKit/menu-bar integration observes this after autosave has updated
    /// its state. It is intentionally a non-modal status update.
    var onSaveErrorChanged: ((Error?) -> Void)?

    init(
        repository: NoteRepository,
        schedulerFactory: AutosaveCoordinator.Scheduler? = nil,
        reservationLiveness: ReservationLivenessCheck? = nil,
        repositorySave: RepositorySave? = nil
    ) {
        self.repository = repository
        self.schedulerFactory = schedulerFactory ?? NoteSessionController.defaultScheduler
        self.reservationLiveness = reservationLiveness
            ?? NoteSessionController.defaultReservationLiveness
        self.repositorySaveOverride = repositorySave
    }

    // MARK: - Store

    @discardableResult
    func openStore(inMemory: Bool = false) -> Bool {
        let opened = repository.openStore(inMemory: inMemory)
        isStoreDisabled = !opened
        if !opened { setSaveError(repository.lastError) }
        return opened
    }

    @discardableResult
    func retryStoreOpen(inMemory: Bool = false) -> Bool {
        let opened = repository.retryOpen(inMemory: inMemory)
        isStoreDisabled = !opened
        setSaveError(opened ? nil : repository.lastError)
        return opened
    }

    var isTriggeringEnabled: Bool {
        repository.isReady && !isStoreDisabled
    }

    // MARK: - Sessions

    /// Compatibility entry point. A failed transition returns the current
    /// draft text and leaves the old session active.
    @discardableResult
    func beginSession(
        for target: AccessibilityWindowService.ResolvedTargetWindow
    ) -> String {
        beginSessionIfPossible(for: target)
            ?? activeSession?.autosave?.currentText
            ?? ""
    }

    /// Open or reattach a session. `nil` means that a required save failed;
    /// callers must keep the existing editor/overlay available in that case.
    func beginSessionIfPossible(
        for target: AccessibilityWindowService.ResolvedTargetWindow
    ) -> String? {
        lastBeginSucceeded = false
        guard isTriggeringEnabled else {
            let error = repository.lastError ?? makeError(
                code: 100,
                description: L("error.storeUnavailable")
            )
            setSaveError(error)
            return nil
        }

        // A different target cannot take over while the visible session has a
        // pending write. The old session remains active on failure.
        if let active = activeSession,
           !isSamePhysicalWindow(active, target) {
            guard flush(active) else { return nil }
            activeSession = nil
        }

        if let existing = findLiveSession(for: target) {
            let incoming = resolver.resolve(
                bundleIdentifier: target.metadata.bundleIdentifier,
                documentPath: target.metadata.documentPath,
                documentURL: target.metadata.documentURL,
                windowTitle: target.metadata.windowTitle,
                sessionID: existing.sessionUUID
            )

            if shouldKeep(existing.identity, for: incoming) {
                update(existing, with: target, identity: incoming)
                activeSession = existing
                lastBeginSucceeded = true
                return existing.autosave.currentText
            }

            // Same AX window moved from exact document A to B. Persist A
            // before releasing its live reservation; B is resolved separately.
            guard flush(existing) else {
                activeSession = existing
                return nil
            }
            removeLiveSession(existing)
        }

        let sessionUUID = UUID()
        let identity = resolver.resolve(
            bundleIdentifier: target.metadata.bundleIdentifier,
            documentPath: target.metadata.documentPath,
            documentURL: target.metadata.documentURL,
            windowTitle: target.metadata.windowTitle,
            sessionID: sessionUUID
        )

        let restored: WindowNote?
        if identity.confidence >= .high && !identity.isBrowserSession {
            switch restoreNote(for: identity) {
            case .note(let note):
                restored = note
            case .failure(let error):
                setSaveError(error)
                return nil
            }
        } else {
            restored = nil
        }

        let note = restored ?? makeNewNote(identity: identity, target: target)
        let session = LiveSession(
            sessionUUID: sessionUUID,
            runningApplication: target.runningApplication,
            axWindow: target.axWindow,
            axApplication: target.axApplication,
            evidence: target.evidence,
            identity: identity,
            note: note,
            metadata: target.metadata
        )
        session.requiresRepositorySave = true
        session.autosave = makeAutosave(for: note, session: session)
        session.autosave.load(note.noteText)

        liveSessions.append(session)
        activeSession = session
        note.markOpened()
        lastBeginSucceeded = true
        return session.autosave.currentText
    }

    /// Token-bound editor callback. A dismissed/old editor cannot update the
    /// note selected by a later session.
    func editorTextDidChange(_ text: String, sessionID: UUID? = nil) {
        guard let session = activeSession,
              sessionID == nil || session.sessionUUID == sessionID else {
            return
        }
        updateEditorText(text, for: session)
    }

    /// Read actual editor text after marked-text commit and force the same
    /// session's save.
    @discardableResult
    func commitAndSave(
        editorText: String,
        sessionID: UUID? = nil
    ) -> (Bool, Error?) {
        guard let session = activeSession,
              sessionID == nil || session.sessionUUID == sessionID else {
            let error = makeError(
                code: 101,
                description: L("library.editorDetached")
            )
            setSaveError(error)
            return (false, error)
        }
        updateEditorText(editorText, for: session)
        let result = flush(session)
        return result ? (true, nil) : (false, lastSaveError)
    }

    /// External cleanup always attempts a final write, then releases the
    /// overlay-side active reference. The live reservation and dirty model
    /// remain owned by this controller.
    func handleExternalCleanup(editorText: String? = nil) {
        guard let session = activeSession else { return }
        if let editorText {
            _ = commitAndSave(editorText: editorText, sessionID: session.sessionUUID)
        } else {
            _ = flush(session)
        }
        if session.hasUnsavedChanges {
            retainRecovery(for: session)
        }
        activeSession = nil
    }

    /// Apply metadata delivered by the retained AX observer. Title/frame
    /// changes keep the live binding. An exact document change saves and
    /// releases the old binding so the next trigger resolves the new one.
    @discardableResult
    func handleObservedMetadata(
        for target: AccessibilityWindowService.ResolvedTargetWindow,
        editorText: String? = nil
    ) -> ObservedMetadataResult {
        guard let session = activeSession,
              isSamePhysicalWindow(session, target) else {
            return .unchanged
        }

        let incoming = resolver.resolve(
            bundleIdentifier: target.metadata.bundleIdentifier,
            documentPath: target.metadata.documentPath,
            documentURL: target.metadata.documentURL,
            windowTitle: target.metadata.windowTitle,
            sessionID: session.sessionUUID
        )

        guard !shouldKeep(session.identity, for: incoming) else {
            update(session, with: target, identity: incoming)
            return .unchanged
        }

        if let editorText {
            updateEditorText(editorText, for: session)
        }
        let saved = flush(session)
        if !saved {
            retainRecovery(for: session)
        }
        removeLiveSession(session)
        activeSession = nil
        refreshSaveError()
        return saved ? .documentChanged : .documentChangedSaveFailed
    }

    /// Release a target whose AX element was destroyed. The destroyed element
    /// is never queried here; the caller has already stopped observation.
    func handleDestroyedTarget(editorText: String? = nil) {
        releaseActiveSession(editorText: editorText)
    }

    /// Release the active overlay-side binding before the termination observer
    /// prunes any remaining sessions for the process.
    func handleProcessTermination(editorText: String? = nil) {
        releaseActiveSession(editorText: editorText)
    }

    /// Commit the overlay's actual editor and hide its presentation while
    /// retaining the live reservation for a library handoff.
    @discardableResult
    func yieldActiveOverlay(editorText: String? = nil) -> Bool {
        guard let session = activeSession else { return true }
        if let editorText {
            updateEditorText(editorText, for: session)
        }
        guard flush(session) else { return false }
        activeSession = nil
        refreshSaveError()
        return true
    }

    func endActiveSession() {
        activeSession = nil
    }

    /// Remove a binding only after its caller has successfully flushed it.
    /// If called directly with dirty content, retain an AX-free recovery copy.
    func closeSession(for sessionUUID: UUID) {
        guard let session = liveSessions.first(where: { $0.sessionUUID == sessionUUID })
        else { return }
        if session.hasUnsavedChanges { retainRecovery(for: session) }
        removeLiveSession(session)
    }

    // MARK: - Library editing

    /// Start the one library editor for a persistent note. A live note reuses
    /// its existing autosave owner so an inactive overlay cannot overwrite a
    /// newer library edit.
    func beginLibraryEditing(for note: WindowNote) -> LibraryEditorStart? {
        guard isTriggeringEnabled else {
            setSaveError(repository.lastError ?? makeError(
                code: 107,
                description: L("error.storeUnavailable")
            ))
            return nil
        }
        guard activeSession == nil else {
            setSaveError(makeError(
                code: 108,
                description: L("error.libraryBlocked")
            ))
            return nil
        }
        if let current = libraryEditing {
            guard current.note.id == note.id else {
                setSaveError(makeError(
                    code: 109,
                    description: L("error.switchBlocked")
                ))
                return nil
            }
            return LibraryEditorStart(
                text: current.autosave.currentText,
                token: current.token
            )
        }

        libraryGeneration &+= 1
        let token = LibraryEditorToken(
            noteID: note.id,
            generation: libraryGeneration
        )
        let liveSession = liveSessions.first { $0.note.id == note.id }
        let autosave = liveSession?.autosave
            ?? makeAutosave(for: note, session: nil)
        if liveSession == nil {
            autosave.load(note.noteText)
        }
        let editing = LibraryEditing(
            note: note,
            autosave: autosave,
            token: token
        )
        editing.requiresRepositorySave = liveSession?.requiresRepositorySave ?? false
        libraryEditing = editing
        note.markOpened()
        editing.requiresRepositorySave = true
        return LibraryEditorStart(
            text: autosave.currentText,
            token: token
        )
    }

    /// Apply a native editor callback only to the selected library generation.
    func libraryEditorTextDidChange(
        _ text: String,
        token: LibraryEditorToken
    ) {
        guard let editing = libraryEditing, editing.token == token else {
            return
        }
        editing.note.noteText = text
        editing.note.markUpdated()
        editing.requiresRepositorySave = true
        if let live = liveSessions.first(where: { $0.note.id == token.noteID }) {
            live.requiresRepositorySave = true
        }
        editing.autosave.textDidChange(text)
    }

    /// Read/commit the actual library editor value, including marked text,
    /// before any handoff or metadata mutation.
    @discardableResult
    func commitLibraryEditorAndSave(
        editorText: String,
        token: LibraryEditorToken
    ) -> (Bool, Error?) {
        guard let editing = libraryEditing, editing.token == token else {
            let error = makeError(
                code: 110,
                description: L("error.libraryDetached")
            )
            setSaveError(error)
            return (false, error)
        }

        editing.note.noteText = editorText
        editing.note.markUpdated()
        editing.requiresRepositorySave = true
        editing.autosave.textDidChange(editorText)

        switch editing.autosave.forceFlush() {
        case .success:
            editing.requiresRepositorySave = false
            if let live = liveSessions.first(where: { $0.note.id == editing.note.id }) {
                live.requiresRepositorySave = false
            }
            refreshSaveError()
            return (true, nil)
        case .failure(let error):
            editing.requiresRepositorySave = true
            setSaveError(error)
            return (false, error)
        }
    }

    /// End a successful library presentation. The reused live autosave stays
    /// with its reservation, while a standalone draft is released.
    @discardableResult
    func endLibraryEditing(token: LibraryEditorToken) -> Bool {
        guard let current = libraryEditing, current.token == token else {
            return false
        }
        current.autosave.cancelDebounce()
        libraryEditing = nil
        libraryGeneration &+= 1
        refreshSaveError()
        return true
    }

    var libraryEditorToken: LibraryEditorToken? { libraryEditing?.token }
    var libraryEditorText: String? { libraryEditing?.autosave.currentText }
    var hasUnsavedLibraryChanges: Bool { libraryEditing?.hasUnsavedChanges == true }

    /// Return the retained AX binding for a note, without validating it.
    /// Callers must use AccessibilityWindowService.refreshTarget before Raise.
    func liveTarget(for noteID: UUID) -> AccessibilityWindowService.ResolvedTargetWindow? {
        guard let session = liveSessions.first(where: { $0.note.id == noteID }) else {
            return nil
        }
        return AccessibilityWindowService.ResolvedTargetWindow(
            metadata: session.metadata,
            evidence: session.evidence,
            axWindow: session.axWindow,
            axApplication: session.axApplication,
            runningApplication: session.runningApplication
        )
    }

    /// Confirm that refreshed metadata still names the note's retained
    /// document. Title-only/browser bindings may change title; a stored exact
    /// path may never be raised for a different document.
    func liveTargetMatchesNote(
        noteID: UUID,
        target: AccessibilityWindowService.ResolvedTargetWindow
    ) -> Bool {
        guard let session = liveSessions.first(where: { $0.note.id == noteID }),
              session.runningApplication.isEqual(target.runningApplication),
              CFEqual(session.axWindow, target.axWindow) else {
            return false
        }

        let incoming = resolver.resolve(
            bundleIdentifier: target.metadata.bundleIdentifier,
            documentPath: target.metadata.documentPath,
            documentURL: target.metadata.documentURL,
            windowTitle: target.metadata.windowTitle,
            sessionID: session.sessionUUID
        )
        let note = session.note

        if !note.documentPath.isEmpty {
            return incoming.documentPath == note.documentPath
                && WindowIdentityResolver.keysMatch(
                    incoming.identityKey,
                    note.identityKey
                )
        }

        // A path appearing after a title-only/session binding is not enough
        // evidence to show that exact document; browser title changes remain
        // valid for their retained session identity.
        if incoming.documentPath != nil { return false }
        if session.identity.isBrowserSession {
            return WindowIdentityResolver.keysMatch(
                incoming.identityKey,
                note.identityKey
            )
        }
        return true
    }

    /// Toggle Pin for the selected library note after saving its actual text.
    @discardableResult
    func toggleLibraryPin(
        noteID: UUID,
        editorText: String,
        token: LibraryEditorToken
    ) -> (Bool, Error?) {
        guard let editing = libraryEditing,
              editing.note.id == noteID,
              editing.token == token else {
            return libraryEditorError()
        }
        let (textSaved, textError) = commitLibraryEditorAndSave(
            editorText: editorText,
            token: token
        )
        guard textSaved else { return (false, textError) }

        let oldPinned = editing.note.pinned
        let oldUpdatedAt = editing.note.updatedAt
        editing.note.pinned.toggle()
        editing.note.markUpdated()
        editing.requiresRepositorySave = true
        let (saved, error) = saveRepository()
        guard saved else {
            editing.note.pinned = oldPinned
            editing.note.updatedAt = oldUpdatedAt
            editing.requiresRepositorySave = true
            setSaveError(error)
            return (false, error)
        }

        editing.requiresRepositorySave = false
        if let live = liveSessions.first(where: { $0.note.id == noteID }) {
            live.requiresRepositorySave = false
        }
        refreshSaveError()
        return (true, nil)
    }

    /// Archive the selected note. Its live reservation is released only after
    /// the metadata save succeeds.
    @discardableResult
    func archiveLibraryNote(
        noteID: UUID,
        editorText: String,
        token: LibraryEditorToken
    ) -> (Bool, Error?) {
        guard let editing = libraryEditing,
              editing.note.id == noteID,
              editing.token == token else {
            return libraryEditorError()
        }
        let (textSaved, textError) = commitLibraryEditorAndSave(
            editorText: editorText,
            token: token
        )
        guard textSaved else { return (false, textError) }

        let oldArchived = editing.note.archived
        let oldUpdatedAt = editing.note.updatedAt
        editing.note.archived = true
        editing.note.markUpdated()
        editing.requiresRepositorySave = true
        let (saved, error) = saveRepository()
        guard saved else {
            editing.note.archived = oldArchived
            editing.note.updatedAt = oldUpdatedAt
            editing.requiresRepositorySave = true
            setSaveError(error)
            return (false, error)
        }

        let live = liveSessions.first(where: { $0.note.id == noteID })
        editing.requiresRepositorySave = false
        _ = endLibraryEditing(token: token)
        if let live { removeLiveSession(live) }
        refreshSaveError()
        return (true, nil)
    }

    /// Restore an archived note without attempting to bind it to a window.
    @discardableResult
    func restoreLibraryNote(
        noteID: UUID,
        editorText: String,
        token: LibraryEditorToken
    ) -> (Bool, Error?) {
        guard let editing = libraryEditing,
              editing.note.id == noteID,
              editing.token == token else {
            return libraryEditorError()
        }
        let (textSaved, textError) = commitLibraryEditorAndSave(
            editorText: editorText,
            token: token
        )
        guard textSaved else { return (false, textError) }

        let oldArchived = editing.note.archived
        let oldUpdatedAt = editing.note.updatedAt
        editing.note.archived = false
        editing.note.markUpdated()
        editing.requiresRepositorySave = true
        let (saved, error) = saveRepository()
        guard saved else {
            editing.note.archived = oldArchived
            editing.note.updatedAt = oldUpdatedAt
            editing.requiresRepositorySave = true
            setSaveError(error)
            return (false, error)
        }

        editing.requiresRepositorySave = false
        _ = endLibraryEditing(token: token)
        refreshSaveError()
        return (true, nil)
    }

    /// Delete only after every dirty owner has flushed. A failed delete rolls
    /// back the isolated deletion transaction, never another dirty note.
    @discardableResult
    func deleteLibraryNote(
        noteID: UUID,
        editorText: String,
        token: LibraryEditorToken
    ) -> (Bool, Error?) {
        guard let editing = libraryEditing,
              editing.note.id == noteID,
              editing.token == token else {
            return libraryEditorError()
        }
        let (textSaved, textError) = commitLibraryEditorAndSave(
            editorText: editorText,
            token: token
        )
        guard textSaved, forceSaveAll() else {
            let error = textError ?? lastSaveError
            return (false, error)
        }

        let live = liveSessions.first(where: { $0.note.id == noteID })
        repository.delete(editing.note)
        let (saved, error) = saveRepository()
        guard saved else {
            repository.rollbackFailedDeletion()
            editing.requiresRepositorySave = true
            setSaveError(error)
            return (false, error)
        }

        let recoveryIDs = recoveryDrafts.compactMap { id, draft in
            draft.note.id == noteID ? id : nil
        }
        for id in recoveryIDs {
            recoveryDrafts.removeValue(forKey: id)
        }
        _ = endLibraryEditing(token: token)
        if let live { removeLiveSession(live) }
        refreshSaveError()
        return (true, nil)
    }

    private func libraryEditorError() -> (Bool, Error?) {
        let error = makeError(
            code: 111,
            description: L("error.libraryDetached")
        )
        setSaveError(error)
        return (false, error)
    }

    // MARK: - Metadata updates

    /// A title change alone never replaces a live note.
    func updateActiveTitle(_ title: String) {
        guard let session = activeSession else { return }
        session.note.windowTitle = title
        session.metadata = TargetWindowMetadata(
            pid: session.metadata.pid,
            bundleIdentifier: session.metadata.bundleIdentifier,
            appName: session.metadata.appName,
            windowTitle: title,
            windowRole: session.metadata.windowRole,
            windowSubrole: session.metadata.windowSubrole,
            documentPath: session.metadata.documentPath,
            documentURL: session.metadata.documentURL,
            frame: session.metadata.frame,
            isMinimized: session.metadata.isMinimized,
            isOnScreen: session.metadata.isOnScreen
        )
        session.note.markUpdated()
        session.requiresRepositorySave = true
    }

    // MARK: - Pin/archive

    /// Toggle the active note's membership in Pinned Notes. Icon state is
    /// always derived from this persisted value, never from button state.
    @discardableResult
    func toggleActiveNotePin(editorText: String) -> (Bool, Error?) {
        guard let session = activeSession else { return (false, nil) }
        let (textSaved, textError) = commitAndSave(
            editorText: editorText,
            sessionID: session.sessionUUID
        )
        guard textSaved else { return (false, textError) }

        let oldPinned = session.note.pinned
        let oldUpdatedAt = session.note.updatedAt
        session.note.pinned.toggle()
        session.note.markUpdated()
        session.requiresRepositorySave = true
        let (saved, error) = saveRepository()
        guard saved else {
            session.note.pinned = oldPinned
            session.note.updatedAt = oldUpdatedAt
            session.requiresRepositorySave = true
            setSaveError(error)
            return (false, error)
        }

        session.requiresRepositorySave = false
        refreshSaveError()
        return (true, nil)
    }

    @discardableResult
    func archiveActiveNote(editorText: String) -> (Bool, Error?) {
        guard let session = activeSession else { return (false, nil) }
        let (textSaved, textError) = commitAndSave(
            editorText: editorText,
            sessionID: session.sessionUUID
        )
        guard textSaved else { return (false, textError) }

        let oldArchived = session.note.archived
        let oldUpdatedAt = session.note.updatedAt
        session.note.archived = true
        session.note.markUpdated()
        session.requiresRepositorySave = true
        let (saved, error) = saveRepository()
        guard saved else {
            session.note.archived = oldArchived
            session.note.updatedAt = oldUpdatedAt
            session.requiresRepositorySave = true
            setSaveError(error)
            return (false, error)
        }

        session.requiresRepositorySave = false
        removeLiveSession(session)
        activeSession = nil
        refreshSaveError()
        return (true, nil)
    }

    // MARK: - Recovery and termination

    /// Keep stale AX reservations out of the live set after an explicit
    /// process-termination signal. Hidden/minimized windows are not pruned by
    /// this method unless the owning process is actually identified as dead.
    func pruneStaleReferences(for application: NSRunningApplication) {
        let stale = liveSessions.filter {
            $0.runningApplication.isEqual(application)
        }
        for session in stale {
            _ = flush(session)
            if session.hasUnsavedChanges { retainRecovery(for: session) }
            removeLiveSession(session)
        }
        if let active = activeSession, stale.contains(where: { $0 === active }) {
            activeSession = nil
        }
        refreshSaveError()
    }

    @discardableResult
    func retryPendingSaves() -> Bool {
        guard repository.isReady else {
            setSaveError(repository.lastError ?? makeError(
                code: 102,
                description: L("error.storeUnavailable")
            ))
            return false
        }

        var allSucceeded = true
        var handledAutosaves = Set<ObjectIdentifier>()

        if let editing = libraryEditing, editing.hasUnsavedChanges {
            let identifier = ObjectIdentifier(editing.autosave)
            if handledAutosaves.insert(identifier).inserted {
                if !flushLibraryEditing(editing) { allSucceeded = false }
            } else {
                editing.requiresRepositorySave = false
            }
        }
        for session in liveSessions where session.hasUnsavedChanges {
            let identifier = ObjectIdentifier(session.autosave)
            if handledAutosaves.insert(identifier).inserted {
                if !flush(session) { allSucceeded = false }
            }
        }
        for (id, draft) in Array(recoveryDrafts) {
            // Recovery also owns unsaved metadata and newly inserted empty notes.
            let identifier = ObjectIdentifier(draft.autosave)
            if handledAutosaves.insert(identifier).inserted {
                switch draft.autosave.forceFlush() {
                case .success:
                    recoveryDrafts.removeValue(forKey: id)
                case .failure(let error):
                    setSaveError(error)
                    allSucceeded = false
                }
            } else if !draft.autosave.isDirty {
                recoveryDrafts.removeValue(forKey: id)
            }
        }
        refreshSaveError()
        return allSucceeded && lastSaveError == nil
    }

    @discardableResult
    func forceSaveAll() -> Bool {
        guard repository.isReady else {
            // A store that never opened has no notes to lose. If dirty live or
            // library or recovery models exist, termination must still be
            // cancelled.
            return liveSessions.isEmpty
                && recoveryDrafts.isEmpty
                && libraryEditing == nil
        }

        var allSucceeded = true
        var handledAutosaves = Set<ObjectIdentifier>()
        if let editing = libraryEditing {
            let identifier = ObjectIdentifier(editing.autosave)
            if handledAutosaves.insert(identifier).inserted {
                if !flushLibraryEditing(editing) { allSucceeded = false }
            } else {
                editing.requiresRepositorySave = false
            }
        }
        for session in liveSessions {
            let identifier = ObjectIdentifier(session.autosave)
            if handledAutosaves.insert(identifier).inserted {
                if !flush(session) { allSucceeded = false }
            }
        }
        for (id, draft) in Array(recoveryDrafts) {
            let identifier = ObjectIdentifier(draft.autosave)
            if handledAutosaves.insert(identifier).inserted {
                switch draft.autosave.forceFlush() {
                case .success:
                    recoveryDrafts.removeValue(forKey: id)
                case .failure(let error):
                    setSaveError(error)
                    allSucceeded = false
                }
            } else if !draft.autosave.isDirty {
                recoveryDrafts.removeValue(forKey: id)
            }
        }
        refreshSaveError()
        return allSucceeded && lastSaveError == nil
    }

    var activeLiveSessionCount: Int { liveSessions.count }
    var recoveryDraftCount: Int { recoveryDrafts.count }
    var activeSessionUUID: UUID? { activeSession?.sessionUUID }

    // MARK: - Internal identity/binding logic

    private func findLiveSession(
        for target: AccessibilityWindowService.ResolvedTargetWindow
    ) -> LiveSession? {
        return liveSessions.first {
            $0.runningApplication.isEqual(target.runningApplication)
                && CFEqual($0.axWindow, target.axWindow)
        }
    }

    private func isSamePhysicalWindow(
        _ session: LiveSession,
        _ target: AccessibilityWindowService.ResolvedTargetWindow
    ) -> Bool {
        session.runningApplication.isEqual(target.runningApplication)
            && CFEqual(session.axWindow, target.axWindow)
    }

    private func shouldKeep(
        _ current: WindowIdentityResolver.Identity,
        for incoming: WindowIdentityResolver.Identity
    ) -> Bool {
        if current.isBrowserSession || incoming.isBrowserSession { return true }
        if current.confidence >= .high && incoming.confidence >= .high {
            return WindowIdentityResolver.keysMatch(
                current.identityKey,
                incoming.identityKey
            )
        }
        // Do not replace an initially untitled/title-only live draft when a
        // path appears later, and do not discard it for temporary metadata loss.
        return true
    }

    private func update(
        _ session: LiveSession,
        with target: AccessibilityWindowService.ResolvedTargetWindow,
        identity: WindowIdentityResolver.Identity
    ) {
        session.metadata = target.metadata
        if let title = target.metadata.windowTitle {
            session.note.windowTitle = title
        }
        if session.identity.confidence >= .high,
           identity.confidence >= .high,
           let path = identity.documentPath {
            session.note.documentPath = path
        }
        session.note.markOpened()
        session.requiresRepositorySave = true
    }

    private func restoreNote(
        for identity: WindowIdentityResolver.Identity
    ) -> RestoreResult {
        do {
            let candidates = try repository.fetchActiveNotesThrowing(
                forKey: identity.identityKey
            )
            guard candidates.count == 1, let candidate = candidates.first else {
                return .note(nil)
            }
            guard !isReservedOrReleaseDead(candidate) else { return .note(nil) }
            candidate.markOpened()
            return .note(candidate)
        } catch {
            return .failure(error)
        }
    }

    /// Validate only the live reservation for this candidate. A dead AX
    /// reference may be released lazily; hidden/minimized and ambiguous AX
    /// results remain reserved so a transient state cannot merge notes.
    private func isReservedOrReleaseDead(_ note: WindowNote) -> Bool {
        if let session = liveSessions.first(where: { $0.note.id == note.id }) {
            switch reservationLiveness(session.runningApplication, session.axWindow) {
            case .alive, .unknown:
                return true
            case .dead:
                _ = flush(session)
                let needsRecovery = session.hasUnsavedChanges
                if needsRecovery { retainRecovery(for: session) }
                removeLiveSession(session)
                return needsRecovery
                    || recoveryDrafts.values.contains { $0.note.id == note.id }
            }
        }

        return recoveryDrafts.values.contains { $0.note.id == note.id }
    }

    private func makeNewNote(
        identity: WindowIdentityResolver.Identity,
        target: AccessibilityWindowService.ResolvedTargetWindow
    ) -> WindowNote {
        let note = WindowNote(
            identityKey: identity.identityKey,
            confidence: identity.confidence,
            bundleIdentifier: target.metadata.bundleIdentifier ?? "",
            applicationName: target.metadata.appName,
            windowTitle: target.metadata.windowTitle ?? "",
            documentPath: identity.documentPath ?? ""
        )
        repository.insert(note)
        return note
    }

    private func makeAutosave(
        for note: WindowNote,
        session: LiveSession?
    ) -> AutosaveCoordinator {
        AutosaveCoordinator(
            scheduler: schedulerFactory,
            saveClosure: { [weak self, weak note, weak session] text in
                guard let self, let note else {
                    return .failure(self?.makeError(
                        code: 104,
                        description: L("error.sessionGone")
                    ) ?? NSError(
                        domain: "com.verso.autosave",
                        code: 104,
                        userInfo: [NSLocalizedDescriptionKey: L("error.sessionGone")]
                    ))
                }
                guard self.repository.isReady else {
                    let error = self.repository.lastError ?? self.makeError(
                        code: 105,
                        description: L("error.storeUnavailable")
                    )
                    self.lastSaveError = error
                    return .failure(error)
                }

                note.noteText = text
                note.markUpdated()
                session?.requiresRepositorySave = true
                if let editing = self.libraryEditing,
                   editing.note.id == note.id {
                    editing.requiresRepositorySave = true
                }
                let (saved, error) = self.saveRepository()
                if saved {
                    session?.requiresRepositorySave = false
                    if let editing = self.libraryEditing,
                       editing.note.id == note.id {
                        editing.requiresRepositorySave = false
                    }
                    return .success
                }

                let failure = error ?? self.makeError(
                    code: 106,
                    description: L("error.saveFailed")
                )
                self.lastSaveError = failure
                return .failure(failure)
            },
            saveCompletion: { [weak self] _ in
                self?.refreshSaveError()
            }
        )
    }

    private func updateEditorText(_ text: String, for session: LiveSession) {
        session.note.noteText = text
        session.note.markUpdated()
        session.requiresRepositorySave = true
        session.autosave.textDidChange(text)
    }

    @discardableResult
    private func flushLibraryEditing(_ editing: LibraryEditing) -> Bool {
        switch editing.autosave.forceFlush() {
        case .success:
            editing.requiresRepositorySave = false
            if let live = liveSessions.first(where: { $0.note.id == editing.note.id }) {
                live.requiresRepositorySave = false
            }
            refreshSaveError()
            return true
        case .failure(let error):
            editing.requiresRepositorySave = true
            setSaveError(error)
            return false
        }
    }

    private func releaseActiveSession(editorText: String?) {
        guard let session = activeSession else { return }
        if let editorText {
            updateEditorText(editorText, for: session)
        }
        _ = flush(session)
        if session.hasUnsavedChanges {
            retainRecovery(for: session)
        }
        removeLiveSession(session)
        activeSession = nil
        refreshSaveError()
    }

    @discardableResult
    private func flush(_ session: LiveSession) -> Bool {
        switch session.autosave.forceFlush() {
        case .success:
            session.requiresRepositorySave = false
            refreshSaveError()
            return true
        case .failure(let error):
            session.requiresRepositorySave = true
            lastSaveError = error
            refreshSaveError()
            return false
        }
    }

    private func removeLiveSession(_ session: LiveSession) {
        liveSessions.removeAll { $0 === session }
        if activeSession === session { activeSession = nil }
    }

    private func retainRecovery(for session: LiveSession) {
        guard session.hasUnsavedChanges else { return }
        recoveryDrafts[session.sessionUUID] = RecoveryDraft(
            note: session.note,
            autosave: session.autosave
        )
    }

    private func refreshSaveError() {
        let error = repository.lastError
            ?? liveSessions.compactMap({ $0.autosave.lastError }).first
            ?? libraryEditing?.autosave.lastError
            ?? recoveryDrafts.values.compactMap({ $0.autosave.lastError }).first
        setSaveError(error)
    }

    private func setSaveError(_ error: Error?) {
        lastSaveError = error
        onSaveErrorChanged?(error)
    }

    private func makeError(code: Int, description: String) -> NSError {
        NSError(
            domain: "com.verso.note-session",
            code: code,
            userInfo: [NSLocalizedDescriptionKey: description]
        )
    }

    private func saveRepository() -> (Bool, Error?) {
        repositorySaveOverride?() ?? repository.save()
    }

    private static let defaultReservationLiveness: ReservationLivenessCheck = {
        application, axWindow in
        guard !application.isTerminated else { return .dead }
        guard AXUIElementSetMessagingTimeout(axWindow, 0.015) == .success else {
            return .unknown
        }

        var rawRole: CFTypeRef?
        switch AXUIElementCopyAttributeValue(
            axWindow,
            kAXRoleAttribute as CFString,
            &rawRole
        ) {
        case .success:
            guard let rawRole,
                  CFGetTypeID(rawRole) == CFStringGetTypeID(),
                  let role = rawRole as? String else {
                return .unknown
            }
            return role == kAXWindowRole ? .alive : .dead
        case .invalidUIElement:
            return .dead
        default:
            return .unknown
        }
    }

    nonisolated static let defaultScheduler: AutosaveCoordinator.Scheduler = { delay, callback in
        let work = DispatchWorkItem(block: { callback() })
        DispatchQueue.main.asyncAfter(
            deadline: .now() + delay,
            execute: work
        )
        return work
    }
}
