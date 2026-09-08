import Testing
@testable import VersoCore

@Test func invalidBuildMetadataUsesSafeFallback() {
    let metadata = AppMetadata(bundleIdentifier: "test.verso", name: "Test", version: "1", build: "invalid")
    #expect(metadata.buildNumber == 1)
}
