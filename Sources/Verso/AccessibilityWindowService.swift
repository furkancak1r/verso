import Foundation
import AppKit
import ApplicationServices

#if SWIFT_PACKAGE
import VersoCore
#endif

/// Resolves the AX window and builds evidence for a title-bar hit.
///
/// Uses `AXUIElementCreateSystemWide` + `AXUIElementCopyElementAtPosition`
/// to find the hit element, walks bounded ancestry to the owning
/// AXWindow/AXApplication, validates the target, reads real AX attributes
/// for evidence, and calls `TitleBarHitTester` before returning a result.
///
/// All coordinates are Quartz/AX top-left (Y increases downward).
@MainActor
public final class AccessibilityWindowService {

    // MARK: - Resolved target

    /// A resolved external window target retaining AX references for later use.
    public struct ResolvedTargetWindow {
        public let metadata: TargetWindowMetadata
        public let evidence: HitTestEvidence
        public let axWindow: AXUIElement
        public let axApplication: AXUIElement
        public let runningApplication: NSRunningApplication
    }

    /// Result of a bounded refresh of a retained target.  A minimized target
    /// is reported separately so the overlay can close while its live-note
    /// reservation remains intact.
    public enum TargetRefreshResult {
        case current(ResolvedTargetWindow)
        case minimized(ResolvedTargetWindow)
        case invalid
    }

    /// Decision for a focus/main-window notification.  AX may report the
    /// application element when no window is focused; that is not proof of a
    /// different external window.
    public enum FocusDecision: Equatable {
        case sameTarget
        case applicationOnly
        case differentValidatedWindow
        case ignore
    }

    public typealias RefreshOverride = @MainActor (
        ResolvedTargetWindow
    ) -> TargetRefreshResult
    public typealias FocusOverride = @MainActor (
        ResolvedTargetWindow,
        AXUIElement
    ) -> FocusDecision
    public typealias RaiseOverride = @MainActor (
        ResolvedTargetWindow
    ) -> Bool
    public typealias FrameWriteOverride = @MainActor (
        ResolvedTargetWindow, CGRect
    ) -> CGRect?
    public typealias TargetBoolOverride = @MainActor (
        ResolvedTargetWindow
    ) -> Bool
    public typealias CapabilitiesOverride = @MainActor (
        ResolvedTargetWindow
    ) -> WindowOperationCapabilities

    // MARK: - Internal error type

    /// Errors thrown by AX query helpers. Caught once in the public
    /// resolve method; `nil` return means only no-eligible-target.
    private enum AXIPCError: Error {
        /// General IPC failure: non-`attributeUnsupported`/`noValue` error,
        /// success-with-nil value, malformed CF type, or failed conversion.
        case ipcFailed
        /// Budget exhausted during an AX query.
        case budgetExhausted
    }

    // MARK: - Configuration

    /// Per-IPC messaging timeout ceiling (≤ 15 ms per requirement).
    private static let ipcTimeoutCeiling: CFTimeInterval = 0.015

    /// Total monotonic budget for a single resolution attempt.
    private static let totalBudget: TimeInterval = 0.080

    /// Maximum ancestry nodes to walk from hit to AXApplication.
    private static let maxAncestryNodes = 12

    /// Maximum first-order children to inspect for sheet/modal detection.
    private static let maxChildrenForSheetCheck = 24

    /// Allowed roles for the directly-hit element.
    private static let allowedHitRoles: Set<String> = [
        "AXStaticText", "AXGroup", "AXToolbar", "AXWindow"
    ]

    private let systemWide: AXUIElement
    private let selfPID: pid_t
    private let refreshOverride: RefreshOverride?
    private let focusOverride: FocusOverride?
    private let raiseOverride: RaiseOverride?
    private let frameWriteOverride: FrameWriteOverride?
    private let minimizeOverride: TargetBoolOverride?
    private let fullscreenOverride: TargetBoolOverride?
    private let zoomOverride: TargetBoolOverride?
    private let capabilitiesOverride: CapabilitiesOverride?

    // MARK: - Init

    public init(
        refreshOverride: RefreshOverride? = nil,
        focusOverride: FocusOverride? = nil,
        raiseOverride: RaiseOverride? = nil,
        frameWriteOverride: FrameWriteOverride? = nil,
        minimizeOverride: TargetBoolOverride? = nil,
        fullscreenOverride: TargetBoolOverride? = nil,
        zoomOverride: TargetBoolOverride? = nil,
        capabilitiesOverride: CapabilitiesOverride? = nil
    ) {
        systemWide = AXUIElementCreateSystemWide()
        selfPID = getpid()
        self.refreshOverride = refreshOverride
        self.focusOverride = focusOverride
        self.raiseOverride = raiseOverride
        self.frameWriteOverride = frameWriteOverride
        self.minimizeOverride = minimizeOverride
        self.fullscreenOverride = fullscreenOverride
        self.zoomOverride = zoomOverride
        self.capabilitiesOverride = capabilitiesOverride
    }

    /// Capability snapshot for note window controls. Computed with bounded
    /// AX IPC; unsupported controls must be disabled with a localized reason.
    public struct WindowOperationCapabilities: Equatable {
        public let isKnown: Bool
        public let canMove: Bool
        public let canResize: Bool
        public let canMinimize: Bool
        public let canFullscreen: Bool
        public let canZoom: Bool
        public init(canMove: Bool, canResize: Bool, canMinimize: Bool, canFullscreen: Bool, canZoom: Bool, isKnown: Bool = true) {
            self.isKnown = isKnown
            self.canMove = canMove; self.canResize = canResize
            self.canMinimize = canMinimize; self.canFullscreen = canFullscreen
            self.canZoom = canZoom
        }
    }

    // MARK: - Public API

    /// Resolve an eligible external window for the given Quartz hit point.
    ///
    /// Returns `nil` when no eligible window is found: no AX element at point,
    /// budget exhausted, self-hit, control/content/sheet/menu/unknown roles,
    /// invalid PID, hidden/minimized/modal window, or `TitleBarHitTester`
    /// rejection.  Never consumes input.
    public func resolveTitleBarHit(at point: CGPoint) -> ResolvedTargetWindow? {
        do {
            return try resolveTitleBarHitThrowing(at: point)
        } catch {
            return nil
        }
    }

    /// Re-read the retained window's bounded lifecycle metadata. This is used
    /// only after a delivered AX notification; it does not enumerate windows
    /// or capture pixels.
    public func refreshTarget(
        _ target: ResolvedTargetWindow
    ) -> TargetRefreshResult {
        if let refreshOverride {
            return refreshOverride(target)
        }

        guard let currentApplication = NSRunningApplication(
            processIdentifier: target.metadata.pid
        ),
              currentApplication.isEqual(target.runningApplication),
              !currentApplication.isTerminated,
              !currentApplication.isHidden,
              target.runningApplication.processIdentifier
                  == target.metadata.pid,
              let expectedBundle = target.metadata.bundleIdentifier,
              let runningBundle = currentApplication.bundleIdentifier,
              expectedBundle == runningBundle else {
            return .invalid
        }

        let start = monotonicNow()
        do {
            let windowPID = try axPID(target.axWindow, start: start)
            guard windowPID == target.metadata.pid else { return .invalid }

            let applicationPID = try axPID(target.axApplication, start: start)
            guard applicationPID == target.metadata.pid else { return .invalid }

            guard try axString(target.axWindow, kAXRoleAttribute, start: start)
                    == TargetWindowMetadata.windowRole,
                  try axString(
                    target.axWindow,
                    kAXSubroleAttribute,
                    start: start
                  ) == TargetWindowMetadata.standardWindowSubrole else {
                return .invalid
            }

            let frame = try axFrame(target.axWindow, start: start)
            guard TargetWindowMetadata.isValidFrame(frame) else {
                return .invalid
            }

            guard let minimized = try axBoolStrict(
                target.axWindow,
                kAXMinimizedAttribute,
                start: start
            ) else { return .invalid }
            guard let modal = try axBoolStrict(
                target.axWindow,
                kAXModalAttribute,
                start: start
            ), !modal else { return .invalid }

            let title = try axString(
                target.axWindow,
                kAXTitleAttribute,
                start: start
            )
            let document = try axString(
                target.axWindow,
                kAXDocumentAttribute,
                start: start
            )
            let documentURL = try axURLOptional(
                target.axWindow,
                kAXURLAttribute,
                start: start
            )
            guard hasBudgetRemaining(start) else {
                throw AXIPCError.budgetExhausted
            }

            let metadata = TargetWindowMetadata(
                pid: target.metadata.pid,
                bundleIdentifier: expectedBundle,
                appName: currentApplication.localizedName
                    ?? target.metadata.appName,
                windowTitle: title,
                windowRole: TargetWindowMetadata.windowRole,
                windowSubrole: TargetWindowMetadata.standardWindowSubrole,
                documentPath: document,
                documentURL: documentURL,
                frame: frame,
                isMinimized: minimized,
                isOnScreen: true
            )

            let refreshed = ResolvedTargetWindow(
                metadata: metadata,
                evidence: target.evidence,
                axWindow: target.axWindow,
                axApplication: target.axApplication,
                runningApplication: target.runningApplication
            )
            return minimized ? .minimized(refreshed) : .current(refreshed)
        } catch {
            return .invalid
        }
    }

    /// Decide whether an application focus/main-window notification names the
    /// retained target, merely the application, or a separately validated
    /// live window. The notification element is the only element queried.
    public func focusDecision(
        for target: ResolvedTargetWindow,
        notifiedElement: AXUIElement
    ) -> FocusDecision {
        if let focusOverride {
            return focusOverride(target, notifiedElement)
        }

        if CFEqual(notifiedElement, target.axWindow) {
            return .sameTarget
        }
        if CFEqual(notifiedElement, target.axApplication) {
            return .applicationOnly
        }

        guard let currentApplication = NSRunningApplication(
            processIdentifier: target.metadata.pid
        ),
              currentApplication.isEqual(target.runningApplication),
              !currentApplication.isTerminated,
              !currentApplication.isHidden else {
            return .ignore
        }

        let start = monotonicNow()
        do {
            let pid = try axPID(notifiedElement, start: start)
            guard pid == target.metadata.pid else { return .ignore }
            guard try axString(
                notifiedElement,
                kAXRoleAttribute,
                start: start
            ) == TargetWindowMetadata.windowRole else { return .ignore }
            guard try axString(
                notifiedElement,
                kAXSubroleAttribute,
                start: start
            ) == TargetWindowMetadata.standardWindowSubrole else {
                return .ignore
            }
            let frame = try axFrame(notifiedElement, start: start)
            guard TargetWindowMetadata.isValidFrame(frame),
                  let minimized = try axBoolStrict(
                    notifiedElement,
                    kAXMinimizedAttribute,
                    start: start
                  ), !minimized,
                  let modal = try axBoolStrict(
                    notifiedElement,
                    kAXModalAttribute,
                    start: start
                  ), !modal,
                  hasBudgetRemaining(start) else {
                return .ignore
            }
            return .differentValidatedWindow
        } catch {
            return .ignore
        }
    }

    /// Validate the retained target and perform one bounded AX Raise. The
    /// caller may activate the retained process only after this returns true.
    public func raiseTarget(
        _ target: ResolvedTargetWindow
    ) -> Bool {
        if let raiseOverride {
            return raiseOverride(target)
        }

        guard target.metadata.isEligible,
              let currentApplication = NSRunningApplication(
                processIdentifier: target.metadata.pid
              ),
              currentApplication.isEqual(target.runningApplication),
              !currentApplication.isTerminated,
              !currentApplication.isHidden,
              target.runningApplication.processIdentifier
                  == target.metadata.pid,
              let expectedBundle = target.metadata.bundleIdentifier,
              currentApplication.bundleIdentifier == expectedBundle else {
            return false
        }

        let start = monotonicNow()
        do {
            let pid = try axPID(target.axWindow, start: start)
            guard pid == target.metadata.pid else { return false }
            let applicationPID = try axPID(target.axApplication, start: start)
            guard applicationPID == target.metadata.pid else { return false }
            guard try axString(
                target.axWindow,
                kAXRoleAttribute,
                start: start
            ) == TargetWindowMetadata.windowRole else { return false }
            guard try axString(
                target.axWindow,
                kAXSubroleAttribute,
                start: start
            ) == TargetWindowMetadata.standardWindowSubrole else {
                return false
            }
            let frame = try axFrame(target.axWindow, start: start)
            guard TargetWindowMetadata.isValidFrame(frame),
                  let minimized = try axBoolStrict(
                    target.axWindow,
                    kAXMinimizedAttribute,
                    start: start
                  ), !minimized,
                  let modal = try axBoolStrict(
                    target.axWindow,
                    kAXModalAttribute,
                    start: start
                  ), !modal,
                  hasBudgetRemaining(start) else {
                return false
            }

            let raiseError = withBudgetTimeout(
                element: target.axWindow,
                start: start
            ) {
                AXUIElementPerformAction(
                    target.axWindow,
                    kAXRaiseAction as CFString
                )
            }
            return raiseError == .success && hasBudgetRemaining(start)
        } catch {
            return false
        }
    }

    // MARK: - Window operations (Phase 16A)

    /// Bounded capability probe: settable position/size/minimized plus
    /// pressable fullscreen/zoom buttons. Never throws; false = unsupported.
    public func operationCapabilities(
        for target: ResolvedTargetWindow
    ) -> WindowOperationCapabilities {
        if let capabilitiesOverride { return capabilitiesOverride(target) }
        guard retainedTargetIsLive(target) else {
            return WindowOperationCapabilities(canMove: false, canResize: false, canMinimize: false, canFullscreen: false, canZoom: false, isKnown: false)
        }
        let start = monotonicNow()
        do {
            guard try validatedOperationWindow(target, start: start) else {
                return WindowOperationCapabilities(canMove: false, canResize: false, canMinimize: false, canFullscreen: false, canZoom: false, isKnown: false)
            }
            guard let move = axIsSettable(target.axWindow, kAXPositionAttribute, start: start),
                  let resize = axIsSettable(target.axWindow, kAXSizeAttribute, start: start),
                  let minimize = axIsSettable(target.axWindow, kAXMinimizedAttribute, start: start) else {
                throw AXIPCError.ipcFailed
            }
            let fs = try operationButton(target, attribute: kAXFullScreenButtonAttribute, start: start) != nil
            let zm = try operationButton(target, attribute: kAXZoomButtonAttribute, start: start) != nil
            guard hasBudgetRemaining(start) else {
                return WindowOperationCapabilities(canMove: false, canResize: false, canMinimize: false, canFullscreen: false, canZoom: false, isKnown: false)
            }
            return WindowOperationCapabilities(canMove: move, canResize: resize, canMinimize: minimize, canFullscreen: fs, canZoom: zm)
        } catch {
            return WindowOperationCapabilities(canMove: false, canResize: false, canMinimize: false, canFullscreen: false, canZoom: false, isKnown: false)
        }
    }

    /// Write a Quartz top-left frame to the retained target, then read back
    /// the actual frame. Returns nil on any validation/IPC failure so the
    /// caller never implies success; the returned frame always wins over the
    /// requested one. Caller coalesces rapid drag/resize events.
    public func setTargetFrame(
        _ target: ResolvedTargetWindow, to quartzFrame: CGRect
    ) -> CGRect? {
        if let frameWriteOverride { return frameWriteOverride(target, quartzFrame) }
        guard TargetWindowMetadata.isValidFrame(quartzFrame), retainedTargetIsLive(target) else { return nil }
        let start = monotonicNow()
        do {
            guard try validatedOperationWindow(target, start: start) else { return nil }
            let before = try axFrame(target.axWindow, start: start)
            let moving = abs(before.minX-quartzFrame.minX) > 0.5 || abs(before.minY-quartzFrame.minY) > 0.5
            let resizing = abs(before.width-quartzFrame.width) > 0.5 || abs(before.height-quartzFrame.height) > 0.5
            guard (!moving || axIsSettable(target.axWindow, kAXPositionAttribute, start: start) == true),
                  (!resizing || axIsSettable(target.axWindow, kAXSizeAttribute, start: start) == true) else { return nil }
            // Resize first: a failed resize must not also move the target.
            if resizing {
                var size = quartzFrame.size
                guard let value = AXValueCreate(.cgSize, &size),
                      withBudgetTimeout(element: target.axWindow, start: start, body: {
                          AXUIElementSetAttributeValue(target.axWindow, kAXSizeAttribute as CFString, value)
                      }) == .success else { return nil }
            }
            if moving {
                var position = quartzFrame.origin
                guard let value = AXValueCreate(.cgPoint, &position),
                      withBudgetTimeout(element: target.axWindow, start: start, body: {
                          AXUIElementSetAttributeValue(target.axWindow, kAXPositionAttribute as CFString, value)
                      }) == .success else { return nil }
            }
            // A partial failure returns nil; caller refreshes the real frame
            // instead of claiming rollback of another application's window.
            return try axFrame(target.axWindow, start: start)
        } catch { return nil }
    }

    /// Minimize the retained target via bounded AX. Validates retained
    /// PID/bundle/window before writing.
    public func minimizeTarget(_ target: ResolvedTargetWindow) -> Bool {
        if let minimizeOverride { return minimizeOverride(target) }
        guard retainedTargetIsLive(target) else { return false }
        let start = monotonicNow()
        do {
            guard try validatedOperationWindow(target, start: start),
                  axIsSettable(target.axWindow, kAXMinimizedAttribute, start: start) == true else { return false }
            let v: CFTypeRef = kCFBooleanTrue!
            let err = withBudgetTimeout(element: target.axWindow, start: start) {
                AXUIElementSetAttributeValue(target.axWindow, kAXMinimizedAttribute as CFString, v)
            }
            return err == .success && hasBudgetRemaining(start)
        } catch { return false }
    }

    /// Toggle target fullscreen by pressing its fullscreen button.
    public func toggleTargetFullscreen(_ target: ResolvedTargetWindow) -> Bool {
        if let fullscreenOverride { return fullscreenOverride(target) }
        return pressTargetButton(target, attribute: kAXFullScreenButtonAttribute)
    }

    /// Zoom the target by pressing its zoom button (Option-green).
    public func zoomTargetWindow(_ target: ResolvedTargetWindow) -> Bool {
        if let zoomOverride { return zoomOverride(target) }
        return pressTargetButton(target, attribute: kAXZoomButtonAttribute)
    }

    private func operationButton(_ target: ResolvedTargetWindow, attribute: String, start: TimeInterval) throws -> AXUIElement? {
        guard let button = try axElement(target.axWindow, attribute, start: start) else { return nil }
        guard try axString(button, kAXRoleAttribute, start: start) == "AXButton",
              try axPID(button, start: start) == target.metadata.pid,
              let owner = try axElement(button, kAXWindowAttribute, start: start), CFEqual(owner, target.axWindow),
              try axBoolStrict(button, kAXEnabledAttribute, start: start) == true else { return nil }
        var actions: CFArray?
        let error = withBudgetTimeout(element: button, start: start) { AXUIElementCopyActionNames(button, &actions) }
        guard error == .success, let names = actions as? [String], names.contains(kAXPressAction as String) else { return nil }
        return button
    }

    private func pressTargetButton(_ target: ResolvedTargetWindow, attribute: String) -> Bool {
        guard retainedTargetIsLive(target) else { return false }
        let start = monotonicNow()
        do {
            guard try validatedOperationWindow(target, start: start),
                  let btn = try operationButton(target, attribute: attribute, start: start),
                  hasBudgetRemaining(start) else { return false }
            let err = withBudgetTimeout(element: btn, start: start) {
                AXUIElementPerformAction(btn, kAXPressAction as CFString)
            }
            return err == .success && hasBudgetRemaining(start)
        } catch { return false }
    }

    /// Focus is checked on the source application, not inferred from the
    /// overlay being key (the overlay belongs to a different process).
    public func targetIsFocused(_ target: ResolvedTargetWindow) -> Bool {
        guard retainedTargetIsLive(target) else { return false }
        let start = monotonicNow()
        do {
            guard let focused = try axElement(target.axApplication, kAXFocusedWindowAttribute, start: start) else { return false }
            return CFEqual(focused, target.axWindow) && hasBudgetRemaining(start)
        } catch { return false }
    }

    private func retainedTargetIsLive(_ target: ResolvedTargetWindow) -> Bool {
        guard target.metadata.isEligible,
              let current = NSRunningApplication(processIdentifier: target.metadata.pid),
              current.isEqual(target.runningApplication),
              !current.isTerminated, !current.isHidden,
              target.runningApplication.processIdentifier == target.metadata.pid,
              let expected = target.metadata.bundleIdentifier,
              current.bundleIdentifier == expected else { return false }
        return true
    }

    private func validatedOperationWindow(_ target: ResolvedTargetWindow, start: TimeInterval) throws -> Bool {
        guard try axPID(target.axWindow, start: start) == target.metadata.pid,
              try axPID(target.axApplication, start: start) == target.metadata.pid,
              try axString(target.axWindow, kAXRoleAttribute, start: start) == TargetWindowMetadata.windowRole,
              try axString(target.axWindow, kAXSubroleAttribute, start: start) == TargetWindowMetadata.standardWindowSubrole,
              try axBoolStrict(target.axWindow, kAXMinimizedAttribute, start: start) == false,
              try axBoolStrict(target.axWindow, kAXModalAttribute, start: start) == false,
              hasBudgetRemaining(start) else { return false }
        return true
    }

    private func axIsSettable(_ element: AXUIElement, _ attribute: String, start: TimeInterval) -> Bool? {
        guard hasBudgetRemaining(start) else { return nil }
        var settable: DarwinBoolean = false
        let err = withBudgetTimeout(element: element, start: start) {
            AXUIElementIsAttributeSettable(element, attribute as CFString, &settable)
        }
        guard err == .success, hasBudgetRemaining(start) else { return nil }
        return settable.boolValue
    }

    /// Set the same bounded messaging timeout used by strict AX queries
    /// before an observer registration touches a retained element.
    public func prepareObserverRegistration(
        on element: AXUIElement,
        startedAt: TimeInterval
    ) -> Bool {
        withBudgetTimeout(element: element, start: startedAt) {
            .success
        } == .success
    }

    /// Internal throwing resolver — all AX helpers use `try`, never `try?`.
    /// The single `do/catch` in `resolveTitleBarHit` converts any thrown
    /// error to `nil` (no-eligible-target).
    private func resolveTitleBarHitThrowing(at point: CGPoint) throws -> ResolvedTargetWindow? {
        let start = monotonicNow()

        // 0. Validate hit coordinates: finite, non-NaN, Float-safe
        guard AXValidation.isValidHitPoint(point) else { return nil }

        // 1. Hit element at position — configure per-proxy timeout BEFORE query
        guard let hit = try axElementAtPosition(point, start: start) else { return nil }

        // 2. Hit role (required) — budget check before AND after
        guard let hitRole = try axString(hit, kAXRoleAttribute, start: start) else { return nil }

        // Early rejection: only static-text / group / toolbar / window
        guard Self.allowedHitRoles.contains(hitRole) else { return nil }

        // 3. PID of the hit element — prove ownership immediately
        let hitPID = try axPID(hit, start: start)
        guard AXValidation.isValidPID(hitPID, selfPID: selfPID) else { return nil }

        // 4. Walk ancestry from hit upward to AXApplication
        var ancestors: [(element: AXUIElement, role: String, pid: pid_t)] = []
        var axWindow: AXUIElement?
        var axApp: AXUIElement?
        var appPID: pid_t = 0

        if hitRole == "AXWindow" { axWindow = hit }

        var current = hit
        var currentRole = hitRole
        // ponytail: CFEqual-based seen set; [AXUIElement] is fine for ≤12 items.
        var seen: [AXUIElement] = [hit]

        for _ in 0..<Self.maxAncestryNodes {
            // Budget check BEFORE the next parent query
            guard hasBudgetRemaining(start) else { throw AXIPCError.budgetExhausted }

            guard let parent = try axElement(current, kAXParentAttribute, start: start)
            else { break } // root reached or absent

            // Cycle detection via CFEqual
            if seen.contains(where: { CFEqual($0, parent) }) { return nil }
            seen.append(parent)

            guard let parentRole = try axString(parent, kAXRoleAttribute, start: start)
            else { break }

            guard AXValidation.whitelistedAncestorRoles.contains(parentRole),
                  currentRole != "AXWindow" || parentRole == "AXApplication"
            else { return nil }

            let ancPID = try axPID(parent, start: start)

            ancestors.append((element: parent, role: parentRole, pid: ancPID))

            if parentRole == "AXWindow" && axWindow == nil {
                axWindow = parent
            }
            if parentRole == "AXApplication" {
                axApp = parent; appPID = ancPID; break
            }

            current = parent
            currentRole = parentRole
        }

        guard let app = axApp, let win = axWindow else { return nil }

        // Reject incomplete ancestry: must reach AXApplication
        guard ancestors.last?.role == "AXApplication" else { return nil }

        // Reject more than one AXWindow in the chain (nested windows).
        // Count the hit element itself when it is an AXWindow.
        let hitIsWindow = (hitRole == "AXWindow")
        guard AXValidation.hasAtMostOneWindow(
            ancestors.map(\.role), hitIsWindow: hitIsWindow
        ) else { return nil }

        // PID agreement: all PIDs (hit, ancestors, window, app) must agree
        guard AXValidation.pidAgreement([hitPID] + ancestors.map(\.pid)) else { return nil }
        // The canonical PID comes from the application element
        let pid = appPID
        guard pid > 0, pid != selfPID else { return nil }

        // 5. Running application validation
        guard let runningApp = NSRunningApplication(processIdentifier: pid),
              runningApp.activationPolicy == .regular,
              !runningApp.isTerminated,
              !runningApp.isHidden else { return nil }
        guard let bundleID = runningApp.bundleIdentifier,
              !bundleID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else { return nil }
        guard hasBudgetRemaining(start) else { throw AXIPCError.budgetExhausted }

        // 6. Window frame (required) — throws on abort
        let frame = try axFrame(win, start: start)
        guard TargetWindowMetadata.isValidFrame(frame) else { return nil }

        // 7. Required window modal/minimized state — CFBoolean strict
        //    Absence of the attribute does NOT imply false; throws on malformed.
        let isMinimized = try axBoolStrict(win, kAXMinimizedAttribute, start: start)
        guard let minimized = isMinimized, !minimized else { return nil }

        let isModal = try axBoolStrict(win, kAXModalAttribute, start: start)
        guard let modal = isModal, !modal else { return nil }

        guard hasBudgetRemaining(start) else { throw AXIPCError.budgetExhausted }

        // 8. Optional window attributes — throws on malformed; nil = absent OK
        let title     = try axString(win, kAXTitleAttribute, start: start)
        let subrole   = try axString(win, kAXSubroleAttribute, start: start)
        let document  = try axString(win, kAXDocumentAttribute, start: start)
        let docURL    = try axURLOptional(win, kAXURLAttribute, start: start)
        guard hasBudgetRemaining(start) else { throw AXIPCError.budgetExhausted }

        // 9. Sheet/modal children (conservative bounded check)
        let hasSheet = try axHasSheetOrModalChild(win, start: start)
        if hasSheet { return nil }
        guard hasBudgetRemaining(start) else { throw AXIPCError.budgetExhausted }

        // 10. Build metadata
        let metadata = TargetWindowMetadata(
            pid: pid,
            bundleIdentifier: bundleID,
            appName: runningApp.localizedName ?? "",
            windowTitle: title,
            windowRole: "AXWindow",
            windowSubrole: subrole,
            documentPath: document,
            documentURL: docURL,
            frame: frame,
            isMinimized: minimized,
            isOnScreen: true
        )
        guard metadata.isEligible else { return nil }

        // 11. Evidence — propagate ALL abort flags (throws)

        let ancestorRoles = ancestors.map(\.role)

        // Title UI element: resolve and match with CFEqual on the hit path
        var hasTitleInPath = false
        var titleElementFrame: CGRect? = nil
        if let titleEl = try axElement(win, kAXTitleUIElementAttribute, start: start) {
            guard let role = try axString(titleEl, kAXRoleAttribute, start: start),
                  Self.allowedHitRoles.contains(role), role != "AXWindow",
                  try axPID(titleEl, start: start) == pid,
                  let owner = try axElement(titleEl, kAXWindowAttribute, start: start),
                  CFEqual(owner, win) else { throw AXIPCError.ipcFailed }
            let titleFrame = try axFrame(titleEl, start: start)
            guard frame.contains(titleFrame) else { throw AXIPCError.ipcFailed }
            titleElementFrame = titleFrame
            hasTitleInPath = CFEqual(titleEl, hit) || ancestors.contains { CFEqual(titleEl, $0.element) }
        }
        guard hasBudgetRemaining(start) else { throw AXIPCError.budgetExhausted }

        // Traffic-light button frames: must be actual AXButtons owned by
        // the expected PID/window, not arbitrary AX elements.
        // Throws on IPC error; nil = attribute absent (no button).
        let closeFrame = try buttonFrame(
            win, attr: kAXCloseButtonAttribute, expectedPID: pid, windowFrame: frame, start: start)
        let minFrame   = try buttonFrame(
            win, attr: kAXMinimizeButtonAttribute, expectedPID: pid, windowFrame: frame, start: start)
        let zoomFrame  = try buttonFrame(
            win, attr: kAXZoomButtonAttribute, expectedPID: pid, windowFrame: frame, start: start)

        guard hasBudgetRemaining(start) else { throw AXIPCError.budgetExhausted }

        let evidence = HitTestEvidence(
            hitRole: hitRole,
            ancestorRoles: ancestorRoles,
            hasTitleInPath: hasTitleInPath,
            titleElementFrame: titleElementFrame,
            isLeafWindow: hitRole == "AXWindow",
            closeButtonFrame: closeFrame,
            minimizeButtonFrame: minFrame,
            zoomButtonFrame: zoomFrame
        )

        // 12. TitleBarHitTester eligibility
        guard TitleBarHitTester.hitTest(
            hitPoint: point, target: metadata, evidence: evidence
        ) else { return nil }

        return ResolvedTargetWindow(
            metadata: metadata,
            evidence: evidence,
            axWindow: win,
            axApplication: app,
            runningApplication: runningApp
        )
    }

    // MARK: - Timing

    private func monotonicNow() -> TimeInterval {
        ProcessInfo.processInfo.systemUptime
    }

    private func budgetRemaining(_ start: TimeInterval) -> TimeInterval {
        Self.totalBudget - (ProcessInfo.processInfo.systemUptime - start)
    }

    private func hasBudgetRemaining(_ start: TimeInterval) -> Bool {
        AXValidation.hasRemainingBudget(budgetRemaining(start))
    }

    /// Configure a per-proxy IPC timeout bounded by remaining budget and ceiling,
    /// then execute the AX call. Returns the AXError result. Aborts to
    /// `.failure` if timeout configuration itself fails.
    ///
    /// Zero resets the timeout to the default, so it must not represent an expired budget.
    ///
    /// The actual queried `element` must have `AXUIElementSetMessagingTimeout`
    /// called on it so the per-process timeout applies correctly to
    /// the target proxy.
    ///
    /// Checks deadline immediately before AND after the AX call.
    private func withBudgetTimeout(
        element: AXUIElement,
        start: TimeInterval,
        body: () -> AXError
    ) -> AXError {
        // Budget check BEFORE timeout configuration
        guard hasBudgetRemaining(start) else { return .failure }
        guard let timeout = AXValidation.boundedTimeout(
            remaining: budgetRemaining(start),
            ceiling: Self.ipcTimeoutCeiling
        ) else { return .failure }
        // Reject nonfinite or Float-underflow-to-zero timeout
        guard timeout.isFinite, Float(timeout) > 0 else { return .failure }
        // Set timeout on the actual queried element, not systemWide
        let setErr = AXUIElementSetMessagingTimeout(element, Float(timeout))
        guard setErr == .success, hasBudgetRemaining(start) else { return .failure }
        let result = body()
        // Budget check AFTER the AX call
        guard hasBudgetRemaining(start) else { return .failure }
        return result
    }

    // MARK: - AX Query Helpers — throwing

    /// Copy the AX element at a screen position.
    private func axElementAtPosition(
        _ point: CGPoint, start: TimeInterval
    ) throws -> AXUIElement? {
        var element: AXUIElement?
        let err = withBudgetTimeout(element: systemWide, start: start) {
            AXUIElementCopyElementAtPosition(
                systemWide, Float(point.x), Float(point.y), &element)
        }
        guard hasBudgetRemaining(start) else { throw AXIPCError.budgetExhausted }
        guard err == .success else { return nil }
        return element
    }

    /// Read the PID for an element, proving ownership.
    private func axPID(
        _ element: AXUIElement, start: TimeInterval
    ) throws -> pid_t {
        var pid: pid_t = 0
        let err = withBudgetTimeout(element: element, start: start) {
            AXUIElementGetPid(element, &pid)
        }
        guard hasBudgetRemaining(start) else { throw AXIPCError.budgetExhausted }
        guard err == .success else { throw AXIPCError.ipcFailed }
        return pid
    }

    /// Copy raw CFTypeRef for an attribute with budget checks before AND after.
    ///
    /// Returns nil only for `attributeUnsupported`/`noValue`.
    /// Throws on any other error, success-with-nil, or budget exhaustion.
    private func axCopyRawThrowing(
        _ element: AXUIElement, _ attribute: String, start: TimeInterval
    ) throws -> CFTypeRef? {
        guard hasBudgetRemaining(start) else { throw AXIPCError.budgetExhausted }
        var value: CFTypeRef?
        let err = withBudgetTimeout(element: element, start: start) {
            AXUIElementCopyAttributeValue(
                element, attribute as CFString, &value)
        }
        guard hasBudgetRemaining(start) else { throw AXIPCError.budgetExhausted }
        return try AXValidation.optionalAttribute(value, error: err)
    }

    /// Read a CFString attribute. Throws on malformed CF type or IPC error.
    /// Returns `nil` only for `attributeUnsupported`/`noValue`.
    private func axString(
        _ element: AXUIElement, _ attribute: String, start: TimeInterval
    ) throws -> String? {
        guard let v = try axCopyRawThrowing(element, attribute, start: start)
        else { return nil }
        guard CFGetTypeID(v) == CFStringGetTypeID(), let text = v as? String
        else { throw AXIPCError.ipcFailed }
        return text
    }

    /// Copy an AXUIElement-typed attribute. Throws on malformed CF type
    /// or IPC error. Returns `nil` only for absent.
    private func axElement(
        _ element: AXUIElement, _ attribute: String, start: TimeInterval
    ) throws -> AXUIElement? {
        guard let v = try axCopyRawThrowing(element, attribute, start: start)
        else { return nil }
        guard CFGetTypeID(v) == AXUIElementGetTypeID() else { throw AXIPCError.ipcFailed }
        return unsafeBitCast(v, to: AXUIElement.self)
    }

    /// Read a boolean attribute strictly as CFBoolean.
    ///
    /// CFBoolean is the canonical AX boolean type. CFNumber values that
    /// happen to be 0 or 1 are NOT accepted — that would coerce arbitrary
    /// CFNumber to Bool, masking a type mismatch.
    ///
    /// Returns `nil` when the attribute is absent (.noValue/.attributeUnsupported).
    /// Throws on malformed CF type, success-with-nil, or IPC error.
    private func axBoolStrict(
        _ element: AXUIElement, _ attribute: String, start: TimeInterval
    ) throws -> Bool? {
        guard let v = try axCopyRawThrowing(element, attribute, start: start)
        else { return nil }
        return try AXValidation.boolean(v)
    }

    /// Read position + size as a CGRect (Quartz/AX top-left coordinates).
    /// Throws on any IPC error, malformed type, or failed conversion.
    /// `attributeUnsupported`/`noValue` on either position or size → throws
    /// (the window frame is required).
    private func axFrame(
        _ element: AXUIElement, start: TimeInterval
    ) throws -> CGRect {
        guard let pv = try axCopyRawThrowing(element, kAXPositionAttribute, start: start)
        else { throw AXIPCError.ipcFailed }
        guard let sv = try axCopyRawThrowing(element, kAXSizeAttribute, start: start)
        else { throw AXIPCError.ipcFailed }
        guard CFGetTypeID(pv) == AXValueGetTypeID(),
              CFGetTypeID(sv) == AXValueGetTypeID() else { throw AXIPCError.ipcFailed }
        let posVal  = pv as! AXValue
        let sizeVal = sv as! AXValue
        guard AXValueGetType(posVal)  == .cgPoint,
              AXValueGetType(sizeVal) == .cgSize  else { throw AXIPCError.ipcFailed }
        var pt = CGPoint.zero
        var sz = CGSize.zero
        guard AXValueGetValue(posVal,  .cgPoint, &pt),
              AXValueGetValue(sizeVal, .cgSize,  &sz) else { throw AXIPCError.ipcFailed }
        let frame = CGRect(origin: pt, size: sz)
        guard frame.origin.x.isFinite, frame.origin.y.isFinite,
              frame.size.width > 0, frame.size.height > 0,
              frame.maxX.isFinite, frame.maxY.isFinite else { throw AXIPCError.ipcFailed }
        return frame
    }

    /// Read a URL attribute as a String (handles both CFURL and CFString).
    /// Throws on malformed CF type or IPC error.
    /// Returns `nil` only for `attributeUnsupported`/`noValue`.
    private func axURLOptional(
        _ element: AXUIElement, _ attribute: String, start: TimeInterval
    ) throws -> String? {
        guard let v = try axCopyRawThrowing(element, attribute, start: start)
        else { return nil }
        let tid = CFGetTypeID(v)
        if tid == CFStringGetTypeID(), let text = v as? String { return text }
        if tid == CFURLGetTypeID(), let url = v as? URL { return url.absoluteString }
        // Type mismatch: not a string or URL — throw
        throw AXIPCError.ipcFailed
    }

    /// Read a button reference and validate it is an actual AXButton
    /// owned by the expected PID, with its AXWindow matching the
    /// selected window via CFEqual, and a valid finite positive frame.
    ///
    /// Returns nil if the button is absent (.noValue/.attributeUnsupported).
    /// Throws on: IPC error, non-AXButton role, PID mismatch, owning
    /// window mismatch, missing/invalid frame.
    private func buttonFrame(
        _ window: AXUIElement,
        attr: String,
        expectedPID: pid_t,
        windowFrame: CGRect,
        start: TimeInterval
    ) throws -> CGRect? {
        guard let btn = try axElement(window, attr, start: start)
        else { return nil } // absent — no button

        // Verify actual AXButton role (required)
        guard let role = try axString(btn, kAXRoleAttribute, start: start),
              role == "AXButton" else { throw AXIPCError.ipcFailed }

        // Verify PID ownership: button must belong to the same process
        let btnPID = try axPID(btn, start: start)
        guard btnPID == expectedPID else { throw AXIPCError.ipcFailed }

        guard let owner = try axElement(btn, kAXWindowAttribute, start: start),
              CFEqual(owner, window) else { throw AXIPCError.ipcFailed }

        // Read and validate frame (required for present button)
        let frame = try axFrame(btn, start: start)
        guard TitleBarHitTester.isValidButtonFrame(frame, in: windowFrame)
        else { throw AXIPCError.ipcFailed }
        return frame
    }

    /// Check whether the window has a sheet or modal child.
    ///
    /// Returns `true` = reject target. Throws on:
    /// - AX query errors on the children attribute
    /// - Missing children attribute value (nil on success)
    /// - Non-CFArray children value
    /// - Arrays exceeding `maxChildrenForSheetCheck` (>24)
    /// - Non-AXUIElement members in the array
    /// - Budget exhaustion during inspection
    ///
    /// Inspects ALL accepted children (not just the first N of a long list).
    private func axHasSheetOrModalChild(
        _ window: AXUIElement, start: TimeInterval
    ) throws -> Bool {
        guard let v = try axCopyRawThrowing(window, kAXChildrenAttribute, start: start)
        else { throw AXIPCError.ipcFailed }
        // Missing children value on success: fail closed (throw)
        // (axCopyRawThrowing already throws on success-nil)
        // Validate the array with CF type checks on every member
        guard let kids = AXValidation.validatedChildArray(
            v, maxLength: Self.maxChildrenForSheetCheck
        ) else {
            // >24 children, non-array, or non-AXUIElement member: fail closed
            throw AXIPCError.ipcFailed
        }
        // Inspect ALL accepted children
        for child in kids {
            guard hasBudgetRemaining(start) else { throw AXIPCError.budgetExhausted }
            guard let role = try axString(child, kAXRoleAttribute, start: start)
            else { throw AXIPCError.ipcFailed } // fail closed on query error
            if role == "AXSheet" || role == "AXDialog" { return true }
            if let subrole = try axString(child, kAXSubroleAttribute, start: start) {
                if subrole == "AXDialog" || subrole == "AXSystemDialog" { return true }
            }
            // Check modal state on each child (throws on malformed)
            if let modal = try axBoolStrict(child, kAXModalAttribute, start: start),
               modal { return true }
        }
        return false
    }
}
