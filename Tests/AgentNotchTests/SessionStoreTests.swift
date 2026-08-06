import XCTest
@testable import AgentNotch

@MainActor
final class SessionStoreTests: XCTestCase {

    // MARK: - ProcessInspector matching (pure logic, no kill involved)

    func testMatchesSelfProcessFingerprint() {
        let selfPID = ProcessInfo.processInfo.processIdentifier
        let fp = ProcessInspector.fingerprint(for: selfPID)
        // Self process should yield a resolvable start time and executable path
        // in this test environment.
        XCTAssertNotNil(fp.startedAt)
        XCTAssertNotNil(fp.executablePath)

        let matches = ProcessInspector.matches(
            recordedStartedAt: fp.startedAt,
            recordedExecutablePath: fp.executablePath,
            pid: selfPID
        )
        XCTAssertTrue(matches, "recorded fingerprint should match the current live process")
    }

    func testMismatchOnBogusExecutablePath() {
        let selfPID = ProcessInfo.processInfo.processIdentifier
        let matches = ProcessInspector.matches(
            recordedStartedAt: ProcessInspector.startTime(for: selfPID),
            recordedExecutablePath: "/nonexistent/path/to/nothing",
            pid: selfPID
        )
        XCTAssertFalse(matches, "a bogus recorded executable path must fail the match")
    }

    func testMismatchOnStaleStartTime() {
        let selfPID = ProcessInfo.processInfo.processIdentifier
        let staleDate = Date(timeIntervalSince1970: 0) // 1970, definitely not this process's start
        let matches = ProcessInspector.matches(
            recordedStartedAt: staleDate,
            recordedExecutablePath: ProcessInspector.executablePath(for: selfPID),
            pid: selfPID
        )
        XCTAssertFalse(matches, "a stale recorded start time must fail the match")
    }

    func testBackwardCompatibleNilRecordSkipsMatch() {
        // Old sessions without recorded fingerprint data should skip validation.
        let matches = ProcessInspector.matches(
            recordedStartedAt: nil,
            recordedExecutablePath: nil,
            pid: 99999
        )
        XCTAssertTrue(matches, "nil recorded fingerprint should be treated as backward-compatible pass-through")
    }

    // MARK: - controlManagedSession integration via matching logic

    func testControlManagedSessionFailsWhenFingerprintMismatched() {
        let store = SessionStore()
        let selfPID = ProcessInfo.processInfo.processIdentifier

        let event = makeCLIEvent(
            sessionId: "s1",
            input: [
                "action": "start",
                "agent": "claude",
                "pid": NSNumber(value: selfPID),
                "managed": true
            ]
        )
        store.applyHookEvent(event)

        // Corrupt the recorded fingerprint to simulate PID reuse by an unrelated process.
        guard var session = store.sessions.first(where: { $0.id == "s1" }) else {
            return XCTFail("session should exist after CLI event")
        }
        session.processExecutablePath = "/nonexistent/path/to/nothing"
        // Directly overwrite via re-applying isn't possible since cliSessions is private;
        // instead verify the pure matching function used internally would reject this pid.
        let matches = ProcessInspector.matches(
            recordedStartedAt: session.processStartedAt,
            recordedExecutablePath: session.processExecutablePath,
            pid: selfPID
        )
        XCTAssertFalse(matches)
    }

    func testControlManagedSessionSucceedsForFreshlyRecordedSelfProcess() {
        let store = SessionStore()
        let selfPID = ProcessInfo.processInfo.processIdentifier

        let event = makeCLIEvent(
            sessionId: "s2",
            input: [
                "action": "start",
                "agent": "claude",
                "pid": NSNumber(value: selfPID),
                "managed": true
            ]
        )
        store.applyHookEvent(event)

        guard let session = store.sessions.first(where: { $0.id == "s2" }) else {
            return XCTFail("session should exist after CLI event")
        }
        XCTAssertEqual(session.processID, selfPID)
        XCTAssertTrue(session.isManagedProcess)
        // Fingerprint should have been captured for the self process.
        XCTAssertNotNil(session.processStartedAt)
        XCTAssertNotNil(session.processExecutablePath)

        // Note: we deliberately do not call controlManagedSession(...) here, since that
        // would send a real SIGSTOP/SIGCONT/SIGTERM to this test process. We verify the
        // matching precondition directly instead.
        let matches = ProcessInspector.matches(
            recordedStartedAt: session.processStartedAt,
            recordedExecutablePath: session.processExecutablePath,
            pid: selfPID
        )
        XCTAssertTrue(matches)
    }

    // MARK: - Terminal state clears process fields

    func testDoneTransitionClearsProcessFields() {
        let store = SessionStore()
        let selfPID = ProcessInfo.processInfo.processIdentifier

        store.applyHookEvent(makeCLIEvent(
            sessionId: "s3",
            input: [
                "action": "start",
                "agent": "claude",
                "pid": NSNumber(value: selfPID),
                "managed": true
            ]
        ))
        store.applyHookEvent(makeCLIEvent(
            sessionId: "s3",
            input: ["action": "done", "agent": "claude"]
        ))

        guard let session = store.sessions.first(where: { $0.id == "s3" }) else {
            return XCTFail("session should exist after done event")
        }
        XCTAssertEqual(session.state, .done)
        XCTAssertNil(session.processID)
        XCTAssertFalse(session.isManagedProcess)
        XCTAssertNil(session.processStartedAt)
        XCTAssertNil(session.processExecutablePath)
    }

    func testFailedTransitionClearsProcessFields() {
        let store = SessionStore()
        let selfPID = ProcessInfo.processInfo.processIdentifier

        store.applyHookEvent(makeCLIEvent(
            sessionId: "s4",
            input: [
                "action": "start",
                "agent": "claude",
                "pid": NSNumber(value: selfPID),
                "managed": true
            ]
        ))
        store.applyHookEvent(makeCLIEvent(
            sessionId: "s4",
            input: ["action": "fail", "agent": "claude"]
        ))

        guard let session = store.sessions.first(where: { $0.id == "s4" }) else {
            return XCTFail("session should exist after fail event")
        }
        XCTAssertEqual(session.state, .failed)
        XCTAssertNil(session.processID)
        XCTAssertFalse(session.isManagedProcess)
        XCTAssertNil(session.processStartedAt)
        XCTAssertNil(session.processExecutablePath)
    }

    // MARK: - groupSessionsByProject (Phase 5)

    private func session(_ id: String, agent: AgentKind = .claude, cwd: String) -> AgentSession {
        AgentSession(id: id, agent: agent, title: id, cwd: cwd, lastActivity: Date(), state: .running, lastMessage: "")
    }

    func testGroupSessionsByProjectCombinesSameCwdRegardlessOfAgent() {
        let sessions = [
            session("s1", agent: .claude, cwd: "/repo/a"),
            session("s2", agent: .codex, cwd: "/repo/a"),
            session("s3", agent: .claude, cwd: "/repo/b"),
        ]

        let groups = groupSessionsByProject(sessions)

        XCTAssertEqual(groups.count, 2)
        XCTAssertEqual(groups[0].cwd, "/repo/a")
        XCTAssertEqual(groups[0].sessions.map(\.id), ["s1", "s2"])
        XCTAssertEqual(groups[1].cwd, "/repo/b")
        XCTAssertEqual(groups[1].sessions.map(\.id), ["s3"])
    }

    func testGroupSessionsByProjectPreservesFirstOccurrenceOrdering() {
        // Group order follows each cwd's *first* appearance in the input
        // (which is itself most-recent-first from SessionStore) — not
        // alphabetical, and not disrupted by a later session reusing an
        // earlier project.
        let sessions = [
            session("s1", cwd: "/repo/newest"),
            session("s2", cwd: "/repo/older"),
            session("s3", cwd: "/repo/newest"),
        ]

        let groups = groupSessionsByProject(sessions)

        XCTAssertEqual(groups.map(\.cwd), ["/repo/newest", "/repo/older"])
        XCTAssertEqual(groups[0].sessions.map(\.id), ["s1", "s3"])
    }

    func testGroupSessionsByProjectHandlesEmptyInput() {
        XCTAssertTrue(groupSessionsByProject([]).isEmpty)
    }

    func testGroupSessionsByProjectSingleProjectYieldsOneGroup() {
        let sessions = [session("s1", cwd: "/repo/only"), session("s2", cwd: "/repo/only")]
        let groups = groupSessionsByProject(sessions)

        XCTAssertEqual(groups.count, 1)
        XCTAssertEqual(groups[0].sessions.count, 2)
    }

    // MARK: - Helpers

    private func makeCLIEvent(sessionId: String, input: [String: Any]) -> HookEvent {
        HookEvent(
            eventName: "AgentNotchSession",
            sessionId: sessionId,
            cwd: "/tmp/agent-notch-tests",
            toolName: nil,
            toolInput: input,
            connection: nil
        )
    }
}
