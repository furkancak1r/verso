# Performance and image lifetime verification

This document distinguishes deterministic checks, synthetic process measurements and full application profiling. Xcode 26.6 is now installed and its `xctrace list templates` command succeeds. No completed Instruments recording of Verso exists yet.

The checked-in `./scripts/check-resources.sh` runner compiles the production `TemporaryCaptureResource` with the full Xcode toolchain and runs `scripts/resource-probe.swift`. On 2026-09-07 it passed three warmup cycles and 60 measured synthetic 3840×2160 attach/clear cycles, including repeated cleanup assertions for both the owned image and `CALayer.contents`. The independently verified run, invoked from `/private/tmp` to verify cwd independence, reported baseline resident bytes `9,863,168`, settled resident bytes `10,076,160`, and sampled attached-resource peak resident bytes `43,302,912`. The settled increase was `212,992` bytes. These values are observations, not a benchmark threshold or a full-application claim. The probe writes no images and uses no external pixels. Result log: `.build/resource-probe/result.json`; compilation log: `.build/resource-probe/build.log`. The peak is sampled while each resource is attached, not the process-wide maximum reported by Instruments.

An Allocations attempt with only that probe and a six-second limit did not complete: the launched probe remained suspended with zero recorded CPU time for over 17 minutes, while xctrace stayed waiting. No issue message or successful measurement was produced. The incomplete trace is not validation evidence. The underlying Instruments launch-mode startup cause is unconfirmed. A later attach-mode attempt reached the running synthetic probe but requested administrator authentication to analyze processes; it did not complete a recording. No credentials were supplied or developer/security settings changed. Repeat profiling from an authorized desktop session before release.

## Actual application idle observation (2026-09-07)

The final universal `build/Verso.app` launched in the normal desktop session and was observed as PID 34447 with the expected executable path and unchanged process start time. Across 356 seconds after startup, cumulative CPU time remained `0:00.16` at `ps`'s 0.01-second display precision, both CPU-percentage samples were `0.0`, and RSS remained `84,256 KiB`. The agent performed no target flips or permission changes during this observation. Evidence: `.build/phase-12-idle-measurement.json`.

This is a real-process idle observation, not an Instruments recording, a note-visible measurement, or a ScreenCaptureKit allocation cycle. It does not establish behavior under all permission states or external-application interactions. Full flip-cycle profiling and idle profiling with an open note remain pending.

## Phase 11 source audit (2026-09-07)

- `Sources/Verso/WindowCaptureService.swift:45-123` performs one shareable-content lookup and one `SCScreenshotManager.captureImage` request per operation. `SCStreamConfiguration` is only the required one-shot screenshot configuration; no `SCStream` instance is present.
- `Sources/VersoCore/TemporaryCaptureResource.swift:15-33` owns one `CGImage`, keeps the layer weak, and clears the layer contents and image reference idempotently. `Sources/Verso/FlipOverlayWindowController.swift:483-495, 744-756, 927-954` cancels stale capture tasks and clears/closes resources on normal and external cleanup. Forward edge cleanup is at lines 548-556; reverse completion cleanup is at lines 838-865.
- `Sources/VersoCore/FlipAnimationController.swift:109-148, 281-288` invalidates operation generations and callback owners on cancellation/completion. `Sources/Verso/GlobalInputMonitor.swift:128-145` removes and invalidates the event-tap source and port. `Sources/Verso/WindowObservationService.swift:234-258` invalidates callback context and detaches the AX run-loop source; `Sources/Verso/AppDelegate.swift:191-204, 268-287` removes registered workspace and application observers.
- The scoped source search found no network client, screenshot/image serialization, `CADisplayLink`, recurring timer, or idle window enumeration. The only delayed work is the approximately 400 ms editor debounce in `Sources/Verso/NoteSessionController.swift:1246-1251`; the `while true` in `Sources/Verso/AppDelegate.swift:68-87` is the user-facing quit save retry loop, not idle work.
- `Sources/VersoCore/NoteRepository.swift:55-81` uses an explicit non-CloudKit SwiftData store, and the note model contains text and identity metadata rather than pixels. Permission UI opens user-selected system settings panes; no external service or telemetry surface was found. No obvious private API entry points or external-window test capture were found in the scoped source search.

No concrete source defect was found in this bounded audit. These are source and synthetic-probe findings only; they do not establish full-app memory behavior, idle CPU behavior, accessibility interaction, Screen Recording behavior, or physical-display compatibility.

## Required invariants

- No SCStream instance, display link, recurring enumeration or high-frequency timer while idle.
- One temporary window snapshot on forward flip and one fresh snapshot on return. Never capture the whole display as a fallback for an uncertain window match.
- No target screenshot ownership in `noteVisible` or `idle`: clear `CALayer.contents`, remove the image layer, release CGImage/NSImage/pixel/capture owners and cancel stale tasks.
- Cleanup is idempotent on success, cancellation, close, minimize, app termination, target switch, permission failure and capture error.
- No screenshot disk writes, temporary image files, screenshot logs, thumbnail caches or model image fields. Persistent storage contains note text and minimal identity metadata only.

## Instruments protocol (pending a completed desktop recording)

Follow-up prerequisite check on 2026-09-08: the normal-session read-only `DevToolsSecurity -status` still reports developer mode disabled, and the desktop is locked. The earlier administrator-authentication-blocked recording was not retried without a changed prerequisite. No developer/security setting, permission grant or login-item state was changed. A successful authorized desktop recording is still required.

1. Build Release, launch the actual app bundle and grant required permissions. Use synthetic TextEdit or Preview content for the target.
2. Open Instruments Allocations and VM Tracker for Verso. Record baseline after startup/onboarding has settled. Use Points of Interest if the build provides resource-lifetime markers; do not add logs containing title/path/text/pixels.
3. Flip to a note and wait after the animation. Inspect live CGImage, IOSurface, pixel buffer and capture resource allocations. The app must own zero target snapshot resources while the note is visible.
4. Enter text, update the underlying target and flip back. Confirm the capture request count increased for the return and live snapshot ownership returned to zero.
5. Repeat at least 50 full cycles, marking generations. Separately cancel during preparation/animation, close the target, quit the target and revoke permission. No monotonic accumulation of image resources, observers, windows or tasks is acceptable.
6. Compare settled memory with the warmed baseline. Some system framework/font/render caches may remain; investigate continuing growth and all retained large target bitmaps. Record the baseline, settled values, peak, cycle count and trace file location. Do not persist captured pixels as trace attachments.
7. In Time Profiler/Energy Log, idle for five minutes with no note, then with a stationary open note. Verify no recurring capture/enumeration work and near-zero CPU. Record measured CPU/energy instead of asserting a numerical target passed without evidence.

## Verification record

| Check | Result |
| --- | --- |
| Instruments availability | Xcode 26.6 templates listed; launch recording stalled; attach mode requested administrator authentication |
| Source image-write / private API audit | Phase 11 scoped final-source audit found no image serialization, network client, obvious private API entry point, idle enumeration, display link, or recurring timer |
| Deterministic capture cleanup tests | Pass: full suite, 253 tests in 13 suites |
| Release build | Pass: `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer VERSO_BUILD_IN_SANDBOX=1 ./scripts/build.sh` |
| Synthetic resource memory run | Pass: 3 warmups + 60 measured 4K cycles; all references cleared; baseline 9,863,168, settled 10,076,160, sampled peak 43,302,912 bytes |
| 50-cycle full interaction allocation run | Pending Instruments |
| Application idle CPU/RSS observation | 356 seconds after startup: CPU time unchanged at 0.01-second precision; sampled CPU 0.0%; RSS unchanged at 84,256 KiB |
| Idle with an open note / full energy profiling | Pending desktop target interaction and Instruments |

Native application screenshot previews are unnecessary for this protocol. Never use external-window screenshots as test artifacts.
