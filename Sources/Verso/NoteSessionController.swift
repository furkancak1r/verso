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
        var note: WindowNote
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

        // APPLICATION grouping: every window of the same app shares one
        // notebook. Unidentified apps (empty bundleIdentifier) keep the legacy
        // isolated per-window behavior below and never merge notebooks.
        if let appKey = Self.notebookKey(bundleIdentifier: target.metadata.bundleIdentifier) {
            return beginAppSession(for: target, appKey: appKey)
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

        let note = restored?.detachedCopy() ?? makeNewNote(identity: identity, target: target)
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
        session.requiresRepositorySave = note.hasContent
        session.autosave = makeAutosave(for: note, session: session)
        session.autosave.load(note.noteText)

        liveSessions.append(session)
        activeSession = session
        note.markOpened()
        lastBeginSucceeded = true
        return session.autosave.currentText
    }

    // MARK: - Application tabs

    /// One notebook per nonempty bundleIdentifier. Tabs are live detached
    /// drafts in stable creation order (createdAt, then UUID); blank tabs
    /// stay in memory only until they gain content.
    /// ponytail: ceiling is in-memory notebooks keyed by bundleIdentifier; if
    /// persisted tab ordering beyond createdAt+UUID is ever requested, replace
    /// AppNotebook with a real order entity instead of patching this class.
    private final class AppNotebook {
        let bundleID: String
        var tabs: [WindowNote] = []
        var autosaves: [UUID: AutosaveCoordinator] = [:]
        var dirty: [UUID: Bool] = [:]
        var selectedID: UUID?
        init(bundleID: String) { self.bundleID = bundleID }
    }

    private var appNotebooks: [String: AppNotebook] = [:]

    /// Nonempty bundleIdentifier is the persistent notebook key. Empty or
    /// missing identifiers return nil so unidentified apps keep isolated
    /// per-window behavior instead of merging into one empty-ID notebook.
    private static func notebookKey(bundleIdentifier: String?) -> String? {
        guard let key = bundleIdentifier?.trimmingCharacters(
            in: .whitespacesAndNewlines
        ), !key.isEmpty else { return nil }
        return key
    }

    private static func tabOrder(_ a: WindowNote, _ b: WindowNote) -> Bool {
        if a.createdAt != b.createdAt { return a.createdAt < b.createdAt }
        return a.id.uuidString < b.id.uuidString
    }

    /// Last-used tab wins; nonblank notes are preferred after restart.
    private static func pickSelectedID(from tabs: [WindowNote]) -> UUID? {
        guard !tabs.isEmpty else { return nil }
        let pool = tabs.contains(where: { $0.hasContent })
            ? tabs.filter({ $0.hasContent }) : tabs
        return pool.max(by: {
            if $0.lastOpenedAt != $1.lastOpenedAt {
                return $0.lastOpenedAt < $1.lastOpenedAt
            }
            return $0.id.uuidString < $1.id.uuidString
        })?.id
    }

    /// UI contract: tabs of the active application in stable tab order.
    /// UI reads returned models only, never mutates them.
    var activeTabNotes: [WindowNote] {
        guard let active = activeSession,
              let key = Self.notebookKey(
                  bundleIdentifier: active.metadata.bundleIdentifier
              ),
              let book = appNotebooks[key] else { return [] }
        return book.tabs
    }

    /// UI contract: create an in-memory empty tab and select it. The current
    /// tab is saved first; on failure current text/selection is preserved.
    @discardableResult
    func addTab(editorText: String) -> Bool {
        guard let active = activeSession,
              let key = Self.notebookKey(
                  bundleIdentifier: active.metadata.bundleIdentifier
              ),
              let book = appNotebooks[key],
              isTriggeringEnabled else { return false }
        updateEditorText(editorText, for: active)
        guard flush(active) else { return false }
        markTabDirty(false, noteID: active.note.id)
        let blank = makeBlankTab(
            appKey: key,
            target: active.metadata,
            identity: active.identity
        )
        // ponytail: blank drafts stay in memory; the first content save
        // persists them via the shared per-note autosave.
        book.tabs.append(blank)
        let autosave = makeTabAutosave(for: blank, bundleID: key)
        autosave.load("")
        book.autosaves[blank.id] = autosave
        book.dirty[blank.id] = false
        selectTabID(blank.id, in: book)
        refreshSaveError()
        return true
    }

    /// UI contract: select a tab. The current tab is saved first; on failure
    /// current text/selection is preserved and selection never moves.
    @discardableResult
    func selectTab(noteID: UUID, editorText: String) -> Bool {
        guard let active = activeSession,
              let key = Self.notebookKey(
                  bundleIdentifier: active.metadata.bundleIdentifier
              ),
              let book = appNotebooks[key],
              book.tabs.contains(where: { $0.id == noteID }),
              isTriggeringEnabled else { return false }
        updateEditorText(editorText, for: active)
        guard flush(active) else { return false }
        markTabDirty(false, noteID: active.note.id)
        // ponytail: selection moves only after the previous tab saved.
        selectTabID(noteID, in: book)
        refreshSaveError()
        return true
    }

    /// UI contract: close a tab. The current tab is saved first; on failure
    /// current text/selection is preserved. A nonblank tab is archived
    /// (recoverable in Archive); a blank tab is discarded; closing the last
    /// tab creates one empty tab.
    @discardableResult
    func closeTab(noteID: UUID, editorText: String) -> Bool {
        guard let active = activeSession,
              let key = Self.notebookKey(
                  bundleIdentifier: active.metadata.bundleIdentifier
              ),
              let book = appNotebooks[key],
              let index = book.tabs.firstIndex(where: { $0.id == noteID }),
              isTriggeringEnabled else { return false }
        updateEditorText(editorText, for: active)
        guard flush(active) else { return false }
        markTabDirty(false, noteID: active.note.id)
        // Flush the closing tab itself so an inactive dirty tab is saved
        // before deciding blank vs nonblank; failure preserves everything.
        if let closing = book.autosaves[noteID],
           book.dirty[noteID] == true || closing.isDirty {
            switch closing.forceFlush() {
            case .success:
                markTabDirty(false, noteID: noteID)
            case .failure(let error):
                setSaveError(error)
                return false
            }
        }
        guard let closingTab = book.tabs.first(where: { $0.id == noteID })
        else { return false }
        if closingTab.hasContent {
            let oldArchived = closingTab.archived
            let oldUpdatedAt = closingTab.updatedAt
            closingTab.archived = true
            closingTab.markUpdated()
            markTabDirty(true, noteID: noteID)
            let (saved, error) = saveRepository(note: closingTab)
            guard saved else {
                closingTab.archived = oldArchived
                closingTab.updatedAt = oldUpdatedAt
                markTabDirty(true, noteID: noteID)
                setSaveError(error)
                return false
            }
        } else {
            // ponytail: clearing only removes the stored row by UUID; the
            // live draft object stays valid for Undo until discarded here.
            let (saved, error) = saveRepository(note: closingTab)
            guard saved else {
                setSaveError(error)
                return false
            }
        }
        book.tabs.remove(at: index)
        book.autosaves.removeValue(forKey: noteID)
        book.dirty.removeValue(forKey: noteID)
        if book.tabs.isEmpty {
            let blank = makeBlankTab(
                appKey: key,
                target: active.metadata,
                identity: active.identity
            )
            book.tabs.append(blank)
            let autosave = makeTabAutosave(for: blank, bundleID: key)
            autosave.load("")
            book.autosaves[blank.id] = autosave
            book.dirty[blank.id] = false
            selectTabID(blank.id, in: book)
        } else if book.selectedID == noteID {
            let next = book.tabs[min(index, book.tabs.count - 1)]
            selectTabID(next.id, in: book)
        }
        refreshSaveError()
        return true
    }

    private func makeBlankTab(
        appKey: String,
        target: TargetWindowMetadata,
        identity: WindowIdentityResolver.Identity
    ) -> WindowNote {
        WindowNote(
            identityKey: identity.identityKey,
            confidence: identity.confidence,
            bundleIdentifier: appKey,
            applicationName: target.appName,
            windowTitle: target.windowTitle ?? "",
            documentPath: identity.documentPath ?? ""
        )
    }

    private func selectTabID(_ noteID: UUID, in book: AppNotebook) {
        selectTabID(noteID, in: book, touchOpened: true)
    }

    private func selectTabID(
        _ noteID: UUID,
        in book: AppNotebook,
        touchOpened: Bool
    ) {
        guard let tab = book.tabs.first(where: { $0.id == noteID }),
              let autosave = book.autosaves[noteID] else { return }
        book.selectedID = noteID
        if touchOpened {
            tab.markOpened()
            if tab.hasContent { book.dirty[noteID] = true }
        }
        for session in liveSessions
        where Self.notebookKey(
            bundleIdentifier: session.metadata.bundleIdentifier
        ) == book.bundleID {
            session.note = tab
            session.autosave = autosave
            session.requiresRepositorySave = book.dirty[noteID] ?? false
        }
        if let editing = libraryEditing, editing.note.id == noteID {
            editing.requiresRepositorySave = book.dirty[noteID] ?? false
        }
    }

    private func findBookTab(noteID: UUID) -> (AppNotebook, WindowNote)? {
        for book in appNotebooks.values {
            if let tab = book.tabs.first(where: { $0.id == noteID }) {
                return (book, tab)
            }
        }
        return nil
    }

    /// Mirror a per-note dirty flag onto every owner of that note: the
    /// notebook entry, all same-app window sessions sharing its autosave,
    /// and the library editor when it targets the same note.
    private func markTabDirty(_ value: Bool, noteID: UUID) {
        for book in appNotebooks.values
        where book.tabs.contains(where: { $0.id == noteID }) {
            book.dirty[noteID] = value
            for session in liveSessions where session.note.id == noteID {
                session.requiresRepositorySave = value
            }
            if let editing = libraryEditing, editing.note.id == noteID {
                editing.requiresRepositorySave = value
            }
        }
    }

    private func syncBookDirtyFromSession(_ session: LiveSession) {
        if let key = Self.notebookKey(
            bundleIdentifier: session.metadata.bundleIdentifier
        ), let book = appNotebooks[key] {
            book.dirty[session.note.id] = session.requiresRepositorySave
        }
    }

    /// Load the persistent notebook on first use: every existing nonarchived
    /// row for the bundleIdentifier becomes a tab without rewriting rows.
    /// Returns nil only when the fetch itself fails.
    private func ensureNotebook(
        for appKey: String,
        makeBlank: () -> WindowNote
    ) -> AppNotebook? {
        if let book = appNotebooks[appKey] {
            if book.tabs.isEmpty {
                let blank = makeBlank()
                book.tabs.append(blank)
                let autosave = makeTabAutosave(for: blank, bundleID: appKey)
                autosave.load("")
                book.autosaves[blank.id] = autosave
                book.dirty[blank.id] = false
                book.selectedID = blank.id
            }
            return book
        }
        let book = AppNotebook(bundleID: appKey)
        do {
            let stored = try repository.fetchAppNotesThrowing(
                forBundleIdentifier: appKey
            )
            for copy in stored.map({ $0.detachedCopy() }).sorted(by: Self.tabOrder) {
                book.tabs.append(copy)
                let autosave = makeTabAutosave(for: copy, bundleID: appKey)
                autosave.load(copy.noteText)
                book.autosaves[copy.id] = autosave
                book.dirty[copy.id] = false
            }
            if book.tabs.isEmpty {
                let blank = makeBlank()
                book.tabs.append(blank)
                let autosave = makeTabAutosave(for: blank, bundleID: appKey)
                autosave.load("")
                book.autosaves[blank.id] = autosave
                book.dirty[blank.id] = false
                book.selectedID = blank.id
            } else {
                book.selectedID = Self.pickSelectedID(from: book.tabs)
                    ?? book.tabs[0].id
            }
        } catch {
            setSaveError(error)
            return nil
        }
        appNotebooks[appKey] = book
        return book
    }

    /// Fixed-note autosave shared by every same-app window session selected
    /// on this note, so same-app windows never run competing writers.
    private func makeTabAutosave(
        for note: WindowNote,
        bundleID: String
    ) -> AutosaveCoordinator {
        AutosaveCoordinator(
            scheduler: schedulerFactory,
            saveClosure: { [weak self, weak note] text in
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
                self.markTabDirty(true, noteID: note.id)
                let (saved, error) = self.saveRepository(note: note)
                if saved {
                    self.markTabDirty(false, noteID: note.id)
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

    /// Attach a physical window to its application notebook. Window or
    /// document changes update front-window metadata only and never switch
    /// the app notes. Returns nil when a required save failed; the caller
    /// must then keep the existing editor available.
    private func beginAppSession(
        for target: AccessibilityWindowService.ResolvedTargetWindow,
        appKey: String
    ) -> String? {
        if let active = activeSession, isSamePhysicalWindow(active, target) {
            guard ensureNotebook(for: appKey, makeBlank: {
                self.makeBlankTab(
                    appKey: appKey,
                    target: target.metadata,
                    identity: active.identity
                )
            }) != nil else { return nil }
            updateAppSession(active, with: target)
            if let book = appNotebooks[appKey] {
                pointSession(active, toBook: book)
            }
            activeSession = active
            lastBeginSucceeded = true
            return active.autosave.currentText
        }

        if let active = activeSession {
            guard flush(active) else { return nil }
            syncBookDirtyFromSession(active)
            activeSession = nil
        }

        if let existing = findLiveSession(for: target) {
            guard ensureNotebook(for: appKey, makeBlank: {
                self.makeBlankTab(
                    appKey: appKey,
                    target: target.metadata,
                    identity: existing.identity
                )
            }) != nil else { return nil }
            updateAppSession(existing, with: target)
            if let book = appNotebooks[appKey] {
                pointSession(existing, toBook: book)
            }
            activeSession = existing
            lastBeginSucceeded = true
            return existing.autosave.currentText
        }

        let sessionUUID = UUID()
        let identity = resolver.resolve(
            bundleIdentifier: target.metadata.bundleIdentifier,
            documentPath: target.metadata.documentPath,
            documentURL: target.metadata.documentURL,
            windowTitle: target.metadata.windowTitle,
            sessionID: sessionUUID
        )
        guard let book = ensureNotebook(for: appKey, makeBlank: {
            self.makeBlankTab(
                appKey: appKey,
                target: target.metadata,
                identity: identity
            )
        }) else { return nil }
        guard let selectedID = book.selectedID,
              let tab = book.tabs.first(where: { $0.id == selectedID }),
              let autosave = book.autosaves[selectedID] else {
            setSaveError(makeError(code: 112, description: L("error.saveFailed")))
            return nil
        }
        let session = LiveSession(
            sessionUUID: sessionUUID,
            runningApplication: target.runningApplication,
            axWindow: target.axWindow,
            axApplication: target.axApplication,
            evidence: target.evidence,
            identity: identity,
            note: tab,
            metadata: target.metadata
        )
        session.requiresRepositorySave = book.dirty[selectedID] ?? false
        session.autosave = autosave
        liveSessions.append(session)
        activeSession = session
        lastBeginSucceeded = true
        return session.autosave.currentText
    }

    private func pointSession(_ session: LiveSession, toBook book: AppNotebook) {
        guard let selectedID = book.selectedID,
              let tab = book.tabs.first(where: { $0.id == selectedID }),
              let autosave = book.autosaves[selectedID] else { return }
        session.note = tab
        session.autosave = autosave
        session.requiresRepositorySave = book.dirty[selectedID] ?? false
    }

    /// Title/frame changes keep the live binding and the selected note.
    private func updateAppSession(
        _ session: LiveSession,
        with target: AccessibilityWindowService.ResolvedTargetWindow
    ) {
        session.metadata = target.metadata
        if let title = target.metadata.windowTitle, !title.isEmpty {
            session.note.windowTitle = title
            session.note.markUpdated()
            markTabDirty(true, noteID: session.note.id)
        }
    }

    /// Remove a tab from every notebook after a successful library
    /// archive/delete, moving selection to a neighbor or a fresh empty tab.
    private func removeBookTab(noteID: UUID, prototype: WindowNote?) {
        for book in appNotebooks.values {
            guard let index = book.tabs.firstIndex(
                where: { $0.id == noteID }
            ) else { continue }
            book.tabs.remove(at: index)
            book.autosaves.removeValue(forKey: noteID)
            book.dirty.removeValue(forKey: noteID)
            if book.tabs.isEmpty {
                let blank = WindowNote(
                    identityKey: prototype?.identityKey ?? book.bundleID,
                    confidence: prototype?.confidence ?? .sessionOnly,
                    bundleIdentifier: book.bundleID,
                    applicationName: prototype?.applicationName ?? "",
                    windowTitle: prototype?.windowTitle ?? "",
                    documentPath: prototype?.documentPath ?? ""
                )
                book.tabs.append(blank)
                let autosave = makeTabAutosave(for: blank, bundleID: book.bundleID)
                autosave.load("")
                book.autosaves[blank.id] = autosave
                book.dirty[blank.id] = false
                selectTabID(blank.id, in: book, touchOpened: false)
            } else if book.selectedID == noteID {
                let next = book.tabs[min(index, book.tabs.count - 1)]
                selectTabID(next.id, in: book, touchOpened: false)
            }
        }
    }

    /// A restored archive rejoins its live notebook in creation order when
    /// that notebook is already loaded; otherwise the next load picks it up.
    private func insertRestoredBookTab(_ note: WindowNote) {
        guard let key = Self.notebookKey(bundleIdentifier: note.bundleIdentifier),
              let book = appNotebooks[key],
              !book.tabs.contains(where: { $0.id == note.id }) else { return }
        book.tabs.append(note)
        book.tabs.sort(by: Self.tabOrder)
        let autosave = makeTabAutosave(for: note, bundleID: key)
        autosave.load(note.noteText)
        book.autosaves[note.id] = autosave
        book.dirty[note.id] = false
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

        // APPLICATION grouping: window/document changes update front-window
        // metadata only and never switch the app notebook.
        if Self.notebookKey(
            bundleIdentifier: session.metadata.bundleIdentifier
        ) != nil {
            updateAppSession(session, with: target)
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
        // ponytail: an inactive tab reuses its notebook object/autosave so
        // the library cannot fork a competing draft of the same note.
        let booked = liveSession == nil ? findBookTab(noteID: note.id) : nil
        let note = liveSession?.note ?? booked?.1 ?? note.detachedCopy()
        let autosave: AutosaveCoordinator
        if let liveSession {
            autosave = liveSession.autosave
        } else if let booked, let existing = booked.0.autosaves[booked.1.id] {
            autosave = existing
        } else if let booked {
            let made = makeTabAutosave(for: booked.1, bundleID: booked.0.bundleID)
            made.load(booked.1.noteText)
            booked.0.autosaves[booked.1.id] = made
            autosave = made
        } else {
            autosave = makeAutosave(for: note, session: nil)
            autosave.load(note.noteText)
        }
        let editing = LibraryEditing(
            note: note,
            autosave: autosave,
            token: token
        )
        editing.requiresRepositorySave = liveSession?.requiresRepositorySave
            ?? booked.map({ $0.0.dirty[$0.1.id] ?? false }) ?? false
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
        markTabDirty(true, noteID: token.noteID)
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
            markTabDirty(false, noteID: editing.note.id)
            refreshSaveError()
            return (true, nil)
        case .failure(let error):
            editing.requiresRepositorySave = true
            markTabDirty(true, noteID: editing.note.id)
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
    var libraryEditorNote: WindowNote? { libraryEditing?.note }
    var libraryEditorText: String? { libraryEditing?.autosave.currentText }
    var hasUnsavedLibraryChanges: Bool { libraryEditing?.hasUnsavedChanges == true }

    /// Return the retained AX binding for a note, without validating it.
    /// Callers must use AccessibilityWindowService.refreshTarget before Raise.
    private func retainedSession(for noteID: UUID) -> LiveSession? {
        if let (book, _) = findBookTab(noteID: noteID) {
            return liveSessions.first {
                Self.notebookKey(bundleIdentifier: $0.metadata.bundleIdentifier) == book.bundleID
            }
        }
        return liveSessions.first { $0.note.id == noteID }
    }

    func liveTarget(for noteID: UUID) -> AccessibilityWindowService.ResolvedTargetWindow? {
        guard let session = retainedSession(for: noteID) else {
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
        guard let session = retainedSession(for: noteID),
              session.runningApplication.isEqual(target.runningApplication),
              CFEqual(session.axWindow, target.axWindow) else {
            return false
        }

        if let (book, _) = findBookTab(noteID: noteID) {
            return Self.notebookKey(bundleIdentifier: target.metadata.bundleIdentifier) == book.bundleID
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
        let (saved, error) = saveRepository(note: editing.note)
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
        markTabDirty(false, noteID: noteID)
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
        let (saved, error) = saveRepository(note: editing.note)
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
        removeBookTab(noteID: noteID, prototype: editing.note)
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
        let (saved, error) = saveRepository(note: editing.note)
        guard saved else {
            editing.note.archived = oldArchived
            editing.note.updatedAt = oldUpdatedAt
            editing.requiresRepositorySave = true
            setSaveError(error)
            return (false, error)
        }

        editing.requiresRepositorySave = false
        _ = endLibraryEditing(token: token)
        insertRestoredBookTab(editing.note)
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
        do {
            try repository.delete(editing.note)
        } catch {
            editing.requiresRepositorySave = true
            setSaveError(error)
            return (false, error)
        }
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
        removeBookTab(noteID: noteID, prototype: editing.note)
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
        markTabDirty(true, noteID: session.note.id)
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
        markTabDirty(true, noteID: session.note.id)
        let (saved, error) = saveRepository(note: session.note)
        guard saved else {
            session.note.pinned = oldPinned
            session.note.updatedAt = oldUpdatedAt
            session.requiresRepositorySave = true
            markTabDirty(true, noteID: session.note.id)
            setSaveError(error)
            return (false, error)
        }

        session.requiresRepositorySave = false
        markTabDirty(false, noteID: session.note.id)
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
        let (saved, error) = saveRepository(note: session.note)
        guard saved else {
            session.note.archived = oldArchived
            session.note.updatedAt = oldUpdatedAt
            session.requiresRepositorySave = true
            setSaveError(error)
            return (false, error)
        }

        session.requiresRepositorySave = false
        markTabDirty(false, noteID: session.note.id)
        removeBookTab(noteID: session.note.id, prototype: session.note)
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
        if let key = Self.notebookKey(
            bundleIdentifier: application.bundleIdentifier
        ), let book = appNotebooks[key] {
            for (id, autosave) in book.autosaves {
                if book.dirty[id] == true || autosave.isDirty {
                    switch autosave.forceFlush() {
                    case .success:
                        markTabDirty(false, noteID: id)
                    case .failure(let error):
                        markTabDirty(true, noteID: id)
                        setSaveError(error)
                    }
                }
            }
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
        for book in appNotebooks.values {
            for (id, autosave) in book.autosaves {
                let identifier = ObjectIdentifier(autosave)
                guard handledAutosaves.insert(identifier).inserted else {
                    continue
                }
                if book.dirty[id] == true || autosave.isDirty {
                    switch autosave.forceFlush() {
                    case .success:
                        markTabDirty(false, noteID: id)
                    case .failure(let error):
                        markTabDirty(true, noteID: id)
                        setSaveError(error)
                        allSucceeded = false
                    }
                } else {
                    markTabDirty(false, noteID: id)
                }
            }
        }
        for (id, draft) in Array(recoveryDrafts) {
            // Recovery also owns unsaved metadata and detached editor drafts.
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
            let booksClean = !appNotebooks.values.contains(where: { book in
                book.dirty.values.contains(true)
                    || book.autosaves.values.contains(where: { $0.isDirty })
            })
            return liveSessions.isEmpty
                && recoveryDrafts.isEmpty
                && libraryEditing == nil
                && booksClean
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
        for book in appNotebooks.values {
            for (id, autosave) in book.autosaves {
                let identifier = ObjectIdentifier(autosave)
                guard handledAutosaves.insert(identifier).inserted else {
                    continue
                }
                if book.dirty[id] == true || autosave.isDirty {
                    switch autosave.forceFlush() {
                    case .success:
                        markTabDirty(false, noteID: id)
                    case .failure(let error):
                        markTabDirty(true, noteID: id)
                        setSaveError(error)
                        allSucceeded = false
                    }
                } else {
                    markTabDirty(false, noteID: id)
                }
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
            guard !isReservedOrReleaseDead(candidate.id) else { return .note(nil) }
            // Flushing a dead window may have removed its newly emptied row.
            let current = try repository.fetchActiveNotesThrowing(forKey: identity.identityKey)
            return .note(current.count == 1 ? current.first : nil)
        } catch {
            return .failure(error)
        }
    }

    /// Validate only the live reservation for this candidate. A dead AX
    /// reference may be released lazily; hidden/minimized and ambiguous AX
    /// results remain reserved so a transient state cannot merge notes.
    private func isReservedOrReleaseDead(_ noteID: UUID) -> Bool {
        if let session = liveSessions.first(where: { $0.note.id == noteID }) {
            switch reservationLiveness(session.runningApplication, session.axWindow) {
            case .alive, .unknown:
                return true
            case .dead:
                _ = flush(session)
                let needsRecovery = session.hasUnsavedChanges
                if needsRecovery { retainRecovery(for: session) }
                removeLiveSession(session)
                return needsRecovery
                    || recoveryDrafts.values.contains { $0.note.id == noteID }
            }
        }

        return recoveryDrafts.values.contains { $0.note.id == noteID }
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
                let (saved, error) = self.saveRepository(note: note)
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
        markTabDirty(true, noteID: session.note.id)
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
            markTabDirty(false, noteID: editing.note.id)
            refreshSaveError()
            return true
        case .failure(let error):
            editing.requiresRepositorySave = true
            markTabDirty(true, noteID: editing.note.id)
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
            markTabDirty(false, noteID: session.note.id)
            refreshSaveError()
            return true
        case .failure(let error):
            session.requiresRepositorySave = true
            markTabDirty(true, noteID: session.note.id)
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
            ?? appNotebooks.values.flatMap({ $0.autosaves.values })
                .compactMap({ $0.lastError }).first
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

    private func saveRepository(note: WindowNote? = nil) -> (Bool, Error?) {
        if let note {
            return repository.saveDraft(note, save: repositorySaveOverride)
        }
        return repositorySaveOverride?() ?? repository.save()
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
