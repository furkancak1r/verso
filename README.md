# Verso

**English** · [Türkçe](README.tr.md)

Verso is a native macOS menu-bar app that puts notes behind your application windows. **Option (⌥) + left-click an empty, supported title-bar area** to open a note; press **Escape** or **Back** to return to the application.

**Current version:** 1.2.3 (build 17) · **Deployment target:** macOS 14+ · **Universal package:** Apple Silicon and Intel

## Features

- **Notes per application:** windows belonging to the same application share note tabs. Different applications keep separate notebooks.
- **Native editing:** text selection, clipboard, Unicode, Find, and separate Undo/Redo histories for each tab while the note overlay stays open.
- **A note library:** search, recent notes, pinned notes, and an archive. Saved notes remain available after their application closes.
- **Local storage:** autosave, recovery after save failures, and no saved blank or whitespace-only notes.
- **Personalization:** Turkish and English, System/Light/Dark appearance, and a Launch at Login setting.

Version 1.2.3 freezes the note at its current size before preparing the closing flip and disables extra AppKit window animations. Tab close buttons sit inside their tabs and show hover/pressed feedback. Final visual verification of the closing change is still pending; see [Verification and known limits](#verification-and-known-limits).

## Installation

Release packages are generated locally and excluded from Git. Follow [Build from source](#build-from-source) to create `build/releases/1.2.3/Verso-1.2.3-universal.dmg`.

1. Open the DMG and drag **Verso.app** onto **Applications**.
2. Eject the disk image, then open `/Applications/Verso.app`. Verso runs in the menu bar without a Dock icon.
3. If macOS blocks the first launch, use **System Settings → Privacy & Security → Open Anyway**.
4. Grant **Accessibility** access when Verso opens its Permissions window. **Screen Recording** is optional and enables the flip preview.

The free package uses a persistent, self-signed certificate. It is **not Apple-notarized or signed with Developer ID**. You do not need to import a certificate to use the app. Gatekeeper stays enabled. The initial switch from an older ad-hoc build may require another permission grant; a same-certificate update preserved both permissions on the tested Mac, but this is not a guarantee for every system or future update. See the [compatibility record](docs/COMPATIBILITY.md) and [Apple’s Developer ID documentation](https://developer.apple.com/developer-id/).

If Permissions needs help locating the app, use **Open Settings**, then the permission list’s **+** button and select the installed `Verso.app`. **Show Verso in Finder** reveals the exact running copy; Finder selection alone does not grant permission. Setup instructions disappear when both permissions are granted. Missing Accessibility opens Permissions at launch or explicit reopen; missing optional Screen Recording alone does not.

## Usage

| Action | Control |
| --- | --- |
| Open a note | Option-click an empty, supported title bar |
| Return to the application | Escape, Back, the red window button, or Option-click the note header |
| Add a note tab | **+** or **⌘T** |
| Switch tabs | **Control+Tab** / **Control+Shift+Tab** |
| Close a tab | **×** or **⌘W** |
| Find text / open Settings | **⌘F** / **⌘,** |

Closing a nonempty tab moves it to **Archive**. Closing a blank tab discards it; closing the last tab leaves a new blank tab. Tabs follow creation order. Reordering and Undo/Redo history across overlay or app restarts are not supported.

Click the pin button to add a note to **Pinned Notes**, and click again to unpin it. A filled icon shows the saved state. Success feedback lasts two seconds; a failed save preserves the previous state and shows an error for five seconds without moving the editor or taking its focus.

The menu-bar library supports opening, pinning, archiving/restoring, and confirmed deletion. **Show Window** requires a currently validated live target. Blank notes cannot be newly pinned or archived. Clearing a saved note removes it from the library; Undo/Redo in the open editor restores/removes the same note. Existing stored notes are not bulk-cleaned.

With Screen Recording access, the flip uses temporary images of the target window and a cropped background, including a fresh target image on return. Without a usable capture, or with Reduce Motion enabled, the transition is immediate. Clicks on controls, content, sheets, or ambiguous title-bar areas are rejected.

Dragging and resizing the note, minimizing the source window, and fullscreen/zoom controls are implemented through public macOS APIs. Unsupported controls are disabled. **These controls have not completed desktop acceptance; a note-header dragging failure remains open.**

## Language and settings

In **Settings → Language**, choose **System / Türkçe / English**. System is the default: Verso uses the first supported macOS language preference, or English if none matches. A manual choice is saved and applied on the next launch. Changing language does not recreate open notes; quit and reopen when ready. Note text, application-window titles, and file paths are not translated.

Appearance supports **System / Light / Dark**. On a fresh preferences profile, Launch at Login attempts registration once using `SMAppService.mainApp`. Existing profiles keep their current service state. Later opt-out and system approval requirements are respected; a failed initial registration is not retried automatically. Settings reports the actual service status. Building or packaging does not register a login item.

## Storage and privacy

Notes autosave after approximately **400 ms** and save before explicit dismissal, pin/archive actions, target changes, or quit. Save failures retain the draft and prevent explicit handoff or quit from silently losing edits.

The local SwiftData store is `~/Library/Application Support/Verso/WindowNotes.store`, with normal database sidecar files. It contains note text and minimal window/document identity metadata. Preferences use app-scoped UserDefaults.

The app has no CloudKit integration, network client, telemetry, or screenshot history. Window, cropped-background, and note-preview images exist only in memory during a flip and are released during completion or cleanup. The app does not write captures or thumbnails to disk.

## Build from source

Use full **Xcode with Swift 6.3+**. The recorded environment is Xcode 26.6 / Swift 6.3.3 on macOS 26.6.2. The deployment target is macOS 14.0; actual macOS 14 and Intel hardware runs remain unverified. No third-party application dependencies are required. Open `Verso.xcodeproj` for Xcode development.

### Signing prerequisite

Build scripts and Xcode use the public certificate fingerprint in [`Resources/Signing.xcconfig`](Resources/Signing.xcconfig). The matching code-signing certificate **and private key** must be available in the builder’s Keychain. A missing or incorrect identity stops packaging before an existing app or release is replaced; there is no ad-hoc fallback.

For an independent fork, create your own Code Signing identity once with Keychain Access’s Certificate Assistant and explicitly replace the public fingerprint. Keep the same identity for subsequent versions. Private keys are never bundled, committed, or exported automatically; moving the original identity to another builder requires an owner-controlled Keychain backup. Losing the identity may require new permissions. Build commands do not create certificates, change trust, or register login items.

### Commands

```bash
./scripts/build.sh
./scripts/test.sh
./scripts/test-signing.sh
./scripts/check-resources.sh
./scripts/release.sh
```

`build.sh` stages, signs, and verifies **`build/Verso.app` for the host architecture**, preserving the previous app. `release.sh` builds and verifies **arm64 + x86_64**, bundled English/Turkish resources, version, and the pinned signature before publishing:

```text
build/releases/1.2.3/
├── Verso.app
├── Verso-1.2.3-universal.dmg
├── Verso-1.2.3-universal.zip
└── SHA256SUMS
```

The DMG includes an Applications shortcut and bilingual instructions. Release packaging preserves previous packages and does not modify `/Applications`, the running app, preferences, or notes. The resource probe runs 60 synthetic 4K cleanup cycles and writes numeric results to `.build/resource-probe/result.json`.

To reproduce the universal Xcode build directly:

```bash
xcodebuild -project Verso.xcodeproj -scheme Verso \
  -configuration Release -sdk macosx -destination 'generic/platform=macOS' \
  -derivedDataPath .build/UniversalRelease \
  ARCHS='arm64 x86_64' ONLY_ACTIVE_ARCH=NO build
```

The app is at `.build/UniversalRelease/Build/Products/Release/Verso.app`. Select a toolchain with `DEVELOPER_DIR`. The explicit `VERSO_BUILD_IN_SANDBOX=1` flag supports SwiftData macros inside an existing automation sandbox; ordinary builds do not need it.

## Verification and known limits

The latest recorded suite passes **322 tests in 16 suites**. Version 1.2.3 universal/host builds, pinned signatures, and DMG/ZIP checksums passed. Its final installed desktop attempt stopped at the lock screen before input, so the closing animation’s visual acceptance remains pending. Earlier successful tab checks do not validate the separate window-control issue. Real login/reboot, Intel/macOS 14 hardware, and the full named-application matrix remain unverified. Details are in [`docs/COMPATIBILITY.md`](docs/COMPATIBILITY.md); resource measurements are in [`docs/PERFORMANCE.md`](docs/PERFORMANCE.md).

The optional desktop runner is separate from unit tests:

```bash
./scripts/check-desktop.sh --self-check
./scripts/check-desktop.sh --run
./scripts/check-desktop.sh --run --app-path /Applications/Verso.app
```

Without arguments, it only compiles. `--run` requires an unlocked session and the appropriate Verso/test-process permissions; it rejects an existing note editor or unexpected target/focus. It uses generated windows and leaves uniquely named `SmokeTarget-…` test notes. It does not read the clipboard, delete notes, change permissions/login settings, or write images.

Set `VERSO_SMOKE_TABS_ONLY=1` to run tab creation, separate Undo/Redo, same-app sharing, and close/blank-discard checks instead of window-control stages. Set `VERSO_SMOKE_REQUIRE_CAPTURE=1` to additionally require observation of the capture-only expanded animation canvas. That observation reads window metadata, not pixels. These checks do not replace the real-app or reboot matrix.

## Source layout

- `Sources/VersoCore`: identity, persistence, autosave, coordinates, input, and flip state/animation.
- `Sources/Verso`: native UI, editor, library, settings, Accessibility, capture, and window integration.
- `Tests/VersoCoreTests`: production behavior and synthetic native checks.
- `scripts`: build, tests, release packaging, and resource measurements.
- `docs`: compatibility, performance evidence, and remaining test protocols.

The application icon is bundled as `Resources/AppIcon.icns`; its editable 1024-pixel source is `Resources/AppIcon.png`.
