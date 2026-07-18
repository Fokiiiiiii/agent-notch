import AppKit

enum AppSound {
    case done, permission
}

/// Plays short notification sounds, debounced so rapid-fire events (e.g. a
/// burst of Stop hooks) don't stack.
@MainActor
final class SoundPlayer {
    private var lastPlayedAt: [String: Date] = [:]
    private let debounceInterval: TimeInterval = 1.0

    func play(_ sound: AppSound) {
        let name: String
        let key: String
        switch sound {
        case .done:
            name = "Glass"
            key = "done"
        case .permission:
            name = "Ping"
            key = "permission"
        }

        let now = Date()
        if let last = lastPlayedAt[key], now.timeIntervalSince(last) < debounceInterval {
            return
        }
        lastPlayedAt[key] = now

        guard let nsSound = NSSound(named: name) else { return }
        nsSound.volume = 0.4
        nsSound.play()
    }
}
