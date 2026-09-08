import Testing
import ApplicationServices
import CoreGraphics
@testable import VersoCore

// MARK: - Hit point validation

@Test("Normal finite point is valid")
func validHitPoint() {
    #expect(AXValidation.isValidHitPoint(CGPoint(x: 100, y: 200)))
    #expect(AXValidation.isValidHitPoint(CGPoint(x: -50, y: 300.5)))
    #expect(AXValidation.isValidHitPoint(CGPoint(x: 0, y: 0)))
}

@Test("NaN coordinate is rejected")
func rejectsNaNCoordinate() {
    #expect(!AXValidation.isValidHitPoint(CGPoint(x: CGFloat.nan, y: 200)))
    #expect(!AXValidation.isValidHitPoint(CGPoint(x: 100, y: CGFloat.nan)))
    #expect(!AXValidation.isValidHitPoint(CGPoint(x: CGFloat.nan, y: CGFloat.nan)))
}

@Test("Infinite coordinate is rejected")
func rejectsInfiniteCoordinate() {
    #expect(!AXValidation.isValidHitPoint(CGPoint(x: CGFloat.infinity, y: 200)))
    #expect(!AXValidation.isValidHitPoint(CGPoint(x: 100, y: -CGFloat.infinity)))
    #expect(!AXValidation.isValidHitPoint(CGPoint(x: CGFloat.infinity, y: .infinity)))
}

@Test("Float-overflow coordinate is rejected")
func rejectsFloatOverflowCoordinate() {
    // CGFloat.greatestFiniteMagnitude > Float.greatestFiniteMagnitude on 64-bit
    let huge = CGFloat(Float.greatestFiniteMagnitude) * 2
    #expect(!AXValidation.isValidHitPoint(CGPoint(x: huge, y: 200)))
    #expect(!AXValidation.isValidHitPoint(CGPoint(x: 200, y: -huge)))
}

@Test("Float-boundary coordinate is accepted")
func acceptsFloatBoundaryCoordinate() {
    let maxFloat = CGFloat(Float.greatestFiniteMagnitude)
    #expect(AXValidation.isValidHitPoint(CGPoint(x: maxFloat, y: 200)))
    #expect(AXValidation.isValidHitPoint(CGPoint(x: -maxFloat, y: 200)))
}

// MARK: - PID validation

@Test("Positive non-self PID is valid")
func validPID() {
    #expect(AXValidation.isValidPID(1234, selfPID: 5678))
    #expect(AXValidation.isValidPID(1, selfPID: 2))
}

@Test("Zero or negative PID is rejected")
func rejectsInvalidPID() {
    #expect(!AXValidation.isValidPID(0, selfPID: 100))
    #expect(!AXValidation.isValidPID(-1, selfPID: 100))
}

@Test("Self PID is rejected")
func rejectsSelfPID() {
    #expect(!AXValidation.isValidPID(100, selfPID: 100))
}

// MARK: - PID agreement

@Test("All-same PIDs agree")
func pidAgreementAllSame() {
    #expect(AXValidation.pidAgreement([100, 100, 100]))
    #expect(AXValidation.pidAgreement([42]))
}

@Test("Mixed PIDs do not agree")
func pidAgreementMixed() {
    #expect(!AXValidation.pidAgreement([100, 200, 100]))
    #expect(!AXValidation.pidAgreement([1, 2]))
}

@Test("Empty PID list does not agree")
func pidAgreementEmpty() {
    #expect(!AXValidation.pidAgreement([]))
}

@Test("Zero PID in list does not agree")
func pidAgreementWithZero() {
    #expect(!AXValidation.pidAgreement([0, 0]))
    #expect(!AXValidation.pidAgreement([100, 0]))
}

// MARK: - Child array validation

@Test("Valid child array of AXUIElement passes")
func validChildArray() {
    // Create a synthetic CFArray containing AXUIElement refs.
    // AXUIElementCreateApplication returns a real ref we can use.
    let el = AXUIElementCreateApplication(1234)
    let arr = [el] as CFArray
    let result = AXValidation.validatedChildArray(arr, maxLength: 24)
    #expect(result != nil)
    #expect(result?.count == 1)
}

@Test("Empty child array passes (no children = no sheets)")
func emptyChildArray() {
    let arr = [] as CFArray
    let result = AXValidation.validatedChildArray(arr, maxLength: 24)
    #expect(result != nil)
    #expect(result?.isEmpty == true)
}

@Test("Child array exceeding max length is rejected (fail closed)")
func oversizedChildArray() {
    let el = AXUIElementCreateApplication(1234)
    var elements: [AXUIElement] = []
    for _ in 0..<30 { elements.append(el) }
    let arr = elements as CFArray
    let result = AXValidation.validatedChildArray(arr, maxLength: 24)
    #expect(result == nil) // fail closed
}

@Test("Exactly-at-limit child array passes")
func exactlyAtLimitChildArray() {
    let el = AXUIElementCreateApplication(1234)
    var elements: [AXUIElement] = []
    for _ in 0..<24 { elements.append(el) }
    let arr = elements as CFArray
    let result = AXValidation.validatedChildArray(arr, maxLength: 24)
    #expect(result != nil)
    #expect(result?.count == 24)
}

@Test("One-over-limit child array is rejected")
func oneOverLimitChildArray() {
    let el = AXUIElementCreateApplication(1234)
    var elements: [AXUIElement] = []
    for _ in 0..<25 { elements.append(el) }
    let arr = elements as CFArray
    let result = AXValidation.validatedChildArray(arr, maxLength: 24)
    #expect(result == nil)
}

@Test("Non-CFArray value is rejected")
func rejectsNonArray() {
    let str = "not an array" as CFString
    let result = AXValidation.validatedChildArray(str, maxLength: 24)
    #expect(result == nil)
}

@Test("Array with non-AXUIElement member is rejected")
func rejectsNonAXUIElementMember() {
    // Mixed array: one AXUIElement and one CFString
    let el = AXUIElementCreateApplication(1234)
    let str = "bad" as CFString
    let arr = [el, str] as CFArray
    let result = AXValidation.validatedChildArray(arr, maxLength: 24)
    #expect(result == nil)
}

// MARK: - Remaining budget

@Test("Positive remaining time has budget")
func hasRemainingBudget() {
    #expect(AXValidation.hasRemainingBudget(0.001))
    #expect(AXValidation.hasRemainingBudget(0.080))
    #expect(AXValidation.hasRemainingBudget(100.0))
}

@Test("Zero or negative remaining time has no budget")
func noRemainingBudget() {
    #expect(!AXValidation.hasRemainingBudget(0))
    #expect(!AXValidation.hasRemainingBudget(-0.001))
    #expect(!AXValidation.hasRemainingBudget(-100))
}

// MARK: - Bounded timeout

@Test("Bounded timeout returns min of ceiling and remaining")
func boundedTimeoutRange() {
    let t = AXValidation.boundedTimeout(remaining: 0.050, ceiling: 0.015)
    #expect(t == 0.015) // ceiling wins
    let t2 = AXValidation.boundedTimeout(remaining: 0.008, ceiling: 0.015)
    #expect(t2 == 0.008) // remaining wins
}

@Test("Bounded timeout rejects zero or negative remaining")
func boundedTimeoutRejectsInvalid() {
    #expect(AXValidation.boundedTimeout(remaining: 0, ceiling: 0.015) == nil)
    #expect(AXValidation.boundedTimeout(remaining: -1, ceiling: 0.015) == nil)
    #expect(AXValidation.boundedTimeout(remaining: 0.05, ceiling: 0) == nil)
}

// MARK: - Ancestry validation

@Test("Single AXWindow in ancestry is accepted")
func singleWindowAncestry() {
    #expect(AXValidation.hasAtMostOneWindow(["AXGroup", "AXWindow", "AXApplication"]))
}

@Test("No AXWindow in ancestry is accepted (leaf is the window)")
func noWindowInAncestry() {
    #expect(AXValidation.hasAtMostOneWindow(["AXGroup", "AXApplication"]))
}

@Test("Two AXWindows in ancestry is rejected")
func doubleWindowAncestry() {
    #expect(!AXValidation.hasAtMostOneWindow(["AXWindow", "AXGroup", "AXWindow", "AXApplication"]))
}

@Test("Unsupported ancestor roles are defined")
func unsupportedRolesExist() {
    #expect(AXValidation.unsupportedAncestorRoles.contains("AXSheet"))
    #expect(AXValidation.unsupportedAncestorRoles.contains("AXDialog"))
    #expect(AXValidation.unsupportedAncestorRoles.contains("AXMenu"))
    #expect(AXValidation.unsupportedAncestorRoles.contains("AXUnknown"))
    #expect(!AXValidation.unsupportedAncestorRoles.contains("AXGroup"))
    #expect(!AXValidation.unsupportedAncestorRoles.contains("AXWindow"))
}
