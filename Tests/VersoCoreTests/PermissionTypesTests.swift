import AppKit
import Testing
@testable import Verso
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

private func permissionFixtureBundle(at url: URL, identifier: String) throws -> Bundle {
    let contents = url.appendingPathComponent("Contents")
    try FileManager.default.createDirectory(at: contents, withIntermediateDirectories: true)
    let info = ["CFBundleIdentifier": identifier, "CFBundlePackageType": "APPL"]
    try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
        .write(to: contents.appendingPathComponent("Info.plist"))
    return try #require(Bundle(url: url))
}

@MainActor
@Test func finderRevealsExactBundleWithoutChangingPermissionStatus() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let old = try permissionFixtureBundle(at: root.appendingPathComponent("old/Verso.app"), identifier: "com.verso.app")
    let current = try permissionFixtureBundle(at: root.appendingPathComponent("current/Verso.app"), identifier: "com.verso.app")
    let manager = PermissionManager()
    manager.accessibilityState = .denied
    manager.screenRecordingState = .denied
    manager.systemSettingsError = "Previous failure"
    var selected: [URL] = []

    #expect(manager.revealApplicationInFinder(bundle: current, select: { selected = $0 }))
    #expect(selected == [current.bundleURL])
    #expect(!selected.contains(old.bundleURL))
    #expect(manager.systemSettingsError == nil)
    #expect(!manager.accessibilityState.isGranted)
    #expect(!manager.screenRecordingState.isGranted)
}

@MainActor
@Test func finderRejectsUnrelatedOrUnbundledApplications() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let unrelated = try permissionFixtureBundle(at: root.appendingPathComponent("Verso.app"), identifier: "test.unrelated")
    let unbundled = try permissionFixtureBundle(at: root.appendingPathComponent("Verso.bundle"), identifier: "com.verso.app")
    let manager = PermissionManager()
    var reveals = 0
    for bundle in [unrelated, unbundled] {
        #expect(!manager.revealApplicationInFinder(bundle: bundle, select: { _ in reveals += 1 }))
        #expect(manager.systemSettingsError != nil)
    }
    #expect(reveals == 0)
}

@MainActor
@Test func startupPermissionsTakePriorityAndReuseTheWindow() throws {
    _ = NSApplication.shared
    let name = "VersoStartupTests-\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: name))
    let settings = SettingsStore(
        defaults: defaults, application: nil,
        launchAtLoginService: LaunchAtLoginService(
            status: { .notRegistered }, register: {}, unregister: {}, openLoginItems: {}
        )
    )
    let manager = PermissionManager()
    let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    var canPresent = true
    let controller = MenuBarController(
        statusItem: statusItem, permissionManager: manager,
        noteSessionController: NoteSessionController(repository: NoteRepository()),
        retryStoreHandler: {}, retrySaveHandler: { true }, refreshHandler: {},
        showLibraryHandler: { _ in }, settingsStore: settings,
        prepareUtilityHandler: { canPresent }
    )
    defer {
        controller.permissionsWindow?.close()
        controller.onboardingWindow?.close()
        NSStatusBar.system.removeStatusItem(statusItem)
        defaults.removePersistentDomain(forName: name)
    }

    manager.accessibilityState = .denied
    manager.screenRecordingState = .denied
    canPresent = false
    controller.showStartupWindow()
    #expect(controller.permissionsWindow == nil)
    #expect(settings.shouldShowOnboarding)

    canPresent = true
    controller.showStartupWindow()
    let permissions = try #require(controller.permissionsWindow)
    #expect(permissions.isVisible)
    #expect(controller.onboardingWindow == nil)
    #expect(settings.shouldShowOnboarding)

    permissions.close()
    manager.accessibilityState = .unknown
    controller.showStartupWindow()
    #expect(controller.permissionsWindow === permissions)
    #expect(permissions.isVisible)
    #expect(controller.onboardingWindow == nil)
    permissions.close()

    // Optional capture access alone never opens Permissions.
    manager.accessibilityState = .granted
    controller.showStartupWindow()
    #expect(!permissions.isVisible)
    #expect(controller.onboardingWindow?.isVisible == true)
    #expect(!settings.shouldShowOnboarding)
    controller.onboardingWindow?.close()
    controller.showStartupWindow()
    #expect(!permissions.isVisible)
    #expect(controller.onboardingWindow?.isVisible == false)
}
