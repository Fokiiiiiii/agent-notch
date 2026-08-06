import XCTest
@testable import AgentNotch

@MainActor
final class WatcherParsingTests: XCTestCase {
    // MARK: - UTF-8 tail-boundary safety

    /// `tailByteCount` in both watchers is `64 * 1024`. We build a fixture
    /// where the byte at that exact cut offset falls in the middle of a
    /// multi-byte UTF-8 character, reproducing the historical crash where
    /// `String(data:encoding:.utf8)` returned nil and parsing failed entirely.
    private let tailByteCount = 64 * 1024

    private func makeMidCharacterFixture() -> Data {
        // 3-byte UTF-8 character (Japanese "日"), placed so that the cut
        // offset (fileSize - tailByteCount) lands on its 2nd byte.
        let multibyteChar = "日"
        XCTAssertEqual(multibyteChar.utf8.count, 3)

        let prefix = Data(repeating: 0x41, count: tailByteCount - 1) // "A" * 65535
        let charBytes = Data(multibyteChar.utf8) // 3 bytes, straddling the cut point
        let suffix = Data("""
        {"type":"assistant","sessionId":"abc-123","cwd":"/tmp/proj","message":{"content":[{"type":"text","text":"hello after the split"}]}}
        """.utf8)

        // Total size - tailByteCount must land inside charBytes (offsets 1 or 2 of the 3).
        var data = prefix
        data.append(charBytes)
        data.append(suffix)
        return data
    }

    func testClaudeReadTailLinesSurvivesMidCharacterCut() throws {
        let data = makeMidCharacterFixture()
        let tmpURL = try writeTempFile(data)
        defer { try? FileManager.default.removeItem(at: tmpURL) }

        let watcher = ClaudeWatcher(store: SessionStore())
        let lines = watcher.readTailLines(atPath: tmpURL.path)

        XCTAssertNotNil(lines, "readTailLines must not return nil on a mid-character byte cut")
        XCTAssertFalse(lines?.isEmpty ?? true)
        // The trailing, fully-intact JSON line should still be recoverable.
        XCTAssertTrue(lines?.contains(where: { $0.contains("hello after the split") }) ?? false)
    }

    func testCodexReadTailLinesSurvivesMidCharacterCut() throws {
        let data = makeMidCharacterFixture()
        let tmpURL = try writeTempFile(data)
        defer { try? FileManager.default.removeItem(at: tmpURL) }

        let watcher = CodexWatcher(store: SessionStore())
        let lines = watcher.readTailLines(atPath: tmpURL.path)

        XCTAssertNotNil(lines, "readTailLines must not return nil on a mid-character byte cut")
        XCTAssertFalse(lines?.isEmpty ?? true)
        XCTAssertTrue(lines?.contains(where: { $0.contains("hello after the split") }) ?? false)
    }

    func testReadTailLinesStillWorksForCleanUTF8File() throws {
        // Regression guard: a well-formed, small UTF-8 file (including
        // multi-byte characters, but none straddling the tail cut since the
        // whole file is far smaller than tailByteCount) must parse exactly
        // as before.
        let content = "line one\n日本語のテスト\nline three"
        let tmpURL = try writeTempFile(Data(content.utf8))
        defer { try? FileManager.default.removeItem(at: tmpURL) }

        let watcher = ClaudeWatcher(store: SessionStore())
        let lines = watcher.readTailLines(atPath: tmpURL.path)

        XCTAssertEqual(lines, ["line one", "日本語のテスト", "line three"])
    }

    private func writeTempFile(_ data: Data) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString + ".jsonl")
        try data.write(to: url)
        return url
    }

    // MARK: - Change detection: size alone is not enough

    func testClaudeNeedsReparseDetectsSameSizeDifferentModDate() {
        let modDate1 = Date(timeIntervalSince1970: 1_700_000_000)
        let modDate2 = Date(timeIntervalSince1970: 1_700_000_050)

        XCTAssertTrue(
            ClaudeWatcher.needsReparse(
                cachedSize: 1024, cachedModDate: modDate1,
                currentSize: 1024, currentModDate: modDate2
            ),
            "same size but different modification date must still trigger a re-parse"
        )

        XCTAssertFalse(
            ClaudeWatcher.needsReparse(
                cachedSize: 1024, cachedModDate: modDate1,
                currentSize: 1024, currentModDate: modDate1
            ),
            "identical size and modification date should be treated as unchanged"
        )
    }

    func testCodexNeedsReparseDetectsSameSizeDifferentModDate() {
        let modDate1 = Date(timeIntervalSince1970: 1_700_000_000)
        let modDate2 = Date(timeIntervalSince1970: 1_700_000_050)

        XCTAssertTrue(
            CodexWatcher.needsReparse(
                cachedSize: 2048, cachedModDate: modDate1,
                currentSize: 2048, currentModDate: modDate2
            )
        )
        XCTAssertFalse(
            CodexWatcher.needsReparse(
                cachedSize: 2048, cachedModDate: modDate1,
                currentSize: 2048, currentModDate: modDate1
            )
        )
    }
}
