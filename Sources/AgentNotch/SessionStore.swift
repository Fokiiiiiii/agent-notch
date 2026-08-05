import Foundation
import Darwin

/// PID再利用検知用のプロセス識別情報の取得と照合。純粋な照合ロジックを
/// 単体テストしやすいよう`internal`な静的関数として切り出す。
enum ProcessInspector {
    struct Fingerprint: Equatable {
        var startedAt: Date?
        var executablePath: String?
    }

    static func fingerprint(for pid: Int32) -> Fingerprint {
        Fingerprint(startedAt: startTime(for: pid), executablePath: executablePath(for: pid))
    }

    static func executablePath(for pid: Int32) -> String? {
        // PROC_PIDPATHINFO_MAXSIZE (4 * MAXPATHLEN) はマクロがSwiftから見えないため直値を使用。
        var buf = [Int8](repeating: 0, count: 4 * 1024)
        let ret = proc_pidpath(pid, &buf, UInt32(buf.count))
        guard ret > 0 else { return nil }
        return String(cString: buf)
    }

    static func startTime(for pid: Int32) -> Date? {
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        let ret = sysctl(&mib, u_int(mib.count), &info, &size, nil, 0)
        guard ret == 0, size > 0 else { return nil }
        let tv = info.kp_proc.p_un.__p_starttime
        guard tv.tv_sec != 0 else { return nil }
        let seconds = Double(tv.tv_sec) + Double(tv.tv_usec) / 1_000_000.0
        return Date(timeIntervalSince1970: seconds)
    }

    /// 記録済みのフィンガープリントと、指定PIDの現在の状態を照合する。
    /// 記録された値が両方nilの場合（旧セッション等で取得できなかった場合）は
    /// 後方互換のため常に一致とみなす。
    static func matches(recordedStartedAt: Date?, recordedExecutablePath: String?, pid: Int32) -> Bool {
        if recordedStartedAt == nil && recordedExecutablePath == nil {
            return true
        }
        let current = fingerprint(for: pid)
        if let recorded = recordedExecutablePath {
            guard current.executablePath == recorded else { return false }
        }
        if let recorded = recordedStartedAt {
            guard let currentStart = current.startedAt else { return false }
            // sysctlの時刻粒度による微小な誤差を許容する。
            guard abs(currentStart.timeIntervalSince(recorded)) < 2.0 else { return false }
        }
        return true
    }
}

@MainActor
final class SessionStore: ObservableObject {
    @Published var sessions: [AgentSession]

    /// Hook-driven overrides keyed by session id, layered on top of the
    /// transcript-derived state until they expire or are superseded.
    private var hookOverrides: [String: (state: SessionState, at: Date)] = [:]
    private var cliSessions: [String: AgentSession] = [:]
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

    /// Controls only processes launched through `agent-notch run`. Transcript-
    /// discovered sessions deliberately remain read-only because guessing a PID
    /// could signal an unrelated terminal process.
    func controlManagedSession(id: String, action: ManagedSessionAction) -> Bool {
        guard var session = cliSessions[id], session.isManagedProcess,
              let pid = session.processID, pid > 1 else { return false }
        guard ProcessInspector.matches(
            recordedStartedAt: session.processStartedAt,
            recordedExecutablePath: session.processExecutablePath,
            pid: pid
        ) else { return false }
        let signal: Int32
        switch action {
        case .pause: signal = SIGSTOP
        case .resume: signal = SIGCONT
        case .stop: signal = SIGTERM
        }
        guard Darwin.kill(pid, signal) == 0 else { return false }
        switch action {
        case .pause:
            session.state = .idle
            session.lastMessage = "Paused"
        case .resume:
            session.state = .running
            session.lastMessage = "Resumed"
        case .stop:
            session.lastMessage = "Stopping…"
        }
        session.lastActivity = Date()
        cliSessions[id] = session
        if let index = sessions.firstIndex(where: { $0.id == id }) {
            sessions[index] = session
        }
        return true
    }

    /// Applies a hook event's effect on session state overrides. Agent-
    /// agnostic: any watcher's sessions can be overridden by session id, as
    /// long as the id space doesn't collide across agents.
    func applyHookEvent(_ e: HookEvent) {
        switch e.eventName {
        case "AgentNotchSession":
            applyCLIEvent(e)
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
        let cliForAgent = cliSessions.values.filter { $0.agent == agent }
        let cliIDs = Set(cliForAgent.map(\.id))
        updated.removeAll { cliIDs.contains($0.id) }
        merged.append(contentsOf: updated)
        merged.append(contentsOf: cliForAgent)
        merged.sort { $0.lastActivity > $1.lastActivity }
        sessions = merged
    }

    private func applyCLIEvent(_ event: HookEvent) {
        let input = event.toolInput
        let action = (input["action"] as? String) ?? "update"
        let id = event.sessionId.isEmpty ? "cli-\(event.cwd)" : event.sessionId

        if action == "remove" {
            cliSessions.removeValue(forKey: id)
            sessions.removeAll { $0.id == id }
            return
        }

        let agent = AgentKind(rawValue: (input["agent"] as? String) ?? "claude") ?? .claude
        let existing = cliSessions[id]
        let state: SessionState
        switch action {
        case "done": state = .done
        case "fail": state = .failed
        case "attention": state = .waitingApproval
        case "pause": state = .idle
        default: state = .running
        }

        let cwd = event.cwd.isEmpty ? (existing?.cwd ?? FileManager.default.currentDirectoryPath) : event.cwd

        let newPid = (input["pid"] as? NSNumber)?.int32Value
        let resolvedProcessID: Int32?
        let resolvedStartedAt: Date?
        let resolvedExecutablePath: String?
        if let newPid {
            // 新しいPIDが渡された場合のみフィンガープリントを取得し直す。
            let fingerprint = ProcessInspector.fingerprint(for: newPid)
            resolvedProcessID = newPid
            resolvedStartedAt = fingerprint.startedAt
            resolvedExecutablePath = fingerprint.executablePath
        } else {
            resolvedProcessID = existing?.processID
            resolvedStartedAt = existing?.processStartedAt
            resolvedExecutablePath = existing?.processExecutablePath
        }

        let isTerminal = (state == .done || state == .failed)
        let session = AgentSession(
            id: id,
            agent: agent,
            title: (input["title"] as? String) ?? existing?.title ?? URL(fileURLWithPath: cwd).lastPathComponent,
            cwd: cwd,
            lastActivity: Date(),
            state: state,
            lastMessage: (input["message"] as? String) ?? existing?.lastMessage ?? action.capitalized,
            processID: isTerminal ? nil : resolvedProcessID,
            isManagedProcess: isTerminal ? false : ((input["managed"] as? Bool) ?? existing?.isManagedProcess ?? false),
            processStartedAt: isTerminal ? nil : resolvedStartedAt,
            processExecutablePath: isTerminal ? nil : resolvedExecutablePath
        )
        cliSessions[id] = session
        sessions.removeAll { $0.id == id }
        sessions.append(session)
        sessions.sort { $0.lastActivity > $1.lastActivity }
    }
}

enum ManagedSessionAction {
    case pause, resume, stop
}
