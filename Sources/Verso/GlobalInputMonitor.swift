import AppKit
import CoreGraphics

#if SWIFT_PACKAGE
import VersoCore
#endif

/// Global Option-left-click input monitor using a CGEventTap.
///
/// Installs a `cgSessionEventTap` / `defaultTap` on the main run loop
/// in common modes. The C callback safely re-enters `@MainActor` because
/// the source is on the main run loop.
///
/// Start/stop are idempotent. Stop removes and invalidates the tap
/// and resets input state.
@MainActor
public final class GlobalInputMonitor {

    // MARK: - Error

    /// Tap creation or runtime failure surfaceable in Permissions UI.
    public enum TapError: Sendable, Equatable {
        case creationFailed
        case runtimeFailed
    }

    // MARK: - State

    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var sequence = InputSequence()
    private weak var axService: AccessibilityWindowService?
    private var acceptanceCallback: ((AccessibilityWindowService.ResolvedTargetWindow) -> Bool)?
    /// Called when `lastError` changes, for UI wiring.
    public var onErrorChanged: ((TapError?) -> Void)?
    public private(set) var lastError: TapError? {
        didSet {
            if lastError != oldValue {
                onErrorChanged?(lastError)
            }
        }
    }
    public private(set) var isActive: Bool = false

    // MARK: - Init

    public init(
        axService: AccessibilityWindowService,
        acceptanceCallback: ((AccessibilityWindowService.ResolvedTargetWindow) -> Bool)? = nil
    ) {
        self.axService = axService
        self.acceptanceCallback = acceptanceCallback
    }

    deinit {
        if let source = runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes)
            CFRunLoopSourceInvalidate(source)
        }
        if let tap = eventTap { CFMachPortInvalidate(tap) }
    }

    // MARK: - Public API

    /// Update the acceptance callback.
    public func setAcceptanceCallback(
        _ callback: ((AccessibilityWindowService.ResolvedTargetWindow) -> Bool)?
    ) {
        self.acceptanceCallback = callback
    }

    /// Start monitoring. Idempotent for a valid, enabled tap.
    /// Cleans stale resources before retrying.
    @discardableResult
    public func start() -> TapError? {
        // Idempotent fast path: tap exists and is valid+enabled.
        if let tap = eventTap, CFMachPortIsValid(tap), CGEvent.tapIsEnabled(tap: tap) {
            return nil
        }

        // Clean stale resources before retrying.
        stop()
        lastError = nil

        let mask: CGEventMask = (1 << CGEventType.leftMouseDown.rawValue)
            | (1 << CGEventType.leftMouseUp.rawValue)
            | (1 << CGEventType.leftMouseDragged.rawValue)

        let selfPtr = Unmanaged.passUnretained(self).toOpaque()

        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: mask,
            callback: eventTapCallback,
            userInfo: selfPtr
        ) else {
            lastError = .creationFailed
            isActive = false
            return lastError
        }

        guard let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0),
              CFRunLoopSourceIsValid(source) else {
            CFMachPortInvalidate(tap)
            lastError = .creationFailed
            isActive = false
            return lastError
        }

        eventTap = tap
        runLoopSource = source
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)

        CGEvent.tapEnable(tap: tap, enable: true)
        guard CGEvent.tapIsEnabled(tap: tap) else {
            stop()
            lastError = .creationFailed
            isActive = false
            return lastError
        }

        isActive = true
        return nil
    }

    /// Stop monitoring. Idempotent. Removes and invalidates source,
    /// disables and invalidates port, nils references, resets sequence.
    public func stop() {
        sequence.reset()

        if let source = runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes)
            CFRunLoopSourceInvalidate(source)
            runLoopSource = nil
        }

        if let tap = eventTap {
            CGEvent.tapEnable(tap: tap, enable: false)
            CFMachPortInvalidate(tap)
            eventTap = nil
        }

        isActive = false
    }

    // MARK: - Disabled tap handling

    /// Nonisolated entry point for the C callback. Dispatches to the
    /// private MainActor handler.
    nonisolated func handleTapDisabledEvent(_ type: CGEventType) {
        let isTimeout = (type == .tapDisabledByTimeout)
        MainActor.assumeIsolated {
            self.handleTapDisabled(isTimeout: isTimeout)
        }
    }

    /// MainActor handler for tapDisabledByTimeout and
    /// tapDisabledByUserInput. Resets sequence, checks actual trust.
    ///
    /// Timeout: re-enable if trusted, verify enabled, else stop+runtimeFailed.
    /// UserInput: stop and wait for the next explicit or activation refresh.
    private func handleTapDisabled(isTimeout: Bool) {
        sequence.reset()

        let trusted = AXIsProcessTrusted()

        if isTimeout {
            guard trusted else {
                lastError = .runtimeFailed
                stop()
                return
            }
            guard let tap = eventTap, CFMachPortIsValid(tap) else {
                lastError = .runtimeFailed
                stop()
                return
            }
            CGEvent.tapEnable(tap: tap, enable: true)
            guard CGEvent.tapIsEnabled(tap: tap) else {
                lastError = .runtimeFailed
                stop()
                return
            }
        } else {
            stop()
            lastError = .runtimeFailed
        }
    }

    // MARK: - Event processing

    /// Called from the C callback on the main thread. Works on a local
    /// sequence copy, invokes consumer outside inout borrow, verifies
    /// same tap before committing.
    nonisolated func handleEvent(_ event: CGEvent) -> Bool {
        MainActor.assumeIsolated {
            guard let tap = self.eventTap,
                  CFMachPortIsValid(tap),
                  CGEvent.tapIsEnabled(tap: tap) else {
                return false
            }

            // Local copy avoids inout borrow during consumer callback.
            var seq = self.sequence
            let callback = self.acceptanceCallback
            let service = self.axService
            let suppressed = seq.processMouseEvent(event) { location in
                guard let service, let callback else {
                    return false
                }
                guard let resolved = service.resolveTitleBarHit(at: location) else {
                    return false
                }
                // Consumer invoked outside sequence inout borrow.
                return callback(resolved)
            }

            // Commit only if the same tap is still current, valid,
            // and enabled. A reentrant stop/restart leaves a fresh tap.
            guard self.eventTap === tap,
                  CFMachPortIsValid(tap), CGEvent.tapIsEnabled(tap: tap)
            else { return false }
            self.sequence = seq
            return suppressed
        }
    }
}

// MARK: - C callback

/// The CGEventTap callback. Receives events on the main run loop.
/// MainActor.assumeIsolated is valid because source is on main loop.
private func eventTapCallback(
    proxy: CGEventTapProxy,
    type: CGEventType,
    event: CGEvent,
    userInfo: UnsafeMutableRawPointer?
) -> Unmanaged<CGEvent>? {
    guard let userInfo else { return Unmanaged.passUnretained(event) }

    let monitor = Unmanaged<GlobalInputMonitor>.fromOpaque(userInfo).takeUnretainedValue()

    if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
        monitor.handleTapDisabledEvent(type)
        return Unmanaged.passUnretained(event)
    }

    if monitor.handleEvent(event) {
        return nil
    }
    return Unmanaged.passUnretained(event)
}
