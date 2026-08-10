import XCTest
@testable import AgentNotch

/// `NSHapticFeedbackManager` has no observable "did it fire" state from
/// outside AppKit, and non-Force-Touch hardware silently no-ops it anyway —
/// so, mirroring `SoundPlayerTests`, what we can verify without touching
/// private state is that toggling `AppSettings.shared.hapticsEnabled` off
/// does not crash, and that the guard clause is present in source (a
/// regression check against the guard being silently removed).
@MainActor
final class HapticPlayerTests: XCTestCase {
    func testPerformDoesNotCrashWhenHapticsDisabled() {
        let originalValue = AppSettings.shared.hapticsEnabled
        defer { AppSettings.shared.hapticsEnabled = originalValue }

        AppSettings.shared.hapticsEnabled = false
        HapticPlayer.shared.perform(.confirm)
        HapticPlayer.shared.perform(.reject)

        AppSettings.shared.hapticsEnabled = true
        HapticPlayer.shared.perform(.confirm)
    }

    /// Regression check: `perform(_:)` must bail out before touching
    /// `NSHapticFeedbackManager` when haptics are disabled. We can't observe
    /// the feedback manager's state from here, so we assert the guard exists
    /// at the top of the source function.
    func testPerformSourceGuardsOnHapticsEnabled() throws {
        let sourceURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent() // HapticPlayerTests.swift -> AgentNotchTests
            .deletingLastPathComponent() // AgentNotchTests -> Tests
            .deletingLastPathComponent() // Tests -> repo root
            .appendingPathComponent("Sources/AgentNotch/HapticPlayer.swift")
        let source = try String(contentsOf: sourceURL, encoding: .utf8)

        guard let performRange = source.range(of: "func perform(_ haptic: AppHaptic) {") else {
            return XCTFail("could not locate perform(_:) in HapticPlayer.swift")
        }
        let body = source[performRange.upperBound...]
        XCTAssertTrue(
            body.contains("guard AppSettings.shared.hapticsEnabled else { return }"),
            "perform(_:) must guard on AppSettings.shared.hapticsEnabled before performing"
        )
    }
}
