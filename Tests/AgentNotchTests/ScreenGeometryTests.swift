import XCTest
@testable import AgentNotch

/// Regression tests for the screen-geometry abstraction introduced to fix
/// `NotchWindowController` never recomputing notch geometry when the screen
/// configuration changes (external display connect/disconnect, resolution,
/// or scaling changes). These exercise the pure, `ScreenSnapshot`-based
/// logic directly, without constructing any real `NSScreen`/window.
@MainActor
final class ScreenGeometryTests: XCTestCase {

    // MARK: - computeClosedSize

    func testComputeClosedSizeForTypicalNotch() {
        // A MacBook Pro-class notch: ~200pt wide, ~32pt safe-area height.
        let size = NotchWindowController.computeClosedSize(notchWidth: 200, notchHeight: 32)
        // width = max(200 + notchSafeMargin(32), compactMinContentWidth(160), 220) = 232
        XCTAssertEqual(size.width, 232)
        // height = max(32, 34) = 34
        XCTAssertEqual(size.height, 34)
    }

    func testComputeClosedSizeForNoNotchDisplay() {
        // A display with no notch reports 0 for both measurements.
        let size = NotchWindowController.computeClosedSize(notchWidth: 0, notchHeight: 0)
        // width floors at the larger of compactMinContentWidth(160)/220 => 220
        XCTAssertEqual(size.width, 220)
        // height floors at 34
        XCTAssertEqual(size.height, 34)
    }

    func testComputeClosedSizeForWideNotchAndTallSafeArea() {
        let size = NotchWindowController.computeClosedSize(notchWidth: 300, notchHeight: 40)
        XCTAssertEqual(size.width, 332)
        XCTAssertEqual(size.height, 40)
    }

    func testComputeClosedSizeClampsAgainstAbnormalNegativeMeasurements() {
        // Defends against the "occasional negative/garbage auxiliary area
        // measurement" case `init` already guards against upstream: even if
        // a negative value slipped through, the result must never go below
        // the documented floors.
        let size = NotchWindowController.computeClosedSize(notchWidth: -50, notchHeight: -10)
        XCTAssertEqual(size.width, 220)
        XCTAssertEqual(size.height, 34)
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
