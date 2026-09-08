import AppKit
import ApplicationServices
import CoreGraphics
import Testing
@testable import Verso
@testable import VersoCore

@MainActor
private final class ObservationBackendRecorder {
    var added: [String] = []
    weak var handle: WindowObservationService.ObserverHandle?
    var contexts: [AnyObject] = []
    var failure: AXError = .failure
    var createCount = 0
    var attachCount = 0
    var detachCount = 0
    var failAtAddIndex: Int?
    var attachResult = true

    func deliver(element: AXUIElement, notification: String, contextIndex: Int? = nil) {
        guard let context = contextIndex.map({ contexts[$0] }) ?? contexts.last else { return }
        deliverWindowObservation(
            element: element, notification: notification,
            refcon: Unmanaged.passUnretained(context).toOpaque()
        )
    }
}

@MainActor
@Suite("WindowObservationService")
struct WindowObservationServiceTests {
    private func target(
        axWindow: AXUIElement = AXUIElementCreateApplication(1234),
        axApplication: AXUIElement? = nil,
        title: String = "Synthetic window",
        path: String? = "/tmp/synthetic.md"
    ) -> AccessibilityWindowService.ResolvedTargetWindow {
        let application = NSRunningApplication.current
        let metadata = TargetWindowMetadata(
            pid: application.processIdentifier,
            bundleIdentifier: application.bundleIdentifier ?? "com.example.verso-test",
            appName: application.localizedName ?? "Verso test",
            windowTitle: title,
            windowRole: TargetWindowMetadata.windowRole,
            windowSubrole: TargetWindowMetadata.standardWindowSubrole,
            documentPath: path,
            documentURL: nil,
            frame: CGRect(x: 20, y: 20, width: 640, height: 480)
        )
        return AccessibilityWindowService.ResolvedTargetWindow(
            metadata: metadata,
            evidence: HitTestEvidence(hitRole: "AXWindow"),
            axWindow: axWindow,
            axApplication: axApplication
                ?? AXUIElementCreateApplication(application.processIdentifier),
            runningApplication: application
        )
    }

    private func service(
        recorder: ObservationBackendRecorder
    ) -> WindowObservationService {
        let backend = WindowObservationService.Backend(
            create: { _ in
                recorder.createCount += 1
                let handle = WindowObservationService.ObserverHandle(
                    add: { _, notification, refcon in
                        if let refcon {
                            recorder.contexts.append(Unmanaged<AnyObject>.fromOpaque(refcon).takeUnretainedValue())
                        }
                        let index = recorder.added.count
                        recorder.added.append(notification)
                        return recorder.failAtAddIndex == index ? recorder.failure : .success
                    },
                    attachToMainRunLoop: {
                        recorder.attachCount += 1
                        return recorder.attachResult
                    },
                    detachFromMainRunLoop: { recorder.detachCount += 1 }
                )
                recorder.handle = handle
                return handle
            },
            validatesTarget: false
        )
        return WindowObservationService(backend: backend)
    }

    @Test("Registers required lifecycle notifications before becoming active")
    func requiredRegistrationAndMainRunLoopAttachment() {
        let recorder = ObservationBackendRecorder()
        let service = service(recorder: recorder)
        let target = target()

        #expect(service.start(for: target, generation: 7) { _ in })
        #expect(service.isObserving)
        #expect(recorder.createCount == 1)
        #expect(recorder.attachCount == 1)
        #expect(recorder.added.contains(kAXUIElementDestroyedNotification as String))
        #expect(recorder.added.contains(kAXWindowMiniaturizedNotification as String))
        #expect(recorder.added.contains(kAXWindowDeminiaturizedNotification as String))
        #expect(recorder.added.contains(kAXFocusedWindowChangedNotification as String))
        #expect(recorder.added.contains(kAXMainWindowChangedNotification as String))

        service.stop()
        #expect(!service.isObserving)
        #expect(recorder.detachCount == 1)
        #expect(recorder.handle == nil)
        service.stop()
        #expect(recorder.detachCount == 1)
        #expect(recorder.handle == nil)
    }

    @Test("Required registration failure rejects the overlay setup and tears down partial state")
    func partialSetupFailure() {
        for failedIndex in 0..<5 {
        let recorder = ObservationBackendRecorder()
        recorder.failAtAddIndex = failedIndex
        let service = service(recorder: recorder)

        #expect(!service.start(for: target(), generation: 1) { _ in })
        #expect(!service.isObserving)
        #expect(recorder.attachCount == 0)
        #expect(recorder.handle == nil)
        #expect(recorder.detachCount == 1)
        }
    }

    @Test("Stale lifecycle callbacks cannot route into a newer observation")
    func staleGenerationRouting() {
        let recorder = ObservationBackendRecorder()
        let service = service(recorder: recorder)
        let first = target()
        var firstEvents = 0
        var secondEvents = 0

        #expect(service.start(for: first, generation: 10) { _ in
            firstEvents += 1
        })
        service.stop()

        #expect(service.start(for: first, generation: 11) { _ in
            secondEvents += 1
        })
        recorder.deliver(
            element: first.axWindow,
            notification: kAXWindowMovedNotification as String,
            contextIndex: 0
        )
        #expect(firstEvents == 0)
        #expect(secondEvents == 0)
        recorder.deliver(
            element: first.axWindow,
            notification: kAXWindowMovedNotification as String
        )

        #expect(firstEvents == 0)
        #expect(secondEvents == 1)
        #expect(service.isObserving)
    }

    @Test("Destroyed element uses local matching and never removes its notification")
    func destroyedElementTeardown() {
        let recorder = ObservationBackendRecorder()
        let service = service(recorder: recorder)
        let target = target()
        var destroyedEvents = 0

        #expect(service.start(for: target, generation: 4) { event in
            if case .destroyed = event.kind { destroyedEvents += 1 }
        })
        recorder.deliver(
            element: target.axWindow,
            notification: kAXUIElementDestroyedNotification as String
        )

        #expect(destroyedEvents == 1)
        #expect(!service.isObserving)
        #expect(service.lastTeardownWasDestroyed)
        #expect(recorder.handle == nil)
        #expect(recorder.detachCount == 1)
    }

    @Test("Process termination detaches without remote AX removal")
    func processTerminationTeardown() {
        let recorder = ObservationBackendRecorder()
        let service = service(recorder: recorder)
        let target = target()

        #expect(service.start(for: target, generation: 5) { _ in })
        service.stopForProcessTermination()

        #expect(!service.isObserving)
        #expect(service.lastTeardownWasProcessTermination)
        #expect(recorder.handle == nil)
        #expect(recorder.detachCount == 1)
    }

    @Test("Nonmatching movement is ignored while focus and minimize route through production callbacks")
    func callbackRoutingDecisions() {
        let recorder = ObservationBackendRecorder()
        let service = service(recorder: recorder)
        let target = target()
        let unrelated = AXUIElementCreateSystemWide()
        var metadataEvents = 0
        var minimizedEvents = 0
        var focusEvents = 0

        #expect(service.start(for: target, generation: 8) { event in
            switch event.kind {
            case .metadataChanged: metadataEvents += 1
            case .minimized: minimizedEvents += 1
            case .focusChanged: focusEvents += 1
            default: break
            }
        })
        recorder.deliver(
            element: unrelated,
            notification: kAXWindowMovedNotification as String
        )
        recorder.deliver(
            element: target.axWindow,
            notification: kAXWindowResizedNotification as String
        )
        recorder.deliver(
            element: target.axWindow,
            notification: kAXWindowMiniaturizedNotification as String
        )
        recorder.deliver(
            element: target.axApplication,
            notification: kAXFocusedWindowChangedNotification as String
        )

        #expect(metadataEvents == 1)
        #expect(minimizedEvents == 1)
        #expect(focusEvents == 1)
    }

    @Test("Only unsupported optional notifications permit partial support", arguments: [AXError.notificationUnsupported, .invalidUIElement, .failure])
    func optionalRegistrationErrors(error: AXError) {
        let recorder = ObservationBackendRecorder()
        recorder.failAtAddIndex = 5
        recorder.failure = error
        let service = service(recorder: recorder)
        let started = service.start(for: target(), generation: 2) { _ in }
        #expect(started == (error == .notificationUnsupported))
        if started {
            #expect(service.unavailableOptionalNotifications.count == 1)
        } else {
            #expect(recorder.handle == nil)
            #expect(recorder.attachCount == 0)
            #expect(recorder.detachCount == 1)
        }
        service.stop()
    }

    @Test("Deinitializing an active service detaches and makes in-flight callbacks inert")
    func activeServiceDeinitialization() {
        let recorder = ObservationBackendRecorder()
        var service: WindowObservationService? = service(recorder: recorder)
        let target = target()
        var events = 0
        #expect(service?.start(for: target, generation: 1) { _ in events += 1 } == true)
        service = nil
        #expect(recorder.detachCount == 1)
        #expect(recorder.handle == nil)
        recorder.deliver(element: target.axWindow, notification: kAXWindowMovedNotification as String)
        #expect(events == 0)
    }

    @Test("Observed exact document changes save and release the old live note")
    func observedDocumentChangeReleasesOldBinding() {
        let repository = NoteRepository()
        let controller = NoteSessionController(
            repository: repository,
            schedulerFactory: { _, _ in nil }
        )
        #expect(controller.openStore(inMemory: true))

        let axWindow = AXUIElementCreateApplication(4321)
        let first = target(axWindow: axWindow, title: "A", path: "/tmp/A.md")
        let second = target(axWindow: axWindow, title: "B", path: "/tmp/B.md")
        #expect(controller.beginSessionIfPossible(for: first) == "")
        #expect(controller.commitAndSave(editorText: "note A").0)

        let result = controller.handleObservedMetadata(
            for: second,
            editorText: "note A"
        )
        if case .documentChanged = result {
        } else {
            Issue.record("Expected the observed exact document change")
        }
        #expect(controller.activeSessionUUID == nil)
        #expect(controller.activeLiveSessionCount == 0)
        let oldKey = controller.resolver.resolve(
            bundleIdentifier: first.metadata.bundleIdentifier,
            documentPath: first.metadata.documentPath,
            documentURL: nil,
            windowTitle: first.metadata.windowTitle
        ).identityKey
        #expect(repository.fetchActiveNotes(forKey: oldKey)[0].noteText == "note A")
    }

    @Test("Observed title changes keep the live reservation")
    func observedTitleChangeKeepsBinding() throws {
        let repository = NoteRepository()
        let controller = NoteSessionController(
            repository: repository,
            schedulerFactory: { _, _ in nil }
        )
        #expect(controller.openStore(inMemory: true))

        let axWindow = AXUIElementCreateApplication(5432)
        let first = target(axWindow: axWindow, title: "A", path: "/tmp/A.md")
        let second = target(axWindow: axWindow, title: "B", path: "/tmp/A.md")
        #expect(controller.beginSessionIfPossible(for: first) == "")
        let sessionID = try #require(controller.activeSessionUUID)
        controller.editorTextDidChange("draft", sessionID: sessionID)

        let result = controller.handleObservedMetadata(for: second)
        if case .unchanged = result {
        } else {
            Issue.record("Expected a title-only metadata update")
        }
        #expect(controller.activeSessionUUID == sessionID)
        #expect(controller.activeSession?.metadata.windowTitle == "B")
        #expect(controller.activeSession?.autosave.currentText == "draft")
    }

    @Test("Destroyed target cleanup commits text and releases its reservation")
    func destroyedTargetReleasesBinding() {
        let repository = NoteRepository()
        let controller = NoteSessionController(
            repository: repository,
            schedulerFactory: { _, _ in nil }
        )
        #expect(controller.openStore(inMemory: true))
        let target = target(axWindow: AXUIElementCreateApplication(6543))
        #expect(controller.beginSessionIfPossible(for: target) == "")

        controller.handleDestroyedTarget(editorText: "destroyed draft")
        #expect(controller.activeSessionUUID == nil)
        #expect(controller.activeLiveSessionCount == 0)
        #expect(controller.recoveryDraftCount == 0)
        let key = controller.resolver.resolve(
            bundleIdentifier: target.metadata.bundleIdentifier,
            documentPath: target.metadata.documentPath,
            documentURL: nil,
            windowTitle: target.metadata.windowTitle
        ).identityKey
        #expect(repository.fetchActiveNotes(forKey: key).first?.noteText == "destroyed draft")
    }

    @Test("Injected bounded decisions avoid protected AX calls in lifecycle tests")
    func injectedRefreshFocusRaiseDecisions() {
        let target = target()
        let service = AccessibilityWindowService(
            refreshOverride: { _ in .minimized(target) },
            focusOverride: { _, _ in .differentValidatedWindow },
            raiseOverride: { _ in true }
        )

        if case .minimized = service.refreshTarget(target) {
        } else {
            Issue.record("Expected injected minimized refresh")
        }
        #expect(service.focusDecision(
            for: target,
            notifiedElement: target.axWindow
        ) == .differentValidatedWindow)
        #expect(service.raiseTarget(target))
    }
}

@MainActor
@Suite("Phase 16A observation and AX window operations")
struct Phase16AObservationTests {
    private func target(
        axWindow: AXUIElement = AXUIElementCreateApplication(1234),
        axApplication: AXUIElement? = nil
    ) -> AccessibilityWindowService.ResolvedTargetWindow {
        let application = NSRunningApplication.current
        let appElement = axApplication ?? AXUIElementCreateApplication(application.processIdentifier)
        let metadata = TargetWindowMetadata(
            pid: application.processIdentifier,
            bundleIdentifier: application.bundleIdentifier ?? "com.verso.app",
            appName: "Synthetic",
            windowTitle: "Synthetic window",
            windowRole: "AXWindow",
            windowSubrole: "AXStandardWindow",
            documentPath: nil,
            documentURL: nil,
            frame: CGRect(x: 0, y: 0, width: 640, height: 462),
            isMinimized: false,
            isOnScreen: true
        )
        return AccessibilityWindowService.ResolvedTargetWindow(
            metadata: metadata,
            evidence: HitTestEvidence(hitRole: "AXWindow"),
            axWindow: axWindow,
            axApplication: appElement,
            runningApplication: application
        )
    }

    private func service(recorder: ObservationBackendRecorder) -> WindowObservationService {
        let backend = WindowObservationService.Backend(
            create: { _ in
                recorder.createCount += 1
                let handle = WindowObservationService.ObserverHandle(
                    add: { _, notification, refcon in
                        if let refcon {
                            recorder.contexts.append(Unmanaged<AnyObject>.fromOpaque(refcon).takeUnretainedValue())
                        }
                        let index = recorder.added.count
                        recorder.added.append(notification)
                        return recorder.failAtAddIndex == index ? recorder.failure : .success
                    },
                    attachToMainRunLoop: {
                        recorder.attachCount += 1
                        return recorder.attachResult
                    },
                    detachFromMainRunLoop: { recorder.detachCount += 1 }
                )
                recorder.handle = handle
                return handle
            },
            validatesTarget: false
        )
        return WindowObservationService(backend: backend)
    }

    @Test("Deminiaturized notification routes with current generation only")
    func deminiaturizedRouting() {
        let recorder = ObservationBackendRecorder()
        let svc = service(recorder: recorder)
        let tgt = target()
        var restored = 0
        #expect(svc.start(for: tgt, generation: 21) { event in
            if case .deminiaturized = event.kind { restored += 1 }
        })
        // New required registration includes deminiaturized.
        #expect(recorder.added.contains(kAXWindowDeminiaturizedNotification as String))
        recorder.deliver(element: tgt.axWindow,
                         notification: kAXWindowDeminiaturizedNotification as String)
        #expect(restored == 1)
        // Stale context cannot restore.
        svc.stop()
        #expect(svc.start(for: tgt, generation: 22) { event in
            if case .deminiaturized = event.kind { restored += 1 }
        })
        recorder.deliver(element: tgt.axWindow,
                         notification: kAXWindowDeminiaturizedNotification as String,
                         contextIndex: 0)
        #expect(restored == 1)
    }

    @Test("Production operations reject a synthetic reference outside the retained process")
    func productionOperationsRejectMismatchedTarget() {
        let service = AccessibilityWindowService()
        let candidate = target()
        #expect(service.setTargetFrame(candidate, to: CGRect(x: 10, y: 10, width: 500, height: 400)) == nil)
        #expect(service.setTargetFrame(candidate, to: CGRect(x: 0, y: 0, width: -10, height: 400)) == nil)
        #expect(!service.minimizeTarget(candidate))
        #expect(!service.toggleTargetFullscreen(candidate))
        #expect(!service.zoomTargetWindow(candidate))
        let caps = service.operationCapabilities(for: candidate)
        #expect(!caps.canMove && !caps.canResize && !caps.canMinimize && !caps.canFullscreen && !caps.canZoom)
    }

    @Test("AX frame write override returns confirmed geometry; failures are nil/false")
    func axWriteOverrides() {
        let tgt = target()
        let confirmed = CGRect(x: 10, y: 20, width: 640, height: 462)
        let writer = AccessibilityWindowService(
            frameWriteOverride: { _, _ in confirmed },
            minimizeOverride: { _ in true },
            fullscreenOverride: { _ in false },
            zoomOverride: { _ in true },
            capabilitiesOverride: { _ in AccessibilityWindowService.WindowOperationCapabilities(
                canMove: true, canResize: false, canMinimize: true, canFullscreen: false, canZoom: true) }
        )
        #expect(writer.setTargetFrame(tgt, to: CGRect(x: 0, y: 0, width: 100, height: 100)) == confirmed)
        #expect(writer.minimizeTarget(tgt))
        #expect(!writer.toggleTargetFullscreen(tgt))
        #expect(writer.zoomTargetWindow(tgt))
        let caps = writer.operationCapabilities(for: tgt)
        #expect(caps.canMove && !caps.canResize && caps.canMinimize && !caps.canFullscreen && caps.canZoom)
        let failing = AccessibilityWindowService(
            frameWriteOverride: { _, _ in nil },
            minimizeOverride: { _ in false },
            capabilitiesOverride: { _ in AccessibilityWindowService.WindowOperationCapabilities(
                canMove: false, canResize: false, canMinimize: false, canFullscreen: false, canZoom: false) }
        )
        #expect(failing.setTargetFrame(tgt, to: CGRect(x: 0, y: 0, width: 100, height: 100)) == nil)
        #expect(!failing.minimizeTarget(tgt))
        #expect(!failing.operationCapabilities(for: tgt).canMinimize)
    }
}
