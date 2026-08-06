import XCTest
@testable import AgentNotch

@MainActor
final class JumperTests: XCTestCase {
    // MARK: - Pure logic (no process execution)

    func testProcessNameResolvesKnownAgents() {
        XCTAssertEqual(Jumper.processName(for: .claude), "claude")
        XCTAssertEqual(Jumper.processName(for: .codex), "codex")
    }

    func testProcessNameReturnsNilForUnsupportedAgents() {
        XCTAssertNil(Jumper.processName(for: .gemini))
        XCTAssertNil(Jumper.processName(for: .cursor))
        XCTAssertNil(Jumper.processName(for: .aider))
    }

    func testTerminalBundleIDsContainsExpectedAppsInPriorityOrder() {
        XCTAssertEqual(Jumper.terminalBundleIDs, [
            "com.googlecode.iterm2",
            "com.github.wez.wezterm",
            "com.mitchellh.ghostty",
            "dev.warp.Warp-Stable",
            "com.apple.Terminal",
            "net.kovidgoyal.kitty",
            "com.microsoft.VSCode",
        ])
    }

    // MARK: - Indirect regression: jump(to:) must not block the main thread

    /// `jump(to:)` internally dispatches its process-execution work via
    /// `Task.detached`, so calling it must return immediately and must not
    /// prevent work already queued on the main run loop / main queue from
    /// executing promptly. This is an indirect stand-in for "no more
    /// synchronous `Process.run()` + `waitUntilExit()` on the main thread"
    /// (see Jumper.swift's `run(executable:arguments:)` and its callers).
    func testJumpDoesNotBlockMainThread() {
        let session = AgentSession(
            id: "test",
            agent: .claude,
            title: "test session",
            cwd: "/nonexistent/cwd/for/jumper/tests",
            lastActivity: Date(),
            state: .running,
            lastMessage: ""
        )

        let expectation = expectation(description: "main thread stays responsive")

        // Call jump(to:) first; if it were synchronous/blocking, the
        // DispatchQueue.main.async below would only fire after all of
        // Jumper's pgrep/ps/lsof subprocess calls completed.
        Jumper.jump(to: session)

        DispatchQueue.main.async {
            expectation.fulfill()
        }

        wait(for: [expectation], timeout: 0.5)
    }
}
