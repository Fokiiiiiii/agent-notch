import XCTest
@testable import AgentNotch

/// Scale settings are read from `UserDefaults`, which nothing prevents from
/// holding a value the app can't render. Measured before this guard existed:
/// `uiScale = 40` produced a 21600×10080 panel on a 1680×1050 screen — every
/// control, including the gear that would undo it, off-screen.
@MainActor
final class SettingsValidationTests: XCTestCase {
    // MARK: - Clamping

    func testValueInsideTheRangeIsKept() {
        XCTAssertEqual(AppSettings.clampedScale(1.15, into: AppSettings.uiScaleRange), 1.15, accuracy: 0.0001)
    }

    func testValueAboveTheRangeIsClampedDown() {
        XCTAssertEqual(
            AppSettings.clampedScale(40, into: AppSettings.uiScaleRange),
            AppSettings.uiScaleRange.upperBound,
            accuracy: 0.0001
        )
    }

    func testValueBelowTheRangeIsClampedUp() {
        XCTAssertEqual(
            AppSettings.clampedScale(-3, into: AppSettings.uiScaleRange),
            AppSettings.uiScaleRange.lowerBound,
            accuracy: 0.0001
        )
    }

    /// Zero would collapse the panel to nothing — as unrecoverable as the
    /// oversized case, and reachable by `defaults write … 0`.
    func testZeroIsClampedRatherThanCollapsingThePanel() {
        XCTAssertEqual(
            AppSettings.clampedScale(0, into: AppSettings.uiScaleRange),
            AppSettings.uiScaleRange.lowerBound,
            accuracy: 0.0001
        )
    }

    /// `defaults write` accepts `nan` and `inf`; both propagate through the
    /// layout maths and produce an unrenderable frame.
    func testNonFiniteValuesFallBackToTheDefault() {
        XCTAssertEqual(AppSettings.clampedScale(.nan, into: AppSettings.uiScaleRange), 1.0, accuracy: 0.0001)
        XCTAssertEqual(AppSettings.clampedScale(.infinity, into: AppSettings.uiScaleRange), 1.0, accuracy: 0.0001)
        XCTAssertEqual(AppSettings.clampedScale(-.infinity, into: AppSettings.uiScaleRange), 1.0, accuracy: 0.0001)
    }

    func testMissingValueFallsBackToTheDefault() {
        XCTAssertEqual(AppSettings.clampedScale(nil, into: AppSettings.uiScaleRange), 1.0, accuracy: 0.0001)
    }

    /// Every range must admit 1.0, since that's the fallback a corrupted or
    /// absent value lands on.
    func testEveryRangeContainsTheNeutralValue() {
        XCTAssertTrue(AppSettings.uiScaleRange.contains(1.0))
        XCTAssertTrue(AppSettings.cornerRadiusScaleRange.contains(1.0))
        XCTAssertTrue(AppSettings.animationSpeedScaleRange.contains(1.0))
    }

    // MARK: - Write path

    /// The setter is reachable from anywhere, not only the range-limited
    /// slider, so assigning out of range must correct itself rather than
    /// persisting a value the next launch would have to clamp anyway.
    func testAssigningAnOutOfRangeScaleCorrectsItself() {
        let settings = AppSettings.shared
        let original = settings.uiScale
        defer { settings.uiScale = original }

        settings.uiScale = 40
        XCTAssertEqual(settings.uiScale, AppSettings.uiScaleRange.upperBound, accuracy: 0.0001)

        settings.uiScale = -1
        XCTAssertEqual(settings.uiScale, AppSettings.uiScaleRange.lowerBound, accuracy: 0.0001)
    }

    /// …and what lands in `UserDefaults` is the corrected value, so a later
    /// launch reads something already valid.
    func testTheClampedValueIsWhatGetsPersisted() {
        let settings = AppSettings.shared
        let original = settings.uiScale
        defer { settings.uiScale = original }

        settings.uiScale = 99
        let stored = UserDefaults.standard.double(forKey: "agentnotch.uiScale")
        XCTAssertEqual(stored, AppSettings.uiScaleRange.upperBound, accuracy: 0.0001)
    }
}
