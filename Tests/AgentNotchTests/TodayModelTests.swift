import XCTest
@testable import AgentNotch

@MainActor
final class TodayModelTests: XCTestCase {
    /// `TodayModel` used to only refresh from `init()`/`requestAccess()`, so
    /// it never picked up a midnight rollover or an out-of-band calendar
    /// edit. Regression test: confirm the periodic timer and the
    /// `.EKEventStoreChanged` subscription are both wired up on init.
    /// (Mirror is used because these are private implementation details —
    /// this only asserts the *shape* of the fix, not its exact interval.)
    func testInitWiresUpPeriodicRefreshAndEventStoreChangeSubscription() {
        let model = TodayModel()
        let mirror = Mirror(reflecting: model)

        let timer = mirror.children.first { $0.label == "timer" }?.value
        let storeChangeObserver = mirror.children.first { $0.label == "storeChangeObserver" }?.value

        XCTAssertNotNil(timer, "expected a periodic refresh timer to be set up in init()")
        XCTAssertNotNil(storeChangeObserver, "expected an .EKEventStoreChanged subscription to be set up in init()")

        // AnyCancellable? children show up as Optional(AnyCancellable) rather
        // than nil when actually assigned.
        if let timer {
            XCTAssertFalse(String(describing: timer).contains("nil"))
        }
        if let storeChangeObserver {
            XCTAssertFalse(String(describing: storeChangeObserver).contains("nil"))
        }
    }

    // MARK: - events(on:in:)

    private var utcCalendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }

    private func makeEvent(_ id: String, _ year: Int, _ month: Int, _ day: Int, _ hour: Int) -> TodayEvent {
        var components = DateComponents()
        components.year = year
        components.month = month
        components.day = day
        components.hour = hour
        let start = utcCalendar.date(from: components)!
        return TodayEvent(
            id: id,
            startDate: start,
            endDate: start.addingTimeInterval(3600),
            title: "Event \(id)",
            calendar: "Work",
            location: nil,
            attendeeCount: nil
        )
    }

    /// The week strip marks days and shows an agenda for whichever day is
    /// centered, so this has to select by calendar day rather than by
    /// "today" — that's what lets a scrolled-to day show its own events.
    func testEventsOnDateSelectsOnlyThatCalendarDay() {
        let events = [
            makeEvent("a", 2026, 8, 13, 9),
            makeEvent("b", 2026, 8, 14, 10),
            makeEvent("c", 2026, 8, 14, 16),
            makeEvent("d", 2026, 8, 15, 11),
        ]
        let target = makeEvent("x", 2026, 8, 14, 0).startDate

        let matches = TodayModel.events(on: target, in: events, calendar: utcCalendar)

        XCTAssertEqual(matches.map(\.id), ["b", "c"])
    }

    func testEventsOnDateSortsByStartTime() {
        let events = [
            makeEvent("late", 2026, 8, 14, 18),
            makeEvent("early", 2026, 8, 14, 8),
            makeEvent("mid", 2026, 8, 14, 12),
        ]
        let target = makeEvent("x", 2026, 8, 14, 0).startDate

        let matches = TodayModel.events(on: target, in: events, calendar: utcCalendar)

        XCTAssertEqual(matches.map(\.id), ["early", "mid", "late"])
    }

    func testEventsOnDateReturnsEmptyForADayWithNothingScheduled() {
        let events = [makeEvent("a", 2026, 8, 13, 9)]
        let target = makeEvent("x", 2026, 8, 14, 0).startDate

        XCTAssertTrue(TodayModel.events(on: target, in: events, calendar: utcCalendar).isEmpty)
    }
}
