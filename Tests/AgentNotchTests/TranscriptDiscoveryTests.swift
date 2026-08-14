import XCTest
@testable import AgentNotch

/// Which files the watcher treats as sessions. This is an assumption about
/// Claude's own directory layout, so it's pinned rather than left implicit:
/// on a real machine 212 of 229 transcripts are nested subagent/workflow
/// files that must not become session rows.
@MainActor
final class TranscriptDiscoveryTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("projects-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    @discardableResult
    private func makeTranscript(_ relativePath: String) throws -> URL {
        let url = root.appendingPathComponent(relativePath)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        try "{}".write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    private func discovered() -> [String] {
        ClaudeWatcher(store: SessionStore(), projectsURL: root)
            .discoverTranscripts()
            .map { URL(fileURLWithPath: $0).lastPathComponent }
            .sorted()
    }

    func testFindsTranscriptsDirectlyInsideEachProject() throws {
        try makeTranscript("project-a/one.jsonl")
        try makeTranscript("project-b/two.jsonl")
        XCTAssertEqual(discovered(), ["one.jsonl", "two.jsonl"])
    }

    /// A session's subagents each get their own transcript. They belong to a
    /// session that already has a row; listing them would bury the real
    /// sessions under machine-named entries.
    func testIgnoresNestedSubagentTranscripts() throws {
        try makeTranscript("project/main.jsonl")
        try makeTranscript("project/session-id/subagents/agent-abc.jsonl")
        try makeTranscript("project/session-id/subagents/workflows/wf_1/agent-def.jsonl")
        XCTAssertEqual(discovered(), ["main.jsonl"])
    }

    func testIgnoresNonJSONLFiles() throws {
        try makeTranscript("project/real.jsonl")
        try makeTranscript("project/notes.txt")
        try makeTranscript("project/data.json")
        XCTAssertEqual(discovered(), ["real.jsonl"])
    }

    /// A symlinked transcript would be parsed twice — once as itself and
    /// once as its target — producing duplicate session rows.
    func testIgnoresSymlinkedTranscripts() throws {
        let real = try makeTranscript("project/real.jsonl")
        try FileManager.default.createSymbolicLink(
            at: root.appendingPathComponent("project/link.jsonl"),
            withDestinationURL: real
        )
        XCTAssertEqual(discovered(), ["real.jsonl"])
    }

    /// A symlinked *project directory* could point anywhere, including
    /// outside Claude's own tree.
    func testIgnoresSymlinkedProjectDirectories() throws {
        try makeTranscript("real-project/a.jsonl")
        try FileManager.default.createSymbolicLink(
            at: root.appendingPathComponent("linked-project"),
            withDestinationURL: root.appendingPathComponent("real-project")
        )
        XCTAssertEqual(discovered(), ["a.jsonl"])
    }

    /// Loose files at the top level aren't inside any project, so they have
    /// no cwd to group by.
    func testIgnoresTranscriptsAtTheTopLevel() throws {
        try makeTranscript("stray.jsonl")
        try makeTranscript("project/real.jsonl")
        XCTAssertEqual(discovered(), ["real.jsonl"])
    }

    /// A missing projects directory is the normal state before Claude Code
    /// has ever run; it must be empty, not a crash.
    func testMissingProjectsDirectoryYieldsNothing() {
        let absent = root.appendingPathComponent("does-not-exist")
        let watcher = ClaudeWatcher(store: SessionStore(), projectsURL: absent)
        XCTAssertTrue(watcher.discoverTranscripts().isEmpty)
    }
}
