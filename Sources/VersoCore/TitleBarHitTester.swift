import CoreGraphics

/// Evidence about a hit on an AX element, provided by the caller (AX service).
///
/// All coordinates are Quartz/AX top-left: origin at top-left of primary display,
/// Y increases downward. Top edge of window = `frame.origin.y`.
public struct HitTestEvidence: Sendable, Equatable {
    /// AX role of the directly-hit element.
    public let hitRole: String
    /// AX roles from the nearest parent outward, excluding the hit itself.
    /// Empty means ancestor queries failed or found nothing.
    public let ancestorRoles: [String]
    /// Whether an actual AXTitleUIElement was found in the hit path.
    public let hasTitleInPath: Bool
    /// Actual frame of the proven AXTitleUIElement, if any. AX top-left coordinates.
    public let titleElementFrame: CGRect?
    /// Whether the directly-hit element is the AXWindow itself.
    public let isLeafWindow: Bool
    /// Actual AX frame of the close (traffic-light) button. nil = not found.
    public let closeButtonFrame: CGRect?
    /// Actual AX frame of the minimize button. nil = not found.
    public let minimizeButtonFrame: CGRect?
    /// Actual AX frame of the zoom button. nil = not found.
    public let zoomButtonFrame: CGRect?

    public init(
        hitRole: String,
        ancestorRoles: [String] = [],
        hasTitleInPath: Bool = false,
        titleElementFrame: CGRect? = nil,
        isLeafWindow: Bool = false,
        closeButtonFrame: CGRect? = nil,
        minimizeButtonFrame: CGRect? = nil,
        zoomButtonFrame: CGRect? = nil
    ) {
        self.hitRole = hitRole
        self.ancestorRoles = ancestorRoles
        self.hasTitleInPath = hasTitleInPath
        self.titleElementFrame = titleElementFrame
        self.isLeafWindow = isLeafWindow
        self.closeButtonFrame = closeButtonFrame
        self.minimizeButtonFrame = minimizeButtonFrame
        self.zoomButtonFrame = zoomButtonFrame
    }
}

/// Conservative title-bar hit testing using real AX evidence and geometry.
///
/// Coordinates throughout are Quartz/AX top-left (Y increases downward).
/// `frame.origin.y` = top edge, `frame.origin.y + frame.height` = bottom edge.
/// `isInTopArea` means the hit is in the title-bar band just below the top edge.
public enum TitleBarHitTester {

    /// Height of a standard macOS title bar in points.
    public static let titleBarHeight: CGFloat = 28

    /// Typical min width of a traffic-light button.
    public static let minButtonDimension: CGFloat = CGFloat(8)

    /// Max width/height allowed for a plausible traffic-light button.
    public static let maxButtonDimension: CGFloat = CGFloat(24)

    // MARK: - Main hit test

    /// Pure title-bar hit test using caller-provided AX evidence.
    ///
    /// Returns `true` only for an eligible title-bar interaction:
    /// - Explicit title: actual AXTitleUIElement match in the narrow top band,
    ///   with valid finite frame containing the hit point, complete ancestry,
    ///   and no content/interactive/sheet/unknown ancestor roles.
    /// - Geometry fallback: direct AXWindow hit (requires `AXWindow` hit role),
    ///   corroborated by at least two distinct, same-row traffic-light button
    ///   frames fully inside the target window.
    ///
    /// Returns `false` for: controls, content elements, toolbars, static text
    /// without explicit title evidence, sheets, missing evidence, button clicks,
    /// and invalid geometry.
    public static func hitTest(
        hitPoint: CGPoint,
        target: TargetWindowMetadata,
        evidence: HitTestEvidence
    ) -> Bool {
        // Basic eligibility: target must be valid and hit must be in window.
        guard target.isEligible else { return false }
        guard isFinitePoint(hitPoint) else { return false }
        guard isInTargetWindow(hitPoint: hitPoint, target: target) else { return false }

        // Reject hits landing on any supplied traffic-light button frame.
        // This prevents window-background evidence from consuming button clicks.
        if isInsideSuppliedButton(hitPoint: hitPoint, evidence: evidence) { return false }

        // Interactive controls always fail, even if reported with title evidence.
        if isInteractiveRole(evidence.hitRole) { return false }

        // Explicit title-element evidence path.
        if evidence.hasTitleInPath {
            guard ["AXStaticText", "AXGroup", "AXToolbar"].contains(evidence.hitRole),
                  !evidence.isLeafWindow else { return false }
            guard isInTopArea(hitPoint: hitPoint, target: target) else { return false }
            // Validate actual title frame: present, finite, in top band, contains hit.
            guard let titleFrame = evidence.titleElementFrame,
                  isValidTitleFrame(titleFrame, in: target.frame, hitPoint: hitPoint) else { return false }
            // ponytail: unknown roles fail closed; add roles only with verified title evidence.
            guard evidence.ancestorRoles.contains("AXWindow"),
                  evidence.ancestorRoles.allSatisfy({ ["AXApplication", "AXWindow", "AXGroup", "AXToolbar", "AXStaticText"].contains($0) }) else { return false }
            return true
        }

        // Direct AXWindow background hit: geometry fallback with button corroboration.
        if evidence.isLeafWindow {
            // Require actual AXWindow role — a non-window hit with isLeafWindow is contradictory.
            guard evidence.hitRole == "AXWindow" else { return false }
            // No geometry fallback when ancestor queries failed.
            guard evidence.ancestorRoles == ["AXApplication"] else { return false }
            guard isInTopArea(hitPoint: hitPoint, target: target) else { return false }
            return hasCorroboratedButtonFrames(target: target, evidence: evidence)
        }

        // Anything else in the top area without explicit title evidence fails.
        return false
    }

    // MARK: - Geometry validation helpers

    /// Whether a point has finite coordinates.
    public static func isFinitePoint(_ p: CGPoint) -> Bool {
        p.x.isFinite && p.y.isFinite
    }

    /// Whether the hit point is within the target window frame.
    /// Uses CGRect.contains which handles half-open intervals correctly.
    public static func isInTargetWindow(hitPoint: CGPoint, target: TargetWindowMetadata) -> Bool {
        target.frame.contains(hitPoint)
    }

    /// Whether the hit point is in the narrow top title-bar area.
    /// In AX top-left coordinates: top edge = frame.origin.y, band extends downward.
    public static func isInTopArea(hitPoint: CGPoint, target: TargetWindowMetadata) -> Bool {
        let bandHeight = min(titleBarHeight, target.frame.height * 0.2)
        let topEdge = target.frame.origin.y
        // Y increases downward; top area is [topEdge, topEdge + bandHeight).
        return hitPoint.y >= topEdge && hitPoint.y < topEdge + bandHeight
    }

    /// Whether the hit point overlaps a given button frame.
    public static func isInButtonFrame(hitPoint: CGPoint, buttonFrame: CGRect) -> Bool {
        buttonFrame.contains(hitPoint)
    }

    // MARK: - Title frame validation

    /// Whether the title frame is valid, in the title-bar band, and contains the hit point.
    private static func isValidTitleFrame(_ tf: CGRect, in windowFrame: CGRect, hitPoint: CGPoint) -> Bool {
        // Must have positive, finite dimensions (raw size, not standardized).
        guard tf.size.width > 0, tf.size.height > 0 else { return false }
        guard tf.origin.x.isFinite, tf.origin.y.isFinite,
              tf.maxX.isFinite, tf.maxY.isFinite else { return false }
        // Must be within the title-bar band of the window.
        let bandHeight = min(titleBarHeight, windowFrame.height * 0.2)
        let topEdge = windowFrame.origin.y
        guard windowFrame.contains(tf), tf.origin.y >= topEdge,
              tf.maxY <= topEdge + bandHeight else { return false }
        // Must contain the hit point.
        guard tf.contains(hitPoint) else { return false }
        return true
    }

    /// Whether a point is inside any of the supplied traffic-light button frames.
    private static func isInsideSuppliedButton(hitPoint: CGPoint, evidence: HitTestEvidence) -> Bool {
        for frame in [evidence.closeButtonFrame, evidence.minimizeButtonFrame, evidence.zoomButtonFrame] {
            if let f = frame, f.contains(hitPoint) { return true }
        }
        return false
    }

    // MARK: - Button frame corroboration

    /// Whether the evidence contains at least two valid, distinct traffic-light
    /// button frames in the same title-bar row, fully inside the target window.
    ///
    /// Duplicate frames or misaligned rows are rejected — two buttons must be
    /// two genuinely separate buttons.
    public static func hasCorroboratedButtonFrames(
        target: TargetWindowMetadata,
        evidence: HitTestEvidence
    ) -> Bool {
        let allFrames = [evidence.closeButtonFrame, evidence.minimizeButtonFrame, evidence.zoomButtonFrame]
        let valid = allFrames.compactMap { $0 }.filter { isValidButtonFrame($0, in: target.frame) }
        guard valid.count >= 2 else { return false }
        // Must be distinct frames — duplicate positions are not two buttons.
        for i in 0..<valid.count {
            for j in (i+1)..<valid.count {
                if valid[i].intersects(valid[j]) { return false }
            }
        }
        // Must be in the same row (within tolerance for rounding).
        let firstY = valid[0].origin.y
        let rowTolerance: CGFloat = 2
        guard valid.allSatisfy({ abs($0.origin.y - firstY) <= rowTolerance }) else { return false }
        return true
    }

    /// Whether a button frame is a plausible traffic-light button fully inside the window.
    ///
    /// Uses raw `size.width`/`size.height` because getters standardize negative sizes.
    public static func isValidButtonFrame(_ bf: CGRect, in windowFrame: CGRect) -> Bool {
        // Raw size must be positive and finite.
        guard bf.size.width > 0, bf.size.height > 0 else { return false }
        guard bf.origin.x.isFinite, bf.origin.y.isFinite,
              bf.maxX.isFinite, bf.maxY.isFinite else { return false }
        guard bf.size.width >= minButtonDimension, bf.size.height >= minButtonDimension else { return false }
        guard bf.size.width <= maxButtonDimension, bf.size.height <= maxButtonDimension else { return false }
        // Must be fully inside the target window (not just overlapping the band).
        guard bf.minX >= windowFrame.minX, bf.maxX <= windowFrame.maxX,
              bf.minY >= windowFrame.minY, bf.maxY <= windowFrame.maxY else { return false }
        // Must overlap the title-bar band of the window.
        let bandHeight = min(titleBarHeight, windowFrame.height * 0.2)
        let topEdge = windowFrame.origin.y
        let band = CGRect(x: windowFrame.origin.x, y: topEdge,
                          width: windowFrame.width, height: bandHeight)
        return bf.intersects(band)
    }

    // MARK: - AX role classification

    /// Whether the role identifies an interactive control.
    public static func isInteractiveRole(_ role: String) -> Bool {
        switch role {
        case "AXButton", "AXTextField", "AXTextArea", "AXCheckBox",
             "AXRadioButton", "AXPopUpButton", "AXComboBox",
             "AXSlider", "AXStepper", "AXSegmentedControl",
             "AXColorWell", "AXDisclosureTriangle",
             "AXIncrementor", "AXMenuButton", "AXLink":
            return true
        default:
            return false
        }
    }

    /// Whether the role identifies a content-area element.
    public static func isContentRole(_ role: String) -> Bool {
        switch role {
        case "AXScrollArea", "AXWebArea", "AXTable", "AXOutline",
             "AXTabGroup", "AXTab", "AXList", "AXSplitGroup",
             "AXSplitter", "AXCell", "AXRow", "AXColumn",
             "AXMenu", "AXMenuBar":
            return true
        default:
            return false
        }
    }
}
