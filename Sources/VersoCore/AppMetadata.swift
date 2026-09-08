import Foundation

/// Minimal app metadata for identification and display.
public struct AppMetadata: Sendable {
    public let bundleIdentifier: String
    public let name: String
    public let version: String
    public let build: String

    public init(
        bundleIdentifier: String,
        name: String,
        version: String,
        build: String
    ) {
        self.bundleIdentifier = bundleIdentifier
        self.name = name
        self.version = version
        self.build = build
    }

    /// Create from the running application's main bundle.
    public static func fromMainBundle() -> AppMetadata {
        let bundle = Bundle.main
        return AppMetadata(
            bundleIdentifier: bundle.bundleIdentifier ?? "com.verso.app",
            name: bundle.infoDictionary?["CFBundleName"] as? String ?? "Verso",
            version: bundle.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0.0",
            build: bundle.infoDictionary?["CFBundleVersion"] as? String ?? "1"
        )
    }

    /// Build number as integer for comparisons.
    public var buildNumber: Int {
        Int(build) ?? 1
    }
}

extension AppMetadata: Equatable {}
extension AppMetadata: Hashable {}
