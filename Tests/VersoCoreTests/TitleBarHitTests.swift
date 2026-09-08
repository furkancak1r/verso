import Testing
import CoreGraphics
@testable import VersoCore

// MARK: - Test helpers

/// Make an eligible TargetWindowMetadata at given origin (top-left) with given size.
/// Frame origin is AX top-left; (100, 200) means x=100, y=200 from display top-left.
private func makeWindow(
    origin: CGPoint = CGPoint(x: 100, y: 200),
    size: CGSize = CGSize(width: 800, height: 600),
    title: String? = "My Document",
    bundleID: String = "com.test.app",
    pid: pid_t = 1234,
    role: String? = "AXWindow",
    subrole: String? = "AXStandardWindow",
    minimized: Bool = false,
    onScreen: Bool = true
) -> TargetWindowMetadata {
    TargetWindowMetadata(
        pid: pid,
        bundleIdentifier: bundleID,
        appName: "TestApp",
        windowTitle: title,
        windowRole: role,
        windowSubrole: subrole,
        documentPath: nil,
        documentURL: nil,
        frame: CGRect(origin: origin, size: size),
        isMinimized: minimized,
        isOnScreen: onScreen
    )
}

/// Make a plausible button frame at given offset from window top-left.
private func buttonFrame(
    window: TargetWindowMetadata,
    xOffset: CGFloat,
    yOffset: CGFloat,
    width: CGFloat = 14,
    height: CGFloat = 14
) -> CGRect {
    CGRect(
        x: window.frame.origin.x + xOffset,
        y: window.frame.origin.y + yOffset,
        width: width,
        height: height
    )
}

/// Standard close/minimize/zoom button frames for a window.
private func standardButtons(_ w: TargetWindowMetadata) -> (CGRect, CGRect, CGRect) {
    (buttonFrame(window: w, xOffset: 7,  yOffset: 7),
     buttonFrame(window: w, xOffset: 27, yOffset: 7),
     buttonFrame(window: w, xOffset: 47, yOffset: 7))
}

// MARK: - Test-only HitTestEvidence builders

/// Private test conveniences — not production DSL.
private extension HitTestEvidence {
    static func titleHit(
        titleFrame: CGRect,
        windowFrame: CGRect,
        ancestors: [String] = []
    ) -> HitTestEvidence {
        HitTestEvidence(
            hitRole: "AXStaticText",
            ancestorRoles: ancestors,
            hasTitleInPath: true,
            titleElementFrame: titleFrame,
            isLeafWindow: false,
            closeButtonFrame: nil,
            minimizeButtonFrame: nil,
            zoomButtonFrame: nil
        )
    }

    static func directWindow(
        windowFrame: CGRect,
        close: CGRect? = nil,
        minimize: CGRect? = nil,
        zoom: CGRect? = nil,
        ancestors: [String]? = nil
    ) -> HitTestEvidence {
        HitTestEvidence(
            hitRole: "AXWindow",
            ancestorRoles: ancestors ?? ["AXApplication"],
            hasTitleInPath: false,
            titleElementFrame: nil,
            isLeafWindow: true,
            closeButtonFrame: close,
            minimizeButtonFrame: minimize,
            zoomButtonFrame: zoom
        )
    }

    static func interactive(
        role: String = "AXButton",
        ancestors: [String] = ["AXGroup", "AXWindow"]
    ) -> HitTestEvidence {
        HitTestEvidence(
            hitRole: role,
            ancestorRoles: ancestors,
            hasTitleInPath: false,
            titleElementFrame: nil,
            isLeafWindow: false,
            closeButtonFrame: nil,
            minimizeButtonFrame: nil,
            zoomButtonFrame: nil
        )
    }
}


// MARK: - TargetWindowMetadata eligibility

@Test("Eligible window with AXWindow + AXStandardWindow passes")
func metadataEligibleStandardWindow() {
    let w = makeWindow()
    #expect(w.isEligible)
}

@Test("Metadata without AXWindow role fails")
func metadataRejectsNonWindowRole() {
    let w = makeWindow(role: "AXGroup")
    #expect(!w.isEligible)
}

@Test("Metadata without AXStandardWindow subrole fails")
func metadataRejectsNonStandardSubrole() {
    #expect(!makeWindow(subrole: "AXSheet").isEligible)
    #expect(!makeWindow(subrole: "AXDialog").isEligible)
    #expect(!makeWindow(subrole: "AXSystemDialog").isEligible)
    #expect(!makeWindow(subrole: "AXPopover").isEligible)
    #expect(!makeWindow(subrole: "AXUnknown").isEligible)
}

@Test("Metadata with nil role fails")
func metadataRejectsNilRole() {
    #expect(!makeWindow(role: nil).isEligible)
}

@Test("Metadata with nil subrole fails")
func metadataRejectsNilSubrole() {
    #expect(!makeWindow(subrole: nil).isEligible)
}

@Test("Metadata with empty bundle identifier fails")
func metadataRejectsEmptyBundleID() {
    #expect(!makeWindow(bundleID: "").isEligible)
    #expect(!makeWindow(bundleID: "   ").isEligible)
}

@Test("Metadata with nil/whitespace-only bundle identifier fails")
func metadataRejectsWhitespaceBundleID() {
    #expect(!makeWindow(bundleID: "\t\n").isEligible)
}

@Test("Metadata with invalid PID fails")
func metadataRejectsInvalidPID() {
    #expect(!makeWindow(pid: 0).isEligible)
    #expect(!makeWindow(pid: -1).isEligible)
}

@Test("Metadata with minimized window fails")
func metadataRejectsMinimized() {
    #expect(!makeWindow(minimized: true).isEligible)
}

@Test("Metadata with off-screen window fails")
func metadataRejectsOffScreen() {
    #expect(!makeWindow(onScreen: false).isEligible)
}

@Test("Metadata with NaN frame fails")
func metadataRejectsNaNFrame() {
    let w = makeWindow(origin: CGPoint(x: CGFloat.nan, y: 200), size: CGSize(width: 800, height: 600))
    #expect(!w.isEligible)
}

@Test("Metadata with infinite frame fails")
func metadataRejectsInfiniteFrame() {
    let w = TargetWindowMetadata(
        pid: 1234, bundleIdentifier: "com.test.app", appName: "TestApp",
        windowTitle: "Doc", windowRole: "AXWindow", windowSubrole: "AXStandardWindow",
        documentPath: nil, documentURL: nil,
        frame: CGRect(x: 0, y: 0, width: CGFloat.infinity, height: 600)
    )
    #expect(!w.isEligible)
}

@Test("Metadata with zero-size frame fails")
func metadataRejectsZeroSizeFrame() {
    #expect(!makeWindow(size: CGSize.zero).isEligible)
}

@Test("Negative frame coordinates are accepted if finite and positive size")
func metadataAcceptsNegativeCoordinates() {
    #expect(makeWindow(origin: CGPoint(x: -200, y: -100)).isEligible)
}

// MARK: - Hit test: true title path

@Test("True title path: actual AXTitleUIElement match in top band")
func hitTestTrueTitlePath() {
    let w = makeWindow()
    let topY = w.frame.origin.y
    let hit = CGPoint(x: 300, y: topY + 10)
    let ev = HitTestEvidence.titleHit(
        titleFrame: CGRect(x: 150, y: topY + 5, width: 200, height: 18),
        windowFrame: w.frame,
        ancestors: ["AXGroup", "AXWindow"]
    )
    #expect(TitleBarHitTester.hitTest(hitPoint: hit, target: w, evidence: ev))
}

@Test("True title path with AXGroup role and title in path succeeds")
func hitTestTrueTitlePathGroupRole() {
    let w = makeWindow()
    let topY = w.frame.origin.y
    let hit = CGPoint(x: 300, y: topY + 10)
    let ev = HitTestEvidence(
        hitRole: "AXGroup",
        ancestorRoles: ["AXWindow"],
        hasTitleInPath: true,
        titleElementFrame: CGRect(x: 150, y: topY + 5, width: 200, height: 18),
        isLeafWindow: false
    )
    #expect(TitleBarHitTester.hitTest(hitPoint: hit, target: w, evidence: ev))
}

@Test("True title path with AXToolbar role and title in path succeeds")
func hitTestTrueTitlePathToolbarRole() {
    let w = makeWindow()
    let topY = w.frame.origin.y
    let hit = CGPoint(x: 300, y: topY + 10)
    let ev = HitTestEvidence(
        hitRole: "AXToolbar",
        ancestorRoles: ["AXWindow"],
        hasTitleInPath: true,
        titleElementFrame: CGRect(x: 150, y: topY + 5, width: 200, height: 18),
        isLeafWindow: false
    )
    #expect(TitleBarHitTester.hitTest(hitPoint: hit, target: w, evidence: ev))
}

// MARK: - Hit test: direct window background with corroborated buttons

@Test("Direct window hit with 2+ valid buttons in title bar succeeds")
func hitTestDirectWindowCorroboratedButtons() {
    let w = makeWindow()
    let (close, minimize, _) = standardButtons(w)
    let topY = w.frame.origin.y
    let hit = CGPoint(x: 400, y: topY + 14)
    let ev = HitTestEvidence.directWindow(
        windowFrame: w.frame,
        close: close,
        minimize: minimize,
        zoom: nil,
        ancestors: ["AXApplication"]
    )
    #expect(TitleBarHitTester.hitTest(hitPoint: hit, target: w, evidence: ev))
}

@Test("Direct window hit with all 3 buttons succeeds")
func hitTestDirectWindowAllButtons() {
    let w = makeWindow()
    let (close, minimize, zoom) = standardButtons(w)
    let topY = w.frame.origin.y
    let hit = CGPoint(x: 400, y: topY + 14)
    let ev = HitTestEvidence.directWindow(
        windowFrame: w.frame,
        close: close,
        minimize: minimize,
        zoom: zoom
    )
    #expect(TitleBarHitTester.hitTest(hitPoint: hit, target: w, evidence: ev))
}

// MARK: - Hit test: empty/fake/inconsistent button evidence fails

@Test("Direct window hit with no buttons fails")
func hitTestDirectWindowNoButtons() {
    let w = makeWindow()
    let topY = w.frame.origin.y
    let hit = CGPoint(x: 400, y: topY + 14)
    let ev = HitTestEvidence.directWindow(windowFrame: w.frame)
    #expect(!TitleBarHitTester.hitTest(hitPoint: hit, target: w, evidence: ev))
}

@Test("Direct window hit with only one button fails")
func hitTestDirectWindowOneButton() {
    let w = makeWindow()
    let (close, _, _) = standardButtons(w)
    let topY = w.frame.origin.y
    let hit = CGPoint(x: 400, y: topY + 14)
    let ev = HitTestEvidence.directWindow(
        windowFrame: w.frame,
        close: close
    )
    #expect(!TitleBarHitTester.hitTest(hitPoint: hit, target: w, evidence: ev))
}

@Test("Direct window hit with fake button frames (too large) fails")
func hitTestDirectWindowFakeButtons() {
    let w = makeWindow()
    let topY = w.frame.origin.y
    // Buttons that are way too large to be real traffic lights.
    let fakeClose = CGRect(x: w.frame.origin.x, y: topY, width: 200, height: 100)
    let fakeMinimize = CGRect(x: w.frame.origin.x + 210, y: topY, width: 200, height: 100)
    let hit = CGPoint(x: 400, y: topY + 14)
    let ev = HitTestEvidence.directWindow(
        windowFrame: w.frame,
        close: fakeClose,
        minimize: fakeMinimize
    )
    #expect(!TitleBarHitTester.hitTest(hitPoint: hit, target: w, evidence: ev))
}

@Test("Direct window hit with button frames outside title bar fails")
func hitTestDirectWindowButtonsOutsideTitleBar() {
    let w = makeWindow()
    let topY = w.frame.origin.y
    // Buttons in the content area, not the title bar.
    let outsideClose = CGRect(x: w.frame.origin.x + 10, y: topY + 300, width: 14, height: 14)
    let outsideMinimize = CGRect(x: w.frame.origin.x + 30, y: topY + 300, width: 14, height: 14)
    let hit = CGPoint(x: 400, y: topY + 14)
    let ev = HitTestEvidence.directWindow(
        windowFrame: w.frame,
        close: outsideClose,
        minimize: outsideMinimize
    )
    #expect(!TitleBarHitTester.hitTest(hitPoint: hit, target: w, evidence: ev))
}

// MARK: - Hit test: empty ancestor list (failed ancestor queries) blocks geometry fallback

@Test("Direct window hit with empty ancestor list fails (ancestor queries failed)")
func hitTestDirectWindowEmptyAncestors() {
    let w = makeWindow()
    let (close, minimize, zoom) = standardButtons(w)
    let topY = w.frame.origin.y
    let hit = CGPoint(x: 400, y: topY + 14)
    let ev = HitTestEvidence.directWindow(
        windowFrame: w.frame,
        close: close,
        minimize: minimize,
        zoom: zoom,
        ancestors: []
    )
    #expect(!TitleBarHitTester.hitTest(hitPoint: hit, target: w, evidence: ev))
}

// MARK: - Hit test: top staticText/group/toolbar without title evidence fails

@Test("AXStaticText in top area without title-path proof fails")
func hitTestTopStaticTextWithoutTitle() {
    let w = makeWindow()
    let topY = w.frame.origin.y
    let hit = CGPoint(x: 300, y: topY + 10)
    let ev = HitTestEvidence(
        hitRole: "AXStaticText",
        ancestorRoles: ["AXGroup", "AXWindow"],
        hasTitleInPath: false,
        isLeafWindow: false
    )
    #expect(!TitleBarHitTester.hitTest(hitPoint: hit, target: w, evidence: ev))
}

@Test("AXGroup in top area without title-path proof fails")
func hitTestTopGroupWithoutTitle() {
    let w = makeWindow()
    let topY = w.frame.origin.y
    let hit = CGPoint(x: 300, y: topY + 10)
    let ev = HitTestEvidence(
        hitRole: "AXGroup",
        ancestorRoles: ["AXWindow"],
        hasTitleInPath: false,
        isLeafWindow: false
    )
    #expect(!TitleBarHitTester.hitTest(hitPoint: hit, target: w, evidence: ev))
}

@Test("AXToolbar in top area without title-path proof fails")
func hitTestTopToolbarWithoutTitle() {
    let w = makeWindow()
    let topY = w.frame.origin.y
    let hit = CGPoint(x: 300, y: topY + 10)
    let ev = HitTestEvidence(
        hitRole: "AXToolbar",
        ancestorRoles: ["AXWindow"],
        hasTitleInPath: false,
        isLeafWindow: false
    )
    #expect(!TitleBarHitTester.hitTest(hitPoint: hit, target: w, evidence: ev))
}

// MARK: - Hit test: controls and interactive ancestors fail

@Test("AXButton always fails even in title bar")
func hitTestButtonInTitleBar() {
    let w = makeWindow()
    let topY = w.frame.origin.y
    let hit = CGPoint(x: 14, y: topY + 14)
    let ev = HitTestEvidence.interactive(role: "AXButton")
    #expect(!TitleBarHitTester.hitTest(hitPoint: hit, target: w, evidence: ev))
}

@Test("AXTextField in content area fails")
func hitTestTextField() {
    let w = makeWindow()
    let hit = CGPoint(x: 400, y: 500)
    let ev = HitTestEvidence.interactive(role: "AXTextField")
    #expect(!TitleBarHitTester.hitTest(hitPoint: hit, target: w, evidence: ev))
}

@Test("Hit with interactive ancestor fails even with title evidence")
func hitTestInteractiveAncestor() {
    let w = makeWindow()
    let topY = w.frame.origin.y
    let hit = CGPoint(x: 300, y: topY + 10)
    let ev = HitTestEvidence.titleHit(
        titleFrame: CGRect(x: 150, y: topY + 5, width: 200, height: 18),
        windowFrame: w.frame,
        ancestors: ["AXButton", "AXGroup", "AXWindow"]
    )
    #expect(!TitleBarHitTester.hitTest(hitPoint: hit, target: w, evidence: ev))
}

@Test("AXLink as hit role fails")
func hitTestLink() {
    let w = makeWindow()
    let hit = CGPoint(x: 400, y: 500)
    let ev = HitTestEvidence.interactive(role: "AXLink")
    #expect(!TitleBarHitTester.hitTest(hitPoint: hit, target: w, evidence: ev))
}

// MARK: - Hit test: point inside traffic-light button frames (caller reports as AXButton)

@Test("Point on close button center: caller reports as AXButton → rejected")
func hitTestPointInCloseButton() {
    let w = makeWindow()
    let (close, _, _) = standardButtons(w)
    let hit = CGPoint(x: close.midX, y: close.midY)
    // If the caller correctly reports hitRole=AXButton for a button click, it fails.
    let buttonEv = HitTestEvidence.interactive(role: "AXButton")
    #expect(!TitleBarHitTester.hitTest(hitPoint: hit, target: w, evidence: buttonEv))
}

// MARK: - Hit test: sheets / nonstandard / nil roles fail

@Test("Sheet window (AXSheet subrole) fails")
func hitTestSheetWindow() {
    let w = makeWindow(subrole: "AXSheet")
    let topY = w.frame.origin.y
    let hit = CGPoint(x: 400, y: topY + 10)
    let ev = HitTestEvidence.titleHit(
        titleFrame: CGRect(x: 150, y: topY + 5, width: 200, height: 18),
        windowFrame: w.frame
    )
    #expect(!TitleBarHitTester.hitTest(hitPoint: hit, target: w, evidence: ev))
}

@Test("Dialog window (AXDialog subrole) fails")
func hitTestDialogWindow() {
    let w = makeWindow(subrole: "AXDialog")
    let topY = w.frame.origin.y
    let hit = CGPoint(x: 400, y: topY + 10)
    let ev = HitTestEvidence.titleHit(
        titleFrame: CGRect(x: 150, y: topY + 5, width: 200, height: 18),
        windowFrame: w.frame
    )
    #expect(!TitleBarHitTester.hitTest(hitPoint: hit, target: w, evidence: ev))
}

@Test("Unknown subrole fails")
func hitTestUnknownSubrole() {
    let w = makeWindow(subrole: "AXUnknown")
    let topY = w.frame.origin.y
    let hit = CGPoint(x: 400, y: topY + 10)
    let ev = HitTestEvidence.titleHit(
        titleFrame: CGRect(x: 150, y: topY + 5, width: 200, height: 18),
        windowFrame: w.frame
    )
    #expect(!TitleBarHitTester.hitTest(hitPoint: hit, target: w, evidence: ev))
}

// MARK: - Hit test: bottom vs top correctness

@Test("Hit at bottom of window is NOT in top area")
func hitTestBottomOfWindow() {
    let w = makeWindow()
    let bottomY = w.frame.maxY - 10
    let hit = CGPoint(x: 400, y: bottomY)
    let ev = HitTestEvidence.titleHit(
        titleFrame: CGRect(x: 150, y: w.frame.origin.y + 5, width: 200, height: 18),
        windowFrame: w.frame
    )
    // Hit is in window but NOT in top area -> title path rejects
    #expect(!TitleBarHitTester.hitTest(hitPoint: hit, target: w, evidence: ev))
    // Direct-window path also rejects because hit is not in top area
    let (close, minimize, zoom) = standardButtons(w)
    let dwEv = HitTestEvidence.directWindow(
        windowFrame: w.frame,
        close: close,
        minimize: minimize,
        zoom: zoom
    )
    #expect(!TitleBarHitTester.hitTest(hitPoint: hit, target: w, evidence: dwEv))
}

@Test("Hit at top edge passes isInTopArea; hit just below band fails")
func hitTestTopEdgeVsBelowBand() {
    let w = makeWindow()
    let topY = w.frame.origin.y
    let bandHeight = min(TitleBarHitTester.titleBarHeight, w.frame.height * 0.2)
    // At exact top edge: should be in top area.
    #expect(TitleBarHitTester.isInTopArea(hitPoint: CGPoint(x: 400, y: topY), target: w))
    // At topEdge + bandHeight - 0.01: should be in top area.
    #expect(TitleBarHitTester.isInTopArea(hitPoint: CGPoint(x: 400, y: topY + bandHeight - 0.01), target: w))
    // At topEdge + bandHeight: should NOT be in top area (half-open interval).
    #expect(!TitleBarHitTester.isInTopArea(hitPoint: CGPoint(x: 400, y: topY + bandHeight), target: w))
}

// MARK: - Hit test: negative frame coordinates

@Test("Window with negative origin: title hit works correctly")
func hitTestNegativeOriginTitle() {
    let origin = CGPoint(x: -200, y: -100)
    let w = makeWindow(origin: origin)
    let topY = origin.y
    let hit = CGPoint(x: origin.x + 100, y: topY + 10)
    let ev = HitTestEvidence.titleHit(
        titleFrame: CGRect(x: origin.x + 50, y: topY + 5, width: 200, height: 18),
        windowFrame: w.frame,
        ancestors: ["AXGroup", "AXWindow"]
    )
    #expect(TitleBarHitTester.hitTest(hitPoint: hit, target: w, evidence: ev))
}

@Test("Window with negative origin: direct window with buttons works")
func hitTestNegativeOriginDirectWindow() {
    let origin = CGPoint(x: -200, y: -100)
    let w = makeWindow(origin: origin)
    let (close, minimize, zoom) = standardButtons(w)
    let topY = origin.y
    let hit = CGPoint(x: origin.x + 300, y: topY + 14)
    let ev = HitTestEvidence.directWindow(
        windowFrame: w.frame,
        close: close,
        minimize: minimize,
        zoom: zoom
    )
    #expect(TitleBarHitTester.hitTest(hitPoint: hit, target: w, evidence: ev))
}

// MARK: - Hit test: NaN / invalid point / frame

@Test("NaN hit point fails")
func hitTestNaNPoint() {
    let w = makeWindow()
    let hit = CGPoint(x: CGFloat.nan, y: w.frame.origin.y + 10)
    let ev = HitTestEvidence.titleHit(
        titleFrame: CGRect(x: 150, y: w.frame.origin.y + 5, width: 200, height: 18),
        windowFrame: w.frame
    )
    #expect(!TitleBarHitTester.hitTest(hitPoint: hit, target: w, evidence: ev))
}

@Test("Infinite hit point fails")
func hitTestInfinitePoint() {
    let w = makeWindow()
    let hit = CGPoint(x: CGFloat.infinity, y: w.frame.origin.y + 10)
    let ev = HitTestEvidence.titleHit(
        titleFrame: CGRect(x: 150, y: w.frame.origin.y + 5, width: 200, height: 18),
        windowFrame: w.frame
    )
    #expect(!TitleBarHitTester.hitTest(hitPoint: hit, target: w, evidence: ev))
}

@Test("NaN button frame is rejected as invalid")
func hitTestNaNButtonFrame() {
    let w = makeWindow()
    let topY = w.frame.origin.y
    let hit = CGPoint(x: 400, y: topY + 14)
    let nanClose = CGRect(x: CGFloat.nan, y: topY + 7, width: 14, height: 14)
    let validMinimize = buttonFrame(window: w, xOffset: 27, yOffset: 7)
    let ev = HitTestEvidence.directWindow(
        windowFrame: w.frame,
        close: nanClose,
        minimize: validMinimize
    )
    // Only 1 valid button (NaN close is rejected) -> insufficient corroboration.
    #expect(!TitleBarHitTester.hitTest(hitPoint: hit, target: w, evidence: ev))
}

// MARK: - Hit test: ineligible target always fails

@Test("Ineligible target always fails regardless of evidence")
func hitTestIneligibleTarget() {
    let w = makeWindow(minimized: true)
    let hit = CGPoint(x: 400, y: w.frame.origin.y + 10)
    let ev = HitTestEvidence.titleHit(
        titleFrame: CGRect(x: 150, y: w.frame.origin.y + 5, width: 200, height: 18),
        windowFrame: w.frame
    )
    #expect(!TitleBarHitTester.hitTest(hitPoint: hit, target: w, evidence: ev))
}

// MARK: - Hit test: point outside window frame

@Test("Point outside window frame fails")
func hitTestPointOutsideWindow() {
    let w = makeWindow()
    let hit = CGPoint(x: 1000, y: 400)
    let ev = HitTestEvidence.titleHit(
        titleFrame: CGRect(x: 150, y: 205, width: 200, height: 18),
        windowFrame: w.frame
    )
    #expect(!TitleBarHitTester.hitTest(hitPoint: hit, target: w, evidence: ev))
}

// MARK: - Hit test: content role in content area fails

@Test("Content role (AXScrollArea) in content area fails")
func hitTestContentRole() {
    let w = makeWindow()
    let hit = CGPoint(x: 400, y: 500)
    let ev = HitTestEvidence(
        hitRole: "AXScrollArea",
        ancestorRoles: ["AXWindow"],
        hasTitleInPath: false,
        isLeafWindow: false
    )
    #expect(!TitleBarHitTester.hitTest(hitPoint: hit, target: w, evidence: ev))
}

// MARK: - Button frame validation

@Test("Button frame too small is rejected")
func buttonFrameTooSmall() {
    let w = makeWindow()
    let tiny = CGRect(x: w.frame.origin.x + 7, y: w.frame.origin.y + 7, width: 2, height: 2)
    #expect(!TitleBarHitTester.isValidButtonFrame(tiny, in: w.frame))
}

@Test("Button frame too large is rejected")
func buttonFrameTooLarge() {
    let w = makeWindow()
    let huge = CGRect(x: w.frame.origin.x, y: w.frame.origin.y, width: 200, height: 100)
    #expect(!TitleBarHitTester.isValidButtonFrame(huge, in: w.frame))
}

@Test("Button frame with NaN coordinates is rejected")
func buttonFrameNaN() {
    let w = makeWindow()
    let nan = CGRect(x: CGFloat.nan, y: 0, width: 14, height: 14)
    #expect(!TitleBarHitTester.isValidButtonFrame(nan, in: w.frame))
}

@Test("Valid button frame in title bar passes")
func buttonFrameValid() {
    let w = makeWindow()
    let valid = buttonFrame(window: w, xOffset: 7, yOffset: 7)
    #expect(TitleBarHitTester.isValidButtonFrame(valid, in: w.frame))
}

// MARK: - Geometry: isInTopArea correctness in AX top-left coordinates

@Test("isInTopArea uses frame.origin.y as top edge (AX top-left)")
func topAreaUsesOriginY() {
    let w = makeWindow(origin: CGPoint(x: 0, y: 100), size: CGSize(width: 800, height: 600))
    let topY: CGFloat = 100
    // Point at y=100 (top edge): IN top area.
    #expect(TitleBarHitTester.isInTopArea(hitPoint: CGPoint(x: 400, y: topY), target: w))
    // Point at y=127 (topY + 27): IN top area.
    #expect(TitleBarHitTester.isInTopArea(hitPoint: CGPoint(x: 400, y: topY + 27), target: w))
    // Point at y=128 (topY + 28 = titleBarHeight): NOT in top area.
    #expect(!TitleBarHitTester.isInTopArea(hitPoint: CGPoint(x: 400, y: topY + 28), target: w))
    // Point at y=699 (near bottom): NOT in top area.
    #expect(!TitleBarHitTester.isInTopArea(hitPoint: CGPoint(x: 400, y: 699), target: w))
    // Point at y=99 (above window): NOT in top area.
    #expect(!TitleBarHitTester.isInTopArea(hitPoint: CGPoint(x: 400, y: topY - 1), target: w))
}

@Test("isInTargetWindow uses CGRect.contains for AX coords")
func inTargetWindowUsesContains() {
    let w = makeWindow(origin: CGPoint(x: 100, y: 200), size: CGSize(width: 800, height: 600))
    // Inside.
    #expect(TitleBarHitTester.isInTargetWindow(hitPoint: CGPoint(x: 500, y: 400), target: w))
    // At origin (min-X,min-Y): CGRect.contains returns true (half-open interval includes origin).
    #expect(TitleBarHitTester.isInTargetWindow(hitPoint: CGPoint(x: 100, y: 200), target: w))
    // Just inside.
    // At max edge (exclusive in half-open interval): not contained.
    #expect(!TitleBarHitTester.isInTargetWindow(hitPoint: CGPoint(x: 900, y: 800), target: w))
    #expect(TitleBarHitTester.isInTargetWindow(hitPoint: CGPoint(x: 100.5, y: 200.5), target: w))
}

// MARK: - Hit test: title evidence must be in top area

@Test("Title evidence in content area (not top band) fails")
func hitTestTitleInContentArea() {
    let w = makeWindow()
    let midY = w.frame.origin.y + w.frame.height / 2
    let hit = CGPoint(x: 400, y: midY)
    let ev = HitTestEvidence.titleHit(
        titleFrame: CGRect(x: 150, y: midY - 5, width: 200, height: 18),
        windowFrame: w.frame
    )
    #expect(!TitleBarHitTester.hitTest(hitPoint: hit, target: w, evidence: ev))
}

// MARK: - Edge case: small window where bandHeight = 20% of height

@Test("Small window: top area is 20% of height, not full titleBarHeight")
func hitTestSmallWindowTopArea() {
    let w = makeWindow(size: CGSize(width: 200, height: 50))
    let topY = w.frame.origin.y
    // band = min(28, 50 * 0.2) = min(28, 10) = 10
    // At y = topY + 9: in top area.
    #expect(TitleBarHitTester.isInTopArea(hitPoint: CGPoint(x: 100, y: topY + 9), target: w))
    // At y = topY + 10: NOT in top area.
    #expect(!TitleBarHitTester.isInTopArea(hitPoint: CGPoint(x: 100, y: topY + 10), target: w))
}

// Regression checks from independent review: contradictory AX evidence must fail closed.
@Test func titleProofRequiresAnActualContainingFrame() {
    let w = makeWindow()
    let point = CGPoint(x: 400, y: 214)
    let frames: [CGRect?] = [nil, CGRect(x: 150, y: 205, width: 100, height: 18), CGRect(x: CGFloat.nan, y: 205, width: 100, height: 18)]
    for frame in frames {
        let evidence = HitTestEvidence(hitRole: "AXStaticText", ancestorRoles: ["AXWindow"], hasTitleInPath: true, titleElementFrame: frame)
        #expect(!TitleBarHitTester.hitTest(hitPoint: point, target: w, evidence: evidence))
    }
}

@Test func titleProofCannotBypassContentOrIncompleteAncestry() {
    let w = makeWindow()
    for parents in [[], ["AXWindow", "AXWebArea"], ["AXWindow", "AXScrollArea"], ["AXWindow", "AXSheet"], ["AXWindow", "AXMenu"], ["AXWindow", "AXUnknown"]] {
        let evidence = HitTestEvidence(hitRole: "AXStaticText", ancestorRoles: parents, hasTitleInPath: true, titleElementFrame: CGRect(x: 350, y: 205, width: 100, height: 18))
        #expect(!TitleBarHitTester.hitTest(hitPoint: CGPoint(x: 400, y: 214), target: w, evidence: evidence))
    }
}

@Test func duplicateOrMisalignedTrafficLightsAreNotCorroboration() {
    let w = makeWindow()
    let (close, minimize, _) = standardButtons(w)
    for second in [close, minimize.offsetBy(dx: 0, dy: 11)] {
        let evidence = HitTestEvidence.directWindow(windowFrame: w.frame, close: close, minimize: second)
        #expect(!TitleBarHitTester.hitTest(hitPoint: CGPoint(x: 400, y: 214), target: w, evidence: evidence))
    }
}

@Test func trafficLightFramesMustBeInsideTheTarget() {
    let w = makeWindow()
    let (_, minimize, _) = standardButtons(w)
    let partial = CGRect(x: w.frame.minX - 5, y: w.frame.minY + 7, width: 14, height: 14)
    let evidence = HitTestEvidence.directWindow(windowFrame: w.frame, close: partial, minimize: minimize)
    #expect(!TitleBarHitTester.hitTest(hitPoint: CGPoint(x: 400, y: 214), target: w, evidence: evidence))
}

@Test func windowBackgroundEvidenceMustNotConsumeTrafficLightClicks() {
    let w = makeWindow()
    let (close, minimize, zoom) = standardButtons(w)
    let evidence = HitTestEvidence.directWindow(windowFrame: w.frame, close: close, minimize: minimize, zoom: zoom)
    for button in [close, minimize, zoom] {
        #expect(!TitleBarHitTester.hitTest(hitPoint: CGPoint(x: button.midX, y: button.midY), target: w, evidence: evidence))
    }
}

@Test func directWindowFlagRequiresWindowRole() {
    let w = makeWindow()
    let (close, minimize, _) = standardButtons(w)
    let evidence = HitTestEvidence(hitRole: "AXStaticText", ancestorRoles: ["AXApplication"], isLeafWindow: true, closeButtonFrame: close, minimizeButtonFrame: minimize)
    #expect(!TitleBarHitTester.hitTest(hitPoint: CGPoint(x: 400, y: 214), target: w, evidence: evidence))
}

@Test func overflowingOrNegativeFrameSizesAreInvalid() {
    #expect(!makeWindow(size: CGSize(width: -800, height: 600)).isEligible)
    #expect(!makeWindow(origin: CGPoint(x: CGFloat.greatestFiniteMagnitude, y: 200), size: CGSize(width: CGFloat.greatestFiniteMagnitude, height: 600)).isEligible)
}

@Test func titleProofRejectsUnsupportedLeavesAndParents() {
    let w = makeWindow()
    let point = CGPoint(x: 400, y: 214)
    let frame = CGRect(x: 350, y: 205, width: 100, height: 18)
    for role in ["AXMenu", "AXSheet", "AXWebArea", "AXUnknown", "AXHelpTag", ""] {
        let evidence = HitTestEvidence(hitRole: role, ancestorRoles: ["AXWindow"], hasTitleInPath: true, titleElementFrame: frame)
        #expect(!TitleBarHitTester.hitTest(hitPoint: point, target: w, evidence: evidence))
    }
    for roles in [["AXGroup"], ["AXWindow", "AXHelpTag"]] {
        let evidence = HitTestEvidence(hitRole: "AXStaticText", ancestorRoles: roles, hasTitleInPath: true, titleElementFrame: frame)
        #expect(!TitleBarHitTester.hitTest(hitPoint: point, target: w, evidence: evidence))
    }
    let outside = HitTestEvidence(hitRole: "AXStaticText", ancestorRoles: ["AXWindow"], hasTitleInPath: true, titleElementFrame: CGRect(x: 0, y: 205, width: 1000, height: 18))
    #expect(!TitleBarHitTester.hitTest(hitPoint: point, target: w, evidence: outside))
}

@Test func backgroundProofRejectsOverlappingButtonsAndUnrelatedParents() {
    let w = makeWindow()
    let (close, minimize, _) = standardButtons(w)
    let overlap = HitTestEvidence.directWindow(windowFrame: w.frame, close: close, minimize: close.offsetBy(dx: 1, dy: 0))
    #expect(!TitleBarHitTester.hitTest(hitPoint: CGPoint(x: 400, y: 214), target: w, evidence: overlap))
    let wrongParent = HitTestEvidence.directWindow(windowFrame: w.frame, close: close, minimize: minimize, ancestors: ["AXSheet"])
    #expect(!TitleBarHitTester.hitTest(hitPoint: CGPoint(x: 400, y: 214), target: w, evidence: wrongParent))
}
