/// Canonical list of agent identifiers shared between the AgentNotch GUI app
/// (`Sources/AgentNotch`) and the `agent-notch-bridge` CLI
/// (`Sources/agent-notch-bridge`).
///
/// `agent-notch-bridge` cannot import the `AgentNotch` target directly:
/// `AgentNotch` is an `executableTarget` (SwiftPM executables aren't
/// importable) and it links `SwiftUI`, which the bridge intentionally avoids
/// to stay a lightweight, dependency-free CLI. This small target is the
/// single source of truth for *which agent identifiers are valid*.
///
/// The full `AgentKind` enum (display name, accent color, symbol) still
/// lives in `Sources/AgentNotch/Models.swift`. When adding a new agent,
/// update BOTH `AgentKind`'s cases and `AgentIdentifiers.all` below.
public enum AgentIdentifiers {
    public static let all: [String] = [
        "claude", "codex", "antigravity", "gemini", "copilot", "cursor", "opencode", "aider", "goose",
        "mistral", "deepseek", "kimi",
        "zcode", "trae", "mimocode", "droid", "qoder", "qwen", "codebuddy", "workbuddy", "kiro", "hermes", "amp", "pi", "ohmypi", "gajae"
    ]
}
