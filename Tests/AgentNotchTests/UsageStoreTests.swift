import XCTest
@testable import AgentNotch

/// `UsageWindow.label`/`relativeResetDescription` are pure functions on a
/// plain `Sendable` struct — no `AgentUsageStore.shared` singleton needed to
/// exercise them. `AgentUsageStore.agent(for:)` is `nonisolated static`, so
/// it's callable without MainActor isolation too.
final class UsageStoreTests: XCTestCase {
    private func makeWindow(usedPercent: Double = 42, windowMinutes: Int?) -> UsageWindow {
        UsageWindow(usedPercent: usedPercent, resetDescription: nil, resetsAt: nil, windowMinutes: windowMinutes)
    }

    // MARK: - UsageWindow.label

    func testLabelUsesFiveHourBucketJustBelow360Minutes() {
        XCTAssertEqual(makeWindow(windowMinutes: 359).label, "5h 42%")
    }

    func testLabelUsesDayBucketAt360MinutesExactly() {
        XCTAssertEqual(makeWindow(windowMinutes: 360).label, "Day 42%")
    }

    func testLabelUsesDayBucketJustBelow10000Minutes() {
        XCTAssertEqual(makeWindow(windowMinutes: 9999).label, "Day 42%")
    }

    func testLabelUsesWeekBucketAt10000MinutesExactly() {
        XCTAssertEqual(makeWindow(windowMinutes: 10_000).label, "Week 42%")
    }

    func testLabelTreatsNilWindowMinutesAsZero() {
        // `windowMinutes ?? 0` falls into the 0..<360 branch, same as an
        // explicit 0 — this is a real fallback path, not just a default arg.
        XCTAssertEqual(makeWindow(windowMinutes: nil).label, "5h 42%")
    }

    func testLabelRoundsUsedPercentToNearestInt() {
        XCTAssertEqual(makeWindow(usedPercent: 42.6, windowMinutes: 0).label, "5h 43%")
        XCTAssertEqual(makeWindow(usedPercent: 42.4, windowMinutes: 0).label, "5h 42%")
    }

    // MARK: - UsageWindow.relativeResetDescription

    func testRelativeResetDescriptionReturnsNowWhenIntervalIsZero() {
        let now = Date()
        let window = UsageWindow(usedPercent: 0, resetDescription: nil, resetsAt: now, windowMinutes: nil)
        XCTAssertEqual(window.relativeResetDescription(now: now), "resets now")
    }

    func testRelativeResetDescriptionReturnsNowWhenResetsAtIsInThePast() {
        let now = Date()
        let window = UsageWindow(usedPercent: 0, resetDescription: nil, resetsAt: now.addingTimeInterval(-60), windowMinutes: nil)
        XCTAssertEqual(window.relativeResetDescription(now: now), "resets now")
    }

    func testRelativeResetDescriptionUsesMinutesJustBelow60() {
        let now = Date()
        let window = UsageWindow(usedPercent: 0, resetDescription: nil, resetsAt: now.addingTimeInterval(59 * 60), windowMinutes: nil)
        XCTAssertEqual(window.relativeResetDescription(now: now), "resets in 59m")
    }

    func testRelativeResetDescriptionUsesHoursAt60MinutesExactly() {
        let now = Date()
        let window = UsageWindow(usedPercent: 0, resetDescription: nil, resetsAt: now.addingTimeInterval(60 * 60), windowMinutes: nil)
        XCTAssertEqual(window.relativeResetDescription(now: now), "resets in 1h")
    }

    func testRelativeResetDescriptionUsesHoursJustBelow24() {
        let now = Date()
        let window = UsageWindow(usedPercent: 0, resetDescription: nil, resetsAt: now.addingTimeInterval(23 * 3600 + 59 * 60), windowMinutes: nil)
        XCTAssertEqual(window.relativeResetDescription(now: now), "resets in 23h")
    }

    func testRelativeResetDescriptionUsesDaysAt24HoursExactly() {
        let now = Date()
        let window = UsageWindow(usedPercent: 0, resetDescription: nil, resetsAt: now.addingTimeInterval(24 * 3600), windowMinutes: nil)
        XCTAssertEqual(window.relativeResetDescription(now: now), "resets in 1d")
    }

    func testRelativeResetDescriptionFallsBackToRawStringWhenResetsAtIsNil() {
        let window = UsageWindow(usedPercent: 0, resetDescription: "Jul 20 at 5:20AM", resetsAt: nil, windowMinutes: nil)
        XCTAssertEqual(window.relativeResetDescription(), "Jul 20 at 5:20AM")
    }

    func testRelativeResetDescriptionReturnsNilWhenBothResetsAtAndDescriptionAreNil() {
        let window = UsageWindow(usedPercent: 0, resetDescription: nil, resetsAt: nil, windowMinutes: nil)
        XCTAssertNil(window.relativeResetDescription())
    }

    // MARK: - AgentUsageStore.agent(for:)

    func testAgentForKnownProviderStrings() {
        XCTAssertEqual(AgentUsageStore.agent(for: "codex"), .codex)
        XCTAssertEqual(AgentUsageStore.agent(for: "claude"), .claude)
        XCTAssertEqual(AgentUsageStore.agent(for: "antigravity"), .antigravity)
        XCTAssertEqual(AgentUsageStore.agent(for: "gemini"), .gemini)
        XCTAssertEqual(AgentUsageStore.agent(for: "copilot"), .copilot)
        XCTAssertEqual(AgentUsageStore.agent(for: "cursor"), .cursor)
        XCTAssertEqual(AgentUsageStore.agent(for: "opencode"), .opencode)
        XCTAssertEqual(AgentUsageStore.agent(for: "mistral"), .mistral)
        XCTAssertEqual(AgentUsageStore.agent(for: "deepseek"), .deepseek)
    }

    func testAgentForKimiHasTwoAliases() {
        XCTAssertEqual(AgentUsageStore.agent(for: "kimi"), .kimi)
        XCTAssertEqual(AgentUsageStore.agent(for: "moonshot"), .kimi)
    }

    func testAgentForIsCaseInsensitive() {
        XCTAssertEqual(AgentUsageStore.agent(for: "Codex"), .codex)
        XCTAssertEqual(AgentUsageStore.agent(for: "CLAUDE"), .claude)
        XCTAssertEqual(AgentUsageStore.agent(for: "MoonShot"), .kimi)
    }

    func testAgentForUnknownProviderReturnsNil() {
        XCTAssertNil(AgentUsageStore.agent(for: "some-future-provider"))
        XCTAssertNil(AgentUsageStore.agent(for: ""))
    }
}
