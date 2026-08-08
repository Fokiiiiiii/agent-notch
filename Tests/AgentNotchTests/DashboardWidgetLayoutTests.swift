import XCTest
@testable import AgentNotch

/// `DashboardCell` builds its row from `DashboardWidget.resolved(from:)`, so
/// these cover the ordering/visibility rules that decide what actually gets
/// drawn — without standing up SwiftUI.
final class DashboardWidgetLayoutTests: XCTestCase {
    func testResolvedWithNoStoredConfigurationUsesShippedOrder() {
        XCTAssertEqual(DashboardWidget.resolved(from: nil), [.media, .today])
    }

    func testResolvedRespectsStoredOrder() {
        let config = TabLayoutConfiguration(widgets: [
            WidgetLayoutItem(id: "today", order: 0),
            WidgetLayoutItem(id: "media", order: 1),
        ])
        XCTAssertEqual(DashboardWidget.resolved(from: config), [.today, .media])
    }

    func testResolvedDropsHiddenWidgets() {
        let config = TabLayoutConfiguration(widgets: [
            WidgetLayoutItem(id: "media", isVisible: false, order: 0),
            WidgetLayoutItem(id: "today", order: 1),
        ])
        XCTAssertEqual(DashboardWidget.resolved(from: config), [.today])
    }

    /// Every widget hidden is a state the Nook tab allows, and `DashboardCell`
    /// has a dedicated empty state for it — so this must resolve to nothing
    /// rather than silently falling back to the defaults.
    func testResolvedCanBeEmptyWhenEverythingIsHidden() {
        let config = TabLayoutConfiguration(widgets: [
            WidgetLayoutItem(id: "media", isVisible: false, order: 0),
            WidgetLayoutItem(id: "today", isVisible: false, order: 1),
        ])
        XCTAssertEqual(DashboardWidget.resolved(from: config), [])
    }

    /// A layout written by an older/newer build can name a widget this one
    /// doesn't have; it must be ignored rather than crashing or blanking the
    /// row.
    func testResolvedIgnoresUnknownWidgetIds() {
        let config = TabLayoutConfiguration(widgets: [
            WidgetLayoutItem(id: "timer", order: 0),
            WidgetLayoutItem(id: "today", order: 1),
        ])
        XCTAssertEqual(DashboardWidget.resolved(from: config), [.today, .media])
    }

    /// `applying(to:)` appends ids it has never seen, which is what keeps a
    /// widget added in a later build from being invisible to users who
    /// already have a stored layout.
    func testResolvedAppendsWidgetsMissingFromStoredLayout() {
        let config = TabLayoutConfiguration(widgets: [
            WidgetLayoutItem(id: "today", order: 0),
        ])
        XCTAssertEqual(DashboardWidget.resolved(from: config), [.today, .media])
    }

    func testOnlyTodayDeclaresAFixedWidth() {
        XCTAssertNil(DashboardWidget.media.preferredWidth)
        XCTAssertEqual(DashboardWidget.today.preferredWidth, 236)
    }
}
