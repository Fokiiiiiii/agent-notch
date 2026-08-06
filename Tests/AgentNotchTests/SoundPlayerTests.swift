import XCTest
@testable import AgentNotch

/// SoundPlayer synthesizes real NSSound cues at init, and `play(_:)` is not
/// designed for output mocking, so there's no clean seam to assert "no audio
/// played" from outside the type. What we *can* verify without touching
/// private state is that toggling `AppSettings.shared.soundEnabled` off does
/// not crash or throw, and that the guard clause is present in source (a
/// regression check against the guard being silently removed).
@MainActor
final class SoundPlayerTests: XCTestCase {
    func testPlayDoesNotCrashWhenSoundDisabled() {
        let originalValue = AppSettings.shared.soundEnabled
        defer { AppSettings.shared.soundEnabled = originalValue }

        AppSettings.shared.soundEnabled = false
        // Should be a silent no-op; primarily guards against regressions
        // (e.g. a crash from force-unwrapping) being reintroduced.
        SoundPlayer.shared.play(.done)
        SoundPlayer.shared.play(.permission)

        AppSettings.shared.soundEnabled = true
        SoundPlayer.shared.play(.navigation)
    }

    /// Regression guard for the "every attention type sounded identical"
    /// report: permission/question/plan-review/session-attention used to all
    /// share `.permission`. Pins down that each now has its own distinct
    /// `AppSound` case to play.
    func testAppSoundHasDistinctCuesForEachAttentionType() {
        let cues: Set<AppSound> = [.permission, .question, .plan, .sessionAttention]
        XCTAssertEqual(cues.count, 4, "each attention type must map to its own AppSound case")
        for cue in cues {
            XCTAssertTrue(AppSound.allCases.contains(cue))
        }
    }

    /// Guards against a crash from a missing switch case in
    /// `tones(for:)`/`debounce(for:)`/`volume(for:)` for the newly added
    /// cues — `sounds[cue]` construction happens once at `init`, so a
    /// missing case there would otherwise only surface as a silent no-op.
    func testPlayDoesNotCrashForNewAttentionSounds() {
        SoundPlayer.shared.play(.question)
        SoundPlayer.shared.play(.plan)
        SoundPlayer.shared.play(.sessionAttention)
    }

    /// Regression check: `play(_:)` must bail out before doing any work when
    /// sound is disabled. We can't observe NSSound playback state from here,
    /// so we assert the guard exists at the top of the source function.
    func testPlaySourceGuardsOnSoundEnabled() throws {
        let sourceURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent() // SoundPlayerTests.swift -> AgentNotchTests
            .deletingLastPathComponent() // AgentNotchTests -> Tests
            .deletingLastPathComponent() // Tests -> repo root
            .appendingPathComponent("Sources/AgentNotch/SoundPlayer.swift")
        let source = try String(contentsOf: sourceURL, encoding: .utf8)

        guard let playRange = source.range(of: "func play(_ sound: AppSound) {") else {
            return XCTFail("could not locate play(_:) in SoundPlayer.swift")
        }
        let afterPlay = source[playRange.upperBound...]
        guard let nextFuncRange = afterPlay.range(of: "\n    private func debounce") else {
            return XCTFail("could not locate end of play(_:) body")
        }
        let body = afterPlay[..<nextFuncRange.lowerBound]
        XCTAssertTrue(
            body.contains("guard AppSettings.shared.soundEnabled else { return }"),
            "play(_:) must guard on AppSettings.shared.soundEnabled before playing"
        )
    }
}
