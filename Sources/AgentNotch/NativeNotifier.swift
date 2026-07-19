import Foundation
import UserNotifications
import SwiftUI
import AppKit

/// Posts native macOS notifications for hook events that arrive while the
/// notch itself may not be visible/hovered. Best-effort only: an unsigned
/// manual bundle may fail to authorize, and that must never crash or hang
/// the app — every failure path here is silently logged and swallowed.
@MainActor
final class NativeNotifier {
    private(set) var isAuthorized = false
    private var didRequestAuthorization = false
    private(set) var lastAuthorizationError: String?

    /// Diagnostic snapshot for `agent-notch ping`, so an authorization
    /// failure (e.g. an unsigned/ad-hoc `.app` bundle that usernoted refuses
    /// to register) shows up immediately instead of `notify()` silently
    /// no-op'ing forever.
    var debugInfo: [String: Any] {
        [
            "isAuthorized": isAuthorized,
            "didRequestAuthorization": didRequestAuthorization,
            "lastAuthorizationError": lastAuthorizationError ?? NSNull(),
        ]
    }

    func requestAuthorizationIfNeeded() {
        guard !didRequestAuthorization else { return }
        didRequestAuthorization = true
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { [weak self] granted, error in
            Task { @MainActor in
                self?.isAuthorized = granted
                if let error {
                    self?.lastAuthorizationError = error.localizedDescription
                    FileHandle.standardError.write("agent-notch: notification auth error: \(error.localizedDescription)\n".data(using: .utf8)!)
                } else if !granted {
                    self?.lastAuthorizationError = "authorization denied (granted=false, no error)"
                }
            }
        }
    }

    func notify(title: String, body: String, agentGlyph: AgentKind? = nil) {
        guard isAuthorized else { return }
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = nil // AgentNotch plays its own cue; avoid a double sound.
        if let agentGlyph, let attachment = renderGlyphAttachment(for: agentGlyph) {
            content.attachments = [attachment]
        }
        let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request) { error in
            if let error {
                FileHandle.standardError.write("agent-notch: notification post error: \(error.localizedDescription)\n".data(using: .utf8)!)
            }
        }
    }

    /// Renders the notch's glyph pill (agent icon on a rounded dark
    /// background) off-screen and packages it as a notification image
    /// attachment. Best-effort only: any failure here must fall back to a
    /// text-only notification, never block or crash delivery.
    private func renderGlyphAttachment(for agent: AgentKind) -> UNNotificationAttachment? {
        let renderer = ImageRenderer(content: GlyphBox(agent: agent))
        renderer.scale = 2
        guard let nsImage = renderer.nsImage else {
            FileHandle.standardError.write("agent-notch: glyph render produced no image\n".data(using: .utf8)!)
            return nil
        }
        guard let tiffData = nsImage.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiffData),
              let pngData = bitmap.representation(using: .png, properties: [:]) else {
            FileHandle.standardError.write("agent-notch: glyph PNG conversion failed\n".data(using: .utf8)!)
            return nil
        }
        let fileURL = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).png")
        do {
            try pngData.write(to: fileURL)
            return try UNNotificationAttachment(identifier: UUID().uuidString, url: fileURL, options: nil)
        } catch {
            FileHandle.standardError.write("agent-notch: glyph attachment error: \(error.localizedDescription)\n".data(using: .utf8)!)
            return nil
        }
    }
}
