import AppKit
import AgentNotchCore

/// Activates the running terminal app (if any) so the user can jump to it
/// from a notch session row. Best-effort, two-tier strategy:
///
/// Tier 1: identify the agent process backing this session (by matching its
/// cwd against `session.cwd`), walk up its process ancestry to find the
/// terminal app that actually hosts it, and activate that specific instance.
/// Tier 2: if the resolved terminal is iTerm2 or Terminal.app, additionally
/// select the exact tab/session whose tty matches the agent process via
/// AppleScript.
///
/// Falls back to the previous fixed-priority "activate the first known
/// terminal app that's running" behavior whenever Tier 1 can't resolve a
/// specific target, so existing behavior is never regressed.
@MainActor
enum Jumper {
    /// Preference order: iTerm2, WezTerm, Ghostty, Warp, Terminal.app, Kitty,
    /// VS Code (integrated terminal).
    ///
    /// Kitty and VS Code are Tier 1 only (activate-the-app precision): Kitty
    /// has no AppleScript dictionary to select a specific tab, and VS Code's
    /// AppleScript surface can only activate the whole editor window, so
    /// tab-level precision (Tier 2) is meaningless for either — see
    /// `jumpToTab` below, which intentionally does not branch on these IDs.
    static nonisolated let terminalBundleIDs = [
        "com.googlecode.iterm2",
        "com.github.wez.wezterm",
        "com.mitchellh.ghostty",
        "dev.warp.Warp-Stable",
        "com.apple.Terminal",
        "net.kovidgoyal.kitty",
        "com.microsoft.VSCode",
    ]

    /// Fire-and-forget: all process-execution work (PID lookup, ancestry
    /// walk, tty resolution, AppleScript) runs off the main thread via
    /// `Task.detached`; only the final AppKit calls (`activate()`) hop back
    /// to the main actor. Kept synchronous so call sites don't need to
    /// change (mirrors the background-then-hop-to-main pattern used by
    /// `DashboardServices`).
    static func jump(to session: AgentSession) {
        Task.detached(priority: .userInitiated) {
            let resolution = resolveTarget(for: session)
            await MainActor.run {
                switch resolution {
                case let .resolved(targetApp, agentPID):
                    targetApp.activate()
                    // Tier 2: best-effort tab-level precision for iTerm2/Terminal.app.
                    // Also process-heavy (another `ps` + AppleScript), so keep it
                    // off the main thread too.
                    Task.detached(priority: .userInitiated) {
                        jumpToTab(bundleID: targetApp.bundleIdentifier, agentPID: agentPID)
                    }
                case .unresolved:
                    fallbackActivateFirstKnownTerminal()
                }
            }
        }
    }

    /// Result of the (off-main) Tier 1 resolution step.
    private enum TargetResolution {
        case resolved(NSRunningApplication, pid_t)
        case unresolved
    }

    /// Runs entirely off the main thread: resolves the agent's PID and walks
    /// its process ancestry to find the hosting terminal app.
    private static nonisolated func resolveTarget(for session: AgentSession) -> TargetResolution {
        guard let processName = processName(for: session.agent),
              let agentPID = findAgentPID(processName: processName, cwd: session.cwd),
              let targetApp = findTerminalAncestor(startingAt: agentPID) else {
            return .unresolved
        }
        return .resolved(targetApp, agentPID)
    }

    // MARK: - Tier 1: locate the agent process and its hosting terminal

    static nonisolated func processName(for agent: AgentKind) -> String? {
        switch agent {
        case .claude, .codex:
            return agent.rawValue
        default:
            return nil
        }
    }

    /// Runs `pgrep -x <processName>` and returns the PID whose cwd (via
    /// `lsof -a -p <pid> -d cwd -Fn`) matches `cwd`.
    private static nonisolated func findAgentPID(processName: String, cwd: String) -> pid_t? {
        guard let pgrepOutput = run(executable: "/usr/bin/pgrep", arguments: ["-x", processName]) else {
            return nil
        }
        let candidatePIDs = pgrepOutput
            .split(separator: "\n")
            .compactMap { pid_t($0.trimmingCharacters(in: .whitespaces)) }

        for pid in candidatePIDs {
            guard let lsofOutput = run(
                executable: "/usr/sbin/lsof",
                arguments: ["-a", "-p", String(pid), "-d", "cwd", "-Fn"]
            ) else { continue }

            for line in lsofOutput.split(separator: "\n") where line.hasPrefix("n") {
                let path = String(line.dropFirst())
                if path == cwd {
                    return pid
                }
            }
        }
        return nil
    }

    /// Walks up the process ancestry (max 15 hops) looking for a running
    /// terminal app among the ancestors.
    private static nonisolated func findTerminalAncestor(startingAt pid: pid_t) -> NSRunningApplication? {
        var currentPID = pid
        for _ in 0..<15 {
            guard let ppidOutput = run(executable: "/bin/ps", arguments: ["-o", "ppid=", "-p", String(currentPID)]),
                  let ppid = pid_t(ppidOutput.trimmingCharacters(in: .whitespacesAndNewlines)),
                  ppid > 1 else {
                return nil
            }
            if let app = NSRunningApplication(processIdentifier: ppid),
               let bundleID = app.bundleIdentifier,
               terminalBundleIDs.contains(bundleID) {
                return app
            }
            currentPID = ppid
        }
        return nil
    }

    // MARK: - Tier 2: tab-level precision via AppleScript (best-effort)

    private static nonisolated func jumpToTab(bundleID: String?, agentPID: pid_t) {
        guard bundleID == "com.googlecode.iterm2" || bundleID == "com.apple.Terminal" else { return }
        guard let ttyOutput = run(executable: "/bin/ps", arguments: ["-o", "tty=", "-p", String(agentPID)]) else {
            return
        }
        let tty = ttyOutput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard tty.range(of: #"^ttys\d+$"#, options: .regularExpression) != nil else { return }
        let ttyPath = "/dev/" + tty

        let script: String
        switch bundleID {
        case "com.googlecode.iterm2":
            script = """
            tell application "iTerm2"
                repeat with w in windows
                    repeat with t in tabs of w
                        repeat with s in sessions of t
                            if (tty of s) is "\(ttyPath)" then
                                select t
                                select s
                                set index of w to 1
                                activate
                                return
                            end if
                        end repeat
                    end repeat
                end repeat
            end tell
            """
        case "com.apple.Terminal":
            script = """
            tell application "Terminal"
                repeat with w in windows
                    repeat with t in tabs of w
                        if tty of t is "\(ttyPath)" then
                            set selected of t to true
                            set frontmost of w to true
                            activate
                            return
                        end if
                    end repeat
                end repeat
            end tell
            """
        default:
            return
        }

        guard let appleScript = NSAppleScript(source: script) else { return }
        var errorInfo: NSDictionary?
        appleScript.executeAndReturnError(&errorInfo)
        // Failures (including "no matching tab") are ignored: Tier 1 already
        // activated the app, so that's an acceptable outcome on its own.
    }

    // MARK: - Fallback: fixed-priority "first known terminal running"

    private static func fallbackActivateFirstKnownTerminal() {
        let running = NSWorkspace.shared.runningApplications
        for bundleID in terminalBundleIDs {
            if let app = running.first(where: { $0.bundleIdentifier == bundleID }) {
                app.activate()
                return
            }
        }
    }

    // MARK: - Shell helper

    private static nonisolated func run(executable: String, arguments: [String]) -> String? {
        let process = Process()
        let output = Pipe()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            let data = output.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            guard process.terminationStatus == 0 else { return nil }
            return String(data: data, encoding: .utf8)
        } catch {
            return nil
        }
    }
}
