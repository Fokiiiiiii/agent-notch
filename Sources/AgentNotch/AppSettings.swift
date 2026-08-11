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
        didSet {
            // Re-clamp on write as well: the setter is reachable from any
            // future control, not only the range-limited slider.
            let clamped = Self.clampedScale(uiScale, into: Self.uiScaleRange)
            if clamped != uiScale {
                uiScale = clamped
                return
            }
            UserDefaults.standard.set(uiScale, forKey: Keys.uiScale)
        }
    }
    /// Multiplier applied to corner radii (1.0 = current defaults).
    @Published var cornerRadiusScale: Double {
        didSet {
            // Re-clamp on write as well: the setter is reachable from any
            // future control, not only the range-limited slider.
            let clamped = Self.clampedScale(cornerRadiusScale, into: Self.cornerRadiusScaleRange)
            if clamped != cornerRadiusScale {
                cornerRadiusScale = clamped
                return
            }
            UserDefaults.standard.set(cornerRadiusScale, forKey: Keys.cornerRadiusScale)
        }
    }
    /// Multiplier applied to animation/spring response durations (1.0 = current defaults).
    @Published var animationSpeedScale: Double {
        didSet {
            // Re-clamp on write as well: the setter is reachable from any
            // future control, not only the range-limited slider.
            let clamped = Self.clampedScale(animationSpeedScale, into: Self.animationSpeedScaleRange)
            if clamped != animationSpeedScale {
                animationSpeedScale = clamped
                return
            }
            UserDefaults.standard.set(animationSpeedScale, forKey: Keys.animationSpeedScale)
        }
    }
    /// Per-tab widget layout (order/visibility/size). Keyed by a stable
    /// identifier: `DashboardWidget.layoutKey` is the Dashboard page's own
    /// widget row (edited from Settings ▸ Nook, read by `DashboardCell`),
    /// while `"agents"`/`"today"`/`"system"` identify `expandedDetail`'s
    /// per-source item groups within that merged page rather than top-level
    /// tabs. Absence of a key means "use the built-in default order, all
    /// widgets visible."
    @Published var tabLayouts: [String: TabLayoutConfiguration] {
        didSet {
            if let data = try? JSONEncoder().encode(tabLayouts) {
                UserDefaults.standard.set(data, forKey: Keys.tabLayouts)
            }
        }
    }

    /// Whether the nook bar shows connected AirPods' battery level. Off by
    /// default: it reads private IOBluetooth API and needs Bluetooth
    /// permission (see `AirPodsBatteryMonitor`). Read by the nook bar's
    /// indicator and the Settings toggle.
    @Published var airPodsStatusEnabled: Bool {
        didSet { UserDefaults.standard.set(airPodsStatusEnabled, forKey: Keys.airPodsStatusEnabled) }
    }
    /// Whether the compact waveform is driven by real system audio instead
    /// of its synthetic animation. Off by default: turning it on starts a
    /// ScreenCaptureKit stream, which needs Screen Recording permission.
    /// Read by `AgentNotchApp` on launch and by the Settings toggle.
    @Published var visualizerEnabled: Bool {
        didSet { UserDefaults.standard.set(visualizerEnabled, forKey: Keys.visualizerEnabled) }
    }
    /// Shortcuts the user has pinned to the Tray's action menu, in the
    /// order they appear there. Read by `TrayCell`; edited from
    /// Settings ▸ Nook.
    @Published var registeredShortcuts: [ShortcutBinding] {
        didSet {
            if let data = try? JSONEncoder().encode(registeredShortcuts) {
                UserDefaults.standard.set(data, forKey: Keys.registeredShortcuts)
            }
        }
    }

    /// The ranges the Settings sliders offer, and the only values the app
    /// promises to render correctly. Declared here rather than in the view
    /// so the slider and the persistence check can't drift apart.
    static let uiScaleRange: ClosedRange<Double> = 0.8...1.3
    static let cornerRadiusScaleRange: ClosedRange<Double> = 0.5...1.5
    static let animationSpeedScaleRange: ClosedRange<Double> = 0.5...2.0

    /// Brings a persisted scale back into range on read.
    ///
    /// A stored value outside it can only come from a hand-edited defaults
    /// entry, a corrupted preferences file, or a build whose range differed
    /// — but the consequence is severe and unrecoverable through the UI:
    /// measured, `uiScale = 40` produced a 21600×10080 panel on a 1680×1050
    /// screen, entirely off-screen, so the gear button needed to undo it
    /// couldn't be reached. Non-finite values (NaN/∞, which `defaults write`
    /// accepts) collapse the layout the same way.
    static func clampedScale(_ stored: Double?, into range: ClosedRange<Double>, fallback: Double = 1.0) -> Double {
        guard let stored, stored.isFinite else { return fallback }
        return min(max(stored, range.lowerBound), range.upperBound)
    }

    /// Replaces a stored scale with its clamped value when the two differ.
    private static func normalizePersistedScale(_ clamped: Double, key: String, in defaults: UserDefaults) {
        guard let stored = defaults.object(forKey: key) as? Double else { return }
        guard !stored.isFinite || stored != clamped else { return }
        defaults.set(clamped, forKey: key)
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
        static let registeredShortcuts = "agentnotch.registeredShortcuts"
        static let visualizerEnabled = "agentnotch.visualizerEnabled"
        static let airPodsStatusEnabled = "agentnotch.airPodsStatusEnabled"
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
        uiScale = Self.clampedScale(defaults.object(forKey: Keys.uiScale) as? Double, into: Self.uiScaleRange)
        cornerRadiusScale = Self.clampedScale(defaults.object(forKey: Keys.cornerRadiusScale) as? Double, into: Self.cornerRadiusScaleRange)
        animationSpeedScale = Self.clampedScale(defaults.object(forKey: Keys.animationSpeedScale) as? Double, into: Self.animationSpeedScaleRange)
        visualizerEnabled = defaults.object(forKey: Keys.visualizerEnabled) as? Bool ?? false
        airPodsStatusEnabled = defaults.object(forKey: Keys.airPodsStatusEnabled) as? Bool ?? false
        if let data = defaults.data(forKey: Keys.tabLayouts),
           let decoded = try? JSONDecoder().decode([String: TabLayoutConfiguration].self, from: data) {
            tabLayouts = decoded
        } else {
            tabLayouts = [:]
        }
        if let data = defaults.data(forKey: Keys.registeredShortcuts),
           let decoded = try? JSONDecoder().decode([ShortcutBinding].self, from: data) {
            registeredShortcuts = decoded
        } else {
            registeredShortcuts = []
        }

        // Write the corrected values back, now that every stored property is
        // initialized. `didSet` doesn't fire during `init`, so without this a
        // poisoned entry would sit in the preferences file indefinitely —
        // harmless at runtime (it's clamped on every read) but confusing to
        // anyone inspecting `defaults`, and it would take effect again the
        // moment this clamp is ever relaxed.
        Self.normalizePersistedScale(uiScale, key: Keys.uiScale, in: defaults)
        Self.normalizePersistedScale(cornerRadiusScale, key: Keys.cornerRadiusScale, in: defaults)
        Self.normalizePersistedScale(animationSpeedScale, key: Keys.animationSpeedScale, in: defaults)
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
    case media, today, camera

    /// Key under which the Dashboard's arrangement is stored. Distinct from
    /// the `"today"`/`"system"` keys already in `tabLayouts`, which group
    /// `expandedDetail`'s items rather than page widgets.
    static let layoutKey = "dashboard"

    var id: String { rawValue }

    static var defaultOrder: [String] { allCases.map(\.id) }

    /// What this widget contributes to the panel's total width. Every widget
    /// needs a concrete number here even the flexible one, because this is
    /// what sizes the *panel* — `preferredWidth` below is the separate
    /// question of how the widget is drawn once the panel has a width.
    var layoutWidth: CGFloat {
        switch self {
        case .media: return 235
        case .today: return 236
        case .camera: return 132
        }
    }

    /// Media takes whatever the row has left over, so its rendered width
    /// isn't fixed; Today's five-column date strip is laid out around a
    /// known column size, and the mirror is deliberately small.
    var absorbsLeftoverWidth: Bool { self == .media }

    /// `nil` means "take whatever width is left" at render time.
    var preferredWidth: CGFloat? {
        absorbsLeftoverWidth ? nil : layoutWidth
    }

    /// Whether the widget is on for someone who has never opened Settings.
    /// The camera mirror is opt-in: showing it by default would turn on the
    /// webcam (and its indicator light) the first time the panel opened.
    var isEnabledByDefault: Bool {
        switch self {
        case .media, .today: return true
        case .camera: return false
        }
    }

    var displayName: String {
        switch self {
        case .media: return String(localized: "widget.media", defaultValue: "Media")
        case .today: return String(localized: "widget.today", defaultValue: "Calendar")
        case .camera: return String(localized: "widget.camera", defaultValue: "Mirror")
        }
    }

    var symbolName: String {
        switch self {
        case .media: return "music.note"
        case .today: return "calendar"
        case .camera: return "web.camera"
        }
    }

    /// Resolves a stored arrangement into the widgets to actually draw.
    /// Separate from the view so the ordering/visibility rules are testable
    /// without standing up SwiftUI.
    static func resolved(from configuration: TabLayoutConfiguration?) -> [DashboardWidget] {
        guard let configuration else {
            return allCases.filter(\.isEnabledByDefault)
        }
        return configuration.applying(to: defaultOrder)
            .compactMap(DashboardWidget.init(rawValue:))
            // `applying(to:)` appends ids the stored layout has never seen,
            // so that a widget added in a later build isn't invisible to
            // existing users. An opt-in widget must not be swept in that
            // way — it stays off until it's explicitly in the layout.
            .filter { widget in
                configuration.widgets.contains { $0.id == widget.id } || widget.isEnabledByDefault
            }
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
