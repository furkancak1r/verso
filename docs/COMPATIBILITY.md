# Compatibility verification

This is a verification record, not a claim that every application exposes usable Accessibility metadata. A rejected ambiguous title-bar hit is safer than interfering with another app. Populate results only from observed runs.

## Version 1.1.2 — implementation complete, desktop acceptance pending

Current source adds synchronized direct note drag/resize, retained editor on minimize/restore and Space changes, target-native fullscreen/zoom controls, localized operation feedback and one-time fresh-profile login registration. The latest full test run is recorded in `.build/phase-16-parent-test.log` (298 tests); desktop runner compile/self-check passes in `.build/phase-16-desktop-self-check.log`. Native synthetic layouts at320/360/600pt in English and Turkish are under `.build/phase16-qa/`; the320pt Turkish Back-button clipping found during visual review was fixed. These are generated view renders, not evidence of desktop drag/minimize/fullscreen behavior.

The final universal 1.1.2 build 4 was packaged and installed outside the project. Both architectures, the strict ad-hoc signature, read-only mounted DMG/app equality, Applications symlink and checksums were verified. Previous 1.1.0/1.1.1 packages remain intact. The installed app reports Accessibility and Screen Recording denied despite an enabled Accessibility switch in System Settings; standard in-app Request Access and Refresh did not resolve the mismatch. Final desktop acceptance is blocked by this permission issue.

Final installed Turkish/English interaction acceptance, actual Dock restoration, fullscreen/Space behavior and real login/reboot remain **unverified**. The expanded runner uses only unique synthetic targets and validates exact installed identity before pointer/keyboard input; its programmatic fixture deminiaturize step alone must not be counted as a real Dock click. Prior1.1.1 and older passes below are historical evidence only.

## Historical checks through version 1.1.1

Verified on 2026-09-08 on Apple Silicon, macOS 26.6.2 (25G83), Xcode 26.6 (17F113) and Swift 6.3.3. The final Xcode Release bundle contains arm64 and x86_64 executables targeting macOS 14.0 and passes strict ad-hoc signature validation. Intel and macOS 14 runtime execution remain unverified. Version 1.1.1 build evidence: `.build/phase-15b-release.log`.

The deterministic suite passes **286 tests in 14 suites**, covering identity, geometry, input, persistence and failure recovery, capture matching, animation/resources, observation, library behavior and settings. Evidence: `.build/phase-15a-parent-test.log`.

Native synthetic visual checks verify a centered whole-window flip: the title bar, body, corners and rendered shadow rotate together over a target-excluded background. The native note editor returns to the exact target frame with input enabled and captured images released. A target resize from 680×463 to 808×510 points is followed correctly before the reverse animation. Final visual results and source hashes: `.build/whole-window-qa/phase-13c-final/visual-result.json` and `source-hashes.json`. Both forward and reverse samples disable the native canvas shadow; the rotating face supplies its own shadow. These images contain only generated test content; production captures remain in memory.

The packaged app launches in the normal desktop session. Verso-only stale ad-hoc permission entries were refreshed through standard macOS Settings under the user's authorization; app-reported Accessibility and Screen Recording grants were verified. The canonical desktop runner passed all 14 stages: Option-click, native editor, generated Unicode text, Undo/Redo, Cmd+F, Escape/refocus, exact text on reopen, movement/resize and target-close cleanup. Previous phase 13 project-bundle evidence: `.build/phase-13c-desktop-result.json` and `.build/phase-13c-permissions.txt`. Earlier phase 12 locked-desktop, missing-grant and Find-command failures are historical and superseded; they are not current blockers.

Earlier native synthetic appearance checks verified existing window and note surfaces follow Light/Dark and that System clears the override. An actual-process idle observation over 356 seconds found unchanged cumulative CPU time at 0.01-second precision and unchanged RSS; see [PERFORMANCE.md](PERFORMANCE.md) for its scope. Full Instruments profiling, IME and VoiceOver interaction remain unverified.

Phase 14B passed: `scripts/release.sh` built universal 1.1.0 (build 2), verified identity, version, both architectures, English/Turkish resources and strict ad-hoc signature, created and verified the DMG, and checked ZIP/DMG hashes. Evidence: `.build/phase-14b-release.log`. A forced synthetic build failure preserved the prior release and cleaned its own staging (`.build/phase-14b-release-failure-check.json`). The DMG was mounted read-only; its app bytes matched the release bundle, and the Applications symlink and bilingual guide were verified. It was then installed at `/Applications/Verso.app` and the DMG was ejected. The installed app launches outside the project and recognizes both permission grants after standard Verso-only Settings recovery. The app is ad-hoc signed, not notarized. A clean-machine Gatekeeper flow and physical Intel/macOS 14 execution remain unverified.

Phase 14 localization checks pass: 286 tests in 14 suites, desktop-driver self-check, and a standalone resource probe that makes SwiftPM's `Bundle.module` unavailable. Both languages contain 134 keys with matching formatting arguments; 131 literal production lookup keys are present. Native synthetic Settings layouts fit at 520×663 points in both languages, and onboarding layouts fit at 540×532 (Turkish) and 540×547 (English). Generated settings/onboarding images were visually inspected. Translucent Permissions bitmap captures are not compositor evidence.

Historical phase 14C attempt (superseded by the phase 15 installed run below). The first Turkish run passed identity, fixture and click guards but timed out waiting for the overlay (`.build/phase-14c-desktop-tr.json`). A subsequent native diagnostic found `com.apple.loginwindow` frontmost (`.build/phase14-qa/window-state.txt`); this is not an accepted product interaction result. The required bilingual run and language preference checks were completed on version 1.1.1 in phase 15 below; historical phase 13 passes were not counted as this acceptance.

An installed-bundle inventory found Finder, Safari, Chrome, Terminal, VS Code, Xcode, Preview, Notes, TextEdit and Word. Edge, Arc and iTerm2 were not found at the checked standard paths. Inventory (`.build/compatibility-app-bundles.json`) is not application interaction evidence. Synthetic desktop results do not replace the matrix below, physical-display checks, disk/reboot persistence or login-item verification.

## Phase 15 — pin feedback and installed 1.1.1 acceptance

Version 1.1.1 (build 3) is installed at `/Applications/Verso.app`; strict ad-hoc signature and arm64/x86_64 slices were verified. The DMG was mounted read-only; its app bytes, bilingual guide and Applications link matched the release, and installed bytes matched the mounted app. The DMG was ejected. Release log: `.build/phase-15b-release.log`. Version 1.1.0's release remains intact and the prior installed app is preserved at `.build/checkpoints/phase-15-installed-1.1.0/Verso.app`.

Both installed Turkish and English runs passed **20/20 stages** (`.build/phase-15c-desktop-tr.json`, `.build/phase-15c-desktop-en.json`). The added stages verify pin/unpin, localized feedback with focus retained, message expiry and restored pin state without stale feedback on reopen. Existing Unicode, real Undo/Redo, Find, Escape/refocus, geometry and cleanup checks also pass. Only generated uniquely named notes were used; the runner retains these synthetic notes and never reads the clipboard or deletes user notes.

The source suite passes **286 tests in 14 suites**, including failed-pin/failed-unpin rollback and membership, actual NSTextView focus and undo/redo preservation, and wall-clock two/five-second feedback deadlines with replacement. The final glyph assertion compares actual NSImage data with both SF Symbols (`.build/phase-15a-glyph-test.log`); desktop self-check and standalone resource regression also pass. Synthetic Turkish/English renders at 320/360/600 points fit without ancestor overflow or text truncation (`.build/phase15-qa/{en,tr}-pin-layout.json`). The feedback passes mouse hits through and stays within a fixed editor gap.

Actual Settings screenshots verify version 1.1.1, persisted English after relaunch, and restored System resolving Turkish after the final relaunch (`.build/phase15-qa/en-installed-settings.png`, `tr-installed-settings.png`). Both permissions are recognized (`tr-installed-permissions.png`) after authorized Verso-only normal Settings recovery for the new ad-hoc binary. No credential handling, TCC database edits or Gatekeeper changes were used. The application remains open with System selected. Native accessibility state/labels and announcement API arguments were checked; an actual VoiceOver listening session, physical Intel/macOS 14, named-app matrix and reboot/login checks remain unverified.

## Required application matrix

Synthetic folder, UTF-8 text, RTF and local HTML fixtures are prepared under `.build/compatibility-fixtures`. Preparation and the native synthetic smoke test do not count as passes for these applications.

| Application | Required scenario | Status |
| --- | --- | --- |
| Finder | Two folders, same folder in two windows, folder reopen | Pending interactive test |
| Safari | Two windows, tab/title changes, restart without incorrect restoration | Pending interactive test |
| Chrome | Two windows, tab strip and address field excluded | Pending interactive test |
| Edge | Two windows, tab changes and restart | Pending interactive test; not found in checked standard locations |
| Arc | Sidebar, compact title area, tab changes | Pending interactive test; not found in checked standard locations |
| Terminal | Multiple windows/tabs, changing shell titles | Pending interactive test |
| iTerm2 | Multiple windows/tabs, changing shell titles | Pending interactive test; not found in checked standard locations |
| VS Code | Two projects, unsaved files, title changes | Pending interactive test |
| Xcode | Two projects, multiple editors for one project | Pending interactive test; Xcode 26.6 installed |
| Preview | Two documents, same document in two windows, document reopen | Pending interactive test |
| Notes | Multiple notes/windows, title changes | Pending interactive test |
| TextEdit | Saved and untitled documents, reopen, Unicode text | Pending interactive test |
| Word | Saved and unsaved documents, sheets, document reopen | Pending interactive test |

For each application:

1. Create synthetic documents/windows. Never use customer data or credentials for test captures.
2. Option-left-click an unoccupied title-bar area. Confirm exact overlay placement, a legible flip and a native editor. A conservative rejection should leave the click untouched.
3. Option-click close/minimize/zoom controls, tab/toolbar buttons, text fields, app content, sheets, popovers, menus, Dock and desktop. Confirm no Verso flip and unchanged normal interaction.
4. Enter multiline Unicode, emoji and a link; use selection, scrolling, Cmd+A/C/V/X, undo/redo and Cmd+F. Escape and Back return to the current target window.
5. Change underlying target content while the note is open. Flip back and confirm the returning front is fresh. There must be no saved image files or thumbnail history.
6. Open two distinct windows with the same title. Their notes must remain distinct. Close/reopen saved documents and verify restoration only when identity is sufficiently strong. Browser tab changes must not attach another tab/window's saved note.
7. Move and resize the target through another means while Verso is open. Confirm alignment updates after the AX notification without recurring captures.
8. Minimize, close, hide or quit the target; activate an unrelated application/window. Confirm note save and overlay removal. Reopen the note from the library.
9. Quit/relaunch Verso and reboot; verify saved notes, pin/archive state and search results. Verify Show Window only raises a validated live window.

## System scenarios

| Scenario | Expected behavior | Status |
| --- | --- | --- |
| Accessibility denied/revoked | Explain permission; no intercepted clicks; active overlay cleaned up safely | Pending |
| Screen Recording denied/revoked | Immediate transition to the native editor; no unrelated capture; editing remains usable | Pending |
| Slow/unresponsive target | Bounded AX hit testing; normal input passes through if recognition times out | Pending |
| Retina + external displays | Window bounds in points; capture size uses the target scale | Pending physical display test |
| Display left/above/below main display | Correct negative coordinates and Quartz/AppKit conversion | Pending physical display test |
| Display detach/rearrange | Reposition or safely dismiss overlay | Pending |
| Spaces/fullscreen | Support reliable public behavior; otherwise reject or dismiss safely | Pending |
| Rapid Option-click / Escape / target close | No stuck overlay, stale capture result or consumed input sequence | Pending |
| Store write failure | Visible error, retained draft, retry; quit must not silently lose edits | Synthetic persistence/failure/retry checks pass; desktop test pending |
| Launch at Login | SMAppService status and Settings reflect actual registration | Injected service failure/status tests pass; real registration/login/reboot pending |
| System / Light / Dark | Existing windows and native note surfaces follow the selected appearance | Native synthetic desktop check passed; full interaction matrix pending |
| VoiceOver / increased contrast / reduced motion | Named controls, readable editor, accessible alternative animation | Deterministic reduced-motion/resource checks pass; desktop accessibility testing pending |

## Recording a run

Record date, Verso build, macOS version, application/version, display arrangement, granted permissions, actual result and any reproducible failure. Do not attach captured external-window screenshots. Record geometry, resource counts and synthetic test identifiers when needed.
