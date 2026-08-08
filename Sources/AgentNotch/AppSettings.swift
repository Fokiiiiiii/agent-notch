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
    @Published var hapticsEnabled: Bool {
        didSet { UserDefaults.standard.set(hapticsEnabled, forKey: Keys.hapticsEnabled) }
    }
    /// Sideways scrolling over the compact/hover pill steps tracks. Only
    /// applies while the panel is *not* open — open uses that same gesture
    /// to switch pages.
    @Published var mediaSwipeEnabled: Bool {
        didSet { UserDefaults.standard.set(mediaSwipeEnabled, forKey: Keys.mediaSwipeEnabled) }
    }
    /// Swaps which direction advances: off, swiping left plays the next
    /// track (the content flicks away with the gesture).
    @Published var invertMediaSwipe: Bool {
        didSet { UserDefaults.standard.set(invertMediaSwipe, forKey: Keys.invertMediaSwipe) }
    }
    /// Set once the welcome screen has been dismissed, so it only appears on
    /// a genuine first run. Settings can reopen it regardless.
    @Published var hasSeenOnboarding: Bool {
        didSet { UserDefaults.standard.set(hasSeenOnboarding, forKey: Keys.hasSeenOnboarding) }
    }
    /// Whether an approval/question/plan request expands the panel on
    /// arrival (the long-standing behavior) or only surfaces the compact
    /// badge, leaving the user to click into it. Off is for people who
    /// don't want the panel taking over the screen mid-task; the request
    /// still waits either way. Read by `NotchWindowController.showAttention`.
    @Published var autoOpenOnAttention: Bool {
        didSet { UserDefaults.standard.set(autoOpenOnAttention, forKey: Keys.autoOpenOnAttention) }
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
    /// Per-tab widget layout (order/visibility/size). Keyed by a stable
    /// identifier — since Media/Today/System merged into one Dashboard Nook
    /// page (see `NookView`), these keys (`"agents"`, `"today"`, `"system"`)
    /// now identify `expandedDetail`'s per-source-tab item groups within
    /// that merged page rather than top-level tabs; `orderedDetailItems`
    /// is still the only actual consumer. Not yet editable from any UI —
    /// this is the storage foundation a future "customize layout" settings
    /// screen will read/write. Absence of a key means "use the built-in
    /// default order, all widgets visible."
    @Published var tabLayouts: [String: TabLayoutConfiguration] {
        didSet {
            if let data = try? JSONEncoder().encode(tabLayouts) {
                UserDefaults.standard.set(data, forKey: Keys.tabLayouts)
            }
        }
    }

    private enum Keys {
        static let soundEnabled = "agentnotch.soundEnabled"
        static let hapticsEnabled = "agentnotch.hapticsEnabled"
        static let mediaSwipeEnabled = "agentnotch.mediaSwipeEnabled"
        static let invertMediaSwipe = "agentnotch.invertMediaSwipe"
        static let hasSeenOnboarding = "agentnotch.hasSeenOnboarding"
        static let autoOpenOnAttention = "agentnotch.autoOpenOnAttention"
        static let languageOverride = "agentnotch.languageOverride"
        static let uiScale = "agentnotch.uiScale"
        static let cornerRadiusScale = "agentnotch.cornerRadiusScale"
        static let animationSpeedScale = "agentnotch.animationSpeedScale"
        static let tabLayouts = "agentnotch.tabLayouts"
    }

    private init() {
        let defaults = UserDefaults.standard
        soundEnabled = defaults.object(forKey: Keys.soundEnabled) as? Bool ?? true
        hapticsEnabled = defaults.object(forKey: Keys.hapticsEnabled) as? Bool ?? true
        mediaSwipeEnabled = defaults.object(forKey: Keys.mediaSwipeEnabled) as? Bool ?? true
        invertMediaSwipe = defaults.object(forKey: Keys.invertMediaSwipe) as? Bool ?? false
        hasSeenOnboarding = defaults.object(forKey: Keys.hasSeenOnboarding) as? Bool ?? false
        autoOpenOnAttention = defaults.object(forKey: Keys.autoOpenOnAttention) as? Bool ?? true
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

/// Which side of its row/tab-bar a widget anchors to.
enum WidgetAlignment: String, Codable, CaseIterable {
    case leading, trailing
}

/// How a widget behaves while a fullscreen app is active on the current
/// Space — mirrors the suppression behavior `NotchWindowController` already
/// applies to the whole notch, but per-widget.
enum WidgetFullscreenBehavior: String, Codable, CaseIterable {
    /// Shows exactly as it would in a normal (non-fullscreen) Space.
    case show
    /// Never shows while a fullscreen app is active.
    case hide
    /// Only reachable via the Hover peek (long-press), never Compact/Expanded.
    case hoverOnly
}

/// A single widget's placement and per-state visibility within a tab's
/// layout. `id` should be a stable, human-readable identifier (e.g.
/// `"media.sources"`) so saved layouts survive code refactors that don't
/// rename the underlying widget.
///
/// Decoding is hand-written (not synthesized) so a layout saved by an
/// older build — before `displayName`/`alignment`/`priority`/`minWidth`/
/// `preferredWidth`/`showsInCompact`/`showsInHover`/`showsInExpanded`/
/// `fullscreenBehavior` existed — still decodes cleanly instead of
/// throwing on the missing keys; every new field falls back to its
/// default. See `WidgetLayoutItemCodableTests` for the regression guard.
struct WidgetLayoutItem: Codable, Identifiable, Equatable {
    let id: String
    var displayName: String = ""
    var isVisible: Bool = true
    var alignment: WidgetAlignment = .leading
    var order: Int
    /// Lower-priority widgets are the first candidates to drop when a row
    /// doesn't have room for everything at once. Not yet consumed by any
    /// layout code — reserved for the settings/module-rewiring work this
    /// data model exists to support (see this type's introducing commit).
    var priority: Int = 0
    var minWidth: CGFloat = 0
    var preferredWidth: CGFloat = 0
    var showsInCompact: Bool = true
    var showsInHover: Bool = true
    var showsInExpanded: Bool = true
    var fullscreenBehavior: WidgetFullscreenBehavior = .hoverOnly
    var sizeScale: Double = 1.0

    init(
        id: String,
        displayName: String = "",
        isVisible: Bool = true,
        alignment: WidgetAlignment = .leading,
        order: Int,
        priority: Int = 0,
        minWidth: CGFloat = 0,
        preferredWidth: CGFloat = 0,
        showsInCompact: Bool = true,
        showsInHover: Bool = true,
        showsInExpanded: Bool = true,
        fullscreenBehavior: WidgetFullscreenBehavior = .hoverOnly,
        sizeScale: Double = 1.0
    ) {
        self.id = id
        self.displayName = displayName
        self.isVisible = isVisible
        self.alignment = alignment
        self.order = order
        self.priority = priority
        self.minWidth = minWidth
        self.preferredWidth = preferredWidth
        self.showsInCompact = showsInCompact
        self.showsInHover = showsInHover
        self.showsInExpanded = showsInExpanded
        self.fullscreenBehavior = fullscreenBehavior
        self.sizeScale = sizeScale
    }

    private enum CodingKeys: String, CodingKey {
        case id, displayName, isVisible, alignment, order, priority
        case minWidth, preferredWidth, showsInCompact, showsInHover, showsInExpanded
        case fullscreenBehavior, sizeScale
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        displayName = try container.decodeIfPresent(String.self, forKey: .displayName) ?? ""
        isVisible = try container.decodeIfPresent(Bool.self, forKey: .isVisible) ?? true
        alignment = try container.decodeIfPresent(WidgetAlignment.self, forKey: .alignment) ?? .leading
        order = try container.decode(Int.self, forKey: .order)
        priority = try container.decodeIfPresent(Int.self, forKey: .priority) ?? 0
        minWidth = try container.decodeIfPresent(CGFloat.self, forKey: .minWidth) ?? 0
        preferredWidth = try container.decodeIfPresent(CGFloat.self, forKey: .preferredWidth) ?? 0
        showsInCompact = try container.decodeIfPresent(Bool.self, forKey: .showsInCompact) ?? true
        showsInHover = try container.decodeIfPresent(Bool.self, forKey: .showsInHover) ?? true
        showsInExpanded = try container.decodeIfPresent(Bool.self, forKey: .showsInExpanded) ?? true
        fullscreenBehavior = try container.decodeIfPresent(WidgetFullscreenBehavior.self, forKey: .fullscreenBehavior) ?? .hoverOnly
        sizeScale = try container.decodeIfPresent(Double.self, forKey: .sizeScale) ?? 1.0
    }
}

/// The widgets that can occupy the Dashboard page's row, in the order they
/// ship in. Each case's `id` is what gets persisted in
/// `AppSettings.tabLayouts[DashboardWidget.layoutKey]`, so renaming a case's
/// raw value would orphan an existing user layout.
enum DashboardWidget: String, CaseIterable, Identifiable {
    case media, today

    /// Key under which the Dashboard's arrangement is stored. Distinct from
    /// the `"today"`/`"system"` keys already in `tabLayouts`, which group
    /// `expandedDetail`'s items rather than page widgets.
    static let layoutKey = "dashboard"

    var id: String { rawValue }

    static var defaultOrder: [String] { allCases.map(\.id) }

    /// `nil` means "take whatever width is left". Today is a fixed width
    /// because its five-column date strip is laid out around a known column
    /// size; Media absorbs the remainder.
    var preferredWidth: CGFloat? {
        switch self {
        case .media: return nil
        case .today: return 236
        }
    }

    var displayName: String {
        switch self {
        case .media: return String(localized: "widget.media", defaultValue: "Media")
        case .today: return String(localized: "widget.today", defaultValue: "Calendar")
        }
    }

    var symbolName: String {
        switch self {
        case .media: return "music.note"
        case .today: return "calendar"
        }
    }

    /// Resolves a stored arrangement into the widgets to actually draw.
    /// Separate from the view so the ordering/visibility rules are testable
    /// without standing up SwiftUI.
    static func resolved(from configuration: TabLayoutConfiguration?) -> [DashboardWidget] {
        let ids = configuration?.applying(to: defaultOrder) ?? defaultOrder
        return ids.compactMap(DashboardWidget.init(rawValue:))
    }
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
