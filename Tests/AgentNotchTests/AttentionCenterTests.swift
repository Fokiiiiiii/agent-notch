import XCTest
@testable import AgentNotch

@MainActor
final class AttentionCenterTests: XCTestCase {
    private func permissionEvent(sessionId: String = "perm-session") -> HookEvent {
        HookEvent(
            eventName: "PermissionRequest",
            sessionId: sessionId,
            cwd: "/tmp",
            toolName: "Bash",
            toolInput: ["command": "echo hi"],
            connection: SocketConnection(fd: -1)
        )
    }

    private func questionEvent(sessionId: String = "question-session") -> HookEvent {
        HookEvent(
            eventName: "PreToolUse",
            sessionId: sessionId,
            cwd: "/tmp",
            toolName: "AskUserQuestion",
            toolInput: ["questions": [["header": "Q1", "question": "Pick one?", "options": []]]],
            connection: SocketConnection(fd: -1)
        )
    }

    private func planEvent(sessionId: String = "plan-session") -> HookEvent {
        HookEvent(
            eventName: "AgentNotchPlanReview",
            sessionId: sessionId,
            cwd: "/tmp",
            toolName: nil,
            toolInput: ["title": "My Plan", "summary": "Do the thing"],
            connection: SocketConnection(fd: -1)
        )
    }

    // MARK: - AttentionCenter.sorted (pure)

    func testSortedPutsPermissionAboveOtherTypes() {
        let permissions = PermissionCenter()
        let questions = QuestionCenter()
        let plans = PlanCenter()
        permissions.enqueue(permissionEvent())
        questions.enqueue(questionEvent())
        plans.enqueue(planEvent())

        let items = AttentionCenter.sorted(permissions: permissions.queue, questions: questions.queue, plans: plans.queue)

        XCTAssertEqual(items.first?.urgency, .permission)
    }

    func testSortedPutsPlanAboveQuestion() {
        let questions = QuestionCenter()
        let plans = PlanCenter()
        questions.enqueue(questionEvent())
        plans.enqueue(planEvent())

        let items = AttentionCenter.sorted(permissions: [], questions: questions.queue, plans: plans.queue)

        // Preserves the exact order the old hand-rolled if/else chains used
        // (permission > plan > question) — plan wins over question.
        XCTAssertEqual(items.first?.urgency, .plan)
    }

    func testSortedIsEmptyWhenAllQueuesEmpty() {
        XCTAssertTrue(AttentionCenter.sorted(permissions: [], questions: [], plans: []).isEmpty)
    }

    func testSortedWithinSameUrgencyOrdersOldestFirst() {
        let permissions = PermissionCenter()
        permissions.enqueue(permissionEvent(sessionId: "first"))
        permissions.enqueue(permissionEvent(sessionId: "second"))

        let items = AttentionCenter.sorted(permissions: permissions.queue, questions: [], plans: [])

        XCTAssertEqual(items.count, 2)
        if case .permission(let p) = items[0].source {
            XCTAssertEqual(p.sessionId, "first")
        } else {
            XCTFail("expected a permission item first")
        }
    }

    func testSortedPreservesAllItemsCountAcrossTypes() {
        let permissions = PermissionCenter()
        let questions = QuestionCenter()
        let plans = PlanCenter()
        permissions.enqueue(permissionEvent())
        permissions.enqueue(permissionEvent(sessionId: "perm-2"))
        questions.enqueue(questionEvent())
        plans.enqueue(planEvent())

        let items = AttentionCenter.sorted(permissions: permissions.queue, questions: questions.queue, plans: plans.queue)

        XCTAssertEqual(items.count, 4)
    }

    // MARK: - AttentionCenter (Combine wiring)

    func testAttentionCenterPublishesWhenAnySourceQueueChanges() {
        let permissions = PermissionCenter()
        let questions = QuestionCenter()
        let plans = PlanCenter()
        let attention = AttentionCenter(permissions: permissions, questions: questions, plans: plans)

        XCTAssertTrue(attention.items.isEmpty)

        permissions.enqueue(permissionEvent())

        XCTAssertEqual(attention.items.count, 1)
        XCTAssertEqual(attention.items.first?.urgency, .permission)
    }

    func testAttentionCenterItemsShrinksAfterResolve() {
        let permissions = PermissionCenter()
        let questions = QuestionCenter()
        let plans = PlanCenter()
        let attention = AttentionCenter(permissions: permissions, questions: questions, plans: plans)

        permissions.enqueue(permissionEvent())
        XCTAssertEqual(attention.items.count, 1)

        guard let id = permissions.queue.first?.id else {
            return XCTFail("expected a queued permission")
        }
        permissions.resolve(id, behavior: "allow")

        XCTAssertTrue(attention.items.isEmpty)
    }
}
