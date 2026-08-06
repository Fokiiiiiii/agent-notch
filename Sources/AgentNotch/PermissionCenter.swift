import Foundation

/// Tracks PermissionRequest hook events awaiting an Allow/Deny decision from
/// the notch UI. Each entry keeps the open `SocketConnection` so a decision
/// can be written straight back to the blocked bridge process.
@MainActor
final class PermissionCenter: ObservableObject {
    struct PendingPermission: Identifiable {
        let id: UUID
        let agent: AgentKind
        let sessionId: String
        let cwd: String
        let toolName: String
        let summary: String
        let toolInput: [String: Any]
        let connectionRef: SocketConnection
        /// Used by `AttentionCenter` to sort/tie-break the unified attention
        /// list — see its doc comment. Not read anywhere in this file.
        let occurredAt: Date
    }

    @Published var queue: [PendingPermission] = []

    func enqueue(_ event: HookEvent) {
        guard let connection = event.connection else { return }
        let toolName = event.toolName ?? "Unknown"
        let pending = PendingPermission(
            id: UUID(),
            agent: (event.toolInput["agent"] as? String).flatMap(AgentKind.init(rawValue:)) ?? .claude,
            sessionId: event.sessionId,
            cwd: event.cwd,
            toolName: toolName,
            summary: Self.summarize(toolName: toolName, toolInput: event.toolInput),
            toolInput: event.toolInput,
            connectionRef: connection,
            occurredAt: Date()
        )
        queue.append(pending)
    }

    func resolve(_ id: UUID, behavior: String) {
        guard let index = queue.firstIndex(where: { $0.id == id }) else { return }
        let pending = queue[index]
        pending.connectionRef.respond(behavior: behavior)
        queue.remove(at: index)
    }

    /// Called when a connection drops before the user decided (e.g. the
    /// bridge process was killed by the hook timeout).
    func cancel(connection: SocketConnection) {
        queue.removeAll { $0.connectionRef === connection }
    }

    private static func summarize(toolName: String, toolInput: [String: Any]) -> String {
        if let summary = toolInput["summary"] as? String {
            return summary
        }
        switch toolName {
        case "Bash":
            if let command = toolInput["command"] as? String {
                return command
            }
        case "Edit", "Write", "Read":
            if let filePath = toolInput["file_path"] as? String {
                return filePath
            }
        default:
            break
        }
        if let data = try? JSONSerialization.data(withJSONObject: toolInput),
           let str = String(data: data, encoding: .utf8) {
            return str
        }
        return ""
    }
}
