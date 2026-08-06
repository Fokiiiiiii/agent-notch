import XCTest
@testable import AgentNotch

/// Regression tests for the screen-geometry abstraction introduced to fix
/// `NotchWindowController` never recomputing notch geometry when the screen
/// configuration changes (external display connect/disconnect, resolution,
/// or scaling changes). These exercise the pure, `ScreenSnapshot`-based
/// logic directly, without constructing any real `NSScreen`/window.
@MainActor
final class ScreenGeometryTests: XCTestCase {

    // MARK: - computeClosedSize (hasNotch: false — non-notched Macs must be byte-identical to before)

    func testComputeClosedSizeForTypicalNotch() {
        // A MacBook Pro-class notch: ~200pt wide, ~32pt safe-area height.
        let size = NotchWindowController.computeClosedSize(notchWidth: 200, notchHeight: 32, hasNotch: false)
        // width = max(200 + notchSafeMargin(32), compactMinContentWidth(160), 220) = 232
        XCTAssertEqual(size.width, 232)
        // height = max(32, 34) = 34
        XCTAssertEqual(size.height, 34)
    }

    func testComputeClosedSizeForNoNotchDisplay() {
        // A display with no notch reports 0 for both measurements.
        let size = NotchWindowController.computeClosedSize(notchWidth: 0, notchHeight: 0, hasNotch: false)
        // width floors at the larger of compactMinContentWidth(160)/220 => 220
        XCTAssertEqual(size.width, 220)
        // height floors at 34
        XCTAssertEqual(size.height, 34)
    }

    func testComputeClosedSizeForWideNotchAndTallSafeArea() {
        let size = NotchWindowController.computeClosedSize(notchWidth: 300, notchHeight: 40, hasNotch: false)
        XCTAssertEqual(size.width, 332)
        XCTAssertEqual(size.height, 40)
    }

    func testComputeClosedSizeClampsAgainstAbnormalNegativeMeasurements() {
        // Defends against the "occasional negative/garbage auxiliary area
        // measurement" case `init` already guards against upstream: even if
        // a negative value slipped through, the result must never go below
        // the documented floors.
        let size = NotchWindowController.computeClosedSize(notchWidth: -50, notchHeight: -10, hasNotch: false)
        XCTAssertEqual(size.width, 220)
        XCTAssertEqual(size.height, 34)
    }

    // MARK: - computeClosedSize (hasNotch: true — hugs the physical cutout)

    func testComputeClosedSizeHugsRealNotchTighterThanNonNotchedFallback() {
        // Typical 14"/16" MBP notch: 200×37.
        let size = NotchWindowController.computeClosedSize(notchWidth: 200, notchHeight: 37, hasNotch: true)
        // width = max(200 + notchHuggingMargin(16), compactMinContentWidth(160)) = 216 — no 220 floor.
        XCTAssertEqual(size.width, 216)
        XCTAssertEqual(size.height, 37)
    }

    func testComputeClosedSizeForAirNotchIsNarrowerThanNonNotchedFloor() {
        // Air-class notch: 180×37. Pins down that the two branches really are
        // different formulas, not just different inputs into the same one —
        // this width must fall *below* the non-notched fallback's 220pt floor.
        let hugging = NotchWindowController.computeClosedSize(notchWidth: 180, notchHeight: 37, hasNotch: true)
        let nonNotchedFloor = NotchWindowController.computeClosedSize(notchWidth: 180, notchHeight: 37, hasNotch: false)
        XCTAssertEqual(hugging.width, 196)
        XCTAssertLessThan(hugging.width, nonNotchedFloor.width)
    }

    func testComputeClosedSizeHugsStillRespectsMinContentWidthFloor() {
        // An implausibly narrow virtual notch must still floor at
        // compactMinContentWidth so compact-mode content never clips.
        let size = NotchWindowController.computeClosedSize(notchWidth: 100, notchHeight: 37, hasNotch: true)
        XCTAssertEqual(size.width, 160)
        XCTAssertEqual(size.height, 37)
    }

    // MARK: - selectScreenIndex(from:) — mockable stand-in for isBuiltInDisplay-driven selection

    private func snapshot(isBuiltIn: Bool, safeAreaInsetsTop: CGFloat, originX: CGFloat = 0) -> ScreenSnapshot {
        ScreenSnapshot(
            frame: CGRect(x: originX, y: 0, width: 1440, height: 900),
            safeAreaInsetsTop: safeAreaInsetsTop,
            auxiliaryTopLeftWidth: nil,
            auxiliaryTopRightWidth: nil,
            isBuiltIn: isBuiltIn
        )
    }

    func testSelectScreenIndexPrefersBuiltInWithNotchOverEverything() {
        let snapshots = [
            snapshot(isBuiltIn: false, safeAreaInsetsTop: 0, originX: 0),      // plain external
            snapshot(isBuiltIn: true, safeAreaInsetsTop: 32, originX: 100),    // built-in w/ notch
            snapshot(isBuiltIn: false, safeAreaInsetsTop: 20, originX: 200),   // external reporting a notch-like inset
        ]
        XCTAssertEqual(NotchWindowController.selectScreenIndex(from: snapshots), 1)
    }

    func testSelectScreenIndexPrefersBuiltInWithoutNotchOverExternalNotch() {
        // Regression guard: a notch-less built-in display (older MacBook)
        // must still be preferred over an external monitor that happens to
        // report a nonzero safe-area inset.
        let snapshots = [
            snapshot(isBuiltIn: false, safeAreaInsetsTop: 20, originX: 0),  // external w/ notch-like inset
            snapshot(isBuiltIn: true, safeAreaInsetsTop: 0, originX: 100),  // built-in, no notch
        ]
        XCTAssertEqual(NotchWindowController.selectScreenIndex(from: snapshots), 1)
    }

    func testSelectScreenIndexFallsBackToAnyNotchWhenNoBuiltInPresent() {
        // e.g. a Mac mini/Mac Studio driving only external displays.
        let snapshots = [
            snapshot(isBuiltIn: false, safeAreaInsetsTop: 0, originX: 0),
            snapshot(isBuiltIn: false, safeAreaInsetsTop: 24, originX: 100),
        ]
        XCTAssertEqual(NotchWindowController.selectScreenIndex(from: snapshots), 1)
    }

    func testSelectScreenIndexReturnsNilWhenNothingMatches() {
        // Caller (`selectScreen()`) is expected to fall back to
        // `NSScreen.main`/first in this case.
        let snapshots = [
            snapshot(isBuiltIn: false, safeAreaInsetsTop: 0, originX: 0),
            snapshot(isBuiltIn: false, safeAreaInsetsTop: 0, originX: 100),
        ]
        XCTAssertNil(NotchWindowController.selectScreenIndex(from: snapshots))
    }

    func testSelectScreenIndexReturnsNilForEmptyInput() {
        XCTAssertNil(NotchWindowController.selectScreenIndex(from: []))
    }

    func testSelectScreenIndexPicksFirstMatchWhenMultipleBuiltInNotchScreensExist() {
        // Not physically realistic (two built-in displays), but pins down
        // "first match wins" ordering behavior.
        let snapshots = [
            snapshot(isBuiltIn: true, safeAreaInsetsTop: 32, originX: 0),
            snapshot(isBuiltIn: true, safeAreaInsetsTop: 32, originX: 100),
        ]
        XCTAssertEqual(NotchWindowController.selectScreenIndex(from: snapshots), 0)
    }
}
