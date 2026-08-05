import XCTest
@testable import AgentNotch

/// Regression tests for the `.hover` intermediate island mode (Phase 1 of
/// the NotchNook-style redesign): a lightweight peek shown after a further
/// dwell over the already-visible `.closed` notch, strictly between
/// `.closed` and `.open` in size, and always pre-empted by a pending
/// Attention item (approval/question/plan) via `showAttention()`.
///
/// These exercise the pure, static decision/size logic directly — no live
/// `NSPanel`/window/timers are constructed (`NotchWindowController` needs a
/// real screen to initialize, so it is intentionally not instantiated here,
/// matching the existing `ScreenGeometryTests` approach).
@MainActor
final class HoverStateTests: XCTestCase {

    // MARK: - shouldEnterHover

    func testShouldEnterHoverWhenIdleVisibleAndNotched() {
        XCTAssertTrue(NotchWindowController.shouldEnterHover(
            currentMode: .closed,
            shouldPersistVisible: true,
            isClickPinned: false,
            hasPendingAttention: false,
            hasRealNotch: true
        ))
    }

    func testShouldNotEnterHoverWithoutARealNotch() {
        // `.hover` is a NotchNook-style peek meant specifically for notched
        // Macs. A non-notched screen must never enter it, even when every
        // other condition would otherwise allow it — hovering there must
        // behave exactly as it did before `.hover` existed.
        XCTAssertFalse(NotchWindowController.shouldEnterHover(
            currentMode: .closed,
            shouldPersistVisible: true,
            isClickPinned: false,
            hasPendingAttention: false,
            hasRealNotch: false
        ))
    }

    func testShouldNotEnterHoverWhenAttentionIsPending() {
        // Approval/question/plan always wins over the lightweight peek —
        // those are surfaced directly via `showAttention()` instead.
        XCTAssertFalse(NotchWindowController.shouldEnterHover(
            currentMode: .closed,
            shouldPersistVisible: true,
            isClickPinned: false,
            hasPendingAttention: true,
            hasRealNotch: true
        ))
    }

    func testShouldNotEnterHoverWhileFullscreenSuppressed() {
        // Fullscreen suppression applies to Hover too, not just Open/Closed.
        XCTAssertFalse(NotchWindowController.shouldEnterHover(
            currentMode: .closed,
            shouldPersistVisible: false,
            isClickPinned: false,
            hasPendingAttention: false,
            hasRealNotch: true
        ))
    }

    func testShouldNotEnterHoverWhenClickPinnedOpen() {
        // A user-opened (click-pinned) panel must not be interrupted by a
        // stray hover-dwell timer resolving afterward.
        XCTAssertFalse(NotchWindowController.shouldEnterHover(
            currentMode: .closed,
            shouldPersistVisible: true,
            isClickPinned: true,
            hasPendingAttention: false,
            hasRealNotch: true
        ))
    }

    func testShouldNotEnterHoverFromNonClosedMode() {
        // Only a dwell starting from `.closed` may expand into `.hover`;
        // `.open`/`.notice`/already-`.hover` are left alone.
        for mode: IslandMode in [.hover, .notice, .open] {
            XCTAssertFalse(NotchWindowController.shouldEnterHover(
                currentMode: mode,
                shouldPersistVisible: true,
                isClickPinned: false,
                hasPendingAttention: false,
                hasRealNotch: true
            ), "expected \(mode) to not enter hover")
        }
    }

    func testShouldEnterHoverRequiresAllConditionsSimultaneously() {
        // Every failing input independently blocks the transition, even
        // when combined with otherwise-passing inputs.
        let failingCombinations: [(IslandMode, Bool, Bool, Bool, Bool)] = [
            (.open, true, false, false, true),
            (.closed, false, false, false, true),
            (.closed, true, true, false, true),
            (.closed, true, false, true, true),
            (.closed, true, false, false, false),
        ]
        for (mode, persist, pinned, attention, notch) in failingCombinations {
            XCTAssertFalse(NotchWindowController.shouldEnterHover(
                currentMode: mode,
                shouldPersistVisible: persist,
                isClickPinned: pinned,
                hasPendingAttention: attention,
                hasRealNotch: notch
            ))
        }
    }

    // MARK: - Hover size selection

    func testHoverSizeIsStrictlyBetweenClosedAndOpenWithoutNotch() {
        // Pinned regression values: `computeClosedSize`'s floor for a
        // typical built-in notch (see `ScreenGeometryTests`) and the fixed
        // `openSize` (540×206) declared alongside `hoverSize` in
        // `NotchWindowController`.
        let closedFloor = NotchWindowController.computeClosedSize(notchWidth: 200, notchHeight: 32)
        let openSize = CGSize(width: 540, height: 206)
        let hoverSize = NotchWindowController.computeHoverSize(notchWidth: 200, hasNotch: false)

        XCTAssertGreaterThan(hoverSize.width, closedFloor.width)
        XCTAssertLessThan(hoverSize.width, openSize.width)
        XCTAssertGreaterThan(hoverSize.height, closedFloor.height)
        XCTAssertLessThan(hoverSize.height, openSize.height)
    }

    func testHoverSizeIsFixedDefaultWithoutANotch() {
        // No physical notch: the plain original 320×90 peek, regardless of
        // whatever `notchWidth` fallback value happened to be measured.
        XCTAssertEqual(NotchWindowController.computeHoverSize(notchWidth: 200, hasNotch: false), CGSize(width: 320, height: 90))
        XCTAssertEqual(NotchWindowController.computeHoverSize(notchWidth: 999, hasNotch: false), CGSize(width: 320, height: 90))
    }

    func testHoverSizeWidensToMergeWithARealNotch() {
        // A real notch widens the pill so it visually merges with the
        // physical cutout (NotchNook reference look) instead of floating as
        // a narrower island beside it. Height is unaffected.
        let wideNotch = NotchWindowController.computeHoverSize(notchWidth: 300, hasNotch: true)
        XCTAssertGreaterThan(wideNotch.width, 320)
        XCTAssertEqual(wideNotch.height, 90)

        // A narrow notch must never shrink the pill below the non-notch default.
        let narrowNotch = NotchWindowController.computeHoverSize(notchWidth: 100, hasNotch: true)
        XCTAssertEqual(narrowNotch.width, 320)
    }

    func testHoverSizeStillFitsUnderOpenSizeWithAWideNotch() {
        let openSize = CGSize(width: 540, height: 206)
        let hoverSize = NotchWindowController.computeHoverSize(notchWidth: 300, hasNotch: true)
        XCTAssertLessThan(hoverSize.width, openSize.width)
    }

    // MARK: - One-row vs. two-row height

    func testHoverCompactHeightIsShorterThanTheTwoRowHeight() {
        // `HoverPeekView` only draws a second row when media is playing
        // *and* a session is tracked; every other combination (media-only,
        // session-only, or the empty-state row) is a single row and should
        // get the shorter `hoverCompactHeight`, not the full two-row height
        // baked into `computeHoverSize` — a fixed tall pill around one short
        // line was reported as looking visually unbalanced.
        let twoRowHeight = NotchWindowController.computeHoverSize(notchWidth: 200, hasNotch: false).height
        XCTAssertLessThan(NotchWindowController.hoverCompactHeight, twoRowHeight)
    }

    func testHoverCompactHeightIsStillTallerThanClosed() {
        let closedFloor = NotchWindowController.computeClosedSize(notchWidth: 200, notchHeight: 32)
        XCTAssertGreaterThan(NotchWindowController.hoverCompactHeight, closedFloor.height)
    }

    // MARK: - Notch top clearance

    func testNoTopClearanceWithoutARealNotch() {
        // Non-notched screens must be completely unaffected by
        // notch-awareness — this always resolves to 0 regardless of
        // whatever `notchHeight` fallback value happened to be measured.
        XCTAssertEqual(NotchWindowController.computeHoverTopClearance(notchHeight: 32, hasNotch: false), 0)
        XCTAssertEqual(NotchWindowController.computeHoverTopClearance(notchHeight: 999, hasNotch: false), 0)
    }

    func testTopClearanceExceedsNotchHeightOnARealNotch() {
        // Must reserve *at least* `notchHeight` of dead space above the
        // rows — `safeAreaInsetsTop` isn't guaranteed pixel-exact for the
        // housing's actual (rounded-corner) bottom edge, so a small safety
        // margin on top is required, not just the bare measured value.
        XCTAssertGreaterThan(NotchWindowController.computeHoverTopClearance(notchHeight: 32, hasNotch: true), 32)
        XCTAssertGreaterThan(NotchWindowController.computeHoverTopClearance(notchHeight: 37, hasNotch: true), 37)
    }

    // MARK: - Notch-aware content height (icon band + info text)

    func testHoverContentHeightExceedsTheIconBandAlone() {
        // Must leave room for the text below the icon band, not just the
        // band itself — otherwise `HoverPeekView`'s text would be clipped.
        let clearance: CGFloat = 43
        XCTAssertGreaterThan(NotchWindowController.computeHoverContentHeight(topClearance: clearance, isMediaPlaying: false), clearance)
        XCTAssertGreaterThan(NotchWindowController.computeHoverContentHeight(topClearance: clearance, isMediaPlaying: true), clearance)
    }

    func testHoverContentHeightGrowsMonotonicallyWithClearance() {
        // A taller measured notch (e.g. a wider-bezel future model) must
        // reserve a taller pill, not silently reuse a shorter fixed height.
        let shortNotch = NotchWindowController.computeHoverContentHeight(topClearance: 38, isMediaPlaying: false)
        let tallNotch = NotchWindowController.computeHoverContentHeight(topClearance: 43, isMediaPlaying: false)
        XCTAssertLessThan(shortNotch, tallNotch)
    }

    func testHoverContentHeightIsTallerWhilePlayingMedia() {
        // Media draws an extra artist line under the title (see
        // `HoverPeekView.primaryInfo`), so it needs more room than the
        // session/idle single-line case at the same clearance.
        let clearance: CGFloat = 43
        let sessionHeight = NotchWindowController.computeHoverContentHeight(topClearance: clearance, isMediaPlaying: false)
        let mediaHeight = NotchWindowController.computeHoverContentHeight(topClearance: clearance, isMediaPlaying: true)
        XCTAssertGreaterThan(mediaHeight, sessionHeight)
    }
}
