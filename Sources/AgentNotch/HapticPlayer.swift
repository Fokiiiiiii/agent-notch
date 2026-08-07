import AppKit

/// Two coarse haptic categories — enough to distinguish a positive
/// confirmation (approve / pick an answer) from a negative one (deny) by
/// feel alone, mirroring `AppSound`'s split without trying to match its
/// finer-grained cue count.
enum AppHaptic {
    case confirm, reject
}

/// A thin wrapper around `NSHapticFeedbackManager`, styled after
/// `SoundPlayer`'s shared-singleton + `AppSettings`-gated `play`/`perform`
/// shape. On Macs without a Force Touch trackpad, `NSHapticFeedbackManager`
/// silently no-ops (Apple's documented behavior), so no availability check
/// or fallback is needed here.
@MainActor
final class HapticPlayer {
    static let shared = HapticPlayer()

    private init() {}

    func perform(_ haptic: AppHaptic) {
        guard AppSettings.shared.hapticsEnabled else { return }
        let pattern: NSHapticFeedbackManager.FeedbackPattern = haptic == .confirm ? .levelChange : .generic
        NSHapticFeedbackManager.defaultPerformer.perform(pattern, performanceTime: .now)
    }
}
