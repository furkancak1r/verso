import CoreGraphics

public enum CoordinateSpaceConverter {

    public static let minimumOverlayDimension: CGFloat = 50

    // MARK: - Public API

    /// Convert Quartz/AX top-left points to AppKit bottom-left points.
    public static func toAppKit(_ rect: CGRect, screenH: CGFloat) -> CGRect? {
        guard let validated = validateRect(rect, screenH: screenH) else { return nil }
        return flipY(validated, screenH: screenH)
    }

    /// The same Y flip converts AppKit points back to Quartz/AX points.
    public static func toQuartz(_ rect: CGRect, screenH: CGFloat) -> CGRect? {
        guard let validated = validateRect(rect, screenH: screenH) else { return nil }
        return flipY(validated, screenH: screenH)
    }

    /// Convert point between coordinate systems
    public static func pointToAppKit(_ point: CGPoint, screenH: CGFloat) -> CGPoint? {
        guard screenH.isFinite, screenH > 0,
              point.x.isFinite, point.y.isFinite else { return nil }

        let flippedY = screenH - point.y
        guard flippedY.isFinite else { return nil }

        return CGPoint(x: point.x, y: flippedY)
    }

    /// Check if a Quartz rect is eligible for overlay display
    public static func isEligibleOverlayFrame(
        _ quartzRect: CGRect,
        screenH: CGFloat,
        displayFrames: [CGRect]
    ) -> Bool {
        guard screenH.isFinite, screenH > 0,
              !displayFrames.isEmpty,
              isValidScreenReference(displayFrames) else { return false }

        // ponytail: cap windows at twice the desktop extent; revisit for virtual desktops.
        let desktopUnion = displayFrames.reduce(CGRect.null) { $0.union($1) }
        guard desktopUnion.width.isFinite, desktopUnion.height.isFinite else { return false }
        let maxWidth = desktopUnion.width * 2
        let maxHeight = desktopUnion.height * 2
        guard maxWidth.isFinite, maxHeight.isFinite else { return false }

        // Convert to AppKit for validation
        guard let appKitRect = toAppKit(quartzRect, screenH: screenH) else { return false }

        // Check raw size validity (before standardization)
        let rawW = quartzRect.size.width
        let rawH = quartzRect.size.height
        guard rawW.isFinite, rawH.isFinite, rawW > 0, rawH > 0 else { return false }

        // Reject tiny windows
        guard rawW >= minimumOverlayDimension, rawH >= minimumOverlayDimension else { return false }

        // Reject oversized windows
        guard rawW <= maxWidth, rawH <= maxHeight else { return false }

        // Reject fully offscreen (no intersection with any display)
        let intersectsAnyDisplay = displayFrames.contains { display in
            appKitRect.intersects(display)
        }
        guard intersectsAnyDisplay else { return false }

        // Reject fullscreen match (position within 2 points of any display with same size)
        for display in displayFrames {
            if abs(display.width - appKitRect.width) <= 2,
               abs(display.height - appKitRect.height) <= 2,
               abs(display.origin.x - appKitRect.origin.x) <= 2,
               abs(display.origin.y - appKitRect.origin.y) <= 2 {
                return false
            }
        }

        return true
    }

    // MARK: - Validation

    public static func isValidScreenReference(_ displayFrames: [CGRect]) -> Bool {
        guard !displayFrames.isEmpty else { return false }
        return displayFrames.allSatisfy { frame in
            frame.origin.x.isFinite && frame.origin.y.isFinite &&
            frame.size.width.isFinite && frame.size.height.isFinite &&
            frame.size.width > 0 && frame.size.height > 0 &&
            (frame.origin.x + frame.size.width).isFinite &&
            (frame.origin.y + frame.size.height).isFinite
        }
    }

    // MARK: - Private Helpers

    private static func validateRect(_ rect: CGRect, screenH: CGFloat) -> CGRect? {
        guard screenH.isFinite, screenH > 0 else { return nil }

        let rawW = rect.size.width
        let rawH = rect.size.height
        guard rawW.isFinite, rawH.isFinite, rawW > 0, rawH > 0 else { return nil }

        let origin = rect.origin
        guard origin.x.isFinite, origin.y.isFinite else { return nil }

        let maxX = origin.x + rawW
        let maxY = origin.y + rawH
        guard maxX.isFinite, maxY.isFinite else { return nil }

        return rect
    }

    // Y flip is an involution: same formula for both directions
    private static func flipY(_ rect: CGRect, screenH: CGFloat) -> CGRect? {
        let newY = screenH - rect.origin.y - rect.size.height
        guard newY.isFinite, (newY + rect.size.height).isFinite else { return nil }

        return CGRect(
            x: rect.origin.x,
            y: newY,
            width: rect.size.width,
            height: rect.size.height
        )
    }
}
