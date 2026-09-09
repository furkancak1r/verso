# Verso

Verso is a native macOS 14+ menu-bar scratchpad for supported application windows. Option (⌥) + left-click an eligible title-bar area to reveal its note. Escape or Back returns to the original window.

Version 1.1.3 provides the running app’s version and selectable path in Permissions. Use Open Settings and the permission list’s + button to add the app; Show Verso in Finder is a separate convenience. Finder selection alone does not verify successful permission registration. Version 1.1.2 window controls and deterministic checks are implemented. Final installed window-control interaction checks remain pending; the installed build 9 now reports both macOS grants, as recorded in the [compatibility record](docs/COMPATIBILITY.md). Earlier 1.1.1 desktop passes do not validate the new controls.

## Install Verso 1.1.3

Run `./scripts/release.sh` with the toolchain described below to generate `build/releases/1.1.3/Verso-1.1.3-universal.dmg`. Open the DMG and drag **Verso.app** onto **Applications**. Eject the disk image, then open `/Applications/Verso.app`. The same release directory contains a ZIP and `SHA256SUMS`. Generated packages are excluded from Git. The app supports Apple Silicon and Intel and targets macOS 14 or later.

This free build is ad-hoc signed and is not notarized by Apple. If macOS blocks the first launch, use **System Settings → Privacy & Security → Open Anyway**. Gatekeeper stays enabled. After an update, you may need to grant Verso's permissions again; ad-hoc signing does not guarantee that macOS retains them.

Türkçe: **Verso.app'i Applications (Uygulamalar) klasörüne sürükleyin.** İlk açılış engellenirse **Sistem Ayarları → Gizlilik ve Güvenlik → Yine de Aç** yolunu izleyin.

## Language / Dil

Settings offers **System / Türkçe / English**. System is the default: Verso follows the first supported macOS language preference and falls back to English when none matches. A manual choice is saved for the next launch. Changing language leaves open notes and their editing history intact; quit and reopen Verso when ready. App-owned menus, utility windows, errors and accessibility labels use the same bundled `.strings` resources. Note text, target-window titles and paths are never translated. Apple's standard editing commands use native localization.

**Ayarlar → Dil** bölümünde **Sistem / Türkçe / English** seçenekleri bulunur. Tercih kaydedilir ve Verso yeniden açıldığında uygulanır. Sistem dillerinde Türkçe veya İngilizce yoksa İngilizce kullanılır.

## Run from the project

For development, run `./scripts/build.sh` and open `build/Verso.app`; this builds for the host architecture. The versioned release above contains both architectures. Permissions takes priority when Accessibility is missing; the first-use guide remains available afterward. Verso has a menu-bar icon and no Dock icon.

1. Verso automatically opens Permissions at launch or when explicitly reopened if Accessibility access is missing. Grant it so Verso can identify and follow supported windows. Missing optional Screen Recording access alone does not open this window. macOS keeps the user in control of the grant.
2. Option-click a supported external title bar, then type in the native note editor. Controls, content, sheets and ambiguous hits are rejected.
3. Use Escape, Back or a completed Option-click on the note header to return. Native selection, clipboard, undo/redo, Unicode and Cmd+F are available in the editor.

Screen Recording is optional. With access, ScreenCaptureKit supplies temporary window and cropped background images; Core Animation rotates the complete window face, including its title bar, corners and shadow. Returning captures a fresh target image. Without a usable capture, or with Reduce Motion enabled, Verso switches directly to the native note editor.

Click the pin icon to add the current note to **Pinned Notes**; click again to remove it. A filled pin shows the saved state. A short message confirms success for two seconds; a save failure keeps the prior state and displays an error for five seconds. Tooltips and accessibility feedback explain the action in the selected language. The message does not move the editor or take keyboard focus.

The menu opens Search, Recent, Pinned and Archived notes. Saved notes remain accessible after their target window or application closes. The library supports opening, pinning/unpinning, archiving/restoring and confirmed deletion; Show Window requires a currently validated live target. Exact document paths can reconnect an unambiguous saved note. Browser tab titles and uncertain identities deliberately create separate notes instead of risking a wrong attachment.

Settings and Cmd+, open the same window. Appearance offers System, Light and Dark. Launch at Login uses `SMAppService.mainApp`: a fresh preferences profile registers once at first launch; existing profiles keep their service state. Later opt-out and system approval requirements are respected, and failed default registration is not retried automatically. Settings always shows actual service status. Building or packaging never registers a login item.

Version 1.1.2 adds note-header dragging and edge resizing synchronized through the original window's Accessibility API. Yellow minimizes the source while retaining the same editor; green invokes source fullscreen, with Option-green for zoom (zoom-only targets use zoom directly). Red saves the note and returns to the source. Fullscreen visibility is scoped to the source window using public window-server metadata. Unsupported controls are disabled and failures use the existing localized feedback row. These new interactions still require final installed desktop acceptance; no real login/reboot pass is claimed.

## Storage and privacy

Notes autosave after approximately 400 ms and save before explicit dismissal, target changes, metadata actions and quit. A failed save retains the draft, exposes retry and prevents an explicit handoff or quit from silently losing edits.

The local SwiftData store is at `~/Library/Application Support/Verso/WindowNotes.store`, with normal database sidecar files. It contains note text and minimal window/document identity metadata. Appearance, language and first-use preferences use app-scoped UserDefaults. There is no CloudKit, network client, telemetry or screenshot history.

Target and cropped background pixels exist only in memory during the flip. The native note surface also uses a temporary in-memory image while rotating. Image references are cleared when the note becomes visible, after return, and on cancellation or cleanup. The app never writes captures, thumbnails or capture logs to disk. The resource probe generates synthetic pixels only and also writes no images.

## Build and verify

Requires full Xcode with Swift 6.3+; verified with Xcode 26.6 / Swift 6.3.3 on macOS 26.6.2. Runtime deployment targets macOS 14.0; macOS 14 hardware execution remains unverified.

```bash
./scripts/build.sh
./scripts/test.sh
./scripts/check-resources.sh
```

The normal build script creates an ad-hoc signed `build/Verso.app` for the host architecture. Tests cover production identity, persistence, input, geometry, capture, animation, observation and native UI behavior; the latest verified suite has 301 tests in 16 suites. The resource command compiles the production image owner, checks 60 synthetic 4K cleanup cycles, and writes numeric results to `.build/resource-probe/result.json`.

The optional desktop runner is separate from those unit tests:

```bash
./scripts/check-desktop.sh --self-check  # Compile and check event encoding, geometry, arg parsing and result logic.
./scripts/check-desktop.sh --run         # Explicitly drive the running build/Verso.app with synthetic windows.
./scripts/check-desktop.sh --run --app-path /path/to/Verso.app  # Drive an installed copy; default is build/Verso.app.
```

Without an argument, this script only compiles the runner. The desktop run needs an unlocked session, the test process's Accessibility/event access, and Verso's own required permission. It refuses an existing note editor or an unexpected target/focus. It checks Option-click, native typing/undo/redo/find, Escape, reopening the same live window, movement/resize and target-close cleanup. It leaves uniquely named `SmokeTarget-…` synthetic notes; it never reads the clipboard, deletes notes, changes permissions/login settings or writes images. This native target does not replace the named-app matrix or a disk/reboot persistence test. Verso 1.1.1 installed at `/Applications/Verso.app` passed all 20 desktop stages in both Turkish and English, including pin/unpin feedback, message expiry, persisted pin state on reopen, Unicode, Undo/Redo, Find, Escape/refocus, movement/resize and cleanup. The real Settings control was used to switch to English and relaunch, then restore System and relaunch. Native whole-window visual checks from phase 13 remain recorded separately; the compatibility record distinguishes them from the named-app/hardware matrix.

Open `Verso.xcodeproj` for Xcode development. To reproduce the universal Release build:

```bash
xcodebuild -project Verso.xcodeproj -scheme Verso \
  -configuration Release -sdk macosx -destination 'generic/platform=macOS' \
  -derivedDataPath .build/UniversalRelease \
  ARCHS='arm64 x86_64' ONLY_ACTIVE_ARCH=NO CODE_SIGN_IDENTITY=- build
```

The Xcode bundle is at `.build/UniversalRelease/Build/Products/Release/Verso.app`. No third-party dependencies are required. If compiling inside an existing automation sandbox, the scripts support the explicit `VERSO_BUILD_IN_SANDBOX=1` flag for SwiftData macros; ordinary builds do not need it. The toolchain can be selected with `DEVELOPER_DIR`.

The one-command universal release is separate from the host-architecture build:

```bash
./scripts/release.sh  # xcodebuild arm64+x86_64, staged verify, publish build/releases/1.1.3/
```

It builds Xcode for `arm64`/`x86_64`, verifies bundle identity `com.verso.app`, version 1.1.3 (build 9), both architectures, English/Turkish resources and the strict ad-hoc signature in a unique staging directory. It then creates a UDZO/HFS+ DMG containing the app, an Applications symlink and a bilingual installation guide, plus ZIP and SHA-256 checksums. Only a completely validated release is published. Previous releases are preserved; a failed build does not replace them. The script does not modify the running app, `/Applications`, preferences or notes.

The previous 1.1.1 app passed a 20-stage interaction run in both languages. Version 1.1.2 has expanded direct-pointer and window-control smoke checks, but those checks have not yet completed on the installed app. Installed build 9 now reports both Accessibility and Screen Recording granted. Do not treat historical runs as acceptance for the newer window controls. See the compatibility record for current build, package and permission evidence.

The free package can be shared with the first-launch instructions above. Apple-recognized Developer ID signing and notarization require the owner's Apple Developer Program membership; see [Apple's Developer ID documentation](https://developer.apple.com/developer-id/). No signing credentials or login-item registration were configured by the build.

## Source layout

- `Sources/VersoCore`: identity, persistence, autosave, coordinates, input and flip state/animation.
- `Sources/Verso`: native app/editor/library/settings, Accessibility, capture, observation and overlay integration.
- `Tests/VersoCoreTests`: deterministic production behavior and synthetic native checks.
- `scripts`: build, tests and the isolated resource measurement.
- `docs`: observed compatibility results, performance evidence and remaining desktop protocols.

The application icon is bundled as `Resources/AppIcon.icns` in both build paths; the editable 1024px source is `Resources/AppIcon.png`. The ICNS contains standard and Retina sizes from 16px through 1024px. Release verification checks the bundle reference, exact icon bytes and native icon decoding.
