import SwiftUI

enum AgentKind: String, Hashable, Sendable {
    case claude, codex, antigravity, gemini, copilot, cursor, opencode, aider, goose

    var displayName: String {
        switch self {
        case .claude: return "Claude"
        case .codex: return "Codex"
        case .antigravity: return "Antigravity"
        case .gemini: return "Gemini"
        case .copilot: return "Copilot"
        case .cursor: return "Cursor"
        case .opencode: return "OpenCode"
        case .aider: return "Aider"
        case .goose: return "Goose"
        }
    }

    var accentColor: Color {
        switch self {
        case .claude: return Color(red: 0.85, green: 0.45, blue: 0.35)
        case .codex: return .white.opacity(0.9)
        case .antigravity: return .cyan
        case .gemini: return Color(red: 0.45, green: 0.55, blue: 1.0)
        case .copilot: return Color(red: 0.55, green: 0.45, blue: 0.95)
        case .cursor: return Color(red: 0.2, green: 0.7, blue: 0.9)
        case .opencode: return Color(red: 0.2, green: 0.85, blue: 0.5)
        case .aider: return Color(red: 0.95, green: 0.35, blue: 0.35)
        case .goose: return Color(red: 0.98, green: 0.65, blue: 0.2)
        }
    }

    var symbolName: String {
        switch self {
        case .claude: return "sparkle"
        case .codex: return "chevron.left.forwardslash.chevron.right"
        case .antigravity: return "paperplane.fill"
        case .gemini: return "diamond.fill"
        case .copilot: return "infinity"
        case .cursor: return "cursorarrow"
        case .opencode: return "terminal.fill"
        case .aider: return "hammer.fill"
        case .goose: return "bird.fill"
        }
    }
}

enum SessionState {
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
    var processID: Int32? = nil
    var isManagedProcess: Bool = false
}
