import AppKit

#if SWIFT_PACKAGE
import VersoCore
#endif

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem?
    private var menuBarController: MenuBarController?

    let settingsStore = SettingsStore()
    let permissionManager = PermissionManager()
    let axService = AccessibilityWindowService()
    var inputMonitor: GlobalInputMonitor?

    let noteSessionController = NoteSessionController(
        repository: NoteRepository()
    )

    private lazy var overlayController = FlipOverlayWindowController(
        accessibilityWindowService: axService
    )

    private lazy var noteLibraryController = NoteLibraryController(
        noteSessionController: noteSessionController,
        accessibilityWindowService: axService,
        prepareOverlayForLibrary: { [weak self] in
            self?.overlayController.prepareForLibrary() ?? true
        }
    )

    private var didBecomeActiveObserver: NSObjectProtocol?
    private var workspaceDidActivateObserver: NSObjectProtocol?
    private var workspaceDidHideObserver: NSObjectProtocol?
    private var workspaceDidTerminateObserver: NSObjectProtocol?
    private var workspaceSpaceChangeObserver: NSObjectProtocol?
    private var displayConfigObserver: NSObjectProtocol?

    func applicationDidFinishLaunching(_ notification: Notification) {
        settingsStore.applyAppearance()
        Task { @MainActor [weak self] in
            await self?.settingsStore.applyLaunchAtLoginDefaultIfNeeded()
        }

        permissionManager.onRefresh = { [weak self] in
            self?.updateInputMonitoring()
        }

        // Wire the session controller into the overlay controller.
        overlayController.noteSessionController = noteSessionController
        overlayController.onSaveErrorChanged = { [weak self] error in
            // Update menu bar indicator if needed.
            self?.menuBarController?.saveError = error
        }
        noteSessionController.onSaveErrorChanged = { [weak self] error in
            self?.menuBarController?.saveError = error
            self?.noteLibraryController.saveStateDidChange()
        }

        // Open the persistent store. On failure, triggering is disabled with retry.
        noteSessionController.openStore()

        setupStatusBar()
        registerDismissalObservers()
        registerActivationObservers()
        refreshInputMonitoring()
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        while true {
            let overlaySaved = overlayController.forceSaveForQuit()
            let librarySaved = noteLibraryController.forceSaveForQuit()
            guard overlaySaved && librarySaved else {
                let alert = NSAlert()
                alert.alertStyle = .warning
                alert.messageText = L("quit.title")
                let detail = noteSessionController.lastSaveError?.localizedDescription
                    ?? L("error.storeGoneFallback")
                alert.informativeText = L("quit.detail", detail)
                alert.addButton(withTitle: L("common.retry"))
                alert.addButton(withTitle: L("common.cancel"))
                NSApp.activate()
                guard alert.runModal() == .alertFirstButtonReturn else {
                    return .terminateCancel
                }
                continue
            }
            break
        }
        return .terminateNow
    }

    func applicationWillTerminate(_ notification: Notification) {
        removeActivationObservers()
        removeDismissalObservers()

        overlayController.dismissForExternalEvent()
        noteLibraryController.closeAfterTermination()

        inputMonitor?.setAcceptanceCallback(nil)
        inputMonitor?.onErrorChanged = nil
        inputMonitor?.stop()
        inputMonitor = nil

        permissionManager.onRefresh = nil
    }

    private func setupStatusBar() {
        statusItem = NSStatusBar.system.statusItem(
            withLength: NSStatusItem.squareLength
        )

        guard let statusItem = statusItem,
              let button = statusItem.button else {
            return
        }

        button.image = NSImage(
            systemSymbolName: "note.text",
            accessibilityDescription: "Verso"
        )

        menuBarController = MenuBarController(
            statusItem: statusItem,
            permissionManager: permissionManager,
            noteSessionController: noteSessionController,
            retryStoreHandler: { [weak self] in
                guard let self,
                      self.noteSessionController.retryStoreOpen() else {
                    return
                }
                self.refreshInputMonitoring()
            },
            retrySaveHandler: { [weak self] in
                self?.noteSessionController.retryPendingSaves() ?? false
            },
            refreshHandler: { [weak self] in
                self?.refreshInputMonitoring()
            },
            showLibraryHandler: { [weak self] category in
                self?.noteLibraryController.show(category: category)
            },
            settingsStore: settingsStore,
            prepareUtilityHandler: { [weak self] in
                guard let self else { return false }
                return self.noteLibraryController.prepareForOverlay()
                    && self.overlayController.prepareForLibrary()
            }
        )

        if settingsStore.shouldShowOnboarding {
            _ = menuBarController?.showOnboardingForFirstUse()
        }
    }

    @discardableResult
    func showSettingsFromCommand() -> Bool {
        menuBarController?.showSettingsFromCommand() ?? false
    }

    private func handleAcceptedTarget(
        _ resolved: AccessibilityWindowService.ResolvedTargetWindow
    ) -> Bool {
        guard noteSessionController.isTriggeringEnabled,
              noteLibraryController.prepareForOverlay() else { return false }
        return overlayController.accept(resolved)
    }

    private func registerDismissalObservers() {
        let workspaceCenter = NSWorkspace.shared.notificationCenter

        workspaceSpaceChangeObserver = workspaceCenter.addObserver(
            forName: NSWorkspace.activeSpaceDidChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.overlayController.handleSpaceChange()
            }
        }

        displayConfigObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.overlayController.dismissForExternalEvent()
            }
        }
    }

    private func removeDismissalObservers() {
        let workspaceCenter = NSWorkspace.shared.notificationCenter

        if let observer = workspaceSpaceChangeObserver {
            workspaceCenter.removeObserver(observer)
        }

        if let observer = displayConfigObserver {
            NotificationCenter.default.removeObserver(observer)
        }

        workspaceSpaceChangeObserver = nil
        displayConfigObserver = nil
    }

    private func registerActivationObservers() {
        didBecomeActiveObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.refreshInputMonitoring()
                self?.settingsStore.refreshLaunchAtLoginStatus()
            }
        }

        workspaceDidActivateObserver =
            NSWorkspace.shared.notificationCenter.addObserver(
                forName: NSWorkspace.didActivateApplicationNotification,
                object: nil,
                queue: .main
            ) { [weak self] notification in
                MainActor.assumeIsolated {
                    self?.handleWorkspaceActivation(notification)
                }
            }

        workspaceDidTerminateObserver =
            NSWorkspace.shared.notificationCenter.addObserver(
                forName: NSWorkspace.didTerminateApplicationNotification,
                object: nil,
                queue: .main
            ) { [weak self] notification in
                MainActor.assumeIsolated {
                    guard let application = notification.userInfo?[
                        NSWorkspace.applicationUserInfoKey
                    ] as? NSRunningApplication else {
                        return
                    }
                    // Commit and tear down the displayed editor before the
                    // session controller prunes the terminated process.
                    self?.overlayController.applicationDidTerminate(application)
                    self?.noteSessionController.pruneStaleReferences(
                        for: application
                    )
                    self?.noteLibraryController.refreshIfVisible()
                }
            }

        workspaceDidHideObserver =
            NSWorkspace.shared.notificationCenter.addObserver(
                forName: NSWorkspace.didHideApplicationNotification,
                object: nil,
                queue: .main
            ) { [weak self] notification in
                MainActor.assumeIsolated {
                    guard let application = notification.userInfo?[
                        NSWorkspace.applicationUserInfoKey
                    ] as? NSRunningApplication else {
                        return
                    }
                    self?.overlayController.applicationDidHide(application)
                }
            }
    }

    private func removeActivationObservers() {
        if let observer = didBecomeActiveObserver {
            NotificationCenter.default.removeObserver(observer)
        }

        if let observer = workspaceDidActivateObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(observer)
        }
        if let observer = workspaceDidTerminateObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(observer)
        }
        if let observer = workspaceDidHideObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(observer)
        }

        didBecomeActiveObserver = nil
        workspaceDidActivateObserver = nil
        workspaceDidHideObserver = nil
        workspaceDidTerminateObserver = nil
    }

    private func handleWorkspaceActivation(_ notification: Notification) {
        guard let activated = notification.userInfo?[NSWorkspace.applicationUserInfoKey]
                  as? NSRunningApplication,
              let frontmost = NSWorkspace.shared.frontmostApplication,
              activated.isEqual(frontmost) else {
            refreshInputMonitoring()
            return
        }
        overlayController.applicationDidActivate(frontmost)
        refreshInputMonitoring()
    }

    func refreshInputMonitoring() {
        permissionManager.refreshStates()
    }

    private func updateInputMonitoring() {
        overlayController.screenRecordingPermissionDidChange(
            isGranted: permissionManager.screenRecordingState.isGranted
        )

        guard noteSessionController.isTriggeringEnabled else {
            overlayController.dismissForExternalEvent()
            inputMonitor?.stop()
            permissionManager.inputMonitorError = nil
            return
        }

        if permissionManager.accessibilityState.isGranted {
            if inputMonitor == nil {
                let monitor = GlobalInputMonitor(axService: axService)
                monitor.onErrorChanged = { [weak self] error in
                    self?.handleInputMonitorError(error)
                }
                inputMonitor = monitor
            }

            inputMonitor?.setAcceptanceCallback { [weak self] resolved in
                self?.handleAcceptedTarget(resolved) ?? false
            }

            guard let monitor = inputMonitor else { return }

            if let error = monitor.start() {
                permissionManager.inputMonitorError = error
                overlayController.dismissForExternalEvent()
            } else {
                permissionManager.inputMonitorError = nil
            }
        } else {
            overlayController.dismissForExternalEvent()
            inputMonitor?.stop()
            permissionManager.inputMonitorError = nil
        }
    }

    private func handleInputMonitorError(
        _ error: GlobalInputMonitor.TapError?
    ) {
        permissionManager.inputMonitorError = error

        if error != nil {
            overlayController.dismissForExternalEvent()
        }
    }
}
