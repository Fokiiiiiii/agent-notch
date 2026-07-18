import SwiftUI
import AppKit
import Combine

@main
struct AgentNotchApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        Settings {
            EmptyView()
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
    private var soundPlayer: SoundPlayer?
    private var store: SessionStore?
    private var collapseTask: Task<Void, Never>?
    private var hadPendingPermission = false
    private var cancellables = Set<AnyCancellable>()

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)

        let store = SessionStore()
        let permissionCenter = PermissionCenter()
        store.permissionCenter = permissionCenter
        let soundPlayer = SoundPlayer.shared

        let controller = NotchWindowController(store: store, permissions: permissionCenter)
        controller.showWindow()

        self.store = store
        self.permissionCenter = permissionCenter
        self.soundPlayer = soundPlayer
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
            }
        )
        server.start()
        self.socketServer = server

        permissionCenter.$queue
            .sink { [weak self] queue in
                self?.handleQueueChange(isEmpty: queue.isEmpty)
            }
            .store(in: &cancellables)
    }

    private func handle(event: HookEvent) {
        Self.logEvent(event)
        switch event.eventName {
        case "PermissionRequest":
            permissionCenter?.enqueue(event)
            soundPlayer?.play(.permission)
            notchWindowController?.forceShow()
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
