import Foundation

/// Permission categories Verso needs to function.
public enum PermissionCategory: String, CaseIterable, Sendable {
    case accessibility
    case screenRecording

    public var displayName: String {
        switch self {
        case .accessibility: return L("permcat.accessibility")
        case .screenRecording: return L("permcat.screen")
        }
    }

    public var description: String {
        switch self {
        case .accessibility:
            return L("permcat.accessibilityDesc")
        case .screenRecording:
            return L("permcat.screenDesc")
        }
    }

    public var systemSettingsAnchor: String {
        switch self {
        case .accessibility: return "Privacy_Accessibility"
        case .screenRecording: return "Privacy_ScreenCapture"
        }
    }
}

/// Current state of a single permission.
public enum PermissionState: Sendable {
    case unknown
    case granted
    case denied

    public var isGranted: Bool {
        if case .granted = self { return true }
        return false
    }
}
