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

extension PermissionCenter.PendingPermission {
    /// Structured fields extracted from `toolInput`, letting
    /// `ApprovalOverlayView` render a dangerous-command warning without
    /// re-parsing `toolInput` itself.
    var details: ApprovalDetails {
        ApprovalDetails.extract(toolName: toolName, toolInput: toolInput)
    }
}

/// Pure and independently testable — mirrors `MediaKeyDecoder.decodeSkipDirection`'s
/// style (no `PermissionCenter`/UI dependency).
struct ApprovalDetails: Equatable {
    let isDangerous: Bool

    static func extract(toolName: String, toolInput: [String: Any]) -> ApprovalDetails {
        guard toolName == "Bash", let command = toolInput["command"] as? String else {
            return ApprovalDetails(isDangerous: false)
        }
        return ApprovalDetails(isDangerous: DangerousCommandDetector.isDangerous(command: command))
    }
}

/// A heuristic nudge for the human reviewing an approval card — not a safety
/// boundary AgentNotch enforces itself (it only relays the human's Allow/Deny
/// decision back to the blocked agent; it never allows/denies on its own).
/// Not exhaustive — a best-effort flag for commands worth a second look.
enum DangerousCommandDetector {
    static let patterns = [
        "rm -rf", "rm -fr", "sudo ", "git push --force", "git push -f",
        "chmod -r 777", "dd if=", "mkfs", ":(){ :|:& };:",
        // Piping a download straight into a shell interpreter — the risky
        // part is the pipe-to-shell itself, not literally "curl | bash"
        // adjacency (real invocations are usually "curl <url> | bash").
        "| sh", "| bash", "| zsh", "|sh", "|bash", "|zsh",
        "> /dev/sd", "> /dev/disk", "diskutil erasedisk", "diskutil erasevolume",
    ]

    static func isDangerous(command: String) -> Bool {
        let lower = command.lowercased()
        return patterns.contains { lower.contains($0) }
    }
}
