import Testing
@testable import VersoCore

@Suite("FlipLifecycleState")
struct FlipLifecycleStateTests {

    // MARK: - Normal Lifecycle

    @Test("Normal lifecycle completes")
    func normalLifecycle() throws {
        var state = FlipLifecycleState()

        #expect(state.phase == .idle)
        #expect(!state.isActive)

        try state.startFlip()
        #expect(state.phase == .preparingFront)
        #expect(state.isActive)

        try state.transition(to: .flippingToNote)
        #expect(state.phase == .flippingToNote)

        try state.transition(to: .noteVisible)
        #expect(state.phase == .noteVisible)

        try state.transition(to: .preparingReturn)
        #expect(state.phase == .preparingReturn)

        try state.transition(to: .flippingToWindow)
        #expect(state.phase == .flippingToWindow)

        try state.transition(to: .cleaningUp)
        #expect(state.phase == .cleaningUp)

        try state.transition(to: .idle)
        #expect(state.phase == .idle)
        #expect(!state.isActive)
    }

    // MARK: - Invalid Transitions

    @Test("Invalid transition throws")
    func invalidTransition() throws {
        var state = FlipLifecycleState()
        try state.startFlip()

        #expect(throws: FlipLifecycleState.TransitionError.self) {
            try state.transition(to: .noteVisible)
        }
        #expect(state.phase == .preparingFront)
    }

    @Test("PreparingFront to idle throws")
    func preparingFrontToIdle() throws {
        var state = FlipLifecycleState()
        try state.startFlip()

        #expect(throws: FlipLifecycleState.TransitionError.self) {
            try state.transition(to: .idle)
        }
        #expect(state.phase == .preparingFront)
    }

    // MARK: - Duplicate Transitions

    @Test("Duplicate transition throws", arguments: [
        FlipLifecycleState.Phase.preparingFront,
        .flippingToNote,
        .noteVisible,
        .preparingReturn,
        .flippingToWindow,
        .cleaningUp,
    ])
    func duplicateTransition(phase: FlipLifecycleState.Phase) throws {
        var state = FlipLifecycleState()
        try state.startFlip()

        let phases: [FlipLifecycleState.Phase] = [.preparingFront, .flippingToNote, .noteVisible, .preparingReturn, .flippingToWindow, .cleaningUp]
        for next in phases.dropFirst() {
            if state.phase == phase { break }
            try state.transition(to: next)
        }
        #expect(state.phase == phase)

        // Duplicate should throw
        #expect(throws: FlipLifecycleState.TransitionError.self) {
            try state.transition(to: phase)
        }
    }

    // MARK: - Cancel

    @Test("Cancel from active state")
    func cancelActive() throws {
        var state = FlipLifecycleState()
        try state.startFlip()
        state.cancel()

        #expect(state.phase == .idle)
        #expect(!state.isActive)
    }

    @Test("Cancel while idle is idempotent")
    func cancelIdle() {
        var state = FlipLifecycleState()
        state.cancel()
        state.cancel()

        #expect(state.phase == .idle)
    }

    @Test("Canceling a return closes the operation and rejects its callbacks")
    func cancelReturnClosesOperation() throws {
        var state = FlipLifecycleState()
        try state.startFlip()
        try state.transition(to: .flippingToNote)
        try state.transition(to: .noteVisible)
        try state.transition(to: .preparingReturn)
        let preparingGeneration = state.generation

        state.cancel()
        #expect(state.phase == .idle)
        #expect(state.generation != preparingGeneration)
        #expect(state.isCurrentGeneration(preparingGeneration) == false)
        state.cancel()
        try state.startFlip()
        try state.transition(to: .flippingToNote)
        try state.transition(to: .noteVisible)
        try state.transition(to: .preparingReturn)
        try state.transition(to: .flippingToWindow)
        let flippingGeneration = state.generation
        state.cancel()
        #expect(state.phase == .idle)
        #expect(state.generation != flippingGeneration)
        #expect(state.isCurrentGeneration(flippingGeneration) == false)
    }

    // MARK: - Generation

    @Test("StartFlip increments generation")
    func startFlipGeneration() throws {
        var state = FlipLifecycleState()
        let gen1 = state.generation

        try state.startFlip()
        let gen2 = state.generation

        #expect(gen2 == gen1 &+ 1)
    }

    @Test("isCurrentGeneration false when idle")
    func isCurrentGenerationIdle() throws {
        var state = FlipLifecycleState()
        try state.startFlip()
        let activeGen = state.generation

        state.cancel()
        #expect(state.generation != activeGen)
        #expect(!state.isCurrentGeneration(activeGen))
    }

    @Test("Transition to preparingFront from idle throws")
    func directPreparingFront() {
        var state = FlipLifecycleState()

        #expect(throws: FlipLifecycleState.TransitionError.self) {
            try state.transition(to: .preparingFront)
        }
        #expect(state.phase == .idle)
    }
}

@Test("Parent regression: invalid, duplicate and stale lifecycle callbacks fail")
func parentLifecycleGuards() throws {
    var state = FlipLifecycleState()
    try state.startFlip()
    let canceled = state.generation
    #expect(throws: FlipLifecycleState.TransitionError.self) { try state.transition(to: .idle) }
    #expect(throws: FlipLifecycleState.TransitionError.self) { try state.transition(to: .preparingFront) }
    state.cancel()
    state.cancel()
    #expect(state.phase == .idle)
    #expect(!state.isCurrentGeneration(canceled))
    try state.startFlip()
    let current = state.generation
    #expect(current != canceled)
    #expect(!state.isCurrentGeneration(canceled))
    let phases: [FlipLifecycleState.Phase] = [.flippingToNote, .noteVisible, .preparingReturn, .flippingToWindow, .cleaningUp, .idle]
    for phase in phases {
        try state.transition(to: phase)
    }
    #expect(state.phase == .idle)
    #expect(!state.isCurrentGeneration(current))
}
