import XCTest
@testable import AgentNotch

/// Where the panel is drawn and when the notch gets out of the way. Both are
/// invisible until they're wrong, and both are hard to notice on the single
/// built-in display a developer usually tests on — a second display's frame
/// has a non-zero (often negative) origin, and fullscreen detection only
/// matters once something is actually fullscreen.
@MainActor
final class PanelPlacementTests: XCTestCase {
    private func snapshot(frame: CGRect, isBuiltIn: Bool = true) -> ScreenSnapshot {
        ScreenSnapshot(
            frame: frame,
            safeAreaInsetsTop: 0,
            auxiliaryTopLeftWidth: nil,
            auxiliaryTopRightWidth: nil,
            isBuiltIn: isBuiltIn
        )
    }

    // MARK: - Placement

    /// The notch grows downward from the menu bar, so the panel's top edge
    /// must sit exactly on the screen's top edge — not its bottom, which is
    /// what a naive `origin.y` would give in AppKit's flipped coordinates.
    func testPanelIsFlushWithTheTopOfTheScreen() {
        let screen = snapshot(frame: CGRect(x: 0, y: 0, width: 1680, height: 1050))
        let rect = NotchWindowController.frame(for: CGSize(width: 540, height: 200), on: screen)
        XCTAssertEqual(rect.maxY, screen.frame.maxY, accuracy: 0.01)
    }

    func testPanelIsHorizontallyCentred() {
        let screen = snapshot(frame: CGRect(x: 0, y: 0, width: 1680, height: 1050))
        let rect = NotchWindowController.frame(for: CGSize(width: 540, height: 200), on: screen)
        XCTAssertEqual(rect.midX, screen.frame.midX, accuracy: 0.01)
    }

    /// A display arranged to the right of the primary has a positive origin;
    /// centring on width alone would put the panel on the wrong screen.
    func testPanelFollowsAScreenWithAPositiveOrigin() {
        let screen = snapshot(frame: CGRect(x: 1680, y: 0, width: 2560, height: 1440), isBuiltIn: false)
        let rect = NotchWindowController.frame(for: CGSize(width: 540, height: 200), on: screen)
        XCTAssertEqual(rect.midX, 1680 + 1280, accuracy: 0.01)
        XCTAssertEqual(rect.maxY, 1440, accuracy: 0.01)
    }

    /// Arranged to the *left* of the primary, the origin is negative — the
    /// case most likely to be missed.
    func testPanelFollowsAScreenWithANegativeOrigin() {
        let screen = snapshot(frame: CGRect(x: -2560, y: 0, width: 2560, height: 1440), isBuiltIn: false)
        let rect = NotchWindowController.frame(for: CGSize(width: 540, height: 200), on: screen)
        XCTAssertEqual(rect.midX, -1280, accuracy: 0.01)
        XCTAssertLessThan(rect.minX, 0)
    }

    /// A display mounted above the primary has a positive y origin, so the
    /// top edge is not simply the screen height.
    func testPanelFollowsAScreenWithAVerticalOffset() {
        let screen = snapshot(frame: CGRect(x: 0, y: 1050, width: 1920, height: 1080), isBuiltIn: false)
        let rect = NotchWindowController.frame(for: CGSize(width: 540, height: 200), on: screen)
        XCTAssertEqual(rect.maxY, 2130, accuracy: 0.01)
    }

    func testPanelKeepsTheRequestedSize() {
        let screen = snapshot(frame: CGRect(x: 0, y: 0, width: 1680, height: 1050))
        let size = CGSize(width: 470, height: 182)
        let rect = NotchWindowController.frame(for: size, on: screen)
        XCTAssertEqual(rect.size, size)
    }

    /// Growing the panel must extend it downward only — the top edge is
    /// anchored, which is what makes the open/close animation read as the
    /// panel unfolding out of the notch.
    func testGrowingThePanelExtendsDownwardOnly() {
        let screen = snapshot(frame: CGRect(x: 0, y: 0, width: 1680, height: 1050))
        let small = NotchWindowController.frame(for: CGSize(width: 540, height: 100), on: screen)
        let large = NotchWindowController.frame(for: CGSize(width: 540, height: 300), on: screen)
        XCTAssertEqual(small.maxY, large.maxY, accuracy: 0.01)
        XCTAssertLessThan(large.minY, small.minY)
    }

    // MARK: - Fullscreen detection

    private let screenFrame = CGRect(x: 0, y: 0, width: 1680, height: 1050)

    func testAWindowFillingTheScreenCountsAsFullscreen() {
        XCTAssertTrue(NotchWindowController.coversScreen(union: screenFrame, screenFrame: screenFrame))
    }

    /// The window server reports fullscreen windows a few points short of
    /// the screen, so an exact-match test would never fire.
    func testAWindowJustInsideTheToleranceStillCountsAsFullscreen() {
        let almost = CGRect(x: 0, y: 0, width: 1680 - 11, height: 1050 - 11)
        XCTAssertTrue(NotchWindowController.coversScreen(union: almost, screenFrame: screenFrame))
    }

    /// …and the tolerance must not be so generous that a merely large
    /// window hides the notch during ordinary use.
    func testAWindowOutsideTheToleranceIsNotFullscreen() {
        let large = CGRect(x: 0, y: 0, width: 1680 - 40, height: 1050 - 40)
        XCTAssertFalse(NotchWindowController.coversScreen(union: large, screenFrame: screenFrame))
    }

    /// Both dimensions have to qualify: a window as wide as the screen but
    /// only half its height is a normal window, not fullscreen.
    func testFullWidthButShortIsNotFullscreen() {
        let banner = CGRect(x: 0, y: 0, width: 1680, height: 525)
        XCTAssertFalse(NotchWindowController.coversScreen(union: banner, screenFrame: screenFrame))
    }

    func testFullHeightButNarrowIsNotFullscreen() {
        let column = CGRect(x: 0, y: 0, width: 600, height: 1050)
        XCTAssertFalse(NotchWindowController.coversScreen(union: column, screenFrame: screenFrame))
    }

    /// The union of several windows can exceed the screen (a window may
    /// straddle displays), which must still read as covering it.
    func testAUnionLargerThanTheScreenCountsAsFullscreen() {
        let oversized = CGRect(x: -100, y: -100, width: 2000, height: 1400)
        XCTAssertTrue(NotchWindowController.coversScreen(union: oversized, screenFrame: screenFrame))
    }

    /// The check is against the screen it's asked about, so the same window
    /// can be fullscreen on a small display and not on a large one.
    func testTheSameWindowIsJudgedPerScreen() {
        let window = CGRect(x: 0, y: 0, width: 1680, height: 1050)
        XCTAssertTrue(NotchWindowController.coversScreen(union: window, screenFrame: screenFrame))
        let bigger = CGRect(x: 0, y: 0, width: 3840, height: 2160)
        XCTAssertFalse(NotchWindowController.coversScreen(union: window, screenFrame: bigger))
    }
}
