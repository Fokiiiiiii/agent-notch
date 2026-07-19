import Foundation
import UserNotifications

/// Posts native macOS notifications for hook events that arrive while the
/// notch itself may not be visible/hovered. Best-effort only: an unsigned
/// manual bundle may fail to authorize, and that must never crash or hang
/// the app — every failure path here is silently logged and swallowed.
@MainActor
final class NativeNotifier {
    private var isAuthorized = false
    private var didRequestAuthorization = false

    func requestAuthorizationIfNeeded() {
        guard !didRequestAuthorization else { return }
        didRequestAuthorization = true
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { [weak self] granted, error in
            Task { @MainActor in
                self?.isAuthorized = granted
                if let error {
                    FileHandle.standardError.write("agent-notch: notification auth error: \(error.localizedDescription)\n".data(using: .utf8)!)
                }
            }
        }
    }

    func notify(title: String, body: String) {
        guard isAuthorized else { return }
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = nil // AgentNotch plays its own cue; avoid a double sound.
        let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request) { error in
            if let error {
                FileHandle.standardError.write("agent-notch: notification post error: \(error.localizedDescription)\n".data(using: .utf8)!)
            }
        }
    }
}
