import Testing
import CoreGraphics
@testable import VersoCore

// MARK: - Helpers

/// Create a synthetic CGEvent with the given type, flags, and location.
private func makeEvent(
    type: CGEventType,
    flags: CGEventFlags = [],
    location: CGPoint = CGPoint(x: 400, y: 300)
) -> CGEvent? {
    guard let evt = CGEvent(source: nil) else { return nil }
    evt.type = type
    evt.flags = flags
    evt.location = location
    return evt
}

private func leftDown(
    flags: CGEventFlags = [],
    location: CGPoint = CGPoint(x: 400, y: 300)
) -> CGEvent? {
    makeEvent(type: .leftMouseDown, flags: flags, location: location)
}

private func leftDrag(location: CGPoint = CGPoint(x: 400, y: 300)) -> CGEvent? {
    makeEvent(type: .leftMouseDragged, location: location)
}

private func leftUp(location: CGPoint = CGPoint(x: 400, y: 300)) -> CGEvent? {
    makeEvent(type: .leftMouseUp, location: location)
}

private func alwaysAccept(_ point: CGPoint) -> Bool { true }
private func alwaysReject(_ point: CGPoint) -> Bool { false }

// MARK: - Tests

@Test("Ordinary left-down (no Option) passes through")
func ordinaryLeftDownPassesThrough() {
    var seq = InputSequence()
    guard let evt = leftDown() else { Issue.record("event creation failed"); return }
    let suppressed = seq.processMouseEvent(evt, acceptanceCallback: alwaysAccept)
    #expect(!suppressed)
    #expect(seq.state == .idle)
    #expect(!seq.isSuppressing)
}

@Test("Option left-down with Shift modifier passes through")
func optionWithShiftPasses() {
    var seq = InputSequence()
    guard let evt = leftDown(flags: [.maskAlternate, .maskShift]) else { Issue.record("event creation failed"); return }
    let suppressed = seq.processMouseEvent(evt, acceptanceCallback: alwaysAccept)
    #expect(!suppressed)
    #expect(seq.state == .idle)
}

@Test("Option left-down with Control modifier passes through")
func optionWithControlPasses() {
    var seq = InputSequence()
    guard let evt = leftDown(flags: [.maskAlternate, .maskControl]) else { Issue.record("event creation failed"); return }
    let suppressed = seq.processMouseEvent(evt, acceptanceCallback: alwaysAccept)
    #expect(!suppressed)
    #expect(seq.state == .idle)
}

@Test("Option left-down with Command modifier passes through")
func optionWithCommandPasses() {
    var seq = InputSequence()
    guard let evt = leftDown(flags: [.maskAlternate, .maskCommand]) else { Issue.record("event creation failed"); return }
    let suppressed = seq.processMouseEvent(evt, acceptanceCallback: alwaysAccept)
    #expect(!suppressed)
    #expect(seq.state == .idle)
}

@Test("Option left-down rejected by callback passes through")
func rejectedRecognitionPasses() {
    var seq = InputSequence()
    guard let evt = leftDown(flags: .maskAlternate) else { Issue.record("event creation failed"); return }
    let suppressed = seq.processMouseEvent(evt, acceptanceCallback: alwaysReject)
    #expect(!suppressed)
    #expect(seq.state == .idle)
    #expect(!seq.isSuppressing)
}

@Test("Option left-down accepted suppresses down event")
func acceptedDownSuppresses() {
    var seq = InputSequence()
    guard let evt = leftDown(flags: .maskAlternate) else { Issue.record("event creation failed"); return }
    let suppressed = seq.processMouseEvent(evt, acceptanceCallback: alwaysAccept)
    #expect(suppressed)
    #expect(seq.state == .accepted)
    #expect(seq.isSuppressing)
}

@Test("Drag after accepted down suppresses drag")
func dragAfterAcceptedSuppresses() {
    var seq = InputSequence()
    guard let down = leftDown(flags: .maskAlternate),
          let drag = leftDrag() else { Issue.record("event creation failed"); return }
    _ = seq.processMouseEvent(down, acceptanceCallback: alwaysAccept)
    let suppressed = seq.processMouseEvent(drag, acceptanceCallback: alwaysAccept)
    #expect(suppressed)
    #expect(seq.state == .dragging)
    #expect(seq.isSuppressing)
}

@Test("Up after accepted+drag suppresses and resets to idle")
func upAfterDragSuppressesAndResets() {
    var seq = InputSequence()
    guard let down = leftDown(flags: .maskAlternate),
          let drag = leftDrag(),
          let up = leftUp() else { Issue.record("event creation failed"); return }
    _ = seq.processMouseEvent(down, acceptanceCallback: alwaysAccept)
    _ = seq.processMouseEvent(drag, acceptanceCallback: alwaysAccept)
    let suppressed = seq.processMouseEvent(up, acceptanceCallback: alwaysAccept)
    #expect(suppressed)
    #expect(seq.state == .idle)
    #expect(!seq.isSuppressing)
}

@Test("Up after accepted down (no drag) suppresses and resets")
func upAfterAcceptedDownOnlySuppresses() {
    var seq = InputSequence()
    guard let down = leftDown(flags: .maskAlternate),
          let up = leftUp() else { Issue.record("event creation failed"); return }
    _ = seq.processMouseEvent(down, acceptanceCallback: alwaysAccept)
    let suppressed = seq.processMouseEvent(up, acceptanceCallback: alwaysAccept)
    #expect(suppressed)
    #expect(seq.state == .idle)
}

@Test("Sequence survives releasing Option before mouse-up (no flags on drag/up)")
func optionReleasedBeforeMouseUp() {
    var seq = InputSequence()
    guard let down = leftDown(flags: .maskAlternate),
          let drag = leftDrag(),
          let up = leftUp() else { Issue.record("event creation failed"); return }
    _ = seq.processMouseEvent(down, acceptanceCallback: alwaysAccept)
    // After accepted down, drag/up without Option flag — still part of sequence.
    let dragSuppressed = seq.processMouseEvent(drag, acceptanceCallback: alwaysReject)
    #expect(dragSuppressed)
    let upSuppressed = seq.processMouseEvent(up, acceptanceCallback: alwaysReject)
    #expect(upSuppressed)
    #expect(seq.state == .idle)
}

@Test("Stray drag/up without prior accepted down passes through")
func strayDragUpPasses() {
    var seq = InputSequence()
    guard let drag = leftDrag(),
          let up = leftUp() else { Issue.record("event creation failed"); return }
    let dragResult = seq.processMouseEvent(drag, acceptanceCallback: alwaysAccept)
    #expect(!dragResult)
    let upResult = seq.processMouseEvent(up, acceptanceCallback: alwaysAccept)
    #expect(!upResult)
    #expect(seq.state == .idle)
}

@Test("Fresh left-down resets stale sequence state")
func freshDownResetsStaleState() {
    var seq = InputSequence()
    guard let down1 = leftDown(flags: .maskAlternate),
          let down2 = leftDown() else { Issue.record("event creation failed"); return }
    _ = seq.processMouseEvent(down1, acceptanceCallback: alwaysAccept)
    #expect(seq.state == .accepted)
    // Fresh ordinary down resets.
    let suppressed = seq.processMouseEvent(down2, acceptanceCallback: alwaysAccept)
    #expect(!suppressed)
    #expect(seq.state == .idle)
}

@Test("Fresh Option left-down resets stale accepted state and re-accepts")
func freshOptionDownResetsAndReaccepts() {
    var seq = InputSequence()
    guard let down1 = leftDown(flags: .maskAlternate),
          let drag = leftDrag(),
          let down2 = leftDown(flags: .maskAlternate) else { Issue.record("event creation failed"); return }
    _ = seq.processMouseEvent(down1, acceptanceCallback: alwaysAccept)
    _ = seq.processMouseEvent(drag, acceptanceCallback: alwaysAccept)
    #expect(seq.state == .dragging)
    let suppressed = seq.processMouseEvent(down2, acceptanceCallback: alwaysAccept)
    #expect(suppressed)
    #expect(seq.state == .accepted)
}

@Test("Explicit reset clears all state")
func explicitResetClears() {
    var seq = InputSequence()
    guard let down = leftDown(flags: .maskAlternate),
          let drag = leftDrag() else { Issue.record("event creation failed"); return }
    _ = seq.processMouseEvent(down, acceptanceCallback: alwaysAccept)
    _ = seq.processMouseEvent(drag, acceptanceCallback: alwaysAccept)
    #expect(seq.state == .dragging)
    seq.reset()
    #expect(seq.state == .idle)
    #expect(!seq.isSuppressing)
}

@Test("Disabled tap behavior: after reset, events pass through")
func resetAllowsPassthrough() {
    var seq = InputSequence()
    guard let down = leftDown(flags: .maskAlternate),
          let drag = leftDrag() else { Issue.record("event creation failed"); return }
    _ = seq.processMouseEvent(down, acceptanceCallback: alwaysAccept)
    _ = seq.processMouseEvent(drag, acceptanceCallback: alwaysAccept)
    // Simulate stop/reset.
    seq.reset()
    guard let up = leftUp() else { Issue.record("event creation failed"); return }
    let upResult = seq.processMouseEvent(up, acceptanceCallback: alwaysAccept)
    #expect(!upResult)
    #expect(seq.state == .idle)
}

@Test("Acceptance callback receives correct location")
func callbackReceivesCorrectLocation() {
    var seq = InputSequence()
    let location = CGPoint(x: 123, y: 456)
    guard let evt = leftDown(flags: .maskAlternate, location: location) else {
        Issue.record("event creation failed"); return
    }
    var receivedLocation: CGPoint?
    _ = seq.processMouseEvent(evt) { point in
        receivedLocation = point
        return true
    }
    #expect(receivedLocation == location)
}

@Test("Non-left-mouse events pass through without changing state")
func nonLeftEventsPassThrough() {
    var seq = InputSequence()
    guard let evt = makeEvent(type: .rightMouseDown) else {
        Issue.record("event creation failed"); return
    }
    let result = seq.processMouseEvent(evt, acceptanceCallback: alwaysAccept)
    #expect(!result)
    #expect(seq.state == .idle)
}

@Test("Multiple drags in accepted sequence stay suppressed")
func multipleDragsStaySuppressed() {
    var seq = InputSequence()
    guard let down = leftDown(flags: .maskAlternate),
          let drag1 = leftDrag(location: CGPoint(x: 410, y: 310)),
          let drag2 = leftDrag(location: CGPoint(x: 420, y: 320)),
          let drag3 = leftDrag(location: CGPoint(x: 430, y: 330)),
          let up = leftUp(location: CGPoint(x: 440, y: 340)) else {
        Issue.record("event creation failed"); return
    }
    _ = seq.processMouseEvent(down, acceptanceCallback: alwaysAccept)
    for drag in [drag1, drag2, drag3] {
        let result = seq.processMouseEvent(drag, acceptanceCallback: alwaysReject)
        #expect(result)
        #expect(seq.isSuppressing)
    }
    let upResult = seq.processMouseEvent(up, acceptanceCallback: alwaysReject)
    #expect(upResult)
    #expect(seq.state == .idle)
    #expect(!seq.isSuppressing)
}

@Test("Option alone without left-down is not an event type we see")
func optionOnlyNotProcessed() {
    var seq = InputSequence()
    guard let evt = makeEvent(type: .rightMouseDown, flags: .maskAlternate) else {
        Issue.record("event creation failed"); return
    }
    let result = seq.processMouseEvent(evt, acceptanceCallback: alwaysAccept)
    #expect(!result)
    #expect(seq.state == .idle)
}

@Test("Down accepted then rejected up still suppresses (pairing)")
func acceptedDownSuppressesUpRegardless() {
    var seq = InputSequence()
    guard let down = leftDown(flags: .maskAlternate),
          let up = leftUp() else { Issue.record("event creation failed"); return }
    _ = seq.processMouseEvent(down, acceptanceCallback: alwaysAccept)
    let suppressed = seq.processMouseEvent(up, acceptanceCallback: alwaysReject)
    #expect(suppressed)
    #expect(seq.state == .idle)
}

@Test("Option with multiple extra modifiers rejects")
func optionWithMultipleExtrasRejects() {
    var seq = InputSequence()
    guard let evt = leftDown(flags: [.maskAlternate, .maskShift, .maskControl]) else {
        Issue.record("event creation failed"); return
    }
    let result = seq.processMouseEvent(evt, acceptanceCallback: alwaysAccept)
    #expect(!result)
    #expect(seq.state == .idle)
}

@Test("Stale dragging state reset by fresh down")
func staleDraggingResetByFreshDown() {
    var seq = InputSequence()
    guard let down1 = leftDown(flags: .maskAlternate),
          let drag1 = leftDrag(),
          let down2 = leftDown() else { Issue.record("event creation failed"); return }
    _ = seq.processMouseEvent(down1, acceptanceCallback: alwaysAccept)
    _ = seq.processMouseEvent(drag1, acceptanceCallback: alwaysAccept)
    #expect(seq.state == .dragging)
    // Fresh ordinary down resets stale dragging.
    let result = seq.processMouseEvent(down2, acceptanceCallback: alwaysAccept)
    #expect(!result) // no Option, passes through
    #expect(seq.state == .idle)
}

@Test("Callback-count: non-Option, extra-modifier, stray drag/up, non-left never invoke recognition")
func callbackCountNeverInvokedForUnrecognizedEvents() {
    var seq = InputSequence()
    var callbackCount = 0
    let countingAccept: (CGPoint) -> Bool = { _ in
        callbackCount += 1
        return true
    }

    // 1. Ordinary left-down (no Option): callback NOT invoked.
    guard let ordinaryDown = leftDown() else { Issue.record("event creation failed"); return }
    _ = seq.processMouseEvent(ordinaryDown, acceptanceCallback: countingAccept)
    #expect(callbackCount == 0)

    // 2. Left-down with Option + Shift: callback NOT invoked.
    guard let optShiftDown = leftDown(flags: [.maskAlternate, .maskShift]) else {
        Issue.record("event creation failed"); return
    }
    _ = seq.processMouseEvent(optShiftDown, acceptanceCallback: countingAccept)
    #expect(callbackCount == 0)

    // 3. Left-down with Option + Control + Command: callback NOT invoked.
    guard let optCtrlCmdDown = leftDown(flags: [.maskAlternate, .maskControl, .maskCommand]) else {
        Issue.record("event creation failed"); return
    }
    _ = seq.processMouseEvent(optCtrlCmdDown, acceptanceCallback: countingAccept)
    #expect(callbackCount == 0)

    // 4. Stray drag (no prior accepted down): callback NOT invoked.
    guard let strayDrag = leftDrag() else { Issue.record("event creation failed"); return }
    let dragResult = seq.processMouseEvent(strayDrag, acceptanceCallback: countingAccept)
    #expect(!dragResult)
    #expect(callbackCount == 0)

    // 5. Stray up (no prior accepted down): callback NOT invoked.
    guard let strayUp = leftUp() else { Issue.record("event creation failed"); return }
    let upResult = seq.processMouseEvent(strayUp, acceptanceCallback: countingAccept)
    #expect(!upResult)
    #expect(callbackCount == 0)

    // 6. Non-left event (right-click): callback NOT invoked.
    guard let rightClick = makeEvent(type: .rightMouseDown) else {
        Issue.record("event creation failed"); return
    }
    let rightResult = seq.processMouseEvent(rightClick, acceptanceCallback: countingAccept)
    #expect(!rightResult)
    #expect(callbackCount == 0)

    // 7. Valid Option left-down (no extra modifiers): callback IS invoked.
    guard let validOptDown = leftDown(flags: .maskAlternate) else {
        Issue.record("event creation failed"); return
    }
    let acceptedResult = seq.processMouseEvent(validOptDown, acceptanceCallback: countingAccept)
    #expect(acceptedResult)
    #expect(callbackCount == 1)
    #expect(seq.state == .accepted)

    // 8. Drag in accepted sequence: callback NOT invoked (no re-query).
    guard let drag2 = leftDrag() else { Issue.record("event creation failed"); return }
    let drag2Result = seq.processMouseEvent(drag2, acceptanceCallback: countingAccept)
    #expect(drag2Result)
    #expect(callbackCount == 1) // still 1

    // 9. Up in accepted sequence: callback NOT invoked.
    guard let up2 = leftUp() else { Issue.record("event creation failed"); return }
    let up2Result = seq.processMouseEvent(up2, acceptanceCallback: countingAccept)
    #expect(up2Result)
    #expect(callbackCount == 1) // still 1
    #expect(seq.state == .idle)
}
