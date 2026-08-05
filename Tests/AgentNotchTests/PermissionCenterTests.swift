import XCTest
@testable import AgentNotch

@MainActor
final class PermissionCenterTests: XCTestCase {
    private func makeEvent(toolName: String, toolInput: [String: Any]) -> HookEvent {
        HookEvent(
            eventName: "PermissionRequest",
            sessionId: "test-session",
            cwd: "/tmp",
            toolName: toolName,
            toolInput: toolInput,
            connection: SocketConnection(fd: -1)
        )
    }

    func testSummaryPreservesLongCommandWithoutTruncation() {
        let longCommand = String(repeating: "echo hello world && ", count: 10) + "done"
        XCTAssertGreaterThan(longCommand.count, 60)

        let center = PermissionCenter()
        center.enqueue(makeEvent(toolName: "Bash", toolInput: ["command": longCommand]))

        XCTAssertEqual(center.queue.count, 1)
        XCTAssertEqual(center.queue.first?.summary, longCommand)
        XCTAssertFalse(center.queue.first?.summary.hasSuffix("…") ?? true)
    }

    func testSummaryPreservesLongFilePathWithoutTruncation() {
        let longPath = "/Users/chaos/Documents/agent-notch/" + String(repeating: "a-very-long-directory-name/", count: 5) + "File.swift"
        XCTAssertGreaterThan(longPath.count, 60)

        let center = PermissionCenter()
        center.enqueue(makeEvent(toolName: "Edit", toolInput: ["file_path": longPath]))

        XCTAssertEqual(center.queue.first?.summary, longPath)
    }

    func testPendingPermissionRetainsOriginalToolInput() {
        let toolInput: [String: Any] = [
            "command": "rm -rf build",
            "description": "Clean build artifacts"
        ]

        let center = PermissionCenter()
        center.enqueue(makeEvent(toolName: "Bash", toolInput: toolInput))

        guard let pending = center.queue.first else {
            return XCTFail("expected a pending permission")
        }
        XCTAssertEqual(pending.toolInput["command"] as? String, "rm -rf build")
        XCTAssertEqual(pending.toolInput["description"] as? String, "Clean build artifacts")
    }
}
