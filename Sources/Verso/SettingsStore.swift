import AppKit
import Foundation
import ServiceManagement
import SwiftUI

#if SWIFT_PACKAGE
import VersoCore
#endif

enum AppearancePreference: String, CaseIterable, Identifiable {
    case system
    case light
    case dark

    var id: String { rawValue }

    var title: String {
        switch self {
        case .system: return L("settings.system")
        case .light: return L("settings.light")
        case .dark: return L("settings.dark")
        }
    }

    var nativeAppearance: NSAppearance? {
        switch self {
        case .system: return nil
        case .light: return NSAppearance(named: .aqua)
        case .dark: return NSAppearance(named: .darkAqua)
        }
    }
}

enum LaunchAtLoginStatus: Equatable {
    case notRegistered
    case enabled
    case requiresApproval
    case notFound
    case unknown

    var isRegistered: Bool {
        switch self {
        case .enabled, .requiresApproval: return true
        case .notRegistered, .notFound, .unknown: return false
        }
    }

    var title: String {
        switch self {
        case .notRegistered: return L("settings.loginOff")
        case .enabled: return L("settings.loginOn")
        case .requiresApproval: return L("settings.loginApproval")
        case .notFound: return L("settings.loginUnavailable")
        case .unknown: return L("settings.loginUnknown")
        }
    }
}

/// The small ServiceManagement seam keeps deterministic tests away from the
/// real login-item registration APIs while production uses SMAppService.mainApp.
@MainActor
struct LaunchAtLoginService {
    let statusProvider: () -> LaunchAtLoginStatus
    let registerAction: () throws -> Void
    let unregisterAction: () async throws -> Void
    let openLoginItemsAction: () -> Void

    init(
        status: @escaping () -> LaunchAtLoginStatus,
        register: @escaping () throws -> Void,
        unregister: @escaping () async throws -> Void,
        openLoginItems: @escaping () -> Void = {}
    ) {
        self.statusProvider = status
        self.registerAction = register
        self.unregisterAction = unregister
        self.openLoginItemsAction = openLoginItems
    }

    static var live: LaunchAtLoginService {
        let service = SMAppService.mainApp
        return LaunchAtLoginService(
            status: {
                switch service.status {
                case .notRegistered: return .notRegistered
                case .enabled: return .enabled
                case .requiresApproval: return .requiresApproval
                case .notFound: return .notFound
                @unknown default: return .unknown
                }
            },
            register: {
                try service.register()
            },
            unregister: {
                try await service.unregister()
            },
            openLoginItems: {
                SMAppService.openSystemSettingsLoginItems()
            }
        )
    }
}

@MainActor
final class SettingsStore: ObservableObject {
    static let appearanceDefaultsKey = "appearancePreference"
    static let onboardingDefaultsKey = "hasCompletedOnboarding"
    static let languageDefaultsKey = "appLanguagePreference"
    static let loginDefaultAppliedKey = "hasInitializedLaunchAtLogin"

    @Published private(set) var appearance: AppearancePreference
    @Published private(set) var language: AppLanguagePreference
    @Published private(set) var hasCompletedOnboarding: Bool
    @Published private(set) var launchAtLoginStatus: LaunchAtLoginStatus = .unknown
    @Published private(set) var launchAtLoginError: String?
    @Published private(set) var isChangingLaunchAtLogin = false

    private let defaults: UserDefaults
    private let application: NSApplication?
    private let appearanceApplier: ((AppearancePreference) -> Void)?
    private let launchAtLoginService: LaunchAtLoginService
    private let hadExistingPreferences: Bool

    init(
        defaults: UserDefaults,
        application: NSApplication?,
        launchAtLoginService: LaunchAtLoginService,
        appearanceApplier: ((AppearancePreference) -> Void)? = nil
    ) {
        self.defaults = defaults
        self.application = application
        self.appearanceApplier = appearanceApplier
        self.launchAtLoginService = launchAtLoginService
        self.hadExistingPreferences = [
            Self.appearanceDefaultsKey, Self.onboardingDefaultsKey,
            Self.languageDefaultsKey
        ].contains { defaults.object(forKey: $0) != nil }
        self.appearance = AppearancePreference(
            rawValue: defaults.string(forKey: Self.appearanceDefaultsKey) ?? ""
        ) ?? .system
        self.language = AppLanguagePreference(
            rawValue: defaults.string(forKey: Self.languageDefaultsKey) ?? ""
        ) ?? .system
        self.hasCompletedOnboarding = defaults.bool(
            forKey: Self.onboardingDefaultsKey
        )
        refreshLaunchAtLoginStatus()
    }

    convenience init(defaults: UserDefaults = .standard) {
        self.init(
            defaults: defaults,
            application: NSApp,
            launchAtLoginService: .live
        )
    }

    var shouldShowOnboarding: Bool { !hasCompletedOnboarding }

    func setAppearance(_ preference: AppearancePreference) {
        guard appearance != preference else {
            applyAppearance()
            return
        }
        appearance = preference
        defaults.set(preference.rawValue, forKey: Self.appearanceDefaultsKey)
        applyAppearance()
    }

    /// Applies on next launch, including Apple's native editing commands.
    /// Both preferences belong to this app; System removes only its override.
    func setLanguage(_ preference: AppLanguagePreference) {
        guard language != preference else { return }
        language = preference
        defaults.set(preference.rawValue, forKey: Self.languageDefaultsKey)
        if preference == .system {
            defaults.removeObject(forKey: "AppleLanguages")
        } else {
            defaults.set([preference.rawValue], forKey: "AppleLanguages")
        }
    }

    func applyAppearance() {
        if let appearanceApplier {
            appearanceApplier(appearance)
        } else {
            application?.appearance = appearance.nativeAppearance
        }
    }

    func markOnboardingCompleted() {
        guard !hasCompletedOnboarding else { return }
        hasCompletedOnboarding = true
        defaults.set(true, forKey: Self.onboardingDefaultsKey)
    }

    func refreshLaunchAtLoginStatus() {
        launchAtLoginStatus = launchAtLoginService.statusProvider()
    }

    /// Apply the new-install default once; an existing service remains authoritative.
    func applyLaunchAtLoginDefaultIfNeeded() async {
        guard !defaults.bool(forKey: Self.loginDefaultAppliedKey) else { return }
        // ponytail: one marker prevents automatic retries after an error;
        // Settings provides the explicit retry and system approval path.
        defaults.set(true, forKey: Self.loginDefaultAppliedKey)
        refreshLaunchAtLoginStatus()
        guard !hadExistingPreferences, launchAtLoginStatus == .notRegistered else {
            return
        }
        _ = await setLaunchAtLoginAndWait(true)
    }

    /// The UI starts this only from a deliberate user toggle. The published
    /// status is refreshed after the real operation instead of being guessed.
    func requestLaunchAtLogin(_ enabled: Bool) {
        guard !isChangingLaunchAtLogin else { return }
        defaults.set(true, forKey: Self.loginDefaultAppliedKey)
        Task { @MainActor [weak self] in
            _ = await self?.setLaunchAtLoginAndWait(enabled)
        }
    }

    @discardableResult
    func setLaunchAtLoginAndWait(_ enabled: Bool) async -> Bool {
        guard !isChangingLaunchAtLogin else { return false }
        defaults.set(true, forKey: Self.loginDefaultAppliedKey)
        isChangingLaunchAtLogin = true
        launchAtLoginError = nil
        defer { isChangingLaunchAtLogin = false }

        do {
            if enabled {
                try launchAtLoginService.registerAction()
            } else {
                try await launchAtLoginService.unregisterAction()
            }
            refreshLaunchAtLoginStatus()
            return true
        } catch {
            refreshLaunchAtLoginStatus()
            launchAtLoginError = error.localizedDescription
            return false
        }
    }

    func openLoginItemsSettings() {
        launchAtLoginService.openLoginItemsAction()
    }
}
