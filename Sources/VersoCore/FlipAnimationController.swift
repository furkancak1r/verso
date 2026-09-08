import Foundation
import QuartzCore

/// Owns the two face layers for both directions of one flip.
@MainActor
public final class FlipAnimationController {
    public static let defaultDuration: TimeInterval = 0.4
    public static let defaultPerspectiveDepth: CGFloat = 1_000

    public enum Direction: Sendable, Equatable {
        case toNote
        case toWindow
    }

    private enum Phase {
        case first
        case second
    }

    private enum RestingState {
        case front
        case note
    }

    private let containerLayer: CALayer
    private let frontLayer: CALayer
    private let backLayer: CALayer
    private let perspectiveDepth: CGFloat
    private var phase: Phase?
    private var direction: Direction?
    private var activeGeneration: UInt64?
    private var nextOperationID: UInt64 = 0
    private var activeOperationID: UInt64?
    private var onEdge: ((UInt64) -> Void)?
    private var onCompletion: ((UInt64) -> Void)?

    private let frontAnimationKey = "verso.flip.front"
    private let backAnimationKey = "verso.flip.back"

    public var isRunning: Bool {
        activeOperationID != nil
    }

    public init(
        containerLayer: CALayer,
        frontLayer: CALayer,
        backLayer: CALayer,
        perspectiveDepth: CGFloat = FlipAnimationController.defaultPerspectiveDepth
    ) {
        self.containerLayer = containerLayer
        self.frontLayer = frontLayer
        self.backLayer = backLayer
        self.perspectiveDepth = perspectiveDepth

        frontLayer.isDoubleSided = false
        backLayer.isDoubleSided = false
        configure(restingState: .front)
    }

    /// Starts a two-stage native Core Animation flip. The edge callback runs
    /// after the outgoing layer is hidden and before the incoming layer is
    /// shown. Forward callers use it to release the front screenshot; reverse
    /// callers keep the fresh screenshot until `completion`.
    public func start(
        direction: Direction = .toNote,
        generation: UInt64,
        reduceMotion: Bool,
        onEdge: @escaping (UInt64) -> Void,
        completion: @escaping (UInt64) -> Void
    ) {
        if isRunning {
            cancel()
        } else {
            removeAnimations()
        }
        configure(restingState: initialState(for: direction))

        nextOperationID = nextOperationID &+ 1
        let operationID = nextOperationID
        activeOperationID = operationID
        activeGeneration = generation
        self.direction = direction
        phase = .first
        self.onEdge = onEdge
        onCompletion = completion

        if reduceMotion {
            _ = finish(direction: direction, generation: generation)
        } else {
            startFirstPhase(
                generation: generation,
                operationID: operationID
            )
        }
    }

    /// Completes the current forward transition without motion, for Reduce
    /// Motion or a Screen Recording permission change.
    @discardableResult
    public func finishToNote(generation: UInt64) -> Bool {
        finish(direction: .toNote, generation: generation)
    }

    /// Completes the current reverse transition without motion. The edge
    /// callback still switches the visible face, and the owner releases the
    /// fresh screenshot from its completion callback.
    @discardableResult
    public func finishToWindow(generation: UInt64) -> Bool {
        finish(direction: .toWindow, generation: generation)
    }

    /// Cancels the transition and restores the initial face state. Passing a
    /// generation makes stale cancellation harmless; an omitted generation is
    /// the idempotent owner cleanup path.
    @discardableResult
    public func cancel(generation: UInt64? = nil) -> Bool {
        if let generation,
           activeGeneration != generation {
            return false
        }

        let wasRunning = isRunning
        invalidateOperation()
        removeAnimations()
        configure(restingState: .front)
        return wasRunning
    }

    @discardableResult
    private func finish(
        direction requestedDirection: Direction,
        generation: UInt64
    ) -> Bool {
        guard let operationID = currentOperationID(for: generation),
              direction == requestedDirection,
              let currentPhase = phase else {
            return false
        }

        let edge = currentPhase == .first ? onEdge : nil
        let completion = onCompletion
        invalidateOperation()
        removeAnimations()
        configure(restingState: finalState(for: requestedDirection))

        edge?(generation)
        // An edge callback may synchronously begin a new operation. The old
        // completion must not advance that later operation, even if it uses
        // the same generation value.
        if activeOperationID == nil, nextOperationID == operationID {
            completion?(generation)
        }
        return true
    }

    private func startFirstPhase(
        generation: UInt64,
        operationID: UInt64
    ) {
        guard let direction else { return }

        let layer = firstLayer(for: direction)
        let from = CATransform3DIdentity
        let to = edgeTransform(for: direction)
        let animation = CABasicAnimation(keyPath: "transform")
        animation.fromValue = NSValue(caTransform3D: from)
        animation.toValue = NSValue(caTransform3D: to)
        animation.duration = Self.defaultDuration / 2
        animation.timingFunction = CAMediaTimingFunction(
            name: .easeInEaseOut
        )

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        CATransaction.setCompletionBlock { [weak self] in
            self?.firstPhaseDidFinish(
                generation: generation,
                operationID: operationID
            )
        }
        layer.transform = to
        layer.add(animation, forKey: animationKey(for: direction, phase: .first))
        CATransaction.commit()
    }

    private func firstPhaseDidFinish(
        generation: UInt64,
        operationID: UInt64
    ) {
        guard isCurrent(generation, operationID: operationID), phase == .first,
              let direction else {
            return
        }

        let edge = onEdge
        onEdge = nil
        phase = .second

        let outgoingLayer = firstLayer(for: direction)
        outgoingLayer.removeAnimation(
            forKey: animationKey(for: direction, phase: .first)
        )
        setHidden(outgoingLayer, true)

        edge?(generation)

        guard isCurrent(generation, operationID: operationID), phase == .second else {
            return
        }
        startSecondPhase(
            generation: generation,
            operationID: operationID
        )
    }

    private func startSecondPhase(
        generation: UInt64,
        operationID: UInt64
    ) {
        guard let direction else { return }

        let layer = secondLayer(for: direction)
        let from = secondStartTransform(for: direction)
        let to = CATransform3DIdentity
        setHidden(layer, false)

        let animation = CABasicAnimation(keyPath: "transform")
        animation.fromValue = NSValue(caTransform3D: from)
        animation.toValue = NSValue(caTransform3D: to)
        animation.duration = Self.defaultDuration / 2
        animation.timingFunction = CAMediaTimingFunction(
            name: .easeInEaseOut
        )

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        CATransaction.setCompletionBlock { [weak self] in
            self?.secondPhaseDidFinish(
                generation: generation,
                operationID: operationID
            )
        }
        layer.transform = to
        layer.add(animation, forKey: animationKey(for: direction, phase: .second))
        CATransaction.commit()
    }

    private func secondPhaseDidFinish(
        generation: UInt64,
        operationID: UInt64
    ) {
        guard isCurrent(generation, operationID: operationID), phase == .second,
              let direction else {
            return
        }

        let completion = onCompletion
        invalidateOperation()
        let layer = secondLayer(for: direction)
        layer.removeAnimation(forKey: animationKey(for: direction, phase: .second))
        configure(restingState: finalState(for: direction))

        completion?(generation)
    }

    private func currentOperationID(for generation: UInt64) -> UInt64? {
        guard activeGeneration == generation,
              let activeOperationID,
              phase != nil else {
            return nil
        }
        return activeOperationID
    }

    private func isCurrent(
        _ generation: UInt64,
        operationID: UInt64
    ) -> Bool {
        activeGeneration == generation
            && activeOperationID == operationID
            && phase != nil
    }

    private func invalidateOperation() {
        phase = nil
        direction = nil
        activeGeneration = nil
        activeOperationID = nil
        onEdge = nil
        onCompletion = nil
    }

    private var frontTransform: CATransform3D {
        CATransform3DMakeRotation(.pi / 2, 0, 1, 0)
    }

    private var backTransform: CATransform3D {
        CATransform3DMakeRotation(-.pi / 2, 0, 1, 0)
    }

    private var perspectiveTransform: CATransform3D {
        var transform = CATransform3DIdentity
        transform.m34 = -1 / max(perspectiveDepth, containerLayer.bounds.width * 4)
        return transform
    }

    private func initialState(for direction: Direction) -> RestingState {
        switch direction {
        case .toNote:
            return .front
        case .toWindow:
            return .note
        }
    }

    private func finalState(for direction: Direction) -> RestingState {
        switch direction {
        case .toNote:
            return .note
        case .toWindow:
            return .front
        }
    }

    private func firstLayer(for direction: Direction) -> CALayer {
        switch direction {
        case .toNote:
            return frontLayer
        case .toWindow:
            return backLayer
        }
    }

    private func secondLayer(for direction: Direction) -> CALayer {
        switch direction {
        case .toNote:
            return backLayer
        case .toWindow:
            return frontLayer
        }
    }

    private func edgeTransform(for direction: Direction) -> CATransform3D {
        switch direction {
        case .toNote:
            return frontTransform
        case .toWindow:
            return backTransform
        }
    }

    private func secondStartTransform(for direction: Direction) -> CATransform3D {
        switch direction {
        case .toNote:
            return backTransform
        case .toWindow:
            return frontTransform
        }
    }

    private func animationKey(
        for direction: Direction,
        phase: Phase
    ) -> String {
        switch (direction, phase) {
        case (.toNote, .first), (.toWindow, .second):
            return frontAnimationKey
        case (.toNote, .second), (.toWindow, .first):
            return backAnimationKey
        }
    }

    private func configure(restingState state: RestingState) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        containerLayer.sublayerTransform = perspectiveTransform
        switch state {
        case .front:
            frontLayer.transform = CATransform3DIdentity
            backLayer.transform = backTransform
            frontLayer.isHidden = false
            backLayer.isHidden = true
        case .note:
            frontLayer.transform = frontTransform
            backLayer.transform = CATransform3DIdentity
            frontLayer.isHidden = true
            backLayer.isHidden = false
        }
        CATransaction.commit()
    }

    private func removeAnimations() {
        frontLayer.removeAnimation(forKey: frontAnimationKey)
        backLayer.removeAnimation(forKey: backAnimationKey)
    }

    private func setHidden(_ layer: CALayer, _ hidden: Bool) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer.isHidden = hidden
        CATransaction.commit()
    }
}
