import XCTest
@testable import AgentNotch

/// Regression tests for `NotchWindowController.dashboardOpenSize(...)`, the
/// sizing calculation for the Dashboard page (`NotchView.DashboardCell`) —
/// Media and Today side by side in one row, not the stacked-cards layout an
/// earlier pass used. Exercises the pure, `static` function directly — same
/// pattern as `ScreenGeometryTests`' `computeClosedSize` tests — without
/// constructing a real `NotchWindowController`.
@MainActor
final class DashboardSizingTests: XCTestCase {
    func testDashboardOpenSizeBaseCase() {
        let size = NotchWindowController.dashboardOpenSize(width: 540, detailExpanded: false)
        XCTAssertEqual(size, CGSize(width: 540, height: NotchWindowController.dashboardBaseHeight))
    }

    func testDashboardOpenSizeAddsDetailExpandedHeight() {
        let collapsed = NotchWindowController.dashboardOpenSize(width: 540, detailExpanded: false)
        let expanded = NotchWindowController.dashboardOpenSize(width: 540, detailExpanded: true)
        XCTAssertEqual(expanded.height, collapsed.height + NotchWindowController.dashboardDetailExpandedHeight)
    }

    func testDashboardOpenSizeCapsAtMaxHeight() {
        let size = NotchWindowController.dashboardOpenSize(width: 540, detailExpanded: true)
        XCTAssertLessThanOrEqual(size.height, NotchWindowController.dashboardMaxHeight)
    }

    /// The cap must sit above the tallest layout the formula can actually
    /// produce, not clip it — Dashboard has no scroll fallback, so a cap
    /// that bites would silently hide real content.
    func testDashboardMaxHeightExceedsWorstCaseLayout() {
        let worstCase = NotchWindowController.dashboardBaseHeight + NotchWindowController.dashboardDetailExpandedHeight
        XCTAssertGreaterThanOrEqual(NotchWindowController.dashboardMaxHeight, worstCase)
    }

    func testDashboardOpenSizePreservesGivenWidth() {
        let size = NotchWindowController.dashboardOpenSize(width: 600, detailExpanded: false)
        XCTAssertEqual(size.width, 600)
    }

    /// `DashboardMediaSection`'s 68pt artwork plus `DashboardCell`'s padding
    /// and the surrounding chrome need this much headroom — guards against
    /// the base height regressing below what the layout actually requires.
    func testDashboardBaseHeightAccountsForMediaArtworkAndChrome() {
        XCTAssertGreaterThanOrEqual(NotchWindowController.dashboardBaseHeight, 130)
    }
}
