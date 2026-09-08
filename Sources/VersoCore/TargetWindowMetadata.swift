import CoreGraphics

/// Metadata about a resolved external application window from AX queries.
///
/// Coordinates are Quartz/AX top-left: origin at top-left of primary display,
/// Y increases downward. `frame.origin.y` is the top edge of the window.
public struct TargetWindowMetadata: Sendable, Equatable {
    public let pid: pid_t
    public let bundleIdentifier: String?
    public let appName: String
    public let windowTitle: String?
    public let windowRole: String?
    public let windowSubrole: String?
    public let documentPath: String?
    public let documentURL: String?
    public let frame: CGRect
    public let isMinimized: Bool
    public let isOnScreen: Bool

    public init(
        pid: pid_t,
        bundleIdentifier: String?,
        appName: String,
        windowTitle: String?,
        windowRole: String?,
        windowSubrole: String?,
        documentPath: String?,
        documentURL: String?,
        frame: CGRect,
        isMinimized: Bool = false,
        isOnScreen: Bool = true
    ) {
        self.pid = pid
        self.bundleIdentifier = bundleIdentifier
        self.appName = appName
        self.windowTitle = windowTitle
        self.windowRole = windowRole
        self.windowSubrole = windowSubrole
        self.documentPath = documentPath
        self.documentURL = documentURL
        self.frame = frame
        self.isMinimized = isMinimized
        self.isOnScreen = isOnScreen
    }

    // MARK: - Eligibility

    /// The standard AX role for application windows.
    public static let windowRole = "AXWindow"
    /// The standard AX subrole for regular application windows.
    public static let standardWindowSubrole = "AXStandardWindow"

    /// Whether this target represents an eligible title-bar interaction target.
    ///
    /// Requires: AXWindow + AXStandardWindow, nonempty bundle ID, valid PID,
    /// finite positive frame, non-minimized, on-screen.
    /// Self-identification (rejecting own app) and modal/sheet checks are done
    /// by the AX service in phase 2b/2c; this pure metadata does not reference
    /// Bundle.main.
    public var isEligible: Bool {
        // Must be a standard application window.
        guard windowRole == Self.windowRole,
              windowSubrole == Self.standardWindowSubrole else { return false }
        // Need a nonempty bundle identifier.
        guard let bid = bundleIdentifier,
              !bid.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return false }
        // Need a valid PID (positive).
        guard pid > 0 else { return false }
        // Frame must be finite with positive area.
        guard Self.isValidFrame(frame) else { return false }
        // Reject minimized or off-screen windows.
        guard !isMinimized, isOnScreen else { return false }
        return true
    }

    /// Whether a CGRect has finite origins/size and positive area.
    ///
    /// Uses raw `size.width`/`size.height` because `width`/`height` getters
    /// standardize negative sizes to absolute values on Apple platforms.
    /// Checks `maxX`/`maxY` to catch overflow from large-but-finite components.
    public static func isValidFrame(_ f: CGRect) -> Bool {
        guard f.size.width >= 1, f.size.height >= 1 else { return false }
        guard f.origin.x.isFinite, f.origin.y.isFinite else { return false }
        guard f.maxX.isFinite, f.maxY.isFinite else { return false }
        return true
    }

    /// Display title for UI purposes.
    public var displayTitle: String {
        let title = windowTitle ?? ""
        return title.isEmpty ? appName : title
    }
}
