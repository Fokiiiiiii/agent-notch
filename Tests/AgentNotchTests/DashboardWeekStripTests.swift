import XCTest
@testable import AgentNotch

/// `centeredWeekStrip` is a pure `Calendar` function extracted from
/// `DashboardTodaySection`'s week strip — same "static purely-functional,
/// no SwiftUI dependency" pattern as
/// `NotchWindowController.computeClosedSize`, exercised directly here
/// without standing up any View.
final class DashboardWeekStripTests: XCTestCase {
    private var utcCalendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }

    private func date(_ year: Int, _ month: Int, _ day: Int) -> Date {
        var components = DateComponents()
        components.year = year
        components.month = month
        components.day = day
        components.hour = 12
        return utcCalendar.date(from: components)!
    }

    // MARK: - centeredWeekStrip

    func testCenteredWeekStripOfSevenIsCenteredOnReferenceDate() {
        let reference = date(2026, 8, 14)
        let days = centeredWeekStrip(around: reference, count: 7, calendar: utcCalendar)

        XCTAssertEqual(days.count, 7)
        XCTAssertEqual(days.map(\.offset), [-3, -2, -1, 0, 1, 2, 3])
        // The offset-0 entry must be the reference date itself.
        XCTAssertTrue(utcCalendar.isDate(days[3].date, inSameDayAs: reference))
    }

    func testCenteredWeekStripDatesAreConsecutiveAndOrdered() {
        let reference = date(2026, 8, 14)
        let days = centeredWeekStrip(around: reference, count: 7, calendar: utcCalendar)

        let expectedDays = [11, 12, 13, 14, 15, 16, 17]
        XCTAssertEqual(days.map { utcCalendar.component(.day, from: $0.date) }, expectedDays)
    }

    func testCenteredWeekStripHandlesMonthBoundary() {
        // Aug 1 2026 is a Saturday; centering on it must cross back into July.
        let reference = date(2026, 8, 1)
        let days = centeredWeekStrip(around: reference, count: 7, calendar: utcCalendar)

        XCTAssertEqual(days.count, 7)
        XCTAssertEqual(utcCalendar.component(.month, from: days.first!.date), 7)
        XCTAssertEqual(utcCalendar.component(.day, from: days.first!.date), 29)
        XCTAssertTrue(utcCalendar.isDate(days[3].date, inSameDayAs: reference))
    }

    func testCenteredWeekStripReturnsEmptyForNonPositiveCount() {
        XCTAssertEqual(centeredWeekStrip(around: Date(), count: 0, calendar: utcCalendar), [])
        XCTAssertEqual(centeredWeekStrip(around: Date(), count: -1, calendar: utcCalendar), [])
    }

    func testCenteredWeekStripOfFiveSkewsBeforeReference() {
        // Even counts can't split symmetrically; `before = (count-1)/2` rounds
        // down, so the extra day lands after the reference — pin this down
        // so a future refactor can't silently flip which side gets it.
        let reference = date(2026, 8, 14)
        let days = centeredWeekStrip(around: reference, count: 4, calendar: utcCalendar)

        XCTAssertEqual(days.map(\.offset), [-1, 0, 1, 2])
    }

    /// The strip renders five columns (`DashboardTodaySection.weekStripDays`);
    /// seven left each column too narrow for today's enlarged number.
    func testCenteredWeekStripOfFiveIsCenteredOnReferenceDate() {
        let reference = date(2026, 8, 14)
        let days = centeredWeekStrip(around: reference, count: 5, calendar: utcCalendar)

        XCTAssertEqual(days.map(\.offset), [-2, -1, 0, 1, 2])
        XCTAssertEqual(days.map { utcCalendar.component(.day, from: $0.date) }, [12, 13, 14, 15, 16])
    }
}
