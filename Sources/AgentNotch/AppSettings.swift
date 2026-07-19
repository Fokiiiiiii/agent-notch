import Foundation
import Combine

/// Persisted, app-wide settings. This is the foundation for a future
/// settings UI — the controls themselves are added separately; this file
/// only wires up storage and the scaling knobs consumed elsewhere
/// (`NotchWindowController`, `DesignTokens`).
@MainActor
final class AppSettings: ObservableObject {
    static let shared = AppSettings()

    @Published var soundEnabled: Bool {
        didSet { UserDefaults.standard.set(soundEnabled, forKey: Keys.soundEnabled) }
    }
    @Published var languageOverride: String? {
        didSet { UserDefaults.standard.set(languageOverride, forKey: Keys.languageOverride) }
    }
    /// Global multiplier applied to notch window sizes (1.0 = current default sizes).
    @Published var uiScale: Double {
        didSet { UserDefaults.standard.set(uiScale, forKey: Keys.uiScale) }
    }
    /// Multiplier applied to corner radii (1.0 = current defaults).
    @Published var cornerRadiusScale: Double {
        didSet { UserDefaults.standard.set(cornerRadiusScale, forKey: Keys.cornerRadiusScale) }
    }
    /// Multiplier applied to animation/spring response durations (1.0 = current defaults).
    @Published var animationSpeedScale: Double {
        didSet { UserDefaults.standard.set(animationSpeedScale, forKey: Keys.animationSpeedScale) }
    }

    private enum Keys {
        static let soundEnabled = "agentnotch.soundEnabled"
        static let languageOverride = "agentnotch.languageOverride"
        static let uiScale = "agentnotch.uiScale"
        static let cornerRadiusScale = "agentnotch.cornerRadiusScale"
        static let animationSpeedScale = "agentnotch.animationSpeedScale"
    }

    private init() {
        let defaults = UserDefaults.standard
        soundEnabled = defaults.object(forKey: Keys.soundEnabled) as? Bool ?? true
        languageOverride = defaults.string(forKey: Keys.languageOverride)
        uiScale = defaults.object(forKey: Keys.uiScale) as? Double ?? 1.0
        cornerRadiusScale = defaults.object(forKey: Keys.cornerRadiusScale) as? Double ?? 1.0
        animationSpeedScale = defaults.object(forKey: Keys.animationSpeedScale) as? Double ?? 1.0
    }
}
