import SwiftUI

#if SWIFT_PACKAGE
import VersoCore
#endif

/// Displays Accessibility and Screen Recording permission states with explicit
/// request actions.
///
/// Also surfaces tap creation/runtime errors from the input monitor.
/// Screen Recording is shown but NOT required for input monitoring.
struct PermissionsView: View {
    @ObservedObject var manager: PermissionManager
    private let appMetadata = AppMetadata.fromMainBundle()

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text(L("window.permissions"))
                .font(.title2)
                .fontWeight(.semibold)

            Text(L("perm.intro"))
                .font(.subheadline)
                .foregroundStyle(.secondary)

            VStack(alignment: .leading, spacing: 12) {
                permissionRow(category: .accessibility, state: manager.accessibilityState)
                permissionRow(category: .screenRecording, state: manager.screenRecordingState)
            }

            VStack(alignment: .leading, spacing: 8) {
                Text(L("perm.runningVersion", appMetadata.version, appMetadata.build))
                    .font(.subheadline.weight(.semibold))
                Text(Bundle.main.bundleURL.path)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                Text(L("perm.addHelp"))
                    .font(.caption)
                    .fixedSize(horizontal: false, vertical: true)
                if !manager.allPermissionsGranted {
                    Text(L("perm.staleHelp"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Button(L("perm.showInFinder")) {
                    manager.revealApplicationInFinder()
                }
                .accessibilityIdentifier("permissions.showInFinder")
            }

            if let error = manager.inputMonitorError {
                HStack(spacing: 8) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                    Text(errorDescription(error))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .padding(10)
                .background(Color.orange.opacity(0.1))
                .cornerRadius(8)
            }

            if let error = manager.systemSettingsError {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.red)
            }

            HStack {
                Spacer()
                Button(L("perm.refresh")) {
                    manager.refreshStates()
                }
            }

            Spacer()
        }
        .padding(20)
        .frame(minWidth: 460, idealWidth: 560, minHeight: 560)
    }

    private func errorDescription(_ error: GlobalInputMonitor.TapError) -> String {
        switch error {
        case .creationFailed:
            return L("perm.tapCreation")
        case .runtimeFailed:
            return L("perm.tapRuntime")
        }
    }

    private func permissionRow(category: PermissionCategory, state: PermissionState) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 12) {
                Image(systemName: state.isGranted ? "checkmark.circle.fill" : "xmark.circle.fill")
                    .foregroundStyle(state.isGranted ? .green : .red)
                    .font(.title3)
                    .accessibilityLabel(L(state.isGranted ? "perm.allowed" : "perm.notAllowed"))

                VStack(alignment: .leading, spacing: 2) {
                    Text(category.displayName)
                        .font(.body)
                        .fontWeight(.medium)
                    Text(description(for: category))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            HStack {
                if !state.isGranted {
                    Button(L("perm.requestAccess")) {
                        switch category {
                        case .accessibility:
                            manager.requestAccessibility()
                        case .screenRecording:
                            manager.requestScreenRecording()
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                }
                Button(L("perm.openSettings")) {
                    manager.openSystemSettings(
                        anchor: category.systemSettingsAnchor
                    )
                }
                .controlSize(.small)
                .accessibilityIdentifier("permissions.setup.\(category.rawValue)")
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(Color.primary.opacity(0.05))
        .cornerRadius(8)
    }

    private func description(for category: PermissionCategory) -> String {
        switch category {
        case .accessibility:
            return L("perm.accessibilityDesc")
        case .screenRecording:
            return L("perm.screenDesc")
        }
    }
}
