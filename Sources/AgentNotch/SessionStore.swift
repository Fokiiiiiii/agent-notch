import Foundation

@MainActor
final class SessionStore: ObservableObject {
    @Published var sessions: [AgentSession]

    /// Hook-driven overrides keyed by session id, layered on top of the
    /// transcript-derived state until they expire or are superseded.
    private var hookOverrides: [String: (state: SessionState, at: Date)] = [:]
    private let overrideTTL: TimeInterval = 5 * 60

    /// Set by AppDelegate after both objects exist. Used to decide whether a
    /// `.waitingApproval` override is still live.
    weak var permissionCenter: PermissionCenter?

    init() {
        self.sessions = []
    }

    var hasActivity: Bool {
        sessions.contains { $0.state == .running || $0.state == .waitingApproval }
    }

    var isEmpty: Bool {
        sessions.isEmpty
    }

    /// Applies a hook event's effect on session state overrides. Agent-
    /// agnostic: any watcher's sessions can be overridden by session id, as
    /// long as the id space doesn't collide across agents.
    func applyHookEvent(_ e: HookEvent) {
        switch e.eventName {
        case "Stop", "CodexTurnComplete":
            hookOverrides[e.sessionId] = (.done, Date())
        case "PermissionRequest":
            hookOverrides[e.sessionId] = (.waitingApproval, Date())
        case "SessionStart":
            hookOverrides.removeValue(forKey: e.sessionId)
        default:
            break
        }
    }

    /// Replaces all Claude sessions with `new`, preserving sessions from other agents.
    /// Result is sorted by lastActivity descending.
    func replaceClaudeSessions(_ new: [AgentSession]) {
        replaceSessions(agent: .claude, new)
    }

    /// Replaces all sessions for `agent` with `new`, preserving sessions from
    /// other agents, applying live hook overrides, and re-sorting the full
    /// list by lastActivity descending.
    func replaceSessions(agent: AgentKind, _ new: [AgentSession]) {
        let now = Date()

        // Drop overrides older than the TTL.
        for (sessionId, entry) in hookOverrides where now.timeIntervalSince(entry.at) > overrideTTL {
            hookOverrides.removeValue(forKey: sessionId)
        }

        var updated = new
        for i in updated.indices {
            let sessionId = updated[i].id
            guard let override = hookOverrides[sessionId] else { continue }

            switch override.state {
            case .done:
                if updated[i].lastActivity > override.at {
                    // Work resumed after the Stop/TurnComplete hook fired; drop the override.
                    hookOverrides.removeValue(forKey: sessionId)
                } else {
                    updated[i].state = .done
                }
            case .waitingApproval:
                if permissionCenter?.queue.contains(where: { $0.sessionId == sessionId }) == true {
                    updated[i].state = .waitingApproval
                } else {
                    hookOverrides.removeValue(forKey: sessionId)
                }
            default:
                break
            }
        }

        var merged = sessions.filter { $0.agent != agent }
        merged.append(contentsOf: updated)
        merged.sort { $0.lastActivity > $1.lastActivity }
        sessions = merged
    }
}
