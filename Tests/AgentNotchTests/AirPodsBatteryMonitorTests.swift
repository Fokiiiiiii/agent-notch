import XCTest
@testable import AgentNotch

/// Covers the label logic only. `readConnectedAirPods()` walks real paired
/// Bluetooth devices through private API and can't be exercised without
/// hardware, so it's verified by hand.
final class AirPodsBatteryMonitorTests: XCTestCase {
    private func battery(
        single: Int? = nil,
        left: Int? = nil,
        right: Int? = nil,
        caseLevel: Int? = nil
    ) -> AirPodsBattery {
        AirPodsBattery(name: "AirPods", single: single, left: left, right: right, caseLevel: caseLevel)
    }

    func testSingleBatteryDeviceReportsItsOwnLevel() {
        XCTAssertEqual(AirPodsBatteryMonitor.summaryLabel(for: battery(single: 72)), "72%")
    }

    /// There's no room for "L 80% R 65%" beside the Mac's own battery, and
    /// the lower earbud is the one that decides when playback stops.
    func testEarbudsCollapseToTheLowerSide() {
        XCTAssertEqual(AirPodsBatteryMonitor.summaryLabel(for: battery(left: 80, right: 65)), "65%")
        XCTAssertEqual(AirPodsBatteryMonitor.summaryLabel(for: battery(left: 40, right: 90)), "40%")
    }

    func testOneEarbudReportingIsEnough() {
        XCTAssertEqual(AirPodsBatteryMonitor.summaryLabel(for: battery(left: 55)), "55%")
        XCTAssertEqual(AirPodsBatteryMonitor.summaryLabel(for: battery(right: 33)), "33%")
    }

    /// `single` wins even when earbud levels are also present: a device
    /// reporting both is describing itself as one battery.
    func testSingleTakesPrecedenceOverEarbudLevels() {
        XCTAssertEqual(AirPodsBatteryMonitor.summaryLabel(for: battery(single: 90, left: 10, right: 20)), "90%")
    }

    /// The case's level is the last resort — it's the one reading that says
    /// nothing about whether you can keep listening right now.
    func testCaseLevelIsUsedOnlyWhenNothingElseReports() {
        XCTAssertEqual(AirPodsBatteryMonitor.summaryLabel(for: battery(caseLevel: 47)), "47%")
        XCTAssertEqual(AirPodsBatteryMonitor.summaryLabel(for: battery(left: 60, caseLevel: 47)), "60%")
    }

    /// Drives whether the indicator renders at all — with no readings there
    /// is nothing to show, and an empty slot would be worse than none.
    func testLabelIsNilWhenNothingReports() {
        XCTAssertNil(AirPodsBatteryMonitor.summaryLabel(for: battery()))
        XCTAssertFalse(battery().hasAnyReading)
    }

    func testHasAnyReadingIsTrueForEachIndividualField() {
        XCTAssertTrue(battery(single: 1).hasAnyReading)
        XCTAssertTrue(battery(left: 1).hasAnyReading)
        XCTAssertTrue(battery(right: 1).hasAnyReading)
        XCTAssertTrue(battery(caseLevel: 1).hasAnyReading)
    }
}
