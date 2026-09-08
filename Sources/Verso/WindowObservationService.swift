import AppKit
import ApplicationServices

/// Owns the one AXObserver used by the displayed overlay.
///
/// The observer is deliberately short-lived: it follows one retained AX
/// window and its application until the overlay is dismissed. There is no
/// enumeration or polling path here. All callbacks are delivered through the
/// main run loop and carry a generation checked before reaching the owner.
@MainActor
final class WindowObservationService {

    enum EventKind {
        case metadataChanged
        case minimized
        case deminiaturized
        case destroyed
        case focusChanged(AXUIElement)
        case applicationHidden
    }

    struct Event {
        let generation: UInt64
        let kind: EventKind
    }

    typealias Handler = @MainActor (Event) -> Void

    /// Small native seam used by deterministic tests. Production construction
    /// below is the only implementation that touches AXObserver APIs.
    final class ObserverHandle {
        typealias Add = (
            AXUIElement,
            String,
            UnsafeMutableRawPointer?
        ) -> AXError
        let add: Add
        let attachToMainRunLoop: () -> Bool
        let detachFromMainRunLoop: () -> Void

        init(
            add: @escaping Add,
            attachToMainRunLoop: @escaping () -> Bool,
            detachFromMainRunLoop: @escaping () -> Void
        ) {
            self.add = add
            self.attachToMainRunLoop = attachToMainRunLoop
            self.detachFromMainRunLoop = detachFromMainRunLoop
        }
    }

    struct Backend {
        let create: (pid_t) -> ObserverHandle?
        let validatesTarget: Bool

        init(
            create: @escaping (pid_t) -> ObserverHandle?,
            validatesTarget: Bool = true
        ) {
            self.create = create
            self.validatesTarget = validatesTarget
        }
    }

    private enum TeardownReason {
        case normal
        case setupFailure
        case destroyed
        case processTerminated
    }

    private var observer: ObserverHandle?
    private var callbackContext: WindowObservationCallbackContext?
    private var eventHandler: Handler?
    private let backend: Backend
    private let accessibilityWindowService: AccessibilityWindowService
    private var operationGeneration: UInt64 = 0
    private(set) var isObserving = false
    private(set) var lastTeardownWasDestroyed = false
    private(set) var lastTeardownWasProcessTermination = false
    private(set) var unavailableOptionalNotifications: Set<String> = []

    init(
        backend: Backend? = nil,
        accessibilityWindowService: AccessibilityWindowService? = nil
    ) {
        self.backend = backend ?? WindowObservationService.nativeBackend()
        self.accessibilityWindowService = accessibilityWindowService
            ?? AccessibilityWindowService()
    }

    isolated deinit {
        stop()
    }

    @discardableResult
    func start(
        for target: AccessibilityWindowService.ResolvedTargetWindow,
        generation: UInt64,
        handler: @escaping Handler
    ) -> Bool {
        stop()

        guard !backend.validatesTarget || (
            target.metadata.isEligible
                && targetProcessIsCurrent(target)
        ) else {
            return false
        }

        operationGeneration &+= 1
        let context = WindowObservationCallbackContext(
            owner: self,
            lifecycleGeneration: generation,
            operationGeneration: operationGeneration,
            targetWindow: target.axWindow,
            targetApplication: target.axApplication
        )

        guard let observer = backend.create(target.metadata.pid) else {
            return false
        }

        self.observer = observer
        callbackContext = context
        eventHandler = handler
        unavailableOptionalNotifications = []
        lastTeardownWasDestroyed = false
        lastTeardownWasProcessTermination = false

        // These notifications are required for safe lifecycle ownership. If
        // an application cannot provide one, do not display an untracked
        // overlay. Movement/title support is optional and varies by app.
        let required: [(AXUIElement, String)] = [
            (target.axWindow, kAXUIElementDestroyedNotification as String),
            (target.axWindow, kAXWindowMiniaturizedNotification as String),
            (target.axWindow, kAXWindowDeminiaturizedNotification as String),
            (target.axApplication, kAXFocusedWindowChangedNotification as String),
            (target.axApplication, kAXMainWindowChangedNotification as String)
        ]
        let registrationStart = ProcessInfo.processInfo.systemUptime

        for (element, notification) in required {
            guard add(
                notification,
                to: element,
                context: context,
                startedAt: registrationStart
            ) == .success else {
                stop(reason: .setupFailure)
                return false
            }
        }

        let optional: [(AXUIElement, String)] = [
            (target.axWindow, kAXWindowMovedNotification as String),
            (target.axWindow, kAXWindowResizedNotification as String),
            (target.axWindow, kAXTitleChangedNotification as String),
            (target.axApplication, kAXApplicationHiddenNotification as String)
        ]
        for (element, notification) in optional {
            let result = add(
                notification,
                to: element,
                context: context,
                startedAt: registrationStart
            )
            if result == .notificationUnsupported {
                unavailableOptionalNotifications.insert(notification)
            } else if result != .success {
                stop(reason: .setupFailure)
                return false
            }
        }

        guard observer.attachToMainRunLoop() else {
            stop(reason: .setupFailure)
            return false
        }

        isObserving = true
        return true
    }

    private func targetProcessIsCurrent(
        _ target: AccessibilityWindowService.ResolvedTargetWindow
    ) -> Bool {
        guard let currentApplication = NSRunningApplication(
            processIdentifier: target.metadata.pid
        ) else { return false }
        return currentApplication.isEqual(target.runningApplication)
            && !currentApplication.isTerminated
            && !currentApplication.isHidden
            && currentApplication.processIdentifier == target.metadata.pid
    }

    /// Idempotent normal teardown. Registered elements are still valid unless
    /// a destroyed/process-terminated teardown was explicitly selected.
    func stop() {
        stop(reason: .normal)
    }

    /// Teardown for kAXUIElementDestroyedNotification. The destroyed window
    /// is never passed to AXObserverRemoveNotification.
    func stopForDestroyedTarget() {
        stop(reason: .destroyed)
    }

    /// Teardown after NSWorkspace reports the owning process has terminated.
    /// No remote AX removal call is attempted in that state.
    func stopForProcessTermination() {
        stop(reason: .processTerminated)
    }

    private func add(
        _ notification: String,
        to element: AXUIElement,
        context: WindowObservationCallbackContext,
        startedAt: TimeInterval
    ) -> AXError {
        guard let observer else { return .failure }
        if backend.validatesTarget {
            guard accessibilityWindowService.prepareObserverRegistration(
                on: element,
                startedAt: startedAt
            ) else { return .failure }
        }
        let result = observer.add(
            element,
            notification,
            Unmanaged.passUnretained(context).toOpaque()
        )
        return result
    }

    private func stop(reason: TeardownReason) {
        let oldContext = callbackContext
        oldContext?.active = false
        // Invalidate the operation before detaching sources or notifications.
        operationGeneration &+= 1

        var oldObserver = observer
        observer = nil
        callbackContext = nil
        eventHandler = nil
        isObserving = false

        if reason == .destroyed {
            lastTeardownWasDestroyed = true
        }
        if reason == .processTerminated {
            lastTeardownWasProcessTermination = true
        }

        // The observer is never reused. Releasing it removes its native
        // registrations without another IPC call to a possibly dead element.
        withExtendedLifetime(oldContext) {
            oldObserver?.detachFromMainRunLoop()
            oldObserver = nil
        }
    }

    fileprivate func receive(
        _ context: WindowObservationCallbackContext,
        element: AXUIElement,
        notification: String
    ) {
        guard context.active,
              callbackContext === context,
              context.operationGeneration == operationGeneration,
              let eventHandler else {
            return
        }

        if notification == kAXUIElementDestroyedNotification as String {
            // The callback element is invalid by contract; only compare it
            // locally and immediately release the observer/context.
            guard CFEqual(element, context.targetWindow) else { return }
            stopForDestroyedTarget()
            eventHandler(Event(
                generation: context.lifecycleGeneration,
                kind: .destroyed
            ))
            return
        }

        if notification == kAXWindowMiniaturizedNotification as String {
            guard CFEqual(element, context.targetWindow) else { return }
            eventHandler(Event(
                generation: context.lifecycleGeneration,
                kind: .minimized
            ))
            return
        }

        if notification == kAXWindowDeminiaturizedNotification as String {
            guard CFEqual(element, context.targetWindow) else { return }
            eventHandler(Event(
                generation: context.lifecycleGeneration,
                kind: .deminiaturized
            ))
            return
        }

        if notification == kAXWindowMovedNotification as String
            || notification == kAXWindowResizedNotification as String
            || notification == kAXTitleChangedNotification as String {
            guard CFEqual(element, context.targetWindow) else { return }
            eventHandler(Event(
                generation: context.lifecycleGeneration,
                kind: .metadataChanged
            ))
            return
        }

        if notification == kAXApplicationHiddenNotification as String {
            guard CFEqual(element, context.targetApplication) else { return }
            eventHandler(Event(
                generation: context.lifecycleGeneration,
                kind: .applicationHidden
            ))
            return
        }

        if notification == kAXFocusedWindowChangedNotification as String
            || notification == kAXMainWindowChangedNotification as String {
            eventHandler(Event(
                generation: context.lifecycleGeneration,
                kind: .focusChanged(element)
            ))
        }
    }

    private static func nativeBackend() -> Backend {
        Backend(create: { pid in
            var nativeObserver: AXObserver?
            guard AXObserverCreate(
                pid,
                windowObservationAXCallback,
                &nativeObserver
            ) == .success,
                  let nativeObserver,
                  CFRunLoopSourceIsValid(
                    AXObserverGetRunLoopSource(nativeObserver)
                  ) else {
                return nil
            }

            let source = AXObserverGetRunLoopSource(nativeObserver)

            return ObserverHandle(
                add: { element, notification, refcon in
                    AXObserverAddNotification(
                        nativeObserver,
                        element,
                        notification as CFString,
                        refcon
                    )
                },
                attachToMainRunLoop: {
                    CFRunLoopAddSource(
                        CFRunLoopGetMain(),
                        source,
                        .commonModes
                    )
                    return CFRunLoopSourceIsValid(source)
                },
                detachFromMainRunLoop: {
                    CFRunLoopRemoveSource(
                        CFRunLoopGetMain(),
                        source,
                        .commonModes
                    )
                    CFRunLoopSourceInvalidate(source)
                }
            )
        })
    }
}

private final class WindowObservationCallbackContext {
    weak var owner: WindowObservationService?
    let lifecycleGeneration: UInt64
    let operationGeneration: UInt64
    let targetWindow: AXUIElement
    let targetApplication: AXUIElement
    var active = true

    init(
        owner: WindowObservationService,
        lifecycleGeneration: UInt64,
        operationGeneration: UInt64,
        targetWindow: AXUIElement,
        targetApplication: AXUIElement
    ) {
        self.owner = owner
        self.lifecycleGeneration = lifecycleGeneration
        self.operationGeneration = operationGeneration
        self.targetWindow = targetWindow
        self.targetApplication = targetApplication
    }

    func receive(
        element: AXUIElement,
        notification: String
    ) {
        guard active else { return }
        let retainedContext = self
        MainActor.assumeIsolated {
            guard retainedContext.active else { return }
            retainedContext.owner?.receive(
                retainedContext,
                element: element,
                notification: notification
            )
        }
    }
}

private func windowObservationAXCallback(
    _ observer: AXObserver,
    _ element: AXUIElement,
    _ notification: CFString,
    _ refcon: UnsafeMutableRawPointer?
) {
    deliverWindowObservation(element: element, notification: notification as String, refcon: refcon)
}

/// Shared native callback entry. The run-loop source invokes this on main;
/// tests can deliver a retained in-flight context without querying remote AX.
func deliverWindowObservation(
    element: AXUIElement,
    notification: String,
    refcon: UnsafeMutableRawPointer?
) {
    guard let refcon else { return }
    let context = Unmanaged<WindowObservationCallbackContext>
        .fromOpaque(refcon)
        .takeUnretainedValue()
    context.receive(
        element: element,
        notification: notification
    )
}
