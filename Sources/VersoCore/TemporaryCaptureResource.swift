import CoreGraphics
import QuartzCore

/// Owns one ephemeral screenshot and the layer to which it is attached.
///
/// This type deliberately has no image serialization or NSImage conversion.
@MainActor
public final class TemporaryCaptureResource {
    public private(set) var image: CGImage?
    private weak var attachedLayer: CALayer?

    public init() {}

    /// Replace the current screenshot and attach it directly to a display layer.
    public func attach(_ image: CGImage, to layer: CALayer) {
        clear()
        self.image = image
        attachedLayer = layer
        layer.contents = image
    }

    /// Detach and release every pixel reference. Safe to call repeatedly.
    public func clear() {
        attachedLayer?.contents = nil
        attachedLayer = nil
        image = nil
    }

    deinit {
        attachedLayer?.contents = nil
        attachedLayer = nil
        image = nil
    }
}
