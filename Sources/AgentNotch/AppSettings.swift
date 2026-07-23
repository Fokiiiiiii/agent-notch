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
    /// Per-tab widget layout (order/visibility/size). Keyed by a stable tab
    /// identifier (e.g. `"agents"`, `"media"`, `"today"`, `"system"`). Not
    /// yet editable from any UI — this is the storage foundation a future
    /// "customize layout" settings screen will read/write. Absence of a key
    /// means "use the built-in default order, all widgets visible."
    @Published var tabLayouts: [String: TabLayoutConfiguration] {
        didSet {
            if let data = try? JSONEncoder().encode(tabLayouts) {
                UserDefaults.standard.set(data, forKey: Keys.tabLayouts)
            }
        }
    }

    private enum Keys {
        static let soundEnabled = "agentnotch.soundEnabled"
        static let languageOverride = "agentnotch.languageOverride"
        static let uiScale = "agentnotch.uiScale"
        static let cornerRadiusScale = "agentnotch.cornerRadiusScale"
        static let animationSpeedScale = "agentnotch.animationSpeedScale"
        static let tabLayouts = "agentnotch.tabLayouts"
    }

    private init() {
        let defaults = UserDefaults.standard
        soundEnabled = defaults.object(forKey: Keys.soundEnabled) as? Bool ?? true
        languageOverride = defaults.string(forKey: Keys.languageOverride)
        uiScale = defaults.object(forKey: Keys.uiScale) as? Double ?? 1.0
        cornerRadiusScale = defaults.object(forKey: Keys.cornerRadiusScale) as? Double ?? 1.0
        animationSpeedScale = defaults.object(forKey: Keys.animationSpeedScale) as? Double ?? 1.0
        if let data = defaults.data(forKey: Keys.tabLayouts),
           let decoded = try? JSONDecoder().decode([String: TabLayoutConfiguration].self, from: data) {
            tabLayouts = decoded
        } else {
            tabLayouts = [:]
        }
    }
}

/// A single widget's placement within a tab's layout: whether it shows, and
/// in what order relative to its siblings. `id` should be a stable,
/// human-readable identifier (e.g. `"media.sources"`) so saved layouts
/// survive code refactors that don't rename the underlying widget.
struct WidgetLayoutItem: Codable, Identifiable, Equatable {
    let id: String
    var isVisible: Bool = true
    var order: Int
    var sizeScale: Double = 1.0
}

/// The full widget arrangement for one tab (Agents/Media/Today/System).
/// Persisted as JSON under `AppSettings.tabLayouts`, keyed by tab id.
struct TabLayoutConfiguration: Codable, Equatable {
    var widgets: [WidgetLayoutItem]

    /// Returns `fallback`'s ids reordered/filtered by this configuration:
    /// items present here are sorted by `order` and dropped when
    /// `isVisible == false`; any id in `fallback` but missing from this
    /// configuration is appended at the end (visible), so a partially
    /// populated layout never silently hides unknown widgets.
    func applying(to fallback: [String]) -> [String] {
        let byId = Dictionary(uniqueKeysWithValues: widgets.map { ($0.id, $0) })
        let known = widgets
            .filter { $0.isVisible && fallback.contains($0.id) }
            .sorted { $0.order < $1.order }
            .map(\.id)
        let unknown = fallback.filter { byId[$0] == nil }
        return known + unknown
    }
}
