import AppKit

enum AppSound {
    case done, permission, approve, deny, navigation, action
}

/// Plays short notification sounds, debounced so rapid-fire events (e.g. a
/// burst of Stop hooks) don't stack.
@MainActor
final class SoundPlayer {
    static let shared = SoundPlayer()

    private var lastPlayedAt: [String: Date] = [:]
    func play(_ sound: AppSound) {
        let name: String
        let key: String
        let volume: Float
        let debounceInterval: TimeInterval
        switch sound {
        case .done:
            name = "Glass"
            key = "done"
            volume = 0.35
            debounceInterval = 1.0
        case .permission:
            name = "Ping"
            key = "permission"
            volume = 0.3
            debounceInterval = 1.0
        case .approve:
            name = "Tink"
            key = "approve"
            volume = 0.28
            debounceInterval = 0.15
        case .deny:
            name = "Basso"
            key = "deny"
            volume = 0.18
            debounceInterval = 0.15
        case .navigation:
            name = "Pop"
            key = "navigation"
            volume = 0.1
            debounceInterval = 0.08
        case .action:
            name = "Tink"
            key = "action"
            volume = 0.14
            debounceInterval = 0.12
        }

        let now = Date()
        if let last = lastPlayedAt[key], now.timeIntervalSince(last) < debounceInterval {
            return
        }
        lastPlayedAt[key] = now

        guard let nsSound = NSSound(named: name) else { return }
        nsSound.volume = volume
        nsSound.play()
    }
}
