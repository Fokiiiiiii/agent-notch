import XCTest
@testable import AgentNotch

/// `AppSettings` is a MainActor singleton with a private initializer — no
/// way to construct an isolated instance for testing — so these tests
/// exercise `AppSettings.shared` directly, saving and restoring each
/// property's original value around every test (the same pattern
/// `SoundPlayerTests.swift` already uses for `soundEnabled`). Every test
/// restores whatever value was actually present beforehand rather than
/// assuming a specific default, since `UserDefaults.standard` here is the
/// same domain the real app (and this session's own SettingsView work)
/// reads/writes — never assert or rely on a fixed starting value.
///
/// Verifies the real persistence round-trip through `UserDefaults` (not
/// just "the in-memory property returns what I just set it to", which
/// would stay true even if the `didSet` write to `UserDefaults` were
/// silently broken).
@MainActor
final class AppSettingsTests: XCTestCase {
    // Mirrors the key strings in AppSettings.Keys (private to that file) —
    // these are the actual persisted UserDefaults keys, duplicated here
    // only so the test can verify persistence from outside the type.
    private enum Keys {
        static let uiScale = "agentnotch.uiScale"
        static let cornerRadiusScale = "agentnotch.cornerRadiusScale"
        static let animationSpeedScale = "agentnotch.animationSpeedScale"
        static let languageOverride = "agentnotch.languageOverride"
        static let hapticsEnabled = "agentnotch.hapticsEnabled"
    }

    func testHapticsEnabledPersistsToUserDefaults() {
        let original = AppSettings.shared.hapticsEnabled
        defer { AppSettings.shared.hapticsEnabled = original }

        AppSettings.shared.hapticsEnabled = false
        XCTAssertEqual(UserDefaults.standard.object(forKey: Keys.hapticsEnabled) as? Bool, false)

        AppSettings.shared.hapticsEnabled = true
        XCTAssertEqual(UserDefaults.standard.object(forKey: Keys.hapticsEnabled) as? Bool, true)
    }

    func testUiScalePersistsToUserDefaults() {
        let original = AppSettings.shared.uiScale
        defer { AppSettings.shared.uiScale = original }

        AppSettings.shared.uiScale = 1.15
        XCTAssertEqual(UserDefaults.standard.double(forKey: Keys.uiScale), 1.15, accuracy: 0.0001)
    }

    func testCornerRadiusScalePersistsToUserDefaults() {
        let original = AppSettings.shared.cornerRadiusScale
        defer { AppSettings.shared.cornerRadiusScale = original }

        AppSettings.shared.cornerRadiusScale = 0.75
        XCTAssertEqual(UserDefaults.standard.double(forKey: Keys.cornerRadiusScale), 0.75, accuracy: 0.0001)
    }

    func testAnimationSpeedScalePersistsToUserDefaults() {
        let original = AppSettings.shared.animationSpeedScale
        defer { AppSettings.shared.animationSpeedScale = original }

        AppSettings.shared.animationSpeedScale = 1.8
        XCTAssertEqual(UserDefaults.standard.double(forKey: Keys.animationSpeedScale), 1.8, accuracy: 0.0001)
    }

    func testLanguageOverridePersistsToUserDefaultsIncludingNil() {
        let original = AppSettings.shared.languageOverride
        defer { AppSettings.shared.languageOverride = original }

        AppSettings.shared.languageOverride = "fr"
        XCTAssertEqual(UserDefaults.standard.string(forKey: Keys.languageOverride), "fr")

        AppSettings.shared.languageOverride = nil
        XCTAssertNil(UserDefaults.standard.string(forKey: Keys.languageOverride))
    }

    func testScalePropertiesRoundTripThroughMultipleAssignments() {
        // Regression guard against a `didSet` that only fires once, or a
        // stale-closure-capture bug — assign several distinct values in
        // sequence and confirm each one lands, not just the first/last.
        let original = AppSettings.shared.uiScale
        defer { AppSettings.shared.uiScale = original }

        for value in [0.8, 1.0, 1.3, 0.95] {
            AppSettings.shared.uiScale = value
            XCTAssertEqual(AppSettings.shared.uiScale, value, accuracy: 0.0001)
            XCTAssertEqual(UserDefaults.standard.double(forKey: Keys.uiScale), value, accuracy: 0.0001)
        }
    }
}
