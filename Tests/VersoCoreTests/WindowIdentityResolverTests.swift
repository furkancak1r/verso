import Foundation
import Testing
@testable import VersoCore

@Suite("WindowIdentityResolver")
struct WindowIdentityResolverTests {
    private let resolver = WindowIdentityResolver()

    @Test("An absolute path resolves exactly and standardizes only lexically")
    func exactPath() {
        let identity = resolver.resolve(
            bundleIdentifier: "com.example.editor",
            documentPath: "/tmp/Workspace/../Draft  .md",
            documentURL: nil,
            windowTitle: "Draft — Verso"
        )

        #expect(identity.confidence == .exact)
        #expect(identity.documentPath == "/tmp/Draft  .md")
        #expect(identity.identityKey.contains("Draft  .md"))
    }

    @Test("A file URL is decoded exactly once while a direct percent path stays literal")
    func percentEncoding() {
        let urlIdentity = resolver.resolve(
            bundleIdentifier: "com.example.editor",
            documentPath: nil,
            documentURL: "file:///tmp/100%25%20ready.md",
            windowTitle: nil
        )
        let pathIdentity = resolver.resolve(
            bundleIdentifier: "com.example.editor",
            documentPath: "/tmp/100%25%20ready.md",
            documentURL: nil,
            windowTitle: nil
        )

        #expect(urlIdentity.documentPath == "/tmp/100% ready.md")
        #expect(pathIdentity.documentPath == "/tmp/100%25%20ready.md")
        #expect(urlIdentity.identityKey != pathIdentity.identityKey)
    }

    @Test("Malformed, nonlocal, NUL, and conflicting path evidence degrades")
    func rejectsUnsafeEvidence() {
        let inputs: [(String?, String?)] = [
            ("file:///tmp/%ZZ", nil),
            ("file://other-host/tmp/draft.md", nil),
            ("file:////other-host/tmp/draft.md", nil),
            ("file:///tmp/draft.md?guess=1", nil),
            ("file:///tmp/draft%00.md", nil),
            ("/tmp/a.md", "/tmp/b.md"),
            ("/tmp/a.md", "https://example.invalid/a.md")
        ]

        for (path, url) in inputs {
            let identity = resolver.resolve(
                bundleIdentifier: "com.example.editor",
                documentPath: path,
                documentURL: url,
                windowTitle: "Untitled Draft"
            )
            #expect(identity.confidence == .medium)
            #expect(identity.documentPath == nil)
        }
    }

    @Test("Title normalization preserves case, diacritics, and numeric suffixes")
    func titleNormalization() {
        let first = resolver.resolve(
            bundleIdentifier: "com.example.editor",
            documentPath: nil,
            documentURL: nil,
            windowTitle: "  Café   Draft 2  "
        )
        let second = resolver.resolve(
            bundleIdentifier: "com.example.editor",
            documentPath: nil,
            documentURL: nil,
            windowTitle: "café Draft 2"
        )

        #expect(first.confidence == .medium)
        #expect(first.identityKey != second.identityKey)
    }

    @Test("Browser identity is session-only and changes with a session token", arguments: [
        "com.apple.Safari", "com.apple.SafariTechnologyPreview", "com.google.Chrome",
        "com.microsoft.edgemac", "company.thebrowser.Browser"
    ])
    func browserSessionIsolation(bundleIdentifier: String) {
        let first = UUID()
        let second = UUID()
        let one = resolver.resolve(
            bundleIdentifier: bundleIdentifier,
            documentPath: "/tmp/ignored.md",
            documentURL: nil,
            windowTitle: "Tab A",
            sessionID: first
        )
        let two = resolver.resolve(
            bundleIdentifier: bundleIdentifier,
            documentPath: "/tmp/ignored.md",
            documentURL: nil,
            windowTitle: "Tab B",
            sessionID: second
        )

        #expect(one.isBrowserSession)
        #expect(one.confidence == .sessionOnly)
        #expect(one.identityKey != two.identityKey)
    }

    @Test("Length-prefixed keys cannot collide through delimiters")
    func keyBoundaries() {
        let first = WindowIdentityResolver.makeIdentityKey(
            bundleIdentifier: "a|b",
            kind: "path",
            value: "c"
        )
        let second = WindowIdentityResolver.makeIdentityKey(
            bundleIdentifier: "a",
            kind: "b|path",
            value: "c"
        )

        #expect(first != second)
    }

    @Test("Local file URLs normalize decoded dot segments and localhost")
    func localURLNormalization() {
        for url in [
            "file:///tmp/Folder/%2E%2E/Note.txt",
            "file://localhost/tmp/Note.txt"
        ] {
            let identity = resolver.resolve(
                bundleIdentifier: "com.example.editor", documentPath: nil,
                documentURL: url, windowTitle: nil
            )
            #expect(identity.confidence == .exact)
            #expect(identity.documentPath == "/tmp/Note.txt")
        }
    }

    @Test("Ambiguous encoded separators do not alias literal percent filenames")
    func encodedSeparatorIsAmbiguous() {
        for url in ["file:///tmp/A%2FB.txt", "file:///tmp/A%2fB.txt"] {
            let identity = resolver.resolve(
                bundleIdentifier: "com.example.editor", documentPath: nil,
                documentURL: url, windowTitle: nil
            )
            #expect(identity.confidence == .sessionOnly)
            #expect(identity.documentPath == nil)
        }
        let literal = resolver.resolve(
            bundleIdentifier: "com.example.editor", documentPath: nil,
            documentURL: "file:///tmp/A%252FB.txt", windowTitle: nil
        )
        #expect(literal.confidence == .exact)
        #expect(literal.documentPath == "/tmp/A%2FB.txt")
    }
}
