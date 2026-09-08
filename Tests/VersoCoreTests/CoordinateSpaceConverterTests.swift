import Testing
import CoreGraphics
@testable import VersoCore

@Suite("CoordinateSpaceConverter")
struct CoordinateSpaceConverterTests {

    // MARK: - Fixtures

    let screenH1080: CGFloat = 1080

    let primaryDisplay = CGRect(x: 0, y: 0, width: 1920, height: 1080)
    let leftDisplay = CGRect(x: -1600, y: 0, width: 1600, height: 900)
    let rightDisplay = CGRect(x: 1920, y: -300, width: 2560, height: 1440)
    let aboveDisplay = CGRect(x: 0, y: 1080, width: 1920, height: 1200)
    let belowDisplay = CGRect(x: 0, y: -1080, width: 1920, height: 1080)

    var allDisplays: [CGRect] {
        [primaryDisplay, leftDisplay, rightDisplay, aboveDisplay, belowDisplay]
    }

    // MARK: - Round Trip Tests

    @Test("Round trip preserves rect")
    func roundTripRect() {
        let input = CGRect(x: 200, y: 300, width: 500, height: 400)
        let appKit = CoordinateSpaceConverter.toAppKit(input, screenH: screenH1080)
        #expect(appKit != nil)
        let backToQuartz = CoordinateSpaceConverter.toQuartz(appKit!, screenH: screenH1080)
        #expect(backToQuartz != nil)
        #expect(backToQuartz!.origin.x == input.origin.x)
        #expect(backToQuartz!.origin.y == input.origin.y)
        #expect(backToQuartz!.size.width == input.size.width)
        #expect(backToQuartz!.size.height == input.size.height)
    }

    @Test("Round trip preserves point dimensions")
    func roundTripPoint() {
        let input = CGPoint(x: 100, y: 200)
        let appKit = CoordinateSpaceConverter.pointToAppKit(input, screenH: screenH1080)
        #expect(appKit != nil)
        let backToQuartz = CoordinateSpaceConverter.pointToAppKit(appKit!, screenH: screenH1080)
        #expect(backToQuartz != nil)
        #expect(backToQuartz!.x == input.x)
        #expect(backToQuartz!.y == input.y)
    }

    // MARK: - Display Fixtures (All Directions)

    @Test("Window on primary display")
    func primaryDisplayWindow() {
        let quartz = CGRect(x: 100, y: 200, width: 500, height: 400)
        #expect(CoordinateSpaceConverter.isEligibleOverlayFrame(quartz, screenH: screenH1080, displayFrames: allDisplays))
    }

    @Test("Window on left display")
    func leftDisplayWindow() {
        let quartz = CGRect(x: -1000, y: 200, width: 500, height: 400)
        #expect(CoordinateSpaceConverter.isEligibleOverlayFrame(quartz, screenH: screenH1080, displayFrames: allDisplays))
    }

    @Test("Window on right display")
    func rightDisplayWindow() {
        let quartz = CGRect(x: 2000, y: 100, width: 600, height: 600)
        #expect(CoordinateSpaceConverter.isEligibleOverlayFrame(quartz, screenH: screenH1080, displayFrames: allDisplays))
    }

    @Test("Window on below display")
    func belowDisplayWindow() {
        let quartz = CGRect(x: 100, y: 1200, width: 500, height: 300)
        #expect(CoordinateSpaceConverter.isEligibleOverlayFrame(quartz, screenH: screenH1080, displayFrames: allDisplays))
    }

    @Test("Window on above display")
    func aboveDisplayWindow() {
        let quartz = CGRect(x: 100, y: -500, width: 500, height: 300)
        #expect(CoordinateSpaceConverter.isEligibleOverlayFrame(quartz, screenH: screenH1080, displayFrames: allDisplays))
    }

    // MARK: - Invalid Screen References

    @Test("Empty display frames rejected", arguments: [
        [CGRect](),
        [CGRect(x: 0, y: 0, width: -1, height: 100)],
        [CGRect(x: 0, y: 0, width: 100, height: 0)],
        [CGRect(x: CGFloat.infinity, y: 0, width: 100, height: 100)],
        [CGRect(x: CGFloat.greatestFiniteMagnitude, y: 0, width: CGFloat.greatestFiniteMagnitude, height: 1000)],
        [CGRect(x: 0, y: 0, width: CGFloat.greatestFiniteMagnitude, height: 1000)],
    ])
    func invalidDisplays(frames: [CGRect]) {
        let quartz = CGRect(x: 100, y: 200, width: 500, height: 400)
        #expect(!CoordinateSpaceConverter.isEligibleOverlayFrame(quartz, screenH: screenH1080, displayFrames: frames))
    }

    // MARK: - Tiny/Offscreen/Oversized Windows

    @Test("Tiny window rejected")
    func tinyWindow() {
        let quartz = CGRect(x: 100, y: 200, width: 49, height: 49)
        #expect(!CoordinateSpaceConverter.isEligibleOverlayFrame(quartz, screenH: screenH1080, displayFrames: allDisplays))
    }

    @Test("Fully offscreen window rejected")
    func offscreenWindow() {
        let quartz = CGRect(x: -5000, y: -5000, width: 500, height: 400)
        #expect(!CoordinateSpaceConverter.isEligibleOverlayFrame(quartz, screenH: screenH1080, displayFrames: allDisplays))
    }

    @Test("Oversized window rejected")
    func oversizedWindow() {
        let quartz = CGRect(x: 0, y: 0, width: 10000, height: 10000)
        #expect(!CoordinateSpaceConverter.isEligibleOverlayFrame(quartz, screenH: screenH1080, displayFrames: allDisplays))
    }

    // MARK: - Fullscreen Position Rejection

    @Test("Fullscreen position rejected")
    func fullscreenPosition() {
        // Match primary display exactly
        let quartz = CGRect(x: 0, y: 0, width: 1920, height: 1080)
        #expect(!CoordinateSpaceConverter.isEligibleOverlayFrame(quartz, screenH: screenH1080, displayFrames: allDisplays))
    }

    @Test("Shifted fullscreen accepted")
    func shiftedFullscreen() {
        // Same size but shifted - should be accepted
        let quartz = CGRect(x: 200, y: 100, width: 1920, height: 1080)
        #expect(CoordinateSpaceConverter.isEligibleOverlayFrame(quartz, screenH: screenH1080, displayFrames: allDisplays))
    }

    // MARK: - Raw Negative/Zero Sizes

    @Test("Negative width rejected", arguments: [-100.0, -0.001])
    func negativeWidth(w: CGFloat) {
        let rect = CGRect(x: 100, y: 200, width: w, height: 400)
        #expect(CoordinateSpaceConverter.toAppKit(rect, screenH: screenH1080) == nil)
        #expect(CoordinateSpaceConverter.toQuartz(rect, screenH: screenH1080) == nil)
    }

    @Test("Zero height rejected")
    func zeroHeight() {
        let rect = CGRect(x: 100, y: 200, width: 500, height: 0)
        #expect(CoordinateSpaceConverter.toAppKit(rect, screenH: screenH1080) == nil)
        #expect(CoordinateSpaceConverter.toQuartz(rect, screenH: screenH1080) == nil)
    }

    // MARK: - Overflow Regression

    @Test("Real output overflow returns nil")
    func overflowRegression() {
        let screenH = CGFloat.greatestFiniteMagnitude
        let rect = CGRect(
            x: 0,
            y: -CGFloat.greatestFiniteMagnitude / 2,
            width: 100,
            height: 100
        )
        #expect(CoordinateSpaceConverter.toAppKit(rect, screenH: screenH) == nil)
        #expect(CoordinateSpaceConverter.toQuartz(rect, screenH: screenH) == nil)
    }

    @Test("Point overflow returns nil")
    func pointOverflow() {
        let screenH = CGFloat.greatestFiniteMagnitude
        let point = CGPoint(x: 0, y: -CGFloat.greatestFiniteMagnitude)
        #expect(CoordinateSpaceConverter.pointToAppKit(point, screenH: screenH) == nil)
    }

    // MARK: - Invalid screenH

    @Test("Invalid screenH rejected", arguments: [0.0, -100.0, CGFloat.infinity, CGFloat.nan])
    func invalidScreenH(h: CGFloat) {
        let rect = CGRect(x: 100, y: 200, width: 500, height: 400)
        #expect(CoordinateSpaceConverter.toAppKit(rect, screenH: h) == nil)
        #expect(CoordinateSpaceConverter.toQuartz(rect, screenH: h) == nil)
        #expect(CoordinateSpaceConverter.pointToAppKit(CGPoint(x: 100, y: 200), screenH: h) == nil)
    }
}

private let desktopFixtures = [
    CGRect(x: 0, y: 0, width: 1920, height: 1080),
    CGRect(x: -1600, y: 0, width: 1600, height: 900),
    CGRect(x: 1920, y: -300, width: 2560, height: 1440),
    CGRect(x: 0, y: 1080, width: 1920, height: 1200),
    CGRect(x: 0, y: -1080, width: 1920, height: 1080)
]

@Test("Parent regression: display direction never changes point dimensions")
func parentDisplayGeometry() throws {
    let fixtures: [(CGRect, CGRect)] = [
        (CGRect(x: 100, y: 200, width: 500, height: 300), CGRect(x: 100, y: 580, width: 500, height: 300)),
        (CGRect(x: -1000, y: 200, width: 500, height: 400), CGRect(x: -1000, y: 480, width: 500, height: 400)),
        (CGRect(x: 2000, y: 100, width: 600, height: 600), CGRect(x: 2000, y: 380, width: 600, height: 600)),
        (CGRect(x: 100, y: -500, width: 500, height: 300), CGRect(x: 100, y: 1280, width: 500, height: 300)),
        (CGRect(x: 100, y: 1200, width: 500, height: 300), CGRect(x: 100, y: -420, width: 500, height: 300))
    ]
    for (quartz, appKit) in fixtures {
        #expect(CoordinateSpaceConverter.toAppKit(quartz, screenH: 1080) == appKit)
        #expect(CoordinateSpaceConverter.toQuartz(appKit, screenH: 1080) == quartz)
        #expect(CoordinateSpaceConverter.isEligibleOverlayFrame(quartz, screenH: 1080, displayFrames: desktopFixtures))
    }
    #expect(CoordinateSpaceConverter.pointToAppKit(CGPoint(x: -1600, y: -300), screenH: 1080) == CGPoint(x: -1600, y: 1380))
}

@Test("Parent regression: fullscreen rejection includes every display position")
func parentOverlayAdmission() throws {
    for display in desktopFixtures {
        let quartz = try #require(CoordinateSpaceConverter.toQuartz(display, screenH: 1080))
        #expect(!CoordinateSpaceConverter.isEligibleOverlayFrame(quartz, screenH: 1080, displayFrames: desktopFixtures))
    }
    let atFullscreenTolerance = CGRect(x: 2, y: 0, width: 1920, height: 1080)
    #expect(!CoordinateSpaceConverter.isEligibleOverlayFrame(atFullscreenTolerance, screenH: 1080, displayFrames: desktopFixtures))
    let shiftedScreenSize = CGRect(x: 200, y: 100, width: 1920, height: 1080)
    #expect(CoordinateSpaceConverter.isEligibleOverlayFrame(shiftedScreenSize, screenH: 1080, displayFrames: desktopFixtures))
    for frame in [CGRect(x: 15000, y: 0, width: 500, height: 400), CGRect(x: 100, y: 100, width: 20, height: 20), CGRect(x: 0, y: 0, width: CGFloat.greatestFiniteMagnitude / 4, height: 400)] {
        #expect(!CoordinateSpaceConverter.isEligibleOverlayFrame(frame, screenH: 1080, displayFrames: desktopFixtures))
    }
    #expect(!CoordinateSpaceConverter.isEligibleOverlayFrame(CGRect(x: 100, y: 100, width: 500, height: 400), screenH: 1080, displayFrames: []))
}

@Test("Parent regression: malformed and overflowing geometry is rejected")
func parentCoordinateTrustBoundary() {
    let extreme = CGFloat.greatestFiniteMagnitude
    let invalid = [CGRect(x: 0, y: 0, width: -1, height: 100), CGRect(x: 0, y: 0, width: 100, height: 0), CGRect(x: CGFloat.nan, y: 0, width: 100, height: 100), CGRect(x: 0, y: 0, width: CGFloat.infinity, height: 100)]
    for frame in invalid {
        #expect(CoordinateSpaceConverter.toAppKit(frame, screenH: 1080) == nil)
        #expect(CoordinateSpaceConverter.toQuartz(frame, screenH: 1080) == nil)
        #expect(!CoordinateSpaceConverter.isEligibleOverlayFrame(frame, screenH: 1080, displayFrames: desktopFixtures))
    }
    let overflowing = CGRect(x: 0, y: -extreme / 2, width: 100, height: 100)
    #expect(CoordinateSpaceConverter.toAppKit(overflowing, screenH: extreme) == nil)
    #expect(CoordinateSpaceConverter.toQuartz(overflowing, screenH: extreme) == nil)
    #expect(CoordinateSpaceConverter.pointToAppKit(CGPoint(x: 0, y: -extreme), screenH: extreme) == nil)
}
