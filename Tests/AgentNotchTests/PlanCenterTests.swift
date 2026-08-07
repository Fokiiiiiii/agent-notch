import XCTest
import Darwin
@testable import AgentNotch

@MainActor
final class PlanCenterTests: XCTestCase {
    private func makeEvent(toolInput: [String: Any], connection: SocketConnection = SocketConnection(fd: -1)) -> HookEvent {
        HookEvent(
            eventName: "AgentNotchPlanReview",
            sessionId: "test-session",
            cwd: "/tmp/project",
            toolName: nil,
            toolInput: toolInput,
            connection: connection
        )
    }

    func testEnqueueBuildsRequestFromToolInput() throws {
        let center = PlanCenter()
        center.enqueue(makeEvent(toolInput: [
            "agent": "codex",
            "title": "Refactor auth module",
            "summary": "Extract token validation into its own file.",
        ]))

        XCTAssertEqual(center.queue.count, 1)
        let request = try XCTUnwrap(center.queue.first)
        XCTAssertEqual(request.agent, .codex)
        XCTAssertEqual(request.sessionID, "test-session")
        XCTAssertEqual(request.cwd, "/tmp/project")
        XCTAssertEqual(request.title, "Refactor auth module")
        XCTAssertEqual(request.summary, "Extract token validation into its own file.")
    }

    func testEnqueueFallsBackToDefaultTitleAndSummaryWhenMissing() throws {
        let center = PlanCenter()
        center.enqueue(makeEvent(toolInput: [:]))

        let request = try XCTUnwrap(center.queue.first)
        XCTAssertEqual(request.title, "Plan Review")
        XCTAssertEqual(request.summary, "Review the proposed implementation plan.")
    }

    func testEnqueueDefaultsToClaudeWhenAgentMissingOrInvalid() {
        let center = PlanCenter()
        center.enqueue(makeEvent(toolInput: [:]))
        XCTAssertEqual(center.queue.first?.agent, .claude)

        let center2 = PlanCenter()
        center2.enqueue(makeEvent(toolInput: ["agent": "not-a-real-agent"]))
        XCTAssertEqual(center2.queue.first?.agent, .claude)
    }

    func testEnqueueAppendsMultipleRequestsIndependently() {
        let center = PlanCenter()
        center.enqueue(makeEvent(toolInput: ["title": "Plan A"]))
        center.enqueue(makeEvent(toolInput: ["title": "Plan B"]))

        XCTAssertEqual(center.queue.count, 2)
        XCTAssertEqual(center.queue[0].title, "Plan A")
        XCTAssertEqual(center.queue[1].title, "Plan B")
    }

    /// Real connected socket pair (same pattern as
    /// `QuestionCenterTests`/`PermissionCenterTests`' `fd: -1` fakes, but a
    /// live pair here since this test needs to actually read back what
    /// `respond(json:)` wrote) — verifies `resolve` both removes only the
    /// matching request from the queue and sends `decision`/`comment` over
    /// the wire.
    func testResolveRemovesOnlyMatchingRequestAndRespondsWithDecisionAndComment() throws {
        var fds: [Int32] = [0, 0]
        let result = fds.withUnsafeMutableBufferPointer { buffer -> Int32 in
            socketpair(AF_UNIX, SOCK_STREAM, 0, buffer.baseAddress)
        }
        XCTAssertEqual(result, 0, "socketpair() failed")
        let appSideFD = fds[0]
        let testSideFD = fds[1]
        defer { Darwin.close(testSideFD) }

        let connection = SocketConnection(fd: appSideFD)
        let center = PlanCenter()
        center.enqueue(makeEvent(toolInput: ["title": "Keep me"]))
        center.enqueue(makeEvent(toolInput: ["title": "Resolve me"], connection: connection))
        XCTAssertEqual(center.queue.count, 2)

        let targetID = try XCTUnwrap(center.queue.last?.id)
        center.resolve(targetID, decision: "allow", comment: "looks good")

        XCTAssertEqual(center.queue.count, 1, "only the resolved request should leave the queue")
        XCTAssertEqual(center.queue.first?.title, "Keep me")

        var buffer = [UInt8](repeating: 0, count: 4096)
        let bytesRead = Darwin.read(testSideFD, &buffer, buffer.count)
        XCTAssertGreaterThan(bytesRead, 0, "expected a response over the connection")
        let line = String(decoding: buffer[0..<bytesRead], as: UTF8.self)
        let json = try XCTUnwrap((try? JSONSerialization.jsonObject(with: Data(line.utf8))) as? [String: Any])
        XCTAssertEqual(json["decision"] as? String, "allow")
        XCTAssertEqual(json["comment"] as? String, "looks good")
    }

    func testResolveOnUnknownIDIsNoOp() {
        let center = PlanCenter()
        center.enqueue(makeEvent(toolInput: ["title": "Only plan"]))
        XCTAssertEqual(center.queue.count, 1)

        center.resolve(UUID(), decision: "allow", comment: "")

        XCTAssertEqual(center.queue.count, 1, "resolving an unknown id must not touch the queue")
        XCTAssertEqual(center.queue.first?.title, "Only plan")
    }

    func testCancelRemovesOnlyRequestsForThatConnection() {
        let connectionA = SocketConnection(fd: -1)
        let connectionB = SocketConnection(fd: -1)

        let center = PlanCenter()
        center.enqueue(makeEvent(toolInput: ["title": "From A"], connection: connectionA))
        center.enqueue(makeEvent(toolInput: ["title": "From B"], connection: connectionB))
        XCTAssertEqual(center.queue.count, 2)

        center.cancel(connection: connectionA)

        XCTAssertEqual(center.queue.count, 1)
        XCTAssertEqual(center.queue.first?.title, "From B")
    }
}
