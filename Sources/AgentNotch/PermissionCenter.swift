import Foundation

/// Tracks PermissionRequest hook events awaiting an Allow/Deny decision from
/// the notch UI. Each entry keeps the open `SocketConnection` so a decision
/// can be written straight back to the blocked bridge process.
@MainActor
final class PermissionCenter: ObservableObject {
    struct PendingPermission: Identifiable {
        let id: UUID
        let sessionId: String
        let cwd: String
        let toolName: String
        let summary: String
        let connectionRef: SocketConnection
    }

    @Published var queue: [PendingPermission] = []

    func enqueue(_ event: HookEvent) {
        guard let connection = event.connection else { return }
        let toolName = event.toolName ?? "Unknown"
        let pending = PendingPermission(
            id: UUID(),
            sessionId: event.sessionId,
            cwd: event.cwd,
            toolName: toolName,
            summary: Self.summarize(toolName: toolName, toolInput: event.toolInput),
            connectionRef: connection
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
        switch toolName {
        case "Bash":
            if let command = toolInput["command"] as? String {
                return truncate(command)
            }
        case "Edit", "Write", "Read":
            if let filePath = toolInput["file_path"] as? String {
                return truncate(filePath)
            }
        default:
            break
        }
        if let data = try? JSONSerialization.data(withJSONObject: toolInput),
           let str = String(data: data, encoding: .utf8) {
            return truncate(str)
        }
        return ""
    }

    private static func truncate(_ s: String, _ limit: Int = 60) -> String {
        s.count > limit ? String(s.prefix(limit)) + "…" : s
    }
}
