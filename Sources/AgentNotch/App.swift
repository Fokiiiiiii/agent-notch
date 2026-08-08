import SwiftUI
import AppKit
import Combine
import Darwin

@main
struct AgentNotchApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        Settings {
            SettingsView(settings: AppSettings.shared)
        }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var notchWindowController: NotchWindowController?
    private var claudeWatcher: ClaudeWatcher?
    private var codexWatcher: CodexWatcher?
    private var antigravityWatcher: AntigravityWatcher?
    private var socketServer: SocketServer?
    private var permissionCenter: PermissionCenter?
    private var questionCenter: QuestionCenter?
    private var planCenter: PlanCenter?
    private var soundPlayer: SoundPlayer?
    private var nativeNotifier: NativeNotifier?
    private var store: SessionStore?
    private var collapseTask: Task<Void, Never>?
    private var hadPendingPermission = false
    private var cancellables = Set<AnyCancellable>()

    func applicationDidFinishLaunching(_ notification: Notification) {
        signal(SIGPIPE, SIG_IGN)
        NSApp.setActivationPolicy(.accessory)

        let store = SessionStore()
        let permissionCenter = PermissionCenter()
        let questionCenter = QuestionCenter()
        let planCenter = PlanCenter()
        store.permissionCenter = permissionCenter
        let soundPlayer = SoundPlayer.shared
        let nativeNotifier = NativeNotifier.shared
        nativeNotifier.requestAuthorizationIfNeeded()

        let controller = NotchWindowController(store: store, permissions: permissionCenter, questions: questionCenter, plans: planCenter, nativeNotifier: nativeNotifier)
        controller.showWindow()

        self.store = store
        self.permissionCenter = permissionCenter
        self.questionCenter = questionCenter
        self.planCenter = planCenter
        self.soundPlayer = soundPlayer
        self.nativeNotifier = nativeNotifier
        self.notchWindowController = controller

        let watcher = ClaudeWatcher(store: store)
        watcher.start()
        self.claudeWatcher = watcher

        let codexWatcher = CodexWatcher(store: store)
        codexWatcher.start()
        self.codexWatcher = codexWatcher

        let antigravityWatcher = AntigravityWatcher(store: store)
        antigravityWatcher.start()
        self.antigravityWatcher = antigravityWatcher

        let server = SocketServer(
            onEvent: { [weak self] event in
                self?.handle(event: event)
            },
            onCancel: { [weak self] connection in
                self?.permissionCenter?.cancel(connection: connection)
                self?.questionCenter?.cancel(connection: connection)
                self?.planCenter?.cancel(connection: connection)
            },
            onStartupFailure: { [weak self] in
                // Best-effort only, same as every other `nativeNotifier`
                // call in this file: if `isAuthorized` hasn't resolved yet
                // (this can fire moments after `requestAuthorizationIfNeeded()`,
                // before its async callback returns), `notify()` silently
                // no-ops. No retry — matches NativeNotifier's own policy.
                self?.nativeNotifier?.notify(
                    title: String(localized: "notification.socketServerFailure.title", defaultValue: "AgentNotch can't receive events"),
                    body: String(localized: "notification.socketServerFailure.body", defaultValue: "The local socket failed to start. Hook events from Claude/Codex won't reach the notch until AgentNotch is restarted.")
                )
            }
        )
        server.start()
        self.socketServer = server

        permissionCenter.$queue
            .sink { [weak self] queue in
                self?.handleQueueChange(isEmpty: queue.isEmpty)
            }
            .store(in: &cancellables)

        NotificationCenter.default.publisher(for: .agentNotchReplayOnboarding)
            .sink { [weak controller] _ in
                controller?.showOnboarding(force: true)
            }
            .store(in: &cancellables)

        // First run only — explains the gestures, since an `.accessory` app
        // with no Dock icon gives no other hint that the notch is
        // interactive at all. Shown in the notch rather than a window: the
        // gestures it describes only exist there. No-op on later launches.
        controller.showOnboarding()
    }

    private func handle(event: HookEvent) {
        Self.logEvent(event)
        switch event.eventName {
        case "AgentNotchPing":
            event.connection?.respond(json: [
                "ok": true,
                "sessions": store?.sessions.count ?? 0,
                "questions": questionCenter?.queue.count ?? 0,
                "permissions": permissionCenter?.queue.count ?? 0,
                "mode": notchWindowController?.debugMode ?? "missing",
                "overlay": notchWindowController?.debugOverlay ?? "missing",
                "visible": notchWindowController?.debugVisible ?? false,
                "persists": notchWindowController?.debugPersists ?? false,
                "screenInfo": notchWindowController?.debugScreenInfo ?? [:],
                "nativeNotifier": nativeNotifier?.debugInfo ?? [:],
                "version": 1,
            ])
        case "AgentNotchShow":
            let mode = (event.toolInput["mode"] as? String) == "hover" ? IslandMode.hover : IslandMode.open
            notchWindowController?.showFromCLI(mode: mode)
        case "AgentNotchHide":
            notchWindowController?.hideFromCLI()
        case "AgentNotchToggle":
            notchWindowController?.toggleOpen()
        case "AgentNotchSession":
            store?.applyHookEvent(event)
            let action = event.toolInput["action"] as? String ?? "update"
            let urgent = action == "attention" || action == "fail"
            notchWindowController?.showAgentActivity(urgent: urgent)
            soundPlayer?.play(action == "done" ? .done : urgent ? .sessionAttention : .action)
        case "AgentNotchPlanWaiting":
            notchWindowController?.showNotification(title: "Plan ready", message: "Approve in the terminal to continue")
            soundPlayer?.play(.action)
        case "PermissionRequest":
            permissionCenter?.enqueue(event)
            soundPlayer?.play(.permission)
            notchWindowController?.showAttention()
        case "PreToolUse" where event.toolName == "AskUserQuestion" || event.toolName == "request_user_input":
            questionCenter?.enqueue(event)
            soundPlayer?.play(.question)
            notchWindowController?.showAttention()
        case "AgentNotchQuestion":
            questionCenter?.enqueue(event)
            soundPlayer?.play(.question)
            notchWindowController?.showAttention()
        case "AgentNotchPlanReview":
            planCenter?.enqueue(event)
            soundPlayer?.play(.plan)
            notchWindowController?.showAttention()
        case "Notification":
            let message = (event.toolInput["message"] as? String) ?? "Notification"
            if event.toolInput["notification_type"] as? String == "agent_needs_input" {
                questionCenter?.enqueue(event)
                soundPlayer?.play(.question)
                notchWindowController?.showAttention()
            } else {
                notchWindowController?.showNotification(title: "Agent", message: message)
                soundPlayer?.play(.action)
            }
            nativeNotifier?.notify(title: "AgentNotch", body: message)
        case "Stop", "CodexTurnComplete":
            store?.applyHookEvent(event)
            soundPlayer?.play(.done)
        default:
            store?.applyHookEvent(event)
        }
    }

    /// Append-only event log for debugging hook delivery (~/.agent-notch/events.log).
    private static func logEvent(_ event: HookEvent) {
        let line = "\(ISO8601DateFormatter().string(from: Date())) \(event.eventName) session=\(event.sessionId) tool=\(event.toolName ?? "-")\n"
        let url = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".agent-notch/events.log")
        if let handle = try? FileHandle(forWritingTo: url) {
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: Data(line.utf8))
            try? handle.close()
        } else {
            try? Data(line.utf8).write(to: url)
        }
    }

    private func handleQueueChange(isEmpty: Bool) {
        collapseTask?.cancel()
        if !isEmpty {
            hadPendingPermission = true
            return
        }
        // Ignore the publisher's initial empty value. Only a real transition
        // from pending to empty should schedule the post-approval collapse.
        guard hadPendingPermission else { return }
        hadPendingPermission = false
        collapseTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            guard !Task.isCancelled else { return }
            guard let self else { return }
            guard self.permissionCenter?.queue.isEmpty == true else { return }
            guard self.notchWindowController?.isHovering != true else { return }
            guard self.notchWindowController?.isPinnedOpen != true else { return }
            self.notchWindowController?.setMode(.closed)
        }
    }
}
