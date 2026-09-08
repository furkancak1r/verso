import Foundation
import ApplicationServices

/// Pure, reusable validation functions for AX guard logic.
///
/// All functions are `Sendable` and dependency-free; they validate CF/CG
/// values without touching any live AX element or IPC call.
public enum AXValidation {
    public enum Failure: Error { case invalidResponse }

    /// Only unsupported or absent attributes are optional; failed queries reject the hit.
    public static func optionalAttribute(_ value: CFTypeRef?, error: AXError) throws -> CFTypeRef? {
        switch error {
        case .attributeUnsupported, .noValue: return nil
        case .success:
            guard let value else { throw Failure.invalidResponse }
            return value
        default: throw Failure.invalidResponse
        }
    }

    public static func boolean(_ value: CFTypeRef) throws -> Bool {
        guard CFGetTypeID(value) == CFBooleanGetTypeID() else { throw Failure.invalidResponse }
        return CFBooleanGetValue(unsafeBitCast(value, to: CFBoolean.self))
    }

    // MARK: - Coordinate validation

    /// Whether a hit coordinate is finite and representable as `Float`
    /// without overflow, so `AXUIElementCopyElementAtPosition` is safe.
    ///
    /// Rejects NaN, infinity, and magnitudes exceeding `Float.greatestFiniteMagnitude`.
    public static func isValidHitPoint(_ point: CGPoint) -> Bool {
        guard point.x.isFinite, point.y.isFinite else { return false }
        guard abs(point.x) <= CGFloat(Float.greatestFiniteMagnitude),
              abs(point.y) <= CGFloat(Float.greatestFiniteMagnitude) else { return false }
        return true
    }

    // MARK: - PID validation

    /// Whether a PID is positive and not the current process.
    public static func isValidPID(_ pid: pid_t, selfPID: pid_t) -> Bool {
        pid > 0 && pid != selfPID
    }

    /// Whether all supplied PIDs agree (non-empty, all equal).
    ///
    /// Returns `false` if the array is empty (incomplete evidence) or
    /// any two PIDs differ. Used to prove hit, ancestor, window and
    /// application PIDs all refer to the same process.
    public static func pidAgreement(_ pids: [pid_t]) -> Bool {
        guard let first = pids.first, first > 0 else { return false }
        return pids.allSatisfy { $0 == first }
    }

    // MARK: - Child-array validation

    /// Validate a raw CF value as an array of AXUIElement references.
    ///
    /// Returns `nil` (fail closed) when:
    /// - the value is not a CFArray,
    /// - the array exceeds `maxLength`,
    /// - any element is not an AXUIElement reference.
    ///
    /// Returns the validated array on success.
    public static func validatedChildArray(
        _ raw: CFTypeRef, maxLength: Int
    ) -> [AXUIElement]? {
        guard CFGetTypeID(raw) == CFArrayGetTypeID() else { return nil }
        let cfArray = unsafeBitCast(raw, to: CFArray.self)
        let count = CFArrayGetCount(cfArray)
        guard count <= maxLength else { return nil }
        var result: [AXUIElement] = []
        result.reserveCapacity(count)
        for i in 0..<count {
            guard let element = CFArrayGetValueAtIndex(cfArray, i) else { return nil }
            let cf = unsafeBitCast(element, to: CFTypeRef.self)
            guard CFGetTypeID(cf) == AXUIElementGetTypeID() else { return nil }
            result.append(unsafeBitCast(cf, to: AXUIElement.self))
        }
        return result
    }

    // MARK: - Time budget

    /// Whether a remaining time budget can support at least one more IPC
    /// round-trip. Rejects zero and negative values — passing a zero timeout
    /// to `AXUIElementSetMessagingTimeout` resets to the default timeout.
    public static func hasRemainingBudget(_ remaining: TimeInterval) -> Bool {
        remaining.isFinite && remaining > 0
    }

    /// Compute a per-proxy IPC timeout bounded by the remaining budget
    /// and a caller-supplied ceiling. Returns `nil` if no useful timeout
    /// remains (≤ 0).
    ///
    /// Returns the smaller of `ceiling` and `remaining`, provided it is
    /// strictly positive.
    public static func boundedTimeout(
        remaining: TimeInterval, ceiling: TimeInterval
    ) -> TimeInterval? {
        guard hasRemainingBudget(remaining), hasRemainingBudget(ceiling) else { return nil }
        let timeout = min(ceiling, remaining)
        return Float(timeout).isFinite && Float(timeout) > 0 ? timeout : nil
    }

    // MARK: - Ancestry validation

    /// The set of unsupported intermediate roles that must not appear
    /// between a hit element and its owning AXWindow/AXApplication.
    public static let unsupportedAncestorRoles: Set<String> = [
        "AXSheet", "AXDialog", "AXUnknown",
        "AXMenu", "AXMenuBar", "AXMenuBarItem",
        "AXPopover", "AXHelpTag"
    ]

    /// The set of roles that may appear in the ancestry chain between
    /// a hit element and its owning AXWindow/AXApplication.
    ///
    /// Anything not in this set (and not the owning AXWindow/AXApplication
    /// themselves) is an immediate reject.
    public static let whitelistedAncestorRoles: Set<String> = [
        "AXApplication", "AXWindow", "AXGroup", "AXToolbar", "AXStaticText"
    ]

    /// Whether an ancestry chain contains at most one AXWindow
    /// (the owning window) before AXApplication is reached.
    ///
    /// A second AXWindow means the hit is inside a nested window
    /// (panel, sheet window), which is ambiguous.
    ///
    /// When `hitIsWindow` is true, the hit element itself is counted
    /// as the first AXWindow so nested-window rejection catches a
    /// hit on a child AXWindow inside another AXWindow.
    public static func hasAtMostOneWindow(
        _ roles: [String], hitIsWindow: Bool = false
    ) -> Bool {
        var windowCount = hitIsWindow ? 1 : 0
        for role in roles {
            if role == "AXWindow" {
                windowCount += 1
                if windowCount > 1 { return false }
            }
            if role == "AXApplication" { break }
        }
        return true
    }
}
