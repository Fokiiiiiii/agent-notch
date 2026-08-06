import XCTest
import Darwin
@testable import AgentNotch

@MainActor
final class QuestionCenterTests: XCTestCase {
    private func makeEvent(toolInput: [String: Any], toolName: String = "AskUserQuestion", connection: SocketConnection = SocketConnection(fd: -1)) -> HookEvent {
        HookEvent(
            eventName: "PreToolUse",
            sessionId: "test-session",
            cwd: "/tmp",
            toolName: toolName,
            toolInput: toolInput,
            connection: connection
        )
    }

    func testEnqueueKeepsAllQuestionsInOneRequestWhenMultipleArePresent() {
        let toolInput: [String: Any] = [
            "questions": [
                ["header": "Q1", "question": "First question?", "options": []],
                ["header": "Q2", "question": "Second question?", "options": []],
            ],
        ]

        let center = QuestionCenter()
        center.enqueue(makeEvent(toolInput: toolInput))

        // One hook invocation = one shared socket connection = one Request,
        // not one Request per sub-question (see QuestionCenter.resolve's
        // doc comment for why splitting them broke multi-question batches).
        XCTAssertEqual(center.queue.count, 1)
        XCTAssertEqual(center.queue.first?.questions.count, 2)
        XCTAssertEqual(center.queue.first?.questions[0].prompt, "First question?")
        XCTAssertEqual(center.queue.first?.questions[1].prompt, "Second question?")
    }

    func testEnqueueDoesNotTruncateOptionsToThree() {
        let options = (1...5).map { ["label": "Option \($0)", "description": ""] }
        let toolInput: [String: Any] = [
            "questions": [
                ["header": "Q1", "question": "Pick one", "options": options],
            ],
        ]

        let center = QuestionCenter()
        center.enqueue(makeEvent(toolInput: toolInput))

        XCTAssertEqual(center.queue.first?.questions.first?.options.count, 5)
    }

    func testEnqueuePreservesOriginalQuestionID() {
        let toolInput: [String: Any] = [
            "questions": [
                ["id": "q-abc", "header": "Q1", "question": "First?", "options": []],
                ["header": "Q2", "question": "Second?", "options": []],
            ],
        ]

        let center = QuestionCenter()
        center.enqueue(makeEvent(toolInput: toolInput))

        XCTAssertEqual(center.queue.count, 1)
        XCTAssertEqual(center.queue.first?.questions[0].sourceQuestionID, "q-abc")
        // No explicit "id" on the second question: falls back to its index
        // within the `questions` array.
        XCTAssertEqual(center.queue.first?.questions[1].sourceQuestionID, "1")
    }

    func testEnqueueFallsBackToMessageWhenNoQuestionsArray() {
        let toolInput: [String: Any] = ["message": "Agent needs attention"]

        let center = QuestionCenter()
        center.enqueue(makeEvent(toolInput: toolInput, toolName: "request_user_input"))

        XCTAssertEqual(center.queue.count, 1)
        XCTAssertEqual(center.queue.first?.questions.count, 1)
        XCTAssertEqual(center.queue.first?.prompt, "Agent needs attention")
        XCTAssertEqual(center.queue.first?.agent, .codex)
    }

    func testResolveSendsCombinedAnswerAndRemovesRequestFromQueue() {
        let toolInput: [String: Any] = [
            "questions": [
                ["header": "Q1", "question": "First?", "options": []],
                ["header": "Q2", "question": "Second?", "options": []],
            ],
        ]

        let center = QuestionCenter()
        center.enqueue(makeEvent(toolInput: toolInput))
        XCTAssertEqual(center.queue.count, 1)

        let id = center.queue[0].id
        center.resolve(id, answers: ["yes", "no"])

        // There's only ever one Request per batch now, so "only the
        // matching one is removed" collapses into "the queue is empty".
        XCTAssertTrue(center.queue.isEmpty)
    }

    /// The regression test for the actual bug: every sub-question in a
    /// batch shares one `SocketConnection`, which can only be responded to
    /// once (`SocketConnection.respond(json:)`'s `isClosed` guard). Before
    /// the fix, `QuestionCenter` split a batch into N independently
    /// resolvable `Request`s all pointing at that one connection — the
    /// first `resolve()` call would close it, silently dropping every
    /// answer after the first. This drives a real connected socket pair to
    /// prove exactly one response is ever written, with all answers combined.
    func testResolveRespondsOverSharedConnectionExactlyOnceForMultiQuestionBatch() throws {
        var fds: [Int32] = [0, 0]
        let result = fds.withUnsafeMutableBufferPointer { buffer -> Int32 in
            socketpair(AF_UNIX, SOCK_STREAM, 0, buffer.baseAddress)
        }
        XCTAssertEqual(result, 0, "socketpair() failed")
        let appSideFD = fds[0]
        let testSideFD = fds[1]
        defer { Darwin.close(testSideFD) }

        let connection = SocketConnection(fd: appSideFD)
        let toolInput: [String: Any] = [
            "questions": [
                ["header": "Q1", "question": "First?", "options": []],
                ["header": "Q2", "question": "Second?", "options": []],
                ["header": "Q3", "question": "Third?", "options": []],
            ],
        ]

        let center = QuestionCenter()
        center.enqueue(makeEvent(toolInput: toolInput, connection: connection))
        let id = try XCTUnwrap(center.queue.first?.id)

        center.resolve(id, answers: ["a1", "a2", "a3"])

        // Exactly one NDJSON line should have been written.
        var buffer = [UInt8](repeating: 0, count: 4096)
        let bytesRead = Darwin.read(testSideFD, &buffer, buffer.count)
        XCTAssertGreaterThan(bytesRead, 0, "expected a response to be written over the shared connection")
        let line = String(decoding: buffer[0..<bytesRead], as: UTF8.self)
        let json = try XCTUnwrap((try? JSONSerialization.jsonObject(with: Data(line.utf8))) as? [String: Any])
        let answer = try XCTUnwrap(json["answer"] as? String)
        XCTAssertEqual(answer, "Q1: a1\nQ2: a2\nQ3: a3")

        // The connection must be closed after the one response — a second
        // read on a closed peer returns 0 (EOF), never more data.
        let secondRead = Darwin.read(testSideFD, &buffer, buffer.count)
        XCTAssertEqual(secondRead, 0, "expected the connection to be closed after a single response")
    }

    /// Non-regression: the single-question wire format must stay byte-for-
    /// byte identical to what it was before this fix (no header prefix).
    func testResolveSingleQuestionAnswerMatchesLegacyWireFormat() throws {
        var fds: [Int32] = [0, 0]
        let result = fds.withUnsafeMutableBufferPointer { buffer -> Int32 in
            socketpair(AF_UNIX, SOCK_STREAM, 0, buffer.baseAddress)
        }
        XCTAssertEqual(result, 0, "socketpair() failed")
        let appSideFD = fds[0]
        let testSideFD = fds[1]
        defer { Darwin.close(testSideFD) }

        let connection = SocketConnection(fd: appSideFD)
        let toolInput: [String: Any] = [
            "questions": [
                ["header": "Q1", "question": "First?", "options": []],
            ],
        ]

        let center = QuestionCenter()
        center.enqueue(makeEvent(toolInput: toolInput, connection: connection))
        let id = try XCTUnwrap(center.queue.first?.id)

        center.resolve(id, answers: ["ok"])

        var buffer = [UInt8](repeating: 0, count: 4096)
        let bytesRead = Darwin.read(testSideFD, &buffer, buffer.count)
        XCTAssertGreaterThan(bytesRead, 0)
        let line = String(decoding: buffer[0..<bytesRead], as: UTF8.self)
        let json = try XCTUnwrap((try? JSONSerialization.jsonObject(with: Data(line.utf8))) as? [String: Any])
        XCTAssertEqual(json["answer"] as? String, "ok")
    }

    // MARK: - multiSelect (Phase 4)

    func testEnqueueParsesMultiSelectFlagPerQuestion() {
        let toolInput: [String: Any] = [
            "questions": [
                ["header": "Q1", "question": "Pick any", "options": [], "multiSelect": true],
                ["header": "Q2", "question": "Pick one", "options": []],
            ],
        ]

        let center = QuestionCenter()
        center.enqueue(makeEvent(toolInput: toolInput))

        XCTAssertEqual(center.queue.first?.questions[0].isMultiSelect, true)
        // Missing "multiSelect" defaults to false — the common (single-select) case.
        XCTAssertEqual(center.queue.first?.questions[1].isMultiSelect, false)
    }

    func testFallbackSyntheticQuestionIsNeverMultiSelect() {
        let center = QuestionCenter()
        center.enqueue(makeEvent(toolInput: ["message": "Need input"]))

        XCTAssertEqual(center.queue.first?.questions.first?.isMultiSelect, false)
    }
}
