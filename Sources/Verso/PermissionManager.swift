import AppKit
import SwiftUI

#if SWIFT_PACKAGE
import VersoCore
#endif

/// Manages permission checking and requesting for Accessibility and Screen Recording.
///
/// Shared by AppDelegate, MenuBarController, and PermissionsView.
@MainActor
final class PermissionManager: ObservableObject {
    @Published var accessibilityState: PermissionState = .unknown
    @Published var screenRecordingState: PermissionState = .unknown
    /// Last tap creation/runtime error from the input monitor, if any.
    @Published var inputMonitorError: GlobalInputMonitor.TapError?
    /// Failure opening a user-facing Privacy pane, if any.
    @Published var systemSettingsError: String?
    var onRefresh: (() -> Void)?

    init() {
        refreshStates()
    }

    /// Check current permission states.
    func refreshStates() {
        accessibilityState = checkAccessibility()
        screenRecordingState = checkScreenRecording()
        onRefresh?()
    }

    /// Check if accessibility is granted.
    private func checkAccessibility() -> PermissionState {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue(): false] as CFDictionary
        let trusted = AXIsProcessTrustedWithOptions(options)
        return trusted ? .granted : .denied
    }

    /// Check screen recording permission using CGPreflightScreenCaptureAccess (macOS 10.15+).
    private func checkScreenRecording() -> PermissionState {
        if CGPreflightScreenCaptureAccess() {
            return .granted
        }
        return .denied
    }

    /// Request accessibility permission (opens System Settings).
    func requestAccessibility() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue(): true] as CFDictionary
        AXIsProcessTrustedWithOptions(options)
    }

    /// Request screen recording permission (opens System Settings).
    func requestScreenRecording() {
        CGRequestScreenCaptureAccess()
    }

    /// Open System Settings to a specific privacy pane after an explicit user
    /// action. The result is surfaced instead of silently dropping a failure.
    @discardableResult
    func openSystemSettings(anchor: String) -> Bool {
        guard let url = URL(
            string: "x-apple.systempreferences:com.apple.preference.security?\(anchor)"
        ) else {
            systemSettingsError = L("perm.settingsLinkUnavailable")
            return false
        }

        let opened = NSWorkspace.shared.open(url)
        systemSettingsError = opened
            ? nil
            : L("perm.settingsOpenFailed")
        return opened
    }

    /// Check if all required permissions are granted.
    /// Note: Screen Recording is NOT required for input monitoring.
    var allPermissionsGranted: Bool {
        accessibilityState.isGranted && screenRecordingState.isGranted
    }

    /// Get permission states for display.
    var permissionItems: [(PermissionCategory, PermissionState)] {
        [
            (.accessibility, accessibilityState),
            (.screenRecording, screenRecordingState)
        ]
    }
}
