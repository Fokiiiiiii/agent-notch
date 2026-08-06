import Foundation

@MainActor
final class PlanCenter: ObservableObject {
    struct Request: Identifiable {
        let id = UUID()
        let agent: AgentKind
        let sessionID: String
        let cwd: String
        let title: String
        let summary: String
        let connection: SocketConnection?
        /// Used by `AttentionCenter` to sort/tie-break the unified attention
        /// list — see its doc comment. Not read anywhere in this file.
        let occurredAt: Date
    }

    @Published private(set) var queue: [Request] = []

    func enqueue(_ event: HookEvent) {
        queue.append(Request(
            agent: (event.toolInput["agent"] as? String).flatMap(AgentKind.init(rawValue:)) ?? .claude,
            sessionID: event.sessionId,
            cwd: event.cwd,
            title: (event.toolInput["title"] as? String) ?? String(localized: "plan.fallbackTitle", defaultValue: "Plan Review"),
            summary: (event.toolInput["summary"] as? String) ?? String(localized: "plan.fallbackSummary", defaultValue: "Review the proposed implementation plan."),
            connection: event.connection,
            occurredAt: Date()
        ))
    }

    func resolve(_ id: UUID, decision: String, comment: String) {
        guard let index = queue.firstIndex(where: { $0.id == id }) else { return }
        let request = queue.remove(at: index)
        request.connection?.respond(json: ["decision": decision, "comment": comment])
    }

    func cancel(connection: SocketConnection) {
        queue.removeAll { $0.connection === connection }
    }
}
