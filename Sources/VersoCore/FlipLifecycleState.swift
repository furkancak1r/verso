import Foundation

public struct FlipLifecycleState: Sendable {

    // MARK: - Types

    public enum Phase: Sendable, Equatable {
        case idle
        case preparingFront
        case flippingToNote
        case noteVisible
        case preparingReturn
        case flippingToWindow
        case cleaningUp
    }

    public enum TransitionError: Error, Sendable {
        case invalidTransition(from: Phase, to: Phase)
        case duplicateTransition(to: Phase)
    }

    // MARK: - Properties

    public private(set) var phase: Phase = .idle
    public private(set) var generation: UInt64 = 0

    public var isActive: Bool {
        phase != .idle
    }

    // MARK: - Lifecycle

    public init() {}

    public mutating func startFlip() throws {
        guard phase == .idle else {
            throw TransitionError.invalidTransition(from: phase, to: .preparingFront)
        }
        // Wrapping increment for UInt64
        generation = generation &+ 1
        phase = .preparingFront
    }

    public mutating func transition(to newPhase: Phase) throws {
        // Cannot start a new lifecycle via transition
        if newPhase == .preparingFront && phase == .idle {
            throw TransitionError.invalidTransition(from: phase, to: newPhase)
        }

        guard phase != newPhase else {
            throw TransitionError.duplicateTransition(to: newPhase)
        }

        guard isValidTransition(from: phase, to: newPhase) else {
            throw TransitionError.invalidTransition(from: phase, to: newPhase)
        }

        phase = newPhase
    }

    public mutating func cancel() {
        guard phase != .idle else { return } // idempotent while idle
        generation &+= 1
        phase = .idle
    }

    public func isCurrentGeneration(_ checkGeneration: UInt64) -> Bool {
        guard phase != .idle else { return false }
        return checkGeneration == generation
    }

    // MARK: - Private

    private func isValidTransition(from: Phase, to: Phase) -> Bool {
        switch (from, to) {
        case (.idle, .preparingFront),
             (.preparingFront, .flippingToNote),
             (.flippingToNote, .noteVisible),
             (.noteVisible, .preparingReturn),
             (.preparingReturn, .flippingToWindow),
             (.flippingToWindow, .cleaningUp),
             (.cleaningUp, .idle):
            return true
        default:
            return false
        }
    }
}
