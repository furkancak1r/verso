import AppKit

#if SWIFT_PACKAGE
import VersoCore
#endif

/// Owns the single reusable native note library window. The window is a
/// presentation of the app-owned repository/session state; it never searches
/// or recreates external application windows.
@MainActor
final class NoteLibraryController: NSObject, NSWindowDelegate {
    enum Category: Equatable {
        case search
        case recent
        case pinned
        case archived

        var title: String {
            switch self {
            case .search: return L("library.search")
            case .recent: return L("library.recent")
            case .pinned: return L("library.pinned")
            case .archived: return L("library.archived")
            }
        }
    }

    private let noteSessionController: NoteSessionController
    private let accessibilityWindowService: AccessibilityWindowService
    private let prepareOverlayForLibrary: () -> Bool

    private var window: NSWindow?
    private var libraryView: NoteLibraryView?
    private var rows: [WindowNote] = []
    private var selectedNote: WindowNote?
    private var selectedToken: NoteSessionController.LibraryEditorToken?
    private var category: Category = .recent
    private var query = ""
    private var lastReadError: Error?
    private var statusMessage: String?
    private var isUpdatingSelection = false

    init(
        noteSessionController: NoteSessionController,
        accessibilityWindowService: AccessibilityWindowService,
        prepareOverlayForLibrary: @escaping () -> Bool
    ) {
        self.noteSessionController = noteSessionController
        self.accessibilityWindowService = accessibilityWindowService
        self.prepareOverlayForLibrary = prepareOverlayForLibrary
        super.init()
    }

    var isVisible: Bool { window?.isVisible == true }
    var selectedNoteID: UUID? { selectedNote?.id }
    var currentCategory: Category { category }
    var displayedNotes: [WindowNote] { rows }

    /// Foundation's localized case-insensitive matching is used only for
    /// display search. Identity keys remain byte-for-byte in VersoCore.
    static func matches(_ note: WindowNote, query: String) -> Bool {
        let term = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !term.isEmpty else { return true }
        return [
            note.noteText,
            note.applicationName,
            note.windowTitle,
            note.documentPath
        ].contains {
            $0.range(
                of: term,
                options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive]
            ) != nil
        }
    }

    static func filter(_ notes: [WindowNote], query: String) -> [WindowNote] {
        notes.filter { matches($0, query: query) }
    }

    @discardableResult
    func show(category: Category) -> Bool {
        guard prepareOverlayForLibrary() else { return false }
        guard finishCurrentEditor() else { return false }

        self.category = category
        if category != .search { query = "" }
        ensureWindow()
        libraryView?.searchField.stringValue = query
        statusMessage = nil
        reload()

        guard let window else { return false }
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        if category == .search, let search = libraryView?.searchField {
            _ = window.makeFirstResponder(search)
        }
        return true
    }

    /// Called before a global trigger can take over. A failed save leaves the
    /// library visible and prevents the overlay handoff.
    @discardableResult
    func prepareForOverlay() -> Bool {
        guard isVisible || selectedToken != nil else { return true }
        guard finishCurrentEditor() else { return false }
        window?.orderOut(nil)
        return true
    }

    /// The quit path has already shown the app-level retry/cancel affordance;
    /// this method only closes after the final save has succeeded.
    func closeAfterTermination() {
        _ = finishCurrentEditor()
        window?.orderOut(nil)
    }

    @discardableResult
    func forceSaveForQuit() -> Bool {
        guard finishCurrentEditor() else { return false }
        return noteSessionController.forceSaveAll()
    }

    func refreshIfVisible() {
        guard isVisible else { return }
        reload()
    }

    /// The same native content is used by the window and offscreen UI checks.
    func loadContentView() -> NSView {
        if let libraryView { return libraryView }
        let view = NoteLibraryView()
        view.searchField.target = self
        view.searchField.action = #selector(searchSubmitted(_:))
        view.searchField.delegate = self
        view.categoryControl.target = self
        view.categoryControl.action = #selector(categoryChanged(_:))
        view.tableView.dataSource = self
        view.tableView.delegate = self
        view.retryButton.target = self
        view.retryButton.action = #selector(retryStoreOrRead(_:))
        view.pinButton.target = self
        view.pinButton.action = #selector(togglePin(_:))
        view.archiveButton.target = self
        view.archiveButton.action = #selector(archiveOrRestore(_:))
        view.deleteButton.target = self
        view.deleteButton.action = #selector(deleteSelected(_:))
        view.showWindowButton.target = self
        view.showWindowButton.action = #selector(showSelectedWindow(_:))

        libraryView = view
        return view
    }

    private func ensureWindow() {
        guard window == nil else { return }
        let view = loadContentView()

        let newWindow = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 860, height: 560),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        newWindow.title = L("window.library")
        newWindow.isReleasedWhenClosed = false
        newWindow.contentMinSize = NSSize(width: 700, height: 440)
        newWindow.contentView = view
        newWindow.delegate = self
        newWindow.center()

        window = newWindow
        syncCategoryControl()
        updateView()
    }

    private func reload() {
        guard let view = libraryView else { return }

        do {
            let fetched: [WindowNote]
            switch category {
            case .search, .recent:
                fetched = try noteSessionController.repository
                    .fetchActiveNotesThrowing()
            case .pinned:
                fetched = try noteSessionController.repository
                    .fetchPinnedNotesThrowing()
            case .archived:
                fetched = try noteSessionController.repository
                    .fetchArchivedNotesThrowing()
            }

            rows = Self.filter(fetched, query: query)
            lastReadError = nil
            view.tableView.reloadData()
            restoreOrChooseSelection()
            updateView()
        } catch {
            // Retain the prior rows while showing the read error. An empty
            // table is never presented as a successful fetch in this branch.
            lastReadError = error
            view.tableView.reloadData()
            updateView()
        }
    }

    private func restoreOrChooseSelection() {
        let preferredID = selectedNote?.id
        let row = preferredID.flatMap { id in
            rows.firstIndex { $0.id == id }
        } ?? (rows.isEmpty ? nil : 0)

        isUpdatingSelection = true
        if let row {
            libraryView?.tableView.selectRowIndexes(
                IndexSet(integer: row),
                byExtendingSelection: false
            )
        } else {
            libraryView?.tableView.deselectAll(nil)
        }
        isUpdatingSelection = false

        if let row {
            _ = select(row: row)
        } else {
            guard finishCurrentEditor() else { return }
            selectedNote = nil
            selectedToken = nil
            libraryView?.editor.onTextChange = nil
            libraryView?.editor.setEditingEnabled(false)
            updateView()
        }
    }

    @discardableResult
    private func select(row: Int) -> Bool {
        guard rows.indices.contains(row) else {
            clearSelection()
            return true
        }
        let note = rows[row]
        if selectedNote?.id == note.id, selectedToken != nil {
            updateView()
            return true
        }

        let oldRow = selectedNote.flatMap { old in
            rows.firstIndex { $0.id == old.id }
        }
        guard finishCurrentEditor() else {
            isUpdatingSelection = true
            if let oldRow {
                libraryView?.tableView.selectRowIndexes(
                    IndexSet(integer: oldRow),
                    byExtendingSelection: false
                )
            } else {
                libraryView?.tableView.deselectAll(nil)
            }
            isUpdatingSelection = false
            return false
        }

        guard let start = noteSessionController.beginLibraryEditing(for: note)
        else {
            statusMessage = noteSessionController.lastSaveError?.localizedDescription
            updateView()
            return false
        }

        selectedNote = note
        selectedToken = start.token
        let token = start.token
        libraryView?.editor.onTextChange = { [weak self] text in
            self?.noteSessionController.libraryEditorTextDidChange(
                text,
                token: token
            )
        }
        libraryView?.editor.load(start.text)
        libraryView?.editor.setEditingEnabled(true)
        statusMessage = nil
        updateView()
        return true
    }

    @discardableResult
    private func finishCurrentEditor() -> Bool {
        guard let token = selectedToken,
              let editor = libraryView?.editor else {
            return true
        }

        editor.commitMarkedText()
        let (saved, error) = noteSessionController.commitLibraryEditorAndSave(
            editorText: editor.text,
            token: token
        )
        guard saved else {
            statusMessage = error?.localizedDescription
                ?? L("library.couldNotSave")
            updateView()
            return false
        }

        _ = noteSessionController.endLibraryEditing(token: token)
        selectedToken = nil
        editor.onTextChange = nil
        editor.setEditingEnabled(false)
        return true
    }

    private func clearSelection() {
        guard finishCurrentEditor() else { return }
        selectedNote = nil
        selectedToken = nil
        libraryView?.editor.onTextChange = nil
        libraryView?.editor.setEditingEnabled(false)
        updateView()
    }

    func saveStateDidChange() {
        if noteSessionController.lastSaveError == nil { statusMessage = nil }
        updateStatus()
    }

    private func updateStatus() {
        guard let view = libraryView else { return }

        let errorText = lastReadError?.localizedDescription
            ?? noteSessionController.lastSaveError?.localizedDescription
        if let errorText {
            view.statusLabel.stringValue = "⚠️ " + errorText
            view.statusLabel.textColor = .systemRed
            view.retryButton.isHidden = false
        } else if let statusMessage {
            view.statusLabel.stringValue = statusMessage
            view.statusLabel.textColor = .secondaryLabelColor
            view.retryButton.isHidden = true
        } else if rows.isEmpty {
            let emptyKey: String
            switch category {
            case .archived: emptyKey = "library.emptyArchived"
            case .pinned: emptyKey = "library.emptyPinned"
            default: emptyKey = "library.empty"
            }
            view.statusLabel.stringValue = query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                ? L(emptyKey) : L("library.noMatch")
            view.statusLabel.textColor = .secondaryLabelColor
            view.retryButton.isHidden = true
        } else {
            view.statusLabel.stringValue = ""
            view.retryButton.isHidden = true
        }
    }

    private func updateView() {
        guard let view = libraryView else { return }
        syncCategoryControl()
        updateStatus()

        guard let note = selectedNote else {
            view.detailTitle.stringValue = L("library.selectNote")
            view.detailMetadata.stringValue = ""
            view.editor.isHidden = true
            view.pinButton.isEnabled = false
            view.archiveButton.isEnabled = false
            view.deleteButton.isEnabled = false
            view.showWindowButton.isEnabled = false
            return
        }

        view.editor.isHidden = false
        view.detailTitle.stringValue = note.windowTitle.isEmpty
            ? (note.applicationName.isEmpty ? L("library.untitledNote") : note.applicationName)
            : note.windowTitle
        let metadata = [
            note.applicationName,
            note.documentPath
        ].filter { !$0.isEmpty }.joined(separator: "  •  ")
        view.detailMetadata.stringValue = metadata
        view.pinButton.title = note.pinned ? L("library.unpin") : L("library.pin")
        view.pinButton.isEnabled = !note.archived && selectedToken != nil
        view.archiveButton.title = note.archived ? L("library.restore") : L("library.archive")
        view.archiveButton.isEnabled = selectedToken != nil
        view.deleteButton.isEnabled = selectedToken != nil
        view.showWindowButton.isEnabled = !note.archived
            && validatedLiveTarget(for: note) != nil
    }

    private func syncCategoryControl() {
        guard let control = libraryView?.categoryControl else { return }
        let index: Int
        switch category {
        case .search: index = 0
        case .recent: index = 1
        case .pinned: index = 2
        case .archived: index = 3
        }
        control.selectedSegment = index
    }

    func validatedLiveTarget(
        for note: WindowNote
    ) -> AccessibilityWindowService.ResolvedTargetWindow? {
        guard let retained = noteSessionController.liveTarget(for: note.id),
              case .current(let refreshed) = accessibilityWindowService
                .refreshTarget(retained),
              noteSessionController.liveTargetMatchesNote(
                noteID: note.id,
                target: refreshed
              ) else {
            return nil
        }
        return refreshed
    }

    private func saveError(_ error: Error?) {
        statusMessage = error?.localizedDescription
            ?? L("library.couldNotSave")
        updateView()
    }

    @objc
    private func searchSubmitted(_ sender: NSSearchField) {
        query = sender.stringValue
        if category == .recent { category = .search }
        reload()
    }

    @objc
    private func categoryChanged(_ sender: NSSegmentedControl) {
        let next: Category
        switch sender.selectedSegment {
        case 0: next = .search
        case 2: next = .pinned
        case 3: next = .archived
        default: next = .recent
        }
        guard next != category else { return }
        guard finishCurrentEditor() else {
            syncCategoryControl()
            return
        }
        category = next
        if next != .search { query = "" }
        libraryView?.searchField.stringValue = query
        reload()
    }

    @objc
    private func retryStoreOrRead(_ sender: Any?) {
        if noteSessionController.isStoreDisabled {
            _ = noteSessionController.retryStoreOpen()
        } else {
            _ = noteSessionController.retryPendingSaves()
        }
        statusMessage = nil
        reload()
    }

    @objc
    private func togglePin(_ sender: Any?) {
        guard let note = selectedNote,
              let token = selectedToken,
              let editor = libraryView?.editor else { return }
        editor.commitMarkedText()
        let result = noteSessionController.toggleLibraryPin(
            noteID: note.id,
            editorText: editor.text,
            token: token
        )
        guard result.0 else {
            saveError(result.1)
            return
        }

        statusMessage = note.pinned ? L("library.pinnedStatus") : L("library.unpinnedStatus")
        if category == .pinned && !note.pinned {
            _ = noteSessionController.endLibraryEditing(token: token)
            selectedNote = nil
            selectedToken = nil
            editor.onTextChange = nil
            editor.setEditingEnabled(false)
        }
        reload()
    }

    @objc
    private func archiveOrRestore(_ sender: Any?) {
        guard let note = selectedNote,
              let token = selectedToken,
              let editor = libraryView?.editor else { return }
        editor.commitMarkedText()
        let result: (Bool, Error?)
        if note.archived {
            result = noteSessionController.restoreLibraryNote(
                noteID: note.id,
                editorText: editor.text,
                token: token
            )
        } else {
            result = noteSessionController.archiveLibraryNote(
                noteID: note.id,
                editorText: editor.text,
                token: token
            )
        }
        guard result.0 else {
            saveError(result.1)
            return
        }

        statusMessage = note.archived ? L("library.archivedStatus") : L("library.restoredStatus")
        selectedNote = nil
        selectedToken = nil
        editor.onTextChange = nil
        editor.setEditingEnabled(false)
        reload()
    }

    @objc
    private func deleteSelected(_ sender: Any?) {
        guard let note = selectedNote,
              let token = selectedToken,
              let editor = libraryView?.editor else { return }

        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = L("library.deleteTitle")
        let noteName = note.windowTitle.isEmpty
            ? (note.applicationName.isEmpty ? L("library.untitledNote") : note.applicationName)
            : note.windowTitle
        let path = note.documentPath.isEmpty ? "" : "\n\n" + note.documentPath
        alert.informativeText = noteName + path + L("library.deleteSuffix")
        alert.addButton(withTitle: L("common.delete"))
        alert.addButton(withTitle: L("common.cancel"))
        NSApp.activate(ignoringOtherApps: true)
        guard alert.runModal() == .alertFirstButtonReturn else { return }

        editor.commitMarkedText()
        let result = noteSessionController.deleteLibraryNote(
            noteID: note.id,
            editorText: editor.text,
            token: token
        )
        guard result.0 else {
            saveError(result.1)
            return
        }

        selectedNote = nil
        selectedToken = nil
        editor.onTextChange = nil
        editor.setEditingEnabled(false)
        statusMessage = L("library.deleted")
        reload()
    }

    @objc
    private func showSelectedWindow(_ sender: Any?) {
        guard let note = selectedNote,
              let token = selectedToken,
              let editor = libraryView?.editor else {
            statusMessage = L("library.windowUnavailable")
            updateView()
            return
        }
        editor.commitMarkedText()
        let (saved, error) = noteSessionController.commitLibraryEditorAndSave(
            editorText: editor.text,
            token: token
        )
        guard saved else {
            saveError(error)
            return
        }

        guard let target = validatedLiveTarget(for: note),
              accessibilityWindowService.raiseTarget(target) else {
            statusMessage = L("library.windowUnavailable")
            updateView()
            return
        }

        guard noteSessionController.endLibraryEditing(token: token) else {
            statusMessage = L("library.editorDetached")
            updateView()
            return
        }
        selectedToken = nil
        libraryView?.editor.onTextChange = nil
        libraryView?.editor.setEditingEnabled(false)
        window?.orderOut(nil)
        NSApp.yieldActivation(to: target.runningApplication)
        _ = target.runningApplication.activate(options: [])
    }
}

extension NoteLibraryController: NSSearchFieldDelegate {
    func controlTextDidChange(_ notification: Notification) {
        guard let field = notification.object as? NSSearchField,
              field === libraryView?.searchField else { return }
        searchSubmitted(field)
    }
}

extension NoteLibraryController: NSTableViewDataSource, NSTableViewDelegate {
    func numberOfRows(in tableView: NSTableView) -> Int {
        rows.count
    }

    func tableView(
        _ tableView: NSTableView,
        viewFor tableColumn: NSTableColumn?,
        row: Int
    ) -> NSView? {
        guard rows.indices.contains(row) else { return nil }
        let note = rows[row]
        let cell = NSTableCellView()
        cell.identifier = NSUserInterfaceItemIdentifier("VersoNoteCell")

        let title = NSTextField(labelWithString: note.windowTitle.isEmpty
            ? (note.applicationName.isEmpty ? L("library.untitledNote") : note.applicationName)
            : note.windowTitle)
        title.font = .systemFont(ofSize: 13, weight: .medium)
        title.lineBreakMode = .byTruncatingTail

        let preview = note.noteText
            .components(separatedBy: .newlines)
            .first ?? ""
        let subtitle = NSTextField(labelWithString: preview.isEmpty
            ? note.applicationName
            : preview)
        subtitle.font = .systemFont(ofSize: 11)
        subtitle.textColor = .secondaryLabelColor
        subtitle.lineBreakMode = .byTruncatingTail

        let stack = NSStackView(views: [title, subtitle])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 2
        stack.translatesAutoresizingMaskIntoConstraints = false
        cell.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 8),
            stack.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -8),
            stack.centerYAnchor.constraint(equalTo: cell.centerYAnchor)
        ])
        cell.setAccessibilityLabel(title.stringValue)
        return cell
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        guard !isUpdatingSelection,
              let tableView = libraryView?.tableView else { return }
        let row = tableView.selectedRow
        guard row >= 0 else {
            clearSelection()
            return
        }
        _ = select(row: row)
    }
}

extension NoteLibraryController {
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        guard finishCurrentEditor() else { return false }
        sender.orderOut(nil)
        return false
    }
}

@MainActor
private final class NoteLibraryView: NSView {
    let searchField = NSSearchField()
    let categoryControl = NSSegmentedControl(
        labels: [
            NoteLibraryController.Category.search.title,
            NoteLibraryController.Category.recent.title,
            NoteLibraryController.Category.pinned.title,
            NoteLibraryController.Category.archived.title
        ],
        trackingMode: .selectOne,
        target: nil,
        action: nil
    )
    let tableView = NSTableView()
    let detailTitle = NSTextField(labelWithString: L("library.selectNote"))
    let detailMetadata = NSTextField(labelWithString: "")
    let editor = NativeNoteEditor()
    let statusLabel = NSTextField(labelWithString: "")
    let retryButton = NSButton(title: L("common.retry"), target: nil, action: nil)
    let pinButton = NSButton(title: L("library.pin"), target: nil, action: nil)
    let archiveButton = NSButton(title: L("library.archive"), target: nil, action: nil)
    let deleteButton = NSButton(title: L("common.delete"), target: nil, action: nil)
    let showWindowButton = NSButton(title: L("library.showWindow"), target: nil, action: nil)

    init() {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false

        searchField.placeholderString = L("library.searchPlaceholder")
        searchField.setAccessibilityLabel(L("ax.librarySearch"))
        searchField.translatesAutoresizingMaskIntoConstraints = false

        categoryControl.setAccessibilityLabel(L("ax.libraryView"))
        categoryControl.translatesAutoresizingMaskIntoConstraints = false

        let tableColumn = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("VersoNotes"))
        tableColumn.title = L("library.columnNotes")
        tableView.addTableColumn(tableColumn)
        tableView.headerView = nil
        tableView.rowHeight = 54
        tableView.selectionHighlightStyle = .regular
        tableView.usesAlternatingRowBackgroundColors = true
        tableView.allowsEmptySelection = true
        tableView.setAccessibilityLabel(L("ax.noteList"))

        let tableScroll = NSScrollView()
        tableScroll.documentView = tableView
        tableScroll.hasVerticalScroller = true
        tableScroll.autohidesScrollers = true
        tableScroll.borderType = .bezelBorder
        tableScroll.translatesAutoresizingMaskIntoConstraints = false

        detailTitle.font = .systemFont(ofSize: 18, weight: .semibold)
        detailTitle.lineBreakMode = .byTruncatingTail
        detailTitle.translatesAutoresizingMaskIntoConstraints = false
        detailMetadata.font = .systemFont(ofSize: 12)
        detailMetadata.textColor = .secondaryLabelColor
        detailMetadata.lineBreakMode = .byTruncatingTail
        detailMetadata.translatesAutoresizingMaskIntoConstraints = false

        editor.translatesAutoresizingMaskIntoConstraints = false
        editor.isHidden = true
        editor.setEditingEnabled(false)

        statusLabel.font = .systemFont(ofSize: 12)
        statusLabel.lineBreakMode = .byWordWrapping
        statusLabel.maximumNumberOfLines = 2
        statusLabel.translatesAutoresizingMaskIntoConstraints = false
        retryButton.bezelStyle = .rounded
        retryButton.setAccessibilityLabel(L("ax.retryOp"))
        retryButton.translatesAutoresizingMaskIntoConstraints = false

        for button in [pinButton, archiveButton, deleteButton, showWindowButton] {
            button.bezelStyle = .rounded
            button.translatesAutoresizingMaskIntoConstraints = false
        }
        pinButton.setAccessibilityLabel(L("ax.pinToggle"))
        archiveButton.setAccessibilityLabel(L("ax.archiveToggle"))
        deleteButton.setAccessibilityLabel(L("ax.deleteNote"))
        showWindowButton.setAccessibilityLabel(L("ax.showWindow"))

        let statusStack = NSStackView(views: [statusLabel, retryButton])
        statusStack.orientation = .horizontal
        statusStack.alignment = .centerY
        statusStack.spacing = 8
        statusStack.translatesAutoresizingMaskIntoConstraints = false

        let actionStack = NSStackView(views: [
            showWindowButton, pinButton, archiveButton, deleteButton
        ])
        actionStack.orientation = .horizontal
        actionStack.alignment = .centerY
        actionStack.spacing = 8
        actionStack.translatesAutoresizingMaskIntoConstraints = false

        let detail = NSView()
        detail.translatesAutoresizingMaskIntoConstraints = false
        detail.addSubview(detailTitle)
        detail.addSubview(detailMetadata)
        detail.addSubview(editor)
        detail.addSubview(actionStack)
        NSLayoutConstraint.activate([
            detailTitle.leadingAnchor.constraint(equalTo: detail.leadingAnchor),
            detailTitle.trailingAnchor.constraint(equalTo: detail.trailingAnchor),
            detailTitle.topAnchor.constraint(equalTo: detail.topAnchor),
            detailMetadata.leadingAnchor.constraint(equalTo: detail.leadingAnchor),
            detailMetadata.trailingAnchor.constraint(equalTo: detail.trailingAnchor),
            detailMetadata.topAnchor.constraint(equalTo: detailTitle.bottomAnchor, constant: 4),
            editor.leadingAnchor.constraint(equalTo: detail.leadingAnchor),
            editor.trailingAnchor.constraint(equalTo: detail.trailingAnchor),
            editor.topAnchor.constraint(equalTo: detailMetadata.bottomAnchor, constant: 12),
            editor.bottomAnchor.constraint(equalTo: actionStack.topAnchor, constant: -12),
            actionStack.leadingAnchor.constraint(equalTo: detail.leadingAnchor),
            actionStack.trailingAnchor.constraint(lessThanOrEqualTo: detail.trailingAnchor),
            actionStack.bottomAnchor.constraint(equalTo: detail.bottomAnchor)
        ])

        let contentStack = NSStackView(views: [tableScroll, detail])
        contentStack.orientation = .horizontal
        contentStack.alignment = .height
        contentStack.distribution = .fill
        contentStack.spacing = 16
        contentStack.translatesAutoresizingMaskIntoConstraints = false

        addSubview(searchField)
        addSubview(categoryControl)
        addSubview(contentStack)
        addSubview(statusStack)

        NSLayoutConstraint.activate([
            searchField.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 20),
            searchField.topAnchor.constraint(equalTo: topAnchor, constant: 20),
            searchField.widthAnchor.constraint(equalToConstant: 330),
            categoryControl.leadingAnchor.constraint(equalTo: searchField.trailingAnchor, constant: 12),
            categoryControl.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -20),
            categoryControl.centerYAnchor.constraint(equalTo: searchField.centerYAnchor),
            contentStack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 20),
            contentStack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -20),
            contentStack.topAnchor.constraint(equalTo: searchField.bottomAnchor, constant: 16),
            contentStack.bottomAnchor.constraint(equalTo: statusStack.topAnchor, constant: -10),
            tableScroll.widthAnchor.constraint(equalToConstant: 280),
            detail.widthAnchor.constraint(greaterThanOrEqualToConstant: 360),
            statusStack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 20),
            statusStack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -20),
            statusStack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -16),
            statusStack.heightAnchor.constraint(greaterThanOrEqualToConstant: 20)
        ])
    }

    required init?(coder: NSCoder) { return nil }
}
