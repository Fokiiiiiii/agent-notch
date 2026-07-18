import AppKit

/// Activates the running terminal app (if any) so the user can jump to it
/// from a notch session row. Best-effort: does nothing if no known terminal
/// app is currently running.
@MainActor
enum Jumper {
    /// Preference order: iTerm2, WezTerm, Ghostty, Warp, Terminal.app.
    private static let terminalBundleIDs = [
        "com.googlecode.iterm2",
        "com.github.wez.wezterm",
        "com.mitchellh.ghostty",
        "dev.warp.Warp-Stable",
        "com.apple.Terminal",
    ]

    static func jump(to session: AgentSession) {
        let running = NSWorkspace.shared.runningApplications
        for bundleID in terminalBundleIDs {
            if let app = running.first(where: { $0.bundleIdentifier == bundleID }) {
                app.activate()
                return
            }
        }
    }
}
