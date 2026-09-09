import AppKit
import SwiftUI

#if SWIFT_PACKAGE
import VersoCore
#endif

/// Manages the status-bar menu and its utility windows.
/// Windows are created once and reused (isReleasedWhenClosed = false).
///
/// Receives the shared PermissionManager and a refresh handler from
/// AppDelegate. Triggers refresh on menu opening and user Refresh action.
@MainActor
final class MenuBarController: NSObject {
    private let statusItem: NSStatusItem
    private(set) var permissionsWindow: NSWindow?
    private(set) var onboardingWindow: NSWindow?
    private var settingsWindow: NSWindow?
    private let permissionManager: PermissionManager
    private let settingsStore: SettingsStore
    private let noteSessionController: NoteSessionController
    private let prepareUtilityHandler: () -> Bool
    private let retryStoreHandler: () -> Void
    private let retrySaveHandler: () -> Bool
    private let refreshHandler: () -> Void
    private let showLibraryHandler: (NoteLibraryController.Category) -> Void

    /// Set by the overlay controller when save errors occur.
    var saveError: Error? {
        didSet { updateMenuIndicators() }
    }

    init(
        statusItem: NSStatusItem,
        permissionManager: PermissionManager,
        noteSessionController: NoteSessionController,
        retryStoreHandler: @escaping () -> Void,
        retrySaveHandler: @escaping () -> Bool,
        refreshHandler: @escaping () -> Void,
        showLibraryHandler: @escaping (NoteLibraryController.Category) -> Void = { _ in },
        settingsStore: SettingsStore? = nil,
        prepareUtilityHandler: @escaping () -> Bool = { true }
    ) {
        self.statusItem = statusItem
        self.permissionManager = permissionManager
        self.settingsStore = settingsStore ?? SettingsStore()
        self.noteSessionController = noteSessionController
        self.prepareUtilityHandler = prepareUtilityHandler
        self.retryStoreHandler = retryStoreHandler
        self.retrySaveHandler = retrySaveHandler
        self.refreshHandler = refreshHandler
        self.showLibraryHandler = showLibraryHandler
        super.init()
        setupMenu()
    }

    // MARK: - Menu

    private func setupMenu() {
        let menu = NSMenu()
        menu.delegate = self

        let header = NSMenuItem()
        header.title = "Verso"
        header.isEnabled = false
        menu.addItem(header)

        menu.addItem(.separator())

        // Store status indicator (shown when store failed).
        let storeStatusItem = NSMenuItem(
            title: L("menu.storeRetry"),
            action: #selector(retryStore),
            keyEquivalent: ""
        )
        storeStatusItem.target = self
        storeStatusItem.isHidden = noteSessionController.isStoreDisabled == false
        storeStatusItem.tag = 9001
        menu.addItem(storeStatusItem)

        // Save error indicator (shown when a save fails).
        let saveErrorItem = NSMenuItem(
            title: L("menu.saveRetry"),
            action: #selector(retrySave),
            keyEquivalent: ""
        )
        saveErrorItem.target = self
        saveErrorItem.isHidden = true
        saveErrorItem.tag = 9002
        menu.addItem(saveErrorItem)

        let searchItem = NSMenuItem(
            title: L("menu.search"),
            action: #selector(showSearch),
            keyEquivalent: ""
        )
        searchItem.target = self
        menu.addItem(searchItem)

        let recentItem = NSMenuItem(
            title: L("menu.recent"),
            action: #selector(showRecent),
            keyEquivalent: ""
        )
        recentItem.target = self
        menu.addItem(recentItem)

        let pinnedItem = NSMenuItem(
            title: L("menu.pinned"),
            action: #selector(showPinned),
            keyEquivalent: ""
        )
        pinnedItem.target = self
        menu.addItem(pinnedItem)

        let archivedItem = NSMenuItem(
            title: L("menu.archived"),
            action: #selector(showArchived),
            keyEquivalent: ""
        )
        archivedItem.target = self
        menu.addItem(archivedItem)

        let permissionsItem = NSMenuItem(
            title: L("menu.permissions"),
            action: #selector(showPermissions),
            keyEquivalent: "p"
        )
        permissionsItem.target = self
        menu.addItem(permissionsItem)

        let onboardingItem = NSMenuItem(
            title: L("menu.howto"),
            action: #selector(showOnboarding),
            keyEquivalent: "h"
        )
        onboardingItem.target = self
        menu.addItem(onboardingItem)

        let settingsItem = NSMenuItem(
            title: L("menu.settings"),
            action: #selector(showSettings),
            keyEquivalent: ","
        )
        settingsItem.target = self
        menu.addItem(settingsItem)

        menu.addItem(.separator())

        let quitItem = NSMenuItem(
            title: L("menu.quit"),
            action: #selector(quitApp),
            keyEquivalent: "q"
        )
        quitItem.target = self
        menu.addItem(quitItem)

        statusItem.menu = menu
    }

    /// Update menu bar indicators for store and save errors.
    private func updateMenuIndicators() {
        guard let menu = statusItem.menu else { return }
        let currentSaveError = noteSessionController.lastSaveError ?? saveError

        // Store status.
        if let item = menu.items.first(where: { $0.tag == 9001 }) {
            item.isHidden = !noteSessionController.isStoreDisabled
        }

        // Save error.
        if let item = menu.items.first(where: { $0.tag == 9002 }) {
            item.isHidden = currentSaveError == nil
            item.toolTip = currentSaveError?.localizedDescription
        }

        // Update status bar icon if there's a save error.
        if let button = statusItem.button {
            if currentSaveError != nil {
                button.image = NSImage(
                    systemSymbolName: "exclamationmark.triangle",
                    accessibilityDescription: L("status.saveError")
                )
            } else if noteSessionController.isStoreDisabled {
                button.image = NSImage(
                    systemSymbolName: "xmark.circle",
                    accessibilityDescription: L("status.storeUnavailable")
                )
            } else {
                button.image = NSImage(
                    systemSymbolName: "note.text",
                    accessibilityDescription: "Verso"
                )
            }
        }
    }

    // MARK: - Actions

    /// Called only after a launch/reopen permission refresh, never on activation.
    func showStartupWindow() {
        if !permissionManager.accessibilityState.isGranted {
            _ = presentPermissions()
        } else if settingsStore.shouldShowOnboarding {
            _ = showOnboardingForFirstUse()
        }
    }

    @objc private func showPermissions() {
        _ = presentPermissions()
    }

    @discardableResult
    private func presentPermissions() -> Bool {
        guard prepareUtilityHandler() else { return false }
        refreshHandler()
        showOrReuse(&permissionsWindow, title: L("window.permissions"), size: NSSize(width: 400, height: 340)) {
            PermissionsView(manager: self.permissionManager)
        }
        return true
    }

    @objc private func showOnboarding() {
        if presentOnboarding() {
            settingsStore.markOnboardingCompleted()
        }
    }

    @discardableResult
    private func presentOnboarding() -> Bool {
        guard prepareUtilityHandler() else { return false }
        showOrReuse(&onboardingWindow, title: L("window.howto"), size: NSSize(width: 420, height: 380)) {
            OnboardingView { [weak self] in
                _ = self?.presentPermissions()
            }
        }
        return true
    }

    @objc private func showSettings() {
        _ = presentSettings()
    }

    /// Handles both the status-item Settings action and the real app-menu
    /// Cmd+, command, so they reuse one retained settings window.
    @discardableResult
    func showSettingsFromCommand() -> Bool {
        presentSettings()
    }

    @discardableResult
    private func presentSettings() -> Bool {
        guard prepareUtilityHandler() else { return false }
        refreshHandler()
        settingsStore.refreshLaunchAtLoginStatus()
        showOrReuse(&settingsWindow, title: L("window.settings"), size: NSSize(width: 380, height: 300)) {
            SettingsView(
                manager: self.permissionManager,
                store: self.settingsStore,
                onOpenPermissions: { [weak self] in
                    _ = self?.presentPermissions()
                }
            )
        }
        return true
    }

    /// Shows first-use guidance once, while the menu's How to Use action keeps
    /// it available later.
    @discardableResult
    func showOnboardingForFirstUse() -> Bool {
        guard presentOnboarding() else { return false }
        settingsStore.markOnboardingCompleted()
        return true
    }

    @objc private func quitApp() {
        NSApp.terminate(nil)
    }

    @objc private func retryStore() {
        retryStoreHandler()
        updateMenuIndicators()
    }

    @objc private func retrySave() {
        let succeeded = retrySaveHandler()
        saveError = succeeded ? nil : noteSessionController.lastSaveError
        updateMenuIndicators()
    }

    @objc private func showSearch() {
        showLibraryHandler(.search)
    }

    @objc private func showRecent() {
        showLibraryHandler(.recent)
    }

    @objc private func showPinned() {
        showLibraryHandler(.pinned)
    }

    @objc private func showArchived() {
        showLibraryHandler(.archived)
    }

    // MARK: - Window management

    /// Reuses an existing retained window or creates one on first use.
    private func showOrReuse<Content: View>(
        _ window: inout NSWindow?,
        title: String,
        size: NSSize,
        @ViewBuilder content: () -> Content
    ) {
        if let existing = window {
            existing.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let hostingView = NSHostingView(rootView: content())
        hostingView.frame = NSRect(origin: .zero, size: size)
        hostingView.layoutSubtreeIfNeeded()
        let fittingSize = hostingView.fittingSize
        let contentSize = NSSize(width: max(size.width, fittingSize.width), height: max(size.height, fittingSize.height))
        hostingView.frame.size = contentSize

        let w = NSWindow(
            contentRect: NSRect(origin: .zero, size: contentSize),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        w.title = title
        w.isReleasedWhenClosed = false
        w.contentMinSize = contentSize
        w.contentView = hostingView
        w.center()

        window = w
        w.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}

// MARK: - NSMenuDelegate

extension MenuBarController: NSMenuDelegate {
    nonisolated func menuWillOpen(_ menu: NSMenu) {
        MainActor.assumeIsolated {
            refreshHandler()
            updateMenuIndicators()
        }
    }
}
