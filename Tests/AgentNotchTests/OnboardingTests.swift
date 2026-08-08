import XCTest
@testable import AgentNotch

/// The welcome screen's content list is built by a plain function so it can
/// be checked without standing up the view or a window.
final class OnboardingTests: XCTestCase {
    func testTipsCoverAllFourGestures() {
        let tips = onboardingTips()
        XCTAssertEqual(tips.count, 4)
        // Every tip needs a glyph and a caption — a blank one would render
        // as an empty column.
        for tip in tips {
            XCTAssertFalse(tip.icon.isEmpty)
            XCTAssertFalse(tip.text.isEmpty)
        }
    }

    func testTipsHaveDistinctIconsAndText() {
        let tips = onboardingTips()
        XCTAssertEqual(Set(tips.map(\.icon)).count, tips.count)
        XCTAssertEqual(Set(tips.map(\.text)).count, tips.count)
    }
}

@MainActor
final class OnboardingSettingsTests: XCTestCase {
    private let key = "agentnotch.hasSeenOnboarding"

    /// The welcome screen must only appear once on its own; the flag that
    /// decides that has to survive a relaunch, so verify the real
    /// `UserDefaults` round-trip rather than just the in-memory property.
    func testHasSeenOnboardingPersistsToUserDefaults() {
        let original = AppSettings.shared.hasSeenOnboarding
        defer { AppSettings.shared.hasSeenOnboarding = original }

        AppSettings.shared.hasSeenOnboarding = true
        XCTAssertEqual(UserDefaults.standard.object(forKey: key) as? Bool, true)

        AppSettings.shared.hasSeenOnboarding = false
        XCTAssertEqual(UserDefaults.standard.object(forKey: key) as? Bool, false)
    }
}
