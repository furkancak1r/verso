Build a production-quality native macOS app called "Verso".

GOAL

Verso gives each macOS application window a hidden note surface.

When the user holds Option (⌥) and left-clicks an eligible app window's title bar, that window should visually flip around its vertical Y axis. The front looks like the real app window, the back is a native scratchpad associated with that specific logical window/document.

Examples:
- Safari Window A -> Note A
- Safari Window B -> Note B
- Finder Downloads -> its own note
- VS Code Project A -> its own note
- Preview document -> its own note

Notes must persist after closing windows/apps, quitting Verso and rebooting the Mac. When the same logical document/window returns, reconnect its saved note when identity confidence is sufficient.

MACOS ONLY

Use:
- Swift
- SwiftUI + AppKit
- Accessibility API / AXUIElement / AXObserver
- CGEventTap if appropriate
- ScreenCaptureKit
- Core Animation / CATransform3D
- SwiftData
- ServiceManagement
- async/await

Target macOS 14+.

Use only public macOS APIs.

Do NOT use Electron, Tauri, Flutter, React Native, private APIs, code injection, undocumented CGS APIs, cloud services, analytics or telemetry.

CORE INTERACTION

Global trigger:

Option + Left Click on the title bar of an external application window.

Do not trigger on normal app content, buttons, text fields, webpages, menus, Dock, desktop, popovers, sheets, menu bar, tooltips or transient system UI.

Only consume the click if Verso successfully recognizes a supported title-bar interaction. Otherwise leave normal macOS behavior untouched.

Use Accessibility APIs to resolve:
- owning application
- PID
- bundle identifier
- app name/icon
- AXWindow
- title
- AXDocument / AXURL when available
- role/subrole
- position/size

Create a conservative TitleBarHitTester using AX hierarchy first and geometry heuristics only as fallback.

WINDOW IDENTITY

Create WindowIdentityResolver.

Never persist identity using PID alone.

Preferred identity:
1. bundle ID + document URL/path
2. bundle ID + AXDocument
3. bundle ID + stable project/folder path
4. bundle ID + stable window metadata/title
5. conservative normalized title
6. session-only UUID fallback

Use confidence levels such as exact/high/medium/sessionOnly.

Prefer creating a new note over attaching the wrong existing note.

Different windows of the same application must not automatically share notes.

For Finder/document editors prefer folder/document path.

For VS Code/Xcode prefer project/workspace/document information when publicly available.

Browsers such as Safari, Chrome, Edge and Arc should be best-effort. Do not assume changing tabs are persistent window identities. Avoid incorrect note restoration.

FLIP IMPLEMENTATION

macOS cannot publicly transform another app's NSWindow, so simulate it.

Create a borderless temporary overlay exactly covering the target window.

Before flipping:
1. identify AXWindow
2. resolve corresponding ScreenCaptureKit SCWindow
3. capture ONE snapshot
4. display snapshot in overlay
5. animate overlay in 3D

Create WindowCaptureResolver that matches AXWindow to SCWindow using public data:
- PID
- app identity
- title
- frame
- size/position

Use confidence scoring and reject unsafe matches.

Prefer one-shot ScreenCaptureKit/SCScreenshotManager capture. Do not continuously record or maintain SCStream while idle.

3D ANIMATION

Use CATransform3D with perspective, starting around:

m34 = -1.0 / 1000.0

Front:
0° -> 90°

Around 90° switch to note surface.

Back:
90° -> 180°

Correct orientation so note text is never mirrored.

Duration around 0.35-0.5 sec with smooth easeInEaseOut behavior.

Use subtle perspective/shadow/scale only. No flashy animation.

FLIP BACK

Escape, Back button or the appropriate Option-click should reverse the flip.

Do NOT retain the old screenshot while the user writes.

Before reverse animation, capture a NEW snapshot of the target window so changed content is current.

Then:
note -> 90° -> fresh snapshot -> 0°

After completion remove overlay and restore interaction to the real app.

SCREENSHOT PRIVACY AND MEMORY

CRITICAL:

Captured external-window images are ephemeral.

NEVER save screenshots to:
- disk
- temp files
- SwiftData
- UserDefaults
- Application Support
- cache
- logs

Never maintain screenshot history or thumbnails.

Front-to-note lifecycle:

capture
-> animate
-> note becomes visible
-> immediately remove screenshot layer
-> CALayer.contents = nil
-> clear NSImage/CGImage/pixel/sample-buffer references
-> release capture objects

There should normally be ZERO target screenshots retained while noteVisible.

Reverse lifecycle:

capture fresh snapshot
-> reverse animation
-> immediately clear all image/layer/capture references again

Avoid redundant image conversions/copies.

Do not keep large Retina bitmaps alive through closures.

Use scoped ownership/autoreleasepool where useful.

Create TemporaryCaptureResource or equivalent with safe idempotent cleanup.

Cleanup must execute on:
- animation completion
- cancellation
- window close
- app termination
- target change
- permission failure
- capture error
- Verso termination

Use Instruments to verify memory returns near baseline and screenshots do not accumulate.

NOTE UI

Back side should be a minimal native macOS scratchpad.

Prefer NSTextView/AppKit integration for native editing behavior.

Toolbar:
- app icon
- app/window/document title
- Verso
- Pin
- Archive
- Back

Editor supports:
- multiline text
- Unicode/emojis
- links
- scrolling
- selection
- copy/paste/cut
- undo/redo
- Cmd+A/C/V/X/Z/Shift+Z
- Cmd+F

Escape flips back.

Support Light/Dark/System appearance.

AUTOSAVE

No Save button.

Autosave with roughly 300-500 ms debounce.

Do not write SwiftData on every keystroke.

Force save when:
- flipping back
- closing target
- target app quits
- Verso quits
- switching targets
- archive/pin state changes

PERSISTENCE

Use SwiftData.

WindowNote should include roughly:
- id
- identityKey
- identity confidence
- bundleIdentifier
- applicationName
- windowTitle
- documentURL/path if applicable
- noteText
- createdAt
- updatedAt
- lastOpenedAt
- archived
- pinned

Persist notes and minimal identity metadata only.

Never persist captured pixels.

WINDOW TRACKING

Use AXObserver, not high-frequency polling.

Track relevant events:
- moved
- resized
- destroyed
- minimized
- focused/main window changes
- application termination

Overlay follows target move/resize.

Do not recapture continuously during movement.

If target closes, minimizes, terminates or becomes invalid:
save note
remove overlay
release observers/captures/resources safely

V1 only needs one flipped window at a time.

If another unrelated window becomes active, save and dismiss current Verso overlay.

MULTI DISPLAY

Correctly support:
- Retina
- external displays
- different scale factors
- negative coordinates
- displays positioned in any direction

Centralize conversions between AX, AppKit and ScreenCaptureKit coordinate systems.

SPACES/FULLSCREEN

Use public APIs only.

Support where reliable.

If fullscreen/Space behavior cannot be implemented safely, fail gracefully instead of using private APIs.

PERMISSIONS

Provide onboarding/settings for:

Accessibility:
needed to identify and follow selected windows.

Screen Recording:
needed only to create temporary flip-animation snapshots.

Explicitly explain that screenshots are never saved and exist only briefly in memory.

If Screen Recording is unavailable, use a neutral fallback front surface with app icon/name/title when practical.

MENU BAR

Verso should primarily be a menu-bar utility with low idle overhead.

Menu:
- Search
- Recent
- Pinned
- Archived
- Settings
- Permissions
- Quit

Search notes by:
- note text
- application
- window/document title
- document path

Provide Open Note, Show Window when live, Pin, Archive, Restore and Delete.

Launch at Login using ServiceManagement.

PERFORMANCE

Verso runs all day, so optimize aggressively.

While idle:
- near-zero CPU
- no continuous capture
- no display link
- no high-frequency timers
- no repeated window enumeration
- no screenshot cache

Use event-driven AXObserver/CGEventTap behavior.

Release:
- AXObservers
- event taps
- Tasks
- notification observers
- CALayers
- overlay windows
- capture resources

Avoid retain cycles and obsolete async capture results.

STATE MACHINE

Use explicit states similar to:

idle
preparingFront
flippingToNote
noteVisible
preparingReturn
flippingToWindow
cleaningUp

Do not use scattered booleans.

Invalid transitions must be rejected safely.

cleanup must be idempotent.

If target disappears or an operation fails, immediately clean up and return to idle without breaking mouse/keyboard interaction.

ARCHITECTURE

Keep responsibilities separate, for example:

VersoApp
AppDelegate
GlobalInputMonitor
AccessibilityWindowService
TitleBarHitTester
WindowIdentityResolver
WindowCaptureResolver
WindowCaptureService
TemporaryCaptureResource
FlipOverlayWindowController
FlipAnimationController
WindowObservationService
NoteRepository
AutosaveCoordinator
CoordinateSpaceConverter
MenuBarController
PermissionManagers
SettingsStore

Avoid giant files and unnecessary overengineering.

Use @MainActor for UI work and Swift concurrency safely. Cancel obsolete capture tasks.

TESTING

Add unit tests for:
- WindowIdentityResolver
- identity normalization
- capture candidate scoring
- coordinate conversion
- title-bar logic where practical

Test manually with:
Finder
Safari
Chrome
Edge
Arc
Terminal
iTerm2
VS Code
Xcode
Preview
Notes
TextEdit
Word

IMPLEMENTATION ORDER

Work incrementally and BUILD after every phase.

1. Xcode project + menu bar + permissions
2. Option-click + AX window/title-bar detection
3. overlay positioning
4. ScreenCaptureKit + AX-to-SCWindow matching
5. 3D front-to-note flip + screenshot cleanup
6. note editor + fresh reverse capture + reverse flip
7. SwiftData + identity resolver + autosave
8. AXObserver move/resize/close tracking
9. menu-bar search/pin/archive
10. settings + launch at login
11. Instruments optimization
12. app compatibility testing

Do not continue past a phase while the project has compiler errors.

Do not leave core TODOs or fake/stub implementations.

If an assumed API differs in the installed SDK, inspect the current public SDK and adapt.

FINAL QUALITY BAR

The essential experience must be polished and reliable:

Option + title-bar click
-> real window appears to flip
-> note backside appears
-> user types
-> autosave
-> screenshot is already gone from memory
-> Escape
-> fresh target snapshot is captured
-> window flips back
-> snapshot is immediately released

Prioritize this interaction over secondary features.

Verso must never permanently interfere with another app's input or window and must never persist captured screen content.