import SwiftUI
import AppKit

#if SWIFT_PACKAGE
import VersoCore
#endif

/// Entry point for the Verso menu-bar-only application.
/// LSUIElement hides the Dock icon; all UI is driven via the status-bar menu.
@main
struct VersoApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    init() {
        // Freeze before SwiftUI commands can read L("menu.settings").
        AppLocalization.freeze(
            preference: UserDefaults.standard.string(
                forKey: SettingsStore.languageDefaultsKey
            ),
            appleLanguages: Locale.preferredLanguages
        )
    }

    var body: some Scene {
        // The app remains menu-bar-only. The empty scene is not reachable from
        // the app menu because the Settings command below routes to the one
        // native window owned by MenuBarController.
        Settings {
            EmptyView()
        }
        .commands {
            TextEditingCommands()
            CommandGroup(replacing: .appSettings) {
                Button(L("menu.settings")) {
                    _ = appDelegate.showSettingsFromCommand()
                }
                .keyboardShortcut(",", modifiers: .command)
            }
        }
    }
}
