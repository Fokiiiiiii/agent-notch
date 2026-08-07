import XCTest
@testable import AgentNotch

/// Regression tests for `NotchWindowController.dashboardOpenSize(...)`, the
/// sizing calculation for the merged Media/Today/System Dashboard page
/// (`NotchView.DashboardCell`). Exercises the pure, `static` function
/// directly — same pattern as `ScreenGeometryTests`' `computeClosedSize`
/// tests — without constructing a real `NotchWindowController`.
@MainActor
final class DashboardSizingTests: XCTestCase {
    func testDashboardOpenSizeWithNoEventsAndCollapsedDetail() {
        let size = NotchWindowController.dashboardOpenSize(width: 540, eventCount: 0, needsCalendarPermission: false, detailExpanded: false)
        XCTAssertEqual(size, CGSize(width: 540, height: NotchWindowController.dashboardBaseHeight))
    }

    func testDashboardOpenSizeGrowsPerEventUpToTwo() {
        let zero = NotchWindowController.dashboardOpenSize(width: 540, eventCount: 0, needsCalendarPermission: false, detailExpanded: false)
        let one = NotchWindowController.dashboardOpenSize(width: 540, eventCount: 1, needsCalendarPermission: false, detailExpanded: false)
        let two = NotchWindowController.dashboardOpenSize(width: 540, eventCount: 2, needsCalendarPermission: false, detailExpanded: false)
        let three = NotchWindowController.dashboardOpenSize(width: 540, eventCount: 3, needsCalendarPermission: false, detailExpanded: false)

        XCTAssertEqual(one.height, zero.height + NotchWindowController.dashboardEventRowHeight)
        XCTAssertEqual(two.height, one.height + NotchWindowController.dashboardEventRowHeight)
        // `TodayCell` only ever renders `model.events.prefix(2)`, so a 3rd
        // event must not grow the panel further.
        XCTAssertEqual(three.height, two.height)
    }

    func testDashboardOpenSizeIgnoresEventCountWhenCalendarPermissionNeeded() {
        // The "grant calendar access" prompt replaces the events list
        // entirely, so event count (which can't be known without access
        // anyway) must not also add height on top of the prompt's own extra.
        let noEvents = NotchWindowController.dashboardOpenSize(width: 540, eventCount: 0, needsCalendarPermission: true, detailExpanded: false)
        let withEvents = NotchWindowController.dashboardOpenSize(width: 540, eventCount: 2, needsCalendarPermission: true, detailExpanded: false)
        XCTAssertEqual(noEvents.height, withEvents.height)
        XCTAssertEqual(noEvents.height, NotchWindowController.dashboardBaseHeight + NotchWindowController.dashboardPermissionPromptExtra)
    }

    func testDashboardOpenSizeAddsDetailExpandedHeight() {
        let collapsed = NotchWindowController.dashboardOpenSize(width: 540, eventCount: 0, needsCalendarPermission: false, detailExpanded: false)
        let expanded = NotchWindowController.dashboardOpenSize(width: 540, eventCount: 0, needsCalendarPermission: false, detailExpanded: true)
        XCTAssertEqual(expanded.height, collapsed.height + NotchWindowController.dashboardDetailExpandedHeight)
    }

    func testDashboardOpenSizeCapsAtMaxHeight() {
        let size = NotchWindowController.dashboardOpenSize(width: 540, eventCount: 2, needsCalendarPermission: true, detailExpanded: true)
        XCTAssertLessThanOrEqual(size.height, NotchWindowController.dashboardMaxHeight)
    }

    func testDashboardOpenSizeClampsNegativeEventCount() {
        // Defensive: a negative count shouldn't be able to subtract height.
        let zero = NotchWindowController.dashboardOpenSize(width: 540, eventCount: 0, needsCalendarPermission: false, detailExpanded: false)
        let negative = NotchWindowController.dashboardOpenSize(width: 540, eventCount: -1, needsCalendarPermission: false, detailExpanded: false)
        XCTAssertEqual(negative.height, zero.height)
    }

    func testDashboardOpenSizePreservesGivenWidth() {
        let size = NotchWindowController.dashboardOpenSize(width: 600, eventCount: 0, needsCalendarPermission: false, detailExpanded: false)
        XCTAssertEqual(size.width, 600)
    }
}
