import XCTest
@testable import AgentNotch

/// The app is a permanent resident, so what it does while nobody is looking
/// at it is a product concern, not an implementation detail. Profiling the
/// idle app showed `MediaController`'s poll — which spawns `/usr/bin/perl`
/// every tick — dominating its CPU time; these lock in the policy that
/// fixed it (measured 4.7% → 0.4% CPU while idle).
@MainActor
final class PollingPolicyTests: XCTestCase {
    // MARK: - Media poll rate

    func testVisiblePanelUsesTheFastRate() {
        XCTAssertEqual(
            MediaController.pollInterval(panelVisible: true, isPlaying: true),
            MediaController.activeInterval
        )
        // Visible but paused still needs to be live: the user is looking at
        // the transport controls and expects them to reflect reality.
        XCTAssertEqual(
            MediaController.pollInterval(panelVisible: false, isPlaying: true),
            MediaController.idlePlayingInterval
        )
    }

    /// The closed pill animates a waveform while something plays, so track
    /// changes still have to land — just not at the visible rate.
    func testClosedButPlayingUsesTheMiddleRate() {
        XCTAssertEqual(
            MediaController.pollInterval(panelVisible: false, isPlaying: true),
            MediaController.idlePlayingInterval
        )
    }

    /// Nothing media-related is drawn at all here, so the only job left is
    /// noticing playback *starting* within a few seconds.
    func testClosedAndStoppedUsesTheSlowestRate() {
        XCTAssertEqual(
            MediaController.pollInterval(panelVisible: false, isPlaying: false),
            MediaController.idleStoppedInterval
        )
    }

    /// The ordering matters more than the exact numbers: a regression that
    /// reversed two tiers would still satisfy the equality tests above if
    /// the constants were edited to match.
    func testRatesGetSlowerAsTheAnswerMattersLess() {
        XCTAssertLessThan(MediaController.activeInterval, MediaController.idlePlayingInterval)
        XCTAssertLessThan(MediaController.idlePlayingInterval, MediaController.idleStoppedInterval)
    }

    // MARK: - Gated monitors

    /// `SystemMonitor` feeds the nook bar's battery and the detail strip,
    /// neither of which exists unless the panel is open.
    func testSystemMonitorHoldsNoTimerUntilEnabled() {
        let monitor = SystemMonitor()
        XCTAssertNil(Self.timer(of: monitor), "should not poll before anything asks for it")

        monitor.setPollingEnabled(true)
        XCTAssertNotNil(Self.timer(of: monitor))

        monitor.setPollingEnabled(false)
        XCTAssertNil(Self.timer(of: monitor), "closing the panel must stop the timer")
    }

    /// This one runs `/bin/ps` per tick to feed a single row in the expanded
    /// detail strip — the most expensive poll for the least-seen output.
    func testBackgroundActivityMonitorHoldsNoTimerUntilEnabled() {
        let monitor = BackgroundActivityMonitor()
        XCTAssertNil(Self.timer(of: monitor), "should not spawn `ps` before anything asks for it")

        monitor.setPollingEnabled(true)
        XCTAssertNotNil(Self.timer(of: monitor))

        monitor.setPollingEnabled(false)
        XCTAssertNil(Self.timer(of: monitor))
    }

    /// Enabling twice must not leave a second timer running behind the
    /// first — that would quietly double the poll rate.
    func testEnablingTwiceKeepsASingleTimer() {
        let monitor = SystemMonitor()
        monitor.setPollingEnabled(true)
        let first = Self.timer(of: monitor)
        monitor.setPollingEnabled(true)
        XCTAssertNotNil(first)
        XCTAssertNotNil(Self.timer(of: monitor))
    }

    /// `timer` is a private implementation detail; reflection keeps the test
    /// from forcing it open (same approach as `TodayModelTests`).
    private static func timer(of subject: Any) -> Any? {
        Mirror(reflecting: subject).children.first { $0.label == "timer" }.flatMap { child in
            // A nil `AnyCancellable?` still shows up as a child, so unwrap
            // through `Optional` rather than trusting presence alone.
            Mirror(reflecting: child.value).displayStyle == .optional
                && Mirror(reflecting: child.value).children.isEmpty ? nil : child.value
        }
    }
}
