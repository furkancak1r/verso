import CoreGraphics
import Testing
@testable import VersoCore

@Suite("WindowCaptureResolver")
struct WindowCaptureResolverTests {
    private let targetFrame = CGRect(x: 120, y: 90, width: 900, height: 640)

    private func target(
        title: String? = "Draft — Verso",
        subrole: String = TargetWindowMetadata.standardWindowSubrole,
        frame: CGRect? = nil
    ) -> TargetWindowMetadata {
        TargetWindowMetadata(
            pid: 42,
            bundleIdentifier: "com.example.editor",
            appName: "Editor",
            windowTitle: title,
            windowRole: TargetWindowMetadata.windowRole,
            windowSubrole: subrole,
            documentPath: nil,
            documentURL: nil,
            frame: frame ?? targetFrame
        )
    }

    private func candidate(
        id: CGWindowID,
        pid: pid_t = 42,
        bundle: String? = "com.example.editor",
        title: String? = "Draft — Verso",
        frame: CGRect? = nil
    ) -> WindowCaptureCandidate {
        WindowCaptureCandidate(
            windowID: id,
            pid: pid,
            bundleIdentifier: bundle,
            title: title,
            frame: frame ?? targetFrame
        )
    }

    @Test("Production scoring selects the strongest title and geometry match")
    func selectsStrongestMatch() {
        let weaker = candidate(
            id: 10,
            title: "Draft",
            frame: CGRect(x: 150, y: 115, width: 900, height: 640)
        )
        let stronger = candidate(id: 11)

        let result = WindowCaptureResolver.match(
            target: target(),
            candidates: [weaker, stronger]
        )

        #expect(result?.candidate.windowID == 11)
        #expect(result?.titleScore == 40)
        #expect(result?.geometryScore == 60)
    }

    @Test("Mismatched owning process or application is rejected")
    func rejectsOwnershipMismatch() {
        let candidates = [
            candidate(id: 12, pid: 99),
            candidate(id: 13, bundle: "com.example.other")
        ]

        #expect(WindowCaptureResolver.match(target: target(), candidates: candidates) == nil)
    }

    @Test("Ineligible AX metadata cannot be matched")
    func rejectsIneligibleTarget() {
        let dialog = target(subrole: "AXDialog")
        #expect(WindowCaptureResolver.match(
            target: dialog,
            candidates: [candidate(id: 22)]
        ) == nil)
    }

    @Test("Conflicting title evidence is rejected even with matching geometry")
    func rejectsConflictingTitle() {
        let wrongTitle = candidate(id: 14, title: "Another Window")
        #expect(WindowCaptureResolver.match(target: target(), candidates: [wrongTitle]) == nil)
    }

    @Test("Case, diacritics and internal whitespace remain meaningful", arguments: [
        "draft — verso",
        "Draft — Versö",
        "Draft  — Verso"
    ])
    func rejectsMeaningfulTitleDifferences(_ title: String) {
        #expect(WindowCaptureResolver.match(
            target: target(),
            candidates: [candidate(id: 141, title: title)]
        ) == nil)
    }

    @Test("A distant same-title window is rejected")
    func rejectsDistantSameTitle() {
        let distant = candidate(
            id: 9,
            frame: CGRect(x: 1_100, y: 100, width: 900, height: 640)
        )

        #expect(WindowCaptureResolver.match(
            target: target(), candidates: [distant]
        ) == nil)
    }

    @Test("A same-title window with a different width is rejected")
    func rejectsDifferentWidthSameTitle() {
        let resized = candidate(
            id: 91,
            frame: CGRect(x: 120, y: 90, width: 1_800, height: 640)
        )

        #expect(WindowCaptureResolver.match(
            target: target(), candidates: [resized]
        ) == nil)
    }

    @Test("A case-conflicting title is rejected")
    func rejectsConflictingCase() {
        let conflicting = candidate(id: 92, title: "draft — verso")

        #expect(WindowCaptureResolver.match(
            target: target(), candidates: [conflicting]
        ) == nil)
    }

    @Test("A missing-title lookalike makes an otherwise exact match ambiguous")
    func rejectsMissingTitleLookalike() {
        let known = candidate(id: 10)
        let missing = candidate(id: 11, title: nil)

        #expect(WindowCaptureResolver.match(
            target: target(), candidates: [known, missing]
        ) == nil)
    }

    @Test("A lower-confidence missing title still makes an admitted lookalike ambiguous")
    func rejectsLowerConfidenceMissingTitleLookalike() {
        let frame = CGRect(x: 100, y: 100, width: 200, height: 100)
        let known = candidate(id: 12, frame: frame)
        let missing = candidate(
            id: 13, title: nil,
            frame: CGRect(x: 102, y: 102, width: 202, height: 102)
        )
        for candidates in [[known, missing], [missing, known]] {
            #expect(WindowCaptureResolver.match(
                target: target(frame: frame), candidates: candidates
            ) == nil)
        }
    }

    @Test("Equal and near-equal evidence is ambiguous")
    func rejectsAmbiguousEvidence() {
        let exact = candidate(id: 15)
        let near = candidate(
            id: 16,
            frame: CGRect(x: 120.5, y: 90, width: 900, height: 640)
        )

        #expect(WindowCaptureResolver.match(target: target(), candidates: [exact, near]) == nil)
    }

    @Test("Malformed candidate values fail closed")
    func rejectsMalformedCandidates() {
        let malformed = [
            candidate(id: 0),
            candidate(id: 17, pid: 0),
            candidate(id: 18, bundle: ""),
            candidate(id: 19, frame: CGRect(
                x: CGFloat.greatestFiniteMagnitude,
                y: 0,
                width: 10,
                height: 10
            )),
            candidate(id: 20, title: String(repeating: "x", count: 4_097))
        ]

        #expect(WindowCaptureResolver.match(target: target(), candidates: malformed) == nil)
    }

    @Test("Title input limits use UTF-8 length")
    func rejectsOverlongUTF8Title() {
        let longTitle = String(repeating: "é", count: 2_049)
        let longTarget = target(title: longTitle)
        let matchingCandidate = candidate(id: 201, title: longTitle)

        #expect(WindowCaptureResolver.match(
            target: longTarget,
            candidates: [matchingCandidate]
        ) == nil)
    }

    @Test("Duplicate public window IDs are unsafe")
    func rejectsDuplicateIDs() {
        let first = candidate(id: 21)
        let second = candidate(id: 21, title: "Draft — Verso")
        #expect(WindowCaptureResolver.match(target: target(), candidates: [first, second]) == nil)
    }

    @Test("Capture dimensions use filter points and scale with a pixel budget")
    func validatesCaptureDimensions() {
        let dimensions = WindowCaptureResolver.CaptureDimensions(
            contentRect: CGRect(x: -20, y: 30, width: 100.25, height: 50.1),
            pointPixelScale: 2
        )

        #expect(dimensions?.width == 201)
        #expect(dimensions?.height == 101)
        #expect(dimensions?.pixelCount == 20_301)
        #expect(WindowCaptureResolver.CaptureDimensions(
            contentRect: CGRect(x: 0, y: 0, width: 4_097, height: 4_096),
            pointPixelScale: 1
        ) == nil)
        #expect(WindowCaptureResolver.CaptureDimensions(
            contentRect: CGRect(x: 0, y: 0, width: 100, height: 100),
            pointPixelScale: .infinity
        ) == nil)
        #expect(WindowCaptureResolver.CaptureDimensions(
            contentRect: CGRect(x: 0, y: 0, width: 0, height: 100),
            pointPixelScale: 2
        ) == nil)
    }
    // MARK: - Canvas geometry

    @Test("Canvas geometry for a single-display target")
    func canvasGeometrySingleDisplay() {
        let displays = [
            WindowCaptureResolver.DisplayFrame(
                frame: CGRect(x: 0, y: 0, width: 2560, height: 1440),
                pointPixelScale: 2
            )
        ]
        let target = CGRect(x: 100, y: 100, width: 800, height: 600)

        let result = WindowCaptureResolver.canvasGeometry(
            targetWindowFrame: target,
            displays: displays
        )

        #expect(result != nil)
        // The canvas should be expanded by perspective/shadow margin (12% of
        // width = 96, clamped between 40 and 200).
        let expectedMargin: CGFloat = 96
        #expect(abs(result!.canvasFrame.origin.x - (100 - expectedMargin)) < 0.01)
        #expect(abs(result!.canvasFrame.origin.y - (100 - expectedMargin)) < 0.01)
        #expect(abs(result!.canvasFrame.width - (800 + 2 * expectedMargin)) < 0.01)
        #expect(abs(result!.canvasFrame.height - (600 + 2 * expectedMargin)) < 0.01)
        // sourceRect is display-local (origin - display origin).
        #expect(abs(result!.sourceRect.origin.x - (100 - expectedMargin)) < 0.01)
        #expect(abs(result!.sourceRect.origin.y - (100 - expectedMargin)) < 0.01)
        // Dimensions are in pixels at 2x scale.
        #expect(result!.dimensions.scale == 2)
    }

    @Test("Canvas geometry returns nil for a cross-display target")
    func canvasGeometryCrossDisplay() {
        let displays = [
            WindowCaptureResolver.DisplayFrame(
                frame: CGRect(x: 0, y: 0, width: 1920, height: 1080),
                pointPixelScale: 1
            ),
            WindowCaptureResolver.DisplayFrame(
                frame: CGRect(x: 1920, y: 0, width: 1920, height: 1080),
                pointPixelScale: 1
            )
        ]
        // Window straddles the boundary between the two displays.
        let target = CGRect(x: 1800, y: 100, width: 400, height: 600)

        let result = WindowCaptureResolver.canvasGeometry(
            targetWindowFrame: target,
            displays: displays
        )

        #expect(result == nil)
    }

    @Test("Canvas geometry returns nil for a partly off-display target")
    func canvasGeometryPartlyOffDisplay() {
        let displays = [
            WindowCaptureResolver.DisplayFrame(
                frame: CGRect(x: 0, y: 0, width: 1920, height: 1080),
                pointPixelScale: 1
            )
        ]
        // Window extends past the right edge of the display.
        let target = CGRect(x: 1700, y: 100, width: 400, height: 600)

        let result = WindowCaptureResolver.canvasGeometry(
            targetWindowFrame: target,
            displays: displays
        )

        #expect(result == nil)
    }

    @Test("Canvas geometry returns nil for invalid target frame")
    func canvasGeometryInvalidFrame() {
        let displays = [
            WindowCaptureResolver.DisplayFrame(
                frame: CGRect(x: 0, y: 0, width: 1920, height: 1080),
                pointPixelScale: 1
            )
        ]

        #expect(WindowCaptureResolver.canvasGeometry(
            targetWindowFrame: .zero,
            displays: displays
        ) == nil)
        #expect(WindowCaptureResolver.canvasGeometry(
            targetWindowFrame: CGRect(x: 0, y: 0, width: -100, height: 100),
            displays: displays
        ) == nil)
        #expect(WindowCaptureResolver.canvasGeometry(
            targetWindowFrame: CGRect(
                x: CGFloat.nan, y: 0, width: 100, height: 100
            ),
            displays: displays
        ) == nil)
    }

    @Test("Canvas geometry returns nil for empty displays")
    func canvasGeometryEmptyDisplays() {
        #expect(WindowCaptureResolver.canvasGeometry(
            targetWindowFrame: targetFrame,
            displays: []
        ) == nil)
    }

    @Test("Canvas clips at display edges while retaining a fully visible target")
    func canvasGeometryClipsAtDisplayEdge() throws {
        let targetFrame = CGRect(x: 100, y: 100, width: 800, height: 600)
        let display = CGRect(x: 0, y: 0, width: 900, height: 700)
        let result = try #require(WindowCaptureResolver.canvasGeometry(
            targetWindowFrame: targetFrame,
            displays: [.init(frame: display, pointPixelScale: 2)]
        ))
        #expect(display.contains(result.canvasFrame))
        #expect(result.canvasFrame.contains(targetFrame))
        #expect(result.canvasFrame.maxX == display.maxX)
        #expect(result.canvasFrame.maxY == display.maxY)
        #expect(result.dimensions.width == Int(result.canvasFrame.width * 2))
    }

    @Test("Canvas geometry uses display-local origin for sourceRect")
    func canvasGeometrySourceRectIsDisplayLocal() {
        let displays = [
            WindowCaptureResolver.DisplayFrame(
                frame: CGRect(x: 1920, y: 0, width: 2560, height: 1440),
                pointPixelScale: 2
            )
        ]
        let target = CGRect(x: 2020, y: 100, width: 800, height: 600)

        let result = WindowCaptureResolver.canvasGeometry(
            targetWindowFrame: target,
            displays: displays
        )

        #expect(result != nil)
        // sourceRect origin = canvas origin - display origin
        // canvas origin = target origin - margin
        let expectedMargin: CGFloat = 96
        #expect(abs(result!.sourceRect.origin.x - (2020 - expectedMargin - 1920)) < 0.01)
        #expect(abs(result!.sourceRect.origin.y - (100 - expectedMargin)) < 0.01)
    }

    @Test("Canvas geometry clamps perspective margin for very wide windows")
    func canvasGeometryClampedMargin() {
        // Display must be large enough to contain the expanded canvas.
        let displays = [
            WindowCaptureResolver.DisplayFrame(
                frame: CGRect(x: 0, y: 0, width: 4000, height: 3000),
                pointPixelScale: 1
            )
        ]
        // 12% of 3000 = 360, which exceeds the 200 maximum.
        let target = CGRect(x: 500, y: 500, width: 3000, height: 1000)

        let result = WindowCaptureResolver.canvasGeometry(
            targetWindowFrame: target,
            displays: displays
        )

        #expect(result != nil)
        let expectedMargin: CGFloat = 200
        #expect(abs(result!.canvasFrame.origin.x - (500 - expectedMargin)) < 0.01)
    }

    @Test("Canvas geometry uses minimum margin for very small windows")
    func canvasGeometryMinimumMargin() {
        let displays = [
            WindowCaptureResolver.DisplayFrame(
                frame: CGRect(x: 0, y: 0, width: 1920, height: 1080),
                pointPixelScale: 1
            )
        ]
        // 12% of 100 = 12, which is below the 40 minimum.
        let target = CGRect(x: 100, y: 100, width: 100, height: 100)

        let result = WindowCaptureResolver.canvasGeometry(
            targetWindowFrame: target,
            displays: displays
        )

        #expect(result != nil)
        let expectedMargin: CGFloat = 40
        #expect(abs(result!.canvasFrame.origin.x - (100 - expectedMargin)) < 0.01)
        #expect(abs(result!.canvasFrame.width - (100 + 2 * expectedMargin)) < 0.01)
    }

}
