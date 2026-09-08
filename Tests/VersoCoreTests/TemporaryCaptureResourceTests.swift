import CoreGraphics
import Foundation
import QuartzCore
import Testing
@testable import VersoCore

@MainActor
@Suite("TemporaryCaptureResource")
struct TemporaryCaptureResourceTests {
    private func image() -> CGImage {
        let bytes: [UInt8] = [255, 0, 0, 255]
        let provider = CGDataProvider(data: Data(bytes) as CFData)!
        return CGImage(
            width: 1,
            height: 1,
            bitsPerComponent: 8,
            bitsPerPixel: 32,
            bytesPerRow: 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
            provider: provider,
            decode: nil,
            shouldInterpolate: false,
            intent: .defaultIntent
        )!
    }

    @Test("Clear detaches the layer and releases the owned image")
    func clearIsIdempotent() {
        let layer = CALayer()
        let resource = TemporaryCaptureResource()
        weak var releasedImage: CGImage?

        autoreleasepool {
            let capturedImage = image()
            releasedImage = capturedImage
            resource.attach(capturedImage, to: layer)
        }
        #expect(resource.image != nil)
        #expect(layer.contents != nil)
        #expect(releasedImage != nil)

        resource.clear()
        resource.clear()
        CATransaction.flush()

        #expect(resource.image == nil)
        #expect(layer.contents == nil)
        #expect(releasedImage == nil)
    }

    @Test("Deinitialization clears an attached layer")
    func deinitClearsLayer() {
        let layer = CALayer()
        weak var releasedImage: CGImage?
        var resource: TemporaryCaptureResource? = TemporaryCaptureResource()
        autoreleasepool {
            let capturedImage = image()
            releasedImage = capturedImage
            resource?.attach(capturedImage, to: layer)
        }
        #expect(layer.contents != nil)
        #expect(releasedImage != nil)

        resource = nil
        CATransaction.flush()

        #expect(layer.contents == nil)
        #expect(releasedImage == nil)
    }

    @Test("Second resource on a separate layer clears independently")
    func independentResources() {
        let frontLayer = CALayer()
        let backdropLayer = CALayer()
        let frontResource = TemporaryCaptureResource()
        let backdropResource = TemporaryCaptureResource()

        autoreleasepool {
            let img1 = image()
            let img2 = image()
            frontResource.attach(img1, to: frontLayer)
            backdropResource.attach(img2, to: backdropLayer)
        }

        #expect(frontResource.image != nil)
        #expect(backdropResource.image != nil)
        #expect(frontLayer.contents != nil)
        #expect(backdropLayer.contents != nil)

        // Clearing one does not affect the other.
        frontResource.clear()
        #expect(frontResource.image == nil)
        #expect(frontLayer.contents == nil)
        #expect(backdropResource.image != nil)
        #expect(backdropLayer.contents != nil)

        backdropResource.clear()
        #expect(backdropResource.image == nil)
        #expect(backdropLayer.contents == nil)
    }
}
