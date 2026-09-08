import Testing
import Foundation
import ApplicationServices
import CoreGraphics
@testable import VersoCore

// MARK: - Focused AX validation tests (phase 2b repair)

// Tests use the small pure AXValidation functions with synthetic CF data.
// No protected GUI testing; these validate deterministic guard logic only.

// MARK: - CFBoolean strict: CFNumber must not become Bool

@Test("CFBoolean true is detected correctly")
func cfBooleanTrueDetected() throws {
    let v: CFTypeRef = kCFBooleanTrue
    let value = try #require(try AXValidation.optionalAttribute(v, error: .success))
    #expect(try AXValidation.boolean(value))
}

@Test("CFBoolean false is detected correctly")
func cfBooleanFalseDetected() throws {
    let v: CFTypeRef = kCFBooleanFalse
    #expect(try !AXValidation.boolean(v))
}

@Test("CFNumber 1 is NOT CFBoolean — strict check rejects it")
func cfNumberNotAcceptedAsBool() {
    let num = 1 as CFNumber
    #expect(throws: AXValidation.Failure.self) { try AXValidation.boolean(num) }
}

@Test("CFNumber 0 is NOT CFBoolean — strict check rejects it")
func cfNumberZeroNotAcceptedAsBool() {
    let num = 0 as CFNumber
    #expect(throws: AXValidation.Failure.self) { try AXValidation.boolean(num) }
}

// MARK: - Failed vs absent attributes

@Test("AttributeUnsupported maps to absent (nil, not error)")
func attributeUnsupportedMeansAbsent() throws {
    #expect(try AXValidation.optionalAttribute(nil, error: .attributeUnsupported) == nil)
}

@Test("noValue maps to absent (nil, not error)")
func noValueMeansAbsent() throws {
    #expect(try AXValidation.optionalAttribute(nil, error: .noValue) == nil)
}

@Test("General IPC error (.failure etc.) throws, not nil")
func generalIPCErrorsThrow() {
    for error in [AXError.failure, .cannotComplete, .invalidUIElement, .apiDisabled, .notImplemented] {
        #expect(throws: AXValidation.Failure.self) {
            try AXValidation.optionalAttribute(kCFBooleanFalse, error: error)
        }
    }
    #expect(throws: AXValidation.Failure.self) {
        try AXValidation.optionalAttribute(nil, error: .success)
    }
}

// MARK: - Invalid timeout

@Test("Bounded timeout rejects remaining ≤ 0")
func boundedTimeoutRejectsNonPositive() {
    #expect(AXValidation.boundedTimeout(remaining: 0, ceiling: 0.015) == nil)
    #expect(AXValidation.boundedTimeout(remaining: -0.001, ceiling: 0.015) == nil)
    #expect(AXValidation.boundedTimeout(remaining: -100, ceiling: 0.015) == nil)
}

@Test("Bounded timeout rejects ceiling ≤ 0")
func boundedTimeoutRejectsZeroCeiling() {
    #expect(AXValidation.boundedTimeout(remaining: 0.05, ceiling: 0) == nil)
    #expect(AXValidation.boundedTimeout(remaining: 0.05, ceiling: -1) == nil)
}

@Test("Bounded timeout returns min(ceiling, remaining) when both positive")
func boundedTimeoutReturnsMinimum() {
    // Remaining < ceiling → remaining wins
    #expect(AXValidation.boundedTimeout(remaining: 0.003, ceiling: 0.015) == 0.003)
    // Ceiling < remaining → ceiling wins
    #expect(AXValidation.boundedTimeout(remaining: 0.050, ceiling: 0.015) == 0.015)
    // Equal → either (same value)
    #expect(AXValidation.boundedTimeout(remaining: 0.015, ceiling: 0.015) == 0.015)
}

@Test("Float underflow to zero is rejected — remaining > 0 required")
func rejectsFloatUnderflowToZero() {
    let tiny: TimeInterval = 1e-100
    #expect(tiny > 0 && Float(tiny) == 0)
    #expect(AXValidation.boundedTimeout(remaining: tiny, ceiling: 0.015) == nil)
}

@Test("Nonfinite timeout is rejected by hasRemainingBudget")
func rejectsNonfiniteRemaining() {
    for invalid in [TimeInterval.infinity, -.infinity, .nan] {
        #expect(!AXValidation.hasRemainingBudget(invalid))
        #expect(AXValidation.boundedTimeout(remaining: invalid, ceiling: 0.015) == nil)
        #expect(AXValidation.boundedTimeout(remaining: 0.08, ceiling: invalid) == nil)
    }
}

// MARK: - Whitelisted ancestor roles

@Test("Whitelisted ancestor roles include all required roles")
func whitelistedRolesCorrect() {
    #expect(AXValidation.whitelistedAncestorRoles.contains("AXApplication"))
    #expect(AXValidation.whitelistedAncestorRoles.contains("AXWindow"))
    #expect(AXValidation.whitelistedAncestorRoles.contains("AXGroup"))
    #expect(AXValidation.whitelistedAncestorRoles.contains("AXToolbar"))
    #expect(AXValidation.whitelistedAncestorRoles.contains("AXStaticText"))
}

@Test("Content and interactive roles are NOT whitelisted")
func contentRolesNotWhitelisted() {
    #expect(!AXValidation.whitelistedAncestorRoles.contains("AXScrollArea"))
    #expect(!AXValidation.whitelistedAncestorRoles.contains("AXWebArea"))
    #expect(!AXValidation.whitelistedAncestorRoles.contains("AXButton"))
    #expect(!AXValidation.whitelistedAncestorRoles.contains("AXTextField"))
    #expect(!AXValidation.whitelistedAncestorRoles.contains("AXTable"))
    #expect(!AXValidation.whitelistedAncestorRoles.contains("AXSplitGroup"))
}

@Test("Unsupported roles are not whitelisted")
func unsupportedRolesNotWhitelisted() {
    for role in AXValidation.unsupportedAncestorRoles {
        #expect(!AXValidation.whitelistedAncestorRoles.contains(role),
                "\(role) is unsupported and should not be whitelisted")
    }
}

// MARK: - hasAtMostOneWindow with hitIsWindow

@Test("Default hitIsWindow=false preserves backward compat")
func backwardCompatAtMostOneWindow() {
    // Existing tests call with just roles array; default hitIsWindow=false
    #expect(AXValidation.hasAtMostOneWindow(["AXGroup", "AXWindow", "AXApplication"]))
    #expect(AXValidation.hasAtMostOneWindow(["AXGroup", "AXApplication"]))
}

@Test("hitIsWindow counts the hit as a window")
func hitIsWindowCountsCorrectly() {
    // Hit IS a window, no AXWindow ancestors → 1 total → pass
    #expect(AXValidation.hasAtMostOneWindow(
        ["AXGroup", "AXApplication"], hitIsWindow: true))
    // Hit IS a window, one AXWindow ancestor → 2 total → reject
    #expect(!AXValidation.hasAtMostOneWindow(
        ["AXWindow", "AXGroup", "AXApplication"], hitIsWindow: true))
    // Hit is NOT a window, one AXWindow ancestor → 1 total → pass
    #expect(AXValidation.hasAtMostOneWindow(
        ["AXWindow", "AXGroup", "AXApplication"], hitIsWindow: false))
}

@Test("hitIsWindow false does not count when hit is not a window")
func nonWindowHitNotDoubleCounted() {
    // hitIsWindow=false, two AXWindow ancestors → 2 → reject
    #expect(!AXValidation.hasAtMostOneWindow(
        ["AXWindow", "AXGroup", "AXWindow", "AXApplication"], hitIsWindow: false))
}

// MARK: - PID agreement edge cases

@Test("Single-element PID list agrees")
func pidAgreementSingleElement() {
    #expect(AXValidation.pidAgreement([42]))
}

@Test("Zero PID prevents agreement even when all equal")
func pidAgreementZeroRejects() {
    #expect(!AXValidation.pidAgreement([0]))
    #expect(!AXValidation.pidAgreement([0, 0, 0]))
}

// MARK: - Child array edge cases

@Test("Mixed CFArray with CFString member is rejected")
func mixedArrayRejected() {
    let el = AXUIElementCreateApplication(1234)
    let str = "bad" as CFString
    let arr = [el, str] as CFArray
    #expect(AXValidation.validatedChildArray(arr, maxLength: 24) == nil)
}

@Test("Array of only non-AXUIElement is rejected")
func allNonElementArrayRejected() {
    let arr = ["a", "b"] as CFArray
    #expect(AXValidation.validatedChildArray(arr, maxLength: 24) == nil)
}

@Test("CFString (not array) is rejected as children")
func nonArrayCFStringRejected() {
    let str = "not-array" as CFString
    #expect(AXValidation.validatedChildArray(str, maxLength: 24) == nil)
}

// MARK: - Validation function determinism

@Test("isValidHitPoint rejects exactly NaN, infinity, and Float-overflow")
func hitPointBoundaryCases() {
    let maxFloat = CGFloat(Float.greatestFiniteMagnitude)
    #expect(AXValidation.isValidHitPoint(CGPoint(x: maxFloat, y: 0)))
    #expect(!AXValidation.isValidHitPoint(CGPoint(x: maxFloat * 2, y: 0)))
    #expect(!AXValidation.isValidHitPoint(CGPoint(x: CGFloat.nan, y: 0)))
    #expect(!AXValidation.isValidHitPoint(CGPoint(x: 0, y: CGFloat.infinity)))
    #expect(!AXValidation.isValidHitPoint(CGPoint(x: 0, y: -CGFloat.infinity)))
}

@Test("PID validation rejects zero, negative, and self")
func pidValidationEdgeCases() {
    let selfPID: pid_t = 100
    #expect(!AXValidation.isValidPID(0, selfPID: selfPID))
    #expect(!AXValidation.isValidPID(-1, selfPID: selfPID))
    #expect(!AXValidation.isValidPID(selfPID, selfPID: selfPID))
    #expect(AXValidation.isValidPID(1, selfPID: selfPID))
    #expect(AXValidation.isValidPID(pid_t.max, selfPID: selfPID))
}
