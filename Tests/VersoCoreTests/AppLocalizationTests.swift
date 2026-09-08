import AppKit
import Foundation
import Testing
@testable import Verso
@testable import VersoCore

@MainActor
@Suite("App Localization", .serialized)
struct AppLocalizationTests {
    private func temporaryDefaults() throws -> (String, UserDefaults) {
        let name = "VersoLocalizationTests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: name))
        return (name, defaults)
    }

    private func service(
        status: @escaping () -> LaunchAtLoginStatus = { .notRegistered }
    ) -> LaunchAtLoginService {
        LaunchAtLoginService(
            status: status,
            register: {},
            unregister: {},
            openLoginItems: {}
        )
    }

    private func placeholders(in value: String) -> [String] {
        let pattern = "%(?:\\d+\\$)?[#0+\\- ]?(?:\\d+)?(?:\\.\\d+)?[a-zA-Z@]"
        let regex = try! NSRegularExpression(pattern: pattern)
        let range = NSRange(value.startIndex..., in: value)
        return regex.matches(in: value, range: range).compactMap {
            Range($0.range, in: value).map { String(value[$0]) }
        }
    }

    // MARK: - Resolution

    @Test("Explicit preference wins over system languages")
    func explicitPreferenceWins() {
        #expect(AppLocalization.resolve(preference: "tr", appleLanguages: ["en"]) == "tr")
        #expect(AppLocalization.resolve(preference: "en", appleLanguages: ["tr"]) == "en")
    }

    @Test("System follows macOS order with region variants")
    func systemFollowsPreferredLanguages() {
        #expect(AppLocalization.resolve(preference: "system", appleLanguages: ["tr-TR"]) == "tr")
        #expect(AppLocalization.resolve(preference: "system", appleLanguages: ["en-US"]) == "en")
        #expect(AppLocalization.resolve(preference: "system", appleLanguages: ["en_GB"]) == "en")
        #expect(AppLocalization.resolve(preference: "system", appleLanguages: ["fr-FR", "tr"]) == "tr")
        #expect(AppLocalization.resolve(preference: "system", appleLanguages: ["fr", "de"]) == "en")
        #expect(AppLocalization.resolve(preference: "system", appleLanguages: []) == "en")
        #expect(AppLocalization.resolve(preference: "system", appleLanguages: nil) == "en")
        #expect(AppLocalization.resolve(preference: nil, appleLanguages: ["tr"]) == "tr")
    }

    @Test("Invalid preference falls back to system behavior")
    func invalidPreferenceFallsBack() {
        #expect(AppLocalization.resolve(preference: "xx", appleLanguages: ["tr"]) == "tr")
        #expect(AppLocalization.resolve(preference: "xx", appleLanguages: ["de"]) == "en")
        #expect(AppLocalization.resolve(preference: "", appleLanguages: nil) == "en")
    }

    // MARK: - Freeze

    @Test("Frozen language sticks until next launch")
    func frozenLanguageSticks() {
        AppLocalization.resetForTesting()
        defer { AppLocalization.resetForTesting() }
        AppLocalization.freeze(preference: "tr", appleLanguages: ["en"])
        #expect(AppLocalization.activeCode == "tr")
        #expect(L("menu.settings") == "Ayarlar…")
        // A later preference change must not alter the frozen process language.
        AppLocalization.freeze(preference: "system", appleLanguages: ["en"])
        #expect(AppLocalization.activeCode == "en")
    }

    @Test("Switching preference never changes the live display language")
    func preferenceSwitchKeepsLiveDisplay() throws {
        AppLocalization.resetForTesting()
        defer { AppLocalization.resetForTesting() }
        AppLocalization.freeze(preference: "en", appleLanguages: ["en"])
        let (name, defaults) = try temporaryDefaults()
        defer { defaults.removePersistentDomain(forName: name) }
        let store = SettingsStore(
            defaults: defaults,
            application: nil,
            launchAtLoginService: service()
        )
        store.setLanguage(.tr)
        #expect(store.language == .tr)
        #expect(AppLocalization.activeCode == "en")
        #expect(L("menu.settings") == "Settings…")
    }

    // MARK: - Persistence (app-scoped only)

    @Test("Language persists in app-scoped defaults, defaulting to System")
    func languagePersistenceRoundTrip() throws {
        let (name, defaults) = try temporaryDefaults()
        defer { defaults.removePersistentDomain(forName: name) }
        var store = SettingsStore(
            defaults: defaults,
            application: nil,
            launchAtLoginService: service()
        )
        #expect(store.language == .system)
        store.setLanguage(.tr)
        #expect(defaults.string(forKey: SettingsStore.languageDefaultsKey) == "tr")
        store = SettingsStore(
            defaults: defaults,
            application: nil,
            launchAtLoginService: service()
        )
        #expect(store.language == .tr)
        // Invalid stored values heal to System.
        defaults.set("xx", forKey: SettingsStore.languageDefaultsKey)
        store = SettingsStore(
            defaults: defaults,
            application: nil,
            launchAtLoginService: service()
        )
        #expect(store.language == .system)
    }

    @Test("Language switch scopes Apple language override to the app")
    func languageSwitchIsAppScoped() throws {
        let (name, defaults) = try temporaryDefaults()
        defer { defaults.removePersistentDomain(forName: name) }
        defaults.set("dark", forKey: SettingsStore.appearanceDefaultsKey)
        let store = SettingsStore(
            defaults: defaults,
            application: nil,
            launchAtLoginService: service()
        )
        let before = defaults.dictionaryRepresentation()
        store.setLanguage(.en)
        #expect(defaults.persistentDomain(forName: name)?["AppleLanguages"] as? [String] == ["en"])
        store.setLanguage(.tr)
        #expect(defaults.persistentDomain(forName: name)?["AppleLanguages"] as? [String] == ["tr"])
        store.setLanguage(.system)
        #expect(defaults.string(forKey: SettingsStore.appearanceDefaultsKey) == "dark")
        #expect(defaults.string(forKey: SettingsStore.languageDefaultsKey) == "system")
        // Suite reads fall through to the global domain, so inspect only
        // what this suite persisted: our writes must never add the key.
        #expect(defaults.persistentDomain(forName: name)?["AppleLanguages"] == nil)
        let changed = Set(defaults.dictionaryRepresentation().keys)
            .symmetricDifference(Set(before.keys))
        #expect(changed == [SettingsStore.languageDefaultsKey])
    }

    // MARK: - Resources and parity

    @Test("Both languages ship packaged resources")
    func packagedResourcesAvailable() {
        AppLocalization.resetForTesting()
        defer { AppLocalization.resetForTesting() }
        #expect(AppLocalization.availableCodes() == ["en", "tr"])
    }

    @Test("Translation keys and format placeholders match exactly")
    func keyAndFormatParity() {
        AppLocalization.resetForTesting()
        defer { AppLocalization.resetForTesting() }
        let en = AppLocalization.stringsDictionary(for: "en")
        let tr = AppLocalization.stringsDictionary(for: "tr")
        #expect(!en.isEmpty)
        #expect(Set(en.keys) == Set(tr.keys))
        for key in en.keys {
            #expect(
                placeholders(in: en[key]!) == placeholders(in: tr[key]!),
                "placeholder mismatch for \(key)"
            )
        }
    }

    @Test("Turkish strings are meaningful translations")
    func turkishStringsAreMeaningful() {
        AppLocalization.resetForTesting()
        defer { AppLocalization.resetForTesting() }
        AppLocalization.freeze(preference: "tr", appleLanguages: ["tr"])
        #expect(L("menu.settings") == "Ayarlar…")
        #expect(L("menu.quit") == "Verso'dan Çık")
        #expect(L("library.empty") == "Henüz not yok.")
        #expect(L("settings.languageRestart").contains("yeniden başlat"))
        #expect(L("perm.refresh") == "Durumu Yenile")
        #expect(L("error.storeNotOpen").contains("deposu"))
        let combined = AppLocalization.stringsDictionary(for: "tr").values.joined()
        #expect(combined.contains("ğ") || combined.contains("ş"))
        #expect(combined.contains("ı") || combined.contains("İ"))
        #expect(combined.contains("ç"))
        // Brand and user-data placeholders survive translation.
        #expect(L("quit.detail", "boom").contains("boom"))
        #expect(L("quit.detail", "boom").contains("Verso"))
        #expect(L("overlay.versoNote").contains("Verso"))
    }

    @Test("Core store errors translate with the active language")
    func coreErrorsTranslate() {
        AppLocalization.resetForTesting()
        defer { AppLocalization.resetForTesting() }
        AppLocalization.freeze(preference: "en", appleLanguages: ["en"])
        #expect(NoteRepository.RepositoryError.storeNotOpen.errorDescription ==
            "Verso's note store is not available.")
        AppLocalization.freeze(preference: "tr", appleLanguages: ["tr"])
        #expect(NoteRepository.RepositoryError.storeNotOpen.errorDescription ==
            "Verso not deposu kullanılamıyor.")
    }

    @Test("Permission categories translate with the active language")
    func permissionCategoriesTranslate() {
        AppLocalization.resetForTesting()
        defer { AppLocalization.resetForTesting() }
        AppLocalization.freeze(preference: "tr", appleLanguages: ["tr"])
        #expect(PermissionCategory.accessibility.displayName == "Erişilebilirlik")
        #expect(PermissionCategory.screenRecording.displayName == "Ekran Kaydı")
        AppLocalization.freeze(preference: "en", appleLanguages: ["en"])
        #expect(PermissionCategory.accessibility.displayName == "Accessibility")
    }
}
