import AppKit
import Testing
@testable import Verso

@MainActor
@Suite("Settings")
struct SettingsTests {
    private func temporaryDefaults() throws -> (String, UserDefaults) {
        let name = "VersoSettingsTests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: name))
        return (name, defaults)
    }

    private func service(
        status: @escaping () -> LaunchAtLoginStatus,
        register: @escaping () throws -> Void = {},
        unregister: @escaping () async throws -> Void = {},
        openLoginItems: @escaping () -> Void = {}
    ) -> LaunchAtLoginService {
        LaunchAtLoginService(
            status: status,
            register: register,
            unregister: unregister,
            openLoginItems: openLoginItems
        )
    }

    @Test("Appearance and onboarding use an isolated defaults suite")
    func appearanceAndOnboardingRoundTrip() throws {
        let (name, defaults) = try temporaryDefaults()
        defer { defaults.removePersistentDomain(forName: name) }

        defaults.set("future-theme", forKey: SettingsStore.appearanceDefaultsKey)
        var applied: [AppearancePreference] = []
        let service = service(status: { .notRegistered })
        let store = SettingsStore(
            defaults: defaults,
            application: nil,
            launchAtLoginService: service,
            appearanceApplier: { applied.append($0) }
        )

        #expect(store.appearance == .system)
        #expect(!store.hasCompletedOnboarding)

        store.setAppearance(.dark)
        store.markOnboardingCompleted()
        #expect(store.appearance == .dark)
        #expect(store.hasCompletedOnboarding)
        #expect(applied == [.dark])
        #expect(defaults.object(forKey: "launchAtLogin") == nil)

        let reloaded = SettingsStore(
            defaults: defaults,
            application: nil,
            launchAtLoginService: service,
            appearanceApplier: { _ in }
        )
        #expect(reloaded.appearance == .dark)
        #expect(reloaded.hasCompletedOnboarding)
    }

    @Test("Launch-at-login controls follow service status and real outcomes")
    func launchAtLoginStatusAndFailures() async throws {
        let (name, defaults) = try temporaryDefaults()
        defer { defaults.removePersistentDomain(forName: name) }

        var status: LaunchAtLoginStatus = .notRegistered
        var registerCount = 0
        var unregisterCount = 0
        var openSettingsCount = 0
        var registerError: Error?
        let service = service(
            status: { status },
            register: {
                registerCount += 1
                if let registerError { throw registerError }
                status = .enabled
            },
            unregister: {
                unregisterCount += 1
                status = .notRegistered
            },
            openLoginItems: { openSettingsCount += 1 }
        )
        let store = SettingsStore(
            defaults: defaults,
            application: nil,
            launchAtLoginService: service
        )

        #expect(store.launchAtLoginStatus == .notRegistered)
        #expect(await store.setLaunchAtLoginAndWait(true))
        #expect(registerCount == 1)
        #expect(store.launchAtLoginStatus == .enabled)
        #expect(store.hasCompletedOnboarding == false)

        #expect(await store.setLaunchAtLoginAndWait(false))
        #expect(unregisterCount == 1)
        #expect(store.launchAtLoginStatus == .notRegistered)

        registerError = NSError(
            domain: "VersoSettingsTests",
            code: 7,
            userInfo: [NSLocalizedDescriptionKey: "Synthetic registration failure"]
        )
        #expect(!(await store.setLaunchAtLoginAndWait(true)))
        #expect(store.launchAtLoginStatus == .notRegistered)
        #expect(store.launchAtLoginError == "Synthetic registration failure")

        status = .requiresApproval
        store.refreshLaunchAtLoginStatus()
        #expect(store.launchAtLoginStatus == .requiresApproval)
        #expect(store.launchAtLoginStatus.isRegistered)
        store.openLoginItemsSettings()
        #expect(openSettingsCount == 1)
    }

    @Test("Appearance choices map to System, Light and Dark native appearances")
    func appearanceMapping() {
        #expect(AppearancePreference.system.nativeAppearance == nil)
        #expect(AppearancePreference.light.nativeAppearance != nil)
        #expect(AppearancePreference.dark.nativeAppearance != nil)
        #expect(AppearancePreference.allCases.map(\.rawValue) == [
            "system", "light", "dark"
        ])
    }

    @Test("A fresh install registers once and preserves a later opt-out")
    func freshLoginDefaultAndOptOut() async throws {
        let (name, defaults) = try temporaryDefaults()
        defer { defaults.removePersistentDomain(forName: name) }
        var status: LaunchAtLoginStatus = .notRegistered
        var registrations = 0
        let backend = service(status: { status }, register: {
            registrations += 1
            status = .enabled
        }, unregister: { status = .notRegistered })
        let store = SettingsStore(defaults: defaults, application: nil,
                                  launchAtLoginService: backend)
        #expect(registrations == 0)
        await store.applyLaunchAtLoginDefaultIfNeeded()
        #expect(registrations == 1)
        #expect(store.launchAtLoginStatus == .enabled)
        await store.applyLaunchAtLoginDefaultIfNeeded()
        #expect(registrations == 1)
        #expect(await store.setLaunchAtLoginAndWait(false))
        let reloaded = SettingsStore(defaults: defaults, application: nil,
                                     launchAtLoginService: backend)
        await reloaded.applyLaunchAtLoginDefaultIfNeeded()
        #expect(registrations == 1)
        #expect(reloaded.launchAtLoginStatus == .notRegistered)
    }

    @Test("An existing profile never changes its login registration on upgrade")
    func existingLoginProfileIsPreserved() async throws {
        for key in [SettingsStore.onboardingDefaultsKey,
                    SettingsStore.appearanceDefaultsKey, SettingsStore.languageDefaultsKey] {
            let (name, defaults) = try temporaryDefaults()
            defer { defaults.removePersistentDomain(forName: name) }
            defaults.set(false, forKey: key)
            var registrations = 0
            let store = SettingsStore(defaults: defaults, application: nil,
                launchAtLoginService: service(status: { .notRegistered }, register: {
                    registrations += 1
                }))
            await store.applyLaunchAtLoginDefaultIfNeeded()
            #expect(registrations == 0)
            #expect(store.launchAtLoginStatus == .notRegistered)
            #expect(defaults.bool(forKey: SettingsStore.loginDefaultAppliedKey))
        }
    }

    @Test("Existing service state and revoked consent are never overwritten")
    func existingLoginServiceIsPreserved() async throws {
        for status in [LaunchAtLoginStatus.enabled, .requiresApproval, .notFound, .unknown] {
            let (name, defaults) = try temporaryDefaults()
            defer { defaults.removePersistentDomain(forName: name) }
            var registrations = 0
            let store = SettingsStore(defaults: defaults, application: nil,
                launchAtLoginService: service(status: { status }, register: {
                    registrations += 1
                }))
            await store.applyLaunchAtLoginDefaultIfNeeded()
            #expect(registrations == 0)
            #expect(store.launchAtLoginStatus == status)
        }
    }

    @Test("Default registration reports pending approval or failure without retry loops")
    func loginDefaultFailureAndApproval() async throws {
        for fails in [false, true] {
            let (name, defaults) = try temporaryDefaults()
            defer { defaults.removePersistentDomain(forName: name) }
            var status: LaunchAtLoginStatus = .notRegistered
            var registrations = 0
            let backend = service(status: { status }, register: {
                registrations += 1
                if fails {
                    throw NSError(domain: "VersoSettingsTests", code: 9,
                        userInfo: [NSLocalizedDescriptionKey: "Synthetic default failure"])
                }
                status = .requiresApproval
            })
            let store = SettingsStore(defaults: defaults, application: nil,
                                      launchAtLoginService: backend)
            await store.applyLaunchAtLoginDefaultIfNeeded()
            #expect(registrations == 1)
            #expect(store.launchAtLoginStatus == (fails ? .notRegistered : .requiresApproval))
            #expect(store.launchAtLoginError == (fails ? "Synthetic default failure" : nil))
            let reloaded = SettingsStore(defaults: defaults, application: nil,
                                         launchAtLoginService: backend)
            await reloaded.applyLaunchAtLoginDefaultIfNeeded()
            #expect(registrations == 1)
        }
    }

    @Test("A manual opt-out before startup wins over the fresh-install default")
    func manualLoginChoicePrecedesStartup() async throws {
        let (name, defaults) = try temporaryDefaults()
        defer { defaults.removePersistentDomain(forName: name) }
        var registrations = 0
        let store = SettingsStore(defaults: defaults, application: nil,
            launchAtLoginService: service(status: { .notRegistered }, register: {
                registrations += 1
            }))
        #expect(await store.setLaunchAtLoginAndWait(false))
        await store.applyLaunchAtLoginDefaultIfNeeded()
        #expect(registrations == 0)
    }

    @Test("Failed login removal retains service state and permits a successful retry")
    func loginRemovalFailureAndRetry() async throws {
        let (name, defaults) = try temporaryDefaults()
        defer { defaults.removePersistentDomain(forName: name) }
        var status: LaunchAtLoginStatus = .enabled
        var shouldFail = true
        let store = SettingsStore(
            defaults: defaults,
            application: nil,
            launchAtLoginService: service(
                status: { status },
                unregister: {
                    if shouldFail {
                        throw NSError(domain: "VersoSettingsTests", code: 8)
                    }
                    status = .notRegistered
                }
            )
        )
        #expect(!(await store.setLaunchAtLoginAndWait(false)))
        #expect(store.launchAtLoginStatus == .enabled)
        #expect(store.launchAtLoginError != nil)
        #expect(!store.isChangingLaunchAtLogin)
        shouldFail = false
        #expect(await store.setLaunchAtLoginAndWait(false))
        #expect(store.launchAtLoginStatus == .notRegistered)
        #expect(store.launchAtLoginError == nil)
        for unavailable in [LaunchAtLoginStatus.notFound, .unknown] {
            status = unavailable
            store.refreshLaunchAtLoginStatus()
            #expect(!store.launchAtLoginStatus.isRegistered)
        }
    }
}
