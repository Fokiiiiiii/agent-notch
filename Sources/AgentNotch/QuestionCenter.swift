import Foundation
import Combine

@MainActor
final class QuestionCenter: ObservableObject {
    struct Option: Identifiable {
        let id = UUID()
        let label: String
        let detail: String
    }

    struct Request: Identifiable {
        let id = UUID()
        let agent: AgentKind
        let sessionID: String
        let prompt: String
        let header: String
        let options: [Option]
        let connection: SocketConnection?
    }

    @Published private(set) var queue: [Request] = []

    func enqueue(_ event: HookEvent) {
        let first = (event.toolInput["questions"] as? [[String: Any]])?.first
        let prompt = (first?["question"] as? String)
            ?? (event.toolInput["message"] as? String)
            ?? "Agent needs your input"
        let header = (first?["header"] as? String) ?? "Agent asks"
        let options = ((first?["options"] as? [[String: Any]]) ?? []).prefix(3).map {
            Option(
                label: ($0["label"] as? String) ?? "Option",
                detail: ($0["description"] as? String) ?? ""
            )
        }
        let request = Request(
            agent: event.toolName == "request_user_input" ? .codex : .claude,
            sessionID: event.sessionId,
            prompt: prompt,
            header: header,
            options: options,
            connection: event.connection
        )
        queue = queue + [request]
    }

    func resolve(_ id: UUID, answer: String) {
        guard let index = queue.firstIndex(where: { $0.id == id }) else { return }
        let request = queue[index]
        var updated = queue
        updated.remove(at: index)
        queue = updated
        request.connection?.respond(json: ["answer": answer])
    }

    func cancel(connection: SocketConnection) {
        queue = queue.filter { $0.connection !== connection }
    }
}
