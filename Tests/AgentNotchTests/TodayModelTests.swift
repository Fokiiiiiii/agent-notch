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

    // MARK: - Reminders

    /// `now` for every reminder test: 2026-08-13 12:00 UTC.
    private var referenceNow: Date {
        DateComponents(calendar: utcCalendar, year: 2026, month: 8, day: 13, hour: 12).date!
    }

    private func makeReminder(
        _ id: String,
        hour: Int?,
        day: Int = 13,
        isCompleted: Bool = false
    ) -> RawReminderRecord {
        let due = hour.map { DateComponents(calendar: utcCalendar, year: 2026, month: 8, day: day, hour: $0).date! }
        return RawReminderRecord(id: id, title: "Reminder \(id)", dueDate: due, isCompleted: isCompleted)
    }

    private func filtered(_ records: [RawReminderRecord]) -> [TodayReminder] {
        TodayModel.filterAndSortToday(records, now: referenceNow, calendar: utcCalendar)
    }

    func testFilterExcludesCompletedReminders() {
        let result = filtered([
            makeReminder("done", hour: 9, isCompleted: true),
            makeReminder("open", hour: 9),
        ])
        XCTAssertEqual(result.map(\.id), ["open"])
    }

    /// A reminder with no due date has nothing to place it on today's
    /// timeline, so it can't be shown on a line that's about "today".
    func testFilterExcludesRemindersWithNoDueDate() {
        XCTAssertTrue(filtered([makeReminder("someday", hour: nil)]).isEmpty)
    }

    func testFilterExcludesRemindersDueAfterToday() {
        XCTAssertTrue(filtered([makeReminder("tomorrow", hour: 9, day: 14)]).isEmpty)
    }

    /// Yesterday's unfinished reminder is still outstanding, so it belongs
    /// on the line — flagged as overdue.
    func testFilterKeepsOverdueRemindersFromEarlierDays() {
        let result = filtered([makeReminder("late", hour: 9, day: 12)])
        XCTAssertEqual(result.map(\.id), ["late"])
        XCTAssertEqual(result.first?.isOverdue, true)
    }

    func testFilterMarksOverdueRelativeToNowNotToStartOfDay() {
        let result = filtered([
            makeReminder("past", hour: 9),
            makeReminder("future", hour: 18),
        ])
        XCTAssertEqual(result.map(\.id), ["past", "future"])
        XCTAssertEqual(result.map(\.isOverdue), [true, false])
    }

    func testFilterSortsBySoonestDueFirst() {
        let result = filtered([
            makeReminder("c", hour: 20),
            makeReminder("a", hour: 8),
            makeReminder("b", hour: 14),
        ])
        XCTAssertEqual(result.map(\.id), ["a", "b", "c"])
    }

    func testFilterCapsAtTheDisplayLimit() {
        let records = (0..<10).map { makeReminder("r\($0)", hour: $0 % 24) }
        XCTAssertEqual(filtered(records).count, TodayModel.reminderDisplayLimit)
    }
}
