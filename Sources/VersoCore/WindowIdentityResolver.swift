import Foundation

/// Confidence assigned to a window identity.
public enum IdentityConfidence: Int, Sendable, Codable, Comparable {
    case exact = 4
    case high = 3
    case medium = 2
    case sessionOnly = 1

    public static func < (
        lhs: IdentityConfidence,
        rhs: IdentityConfidence
    ) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}

/// Resolves a conservative, deterministic identity for an external window.
///
/// Only an unambiguous local document/folder path is eligible for persistent
/// restoration. URL parsing is performed once and standardization is lexical;
/// this type never reads the filesystem or resolves symlinks.
public struct WindowIdentityResolver: Sendable {
    public static let browserBundleIDs: Set<String> = [
        "com.apple.Safari",
        "com.google.Chrome",
        "com.google.Chrome.canary",
        "com.microsoft.edgemac",
        "company.thebrowser.Browser",
        "org.mozilla.firefox",
        "com.brave.Browser",
        "com.operasoftware.Opera",
        "com.vivaldi.Vivaldi",
        "com.apple.SafariTechnologyPreview"
    ]

    public static let finderBundleID = "com.apple.finder"

    public struct Identity: Sendable, Equatable {
        public let identityKey: String
        public let confidence: IdentityConfidence
        public let isBrowserSession: Bool
        /// The normalized local path used for an exact identity, if any.
        public let documentPath: String?

        public init(
            identityKey: String,
            confidence: IdentityConfidence,
            isBrowserSession: Bool = false,
            documentPath: String? = nil
        ) {
            self.identityKey = identityKey
            self.confidence = confidence
            self.isBrowserSession = isBrowserSession
            self.documentPath = documentPath
        }

        public static func sessionOnly(
            bundleIdentifier: String?,
            sessionID: UUID? = nil
        ) -> Identity {
            let bundle = bundleIdentifier ?? ""
            let token = sessionID?.uuidString ?? "unbound"
            return Identity(
                identityKey: WindowIdentityResolver.makeIdentityKey(
                    bundleIdentifier: bundle,
                    kind: "session",
                    value: token
                ),
                confidence: .sessionOnly
            )
        }

        public static func browserSession(
            bundleIdentifier: String,
            sessionID: UUID? = nil
        ) -> Identity {
            let token = sessionID?.uuidString ?? "unbound"
            return Identity(
                identityKey: WindowIdentityResolver.makeIdentityKey(
                    bundleIdentifier: bundleIdentifier,
                    kind: "browser-session",
                    value: token
                ),
                confidence: .sessionOnly,
                isBrowserSession: true
            )
        }
    }

    private enum PathEvidence {
        case absent
        case valid(String)
        case invalid
    }

    public init() {}

    /// Resolve metadata without making a filesystem or browser-tab guess.
    public func resolve(
        bundleIdentifier: String?,
        documentPath: String?,
        documentURL: String?,
        windowTitle: String?,
        sessionID: UUID? = nil
    ) -> Identity {
        let bundle = bundleIdentifier ?? ""

        if Self.isBrowser(bundleIdentifier) {
            return .browserSession(
                bundleIdentifier: bundle,
                sessionID: sessionID
            )
        }

        if !bundle.isEmpty,
           let path = resolveLocalPath(
               documentPath: documentPath,
               documentURL: documentURL
           ) {
            return Identity(
                identityKey: Self.makeIdentityKey(
                    bundleIdentifier: bundle,
                    kind: "path",
                    value: path
                ),
                confidence: .exact,
                documentPath: path
            )
        }

        if let title = normalizedTitle(windowTitle) {
            return Identity(
                identityKey: Self.makeIdentityKey(
                    bundleIdentifier: bundle,
                    kind: "title",
                    value: title
                ),
                confidence: .medium
            )
        }

        return .sessionOnly(
            bundleIdentifier: bundleIdentifier,
            sessionID: sessionID
        )
    }

    /// Identity keys are compared byte-for-byte; no case folding is applied.
    public static func keysMatch(_ lhs: String, _ rhs: String) -> Bool {
        lhs == rhs
    }

    /// Length-prefix each field so delimiters in a bundle, kind, or path can
    /// never create a second interpretation of the same key.
    public static func makeIdentityKey(
        bundleIdentifier: String,
        kind: String,
        value: String
    ) -> String {
        let fields = [bundleIdentifier, kind, value]
        let encoded = fields.map { field in
            "\(field.utf8.count):\(field)"
        }.joined(separator: "|")
        return "verso-v1|\(encoded)"
    }

    /// Lexically standardize a path without touching the filesystem.
    public static func lexicalStandardize(_ path: String) -> String {
        URL(fileURLWithPath: path, isDirectory: false).standardized.path
    }

    // MARK: - Paths

    private func resolveLocalPath(
        documentPath: String?,
        documentURL: String?
    ) -> String? {
        let pathEvidence = parsePath(documentPath)
        let urlEvidence = parsePath(documentURL)

        switch (pathEvidence, urlEvidence) {
        case (.absent, .absent):
            return nil
        case (.valid(let path), .absent), (.absent, .valid(let path)):
            return path
        case (.valid(let path), .valid(let other)):
            return path == other ? path : nil
        case (.invalid, _), (_, .invalid):
            // One malformed or nonlocal source makes the evidence unsafe.
            return nil
        }
    }

    private func parsePath(_ rawValue: String?) -> PathEvidence {
        guard let rawValue, !rawValue.isEmpty else { return .absent }
        guard !rawValue.contains("\0") else { return .invalid }

        if rawValue.hasPrefix("/") {
            // A double-leading slash is a host/network form, not an
            // unambiguous local POSIX path.
            guard !rawValue.hasPrefix("//") else { return .invalid }
            let url = URL(fileURLWithPath: rawValue, isDirectory: false)
            return standardizedLocalPath(from: url)
        }

        // Only URI-looking values are parsed as URLs. A literal percent in a
        // direct path remains literal rather than being decoded a second time.
        guard rawValue.lowercased().hasPrefix("file:") else {
            return .invalid
        }

        // Foundation may preserve an encoded NUL literally in `path`; reject
        // it before parsing so it cannot become a persistent identity.
        // Foundation's file-system representation preserves an encoded slash,
        // while a fully decoded URL path treats it as a separator. Reject that
        // ambiguous URI; an encoded literal percent (%252F) remains valid.
        guard !rawValue.lowercased().contains("%2f"),
              !containsEncodedNUL(rawValue),
              let url = URL(
                  string: rawValue,
                  encodingInvalidCharacters: false
              ) else {
            return .invalid
        }

        return standardizedLocalPath(from: url, parsedFileURL: true)
    }

    private func standardizedLocalPath(
        from url: URL,
        parsedFileURL: Bool = false
    ) -> PathEvidence {
        guard url.isFileURL,
              parsedFileURL ? url.scheme?.lowercased() == "file" : true,
              url.host == nil || url.host?.isEmpty == true
                  || url.host?.lowercased() == "localhost",
              url.user == nil,
              url.password == nil,
              url.port == nil,
              url.query == nil,
              url.fragment == nil else {
            return .invalid
        }

        let path = url.path
        guard !path.isEmpty,
              path.hasPrefix("/"),
              !path.hasPrefix("//"),
              !path.contains("\0") else {
            return .invalid
        }

        let standardized = URL(fileURLWithPath: path, isDirectory: false)
            .standardized.path
        guard !standardized.isEmpty,
              standardized.hasPrefix("/"),
              !standardized.hasPrefix("//"),
              !standardized.contains("\0") else {
            return .invalid
        }
        return .valid(standardized)
    }

    private func containsEncodedNUL(_ value: String) -> Bool {
        let bytes = Array(value.utf8)
        guard bytes.count >= 3 else { return false }
        for index in 0...(bytes.count - 3) {
            guard bytes[index] == 37 else { continue }
            let first = bytes[index + 1]
            let second = bytes[index + 2]
            if first == 48 && second == 48 {
                return true
            }
        }
        return false
    }

    // MARK: - Titles

    func normalizedTitle(_ title: String?) -> String? {
        guard let title else { return nil }
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        return trimmed
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }

    public static func isBrowser(_ bundleIdentifier: String?) -> Bool {
        guard let bundleIdentifier else { return false }
        return browserBundleIDs.contains(bundleIdentifier)
    }
}
