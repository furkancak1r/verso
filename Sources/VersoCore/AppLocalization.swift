import Foundation

/// App language preference persisted in app-scoped defaults only.
///
/// `system` follows the macOS preferred-languages order; `tr`/`en` force a
/// language. Raw values are the persisted strings (`system`/`tr`/`en`).
public enum AppLanguagePreference: String, CaseIterable, Sendable {
    case system
    case tr
    case en

    /// Display title in the currently active language.
    public var title: String {
        switch self {
        case .system: return AppLocalization.string("settings.system")
        case .tr: return AppLocalization.string("lang.turkish")
        case .en: return AppLocalization.string("lang.english")
        }
    }
}

/// Minimal shared localization for the en/tr UI.
///
/// Resources are real `*.lproj/Localizable.strings` bundles resolved through
/// native `Bundle.localizedString`, so app-owned core `LocalizedError`
/// messages translate the same way as UI strings. Note text, window titles,
/// IDs, AX role constants and API error codes/domains are never passed
/// through here.
///
/// ponytail: native Bundle lookup instead of a manual dictionary cache.
/// SettingsStore persists an app-scoped AppleLanguages override for native
/// menus; System removes it. The active language is frozen at launch so
/// notes and editing history stay intact. Ceiling: no live or per-window
/// switching. Main-app resources win; Bundle.module is only evaluated
/// when the main bundle has no resources (the SwiftPM fallback).
public enum AppLocalization {
    public static let supportedCodes = ["en", "tr"]
    public static let fallbackCode = "en"

    private static let lock = NSLock()
    private static var frozenCode: String?

    private final class BundleAnchor: NSObject {}

    /// Pure resolution: explicit tr/en wins; otherwise the first supported
    /// macOS preferred language (region variants like tr-TR match); anything
    /// else, including an invalid preference, falls back to English.
    public static func resolve(
        preference rawValue: String?,
        appleLanguages: [String]?
    ) -> String {
        switch AppLanguagePreference(rawValue: rawValue ?? "") ?? .system {
        case .tr: return "tr"
        case .en: return "en"
        case .system: break
        }
        for tag in appleLanguages ?? [] {
            let base = tag.lowercased()
                .split(whereSeparator: { $0 == "-" || $0 == "_" })
                .first.map(String.init) ?? ""
            if supportedCodes.contains(base) { return base }
        }
        return fallbackCode
    }

    /// Freeze the display language for this process. Called once at launch;
    /// later preference edits only persist and take effect at next launch.
    public static func freeze(
        preference rawValue: String?,
        appleLanguages: [String]
    ) {
        let code = resolve(preference: rawValue, appleLanguages: appleLanguages)
        lock.lock()
        frozenCode = code
        lock.unlock()
    }

    /// Frozen code when set, otherwise a live System-style resolution.
    public static var activeCode: String {
        lock.lock()
        let frozen = frozenCode
        lock.unlock()
        if let frozen { return frozen }
        return resolve(preference: nil, appleLanguages: Locale.preferredLanguages)
    }

    /// Translated string for `key`, falling back to English, then the key.
    public static func string(_ key: String) -> String {
        let code = activeCode
        if let value = localized(key, code: code) { return value }
        if code != fallbackCode, let value = localized(key, code: fallbackCode) {
            return value
        }
        return key
    }

    public static func format(_ key: String, arguments: [CVarArg]) -> String {
        String(
            format: string(key),
            locale: Locale(identifier: activeCode),
            arguments: arguments
        )
    }

    /// Raw dictionary for `code`, loaded from the packaged strings file for
    /// inspection only (parity/resource tests). Never used for display.
    public static func stringsDictionary(for code: String) -> [String: String] {
        guard let url = resourceFileURL(for: code),
              let data = try? Data(contentsOf: url),
              let plist = try? PropertyListSerialization.propertyList(
                  from: data,
                  format: nil
              ) as? [String: String],
              !plist.isEmpty
        else { return [:] }
        return plist
    }

    /// Supported codes with a packaged dictionary (resource wiring check).
    public static func availableCodes() -> [String] {
        supportedCodes.filter { !stringsDictionary(for: $0).isEmpty }
    }

    private static let missingSentinel = "__VERSO_MISSING__"

    private static func localized(_ key: String, code: String) -> String? {
        guard let bundle = stringsBundle(for: code) else { return nil }
        let value = bundle.localizedString(
            forKey: key,
            value: missingSentinel,
            table: nil
        )
        return value == missingSentinel ? nil : value
    }

    /// Language-specific bundle for native lookup. Main-app resources win;
    /// SwiftPM `Bundle.module` is evaluated only when the main bundle has no
    /// matching resources, so a relocated app never touches it.
    private static func stringsBundle(for code: String) -> Bundle? {
        let main = Bundle.main
        if let bundle = lprojBundle(for: code, in: main) { return bundle }
        #if SWIFT_PACKAGE
        // Deferred: this line runs only when main-app resources are absent.
        if let bundle = lprojBundle(for: code, in: Bundle.module) { return bundle }
        #endif
        let core = Bundle(for: BundleAnchor.self)
        if core != main, let bundle = lprojBundle(for: code, in: core) {
            return bundle
        }
        return nil
    }

    /// Packaged strings file for inspection. Same deferred order as display.
    private static func resourceFileURL(for code: String) -> URL? {
        let main = Bundle.main
        if let url = stringsFileURL(for: code, in: main) { return url }
        #if SWIFT_PACKAGE
        // Deferred: evaluated only when main-app resources are absent.
        if let url = stringsFileURL(for: code, in: Bundle.module) { return url }
        #endif
        let core = Bundle(for: BundleAnchor.self)
        if core != main, let url = stringsFileURL(for: code, in: core) {
            return url
        }
        return nil
    }

    private static func lprojBundle(for code: String, in container: Bundle) -> Bundle? {
        guard let path = container.path(
            forResource: "Localizable",
            ofType: "strings",
            inDirectory: "\(code).lproj"
        ) else { return nil }
        let lprojURL = URL(fileURLWithPath: path).deletingLastPathComponent()
        return Bundle(url: lprojURL)
    }

    private static func stringsFileURL(for code: String, in container: Bundle) -> URL? {
        if let path = container.path(
            forResource: "Localizable",
            ofType: "strings",
            inDirectory: "\(code).lproj"
        ) {
            return URL(fileURLWithPath: path)
        }
        return nil
    }

    static func resetForTesting() {
        lock.lock()
        frozenCode = nil
        lock.unlock()
    }
}

/// Pre-localized lookup: `L("menu.settings")`, `L("quit.detail", detail)`.
/// Never pass user note text, window titles, IDs, or AX constants here.
public func L(_ key: String, _ args: CVarArg...) -> String {
    guard !args.isEmpty else { return AppLocalization.string(key) }
    return AppLocalization.format(key, arguments: args)
}
