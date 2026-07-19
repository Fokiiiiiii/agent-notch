import SwiftUI

enum AgentKind: String, CaseIterable, Hashable, Sendable {
    case claude, codex, antigravity, gemini, copilot, cursor, opencode, aider, goose
    // Usage-dashboard-only providers (Stage 4): no watcher ever creates
    // sessions for these, they exist purely for AgentUsageStore rows.
    case mistral, deepseek, kimi
    case zcode, trae, mimocode, droid, qoder, qwen, codebuddy, workbuddy, kiro, hermes, amp, pi, ohmypi, gajae

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
        case .mistral: return "Mistral Vibe"
        case .deepseek: return "DeepSeek"
        case .kimi: return "Kimi Code"
        case .zcode: return "ZCode"
        case .trae: return "Trae"
        case .mimocode: return "MiMoCode"
        case .droid: return "Droid"
        case .qoder: return "Qoder"
        case .qwen: return "Qwen"
        case .codebuddy: return "CodeBuddy"
        case .workbuddy: return "WorkBuddy"
        case .kiro: return "Kiro"
        case .hermes: return "Hermes"
        case .amp: return "Amp"
        case .pi: return "Pi Agent"
        case .ohmypi: return "Oh My Pi"
        case .gajae: return "Gajae Code"
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
        case .mistral: return Color(red: 0.95, green: 0.55, blue: 0.15)
        case .deepseek: return Color(red: 0.25, green: 0.45, blue: 0.95)
        case .kimi: return Color(red: 0.15, green: 0.75, blue: 0.65)
        case .zcode: return Color(red: 0.1, green: 0.6, blue: 0.9)
        case .trae: return Color(red: 0.2, green: 0.8, blue: 0.6)
        case .mimocode: return Color(red: 0.9, green: 0.4, blue: 0.6)
        case .droid: return Color(red: 0.64, green: 0.79, blue: 0.22)
        case .qoder: return Color(red: 0.5, green: 0.3, blue: 0.8)
        case .qwen: return Color(red: 0.4, green: 0.3, blue: 0.9)
        case .codebuddy: return Color(red: 0.95, green: 0.6, blue: 0.1)
        case .workbuddy: return Color(red: 0.3, green: 0.7, blue: 0.9)
        case .kiro: return Color(red: 0.9, green: 0.2, blue: 0.3)
        case .hermes: return Color(red: 0.7, green: 0.5, blue: 0.3)
        case .amp: return Color(red: 0.9, green: 0.8, blue: 0.1)
        case .pi: return Color(red: 0.1, green: 0.8, blue: 0.5)
        case .ohmypi: return Color(red: 0.2, green: 0.6, blue: 0.8)
        case .gajae: return Color(red: 0.8, green: 0.3, blue: 0.7)
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
        case .mistral: return "wind"
        case .deepseek: return "magnifyingglass"
        case .kimi: return "moon.stars.fill"
        case .zcode: return "z.circle.fill"
        case .trae: return "t.circle.fill"
        case .mimocode: return "m.circle.fill"
        case .droid: return "play.computer"
        case .qoder: return "q.circle.fill"
        case .qwen: return "brain.head.profile"
        case .codebuddy: return "person.2.fill"
        case .workbuddy: return "briefcase.fill"
        case .kiro: return "k.circle.fill"
        case .hermes: return "bolt.fill"
        case .amp: return "waveform.path.ecg"
        case .pi: return "percent"
        case .ohmypi: return "face.smiling"
        case .gajae: return "g.circle.fill"
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
