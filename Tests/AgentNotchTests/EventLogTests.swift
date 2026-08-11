import XCTest
@testable import AgentNotch

/// The event log is written on every hook for the life of a permanently
/// resident app, so its growth is a product concern, not just tidiness — the
/// lines record the directories the user works in.
final class EventLogTests: XCTestCase {
    private var directory: URL!
    private var logURL: URL!

    override func setUpWithError() throws {
        directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("event-log-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        logURL = directory.appendingPathComponent("events.log")
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    private var rotatedURL: URL { logURL.appendingPathExtension("1") }

    private func size(_ url: URL) -> UInt64 {
        (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? UInt64) as? UInt64 ?? 0
    }

    private func mode(_ url: URL) throws -> Int {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        return try XCTUnwrap(attributes[.posixPermissions] as? NSNumber).intValue & 0o777
    }

    // MARK: - Threshold

    func testDoesNotRotateBelowTheCap() {
        XCTAssertFalse(EventLog.shouldRotate(currentSize: 0))
        XCTAssertFalse(EventLog.shouldRotate(currentSize: EventLog.maxBytes - 1))
    }

    func testRotatesAtAndAboveTheCap() {
        XCTAssertTrue(EventLog.shouldRotate(currentSize: EventLog.maxBytes))
        XCTAssertTrue(EventLog.shouldRotate(currentSize: EventLog.maxBytes * 10))
    }

    // MARK: - Appending

    func testFirstWriteCreatesTheFileOwnerOnly() throws {
        EventLog.append("first\n", to: logURL)
        XCTAssertEqual(try String(contentsOf: logURL, encoding: .utf8), "first\n")
        XCTAssertEqual(try mode(logURL), 0o600, "the log names the user's project directories")
    }

    func testSubsequentWritesAppendRatherThanReplace() {
        EventLog.append("one\n", to: logURL)
        EventLog.append("two\n", to: logURL)
        EventLog.append("three\n", to: logURL)
        let contents = (try? String(contentsOf: logURL, encoding: .utf8)) ?? ""
        XCTAssertEqual(contents, "one\ntwo\nthree\n")
    }

    // MARK: - Rotation

    /// The whole point: an oversized log is moved aside and a fresh one
    /// started, so the live file can't grow without bound.
    func testOversizedLogIsRotatedOnNextAppend() throws {
        let filler = String(repeating: "x", count: Int(EventLog.maxBytes) + 10)
        try filler.write(to: logURL, atomically: true, encoding: .utf8)

        EventLog.append("after rotation\n", to: logURL)

        XCTAssertEqual(try String(contentsOf: logURL, encoding: .utf8), "after rotation\n")
        XCTAssertTrue(FileManager.default.fileExists(atPath: rotatedURL.path), "previous generation should be kept")
        XCTAssertEqual(size(rotatedURL), UInt64(filler.utf8.count))
    }

    /// A rotation must never lose the line that triggered it.
    func testTheTriggeringLineSurvivesRotation() throws {
        try String(repeating: "x", count: Int(EventLog.maxBytes)).write(to: logURL, atomically: true, encoding: .utf8)
        EventLog.append("triggering line\n", to: logURL)
        XCTAssertTrue(try String(contentsOf: logURL, encoding: .utf8).contains("triggering line"))
    }

    /// Only one generation is kept — otherwise rotation would just move the
    /// unbounded growth into `.1`, `.2`, `.3`…
    func testOnlyOneGenerationIsKept() throws {
        let oversize = String(repeating: "x", count: Int(EventLog.maxBytes) + 1)

        try oversize.write(to: logURL, atomically: true, encoding: .utf8)
        EventLog.append("gen1\n", to: logURL)
        try oversize.write(to: logURL, atomically: true, encoding: .utf8)
        EventLog.append("gen2\n", to: logURL)

        XCTAssertFalse(
            FileManager.default.fileExists(atPath: logURL.appendingPathExtension("1").appendingPathExtension("1").path),
            "there must be no second-generation file"
        )
        let siblings = try FileManager.default.contentsOfDirectory(atPath: directory.path)
        XCTAssertEqual(Set(siblings), ["events.log", "events.log.1"])
    }

    /// The file created after a rotation must be as locked down as the
    /// original — a rotation is exactly when permissions get forgotten.
    func testFileCreatedAfterRotationIsAlsoOwnerOnly() throws {
        try String(repeating: "x", count: Int(EventLog.maxBytes) + 1)
            .write(to: logURL, atomically: true, encoding: .utf8)
        EventLog.append("fresh\n", to: logURL)
        XCTAssertEqual(try mode(logURL), 0o600)
    }

    /// Diagnostics must never disturb hook delivery: writing into a
    /// directory that doesn't exist fails silently rather than throwing.
    func testWritingToAnUnwritablePathIsSilent() {
        let missing = directory.appendingPathComponent("no-such-dir/events.log")
        EventLog.append("ignored\n", to: missing)
        XCTAssertFalse(FileManager.default.fileExists(atPath: missing.path))
    }
}
