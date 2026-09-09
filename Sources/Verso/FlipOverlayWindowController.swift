import AppKit
import ApplicationServices

#if SWIFT_PACKAGE
import VersoCore
#endif

@MainActor
final class FlipOverlayWindowController: NSObject, NSWindowDelegate {
    private var overlayWindow: FlipOverlayWindow?
    private var activeTarget: AccessibilityWindowService.ResolvedTargetWindow?
    private var lifecycle = FlipLifecycleState()
    private let captureService = WindowCaptureService()
    private let captureResource = TemporaryCaptureResource()
    private let backdropResource = TemporaryCaptureResource()
    private var captureTask: Task<Void, Never>?
    private var captureRevision: UInt64?
    private var flipAnimator: FlipAnimationController?
    private var noteText = ""
    private var targetRevision: UInt64 = 0
    private var currentTargetFrame: CGRect?
    private var hiddenRetainingEditor = false
    private var pendingFrameSync: DispatchWorkItem?
    private var applyingTargetFrame = false
    private var sourceWindowNumber: CGWindowID?
    private var spaceRecheck: DispatchWorkItem?
    private var controlsRecheck: DispatchWorkItem?
    private var operationCheck: Task<Void, Never>?

    private let accessibilityWindowService: AccessibilityWindowService
    private let observationService: WindowObservationService

    /// Session controller for persistence. Injected by AppDelegate.
    var noteSessionController: NoteSessionController?

    /// Called when a save error needs to be surfaced to the user (e.g. menu bar indicator).
    var onSaveErrorChanged: ((Error?) -> Void)?

    init(
        accessibilityWindowService: AccessibilityWindowService? = nil,
        observationService: WindowObservationService? = nil
    ) {
        let resolvedAccessibilityService = accessibilityWindowService
            ?? AccessibilityWindowService()
        self.accessibilityWindowService = resolvedAccessibilityService
        self.observationService = observationService
            ?? WindowObservationService(
                accessibilityWindowService: resolvedAccessibilityService
            )
        super.init()
    }

    @discardableResult
    func accept(
        _ candidate: AccessibilityWindowService.ResolvedTargetWindow
    ) -> Bool {
        guard let appKitFrame = validatedFrame(for: candidate) else {
            return false
        }

        if let current = activeTarget, lifecycle.isActive {
            if isSameTarget(current, candidate) {
                if hiddenRetainingEditor {
                    checkSourceVisibility(attemptsRemaining: 6)
                    return true
                }
                return requestReturn()
            }

            if lifecycle.phase == .noteVisible,
               !flushVisibleEditor() {
                return false
            }
            cleanupForExternalEvent()
        } else if lifecycle.isActive || overlayWindow != nil || activeTarget != nil {
            cleanupForExternalEvent()
        }

        return present(candidate, frame: appKitFrame)
    }

    func dismissForExternalEvent() {
        cleanupForExternalEvent()
    }

    /// Yield the overlay to the library after committing its real editor.
    /// The live session remains reserved so a library edit can reuse its
    /// autosave owner and a later trigger can reattach safely.
    @discardableResult
    func prepareForLibrary() -> Bool {
        guard lifecycle.isActive || overlayWindow != nil || activeTarget != nil
        else { return true }

        let contentView = overlayWindow?.contentView as? OverlayContentView
        contentView?.commitEditing()
        let editorText = contentView?.currentEditorText()
        guard noteSessionController?.yieldActiveOverlay(editorText: editorText)
                ?? true else {
            onSaveErrorChanged?(noteSessionController?.lastSaveError)
            return false
        }

        cancelCapturePreparation()
        lifecycle.cancel()
        flipAnimator?.cancel()
        closeWindowAndClearTarget()
        return true
    }

    /// Route one event from the retained target observer. The observer has
    /// already rejected stale generations; this second check protects the
    /// overlay if a callback races a new lifecycle on the main run loop.
    func handleObservation(_ event: WindowObservationService.Event) {
        guard lifecycle.isCurrentGeneration(event.generation) else { return }

        switch event.kind {
        case .metadataChanged:
            handleObservedMetadataChange(generation: event.generation)
        case .minimized, .applicationHidden:
            hideOverlayRetainingEditor()
        case .deminiaturized:
            checkSourceVisibility(attemptsRemaining: 6)
        case .destroyed:
            cleanupForDestroyedTarget()
        case .focusChanged(let element):
            guard let target = activeTarget else { return }
            switch accessibilityWindowService.focusDecision(
                for: target,
                notifiedElement: element
            ) {
            case .differentValidatedWindow:
                hideOverlayRetainingEditor()
            case .sameTarget, .applicationOnly, .ignore:
                break
            }
        }
    }

    /// Called before NoteSessionController prunes a terminated process. The
    /// editor is committed while it still exists, then the dead reservation
    /// is released without querying its AX element.
    func applicationDidTerminate(_ application: NSRunningApplication) {
        guard let target = activeTarget,
              target.runningApplication.isEqual(application) else {
            return
        }

        let contentView = overlayWindow?.contentView as? OverlayContentView
        contentView?.commitEditing()
        let editorText = contentView?.currentEditorText()

        cancelCapturePreparation()
        lifecycle.cancel()
        flipAnimator?.cancel()
        observationService.stopForProcessTermination()
        noteSessionController?.handleProcessTermination(editorText: editorText)
        onSaveErrorChanged?(noteSessionController?.lastSaveError)
        closeWindowAndClearTarget()
    }

    func applicationDidHide(_ application: NSRunningApplication) {
        guard let target = activeTarget,
              target.runningApplication.isEqual(application) else {
            return
        }
        // ponytail: hide retains the exact editor/content view (undo and
        // selection intact); only destroyed targets free the overlay.
        hideOverlayRetainingEditor()
    }

    // MARK: - Phase 16A window operations

    var isHiddenRetainingEditorForTests: Bool { hiddenRetainingEditor }

    /// Yellow: minimize the retained target; hide the note but keep the
    /// exact editor/content view so undo/selection survive restore.
    func minimizeNote() {
        flushPendingFrameSync()
        guard lifecycle.phase == .noteVisible, let target = activeTarget,
              lifecycle.isCurrentGeneration(lifecycle.generation) else { return }
        guard accessibilityWindowService.operationCapabilities(for: target).canMinimize else {
            (overlayWindow?.contentView as? OverlayContentView)?.showWindowOperationError(L("overlay.minimizeUnsupported"))
            return
        }
        guard flushVisibleEditor() else { return }
        guard accessibilityWindowService.minimizeTarget(target) else {
            (overlayWindow?.contentView as? OverlayContentView)?.showWindowOperationError(L("overlay.windowOpFailed"))
            return
        }
        hideOverlayRetainingEditor()
        verifyTargetOperation(minimized: true, before: target.metadata.frame)
    }

    /// Green: plain = target fullscreen toggle, Option = target zoom.
    func toggleNoteFullscreen(optionZoom: Bool) {
        flushPendingFrameSync()
        guard lifecycle.phase == .noteVisible, let target = activeTarget,
              case .current(let fresh) = accessibilityWindowService.refreshTarget(target) else { return }
        let caps = accessibilityWindowService.operationCapabilities(for: fresh)
        let useZoom = optionZoom || !caps.canFullscreen || sourceWindowNumber == nil
        let supported = useZoom ? caps.canZoom : caps.canFullscreen
        guard supported else {
            (overlayWindow?.contentView as? OverlayContentView)?.showWindowOperationError(
                L(useZoom ? "overlay.zoomUnsupported" : "overlay.fullscreenUnsupported"))
            return
        }
        guard flushVisibleEditor() else { return }
        let accepted = useZoom ? accessibilityWindowService.zoomTargetWindow(fresh)
            : accessibilityWindowService.toggleTargetFullscreen(fresh)
        guard accepted else {
            (overlayWindow?.contentView as? OverlayContentView)?.showWindowOperationError(L("overlay.windowOpFailed"))
            return
        }
        verifyTargetOperation(minimized: false, before: fresh.metadata.frame)
    }

    private func verifyTargetOperation(minimized: Bool, before: CGRect) {
        operationCheck?.cancel()
        let generation = lifecycle.generation
        operationCheck = Task { @MainActor [weak self] in
            for _ in 0..<20 {
                do { try await Task.sleep(nanoseconds: 150_000_000) } catch { return }
                guard let self, !Task.isCancelled, self.lifecycle.isCurrentGeneration(generation),
                      let target = self.activeTarget else { return }
                switch self.accessibilityWindowService.refreshTarget(target) {
                case .minimized where minimized:
                    (self.overlayWindow?.contentView as? OverlayContentView)?.clearWindowOperationError()
                    self.hideOverlayRetainingEditor()
                    return
                case .current(let current) where !minimized && current.metadata.frame != before:
                    (self.overlayWindow?.contentView as? OverlayContentView)?.clearWindowOperationError()
                    self.checkSourceVisibility(attemptsRemaining: 12)
                    return
                case .invalid:
                    return
                default: break
                }
            }
            guard let self, !Task.isCancelled, self.lifecycle.isCurrentGeneration(generation) else { return }
            self.checkSourceVisibility(attemptsRemaining: 0)
            (self.overlayWindow?.contentView as? OverlayContentView)?.showWindowOperationError(L("overlay.windowOpFailed"))
        }
    }

    /// Close dot: save-aware return; dismissal happens only after save.
    func closeNote() { _ = requestReturn() }

    /// Space gating for parent AppDelegate integration: non-source Spaces
    /// hide without destroying the editor; returning restores it.
    /// Parent must call this instead of dismissForExternalEvent on
    /// NSWorkspace.activeSpaceDidChangeNotification (see report).
    func handleSpaceChange() {
        guard lifecycle.phase == .noteVisible else {
            cleanupForExternalEvent()
            return
        }
        hideOverlayRetainingEditor()
        checkSourceVisibility(attemptsRemaining: 12)
    }

    func applicationDidActivate(_ application: NSRunningApplication) {
        guard let target = activeTarget else { return }
        guard lifecycle.phase == .noteVisible else {
            if !application.isEqual(NSRunningApplication.current) { cleanupForExternalEvent() }
            return
        }
        if application.isEqual(target.runningApplication) || application.isEqual(NSRunningApplication.current) {
            checkSourceVisibility(attemptsRemaining: 6)
        } else {
            hideOverlayRetainingEditor()
        }
    }

    // Public window-server metadata binds the exact source window once. The
    // auxiliary overlay's own Space membership is not evidence about its source.
    private func identifySourceWindow(_ target: AccessibilityWindowService.ResolvedTargetWindow) -> CGWindowID? {
        guard let info = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
                as? [[String: Any]] else { return nil }
        let matches = info.filter { row in
            guard (row[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value == target.metadata.pid,
                  (row[kCGWindowLayer as String] as? NSNumber)?.intValue == 0,
                  let bounds = row[kCGWindowBounds as String] as? NSDictionary,
                  let frame = CGRect(dictionaryRepresentation: bounds) else { return false }
            let expected = target.metadata.frame
            return abs(frame.minX-expected.minX) < 2 && abs(frame.minY-expected.minY) < 2
                && abs(frame.width-expected.width) < 2 && abs(frame.height-expected.height) < 2
        }
        guard matches.count == 1 else { return nil }
        return (matches[0][kCGWindowNumber as String] as? NSNumber)?.uint32Value
    }

    private func sourceWindowIsOnActiveSpace() -> Bool {
        guard let number = sourceWindowNumber, let target = activeTarget,
              !target.runningApplication.isTerminated, !target.runningApplication.isHidden,
              let info = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
                as? [[String: Any]] else { return false }
        return info.contains { row in
            (row[kCGWindowNumber as String] as? NSNumber)?.uint32Value == number
                && (row[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value == target.metadata.pid
        }
    }

    private func checkSourceVisibility(attemptsRemaining: Int) {
        spaceRecheck?.cancel()
        spaceRecheck = nil
        guard lifecycle.phase == .noteVisible, let target = activeTarget else { return }
        let front = NSWorkspace.shared.frontmostApplication
        let sourceFocused = accessibilityWindowService.targetIsFocused(target)
        if sourceWindowNumber == nil, sourceFocused, front?.isEqual(target.runningApplication) == true,
           case .current(let fresh) = accessibilityWindowService.refreshTarget(target) {
            sourceWindowNumber = identifySourceWindow(fresh)
        }
        let canShow = sourceFocused && (front?.isEqual(target.runningApplication) == true || front?.isEqual(NSRunningApplication.current) == true)
        if canShow && sourceWindowIsOnActiveSpace() {
            handleObservedMetadataChange(generation: lifecycle.generation)
            restoreOverlayIfRetained(generation: lifecycle.generation)
            return
        }
        hideOverlayRetainingEditor()
        guard attemptsRemaining > 0 else { return }
        let generation = lifecycle.generation
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.lifecycle.isCurrentGeneration(generation) else { return }
            self.checkSourceVisibility(attemptsRemaining: attemptsRemaining - 1)
        }
        spaceRecheck = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15, execute: work)
    }

    /// NSWindowDelegate: user drag / edge resize -> coalesced AX write.
    func windowDidMove(_ notification: Notification) { userFrameDidChange() }
    func windowDidResize(_ notification: Notification) { userFrameDidChange() }

    private func userFrameDidChange() {
        guard lifecycle.phase == .noteVisible, !applyingTargetFrame, !hiddenRetainingEditor,
              pendingFrameSync == nil, let window = overlayWindow, let target = activeTarget else { return }
        let generation = lifecycle.generation
        // ponytail: latest frame every50ms, not a debounce that waits until
        // dragging stops. Only one pending AX write belongs to this window.
        let work = DispatchWorkItem { [weak self, weak window] in
            guard let self, let window, self.overlayWindow === window,
                  self.lifecycle.isCurrentGeneration(generation), let current = self.activeTarget,
                  self.isSameTarget(current, target) else { return }
            self.pendingFrameSync = nil
            guard let height = NSScreen.screens.first?.frame.height,
                  let quartz = CoordinateSpaceConverter.toQuartz(window.frame, screenH: height),
                  let actual = self.accessibilityWindowService.setTargetFrame(current, to: quartz),
                  let frame = CoordinateSpaceConverter.toAppKit(actual, screenH: height) else {
                self.handleObservedMetadataChange(generation: generation)
                (window.contentView as? OverlayContentView)?.showWindowOperationError(L("overlay.windowOpFailed"))
                return
            }
            self.applyingTargetFrame = true
            window.setFrame(frame, display: true)
            self.applyingTargetFrame = false
            self.currentTargetFrame = frame
            (window.contentView as? OverlayContentView)?.clearWindowOperationError()
        }
        pendingFrameSync = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05, execute: work)
    }

    private func flushPendingFrameSync() {
        guard let work = pendingFrameSync else { return }
        work.perform()
        work.cancel()
        pendingFrameSync = nil
    }

    private func hideOverlayRetainingEditor() {
        guard lifecycle.isActive || overlayWindow != nil else { return }
        guard lifecycle.phase == .noteVisible else { cleanupForExternalEvent(); return }
        (overlayWindow?.contentView as? OverlayContentView)?.clearPinFeedback()
        // ponytail: orderOut only; the content/editor view, undo manager and
        // selection stay alive for deminiaturize/restore/Space return.
        pendingFrameSync?.cancel()
        pendingFrameSync = nil
        hiddenRetainingEditor = true
        overlayWindow?.orderOut(nil)
    }

    private func restoreOverlayIfRetained(generation: UInt64) {
        guard hiddenRetainingEditor, let window = overlayWindow,
              activeTarget != nil, lifecycle.isCurrentGeneration(generation),
              lifecycle.phase == .noteVisible else { return }
        guard sourceWindowIsOnActiveSpace(),
              case .current = accessibilityWindowService.refreshTarget(activeTarget!) else { return }
        hiddenRetainingEditor = false
        NSApp.activate()
        (window.contentView as? OverlayContentView)?.clearWindowOperationError()
        window.orderFront(nil)
        window.makeKey()
        (window.contentView as? OverlayContentView)?.focusEditor()
    }

    /// Permission loss uses a neutral front during preparation and completes
    /// an active animation immediately so no accepted pixels remain owned.
    func screenRecordingPermissionDidChange(isGranted: Bool) {
        guard !isGranted,
              let target = activeTarget,
              let window = overlayWindow else {
            return
        }

        switch lifecycle.phase {
        case .preparingFront:
            cancelCapturePreparation()
            captureRevision = targetRevision
            finishFrontPreparation(
                nil,
                target: target,
                window: window,
                generation: lifecycle.generation,
                revision: targetRevision
            )
        case .flippingToNote:
            if flipAnimator?.finishToNote(generation: lifecycle.generation) != true {
                cleanupForExternalEvent()
            }
        case .preparingReturn:
            cancelCapturePreparation()
            captureRevision = targetRevision
            finishReturnPreparation(
                nil,
                target: target,
                window: window,
                generation: lifecycle.generation,
                revision: targetRevision
            )
        case .flippingToWindow:
            // Complete the accepted reverse operation immediately so its
            // native completion releases the fresh image and closes safely.
            if flipAnimator?.finishToWindow(generation: lifecycle.generation)
                != true {
                cleanupForExternalEvent()
            }
        case .idle, .noteVisible, .cleaningUp:
            return
        }
    }

    // MARK: - Pin / Archive

    /// Toggle the current note's pin. Force-saves first. On success the icon
    /// and message follow the persisted value; on failure the old icon stays
    /// and the existing save-error path is preserved.
    func toggleCurrentNotePin() {
        guard let contentView = overlayWindow?.contentView as? OverlayContentView else { return }
        contentView.commitEditing()
        let editorText = contentView.currentEditorText()
        let (ok, err) = noteSessionController?.toggleActiveNotePin(editorText: editorText) ?? (false, nil)
        if ok {
            let pinned = noteSessionController?.activeSession?.note.pinned ?? false
            contentView.showPinSuccess(pinned: pinned)
            onSaveErrorChanged?(nil)
        } else {
            contentView.showPinFailure()
            onSaveErrorChanged?(err)
        }
    }

    /// Archive the current note. Force-saves first; on success, dismisses and
    /// releases the live binding. On failure, text and editing remain available.
    func archiveCurrentNote() {
        guard let contentView = overlayWindow?.contentView as? OverlayContentView else { return }
        contentView.commitEditing()
        let editorText = contentView.currentEditorText()
        let (ok, err) = noteSessionController?.archiveActiveNote(editorText: editorText) ?? (false, nil)
        if ok {
            // Archive succeeded: dismiss the overlay and release bindings.
            if let target = activeTarget {
                cleanupForExternalEvent()
                restoreTarget(target)
            }
        } else {
            onSaveErrorChanged?(err)
        }
    }

    // MARK: - Quit

    /// Called by AppDelegate's applicationShouldTerminate.
    /// Force-saves and returns true if save succeeded (terminate ok) or
    /// false if save failed (cancel termination).
    @discardableResult
    func forceSaveForQuit() -> Bool {
        guard let controller = noteSessionController else {
            return true
        }

        if let contentView = overlayWindow?.contentView as? OverlayContentView {
            contentView.commitEditing()
            let editorText = contentView.currentEditorText()
            let (ok, err) = controller.commitAndSave(editorText: editorText)
            if !ok {
                onSaveErrorChanged?(err)
                return false
            }
        }

        let ok = controller.forceSaveAll()
        if !ok { onSaveErrorChanged?(controller.lastSaveError) }
        return ok
    }

    private func isSameTarget(
        _ current: AccessibilityWindowService.ResolvedTargetWindow,
        _ candidate: AccessibilityWindowService.ResolvedTargetWindow
    ) -> Bool {
        current.metadata.pid == candidate.metadata.pid
            && CFEqual(current.axWindow, candidate.axWindow)
    }

    private func validatedFrame(
        for candidate: AccessibilityWindowService.ResolvedTargetWindow
    ) -> CGRect? {
        guard candidate.metadata.isEligible,
              !candidate.runningApplication.isTerminated,
              candidate.runningApplication.processIdentifier
                  == candidate.metadata.pid else {
            return nil
        }

        let screens = NSScreen.screens
        guard let primaryScreen = screens.first else { return nil }

        let displayFrames = screens.map { $0.frame }
        let screenHeight = primaryScreen.frame.height

        guard CoordinateSpaceConverter.isEligibleOverlayFrame(
            candidate.metadata.frame,
            screenH: screenHeight,
            displayFrames: displayFrames
        ) else {
            return nil
        }

        return CoordinateSpaceConverter.toAppKit(
            candidate.metadata.frame,
            screenH: screenHeight
        )
    }

    @discardableResult
    private func present(
        _ candidate: AccessibilityWindowService.ResolvedTargetWindow,
        frame: CGRect
    ) -> Bool {
        do {
            try lifecycle.startFlip()

            let generation = lifecycle.generation
            activeTarget = candidate
        sourceWindowNumber = identifySourceWindow(candidate)
            targetRevision &+= 1
            currentTargetFrame = frame

            if let controller = noteSessionController {
                guard controller.isTriggeringEnabled else {
                    onSaveErrorChanged?(controller.lastSaveError)
                    cleanupForExternalEvent()
                    return false
                }
            }

            // Begin note session (determines initial text).
            let sessionText: String
            if let controller = noteSessionController {
                guard let text = controller.beginSessionIfPossible(for: candidate)
                else {
                    onSaveErrorChanged?(controller.lastSaveError)
                    cleanupForExternalEvent()
                    return false
                }
                sessionText = text
            } else {
                sessionText = ""
            }
            noteText = sessionText

            let window = makeWindow(
                frame: frame,
                target: candidate
            )
            overlayWindow = window

            // Register the target before making the overlay visible. A
            // partial AXObserver setup rejects this presentation safely.
            guard observationService.start(
                for: candidate,
                generation: generation,
                handler: { [weak self] event in
                    self?.handleObservation(event)
                }
            ) else {
                cleanupForExternalEvent()
                return false
            }

            NSApp.activate()

            guard isCurrentPresentation(window, generation: generation) else {
                cleanupForExternalEvent()
                return false
            }

            // Show window but do NOT make key yet — it is transparent during
            // capture preparation so the original window stays interactive.
            window.orderFront(nil)

            guard isCurrentPresentation(window, generation: generation),
                  window.isVisible, window.isOnActiveSpace else {
                cleanupForExternalEvent()
                return false
            }

            beginFrontPreparation(
                target: candidate,
                window: window,
                generation: generation
            )

            return true
        } catch {
            cleanupForExternalEvent()
            return false
        }
    }

    private func isCurrentPresentation(
        _ window: FlipOverlayWindow,
        generation: UInt64
    ) -> Bool {
        guard let currentWindow = overlayWindow else { return false }

        return currentWindow === window
            && activeTarget != nil
            && lifecycle.isCurrentGeneration(generation)
    }

    private func handleObservedMetadataChange(generation: UInt64) {
        guard let target = activeTarget,
              let window = overlayWindow,
              lifecycle.isCurrentGeneration(generation) else {
            return
        }

        switch accessibilityWindowService.refreshTarget(target) {
        case .invalid:
            cleanupForExternalEvent()

        case .minimized:
            hideOverlayRetainingEditor()
        case .current(let refreshed):
            guard let frame = validatedFrame(for: refreshed) else {
                cleanupForExternalEvent()
                return
            }

            let contentView = window.contentView as? OverlayContentView
            contentView?.commitEditing()
            let editorText = contentView?.currentEditorText()
            let metadataResult = noteSessionController?.handleObservedMetadata(
                for: refreshed,
                editorText: editorText
            ) ?? .unchanged

            switch metadataResult {
            case .documentChanged, .documentChangedSaveFailed:
                // The old note was flushed or retained as recovery before
                // this point. Do not let the old editor remain on document B.
                cleanupForExternalEvent()
                return
            case .unchanged:
                break
            }

            targetRevision &+= 1
            activeTarget = refreshed
            currentTargetFrame = frame
            window.title = refreshed.metadata.displayTitle
            contentView?.updateTargetMetadata(
                appName: refreshed.metadata.appName,
                windowTitle: refreshed.metadata.windowTitle
            )
            // An AX echo from an earlier drag sample must not overwrite a
            // newer pointer position that is waiting to be sent.
            if pendingFrameSync == nil || NSEvent.pressedMouseButtons & 1 == 0 {
                pendingFrameSync?.cancel()
                pendingFrameSync = nil
                applyingTargetFrame = true
                window.setFrame(frame, display: true, animate: false)
                applyingTargetFrame = false
            }

            // A movement/title notification during a pending capture makes
            // that capture stale. Finish with a neutral face; never recapture
            // merely because a window moved.
            switch lifecycle.phase {
            case .preparingFront:
                cancelCapturePreparation()
                captureRevision = targetRevision
                finishFrontPreparation(
                    nil,
                    target: refreshed,
                    window: window,
                    generation: generation,
                    revision: targetRevision
                )
            case .preparingReturn:
                cancelCapturePreparation()
                captureRevision = targetRevision
                finishReturnPreparation(
                    nil,
                    target: refreshed,
                    window: window,
                    generation: generation,
                    revision: targetRevision
                )
            case .flippingToNote, .flippingToWindow:
                // The in-flight animation belongs to the prior geometry and
                // title. Release its pixels instead of stretching a stale face.
                cleanupForExternalEvent()
            case .idle, .noteVisible, .cleaningUp:
                break
            }
        }
    }

    private func beginFrontPreparation(
        target: AccessibilityWindowService.ResolvedTargetWindow,
        window: FlipOverlayWindow,
        generation: UInt64
    ) {
        // Reduce Motion: skip capture, immediate note transition.
        if NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            captureRevision = targetRevision
            finishFrontPreparation(nil, target: target, window: window,
                                   generation: generation, revision: targetRevision)
            return
        }

        captureTask?.cancel()
        let revision = targetRevision
        captureRevision = revision
        captureTask = captureService.capture(for: target) { [weak self, weak window] packet in
            guard let self, let window else { return }
            self.finishFrontPreparation(
                packet,
                target: target,
                window: window,
                generation: generation,
                revision: revision
            )
        }
    }

    /// Immediate note transition for nil capture, unsupported geometry, or
    /// other non-recoverable preparation failures.
    private func immediateNoteTransition(
        window: FlipOverlayWindow,
        generation: UInt64
    ) {
        guard let contentView = window.contentView as? OverlayContentView else {
            cleanupForExternalEvent()
            return
        }
        captureResource.clear()
        backdropResource.clear()
        contentView.revealNoteSurface()
        window.alphaValue = 1.0
        window.hasShadow = true
        window.ignoresMouseEvents = false
        window.makeKey()
        if let cv = window.contentView {
            _ = window.makeFirstResponder(cv)
        }
        do {
            try lifecycle.transition(to: .flippingToNote)
            try lifecycle.transition(to: .noteVisible)
            contentView.setEditingEnabled(true)
            contentView.focusEditor()
        } catch {
            cleanupForExternalEvent()
        }
    }

    private func finishFrontPreparation(
        _ packet: CapturePacket?,
        target: AccessibilityWindowService.ResolvedTargetWindow,
        window: FlipOverlayWindow,
        generation: UInt64,
        revision: UInt64
    ) {
        guard !Task.isCancelled else { return }

        guard lifecycle.isCurrentGeneration(generation),
              captureRevision == revision,
              lifecycle.phase == .preparingFront,
              overlayWindow === window,
              let currentTarget = activeTarget,
              isSameTarget(currentTarget, target) else {
            return
        }

        guard isTargetViable(target) else {
            cleanupForExternalEvent()
            return
        }

        captureTask = nil
        captureRevision = nil

        // nil capture → immediate note (no canvas expansion).
        guard let packet else {
            immediateNoteTransition(window: window, generation: generation)
            return
        }

        // Reduce Motion that arrived during capture → immediate note.
        if NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            immediateNoteTransition(window: window, generation: generation)
            return
        }

        // Compute expanded canvas in AppKit coordinates.
        guard let targetFrame = currentTargetFrame,
              let screenHeight = NSScreen.screens.first?.frame.height,
              let canvasFrameAppKit = CoordinateSpaceConverter.toAppKit(
                  packet.canvasFrame, screenH: screenHeight
              ) else {
            immediateNoteTransition(window: window, generation: generation)
            return
        }

        let faceOrigin = CGPoint(
            x: targetFrame.origin.x - canvasFrameAppKit.origin.x,
            y: targetFrame.origin.y - canvasFrameAppKit.origin.y
        )
        let faceFrame = CGRect(origin: faceOrigin, size: targetFrame.size)

        do {
            try lifecycle.transition(to: .flippingToNote)

            guard let contentView = window.contentView as? OverlayContentView else {
                cleanupForExternalEvent()
                return
            }

            // Atomically: expand window → install backdrop/front → show.
            window.setFrame(canvasFrameAppKit, display: false)
            contentView.installExpandedLayout(faceFrame: faceFrame)
            contentView.configureFaceShadow()
            backdropResource.attach(packet.backdropImage, to: contentView.backdropLayer)
            contentView.showBackdrop()

            contentView.prepareFront(hasSnapshot: true)
            captureResource.clear()
            captureResource.attach(packet.windowImage, to: contentView.frontCaptureLayer)

            window.alphaValue = 1.0
            window.hasShadow = false
            window.ignoresMouseEvents = true
            window.makeKey()
            if let cv = window.contentView {
                _ = window.makeFirstResponder(cv)
            }

            let depth = max(
                FlipAnimationController.defaultPerspectiveDepth,
                targetFrame.width * 4
            )
            let animator = FlipAnimationController(
                containerLayer: contentView.flipContainerLayer,
                frontLayer: contentView.frontFaceLayer,
                backLayer: contentView.noteSurfaceLayer,
                perspectiveDepth: depth
            )
            flipAnimator = animator
            animator.start(
                generation: generation,
                reduceMotion: !contentView.hasNoteSnapshot,
                onEdge: { [weak self, weak contentView] callbackGeneration in
                    guard let self,
                          self.lifecycle.isCurrentGeneration(callbackGeneration),
                          self.lifecycle.phase == .flippingToNote else {
                        return
                    }

                    self.captureResource.clear()
                    contentView?.revealNoteSurface()
                },
                completion: { [weak self, weak window] callbackGeneration in
                    guard let self, let window else { return }
                    self.finishNoteFlip(
                        window: window,
                        generation: callbackGeneration
                    )
                }
            )
        } catch {
            cleanupForExternalEvent()
        }
    }

    private func finishNoteFlip(
        window: FlipOverlayWindow,
        generation: UInt64
    ) {
        guard lifecycle.isCurrentGeneration(generation),
              lifecycle.phase == .flippingToNote,
              overlayWindow === window else {
            return
        }

        guard let target = activeTarget, isTargetViable(target) else {
            cleanupForExternalEvent()
            return
        }

        captureResource.clear()

        // Tighten to target frame, clear backdrop, restore native shadow.
        backdropResource.clear()
        if let contentView = window.contentView as? OverlayContentView {
            contentView.restoreTightLayout()
            contentView.removeFaceShadow()
        }
        if let targetFrame = currentTargetFrame {
            window.setFrame(targetFrame, display: false)
        }
        window.hasShadow = true
        window.ignoresMouseEvents = false

        do {
            try lifecycle.transition(to: .noteVisible)
            let contentView = window.contentView as? OverlayContentView
            contentView?.setEditingEnabled(true)
            contentView?.focusEditor()
        } catch {
            cleanupForExternalEvent()
        }
    }

    private func isTargetViable(
        _ target: AccessibilityWindowService.ResolvedTargetWindow
    ) -> Bool {
        guard target.metadata.isEligible,
              !target.runningApplication.isTerminated,
              !target.runningApplication.isHidden,
              target.runningApplication.processIdentifier
                  == target.metadata.pid,
              let metadataBundle = target.metadata.bundleIdentifier,
              let runningBundle = target.runningApplication.bundleIdentifier,
              metadataBundle == runningBundle else {
            return false
        }
        return true
    }

    @discardableResult
    private func requestReturn() -> Bool {
        flushPendingFrameSync()
        let generation = lifecycle.generation
        guard lifecycle.isCurrentGeneration(generation),
              activeTarget != nil,
              overlayWindow != nil else { return false }

        switch lifecycle.phase {
        case .preparingFront, .flippingToNote, .preparingReturn, .flippingToWindow:
            guard let target = activeTarget else {
                cleanupForExternalEvent()
                return true
            }
            cleanupForExternalEvent()
            restoreTarget(target)
            return true
        case .noteVisible:
            return returnToTarget(generation: generation)
        case .idle, .cleaningUp:
            return false
        }
    }

    private func makeWindow(
        frame: CGRect,
        target: AccessibilityWindowService.ResolvedTargetWindow
    ) -> FlipOverlayWindow {
        let window = FlipOverlayWindow(
            contentRect: frame,
            styleMask: [.borderless, .resizable],
            backing: .buffered,
            defer: false
        )

        // Transparent window — the rotating face and backdrop provide all
        // visual content; native shadow is restored at note rest.
        // ponytail: borderless is preserved for the whole-window flip;
        // resizable edges + movable drag are native AppKit, traffic lights
        // are header dots wired to the retained AX target.
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = false
        window.alphaValue = 0.0
        window.ignoresMouseEvents = true
        window.level = .floating
        window.isMovable = accessibilityWindowService.operationCapabilities(for: target).canMove
        window.isMovableByWindowBackground = false
        window.hidesOnDeactivate = false
        window.collectionBehavior = [.fullScreenAuxiliary, .canJoinAllApplications]
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.title = target.metadata.displayTitle
        window.setFrame(frame, display: false)

        let returnAction: () -> Void = { [weak self, weak window] in
            guard let self, let window, self.overlayWindow === window else { return }
            _ = self.requestReturn()
        }
        let pinAction: () -> Void = { [weak self, weak window] in
            guard let self, let window, self.overlayWindow === window,
                  self.lifecycle.phase == .noteVisible else { return }
            self.toggleCurrentNotePin()
        }
        let archiveAction: () -> Void = { [weak self, weak window] in
            guard let self, let window, self.overlayWindow === window,
                  self.lifecycle.phase == .noteVisible else { return }
            self.archiveCurrentNote()
        }
        let contentView = OverlayContentView(
            appName: target.metadata.appName,
            windowTitle: target.metadata.windowTitle,
            appIcon: target.runningApplication.icon,
            initialText: noteText,
            isPinned: noteSessionController?.activeSession?.note.pinned ?? false,
            backAction: returnAction,
            onTextChange: { [weak self, weak window] text in
                guard let self, let window, self.overlayWindow === window else { return }
                self.noteText = text
                self.noteSessionController?.editorTextDidChange(
                    text,
                    sessionID: self.noteSessionController?.activeSessionUUID
                )
            },
            onPin: pinAction,
            onArchive: archiveAction
        )


        window.contentView = contentView
        refreshNoteTabs(contentView)
        window.initialFirstResponder = contentView
        window.cancelAction = returnAction
        window.headerReturnAction = returnAction
        refreshWindowControls(window: window, target: target, contentView: contentView, retries: 2)

        return window
    }

    private func refreshNoteTabs(_ content: OverlayContentView) {
        guard let controller = noteSessionController, let selected = controller.activeSession?.note else { return }
        noteText = selected.noteText
        content.configureTabs(controller.activeTabNotes.map {
            OverlayNoteTab(id: $0.id, text: $0.noteText, pinned: $0.pinned)
        }, selectedID: selected.id, onAdd: { [weak self] in
            self?.changeNoteTab { $0.addTab(editorText: $1) }
        }, onSelect: { [weak self] id in
            self?.changeNoteTab { $0.selectTab(noteID: id, editorText: $1) }
        }, onClose: { [weak self] id in
            self?.changeNoteTab { $0.closeTab(noteID: id, editorText: $1) }
        })
    }

    private func changeNoteTab(_ operation: (NoteSessionController, String) -> Bool) {
        guard lifecycle.phase == .noteVisible, let controller = noteSessionController,
              let content = overlayWindow?.contentView as? OverlayContentView else { return }
        content.commitEditing()
        guard operation(controller, content.currentEditorText()) else {
            // A native tab button may toggle before its action runs. Restore
            // the controller's selection when saving refuses the switch.
            refreshNoteTabs(content)
            content.showWindowOperationError(L("tabs.saveFailed"))
            content.focusEditor()
            return
        }
        refreshNoteTabs(content)
        content.focusEditor()
    }

    private func refreshWindowControls(window: FlipOverlayWindow,
                                       target: AccessibilityWindowService.ResolvedTargetWindow,
                                       contentView: OverlayContentView, retries: Int) {
        controlsRecheck?.cancel()
        let caps = accessibilityWindowService.operationCapabilities(for: target)
        window.isMovable = caps.canMove
        if caps.canResize { window.styleMask.insert(.resizable) }
        else { window.styleMask.remove(.resizable) }
        let unknown = caps.isKnown ? nil : L("overlay.controlsUnknown")
        contentView.setWindowControls(
            canMinimize: caps.canMinimize && sourceWindowNumber != nil,
            minimizeReason: unknown ?? (sourceWindowNumber == nil ? L("overlay.controlsUnknown") : L("overlay.minimizeUnsupported")),
            canFullscreen: caps.canFullscreen && sourceWindowNumber != nil,
            fullscreenReason: unknown ?? (sourceWindowNumber == nil ? L("overlay.controlsUnknown") : L("overlay.fullscreenUnsupported")),
            canZoom: caps.canZoom,
            zoomReason: unknown ?? L("overlay.zoomUnsupported"),
            onClose: { [weak self, weak window] in
                guard let self, let window, self.overlayWindow === window else { return }
                self.closeNote()
            },
            onMinimize: { [weak self, weak window] in
                guard let self, let window, self.overlayWindow === window else { return }
                self.minimizeNote()
            },
            onZoom: { [weak self, weak window] option in
                guard let self, let window, self.overlayWindow === window else { return }
                self.toggleNoteFullscreen(optionZoom: option)
            }
        )
        guard !caps.isKnown, retries > 0 else { return }
        let generation = lifecycle.generation
        let work = DispatchWorkItem { [weak self, weak window, weak contentView] in
            guard let self, let window, let contentView, self.overlayWindow === window,
                  self.lifecycle.isCurrentGeneration(generation), let current = self.activeTarget,
                  self.isSameTarget(current, target) else { return }
            self.refreshWindowControls(window: window, target: current, contentView: contentView, retries: retries-1)
        }
        controlsRecheck = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25, execute: work)
    }

    @discardableResult
    private func returnToTarget(generation: UInt64) -> Bool {
        guard lifecycle.isCurrentGeneration(generation),
              lifecycle.phase == .noteVisible,
              let target = activeTarget,
              let window = overlayWindow,
              let contentView = window.contentView as? OverlayContentView else {
            return false
        }

        // Commit the native composition before reading the actual editor and
        // do not dismiss until this explicit save succeeds.
        contentView.commitEditing()
        let editorText = contentView.currentEditorText()
        let (saveOk, saveError) = noteSessionController?.commitAndSave(
            editorText: editorText,
            sessionID: noteSessionController?.activeSessionUUID
        ) ?? (true, nil)
        guard saveOk else {
            contentView.setEditingEnabled(true)
            onSaveErrorChanged?(saveError)
            return false
        }

        // ponytail: transient message/timer cleared before the return
        // snapshot and animation, so captures stay clean.
        contentView.clearPinFeedback()
        contentView.commitEditingForReturn()
        cancelCapturePreparation()

        do {
            try lifecycle.transition(to: .preparingReturn)
            beginReturnPreparation(
                target: target,
                window: window,
                generation: generation
            )
            return true
        } catch {
            cleanupForExternalEvent()
            return false
        }
    }

    private func beginReturnPreparation(
        target: AccessibilityWindowService.ResolvedTargetWindow,
        window: FlipOverlayWindow,
        generation: UInt64
    ) {
        // Reduce Motion: skip capture, immediate close/restore.
        if NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            captureRevision = targetRevision
            do {
                try lifecycle.transition(to: .flippingToWindow)
                try lifecycle.transition(to: .cleaningUp)
                closeWindowAndClearTarget()
                try lifecycle.transition(to: .idle)
            } catch {
                cleanupForExternalEvent()
                return
            }
            restoreTarget(target)
            return
        }

        captureTask?.cancel()
        let revision = targetRevision
        captureRevision = revision
        captureTask = captureService.capture(for: target) { [weak self, weak window] packet in
            guard let self, let window else { return }
            self.finishReturnPreparation(
                packet,
                target: target,
                window: window,
                generation: generation,
                revision: revision
            )
        }
    }

    /// Immediate close/restore for nil capture, unsupported geometry, or
    /// other non-recoverable return failures.
    private func immediateReturnClose(
        window: FlipOverlayWindow,
        generation: UInt64
    ) {
        let target = activeTarget
        captureResource.clear()
        backdropResource.clear()
        do {
            try lifecycle.transition(to: .flippingToWindow)
            try lifecycle.transition(to: .cleaningUp)
            closeWindowAndClearTarget()
            try lifecycle.transition(to: .idle)
        } catch {
            cleanupForExternalEvent()
            return
        }
        if let target {
            restoreTarget(target)
        }
    }

    private func finishReturnPreparation(
        _ packet: CapturePacket?,
        target: AccessibilityWindowService.ResolvedTargetWindow,
        window: FlipOverlayWindow,
        generation: UInt64,
        revision: UInt64
    ) {
        guard !Task.isCancelled else { return }

        guard lifecycle.isCurrentGeneration(generation),
              captureRevision == revision,
              lifecycle.phase == .preparingReturn,
              overlayWindow === window,
              let currentTarget = activeTarget,
              isSameTarget(currentTarget, target) else {
            return
        }

        guard isTargetViable(target) else {
            cleanupForExternalEvent()
            return
        }

        captureTask = nil
        captureRevision = nil

        guard let contentView = window.contentView as? OverlayContentView else {
            cleanupForExternalEvent()
            return
        }

        // nil capture → immediate close/restore (no animation).
        guard let packet else {
            immediateReturnClose(window: window, generation: generation)
            return
        }

        // Compute expanded canvas.
        guard let targetFrame = currentTargetFrame,
              let screenHeight = NSScreen.screens.first?.frame.height,
              let canvasFrameAppKit = CoordinateSpaceConverter.toAppKit(
                  packet.canvasFrame, screenH: screenHeight
              ) else {
            immediateReturnClose(window: window, generation: generation)
            return
        }

        let faceOrigin = CGPoint(
            x: targetFrame.origin.x - canvasFrameAppKit.origin.x,
            y: targetFrame.origin.y - canvasFrameAppKit.origin.y
        )
        let faceFrame = CGRect(origin: faceOrigin, size: targetFrame.size)

        do {
            try lifecycle.transition(to: .flippingToWindow)

            // Expand canvas, install backdrop + fresh front image.
            window.hasShadow = false
            window.setFrame(canvasFrameAppKit, display: false)
            contentView.installExpandedLayout(faceFrame: faceFrame)
            contentView.configureFaceShadow()
            backdropResource.attach(packet.backdropImage, to: contentView.backdropLayer)
            contentView.showBackdrop()

            contentView.prepareReverse(hasSnapshot: true)
            captureResource.clear()
            captureResource.attach(packet.windowImage, to: contentView.frontCaptureLayer)

            window.ignoresMouseEvents = true

            let depth = max(
                FlipAnimationController.defaultPerspectiveDepth,
                targetFrame.width * 4
            )
            let animator: FlipAnimationController
            if let existing = flipAnimator {
                animator = existing
            } else {
                animator = FlipAnimationController(
                    containerLayer: contentView.flipContainerLayer,
                    frontLayer: contentView.frontFaceLayer,
                    backLayer: contentView.noteSurfaceLayer,
                    perspectiveDepth: depth
                )
                flipAnimator = animator
            }

            animator.start(
                direction: .toWindow,
                generation: generation,
                reduceMotion: !contentView.hasNoteSnapshot,
                onEdge: { [weak self, weak contentView] callbackGeneration in
                    guard let self,
                          self.lifecycle.isCurrentGeneration(callbackGeneration),
                          self.lifecycle.phase == .flippingToWindow else {
                        return
                    }

                    // Keep the fresh image attached until reverse completion.
                    contentView?.revealFrontSurface()
                },
                completion: { [weak self, weak window] callbackGeneration in
                    guard let self, let window else { return }
                    self.finishWindowFlip(
                        window: window,
                        generation: callbackGeneration
                    )
                }
            )
        } catch {
            cleanupForExternalEvent()
        }
    }

    private func finishWindowFlip(
        window: FlipOverlayWindow,
        generation: UInt64
    ) {
        guard lifecycle.isCurrentGeneration(generation),
              lifecycle.phase == .flippingToWindow,
              overlayWindow === window else {
            return
        }

        guard let target = activeTarget, isTargetViable(target) else {
            cleanupForExternalEvent()
            return
        }

        captureTask = nil
        captureResource.clear()
        backdropResource.clear()

        do {
            try lifecycle.transition(to: .cleaningUp)
            closeWindowAndClearTarget()
            try lifecycle.transition(to: .idle)
        } catch {
            cleanupForExternalEvent()
            return
        }

        restoreTarget(target)
    }

    private func restoreTarget(
        _ target: AccessibilityWindowService.ResolvedTargetWindow
    ) {
        let application = target.runningApplication
        // Raise validates the retained process/window with bounded AX IPC.
        // Activation is reached only after that one public raise path succeeds.
        guard accessibilityWindowService.raiseTarget(target) else {
            return
        }
        NSApp.yieldActivation(to: application)
        _ = application.activate(options: [])
    }

    private func flushVisibleEditor() -> Bool {
        guard let contentView = overlayWindow?.contentView as? OverlayContentView,
              let controller = noteSessionController else {
            return true
        }
        contentView.commitEditing()
        let editorText = contentView.currentEditorText()
        let (ok, error) = controller.commitAndSave(
            editorText: editorText,
            sessionID: controller.activeSessionUUID
        )
        onSaveErrorChanged?(error)
        return ok
    }

    private func cleanupForExternalEvent() {
        let contentView = overlayWindow?.contentView as? OverlayContentView
        contentView?.commitEditing()
        let editorText = contentView?.currentEditorText()

        cancelCapturePreparation()
        lifecycle.cancel()
        flipAnimator?.cancel()
        // External cleanup frees overlay/input/captures even if the final save
        // fails; the controller retains the dirty model/recovery draft.
        noteSessionController?.handleExternalCleanup(editorText: editorText)
        onSaveErrorChanged?(noteSessionController?.lastSaveError)
        closeWindowAndClearTarget()
    }

    private func cleanupForDestroyedTarget() {
        let contentView = overlayWindow?.contentView as? OverlayContentView
        contentView?.commitEditing()
        let editorText = contentView?.currentEditorText()

        cancelCapturePreparation()
        lifecycle.cancel()
        flipAnimator?.cancel()
        // The observer already stopped without removal calls; this is
        // idempotent and keeps the destroyed-element rule explicit here.
        observationService.stopForDestroyedTarget()
        noteSessionController?.handleDestroyedTarget(editorText: editorText)
        onSaveErrorChanged?(noteSessionController?.lastSaveError)
        closeWindowAndClearTarget()
    }

    private func cancelCapturePreparation() {
        captureTask?.cancel()
        captureTask = nil
        captureRevision = nil
        captureResource.clear()
        backdropResource.clear()
    }

    private func closeWindowAndClearTarget() {
        spaceRecheck?.cancel()
        spaceRecheck = nil
        controlsRecheck?.cancel()
        controlsRecheck = nil
        operationCheck?.cancel()
        operationCheck = nil
        sourceWindowNumber = nil
        captureResource.clear()
        backdropResource.clear()
        pendingFrameSync?.cancel()
        pendingFrameSync = nil
        hiddenRetainingEditor = false
        applyingTargetFrame = false
        observationService.stop()
        flipAnimator?.cancel()
        flipAnimator = nil
        currentTargetFrame = nil
        let window = overlayWindow
        overlayWindow = nil
        activeTarget = nil

        guard let window else { return }

        window.delegate = nil
        window.cancelAction = nil
        window.headerReturnAction = nil
        if let contentView = window.contentView as? OverlayContentView {
            contentView.commitEditing()
            contentView.clearAction()
        }
        window.contentView = nil
        window.orderOut(nil)
        window.close()
    }
}

@MainActor
private final class FlipOverlayWindow: NSWindow {
    var cancelAction: (() -> Void)?
    var headerReturnAction: (() -> Void)?

    private var optionHeaderMouseDown = false

    override var canBecomeKey: Bool {
        true
    }

    override func cancelOperation(_ sender: Any?) {
        cancelAction?()
    }

    override func sendEvent(_ event: NSEvent) {
        if event.type == .keyDown,
           (firstResponder as? NSTextView)?.hasMarkedText() != true,
           (contentView as? OverlayContentView)?.handleTabShortcut(event) == true {
            return
        }
        // NSTextView can consume Escape before NSWindow.keyDown. Handle a
        // plain Escape here, while letting an active input method handle its
        // own composition before a subsequent Escape requests a return.
        if event.type == .keyDown, event.keyCode == 53,
           event.modifierFlags.intersection([.command, .control, .option, .shift]).isEmpty,
           (firstResponder as? NSTextView)?.hasMarkedText() != true,
           let cancelAction {
            cancelAction()
            return
        }

        switch event.type {
        case .leftMouseDown:
            optionHeaderMouseDown = isOptionHeaderDown(event)
        case .leftMouseDragged:
            // A completed click, not a drag, is the only local return gesture.
            optionHeaderMouseDown = false
        case .leftMouseUp:
            let completesHeaderClick = optionHeaderMouseDown
                && (contentView as? OverlayContentView)?
                    .isHeaderClickTarget(at: event.locationInWindow) == true
            optionHeaderMouseDown = false
            super.sendEvent(event)
            if completesHeaderClick {
                headerReturnAction?()
            }
            return
        default:
            break
        }

        super.sendEvent(event)
    }

    private func isOptionHeaderDown(_ event: NSEvent) -> Bool {
        let flags = event.modifierFlags.intersection([.command, .control, .option, .shift])
        guard flags == .option,
              let contentView = contentView as? OverlayContentView else {
            return false
        }
        return contentView.isHeaderClickTarget(at: event.locationInWindow)
    }
}
