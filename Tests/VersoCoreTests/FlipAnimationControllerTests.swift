import CoreGraphics
import Foundation
import QuartzCore
import Testing
@testable import VersoCore

@MainActor
@Suite("FlipAnimationController")
struct FlipAnimationControllerTests {
    @Test("Uses perspective and separate upright face orientations")
    func usesNativePerspectiveAndFaceTransforms() {
        let layers = makeLayers()
        let controller = FlipAnimationController(
            containerLayer: layers.container,
            frontLayer: layers.front,
            backLayer: layers.back
        )

        controller.start(
            generation: 4,
            reduceMotion: false,
            onEdge: { _ in },
            completion: { _ in }
        )

        #expect(layers.container.sublayerTransform.m34 == -0.001)
        #expect(
            CATransform3DEqualToTransform(
                layers.front.transform,
                CATransform3DMakeRotation(.pi / 2, 0, 1, 0)
            )
        )
        #expect(
            CATransform3DEqualToTransform(
                layers.back.transform,
                CATransform3DMakeRotation(-.pi / 2, 0, 1, 0)
            )
        )
        #expect(layers.front.isHidden == false)
        #expect(layers.back.isHidden == true)

        let animation = layers.front.animation(
            forKey: "verso.flip.front"
        ) as? CABasicAnimation
        #expect(animation?.duration == 0.2)
        #expect(
            sameTransform(transform(animation?.fromValue), CATransform3DIdentity)
        )
        #expect(
            sameTransform(
                transform(animation?.toValue),
                CATransform3DMakeRotation(.pi / 2, 0, 1, 0)
            )
        )

        _ = controller.cancel(generation: 4)
    }

    @Test("Reduce Motion completes with an unmirrored note and no pixels")
    func reduceMotionCompletesAndClearsResource() {
        let layers = makeLayers()
        let resource = TemporaryCaptureResource()
        resource.attach(makeImage(), to: layers.front)
        var events: [String] = []
        let controller = FlipAnimationController(
            containerLayer: layers.container,
            frontLayer: layers.front,
            backLayer: layers.back
        )

        controller.start(
            generation: 9,
            reduceMotion: true,
            onEdge: { generation in
                events.append("clear-\(generation)")
                resource.clear()
            },
            completion: { generation in
                events.append("complete-\(generation)")
            }
        )

        #expect(controller.isRunning == false)
        #expect(events == ["clear-9", "complete-9"])
        #expect(resource.image == nil)
        #expect(layers.front.contents == nil)
        #expect(layers.front.isHidden == true)
        #expect(layers.back.isHidden == false)
        #expect(
            CATransform3DEqualToTransform(
                layers.back.transform,
                CATransform3DIdentity
            )
        )
    }

    @Test("Stale generations are rejected and cancellation is idempotent")
    func rejectsStaleCompletionAndCancelsSafely() {
        let layers = makeLayers()
        let controller = FlipAnimationController(
            containerLayer: layers.container,
            frontLayer: layers.front,
            backLayer: layers.back
        )
        var completions = 0

        controller.start(
            generation: 12,
            reduceMotion: false,
            onEdge: { _ in },
            completion: { _ in completions += 1 }
        )

        #expect(controller.finishToNote(generation: 11) == false)
        #expect(controller.isRunning)
        #expect(controller.cancel(generation: 11) == false)
        #expect(controller.isRunning)
        #expect(controller.cancel(generation: 12))
        #expect(controller.cancel(generation: 12) == false)
        #expect(controller.isRunning == false)
        #expect(completions == 0)
        #expect(layers.front.animation(forKey: "verso.flip.front") == nil)
        #expect(layers.back.animation(forKey: "verso.flip.back") == nil)
        #expect(layers.front.contents == nil)
        #expect(layers.front.isHidden == false)
        #expect(layers.back.isHidden == true)
    }

    @Test("Completes both native stages once and releases the edge capture")
    func completesNativeStagesAndReleasesCapture() {
        let layers = makeCompletionLayers()
        let captureLayer = CALayer()
        layers.front.addSublayer(captureLayer)
        let resource = TemporaryCaptureResource()
        weak var releasedImage: CGImage?

        autoreleasepool {
            let capturedImage = makeImage()
            releasedImage = capturedImage
            resource.attach(capturedImage, to: captureLayer)
        }

        var events: [String] = []
        let controller = FlipAnimationController(
            containerLayer: layers.container,
            frontLayer: layers.front,
            backLayer: layers.back
        )

        controller.start(
            generation: 30,
            reduceMotion: false,
            onEdge: { generation in
                events.append("clear-\(generation)")
                resource.clear()
            },
            completion: { generation in
                events.append("complete-\(generation)")
            }
        )

        #expect(layers.front.completionCount(forKey: frontAnimationKey) == 1)
        layers.front.deliverCompletion(forKey: frontAnimationKey)

        #expect(events == ["clear-30"])
        #expect(resource.image == nil)
        #expect(captureLayer.contents == nil)
        #expect(layers.front.isHidden)
        #expect(layers.back.isHidden == false)
        #expect(layers.back.completionCount(forKey: backAnimationKey) == 1)

        layers.back.deliverCompletion(forKey: backAnimationKey)

        #expect(events == ["clear-30", "complete-30"])
        #expect(controller.isRunning == false)
        #expect(
            CATransform3DEqualToTransform(
                layers.back.transform,
                CATransform3DIdentity
            )
        )
        #expect(layers.front.animation(forKey: frontAnimationKey) == nil)
        #expect(layers.back.animation(forKey: backAnimationKey) == nil)
        #expect(releasedImage == nil)
    }

    @Test("Cancellation is reentrant-safe and stale same-generation callbacks stay inert")
    func cancellationDetachesCallbacksBeforeNativeRemoval() {
        let layers = makeCompletionLayers()
        let captureLayer = CALayer()
        let resource = TemporaryCaptureResource()
        weak var releasedImage: CGImage?

        autoreleasepool {
            let capturedImage = makeImage()
            releasedImage = capturedImage
            resource.attach(capturedImage, to: captureLayer)
        }

        var callbackOwner: CallbackOwner? = CallbackOwner()
        weak var releasedOwner: CallbackOwner?
        releasedOwner = callbackOwner
        var clearCount = 0
        var completionCount = 0
        let controller = FlipAnimationController(
            containerLayer: layers.container,
            frontLayer: layers.front,
            backLayer: layers.back
        )

        controller.start(
            generation: 41,
            reduceMotion: false,
            onEdge: { _ in clearCount += 1 },
            completion: { [owner = callbackOwner] _ in
                owner?.calls += 1
                completionCount += 1
            }
        )
        let staleCompletion = layers.front.completion(
            forKey: frontAnimationKey,
            at: 0
        )
        callbackOwner = nil
        #expect(releasedOwner != nil)

        #expect(controller.cancel(generation: 41))
        resource.clear()

        #expect(clearCount == 0)
        #expect(completionCount == 0)
        #expect(controller.isRunning == false)
        #expect(captureLayer.contents == nil)
        #expect(releasedImage == nil)

        controller.start(
            generation: 41,
            reduceMotion: false,
            onEdge: { _ in clearCount += 1 },
            completion: { _ in completionCount += 1 }
        )
        staleCompletion?()

        #expect(controller.isRunning)
        #expect(clearCount == 0)
        #expect(completionCount == 0)

        #expect(controller.cancel(generation: 41))
        #expect(clearCount == 0)
        #expect(completionCount == 0)
        #expect(releasedOwner == nil)
    }

    @Test("Reverse native stages keep the fresh capture until completion")
    func completesReverseStagesAndReleasesFreshCaptureAtFinish() {
        let layers = makeCompletionLayers()
        let captureLayer = CALayer()
        layers.front.addSublayer(captureLayer)
        let resource = TemporaryCaptureResource()
        weak var releasedImage: CGImage?

        autoreleasepool {
            let capturedImage = makeImage()
            releasedImage = capturedImage
            resource.attach(capturedImage, to: captureLayer)
        }

        var events: [String] = []
        let controller = FlipAnimationController(
            containerLayer: layers.container,
            frontLayer: layers.front,
            backLayer: layers.back
        )

        controller.start(
            direction: .toWindow,
            generation: 52,
            reduceMotion: false,
            onEdge: { generation in
                events.append("edge-\(generation)")
            },
            completion: { generation in
                events.append("complete-\(generation)")
                resource.clear()
            }
        )

        #expect(layers.front.isHidden)
        #expect(layers.back.isHidden == false)
        #expect(
            CATransform3DEqualToTransform(
                layers.back.transform,
                CATransform3DMakeRotation(-.pi / 2, 0, 1, 0)
            )
        )
        let noteAnimation = layers.back.animation(
            forKey: backAnimationKey
        ) as? CABasicAnimation
        #expect(
            sameTransform(
                transform(noteAnimation?.fromValue),
                CATransform3DIdentity
            )
        )
        #expect(
            sameTransform(
                transform(noteAnimation?.toValue),
                CATransform3DMakeRotation(-.pi / 2, 0, 1, 0)
            )
        )

        layers.back.deliverCompletion(forKey: backAnimationKey)

        #expect(events == ["edge-52"])
        #expect(resource.image != nil)
        #expect(captureLayer.contents != nil)
        #expect(layers.back.isHidden)
        #expect(layers.front.isHidden == false)

        let windowAnimation = layers.front.animation(
            forKey: frontAnimationKey
        ) as? CABasicAnimation
        #expect(
            sameTransform(
                transform(windowAnimation?.fromValue),
                CATransform3DMakeRotation(.pi / 2, 0, 1, 0)
            )
        )
        #expect(
            sameTransform(
                transform(windowAnimation?.toValue),
                CATransform3DIdentity
            )
        )

        layers.front.deliverCompletion(forKey: frontAnimationKey)

        #expect(events == ["edge-52", "complete-52"])
        #expect(controller.isRunning == false)
        #expect(resource.image == nil)
        #expect(captureLayer.contents == nil)
        #expect(releasedImage == nil)
        #expect(layers.front.isHidden == false)
        #expect(layers.back.isHidden)
        #expect(
            CATransform3DEqualToTransform(
                layers.front.transform,
                CATransform3DIdentity
            )
        )

        layers.front.deliverCompletion(forKey: frontAnimationKey)
        #expect(events == ["edge-52", "complete-52"])
    }

    @Test("Reverse cancellation invalidates callbacks before native removal")
    func cancelsReverseWithoutEdgeOrCompletion() {
        let layers = makeCompletionLayers()
        let captureLayer = CALayer()
        layers.front.addSublayer(captureLayer)
        let resource = TemporaryCaptureResource()
        resource.attach(makeImage(), to: captureLayer)
        var edgeCount = 0
        var completionCount = 0
        let controller = FlipAnimationController(
            containerLayer: layers.container,
            frontLayer: layers.front,
            backLayer: layers.back
        )

        controller.start(
            direction: .toWindow,
            generation: 61,
            reduceMotion: false,
            onEdge: { _ in edgeCount += 1 },
            completion: { _ in completionCount += 1 }
        )
        let staleCompletion = layers.back.completion(
            forKey: backAnimationKey,
            at: 0
        )

        #expect(controller.cancel(generation: 61))
        resource.clear()
        #expect(edgeCount == 0)
        #expect(completionCount == 0)
        #expect(controller.isRunning == false)
        #expect(layers.front.isHidden == false)
        #expect(layers.back.isHidden)
        #expect(
            CATransform3DEqualToTransform(
                layers.front.transform,
                CATransform3DIdentity
            )
        )

        controller.start(
            direction: .toWindow,
            generation: 61,
            reduceMotion: false,
            onEdge: { _ in edgeCount += 1 },
            completion: { _ in completionCount += 1 }
        )
        staleCompletion?()
        #expect(controller.isRunning)
        #expect(edgeCount == 0)
        #expect(completionCount == 0)
        #expect(controller.cancel(generation: 61))
    }

    @Test("Reverse Reduce Motion completes in the native callback order")
    func reverseReduceMotionCompletesAndKeepsResourceUntilOwnerFinish() {
        let layers = makeLayers()
        let captureLayer = CALayer()
        layers.front.addSublayer(captureLayer)
        let resource = TemporaryCaptureResource()
        resource.attach(makeImage(), to: captureLayer)
        var events: [String] = []
        let controller = FlipAnimationController(
            containerLayer: layers.container,
            frontLayer: layers.front,
            backLayer: layers.back
        )

        controller.start(
            direction: .toWindow,
            generation: 70,
            reduceMotion: true,
            onEdge: { generation in
                events.append("edge-\(generation)")
                #expect(resource.image != nil)
            },
            completion: { generation in
                events.append("complete-\(generation)")
                resource.clear()
            }
        )

        #expect(events == ["edge-70", "complete-70"])
        #expect(controller.isRunning == false)
        #expect(resource.image == nil)
        #expect(captureLayer.contents == nil)
        #expect(layers.front.isHidden == false)
        #expect(layers.back.isHidden)
    }

    private func makeLayers() -> (
        container: CALayer,
        front: CALayer,
        back: CALayer
    ) {
        let container = CALayer()
        let front = CALayer()
        let back = CALayer()
        container.addSublayer(front)
        container.addSublayer(back)
        return (container, front, back)
    }

    private func makeCompletionLayers() -> (
        container: CALayer,
        front: CompletionCapturingLayer,
        back: CompletionCapturingLayer
    ) {
        let container = CALayer()
        let front = CompletionCapturingLayer()
        let back = CompletionCapturingLayer()
        container.addSublayer(front)
        container.addSublayer(back)
        return (container, front, back)
    }

    private func transform(_ value: Any?) -> CATransform3D? {
        (value as? NSValue)?.caTransform3DValue
    }

    private func sameTransform(
        _ lhs: CATransform3D?,
        _ rhs: CATransform3D
    ) -> Bool {
        guard let lhs else { return false }
        return CATransform3DEqualToTransform(lhs, rhs)
    }

    private func makeImage() -> CGImage {
        let bytes: [UInt8] = [0, 0, 0, 255]
        let provider = CGDataProvider(data: Data(bytes) as CFData)!
        return CGImage(
            width: 1,
            height: 1,
            bitsPerComponent: 8,
            bitsPerPixel: 32,
            bytesPerRow: 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGBitmapInfo(
                rawValue: CGImageAlphaInfo.premultipliedLast.rawValue
            ),
            provider: provider,
            decode: nil,
            shouldInterpolate: false,
            intent: .defaultIntent
        )!
    }

    @Test("Perspective follows actual face width, including a resize before return")
    func widePerspectiveDepth() {
        let layers = makeLayers()
        layers.container.bounds = CGRect(x: 0, y: 0, width: 600, height: 400)
        let controller = FlipAnimationController(
            containerLayer: layers.container, frontLayer: layers.front,
            backLayer: layers.back
        )
        #expect(layers.container.sublayerTransform.m34 == -1.0 / 2_400)
        layers.container.bounds.size.width = 1200
        controller.start(direction: .toWindow, generation: 1, reduceMotion: true,
                         onEdge: { _ in }, completion: { _ in })
        #expect(layers.container.sublayerTransform.m34 == -1.0 / 4_800)
    }

    @Test("Default perspective depth remains 1000")
    func defaultPerspectiveDepth() {
        let layers = makeLayers()
        let controller = FlipAnimationController(
            containerLayer: layers.container,
            frontLayer: layers.front,
            backLayer: layers.back
        )
        #expect(layers.container.sublayerTransform.m34 == -0.001)
        _ = controller.cancel()
    }
}


private let frontAnimationKey = "verso.flip.front"
private let backAnimationKey = "verso.flip.back"

private final class CallbackOwner {
    var calls = 0
}

private final class CompletionCapturingLayer: CALayer {
    private var completionOnRemoval: (() -> Void)?
    private var completions: [String: [() -> Void]] = [:]

    override func add(_ anim: CAAnimation, forKey key: String?) {
        if let key, let completion = CATransaction.completionBlock() {
            completions[key, default: []].append(completion)
            completionOnRemoval = completion
        }
        super.add(anim, forKey: key)
    }

    override func removeAnimation(forKey key: String) {
        let callback = completionOnRemoval
        completionOnRemoval = nil
        super.removeAnimation(forKey: key)
        callback?()
    }

    func completionCount(forKey key: String) -> Int {
        completions[key]?.count ?? 0
    }

    func completion(forKey key: String, at index: Int) -> (() -> Void)? {
        completions[key].flatMap { $0.indices.contains(index) ? $0[index] : nil }
    }

    func deliverCompletion(forKey key: String) {
        completions[key]?.first?()
    }
}
