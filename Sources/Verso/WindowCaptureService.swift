import AppKit
import ScreenCaptureKit

#if SWIFT_PACKAGE
import VersoCore
#endif

/// The complete result of a window capture preparation: the window image for
/// the flip face, a tightly bounded backdrop image excluding the target and
/// all Verso-owned windows, and the Quartz canvas frame for overlay
/// positioning.
@MainActor
struct CapturePacket {
    let windowImage: CGImage
    let backdropImage: CGImage
    let canvasFrame: CGRect
}

/// Performs one ScreenCaptureKit window capture for an already-recognized AX hit.
/// The service never asks for Screen Recording permission and never keeps a
/// capture task or image beyond the caller's active preparation.
@MainActor
final class WindowCaptureService {
    typealias Completion = @MainActor (CapturePacket?) -> Void

    /// Start one asynchronous enumeration/match/capture operation.
    /// The task's result is intentionally Void; the packet exists only while the
    /// native completion is being handed to the overlay controller.
    @discardableResult
    func capture(
        for target: AccessibilityWindowService.ResolvedTargetWindow,
        completion: @escaping Completion
    ) -> Task<Void, Never> {
        Task { @MainActor in
            @MainActor
            func completeNeutral() {
                guard !Task.isCancelled else { return }
                completion(nil)
            }

            guard !Task.isCancelled else { return }

            guard isViable(target) else {
                completeNeutral()
                return
            }

            // Preflight never requests access. A user can grant it from the
            // existing permission UI and retry.
            guard CGPreflightScreenCaptureAccess() else {
                completeNeutral()
                return
            }

            do {
                let shareableContent = try await SCShareableContent
                    .excludingDesktopWindows(
                        true,
                        onScreenWindowsOnly: true
                    )

                guard !Task.isCancelled else { return }

                guard isViable(target) else {
                    completeNeutral()
                    return
                }

                let candidates = shareableContent.windows.compactMap(Self.candidate)
                guard let match = WindowCaptureResolver.match(
                    target: target.metadata,
                    candidates: candidates
                ) else {
                    completeNeutral()
                    return
                }

                let matchingWindows = shareableContent.windows.filter {
                    $0.windowID == match.candidate.windowID
                }
                guard matchingWindows.count == 1,
                      let window = matchingWindows.first,
                      window.isOnScreen,
                      let owningApplication = window.owningApplication,
                      owningApplication.processID == target.metadata.pid,
                      owningApplication.bundleIdentifier
                          == match.candidate.bundleIdentifier else {
                    completeNeutral()
                    return
                }

                // 1. Window capture: desktopIndependentWindow, native shadow
                //    excluded so the flip face owns a procedural shadow.
                let windowFilter = SCContentFilter(
                    desktopIndependentWindow: window
                )
                guard let windowDimensions = WindowCaptureResolver.CaptureDimensions(
                    contentRect: windowFilter.contentRect,
                    pointPixelScale: CGFloat(windowFilter.pointPixelScale)
                ) else {
                    completeNeutral()
                    return
                }

                let windowConfig = SCStreamConfiguration()
                windowConfig.width = windowDimensions.width
                windowConfig.height = windowDimensions.height
                windowConfig.showsCursor = false
                windowConfig.capturesAudio = false
                windowConfig.ignoreShadowsSingleWindow = true

                // 2. Backdrop capture: containing display, excluding the
                //    target window and all Verso-owned windows.
                let versoExclusions = shareableContent.windows.filter {
                    $0.owningApplication?.processID == ProcessInfo.processInfo.processIdentifier
                }
                // ponytail: a target must fit one display; composing multiple
                // display backdrops is deferred, with an immediate-transition fallback.
                guard let containingDisplay = shareableContent.displays.first(
                    where: { $0.frame.contains(target.metadata.frame) }
                ) else {
                    completeNeutral()
                    return
                }
                let backdropFilter = SCContentFilter(
                    display: containingDisplay,
                    excludingWindows: [window] + versoExclusions
                )
                guard let canvasGeometry = WindowCaptureResolver.canvasGeometry(
                    targetWindowFrame: target.metadata.frame,
                    displays: [.init(
                        frame: containingDisplay.frame,
                        pointPixelScale: CGFloat(backdropFilter.pointPixelScale)
                    )]
                ) else {
                    completeNeutral()
                    return
                }
                let backdropConfig = SCStreamConfiguration()
                backdropConfig.width = canvasGeometry.dimensions.width
                backdropConfig.height = canvasGeometry.dimensions.height
                backdropConfig.sourceRect = canvasGeometry.sourceRect
                backdropConfig.showsCursor = false
                backdropConfig.capturesAudio = false

                // 3. Capture both images.
                var capturedWindow: CGImage? = try await SCScreenshotManager
                    .captureImage(
                        contentFilter: windowFilter,
                        configuration: windowConfig
                    )
                guard !Task.isCancelled else {
                    capturedWindow = nil
                    return
                }

                guard CGPreflightScreenCaptureAccess(), isViable(target) else {
                    capturedWindow = nil
                    completeNeutral()
                    return
                }
                var capturedBackdrop: CGImage? = try await SCScreenshotManager
                    .captureImage(
                        contentFilter: backdropFilter,
                        configuration: backdropConfig
                    )
                guard !Task.isCancelled else {
                    capturedWindow = nil
                    capturedBackdrop = nil
                    return
                }

                // Recheck permission and target state after both awaits and
                // before handing any pixels to the UI.
                guard let windowImage = capturedWindow,
                      let backdropImage = capturedBackdrop,
                      CGPreflightScreenCaptureAccess(),
                      windowImage.width == windowDimensions.width,
                      windowImage.height == windowDimensions.height,
                      backdropImage.width == canvasGeometry.dimensions.width,
                      backdropImage.height == canvasGeometry.dimensions.height,
                      isViable(target) else {
                    capturedWindow = nil
                    capturedBackdrop = nil
                    completeNeutral()
                    return
                }

                let packet = CapturePacket(
                    windowImage: windowImage,
                    backdropImage: backdropImage,
                    canvasFrame: canvasGeometry.canvasFrame
                )

                // The caller takes ownership synchronously; no image is
                // captured by this task's stored result or closure.
                completion(packet)
            } catch {
                completeNeutral()
            }
        }
    }

    private func isViable(
        _ target: AccessibilityWindowService.ResolvedTargetWindow
    ) -> Bool {
        guard target.metadata.isEligible,
              target.metadata.pid > 0,
              !target.runningApplication.isTerminated,
              !target.runningApplication.isHidden,
              target.runningApplication.processIdentifier
                  == target.metadata.pid,
              let metadataBundle = target.metadata.bundleIdentifier,
              let runningBundle = target.runningApplication.bundleIdentifier,
              metadataBundle == runningBundle else {
            return false
        }
        return true
    }

    private static func candidate(
        from window: SCWindow
    ) -> WindowCaptureCandidate? {
        guard window.windowID != 0,
              window.isOnScreen,
              let owningApplication = window.owningApplication else {
            return nil
        }

        return WindowCaptureCandidate(
            windowID: window.windowID,
            pid: owningApplication.processID,
            bundleIdentifier: owningApplication.bundleIdentifier,
            title: window.title,
            frame: window.frame
        )
    }

}
