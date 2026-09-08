import CoreGraphics
import Foundation

/// The small, public-data-only part of an SCWindow used for matching.
///
/// The coordinates are Quartz points, just like the AX window frame. No AX or
/// ScreenCaptureKit object is retained here; this value is memory-only.
public struct WindowCaptureCandidate: Sendable, Equatable {
    public let windowID: CGWindowID
    public let pid: pid_t
    public let bundleIdentifier: String?
    public let title: String?
    public let frame: CGRect

    public init(
        windowID: CGWindowID,
        pid: pid_t,
        bundleIdentifier: String?,
        title: String?,
        frame: CGRect
    ) {
        self.windowID = windowID
        self.pid = pid
        self.bundleIdentifier = bundleIdentifier
        self.title = title
        self.frame = frame
    }
}

/// A selected candidate and the evidence that made it the only safe choice.
public struct WindowCaptureMatch: Sendable, Equatable {
    public let candidate: WindowCaptureCandidate
    public let score: Int
    public let titleScore: Int
    public let geometryScore: Int

    public init(
        candidate: WindowCaptureCandidate,
        score: Int,
        titleScore: Int,
        geometryScore: Int
    ) {
        self.candidate = candidate
        self.score = score
        self.titleScore = titleScore
        self.geometryScore = geometryScore
    }
}

/// Pure conservative matching for AX metadata and SCWindow public metadata.
public struct WindowCaptureResolver: Sendable {
    private enum TitleEvidence {
        case matching(score: Int)
        case absent
        case conflicting
    }

    private static let maximumCoordinateMagnitude: CGFloat = 1_000_000
    private static let maximumStringUTF8Length = 4_096
    private static let maximumGeometryDelta: CGFloat = 2
    private static let minimumGeometryScore = 42
    private static let minimumMatchScore = 55

    // ponytail: 16 MP bounds transient screenshot memory; raise only after a measured memory budget.
    public static let conservativePixelBudget = 16_777_216

    /// Perspective/shadow margin as a fraction of the larger window dimension, clamped to a
    /// reasonable pixel range.
    private static let perspectiveMarginFraction: CGFloat = 0.12
    private static let minimumPerspectiveMargin: CGFloat = 40
    private static let maximumPerspectiveMargin: CGFloat = 200

    // MARK: - Display / canvas geometry

    /// A display's public frame in global Quartz coordinates and its pixel
    /// scale (pixels per point). This is the only information needed from an
    /// SCDisplay for pure geometry calculations, keeping VersoCore free of
    /// ScreenCaptureKit imports.
    public struct DisplayFrame: Sendable, Equatable {
        public let frame: CGRect
        public let pointPixelScale: CGFloat

        public init(frame: CGRect, pointPixelScale: CGFloat) {
            self.frame = frame
            self.pointPixelScale = pointPixelScale
        }
    }

    /// The result of a successful canvas geometry calculation.
    public struct CanvasGeometry: Sendable, Equatable {
        /// Canvas rectangle in global Quartz points (AX coordinate space).
        public let canvasFrame: CGRect
        /// sourceRect in display-local points, for `SCStreamConfiguration`.
        public let sourceRect: CGRect
        /// Output pixel dimensions for the canvas region.
        public let dimensions: CaptureDimensions

        public init(
            canvasFrame: CGRect,
            sourceRect: CGRect,
            dimensions: CaptureDimensions
        ) {
            self.canvasFrame = canvasFrame
            self.sourceRect = sourceRect
            self.dimensions = dimensions
        }
    }

    /// Compute an expanded canvas around the target window, clipped at the containing
    /// display edge. Returns nil when the target straddles displays or
    /// lies partly off-screen.
    ///
    /// ponytail: cross-display / partly off-display targets are not supported;
    /// the caller falls back to a normal (non-flip) transition. Multi-display
    /// backdrop composition is a future phase.
    public static func canvasGeometry(
        targetWindowFrame: CGRect,
        displays: [DisplayFrame]
    ) -> CanvasGeometry? {
        guard validFrame(targetWindowFrame),
              !displays.isEmpty else { return nil }

        let margin = max(
            minimumPerspectiveMargin,
            min(
                maximumPerspectiveMargin,
                max(targetWindowFrame.width, targetWindowFrame.height) * perspectiveMarginFraction
            )
        )

        let expandedCanvas = targetWindowFrame.insetBy(
            dx: -margin,
            dy: -margin
        )
        guard expandedCanvas.origin.x.isFinite,
              expandedCanvas.origin.y.isFinite,
              expandedCanvas.size.width.isFinite,
              expandedCanvas.size.height.isFinite,
              expandedCanvas.size.width > 0,
              expandedCanvas.size.height > 0 else { return nil }

        for display in displays {
            guard validFrame(display.frame),
                  display.pointPixelScale.isFinite,
                  display.pointPixelScale > 0 else { continue }

            guard display.frame.contains(targetWindowFrame) else { continue }
            let canvas = expandedCanvas.intersection(display.frame)

            let localX = canvas.origin.x - display.frame.origin.x
            let localY = canvas.origin.y - display.frame.origin.y
            guard localX.isFinite, localY.isFinite else { continue }

            let sourceRect = CGRect(
                x: localX,
                y: localY,
                width: canvas.size.width,
                height: canvas.size.height
            )

            guard let dimensions = CaptureDimensions(
                contentRect: sourceRect,
                pointPixelScale: display.pointPixelScale
            ) else { continue }

            return CanvasGeometry(
                canvasFrame: canvas,
                sourceRect: sourceRect,
                dimensions: dimensions
            )
        }

        return nil
    }

    public init() {}

    /// Return a match only when ownership, evidence, and uniqueness all hold.
    /// A nil result is intentionally neutral: the caller must not guess a
    /// window when the evidence is absent or tied.
    public static func match(
        target: TargetWindowMetadata,
        candidates: [WindowCaptureCandidate]
    ) -> WindowCaptureMatch? {
        guard target.isEligible,
              let targetBundle = validBundleIdentifier(target.bundleIdentifier),
              target.pid > 0,
              validFrame(target.frame),
              validTitle(target.windowTitle) else { return nil }

        var seenWindowIDs = Set<CGWindowID>()
        var plausibleMatch: WindowCaptureMatch?

        for candidate in candidates {
            guard candidate.windowID != 0 else { continue }
            guard seenWindowIDs.insert(candidate.windowID).inserted else {
                return nil
            }
            guard candidate.pid == target.pid,
                  let candidateBundle = validBundleIdentifier(candidate.bundleIdentifier),
                  candidateBundle == targetBundle,
                  validFrame(candidate.frame),
                  validTitle(candidate.title) else { continue }

            let titleEvidence = titleEvidence(
                targetTitle: target.windowTitle,
                candidateTitle: candidate.title
            )
            switch titleEvidence {
            case .conflicting:
                continue
            case .absent, .matching:
                break
            }

            guard let geometryScore = geometryScore(
                target: target.frame,
                candidate: candidate.frame
            ) else { continue }

            // Count every admitted lookalike before scoring confidence. Missing
            // title evidence must not hide a second plausible window.
            guard plausibleMatch == nil else { return nil }

            let titleScore: Int
            switch titleEvidence {
            case .matching(let score):
                titleScore = score
            case .absent, .conflicting:
                titleScore = 0
            }

            plausibleMatch = WindowCaptureMatch(
                candidate: candidate,
                score: titleScore + geometryScore,
                titleScore: titleScore,
                geometryScore: geometryScore
            )
        }

        guard let plausibleMatch,
              plausibleMatch.geometryScore >= minimumGeometryScore,
              plausibleMatch.score >= minimumMatchScore else { return nil }
        return plausibleMatch
    }

    /// Convert a filter's point-space content rect and scale into safe pixels.
    /// The result is validated before it can be used as a capture allocation.
    public struct CaptureDimensions: Sendable, Equatable {
        public let width: Int
        public let height: Int
        public let scale: CGFloat

        public var pixelCount: Int {
            width * height
        }

        public init?(contentRect: CGRect, pointPixelScale: CGFloat) {
            guard WindowCaptureResolver.validFrame(contentRect),
                  pointPixelScale.isFinite,
                  pointPixelScale > 0 else { return nil }

            let scaledWidth = contentRect.size.width * pointPixelScale
            let scaledHeight = contentRect.size.height * pointPixelScale
            guard scaledWidth.isFinite, scaledHeight.isFinite,
                  let width = Self.safePixelDimension(scaledWidth),
                  let height = Self.safePixelDimension(scaledHeight),
                  width.multipliedReportingOverflow(by: height).overflow == false,
                  width * height <= WindowCaptureResolver.conservativePixelBudget else { return nil }

            self.width = width
            self.height = height
            self.scale = pointPixelScale
        }

        private static func safePixelDimension(_ value: CGFloat) -> Int? {
            let rounded = value.rounded(.up)
            guard rounded.isFinite,
                  rounded >= 1,
                  rounded <= CGFloat(WindowCaptureResolver.conservativePixelBudget) else {
                return nil
            }
            return Int(rounded)
        }
    }

    // MARK: - Validation and scoring

    private static func validBundleIdentifier(_ value: String?) -> String? {
        guard let value,
              value.utf8.count <= maximumStringUTF8Length,
              !value.isEmpty,
              value == value.trimmingCharacters(in: .whitespacesAndNewlines),
              !value.contains("\0") else { return nil }
        return value
    }

    private static func validTitle(_ value: String?) -> Bool {
        guard let value else { return true }
        return value.utf8.count <= maximumStringUTF8Length
            && !value.contains("\0")
    }

    private static func validFrame(_ frame: CGRect) -> Bool {
        let width = frame.size.width
        let height = frame.size.height
        guard width.isFinite, height.isFinite,
              width > 0, height > 0,
              width <= maximumCoordinateMagnitude,
              height <= maximumCoordinateMagnitude,
              frame.origin.x.isFinite, frame.origin.y.isFinite,
              abs(frame.origin.x) <= maximumCoordinateMagnitude,
              abs(frame.origin.y) <= maximumCoordinateMagnitude else {
            return false
        }

        let maxX = frame.origin.x + width
        let maxY = frame.origin.y + height
        return maxX.isFinite && maxY.isFinite
            && abs(maxX) <= maximumCoordinateMagnitude
            && abs(maxY) <= maximumCoordinateMagnitude
    }

    private static func titleEvidence(
        targetTitle: String?,
        candidateTitle: String?
    ) -> TitleEvidence {
        guard let targetTitle, !targetTitle.isEmpty,
              let candidateTitle, !candidateTitle.isEmpty else {
            return .absent
        }
        return targetTitle == candidateTitle
            ? .matching(score: 40)
            : .conflicting
    }

    private static func geometryScore(
        target: CGRect,
        candidate: CGRect
    ) -> Int? {
        guard validFrame(target), validFrame(candidate) else { return nil }

        let deltas = [
            abs(target.origin.x - candidate.origin.x),
            abs(target.origin.y - candidate.origin.y),
            abs(target.size.width - candidate.size.width),
            abs(target.size.height - candidate.size.height)
        ]
        guard deltas.allSatisfy({
            $0.isFinite && $0 <= maximumGeometryDelta
        }) else { return nil }

        let widthReference = max(target.size.width, max(candidate.size.width, 1))
        let heightReference = max(target.size.height, max(candidate.size.height, 1))
        let originToleranceX = max(2, widthReference * 0.10)
        let originToleranceY = max(2, heightReference * 0.10)
        let sizeToleranceX = max(2, widthReference * 0.10)
        let sizeToleranceY = max(2, heightReference * 0.10)

        let components = [
            closeness(abs(target.origin.x - candidate.origin.x), tolerance: originToleranceX),
            closeness(abs(target.origin.y - candidate.origin.y), tolerance: originToleranceY),
            closeness(abs(target.size.width - candidate.size.width), tolerance: sizeToleranceX),
            closeness(abs(target.size.height - candidate.size.height), tolerance: sizeToleranceY)
        ]
        guard components.allSatisfy(\.isFinite) else { return nil }
        return Int((components.reduce(0, +) / CGFloat(components.count) * 60).rounded())
    }

    private static func closeness(_ delta: CGFloat, tolerance: CGFloat) -> CGFloat {
        guard delta.isFinite, tolerance.isFinite, tolerance > 0 else { return 0 }
        return max(0, min(1, 1 - delta / tolerance))
    }

}
