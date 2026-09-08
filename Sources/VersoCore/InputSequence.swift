import CoreGraphics

/// Production-reused pure state machine tracking an Option-left-click
/// sequence: Option+left-down → left-drag → left-up.
///
/// Accepts no Shift/Control/Command during the initial Option-left-down.
/// Once accepted, the sequence survives releasing Option before mouse-up.
/// A fresh left-down resets any stale sequence state.
/// State is purely driven by synthetic CGEvent inputs — no timers, no
/// AX queries, no UI.
public struct InputSequence: Sendable {

    // MARK: - State

    public enum State: Sendable, Equatable {
        /// No active sequence; all input passes through.
        case idle
        /// Option+left-down accepted, suppressing that down event.
        case accepted
        /// Dragging while suppressed (after accepted down, before up).
        case dragging
    }

    public private(set) var state: State = .idle

    // MARK: - Init

    public init() {}

    // MARK: - Public API

    /// Reset to idle. Called on stop, disabled tap, or fresh down
    /// when a previous sequence was stale.
    public mutating func reset() {
        state = .idle
    }

    /// Whether the current state is actively suppressing events.
    public var isSuppressing: Bool {
        state == .accepted || state == .dragging
    }

    /// Process a left-mouse event and return whether it should be suppressed.
    ///
    /// - Parameters:
    ///   - event: The CGEvent to inspect.
    ///   - acceptanceCallback: Called only for Option+left-down with no
    ///     extra modifiers. Returns `true` if the target accepts this
    ///     interaction (e.g., AX resolved an eligible title bar).
    /// - Returns: `true` if the event should be suppressed (swallowed),
    ///   `false` if it should pass through normally.
    public mutating func processMouseEvent(
        _ event: CGEvent,
        acceptanceCallback: (CGPoint) -> Bool
    ) -> Bool {
        let type = event.type
        let location = event.location

        // Only process left-mouse button events.
        guard isLeftMouseEvent(type) else { return false }

        switch type {
        case .leftMouseDown:
            // Any fresh left-down resets stale sequence state.
            if state != .idle { reset() }

            // Check for Option modifier only (no Shift/Control/Command).
            let flags = event.flags
            let hasOption = flags.contains(.maskAlternate)
            let hasShift = flags.contains(.maskShift)
            let hasControl = flags.contains(.maskControl)
            let hasCommand = flags.contains(.maskCommand)

            guard hasOption, !hasShift, !hasControl, !hasCommand else {
                // Non-Option or extra modifiers: pass through.
                return false
            }

            // Option+left-down with no extra modifiers: call acceptance.
            if acceptanceCallback(location) {
                state = .accepted
                return true // suppress this down
            }
            // Rejected: stay idle, pass through.
            return false

        case .leftMouseDragged:
            if state == .accepted || state == .dragging {
                state = .dragging
                return true // suppress drag
            }
            return false

        case .leftMouseUp:
            if state == .accepted || state == .dragging {
                let wasSuppressing = true
                state = .idle
                return wasSuppressing // suppress this up
            }
            return false

        default:
            return false
        }
    }

    // MARK: - Helpers

    private func isLeftMouseEvent(_ type: CGEventType) -> Bool {
        type == .leftMouseDown || type == .leftMouseUp || type == .leftMouseDragged
    }
}
