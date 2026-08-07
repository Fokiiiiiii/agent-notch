import XCTest
@testable import AgentNotch

/// Regression tests for `NotchWindowController.dashboardOpenSize(...)`, the
/// sizing calculation for the merged Media/Today/System Dashboard page
/// (`NotchView.DashboardCell`) — a single flat row-layout panel, not the
/// stacked-cards layout an earlier pass used. Exercises the pure, `static`
/// function directly — same pattern as `ScreenGeometryTests`' `computeClosedSize`
/// tests — without constructing a real `NotchWindowController`.
@MainActor
final class DashboardSizingTests: XCTestCase {
    func testDashboardOpenSizeBaseCase() {
        let size = NotchWindowController.dashboardOpenSize(width: 540, needsCalendarPermission: false, detailExpanded: false)
        XCTAssertEqual(size, CGSize(width: 540, height: NotchWindowController.dashboardBaseHeight))
    }

    func testDashboardOpenSizeAddsPermissionPromptExtra() {
        let granted = NotchWindowController.dashboardOpenSize(width: 540, needsCalendarPermission: false, detailExpanded: false)
        let needsPermission = NotchWindowController.dashboardOpenSize(width: 540, needsCalendarPermission: true, detailExpanded: false)
        XCTAssertEqual(needsPermission.height, granted.height + NotchWindowController.dashboardPermissionPromptExtra)
    }

    func testDashboardOpenSizeAddsDetailExpandedHeight() {
        let collapsed = NotchWindowController.dashboardOpenSize(width: 540, needsCalendarPermission: false, detailExpanded: false)
        let expanded = NotchWindowController.dashboardOpenSize(width: 540, needsCalendarPermission: false, detailExpanded: true)
        XCTAssertEqual(expanded.height, collapsed.height + NotchWindowController.dashboardDetailExpandedHeight)
    }

    func testDashboardOpenSizeCombinesPermissionAndDetailExtras() {
        let both = NotchWindowController.dashboardOpenSize(width: 540, needsCalendarPermission: true, detailExpanded: true)
        let expected = NotchWindowController.dashboardBaseHeight + NotchWindowController.dashboardPermissionPromptExtra + NotchWindowController.dashboardDetailExpandedHeight
        XCTAssertEqual(both.height, min(expected, NotchWindowController.dashboardMaxHeight))
    }

    func testDashboardOpenSizeCapsAtMaxHeight() {
        let size = NotchWindowController.dashboardOpenSize(width: 540, needsCalendarPermission: true, detailExpanded: true)
        XCTAssertLessThanOrEqual(size.height, NotchWindowController.dashboardMaxHeight)
    }

    func testDashboardOpenSizePreservesGivenWidth() {
        let size = NotchWindowController.dashboardOpenSize(width: 600, needsCalendarPermission: false, detailExpanded: false)
        XCTAssertEqual(size.width, 600)
    }
}
