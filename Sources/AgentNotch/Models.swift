import SwiftUI

enum AgentKind: String {
    case claude, codex, antigravity

    var displayName: String {
        switch self {
        case .claude: return "Claude"
        case .codex: return "Codex"
        case .antigravity: return "Antigravity"
        }
    }

    var accentColor: Color {
        switch self {
        case .claude: return .orange
        case .codex: return .white.opacity(0.9)
        case .antigravity: return .cyan
        }
    }

    var symbolName: String {
        switch self {
        case .claude: return "sparkle"
        case .codex: return "chevron.left.forwardslash.chevron.right"
        case .antigravity: return "paperplane.fill"
        }
    }
}

enum SessionState {
    // NOTE: `failed` has no producer yet (ClaudeWatcher/hooks never emit it);
    // it exists so the UI's status-dot mapping matches the design mock.
    case running, waitingApproval, done, idle, failed
}

struct AgentSession: Identifiable {
    let id: String
    var agent: AgentKind
    var title: String        // 例 "fix auth bug"
    var cwd: String
    var lastActivity: Date
    var state: SessionState
    var lastMessage: String  // 例 "Writing middleware.ts"
}
