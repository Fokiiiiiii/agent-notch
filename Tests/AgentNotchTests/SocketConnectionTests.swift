import XCTest
@testable import AgentNotch

/// Regression tests for `SocketConnection.setOnClose(_:)`, the fix for a
/// real connection-lifecycle bug: `respond`/`closeWithoutResponse` used to
/// close the raw fd without ever cancelling the owning `DispatchSourceRead`
/// or removing it from `SocketServer.connections`, leaving a zombie read
/// source registered on a descriptor number the kernel was free to hand
/// back to a brand-new `accept()` — see `SocketServer.detach(_:)`'s doc
/// comment for the full mechanism. These tests exercise the callback
/// contract in isolation (no real socket needed — `fd: -1` is the same safe
/// pattern the existing PermissionCenter/QuestionCenter tests use, since
/// `Darwin.write(-1, ...)`/`Darwin.close(-1)` just return EBADF harmlessly).
final class SocketConnectionTests: XCTestCase {
    func testRespondInvokesOnCloseExactlyOnce() {
        let connection = SocketConnection(fd: -1)
        var closeCount = 0
        connection.setOnClose { closeCount += 1 }

        connection.respond(json: ["ok": true])
        XCTAssertEqual(closeCount, 1)

        // Second call hits the pre-existing isClosed guard — must not fire again.
        connection.respond(json: ["ok": true])
        XCTAssertEqual(closeCount, 1)
    }

    func testCloseWithoutResponseInvokesOnCloseExactlyOnce() {
        let connection = SocketConnection(fd: -1)
        var closeCount = 0
        connection.setOnClose { closeCount += 1 }

        connection.closeWithoutResponse()
        XCTAssertEqual(closeCount, 1)

        connection.closeWithoutResponse()
        XCTAssertEqual(closeCount, 1)
    }

    func testRespondBehaviorConvenienceAlsoInvokesOnClose() {
        let connection = SocketConnection(fd: -1)
        var closeCount = 0
        connection.setOnClose { closeCount += 1 }

        connection.respond(behavior: "allow")
        XCTAssertEqual(closeCount, 1)
    }

    func testCloseWithoutResponseAfterRespondDoesNotDoubleFireOnClose() {
        // Whichever close path runs first wins; the second is always a no-op.
        let connection = SocketConnection(fd: -1)
        var closeCount = 0
        connection.setOnClose { closeCount += 1 }

        connection.respond(json: ["ok": true])
        connection.closeWithoutResponse()

        XCTAssertEqual(closeCount, 1)
    }

    func testConnectionWithoutOnCloseRegisteredBehavesExactlyAsBefore() {
        // Real production behavior for callers that never call setOnClose
        // (there are none left in Sources/, but PermissionCenter/
        // QuestionCenter/PlanCenter's test fakes construct SocketConnection
        // directly without it) — respond/closeWithoutResponse must still
        // work, with isClosed guarding double-response as before.
        let connection = SocketConnection(fd: -1)
        connection.respond(json: ["answer": "ok"])
        connection.respond(json: ["answer": "should not resend"])
        // No crash, no assertion possible on the (fd: -1) write itself —
        // this test's value is purely "doesn't crash without a callback".
    }
}
