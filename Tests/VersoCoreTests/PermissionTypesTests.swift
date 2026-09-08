import Testing
@testable import VersoCore

@Test func onlyExplicitPermissionGrantsEnableAccess() {
    #expect(PermissionState.granted.isGranted)
    #expect(!PermissionState.denied.isGranted)
    #expect(!PermissionState.unknown.isGranted)
}

@Test func permissionLinksPointToTheCorrectPrivacyPanes() {
    #expect(PermissionCategory.accessibility.systemSettingsAnchor == "Privacy_Accessibility")
    #expect(PermissionCategory.screenRecording.systemSettingsAnchor == "Privacy_ScreenCapture")
}
