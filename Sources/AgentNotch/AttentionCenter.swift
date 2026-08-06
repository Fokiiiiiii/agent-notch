import Foundation
import Combine

/// Sort priority for the unified attention list — higher wins. Preserves
/// the exact ordering the old hand-rolled if/else chains in
/// `NotchWindowController.syncOverlay()` and `NotchView.swift`'s
/// `compactAgentContent` both independently used: permission > plan >
/// question. `rawValue` doubles as the sort key.
enum AttentionUrgency: Int, Comparable, CaseIterable {
    case question = 0
    case plan = 1
    case permission = 2

    static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }
}

/// One item in the unified, read-only attention list — a `PermissionCenter`/
/// `QuestionCenter`/`PlanCenter` request wrapped with enough metadata to
/// sort/display it uniformly, without touching those Centers' own
/// data-fetch/resolve/cancel logic at all (see `AttentionCenter`).
struct AttentionItem: Identifiable {
    enum Source {
        case permission(PermissionCenter.PendingPermission)
        case plan(PlanCenter.Request)
        case question(QuestionCenter.Request)
    }

    let source: Source
    let occurredAt: Date

    var id: UUID {
        switch source {
        case .permission(let p): return p.id
        case .plan(let p): return p.id
        case .question(let q): return q.id
        }
    }

    var agent: AgentKind {
        switch source {
        case .permission(let p): return p.agent
        case .plan(let p): return p.agent
        case .question(let q): return q.agent
        }
    }

    var urgency: AttentionUrgency {
        switch source {
        case .permission: return .permission
        case .plan: return .plan
        case .question: return .question
        }
    }

    var elapsed: TimeInterval { Date().timeIntervalSince(occurredAt) }
}

/// Unifies `PermissionCenter`/`QuestionCenter`/`PlanCenter`'s three
/// independent queues into one sorted, read-only `[AttentionItem]` list —
/// purely a derived display/coordination layer. Holds no state of its own
/// beyond what's republished from the three source `$queue` publishers, and
/// never calls `enqueue`/`resolve`/`cancel` on any of them.
///
/// Session failure/attention states (`AgentSession.state == .failed/
/// .waitingApproval`, surfaced via `NotchWindowController.showAgentActivity`)
/// are deliberately NOT folded in here — there's no id-tracked, dismissable
/// queue entry for those today, and inventing "who resolves it and how"
/// would be a real behavior change with no spec. `AttentionItem.Source`
/// being an enum leaves room to add a `.sessionAttention(AgentSession)` case
/// later without reshaping anything that already exists.
@MainActor
final class AttentionCenter: ObservableObject {
    @Published private(set) var items: [AttentionItem] = []

    private var cancellable: AnyCancellable?

    init(permissions: PermissionCenter, questions: QuestionCenter, plans: PlanCenter) {
        cancellable = Publishers.CombineLatest3(permissions.$queue, questions.$queue, plans.$queue)
            .map { permissionQueue, questionQueue, planQueue in
                Self.sorted(permissions: permissionQueue, questions: questionQueue, plans: planQueue)
            }
            .assign(to: \.items, on: self)
    }

    /// Pure and independently testable — see `AttentionCenterTests.swift`.
    /// Sorted by urgency descending, tied items oldest-first (FIFO), matching
    /// the fairness reasoning already established for `IslandOverlay.approval`'s
    /// `otherAgentPending` (a busy agent must not starve an older pending
    /// request by always jumping the queue).
    static func sorted(
        permissions: [PermissionCenter.PendingPermission],
        questions: [QuestionCenter.Request],
        plans: [PlanCenter.Request]
    ) -> [AttentionItem] {
        let items: [AttentionItem] =
            permissions.map { AttentionItem(source: .permission($0), occurredAt: $0.occurredAt) }
            + questions.map { AttentionItem(source: .question($0), occurredAt: $0.occurredAt) }
            + plans.map { AttentionItem(source: .plan($0), occurredAt: $0.occurredAt) }
        return items.sorted { lhs, rhs in
            if lhs.urgency != rhs.urgency { return lhs.urgency > rhs.urgency }
            return lhs.occurredAt < rhs.occurredAt
        }
    }
}
