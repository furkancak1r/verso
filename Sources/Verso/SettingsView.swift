import SwiftUI

#if SWIFT_PACKAGE
import VersoCore
#endif

/// The single settings view used by the native utility window and its app
/// menu command.
struct SettingsView: View {
    @ObservedObject var manager: PermissionManager
    @ObservedObject var store: SettingsStore
    private let onOpenPermissions: (() -> Void)?

    init(
        manager: PermissionManager,
        store: SettingsStore? = nil,
        onOpenPermissions: (() -> Void)? = nil
    ) {
        self.manager = manager
        self.store = store ?? SettingsStore()
        self.onOpenPermissions = onOpenPermissions
    }

    var body: some View {
        Form {
            Section(L("settings.appearance")) {
                Picker(
                    L("settings.theme"),
                    selection: Binding(
                        get: { store.appearance },
                        set: { store.setAppearance($0) }
                    )
                ) {
                    ForEach(AppearancePreference.allCases) { preference in
                        Text(preference.title).tag(preference)
                    }
                }
                .pickerStyle(.segmented)
                .accessibilityLabel(L("settings.appearance"))
            }

            Section(L("settings.launchLogin")) {
                Toggle(
                    L("settings.openAtLogin"),
                    isOn: Binding(
                        get: { store.launchAtLoginStatus.isRegistered },
                        set: { store.requestLaunchAtLogin($0) }
                    )
                )
                .disabled(store.isChangingLaunchAtLogin)

                HStack(spacing: 8) {
                    Image(systemName: loginStatusSymbol)
                        .foregroundStyle(loginStatusColor)
                    Text(store.launchAtLoginStatus.title)
                        .foregroundStyle(.secondary)
                }
                .font(.caption)

                if store.launchAtLoginStatus == .requiresApproval {
                    Text(L("settings.approvalNote"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Button(L("settings.openLoginItems")) {
                        store.openLoginItemsSettings()
                    }
                } else if store.launchAtLoginStatus == .notFound
                            || store.launchAtLoginStatus == .unknown {
                    Button(L("settings.openLoginItems")) {
                        store.openLoginItemsSettings()
                    }
                }

                if let error = store.launchAtLoginError {
                    Label(error, systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(.red)
                }
            }

            Section(L("window.permissions")) {
                permissionStatus(
                    title: L("permcat.accessibility"),
                    state: manager.accessibilityState
                )
                permissionStatus(
                    title: L("settings.screenRow"),
                    state: manager.screenRecordingState
                )

                if let onOpenPermissions {
                    Button(L("settings.openPermissions"), action: onOpenPermissions)
                }
            }

            Section(L("settings.language")) {
                Picker(
                    L("settings.language"),
                    selection: Binding(
                        get: { store.language },
                        set: { store.setLanguage($0) }
                    )
                ) {
                    ForEach(AppLanguagePreference.allCases, id: \.self) { preference in
                        Text(preference.title).tag(preference)
                    }
                }
                .pickerStyle(.segmented)
                Text(L("settings.languageRestart"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section(L("settings.about")) {
                HStack {
                    Text(L("settings.version"))
                    Spacer()
                    Text(AppMetadata.fromMainBundle().version)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .formStyle(.grouped)
        .onAppear {
            manager.refreshStates()
            store.refreshLaunchAtLoginStatus()
        }
        .padding(12)
        .frame(minWidth: 460, idealWidth: 520, minHeight: 430)
    }

    private var loginStatusSymbol: String {
        switch store.launchAtLoginStatus {
        case .enabled:
            return "checkmark.circle.fill"
        case .requiresApproval:
            return "exclamationmark.circle.fill"
        case .notRegistered:
            return "circle"
        case .notFound, .unknown:
            return "questionmark.circle.fill"
        }
    }

    private var loginStatusColor: Color {
        switch store.launchAtLoginStatus {
        case .enabled:
            return .green
        case .requiresApproval:
            return .orange
        case .notRegistered:
            return .secondary
        case .notFound, .unknown:
            return .red
        }
    }

    private func permissionStatus(
        title: String,
        state: PermissionState
    ) -> some View {
        HStack {
            Text(title)
            Spacer()
            if state.isGranted {
                Label(L("settings.granted"), systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
            } else {
                Label(L("settings.needsAction"), systemImage: "exclamationmark.circle.fill")
                    .foregroundStyle(.orange)
            }
        }
    }
}
