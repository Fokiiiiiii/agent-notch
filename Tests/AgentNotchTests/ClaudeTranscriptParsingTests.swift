import XCTest
@testable import AgentNotch

/// Turning a Claude transcript into a session row is the app's core job, and
/// coverage measurement found it almost entirely untested — reachable only
/// through the polling timer. These drive `parseSession` directly against
/// real transcript shapes written to a temp file.
@MainActor
final class ClaudeTranscriptParsingTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("claude-parse-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    /// Transcripts are JSONL — one JSON object per line.
    private func write(_ objects: [[String: Any]], name: String = "session.jsonl") throws -> String {
        let lines = try objects.map { object -> String in
            let data = try JSONSerialization.data(withJSONObject: object)
            return String(data: data, encoding: .utf8)!
        }
        let url = directory.appendingPathComponent(name)
        try lines.joined(separator: "\n").write(to: url, atomically: true, encoding: .utf8)
        return url.path
    }

    private func parse(
        _ objects: [[String: Any]],
        name: String = "session.jsonl",
        modDate: Date = Date(),
        now: Date = Date()
    ) throws -> AgentSession? {
        let path = try write(objects, name: name)
        let watcher = ClaudeWatcher(store: SessionStore())
        return watcher.parseSession(atPath: path, modDate: modDate, now: now)
    }

    private func assistantText(_ text: String) -> [String: Any] {
        ["type": "assistant", "message": ["content": [["type": "text", "text": text]]]]
    }

    // MARK: - Identity

    func testExtractsSessionIdAndWorkingDirectory() throws {
        let session = try parse([
            ["sessionId": "abc-123", "cwd": "/Users/x/Projects/thing"],
            assistantText("Done."),
        ])
        XCTAssertEqual(session?.id, "abc-123")
        XCTAssertEqual(session?.cwd, "/Users/x/Projects/thing")
        XCTAssertEqual(session?.agent, .claude)
    }

    /// Without these two there's nothing to key a session row on, so the
    /// whole transcript is skipped rather than half-rendered.
    func testReturnsNilWithoutASessionId() throws {
        XCTAssertNil(try parse([["cwd": "/tmp"], assistantText("hi")]))
    }

    func testReturnsNilWithoutACwd() throws {
        XCTAssertNil(try parse([["sessionId": "abc"], assistantText("hi")]))
    }

    /// A transcript whose `sessionId` is present but empty falls back to the
    /// filename, which is itself the session's identifier on disk.
    func testEmptySessionIdFallsBackToTheFilename() throws {
        let session = try parse(
            [["sessionId": "", "cwd": "/tmp/x"], assistantText("hi")],
            name: "fallback-id.jsonl"
        )
        XCTAssertEqual(session?.id, "fallback-id")
    }

    // MARK: - Title

    func testSlugBecomesTheTitleWithDashesAsSpaces() throws {
        let session = try parse([
            ["sessionId": "s", "cwd": "/tmp/proj", "slug": "fix-auth-bug"],
            assistantText("ok"),
        ])
        XCTAssertEqual(session?.title, "fix auth bug")
    }

    func testTitleFallsBackToTheDirectoryNameWithoutASlug() throws {
        let session = try parse([
            ["sessionId": "s", "cwd": "/Users/x/Projects/agent-notch"],
            assistantText("ok"),
        ])
        XCTAssertEqual(session?.title, "agent-notch")
    }

    /// Claude sometimes derives a slug from a pasted URL, which makes for a
    /// meaningless row title; those are rejected in favour of the directory.
    func testURLDerivedSlugIsRejected() throws {
        let session = try parse([
            ["sessionId": "s", "cwd": "/Users/x/Projects/agent-notch", "slug": "https-example-com-some-page"],
            assistantText("ok"),
        ])
        XCTAssertEqual(session?.title, "agent-notch")
    }

    func testLongSlugIsTruncated() throws {
        let session = try parse([
            ["sessionId": "s", "cwd": "/tmp/p", "slug": String(repeating: "a", count: 120)],
            assistantText("ok"),
        ])
        XCTAssertEqual(session?.title.count, 40)
    }

    // MARK: - Last message

    func testUsesTheMostRecentAssistantText() throws {
        let session = try parse([
            ["sessionId": "s", "cwd": "/tmp/p"],
            assistantText("first"),
            assistantText("second"),
        ])
        XCTAssertEqual(session?.lastMessage, "second")
    }

    func testToolUseIsReportedAsRunning() throws {
        let session = try parse([
            ["sessionId": "s", "cwd": "/tmp/p"],
            ["type": "assistant", "message": ["content": [["type": "tool_use", "name": "Bash"]]]],
        ])
        XCTAssertEqual(session?.lastMessage, "Running Bash…")
    }

    func testFallsBackToAPlaceholderWithNoAssistantMessage() throws {
        let session = try parse([["sessionId": "s", "cwd": "/tmp/p"]])
        XCTAssertEqual(session?.lastMessage, "…")
    }

    /// A transcript is appended to while it's being read, so the final line
    /// is routinely a partial write. One unparseable line must not discard
    /// the rest of the file.
    func testMalformedLinesAreSkipped() throws {
        let path = directory.appendingPathComponent("torn.jsonl").path
        let good = #"{"sessionId":"s","cwd":"/tmp/p"}"#
        let assistant = #"{"type":"assistant","message":{"content":[{"type":"text","text":"hello"}]}}"#
        try "\(good)\n\(assistant)\n{\"type\":\"assist".write(
            toFile: path, atomically: true, encoding: .utf8
        )
        let watcher = ClaudeWatcher(store: SessionStore())
        let session = watcher.parseSession(atPath: path, modDate: Date(), now: Date())
        XCTAssertEqual(session?.id, "s")
        XCTAssertEqual(session?.lastMessage, "hello")
    }

    // MARK: - Context usage

    /// The percentage sums the three token buckets Claude reports, against
    /// the model's window — 20k of 200k is 10%.
    func testContextPercentSumsAllThreeTokenBuckets() throws {
        let session = try parse([
            ["sessionId": "s", "cwd": "/tmp/p"],
            ["type": "assistant", "message": [
                "model": "claude-opus-4",
                "content": [["type": "text", "text": "ok"]],
                "usage": ["input_tokens": 10_000, "cache_creation_input_tokens": 6_000, "cache_read_input_tokens": 4_000],
            ]],
        ])
        XCTAssertEqual(session?.contextUsedPercent ?? 0, 10, accuracy: 0.01)
    }

    /// A model advertising a 1M window must not read as five times fuller
    /// than it is.
    func testExtendedContextModelUsesTheLargerWindow() throws {
        let session = try parse([
            ["sessionId": "s", "cwd": "/tmp/p"],
            ["type": "assistant", "message": [
                "model": "claude-sonnet-4-1m",
                "content": [["type": "text", "text": "ok"]],
                "usage": ["input_tokens": 100_000],
            ]],
        ])
        XCTAssertEqual(session?.contextUsedPercent ?? 0, 10, accuracy: 0.01)
    }

    func testNoUsageLeavesContextPercentUnset() throws {
        let session = try parse([["sessionId": "s", "cwd": "/tmp/p"], assistantText("ok")])
        XCTAssertNil(session?.contextUsedPercent)
    }

    // MARK: - State

    func testRecentActivityReadsAsRunning() throws {
        let now = Date()
        let session = try parse(
            [["sessionId": "s", "cwd": "/tmp/p"], assistantText("ok")],
            modDate: now.addingTimeInterval(-10),
            now: now
        )
        XCTAssertEqual(session?.state, .running)
    }

    func testStaleActivityReadsAsIdle() throws {
        let now = Date()
        let session = try parse(
            [["sessionId": "s", "cwd": "/tmp/p"], assistantText("ok")],
            modDate: now.addingTimeInterval(-600),
            now: now
        )
        XCTAssertEqual(session?.state, .idle)
    }
}
