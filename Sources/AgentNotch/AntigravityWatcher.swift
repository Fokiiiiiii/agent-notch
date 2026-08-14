import Foundation

/// Polls `~/.gemini/antigravity/conversations/` for the newest file
/// modification time and reflects a single synthetic Antigravity "session"
/// into a `SessionStore`. Read-only; Antigravity has no per-conversation
/// transcript format worth parsing here, so this only detects "is it active".
@MainActor
final class AntigravityWatcher {
    private let store: SessionStore
    private var timer: Timer?
    private let fileManager = FileManager.default
    private let conversationsURL: URL

    /// Poll rate while the panel is on screen.
    private let pollInterval: TimeInterval = 5.0
    /// …and while it isn't. Rescanning costs one tail-read and JSON parse
    /// per *active* session, which is why idle CPU scaled with session
    /// count (measured: 0.4% with one session, ~5% with nine). Approvals
    /// and questions arrive over the socket, not from this scan, so the
    /// only thing a slower rate delays is the freshness of a list nobody
    /// is looking at — and opening the panel rescans immediately.
    private let hiddenPollInterval: TimeInterval = 15.0
    private var isPanelVisible = false
    private let runningWindow: TimeInterval = 90
    private let idleWindow: TimeInterval = 30 * 60

    init(store: SessionStore) {
        self.store = store
        self.conversationsURL = fileManager.homeDirectoryForCurrentUser
            .appendingPathComponent(".gemini/antigravity/conversations", isDirectory: true)
    }

    /// Switches between the visible and hidden poll rates. Becoming visible
    /// rescans at once, so the list is current by the time it's drawn.
    func setPanelVisible(_ visible: Bool) {
        guard visible != isPanelVisible else { return }
        isPanelVisible = visible
        restartTimer()
        if visible { scan() }
    }

    func start() {
        scan()
        restartTimer()
    }

    private func restartTimer() {
        timer?.invalidate()
        let interval = isPanelVisible ? pollInterval : hiddenPollInterval
        let timer = Timer(timeInterval: interval, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.scan()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    private func scan() {
        let now = Date()
        guard let newestModDate = newestModificationDate() else {
            store.replaceSessions(agent: .antigravity, [])
            return
        }

        let elapsed = now.timeIntervalSince(newestModDate)
        guard elapsed <= idleWindow else {
            store.replaceSessions(agent: .antigravity, [])
            return
        }

        let state: SessionState = elapsed <= runningWindow ? .running : .idle
        let session = AgentSession(
            id: "antigravity",
            agent: .antigravity,
            title: "Antigravity",
            cwd: "",
            lastActivity: newestModDate,
            state: state,
            lastMessage: "Active"
        )
        store.replaceSessions(agent: .antigravity, [session])
    }

    private func newestModificationDate() -> Date? {
        guard let files = try? fileManager.contentsOfDirectory(
            at: conversationsURL,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) else {
            return nil
        }

        var newest: Date?
        for file in files {
            guard let attrs = try? fileManager.attributesOfItem(atPath: file.path) else { continue }
            guard let modDate = attrs[.modificationDate] as? Date else { continue }
            if newest == nil || modDate > newest! {
                newest = modDate
            }
        }
        return newest
    }
}
