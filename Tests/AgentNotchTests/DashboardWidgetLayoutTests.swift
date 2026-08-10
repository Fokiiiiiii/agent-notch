import XCTest
@testable import AgentNotch

/// `DashboardCell` builds its row from `DashboardWidget.resolved(from:)`, so
/// these cover the ordering/visibility rules that decide what actually gets
/// drawn — without standing up SwiftUI.
// `NotchWindowController`'s sizing helpers are MainActor-isolated, same as
// in `DashboardSizingTests`.
@MainActor
final class DashboardWidgetLayoutTests: XCTestCase {
    /// Opt-in widgets (the camera mirror) stay off for a user who has never
    /// touched Settings — turning the webcam on unprompted would be a
    /// privacy surprise, not a default.
    func testResolvedWithNoStoredConfigurationUsesShippedDefaultsOnly() {
        XCTAssertEqual(DashboardWidget.resolved(from: nil), [.media, .today])
    }

    func testResolvedIncludesAnOptInWidgetOnceItIsInTheStoredLayout() {
        let config = TabLayoutConfiguration(widgets: [
            WidgetLayoutItem(id: "media", order: 0),
            WidgetLayoutItem(id: "camera", order: 1),
            WidgetLayoutItem(id: "today", order: 2),
        ])
        XCTAssertEqual(DashboardWidget.resolved(from: config), [.media, .camera, .today])
    }

    /// `applying(to:)` appends unknown ids so a widget added in a later build
    /// reaches existing users — but that must not drag an opt-in widget in
    /// with it.
    func testResolvedDoesNotAppendAnOptInWidgetMissingFromTheStoredLayout() {
        let config = TabLayoutConfiguration(widgets: [
            WidgetLayoutItem(id: "today", order: 0),
        ])
        XCTAssertEqual(DashboardWidget.resolved(from: config), [.today, .media])
    }

    func testResolvedDropsAnOptInWidgetTurnedBackOff() {
        let config = TabLayoutConfiguration(widgets: [
            WidgetLayoutItem(id: "media", order: 0),
            WidgetLayoutItem(id: "camera", isVisible: false, order: 1),
        ])
        XCTAssertEqual(DashboardWidget.resolved(from: config), [.media, .today])
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

    func testOnlyMediaAbsorbsTheRemainingWidth() {
        XCTAssertTrue(DashboardWidget.media.absorbsLeftoverWidth)
        XCTAssertNil(DashboardWidget.media.preferredWidth)
        XCTAssertEqual(DashboardWidget.today.preferredWidth, 236)
        XCTAssertEqual(DashboardWidget.camera.preferredWidth, 132)
    }

    /// Even the flexible widget needs a concrete `layoutWidth`: it's what
    /// sizes the panel, as opposed to how the widget is drawn inside it.
    func testEveryWidgetDeclaresALayoutWidth() {
        for widget in DashboardWidget.allCases {
            XCTAssertGreaterThan(widget.layoutWidth, 0, "\(widget.id) has no layout width")
        }
    }

    // MARK: - Panel width

    private let generousMaximum: CGFloat = 2000

    /// The shipped two-widget arrangement must keep producing the width the
    /// panel had before it became content-driven.
    func testDefaultArrangementKeepsTheOriginalPanelWidth() {
        let width = NotchWindowController.dashboardWidth(for: [.media, .today], maximum: generousMaximum)
        XCTAssertEqual(width, 540, accuracy: 0.5)
    }

    func testAddingAWidgetWidensThePanel() {
        let two = NotchWindowController.dashboardWidth(for: [.media, .today], maximum: generousMaximum)
        let three = NotchWindowController.dashboardWidth(for: [.media, .today, .camera], maximum: generousMaximum)
        XCTAssertGreaterThan(three, two)
        // One more widget plus the divider that separates it.
        XCTAssertEqual(
            three - two,
            DashboardWidget.camera.layoutWidth + NotchWindowController.dashboardDividerWidth,
            accuracy: 0.5
        )
    }

    /// A single widget's own width is well under what the nook bar and page
    /// tabs need, so the panel has to stop shrinking before it gets there.
    func testASingleNarrowWidgetIsClampedToTheMinimumWidth() {
        let width = NotchWindowController.dashboardWidth(for: [.camera], maximum: generousMaximum)
        XCTAssertEqual(width, NotchWindowController.dashboardMinWidth, accuracy: 0.5)
    }

    func testEmptyArrangementUsesTheMinimumWidth() {
        XCTAssertEqual(
            NotchWindowController.dashboardWidth(for: [], maximum: generousMaximum),
            NotchWindowController.dashboardMinWidth,
            accuracy: 0.5
        )
    }

    func testWidthNeverExceedsTheScreenBudget() {
        let width = NotchWindowController.dashboardWidth(for: [.media, .today, .camera], maximum: 600)
        XCTAssertEqual(width, 600, accuracy: 0.5)
    }

    /// A maximum narrower than the floor would otherwise invert the clamp
    /// and return something smaller than the panel can render.
    func testAnImpossiblyNarrowMaximumStillYieldsTheMinimumWidth() {
        let width = NotchWindowController.dashboardWidth(for: [.media, .today], maximum: 100)
        XCTAssertEqual(width, NotchWindowController.dashboardMinWidth, accuracy: 0.5)
    }
}
