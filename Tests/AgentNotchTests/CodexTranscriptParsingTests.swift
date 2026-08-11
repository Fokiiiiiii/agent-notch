import XCTest
@testable import AgentNotch

/// Codex rollout files use a different envelope from Claude's transcripts
/// (`type`/`payload` pairs rather than flat objects), so its parser needs
/// its own coverage — measurement found it at under 10%.
@MainActor
final class CodexTranscriptParsingTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("codex-parse-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    private func parse(
        _ objects: [[String: Any]],
        name: String = "rollout-2026-08-09T10-00-00-019f74a7-1745-7272-b68b-1e0e3ba44a09.jsonl",
        modDate: Date = Date(),
        now: Date = Date()
    ) throws -> AgentSession? {
        let lines = try objects.map { object -> String in
            let data = try JSONSerialization.data(withJSONObject: object)
            return String(data: data, encoding: .utf8)!
        }
        let url = directory.appendingPathComponent(name)
        try lines.joined(separator: "\n").write(to: url, atomically: true, encoding: .utf8)
        return CodexWatcher(store: SessionStore()).parseSession(atPath: url.path, modDate: modDate, now: now)
    }

    private func cwdLine(_ path: String) -> [String: Any] {
        ["type": "session_meta", "payload": ["cwd": path]]
    }

    private func agentMessage(_ text: String) -> [String: Any] {
        ["type": "event_msg", "payload": ["type": "agent_message", "message": text]]
    }

    // MARK: - Identity

    /// The session id is the UUID at the end of the rollout filename, not
    /// the whole timestamped stem.
    func testSessionIdIsTheTrailingUUIDOfTheFilename() throws {
        let session = try parse([cwdLine("/tmp/p"), agentMessage("ok")])
        XCTAssertEqual(session?.id, "019f74a7-1745-7272-b68b-1e0e3ba44a09")
        XCTAssertEqual(session?.agent, .codex)
    }

    /// A filename that doesn't end in a UUID still has to produce a stable
    /// id, so the whole stem is used.
    func testFilenameWithoutAUUIDFallsBackToTheWholeStem() throws {
        let session = try parse([cwdLine("/tmp/p"), agentMessage("ok")], name: "rollout-plain.jsonl")
        XCTAssertEqual(session?.id, "rollout-plain")
    }

    /// Codex reports no slug, so the row is always titled by its directory.
    func testTitleIsTheDirectoryName() throws {
        let session = try parse([cwdLine("/Users/x/Projects/agent-notch"), agentMessage("ok")])
        XCTAssertEqual(session?.title, "agent-notch")
    }

    func testReturnsNilWithoutACwd() throws {
        XCTAssertNil(try parse([agentMessage("ok")]))
    }

    /// An empty `cwd` is treated as absent rather than producing a session
    /// rooted at "".
    func testEmptyCwdIsIgnored() throws {
        XCTAssertNil(try parse([["type": "session_meta", "payload": ["cwd": ""]], agentMessage("ok")]))
    }

    // MARK: - Last message

    func testUsesTheMostRecentAgentMessage() throws {
        let session = try parse([cwdLine("/tmp/p"), agentMessage("first"), agentMessage("second")])
        XCTAssertEqual(session?.lastMessage, "second")
    }

    func testFunctionCallIsReportedAsRunning() throws {
        let session = try parse([
            cwdLine("/tmp/p"),
            ["type": "response_item", "payload": ["type": "function_call", "name": "shell"]],
        ])
        XCTAssertEqual(session?.lastMessage, "Running shell…")
    }

    func testCustomToolCallIsAlsoReportedAsRunning() throws {
        let session = try parse([
            cwdLine("/tmp/p"),
            ["type": "response_item", "payload": ["type": "custom_tool_call", "name": "apply_patch"]],
        ])
        XCTAssertEqual(session?.lastMessage, "Running apply_patch…")
    }

    /// Newlines are collapsed and the text is capped, so one row can't blow
    /// out the session list's layout.
    func testLongMultilineMessageIsCollapsedAndTruncated() throws {
        let session = try parse([cwdLine("/tmp/p"), agentMessage(String(repeating: "ab\n", count: 100))])
        let message = try XCTUnwrap(session?.lastMessage)
        XCTAssertEqual(message.count, 80)
        XCTAssertFalse(message.contains("\n"))
    }

    func testFallsBackToAPlaceholderWithNoMessages() throws {
        XCTAssertEqual(try parse([cwdLine("/tmp/p")])?.lastMessage, "…")
    }

    // MARK: - Context usage

    /// Codex reports its own window size, so the percentage comes straight
    /// from the transcript rather than from a table of model names.
    func testContextPercentUsesTheReportedWindow() throws {
        let session = try parse([
            cwdLine("/tmp/p"),
            ["type": "event_msg", "payload": [
                "type": "token_count",
                "info": ["total_token_usage": ["total_tokens": 40_000], "model_context_window": 200_000],
            ]],
        ])
        XCTAssertEqual(session?.contextUsedPercent ?? 0, 20, accuracy: 0.01)
    }

    /// A zero window would divide by zero; it must be treated as "unknown".
    func testZeroContextWindowIsIgnored() throws {
        let session = try parse([
            cwdLine("/tmp/p"),
            ["type": "event_msg", "payload": [
                "type": "token_count",
                "info": ["total_token_usage": ["total_tokens": 100], "model_context_window": 0],
            ]],
        ])
        XCTAssertNil(session?.contextUsedPercent)
    }

    func testNoTokenCountLeavesContextPercentUnset() throws {
        XCTAssertNil(try parse([cwdLine("/tmp/p"), agentMessage("ok")])?.contextUsedPercent)
    }

    // MARK: - State

    func testRecentActivityReadsAsRunning() throws {
        let now = Date()
        let session = try parse([cwdLine("/tmp/p")], modDate: now.addingTimeInterval(-5), now: now)
        XCTAssertEqual(session?.state, .running)
    }

    func testStaleActivityReadsAsIdle() throws {
        let now = Date()
        let session = try parse([cwdLine("/tmp/p")], modDate: now.addingTimeInterval(-600), now: now)
        XCTAssertEqual(session?.state, .idle)
    }
}
