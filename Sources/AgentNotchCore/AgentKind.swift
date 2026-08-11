/// The agents AgentNotch knows about, and their human-readable names.
///
/// Lives in this small target — rather than in the GUI app — because
/// `agent-notch-bridge` needs the same list to validate its `--agent`
/// argument, and it cannot import `AgentNotch`: that's an `executableTarget`
/// (SwiftPM executables aren't importable) which links SwiftUI, a dependency
/// the CLI deliberately avoids.
///
/// Presentation that needs SwiftUI (`accentColor`, `symbolName`) is added
/// back as an extension in `Sources/AgentNotch/Models.swift`. Adding an
/// agent is a single edit here — this used to be duplicated as a parallel
/// `AgentIdentifiers.all` array that had to be kept in sync by hand.
public enum AgentKind: String, CaseIterable, Hashable, Sendable, Codable {
    case claude, codex, antigravity, gemini, copilot, cursor, opencode, aider, goose
    // Usage-dashboard-only providers (Stage 4): no watcher ever creates
    // sessions for these, they exist purely for AgentUsageStore rows.
    case mistral, deepseek, kimi
    case zcode, trae, mimocode, droid, qoder, qwen, codebuddy, workbuddy, kiro, hermes, amp, pi, ohmypi, gajae

    public var displayName: String {
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
}
