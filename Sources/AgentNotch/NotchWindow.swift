import AppKit
import SwiftUI
import Combine
import AgentNotchCore

private final class KeyableNotchPanel: NSPanel {
    override var canBecomeKey: Bool { true }
}

/// Owns every file drop onto the panel. The SwiftUI content is a subview, so
/// a SwiftUI `.dropDestination` inside it would compete with this view for
/// the same drag session; instead this stays the single entry point and
/// reports *where* the drop landed, letting the SwiftUI layer route it (Tray
/// vs. the AirDrop well) by hit-testing its own recorded frames.
private final class FileDropContainerView: NSView {
    /// Points are top-left-origin, matching SwiftUI's coordinate space —
    /// see `flippedLocation(of:)`.
    var fileDropHandler: (([URL], CGPoint) -> Void)?
    var fileDragStateHandler: ((Bool, CGPoint) -> Void)?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        registerForDraggedTypes([.fileURL])
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        registerForDraggedTypes([.fileURL])
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        let urls = fileURLs(from: sender)
        guard !urls.isEmpty else { return [] }
        fileDragStateHandler?(true, flippedLocation(of: sender))
        return .copy
    }

    /// Needed for the well's hover highlight: `draggingEntered` fires once at
    /// the panel's edge, so without this the pointer's position would never
    /// update while the drag moves between the Tray and the well.
    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        guard !fileURLs(from: sender).isEmpty else { return [] }
        fileDragStateHandler?(true, flippedLocation(of: sender))
        return .copy
    }

    override func draggingExited(_ sender: NSDraggingInfo?) {
        fileDragStateHandler?(false, .zero)
    }

    override func draggingEnded(_ sender: NSDraggingInfo) {
        fileDragStateHandler?(false, .zero)
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        let urls = fileURLs(from: sender)
        let location = flippedLocation(of: sender)
        fileDragStateHandler?(false, .zero)
        guard !urls.isEmpty else { return false }
        fileDropHandler?(urls, location)
        return true
    }

    /// AppKit hands out window coordinates with a bottom-left origin; the
    /// SwiftUI frames this gets compared against are top-left.
    private func flippedLocation(of sender: NSDraggingInfo) -> CGPoint {
        let inView = convert(sender.draggingLocation, from: nil)
        return CGPoint(x: inView.x, y: bounds.height - inView.y)
    }

    private func fileURLs(from draggingInfo: NSDraggingInfo) -> [URL] {
        let options: [NSPasteboard.ReadingOptionKey: Any] = [.urlReadingFileURLsOnly: true]
        let values = draggingInfo.draggingPasteboard.readObjects(forClasses: [NSURL.self], options: options) ?? []
        return values.compactMap { ($0 as? NSURL) as URL? }
    }
}

/// The three sizes the notch window/panel can take.
enum IslandMode {
    case closed, hover, notice, open
}

/// Which page is shown inside the "Nook" tab of the open panel. Formerly
/// `agents, media, today, system` — Media/Today/System were merged into a
/// single `dashboard` page (three stacked cards) so all of it is visible at
/// once instead of requiring a tab switch; `agents` stays separate by design
/// (agent session monitoring/approval is a distinct concern from the
/// at-a-glance system widgets).
enum NookView: CaseIterable {
    case agents, dashboard

    var title: String {
        switch self {
        case .agents: return String(localized: "nook.tab.agents", defaultValue: "Agents")
        case .dashboard: return String(localized: "nook.tab.dashboard", defaultValue: "Dashboard")
        }
    }
}

/// Which top-level tab is active inside the open panel.
enum NotchTab {
    case nook, tray
}

/// Inline approval, plan, and agent-question surfaces displayed in the Nook.
enum IslandOverlay: Equatable {
    /// `otherAgentPending`: set when at least one of the `extraCount` queued
    /// requests behind this one is from a *different* agent than `agent`.
    /// Without this, a lingering older request (e.g. an unanswered Claude
    /// approval) showing while a brand-new Codex request waits behind it
    /// reads as "the agent label is wrong" — it isn't; it's just the wrong
    /// (older) *request*. Surfacing which other agent is waiting (see the
    /// `+N (Codex)` badge in `ApprovalOverlayView`) makes that legible
    /// without changing FIFO resolution order (changing to "show newest"
    /// would let a busy agent starve an older pending request into timing
    /// out unanswered, which is worse).
    case approval(agent: AgentKind, toolName: String, summary: String, extraCount: Int, otherAgentPending: AgentKind?, cwd: String, isDangerous: Bool)
    case plan
    case question
}

struct ApprovalOutcome: Equatable {
    let allowed: Bool
}

/// A lightweight, plain-data snapshot of the screen geometry inputs
/// `NotchWindowController`'s sizing/placement math needs. Real `NSScreen`s
/// are converted via the `init(screen:)` adapter below; everything else in
/// this file operates on the snapshot so the same logic can run against a
/// fake screen configuration in tests (notch/no-notch, narrow safe area,
/// external displays, etc.) without touching `NSScreen` at all.
struct ScreenSnapshot {
    let frame: CGRect
    let safeAreaInsetsTop: CGFloat
    let auxiliaryTopLeftWidth: CGFloat?
    let auxiliaryTopRightWidth: CGFloat?
    let isBuiltIn: Bool

    /// The only place that touches live `NSScreen`/`CGDirectDisplayID` APIs
    /// to build a snapshot; production code always goes through here.
    init(screen: NSScreen) {
        self.frame = screen.frame
        self.safeAreaInsetsTop = screen.safeAreaInsets.top
        self.auxiliaryTopLeftWidth = screen.auxiliaryTopLeftArea?.width
        self.auxiliaryTopRightWidth = screen.auxiliaryTopRightArea?.width
        self.isBuiltIn = NotchWindowController.isBuiltInDisplay(screen)
    }

    init(frame: CGRect, safeAreaInsetsTop: CGFloat, auxiliaryTopLeftWidth: CGFloat?, auxiliaryTopRightWidth: CGFloat?, isBuiltIn: Bool) {
        self.frame = frame
        self.safeAreaInsetsTop = safeAreaInsetsTop
        self.auxiliaryTopLeftWidth = auxiliaryTopLeftWidth
        self.auxiliaryTopRightWidth = auxiliaryTopRightWidth
        self.isBuiltIn = isBuiltIn
    }
}

@MainActor
final class NotchUIState: ObservableObject {
    @Published var mode: IslandMode = .closed
    @Published var activeTab: NotchTab = .nook
    @Published var activeView: NookView = .agents
    @Published var overlay: IslandOverlay? = nil
    @Published var approvalOutcome: ApprovalOutcome? = nil
    @Published var noticeTitle: String? = nil
    @Published var noticeMessage: String? = nil
    @Published var selectedSessionId: String? = nil
    @Published var isDetailExpanded = false
    @Published var isMediaPreviewVisible = false
    @Published var trayHasItems = false
    @Published var trayItemCount = 0
    @Published var reopenTrayOnNextOpen = false
    @Published var focusEndsAt: Date?
    /// How many days the Dashboard's week strip is scrolled away from today
    /// (0 = centered on today). Lives here rather than in
    /// `DashboardTodaySection`'s own `@State` because the scroll that drives
    /// it is an `NSEvent` monitor in `NotchWindowController`, not a SwiftUI
    /// gesture. Clamped to ±`weekStripScrollLimitDays`.
    @Published var weekStripDayOffset: Int = 0
    /// Whether the pointer is over the week strip. Routes horizontal scroll
    /// to day-stepping instead of page-switching while true — without it the
    /// two gestures would be indistinguishable.
    @Published var isHoveringWeekStrip = false
    /// Shows the first-run gesture guide in place of the normal panel
    /// contents. Takes priority over everything else the panel can show:
    /// it appears before the user has any idea the notch is interactive.
    @Published var isShowingOnboarding = false
    /// The fixed on-screen size of the `.closed`-mode notch shape. Shared
    /// with `NotchWindowController` so the panel's real frame can grow
    /// (invisibly, for file-drag hit-testing) without the visible shape
    /// growing along with it.
    @Published var closedContentSize: CGSize = CGSize(width: 220, height: 34)
    /// The fixed on-screen size of the `.hover`-mode peek. Same rationale as
    /// `closedContentSize`: `NotchView`'s explicit `.frame()` uses this
    /// directly instead of leaving `.hover` to size itself from ambient
    /// SwiftUI layout, which otherwise lets the visible shape/content
    /// mis-align with the panel's real (screen/uiScale-derived) frame.
    @Published var hoverContentSize: CGSize = CGSize(width: 320, height: 90)
    /// Extra top space `HoverPeekView` must leave empty on a real notched
    /// Mac before drawing anything readable — the physical camera housing
    /// is opaque and covers the top `notchHeight` of the screen, so content
    /// placed there is invisible, not just tightly cropped. `0` on a
    /// non-notched screen, where the original (pre-notch-aware) layout is
    /// left exactly as it was.
    @Published var hoverTopClearance: CGFloat = 0
    /// Whether the notch is visible at all (fully independent of `mode`,
    /// which only tracks compact/notice/open *sizing* once visible). See
    /// `NotchWindowController`'s visibility state machine.
    @Published var isVisible: Bool = false
    /// Which sub-question of the current `.question` overlay's batch is
    /// showing, and whether it's in free-text ("Other…") mode — lifted out
    /// of `AgentQuestionView`'s local `@State` into here so
    /// `NotchWindowController` can size the panel to fit the *current*
    /// step's content instead of a single fixed `openQuestionSize` for the
    /// whole batch (see `questionOpenSize(for:)`).
    @Published var questionStepIndex: Int = 0
    @Published var questionCustomMode: Bool = false
    /// `true` once every sub-question in the current batch has been
    /// answered and `AgentQuestionView` is showing the read-only
    /// review-before-send screen instead of a question step — see
    /// `questionOpenSize(for:)`'s `questionReviewHeight` branch.
    @Published var questionReviewMode: Bool = false
    /// Live-measured heights of the two genuinely variable-length text
    /// elements in the question/approval overlays (the question prompt can
    /// run to several lines; the approval summary is a full command/diff
    /// excerpt with no line cap, since truncating it could hide the
    /// dangerous part of what's being approved). Every other element in
    /// those overlays has a fixed or `lineLimit`-capped height, so only
    /// these two need real measurement — see `NotchView.swift`'s
    /// `.onGeometryChange` on each Text, and `questionOpenSize(for:)`/
    /// `approvalOpenSize()` in `NotchWindowController`.
    @Published var questionPromptHeight: CGFloat = 20
    @Published var approvalSummaryHeight: CGFloat = 34

    var hasOverlay: Bool { overlay != nil }
}

@MainActor
final class NotchWindowController: NSObject {
    private let panel: NSPanel
    private let fileDropView: FileDropContainerView
    private let uiState = NotchUIState()
    private let store: SessionStore
    private let permissions: PermissionCenter
    private let questions: QuestionCenter
    private let plans: PlanCenter
    /// Read-only derived view over the three queues above — see its own
    /// doc comment. Built entirely from them; `App.swift` doesn't need to
    /// know about it.
    private let attention: AttentionCenter
    private let nativeNotifier: NativeNotifier?
    private let settings = AppSettings.shared
    private var screen: NSScreen
    /// Geometry-only mirror of `screen`, recomputed alongside it. See
    /// `ScreenSnapshot`.
    private var screenSnapshot: ScreenSnapshot
    private var closedSize: CGSize
    /// Narrower than `closedSize`: used only while fullscreen-suppressed, so the
    /// long-hover peek doesn't collide with a fullscreen app's own top-edge
    /// chrome-reveal gesture (which typically spans the full screen width).
    private var fullscreenHoverSize: CGSize
    private var mediaPreviewSize: CGSize
    /// The visible `.closed`-mode shape's size before `closedSize`'s
    /// `+40w/+70h` hit-test padding — i.e. the actual on-screen pill.
    /// Kept as its own stored property (mirroring `mediaPreviewSize`/
    /// `hoverSize`) so `resizeForCurrentState()` can recompute
    /// `uiState.closedContentSize` correctly whenever `isMediaPreviewVisible`
    /// toggles, instead of `closedContentSize` staying pinned to whatever it
    /// was on the last screen-geometry change (a real bug: the window frame
    /// already grows to `mediaPreviewSize` on media preview, but the visible
    /// SwiftUI content didn't follow, leaving a transparent gap).
    private var visualClosedSize: CGSize
    private let noticeSize = CGSize(width: 320, height: 50)
    static let openSize = CGSize(width: 540, height: 206)
    private let trayOpenSize = CGSize(width: 560, height: 234)
    static let openDetailSize = CGSize(width: 540, height: 264)
    private let openOverlaySize = CGSize(width: 540, height: 246)
    private let openQuestionSize = CGSize(width: 540, height: 316)
    /// Intermediate size for `.hover` — a lightweight peek shown after a
    /// further dwell over the already-visible `.closed` notch (song/
    /// project/status/elapsed time; see `HoverPeekView` in `NotchView.swift`).
    /// Deliberately between `closedSize` (~232×34, screen-derived) and
    /// `openSize` (540×206). On a real notched Mac this widens to visually
    /// merge with the physical notch cutout, matching NotchNook's reference
    /// look; on a non-notched screen it stays the plain fixed default.
    /// Screen-derived (like `closedSize`), so recomputed alongside it —
    /// see `computeHoverSize`. This is the *two-row* height (media + session
    /// both showing); `resizeForCurrentState()` substitutes
    /// `hoverCompactHeight` instead whenever only one row is actually being
    /// drawn, so the pill doesn't sit mostly-empty around a single short
    /// line (reported as looking visually unbalanced).
    private var hoverSize: CGSize
    /// Height for `.hover` when `HoverPeekView` draws only one row (no
    /// playing media, or media but no tracked session — see its `body`).
    /// Comfortably fits one row's icon + two-line text stack plus the same
    /// vertical padding `HoverPeekView` uses (10pt top/bottom), without the
    /// leftover empty space a fixed two-row-sized pill left behind it.
    static let hoverCompactHeight: CGFloat = 64
    /// Extra top clearance `.hover` must reserve on a real notched Mac
    /// before `HoverPeekView` may draw anything readable — `0` on a
    /// non-notched screen, where the pre-existing layout is left untouched.
    /// See `computeScreenGeometry`'s `hoverTopClearance` for why.
    private var hoverTopClearance: CGFloat
    /// Whether the anchor screen has a real physical notch. `.hover` is
    /// gated on this — it's a NotchNook-style feature meant specifically
    /// for notched Macs, and must never trigger on a non-notched screen
    /// (see `shouldEnterHover`).
    private var hasRealNotch: Bool
    /// Height for the Agents tab with exactly one tracked session (the
    /// selected-row detail lines plus usage bar and footer already exceed
    /// `openSize.height`, which is what caused the footer button to visually
    /// float outside the card). Derived empirically from `AgentsCell`'s
    /// layout (usage bar ~27pt + selected row ~70pt + footer 30pt + padding
    ////spacing) plus the chrome above/below it (nookbar, view tabs).
    static let agentsBaseHeight: CGFloat = 252
    /// Extra height contributed by each additional, unselected session row
    /// (row height + list spacing) once more than one session is tracked.
    static let agentsRowHeight: CGFloat = 36
    /// Sessions beyond this count no longer grow the panel further —
    /// `AgentsCell.sessionList`'s own `ScrollView` takes over instead, so
    /// the notch never grows large enough to run off-screen.
    static let agentsMaxVisibleRows = 6
    /// Absolute ceiling on the Agents tab height, independent of session
    /// count — a backstop for an unforeseen input, not the thing that
    /// decides the height in normal use. `agentsMaxVisibleRows` is what
    /// bounds ordinary growth.
    ///
    /// It must therefore sit *above* the formula's own worst case, which is
    /// `agentsBaseHeight + agentsRowHeight * (agentsMaxVisibleRows - 1)`
    /// plus the detail strip: 252 + 36×5 + 58 = 490pt. It previously sat at
    /// 400 — below the 6-row height — so the sixth session row grew the
    /// panel by 4pt instead of 36 and was left clipped. The two constants
    /// were describing different intentions; `AgentsPanelSizingTests`
    /// now pins the relationship.
    static let agentsMaxHeight: CGFloat = 500
    /// Height budget for the Dashboard Nook page — Media and Today sitting
    /// side by side in one row, separated by a hairline rule and drawn
    /// directly on the panel background (see `NotchView.DashboardCell`).
    /// The row's height is set by its tallest widget rather than by how much
    /// content each holds, so it varies with neither event count nor
    /// calendar-permission state: `DashboardTodaySection` renders one agenda
    /// line in every state. Concrete value is an estimate derived from the
    /// tallest widget plus `DashboardCell`'s 12pt vertical padding plus
    /// chrome. Today is the taller of the two widgets (~74pt: 37pt week
    /// strip + 8pt spacing + ~29pt two-line agenda block), having overtaken
    /// Media's 68pt artwork when its agenda line became an icon-over-text
    /// stack.
    ///
    /// Summed rather than estimated, after a too-small value clipped the
    /// view-tab row off the bottom of the panel: `openContent`'s 6pt top
    /// padding + 30pt nookbar + its 7pt `VStack` spacing + 86pt
    /// `DashboardCell` (74pt Today + 12pt vertical padding) +
    /// `nookContentView`'s 4pt spacing + 28pt `viewTabs` + 10pt bottom
    /// padding = 171pt, plus a 5pt cushion for font-metric drift.
    static let dashboardBaseHeight: CGFloat = 182
    /// Extra height for `expandedDetail`'s `.dashboard` case — two stacked
    /// `DetailStrip`s (Today's 3 items + System's 2) plus the focus-timer
    /// row that moved here out of `DashboardTodaySection`.
    static let dashboardDetailExpandedHeight: CGFloat = 126
    /// Absolute ceiling on the Dashboard tab height — same safety-net role
    /// as `agentsMaxHeight`. Set above the worst case the formula above can
    /// actually produce (`dashboardBaseHeight` +
    /// `dashboardDetailExpandedHeight` = 176 + 126 = 302) with a little
    /// headroom — unlike Agents' cap (which exists specifically to hand off
    /// to `AgentsCell`'s own `ScrollView` once a real overflow risk exists),
    /// Dashboard has no scroll fallback, so a cap tighter than its own worst
    /// case would silently clip real content instead of protecting anything.
    static let dashboardMaxHeight: CGFloat = 320
    /// Height for the first-run gesture guide: four icon-over-caption
    /// columns (~72pt, captions wrap to two lines at this width) + 16pt
    /// spacing + a 30pt button + the same nookbar/padding chrome the other
    /// pages sit in.
    static let onboardingHeight: CGFloat = 196

    /// `static` (unlike `agentsOpenSize`, a `private` instance method) so
    /// it's a pure function `DashboardSizingTests` can call directly without
    /// standing up a whole `NotchWindowController` — same reasoning as
    /// `computeClosedSize`/`computeHoverContentHeight`.
    static func dashboardOpenSize(width: CGFloat, detailExpanded: Bool) -> CGSize {
        var height = dashboardBaseHeight
        if detailExpanded {
            height += dashboardDetailExpandedHeight
        }
        return CGSize(width: width, height: min(height, dashboardMaxHeight))
    }

    /// Hairline rule plus its 14pt padding either side — `DashboardCell`'s
    /// `widgetDivider`, which sits between neighbouring widgets only.
    static let dashboardDividerWidth: CGFloat = 29
    /// `openContent`'s 16pt horizontal padding plus `DashboardCell`'s own
    /// 4pt, on both sides.
    static let dashboardHorizontalChrome: CGFloat = 40
    /// Below this the nook bar (Nook/Tray, battery, gear, close) and the
    /// page tabs underneath start crowding each other, so a page with very
    /// little in it stops shrinking here rather than becoming unusable.
    /// Measured, not guessed: at 420 the "Nook" tab label wrapped onto a
    /// second line on a real panel.
    static let dashboardMinWidth: CGFloat = 470

    /// The Dashboard's width follows what's actually in it: every widget
    /// contributes its own `layoutWidth`, plus a divider between each
    /// neighbouring pair and the panel's fixed horizontal chrome. Clamped
    /// to `maximum` so a wide arrangement can't run off the screen.
    static func dashboardWidth(for widgets: [DashboardWidget], maximum: CGFloat) -> CGFloat {
        guard !widgets.isEmpty else { return dashboardMinWidth }
        let content = widgets.reduce(0) { $0 + $1.layoutWidth }
        let dividers = CGFloat(widgets.count - 1) * dashboardDividerWidth
        let total = content + dividers + dashboardHorizontalChrome
        return min(max(total, dashboardMinWidth), max(maximum, dashboardMinWidth))
    }
    private var hoverTask: Task<Void, Never>?
    /// Second-stage dwell timer: while already visible in `.closed` and
    /// still being hovered, expands to `.hover` after a further short dwell.
    /// Kept separate from `dwellTask` (hidden → visible reveal) so the two
    /// distinct transitions never cancel each other out.
    private var hoverExpandTask: Task<Void, Never>?
    private var noticeAutoDismissTask: Task<Void, Never>?
    private var cancellables = Set<AnyCancellable>()

    // MARK: - Visibility state machine
    //
    // Three logical states, driven by `uiState.isVisible` + `uiState.mode`:
    //   hidden  (isVisible=false, mode=.closed)
    //   minimal (isVisible=true,  mode=.closed)
    //   open    (isVisible=true,  mode=.open)
    //
    // The panel itself is always `orderFront`; visibility is expressed via
    // `NotchView`'s opacity so hover hit-testing on the always-present top
    // band keeps working while hidden.
    private var dwellTask: Task<Void, Never>?
    private var hideTask: Task<Void, Never>?
    private var visibilityRefreshTask: Task<Void, Never>?
    private var shouldPersistVisible = true
    private var isClickPinned = false
    // Registration tokens, not state: each is assigned once during setup and
    // read once in `deinit` to unregister. `deinit` is `nonisolated` even on
    // a `@MainActor` class, so touching main-actor storage from it is an
    // error under the Swift 6 language mode — `nonisolated(unsafe)` is the
    // accurate claim here, since write-once/read-once from a single thread
    // leaves nothing to race.
    nonisolated(unsafe) private var workspaceObserver: NSObjectProtocol?
    nonisolated(unsafe) private var spaceObserver: NSObjectProtocol?
    nonisolated(unsafe) private var screenParametersObserver: NSObjectProtocol?
    private var screenGeometryRefreshTask: Task<Void, Never>?
    // Same as the observers above — `NSEvent` monitor tokens, unregistered
    // from `deinit`.
    nonisolated(unsafe) private var scrollMonitor: Any?
    nonisolated(unsafe) private var outsideClickLocalMonitor: Any?
    nonisolated(unsafe) private var outsideClickGlobalMonitor: Any?
    private var horizontalScrollTotal: CGFloat = 0
    private var didCommitCurrentScroll = false
    private var lastDiscreteScrollSwitch: TimeInterval = 0
    private var verticalScrollTotal: CGFloat = 0
    private var didCommitCurrentVerticalScroll = false
    private var lastDiscreteVerticalSwitch: TimeInterval = 0
    /// Coalesces same-runloop-tick `resizeForCurrentState()` requests (e.g.
    /// `activeTab`, `activeView`, and `store.sessions` all changing from one
    /// user action) into a single deferred resize, so `NSAnimationContext`
    /// animation groups don't race against each other mid-flight.
    private var resizeScheduled = false
    /// Ids of permission/question/plan requests already surfaced via a
    /// fallback native notification (fullscreen suppression), so the same
    /// event never notifies twice as visibility toggles.
    private var notifiedPermissionIDs: Set<UUID> = []
    private var notifiedQuestionIDs: Set<UUID> = []
    private var notifiedPlanIDs: Set<UUID> = []

    /// Throttles the `showAgentActivity(urgent:)` fallback notification
    /// (fullscreen suppression) so repeated attention/fail events for the
    /// same busy session don't spam native notifications.
    private var lastAgentActivityNotifyDate: Date?
    private let agentActivityNotifyMinInterval: TimeInterval = 30

    /// Whether the pointer is currently inside the notch. Consulted by
    /// AppDelegate before auto-collapsing after the permission queue drains.
    private(set) var isHovering = false
    /// Any approval/question/plan awaiting a response. Always wins over the
    /// `.hover` peek — such items are surfaced directly via `showAttention()`
    /// (see `shouldEnterHover`), never routed through the lightweight Hover
    /// state.
    private var hasPendingAttention: Bool {
        !permissions.queue.isEmpty || !questions.queue.isEmpty || !plans.queue.isEmpty
    }
    var isPinnedOpen: Bool { isClickPinned && uiState.mode == .open }
    var debugMode: String {
        switch uiState.mode { case .closed: return "closed"; case .hover: return "hover"; case .notice: return "notice"; case .open: return "open" }
    }
    var debugOverlay: String {
        guard let overlay = uiState.overlay else { return "none" }
        switch overlay { case .approval: return "approval"; case .plan: return "plan"; case .question: return "question" }
    }
    var debugVisible: Bool { uiState.isVisible }
    var debugPersists: Bool { shouldPersistVisible }
    private(set) var debugScreenInfo: [String: Any]

    /// True if the given screen's backing display is the Mac's built-in
    /// panel (as opposed to an external monitor). Uses the live `CGDirectDisplayID`
    /// rather than any hardcoded model table, so it holds across all Mac models.
    /// `fileprivate` rather than `private`: also called from `ScreenSnapshot.init(screen:)`.
    nonisolated fileprivate static func isBuiltInDisplay(_ screen: NSScreen) -> Bool {
        guard let screenNumber = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else {
            return false
        }
        let displayID = CGDirectDisplayID(screenNumber.uint32Value)
        return CGDisplayIsBuiltin(displayID) != 0
    }

    /// Picks the screen to anchor the notch window to. Preference order:
    /// built-in display with a notch, then built-in display (no notch),
    /// then any screen reporting a notch-like safe area, then the system
    /// default, then simply the first available screen. The priority
    /// ordering itself lives in `selectScreenIndex(from:)` (pure, snapshot-based);
    /// this wrapper just supplies live `NSScreen`s and the `NSScreen.main`/first
    /// fallback, which has no snapshot equivalent.
    private static func selectScreen() -> NSScreen? {
        let screens = NSScreen.screens
        guard let index = selectScreenIndex(from: screens.map { ScreenSnapshot(screen: $0) }) else {
            return NSScreen.main ?? screens.first
        }
        return screens[index]
    }

    /// Pure version of `selectScreen()`'s priority logic (built-in+notch →
    /// built-in → any notch → none), operating on `ScreenSnapshot`s instead
    /// of live `NSScreen`s so the ordering can be exercised with fake screen
    /// configurations in tests.
    static func selectScreenIndex(from snapshots: [ScreenSnapshot]) -> Int? {
        if let index = snapshots.firstIndex(where: { $0.isBuiltIn && $0.safeAreaInsetsTop > 0 }) {
            return index
        }
        if let index = snapshots.firstIndex(where: { $0.isBuiltIn }) {
            return index
        }
        if let index = snapshots.firstIndex(where: { $0.safeAreaInsetsTop > 0 }) {
            return index
        }
        return nil
    }

    /// Derives the visible `.closed`-mode shape size from the physically
    /// measured notch width/height. Pulled out as a pure function so the
    /// margin/floor logic can be exercised without constructing a window.
    ///
    /// On a non-notched screen (`hasNotch == false`) this is byte-identical
    /// to the original formula (generous `notchSafeMargin` + a `220`pt floor)
    /// — non-notched Macs must keep their existing look unchanged. On a real
    /// notched Mac, the pill hugs the physical cutout more tightly
    /// (`notchHuggingMargin`, no `220`pt floor) so it visually merges with
    /// the notch instead of floating wider than it needs to.
    static func computeClosedSize(notchWidth: CGFloat, notchHeight: CGFloat, hasNotch: Bool) -> CGSize {
        guard hasNotch else {
            return CGSize(
                width: max(notchWidth + DesignTokens.notchSafeMargin, DesignTokens.compactMinContentWidth, 220),
                height: max(notchHeight, 34)
            )
        }
        return CGSize(
            width: max(notchWidth + DesignTokens.notchHuggingMargin, DesignTokens.compactMinContentWidth),
            height: max(notchHeight, 34)
        )
    }

    /// Derives `.hover`'s size. On a non-notched screen (`hasNotch == false`)
    /// this is the plain fixed default (320×90) the peek was originally
    /// designed for. On a real notched Mac, the width widens to at least
    /// `notchWidth`'s footprint so the pill visually merges with the
    /// physical notch cutout instead of floating as a narrower island next
    /// to it — matching the NotchNook reference look. Height stays fixed;
    /// `HoverPeekView`'s two rows don't depend on notch height.
    static func computeHoverSize(notchWidth: CGFloat, hasNotch: Bool) -> CGSize {
        let defaultSize = CGSize(width: 320, height: 90)
        guard hasNotch else { return defaultSize }
        return CGSize(width: max(notchWidth + 120, defaultSize.width), height: defaultSize.height)
    }

    /// The real window frame `.hover` gets, which is *not* the size of what
    /// it draws: the visible peek stays `contentSize` (pinned to the top by
    /// `NotchView`'s `ZStack(alignment: .top)`), while the window itself is
    /// never allowed to be smaller than the closed one.
    ///
    /// `closedSize` is deliberately padded out beyond the visible pill
    /// (+40w/+70h, for file-drag hit-testing). Before this, hovering could
    /// *shrink* the window — 104pt tall closed vs. 90pt hovering on a
    /// notchless screen — so a pointer resting in the ~14pt band between
    /// them fell outside the moment hover began: hover ended, the window
    /// grew back under the pointer, hover began again, and the panel
    /// flickered open/closed indefinitely.
    static func hoverWindowSize(contentSize: CGSize, closedSize: CGSize) -> CGSize {
        CGSize(
            width: max(contentSize.width, closedSize.width),
            height: max(contentSize.height, closedSize.height)
        )
    }

    /// Small safety margin added on top of the measured `notchHeight`.
    /// `safeAreaInsetsTop` is Apple's own boundary for "safe to place menu
    /// bar content", not a guaranteed pixel-exact match for the physical
    /// camera housing's actual bottom edge (anti-aliasing/rounding at the
    /// housing's corners can eat a few more points than the reported
    /// inset), so text starting exactly at that line can still clip under
    /// the housing at its rounded edges. A few extra points of clearance
    /// costs nothing on a notched screen (0 on non-notched, always).
    private static let notchClearanceSafetyMargin: CGFloat = 6

    /// Extra top space `.hover` must reserve before drawing anything
    /// readable. The physical camera housing on a real notched Mac is
    /// opaque — content placed in its `notchHeight`-tall footprint is
    /// invisible, not merely clipped — so `.hover` (which draws actual
    /// multi-line text, unlike `.closed`'s single glyph) needs to grow by
    /// that much (plus a small safety margin) and start its rows below the
    /// line. `0` on a non-notched screen, which must stay exactly as it was
    /// before notch-awareness.
    static func computeHoverTopClearance(notchHeight: CGFloat, hasNotch: Bool) -> CGFloat {
        guard hasNotch else { return 0 }
        return notchHeight + notchClearanceSafetyMargin
    }

    /// Vertical padding (10+10) + inter-row spacing (6) + one text line
    /// (~18) below `HoverPeekView`'s icon band on a real notched Mac — see
    /// `notchAwareContent`/`primaryInfo` there. The icon band's own height
    /// *is* `hoverTopClearance` (icons sit in the pill's left/right
    /// margins, clear of the notch), so unlike the pre-notch-aware layout
    /// this is additive on top of it rather than a separate reserved gap.
    /// Used for the session/idle case, which is a single line.
    private static let hoverNotchAwareContentBudget: CGFloat = 44

    /// Same as `hoverNotchAwareContentBudget` but for media: `primaryInfo`
    /// draws the track title *and* the artist as a second, smaller line
    /// underneath it (both were legible before this redesign; truncating
    /// the artist away entirely lost real information), so it needs a bit
    /// more room than the single-line session/idle case.
    private static let hoverNotchAwareMediaContentBudget: CGFloat = 54

    /// `.hover`'s pill height on a real notched Mac: the icon band
    /// (`topClearance` tall) plus the info text below it — never media and
    /// session simultaneously (see `HoverPeekView.primaryInfo`), so the only
    /// distinction left is media's extra artist line vs. session/idle's
    /// single line.
    static func computeHoverContentHeight(topClearance: CGFloat, isMediaPlaying: Bool) -> CGFloat {
        topClearance + (isMediaPlaying ? hoverNotchAwareMediaContentBudget : hoverNotchAwareContentBudget)
    }

    /// Every screen-derived value `NotchWindowController` keeps around,
    /// bundled together so `init` and the
    /// `didChangeScreenParametersNotification` handler can share one
    /// computation instead of duplicating it.
    private struct ScreenGeometry {
        let screen: NSScreen
        let snapshot: ScreenSnapshot
        let closedSize: CGSize
        let fullscreenHoverSize: CGSize
        let mediaPreviewSize: CGSize
        let visualClosedSize: CGSize
        let closedContentSize: CGSize
        let hoverSize: CGSize
        let hoverContentSize: CGSize
        let hoverTopClearance: CGFloat
        let hasRealNotch: Bool
        let debugScreenInfo: [String: Any]
    }

    /// 実機の物理ノッチ寸法（幅, 高さ）の軽量プリセット表。値はコミュニティ計測値ベースの
    /// 近似値でよく、ピクセル完全一致は狙わない（テスト用フラグの目的はHover挙動の目視確認）。
    private static let notchPresets: [String: (width: CGFloat, height: CGFloat)] = [
        "14": (200, 37),   // MacBook Pro 14/16-inch (2021+)
        "16": (200, 37),
        "air": (180, 37),  // MacBook Air 15-inch (2023+)
    ]
    private static let defaultNotchPresetKey = "14"

    /// テスト用フラグ: 環境変数 `AGENT_NOTCH_SIMULATE_NOTCH` が設定されている場合に限り、
    /// 実測の画面ジオメトリを模擬ノッチ搭載機の値に置き換える。物理ノッチを持たない開発機
    /// でも、ノッチ専用のHover挙動・クリアランス計算を目視確認できるようにするための踏み
    /// 台。値には機種プリセット名（"14"/"16"/"air"）を指定でき、`1`や未知の値は
    /// `defaultNotchPresetKey`にフォールバックする。未設定・`0`では常に`nil`を返し、
    /// 通常起動・配布物や既存の実機検出には一切影響しない。
    private static func simulatedNotchSnapshot(for screen: NSScreen) -> ScreenSnapshot? {
        guard let raw = ProcessInfo.processInfo.environment["AGENT_NOTCH_SIMULATE_NOTCH"], raw != "0" else { return nil }
        // Falls back to a hardcoded literal (not `notchPresets[defaultNotchPresetKey]!`)
        // so a future edit that renames/removes the "14" preset entry can't
        // turn this debug-only path into a crash — it would just silently
        // stop matching `defaultNotchPresetKey`'s intended values instead.
        let preset = notchPresets[raw] ?? notchPresets[defaultNotchPresetKey] ?? (width: 200, height: 37)
        let real = ScreenSnapshot(screen: screen)
        let sideWidth = max((real.frame.width - preset.width) / 2, 0)
        return ScreenSnapshot(
            frame: real.frame,
            safeAreaInsetsTop: preset.height,
            auxiliaryTopLeftWidth: sideWidth,
            auxiliaryTopRightWidth: sideWidth,
            isBuiltIn: true
        )
    }

    /// Computes `ScreenGeometry` for the given (already-selected) screen.
    /// Reads the screen exactly once via `ScreenSnapshot`; every derived
    /// value below is plain arithmetic over that snapshot, matching the
    /// calculation that used to run only once, inline, in `init`.
    private static func computeScreenGeometry(for resolvedScreen: NSScreen) -> ScreenGeometry {
        let snapshot = simulatedNotchSnapshot(for: resolvedScreen) ?? ScreenSnapshot(screen: resolvedScreen)
        let notchHeight: CGFloat = snapshot.safeAreaInsetsTop > 0 ? snapshot.safeAreaInsetsTop : 32

        // auxiliaryTop{Left,Right}Area の測定値には稀に負値や画面幅の大半を占める
        // ような異常値が返るケースがあるため、妥当な範囲外ならフォールバックする。
        var notchWidth: CGFloat = 200
        let hasAuxiliaryAreas = snapshot.auxiliaryTopLeftWidth != nil && snapshot.auxiliaryTopRightWidth != nil
        if let leftWidth = snapshot.auxiliaryTopLeftWidth, let rightWidth = snapshot.auxiliaryTopRightWidth {
            let measured = snapshot.frame.width - leftWidth - rightWidth
            if measured > 0 && measured <= snapshot.frame.width * 0.5 {
                notchWidth = measured
            }
        }

        // hasNotch (a real physical cutout) is `safeAreaInsetsTop > 0`, the
        // same signal `notchHeight`'s fallback branch above already keys
        // off — not `hasAuxiliaryAreas`, which can be true without an actual
        // notch (Apple documents the aux areas as "safe to place menu bar
        // content", not strictly "there is a physical cutout here").
        let hasRealNotch = snapshot.safeAreaInsetsTop > 0
        // 見た目のノッチサイズ（NotchViewが.closedモード時に固定描画するサイズ）
        let visualClosedSize = computeClosedSize(notchWidth: notchWidth, notchHeight: notchHeight, hasNotch: hasRealNotch)
        let mediaPreviewSize = CGSize(width: max(notchWidth + 116, 316), height: max(notchHeight, 34))
        let hoverTopClearance = computeHoverTopClearance(notchHeight: notchHeight, hasNotch: hasRealNotch)
        let debugScreenInfo: [String: Any] = [
            "safeAreaInsetsTop": snapshot.safeAreaInsetsTop,
            "hasAuxiliaryAreas": hasAuxiliaryAreas,
            "auxiliaryTopLeftWidth": snapshot.auxiliaryTopLeftWidth ?? 0,
            "auxiliaryTopRightWidth": snapshot.auxiliaryTopRightWidth ?? 0,
            "screenFrameWidth": snapshot.frame.width,
            "notchWidth": notchWidth,
            "notchHeight": notchHeight,
            "visualClosedWidth": visualClosedSize.width,
            "visualClosedHeight": visualClosedSize.height,
            "isBuiltInDisplay": snapshot.isBuiltIn,
            "hasRealNotch": hasRealNotch,
            "hoverTopClearance": hoverTopClearance,
            "simulatedNotchPreset": {
                guard let raw = ProcessInfo.processInfo.environment["AGENT_NOTCH_SIMULATE_NOTCH"], raw != "0" else { return "" }
                return notchPresets[raw] != nil ? raw : defaultNotchPresetKey
            }(),
        ]
        // closedSize は実際のウィンドウフレーム（ファイルドロップの当たり判定を兼ねる）。
        // 見た目より一回り大きくして常時ドロップを受け付けやすくする。控えめな増分に留め、
        // 他アプリのツールバー等をブロックしすぎないようにする（幅+40, 高さ+70）。
        let closedSize = CGSize(width: visualClosedSize.width + 40, height: visualClosedSize.height + 70)
        let fullscreenHoverSize = CGSize(width: min(closedSize.width, 140), height: closedSize.height)
        let closedContentSize = CGSize(
            width: visualClosedSize.width * AppSettings.shared.uiScale,
            height: visualClosedSize.height * AppSettings.shared.uiScale
        )
        let hoverSize = computeHoverSize(notchWidth: notchWidth, hasNotch: hasRealNotch)
        let hoverContentSize = CGSize(
            width: hoverSize.width * AppSettings.shared.uiScale,
            height: hoverSize.height * AppSettings.shared.uiScale
        )

        return ScreenGeometry(
            screen: resolvedScreen,
            snapshot: snapshot,
            closedSize: closedSize,
            fullscreenHoverSize: fullscreenHoverSize,
            mediaPreviewSize: mediaPreviewSize,
            visualClosedSize: visualClosedSize,
            closedContentSize: closedContentSize,
            hoverSize: hoverSize,
            hoverContentSize: hoverContentSize,
            hoverTopClearance: hoverTopClearance,
            hasRealNotch: hasRealNotch,
            debugScreenInfo: debugScreenInfo
        )
    }

    init(store: SessionStore, permissions: PermissionCenter, questions: QuestionCenter, plans: PlanCenter, nativeNotifier: NativeNotifier? = nil) {
        self.store = store
        self.permissions = permissions
        self.questions = questions
        self.plans = plans
        self.attention = AttentionCenter(permissions: permissions, questions: questions, plans: plans)
        self.nativeNotifier = nativeNotifier

        let resolvedScreen = NotchWindowController.selectScreen() ?? NSScreen()
        let geometry = NotchWindowController.computeScreenGeometry(for: resolvedScreen)
        self.screen = geometry.screen
        self.screenSnapshot = geometry.snapshot
        self.mediaPreviewSize = geometry.mediaPreviewSize
        self.visualClosedSize = geometry.visualClosedSize
        self.debugScreenInfo = geometry.debugScreenInfo
        // closedSize は実際のウィンドウフレーム（ファイルドロップの当たり判定を兼ねる）。
        // 見た目より一回り大きくして常時ドロップを受け付けやすくする。控えめな増分に留め、
        // 他アプリのツールバー等をブロックしすぎないようにする（幅+40, 高さ+70）。
        self.closedSize = geometry.closedSize
        self.fullscreenHoverSize = geometry.fullscreenHoverSize
        self.hoverSize = geometry.hoverSize
        self.hoverTopClearance = geometry.hoverTopClearance
        self.hasRealNotch = geometry.hasRealNotch
        self.uiState.closedContentSize = geometry.closedContentSize
        self.uiState.hoverContentSize = geometry.hoverContentSize
        self.uiState.hoverTopClearance = geometry.hoverTopClearance

        let initialScale = AppSettings.shared.uiScale
        let initialFrame = NotchWindowController.frame(
            for: CGSize(width: closedSize.width * initialScale, height: closedSize.height * initialScale),
            on: screenSnapshot
        )

        let panel = KeyableNotchPanel(
            contentRect: initialFrame,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.level = .statusBar
        // `.fullScreenAuxiliary` lets a long-enough hover at the top edge
        // temporarily surface the notch even over another app's fullscreen
        // Space.
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary]
        panel.isMovable = false
        panel.becomesKeyOnlyIfNeeded = true
        panel.hidesOnDeactivate = false
        panel.setFrame(initialFrame, display: false)
        let fileDropView = FileDropContainerView(frame: NSRect(origin: .zero, size: initialFrame.size))

        self.panel = panel
        self.fileDropView = fileDropView

        super.init()

        let notchView = NotchView(store: store, controller: self, permissions: permissions, questions: questions, plans: plans, attention: attention)
            .environmentObject(uiState)
        let hostingView = NSHostingView(rootView: notchView)
        hostingView.frame = fileDropView.bounds
        hostingView.autoresizingMask = [.width, .height]
        fileDropView.addSubview(hostingView)
        panel.contentView = fileDropView

        // Overlay presence changes the target height while already `.open`
        // (e.g. an approval overlay appearing/disappearing).
        uiState.$overlay
            .dropFirst()
            .sink { [weak self] _ in
                guard let self, self.uiState.mode == .open else { return }
                self.scheduleResize()
            }
            .store(in: &cancellables)

        uiState.$isMediaPreviewVisible
            .dropFirst()
            .sink { [weak self] _ in
                guard let self, self.uiState.mode == .closed else { return }
                self.scheduleResize()
            }
            .store(in: &cancellables)

        // Media/system polling spawns work (a Perl process, `ps`, IOKit
        // reads) on a timer, so it follows what's actually on screen rather
        // than running for the whole session. Any of these three inputs can
        // change what's visible, so they share one recomputation.
        Publishers.CombineLatest3(uiState.$mode, uiState.$isVisible, uiState.$isDetailExpanded)
            .sink { [weak self] mode, isVisible, isDetailExpanded in
                self?.applyPollingDemand(mode: mode, isVisible: isVisible, isDetailExpanded: isDetailExpanded)
            }
            .store(in: &cancellables)

        uiState.$isMediaPreviewVisible
            .sink { [weak self] _ in
                guard let self else { return }
                self.applyPollingDemand(
                    mode: self.uiState.mode,
                    isVisible: self.uiState.isVisible,
                    isDetailExpanded: self.uiState.isDetailExpanded
                )
            }
            .store(in: &cancellables)

        // The Dashboard's width is derived from which widgets are enabled
        // (see `dashboardWidth(for:maximum:)`), so editing the arrangement in
        // Settings has to resize the panel that's already open.
        settings.$tabLayouts
            .dropFirst()
            .sink { [weak self] _ in
                guard let self, self.uiState.mode == .open else { return }
                self.scheduleResize()
            }
            .store(in: &cancellables)

        uiState.$activeTab
            .dropFirst()
            .sink { [weak self] _ in
                guard let self else { return }
                // A detail panel left expanded from a previous tab would
                // otherwise carry its extra height into the new tab's size
                // calculation (`resizeForCurrentState`), making the notch
                // look wrong-sized after switching.
                self.uiState.isDetailExpanded = false
                guard self.uiState.mode == .open else { return }
                self.scheduleResize()
            }
            .store(in: &cancellables)

        // Switching into/out of the Agents Nook page changes which sizing
        // branch `resizeForCurrentState` takes (fixed `openSize` vs. the
        // session-count-driven `agentsOpenSize`).
        uiState.$activeView
            .dropFirst()
            .sink { [weak self] _ in
                guard let self else { return }
                self.uiState.isDetailExpanded = false
                guard self.uiState.mode == .open else { return }
                self.scheduleResize()
            }
            .store(in: &cancellables)

        // Dropping a file into the tray (or clearing it) while fullscreen
        // suppression is already active must re-evaluate visibility: items
        // arriving should surface the notch, and clearing the last item
        // should let normal fullscreen suppression resume.
        uiState.$trayHasItems
            .dropFirst()
            .sink { [weak self] _ in
                guard let self, Self.isNonFinderFullscreen(on: self.screen) else { return }
                self.refreshVisibilityForCurrentSpace()
            }
            .store(in: &cancellables)

        // The Agents tab's height tracks how many sessions are tracked, so
        // sessions appearing/disappearing while the tab is open must resize
        // the panel live (this is what lets the notch "grow" instead of
        // clipping/overlapping content, per the user's request).
        store.$sessions
            .dropFirst()
            .sink { [weak self] _ in
                guard let self else { return }
                if self.uiState.mode == .hover {
                    // Session count flipping the empty/tracked ⇄ present
                    // boundary changes whether `.hover` draws one row or two
                    // (see `resizeForCurrentState`'s `.hover` case).
                    self.scheduleResize()
                    return
                }
                guard self.uiState.mode == .open,
                      self.uiState.activeTab == .nook,
                      self.uiState.activeView == .agents else { return }
                self.scheduleResize()
            }
            .store(in: &cancellables)

        // No `TodayModel` subscription here: `dashboardOpenSize` depends on
        // nothing `TodayModel` publishes. `DashboardTodaySection` renders
        // the same single agenda line whether access is granted, denied, or
        // there are no events at all, and its week strip is fixed at five
        // columns — so neither `$authorizationStatus` nor `$events` can
        // change the row's height. `SystemMonitor`'s battery state likewise
        // never did.

        // `.hover`'s row count (one vs. two) also depends on whether media
        // is playing — resize live if playback starts/stops mid-peek.
        MediaController.shared.$isPlaying
            .dropFirst()
            .sink { [weak self] _ in
                guard let self, self.uiState.mode == .hover else { return }
                self.scheduleResize()
            }
            .store(in: &cancellables)

        // `questionOpenSize(for:)` depends on which step/mode the question
        // overlay is currently on — resize live as the user steps through a
        // multi-question batch or toggles free-text entry.
        uiState.$questionStepIndex
            .dropFirst()
            .sink { [weak self] _ in
                guard let self, self.uiState.overlay == .question else { return }
                self.scheduleResize()
            }
            .store(in: &cancellables)
        uiState.$questionCustomMode
            .dropFirst()
            .sink { [weak self] _ in
                guard let self, self.uiState.overlay == .question else { return }
                self.scheduleResize()
            }
            .store(in: &cancellables)
        uiState.$questionReviewMode
            .dropFirst()
            .sink { [weak self] _ in
                guard let self, self.uiState.overlay == .question else { return }
                self.scheduleResize()
            }
            .store(in: &cancellables)
        uiState.$questionPromptHeight
            .dropFirst()
            .sink { [weak self] _ in
                guard let self, self.uiState.overlay == .question else { return }
                self.scheduleResize()
            }
            .store(in: &cancellables)
        uiState.$approvalSummaryHeight
            .dropFirst()
            .sink { [weak self] _ in
                guard let self, case .approval = self.uiState.overlay else { return }
                self.scheduleResize()
            }
            .store(in: &cancellables)

        // Approval takes priority over agent questions. Both queues feed the
        // same inline surface without replacing the user's current Nook page.
        permissions.$queue
            .sink { [weak self] _ in
                guard let self else { return }
                guard self.uiState.mode != .open || !self.isClickPinned else { return }
                self.syncOverlay()
            }
            .store(in: &cancellables)

        questions.$queue
            .sink { [weak self] queue in
                guard let self else { return }
                if self.uiState.mode != .open || !self.isClickPinned {
                    self.syncOverlay()
                }
                if queue.isEmpty, self.permissions.queue.isEmpty, self.plans.queue.isEmpty, !self.isClickPinned {
                    self.setMode(.closed)
                }
            }
            .store(in: &cancellables)

        plans.$queue
            .sink { [weak self] queue in
                guard let self else { return }
                if self.uiState.mode != .open || !self.isClickPinned { self.syncOverlay() }
                if queue.isEmpty, self.permissions.queue.isEmpty, self.questions.queue.isEmpty, !self.isClickPinned {
                    self.setMode(.closed)
                }
            }
            .store(in: &cancellables)

        // The notch stays visible everywhere except a non-Finder app's true
        // fullscreen window. This is intentionally independent of which
        // ordinary app is frontmost.
        shouldPersistVisible = !Self.isNonFinderFullscreen(on: resolvedScreen)
        uiState.isVisible = shouldPersistVisible

        workspaceObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] note in
            let bundleId = (note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication)?.bundleIdentifier
            Task { @MainActor in
                self?.handleFrontmostChange(bundleId: bundleId)
            }
        }

        spaceObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.activeSpaceDidChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.scheduleVisibilityRefresh()
            }
        }

        // External display connect/disconnect, resolution changes, and
        // scaling changes all fire this notification; the notch's screen
        // selection and geometry (built at `init` time only, previously)
        // need to be recomputed so the panel keeps tracking the right
        // display and the right notch size.
        screenParametersObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.scheduleScreenGeometryRefresh()
            }
        }

        scrollMonitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
            self?.handleScroll(event)
            return event
        }

        let outsideClickMask: NSEvent.EventTypeMask = [.leftMouseDown, .rightMouseDown, .otherMouseDown]
        outsideClickLocalMonitor = NSEvent.addLocalMonitorForEvents(matching: outsideClickMask) { [weak self] event in
            guard let self else { return event }
            // An event delivered to the notch panel is always an inside
            // interaction. AXPress may not update `NSEvent.mouseLocation`,
            // so coordinate-only checks incorrectly dismissed tab clicks.
            if event.window !== self.panel {
                self.collapseForOutsideClickIfNeeded()
            }
            return event
        }
        outsideClickGlobalMonitor = NSEvent.addGlobalMonitorForEvents(matching: outsideClickMask) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.collapseForOutsideClickIfNeeded()
            }
        }
    }

    /// Picks which of the three queues' items shows, via `attention.items`'
    /// urgency sort (permission > plan > question — see `AttentionUrgency`)
    /// instead of a hand-rolled if/else chain. `extraCount`/`otherAgentPending`
    /// stay scoped to the permission queue alone, exactly as before this
    /// unification — generalizing them to "other items of any type" would
    /// change what `ApprovalOverlayView`'s `+N (Codex)` badge means, which
    /// is out of scope here.
    private func syncOverlay() {
        uiState.activeTab = .nook
        guard let top = attention.items.first else {
            uiState.overlay = nil
            return
        }
        switch top.source {
        case .permission(let first):
            let otherAgent = permissions.queue.dropFirst().first { $0.agent != first.agent }?.agent
            uiState.overlay = .approval(
                agent: first.agent,
                toolName: first.toolName,
                summary: first.summary,
                extraCount: permissions.queue.count - 1,
                otherAgentPending: otherAgent,
                cwd: first.cwd,
                isDangerous: first.details.isDangerous
            )
        case .plan:
            uiState.overlay = .plan
        case .question:
            uiState.overlay = .question
        }
    }

    deinit {
        visibilityRefreshTask?.cancel()
        screenGeometryRefreshTask?.cancel()
        noticeAutoDismissTask?.cancel()
        if let workspaceObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(workspaceObserver)
        }
        if let spaceObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(spaceObserver)
        }
        if let screenParametersObserver {
            NotificationCenter.default.removeObserver(screenParametersObserver)
        }
        if let scrollMonitor {
            NSEvent.removeMonitor(scrollMonitor)
        }
        if let outsideClickLocalMonitor {
            NSEvent.removeMonitor(outsideClickLocalMonitor)
        }
        if let outsideClickGlobalMonitor {
            NSEvent.removeMonitor(outsideClickGlobalMonitor)
        }
    }

    /// Debounces `didChangeScreenParametersNotification`, which can fire
    /// several times in quick succession while a display is connecting,
    /// disconnecting, or changing resolution/scaling. Mirrors
    /// `scheduleVisibilityRefresh()`'s two-step settle pattern (immediate
    /// pass, then two follow-up passes as things finish settling).
    private func scheduleScreenGeometryRefresh() {
        screenGeometryRefreshTask?.cancel()
        refreshScreenGeometry()
        screenGeometryRefreshTask = Task { [weak self] in
            for delay in [180_000_000, 520_000_000] as [UInt64] {
                try? await Task.sleep(nanoseconds: delay)
                guard !Task.isCancelled, let self else { return }
                self.refreshScreenGeometry()
            }
        }
    }

    /// Re-selects the anchor screen and recomputes every screen-dependent
    /// property (mirroring what `init` computed once), then resizes the
    /// panel to its new frame. Safe to call repeatedly; it's a no-op beyond
    /// re-deriving the same values when nothing actually changed.
    private func refreshScreenGeometry() {
        guard let resolvedScreen = NotchWindowController.selectScreen() else { return }
        let geometry = NotchWindowController.computeScreenGeometry(for: resolvedScreen)
        screen = geometry.screen
        screenSnapshot = geometry.snapshot
        closedSize = geometry.closedSize
        fullscreenHoverSize = geometry.fullscreenHoverSize
        mediaPreviewSize = geometry.mediaPreviewSize
        visualClosedSize = geometry.visualClosedSize
        hoverSize = geometry.hoverSize
        hoverTopClearance = geometry.hoverTopClearance
        hasRealNotch = geometry.hasRealNotch
        debugScreenInfo = geometry.debugScreenInfo
        uiState.closedContentSize = geometry.closedContentSize
        uiState.hoverContentSize = geometry.hoverContentSize
        uiState.hoverTopClearance = geometry.hoverTopClearance
        scheduleResize()
    }

    /// Applies `AppSettings.uiScale` to a base panel size immediately before
    /// it's turned into a screen frame. Base size constants (`closedSize`,
    /// `openSize`, etc.) stay untouched so they keep documenting the
    /// 1.0-scale defaults.
    private func scaled(_ size: CGSize) -> CGSize {
        let scale = AppSettings.shared.uiScale
        return CGSize(width: size.width * scale, height: size.height * scale)
    }

    /// Where the panel sits: horizontally centred on the screen, flush with
    /// its top edge (the notch grows downward from the menu bar).
    ///
    /// `internal` so the placement is testable — it has to stay correct on a
    /// secondary display, whose frame origin is offset from zero and can be
    /// negative when the display is arranged to the left of the primary.
    static func frame(for size: CGSize, on snapshot: ScreenSnapshot) -> NSRect {
        let x = snapshot.frame.midX - size.width / 2
        let y = snapshot.frame.maxY - size.height
        return NSRect(x: x, y: y, width: size.width, height: size.height)
    }

    /// How close a window union has to come to filling the screen before it
    /// counts as fullscreen. A few points of slack absorb rounding and the
    /// shadow insets reported by the window server.
    static let fullscreenTolerance: CGFloat = 12

    /// The geometric half of `isNonFinderFullscreen`, split out so the
    /// tolerance can be tested without a live window server. Getting this
    /// wrong in either direction is user-visible: too strict and the notch
    /// covers fullscreen video, too loose and it hides during ordinary use.
    static func coversScreen(union: CGRect, screenFrame: CGRect) -> Bool {
        union.width >= screenFrame.width - fullscreenTolerance
            && union.height >= screenFrame.height - fullscreenTolerance
    }

    private static func isNonFinderFullscreen(on screen: NSScreen) -> Bool {
        guard let app = NSWorkspace.shared.frontmostApplication else { return false }
        if app.bundleIdentifier == "com.apple.finder" { return false }
        guard let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else {
            return false
        }
        let screenFrame = screen.frame
        var unionRect: CGRect?
        for info in windows {
            guard (info[kCGWindowOwnerPID as String] as? pid_t) == app.processIdentifier,
                  (info[kCGWindowLayer as String] as? Int) == 0,
                  let boundsDictionary = info[kCGWindowBounds as String] as? NSDictionary,
                  let bounds = CGRect(dictionaryRepresentation: boundsDictionary as CFDictionary) else { continue }
            unionRect = unionRect?.union(bounds) ?? bounds
        }
        guard let unionRect else { return false }
        return coversScreen(union: unionRect, screenFrame: screenFrame)
    }

    func showWindow() {
        panel.orderFrontRegardless()
    }

    func installFileDropHandlers(
        targeted: @escaping (Bool, CGPoint) -> Void,
        dropped: @escaping ([URL], CGPoint) -> Void
    ) {
        fileDropView.fileDragStateHandler = { [weak self] active, location in
            guard let self else { return }
            targeted(active, location)
            guard active else { return }
            // This now fires on every pointer move (`draggingUpdated`, added
            // so the AirDrop well can highlight as the drag passes over it),
            // not once per drag. `@Published` doesn't compare values, so
            // assigning the same state again would republish and redraw the
            // whole panel on every mouse move — hence the guards. `setMode`
            // already early-returns for an unchanged mode.
            if !self.uiState.isVisible { self.uiState.isVisible = true }
            if self.uiState.activeTab != .tray { self.uiState.activeTab = .tray }
            self.setMode(.open)
        }
        fileDropView.fileDropHandler = dropped
    }

    func removeFileDropHandlers() {
        fileDropView.fileDragStateHandler = nil
        fileDropView.fileDropHandler = nil
    }

    /// Replaces the old `setExpanded(_:)`. Animates the panel frame to the
    /// size for `mode` (and, for `.open`, to the taller overlay size when
    /// `uiState.hasOverlay` is true).
    func setMode(_ mode: IslandMode, forceResize: Bool = false) {
        // The first-run guide holds the panel open until it's dismissed.
        // Guarding here rather than at each call site because the paths that
        // collapse the panel are many and unrelated (empty attention queues,
        // hover exit, fullscreen changes, the app delegate's collapse timer)
        // — and a guide that vanishes seconds after launch teaches nothing.
        // `dismissOnboarding` clears the flag before closing, so it still
        // gets through.
        if uiState.isShowingOnboarding, mode != .open { return }
        guard uiState.mode != mode || forceResize else { return }
        if mode != .closed {
            uiState.isMediaPreviewVisible = false
        }
        uiState.mode = mode
        scheduleResize()
        if mode == .closed {
            scheduleHideIfIdle()
        } else {
            hideTask?.cancel()
        }
    }

    /// Defers `resizeForCurrentState()` to the next runloop turn and drops
    /// duplicate requests queued before it runs, so several state changes
    /// firing in the same tick (e.g. `activeTab` and `activeView` both
    /// updating from one tab switch) collapse into a single animation.
    /// Routes the current panel state to the polling monitors. Media keeps a
    /// slow tick even when hidden (the closed pill still shows a now-playing
    /// state); the other two stop entirely, since nothing they produce is on
    /// screen unless the panel — or its detail strip — is open.
    private func applyPollingDemand(mode: IslandMode, isVisible: Bool, isDetailExpanded: Bool) {
        let panelOpen = isVisible && mode == .open
        let mediaOnScreen = isVisible && (mode == .open || mode == .hover || uiState.isMediaPreviewVisible)
        MediaController.shared.setPanelVisible(mediaOnScreen)
        SystemMonitor.shared.setPollingEnabled(panelOpen)
        BackgroundActivityMonitor.shared.setPollingEnabled(panelOpen && isDetailExpanded)
    }

    private func scheduleResize() {
        guard !resizeScheduled else { return }
        resizeScheduled = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.resizeScheduled = false
            self.resizeForCurrentState()
        }
    }

    private func resizeForCurrentState() {
        let targetSize: CGSize
        switch uiState.mode {
        case .closed:
            if !shouldPersistVisible {
                // While fullscreen-suppressed: keep the hit-test region narrow
                // (avoids colliding with a fullscreen app's own top-edge
                // chrome-reveal gesture) only while hidden. Once a long hover
                // actually reveals the notch, it needs the normal width or
                // the fixed-size visual content (`uiState.closedContentSize`)
                // gets clipped at both edges.
                targetSize = uiState.isVisible ? closedSize : fullscreenHoverSize
            } else {
                targetSize = uiState.isMediaPreviewVisible ? mediaPreviewSize : closedSize
            }
        case .hover:
            let baseHeight: CGFloat
            if hoverTopClearance > 0 {
                // Real notched Mac: icon band (topClearance-tall) + the info
                // text below it — media gets an extra artist line, see
                // `HoverPeekView.primaryInfo`.
                baseHeight = Self.computeHoverContentHeight(topClearance: hoverTopClearance, isMediaPlaying: MediaController.shared.isPlaying)
            } else {
                // Non-notched fallback (only reachable via the debug
                // `--mode hover` CLI bypass, since `.hover` itself is gated
                // to real notches — see `shouldEnterHover`). `HoverPeekView`
                // draws a second row only when media is playing *and* a
                // session is being tracked; otherwise it's a single row.
                let hasTwoRows = MediaController.shared.isPlaying && !store.sessions.isEmpty
                baseHeight = hasTwoRows ? hoverSize.height : Self.hoverCompactHeight
            }
            targetSize = CGSize(width: hoverSize.width, height: baseHeight)
        case .notice:
            targetSize = noticeSize
        case .open:
            // Checked ahead of `overlay` because the guide replaces the whole
            // panel body — see `NotchView.openContent`.
            if uiState.isShowingOnboarding {
                targetSize = CGSize(width: Self.openSize.width, height: Self.onboardingHeight)
                break
            }
            switch uiState.overlay {
            case .question:
                targetSize = questions.queue.first.map(questionOpenSize(for:)) ?? openQuestionSize
            case .approval(_, let toolName, _, _, _, _, _):
                // `ExitPlanMode` renders as `PlanApprovalOverlayView` instead
                // (see `overlayCell(_:)`) — entirely fixed/known-height
                // content (a header row + two 38pt `PlanChoiceButton`s), so
                // it gets its own fixed size rather than `approvalOpenSize()`,
                // which is driven by `uiState.approvalSummaryHeight` — a
                // value only the *other* (regular) approval card ever writes.
                targetSize = toolName == "ExitPlanMode" ? planApprovalOpenSize : approvalOpenSize()
            case .plan:
                targetSize = planOpenSize
            case nil:
                if uiState.activeTab == .tray {
                    targetSize = trayOpenSize
                } else if uiState.activeView == .agents {
                    targetSize = Self.agentsOpenSize(sessionCount: store.sessions.count, detailExpanded: uiState.isDetailExpanded)
                } else {
                    targetSize = Self.dashboardOpenSize(
                        width: Self.dashboardWidth(
                            for: DashboardWidget.resolved(from: settings.tabLayouts[DashboardWidget.layoutKey]),
                            // Leaves a margin either side rather than letting
                            // the panel reach the screen edges.
                            maximum: screen.frame.width - 120
                        ),
                        detailExpanded: uiState.isDetailExpanded
                    )
                }
            }
        }

        // `.hover`'s height varies per render (one vs. two rows, above), so
        // unlike `closedContentSize` (fixed per screen), the explicit
        // SwiftUI content frame it drives must be refreshed here alongside
        // the real window frame rather than only on screen-geometry changes.
        if uiState.mode == .hover {
            uiState.hoverContentSize = scaled(targetSize)
        } else if uiState.mode == .closed {
            // Same reasoning as `.hover` above, for the media-preview case:
            // the real window frame already grows to `mediaPreviewSize`
            // (`targetSize = uiState.isMediaPreviewVisible ? mediaPreviewSize
            // : closedSize` above, but only while `shouldPersistVisible` —
            // the fullscreen-suppressed branch never uses `mediaPreviewSize`
            // at all, see its own comment above), while `closedContentSize`
            // was otherwise only ever recomputed on screen-geometry changes —
            // leaving a transparent, un-rendered gap while media preview is
            // visible. `mediaPreviewSize` is already a "visual" (unpadded)
            // size like `visualClosedSize`, unlike `closedSize`'s
            // `+40w/+70h` hit-test padding, so both sides use it directly.
            // Mirror the exact same condition the switch above used, so this
            // never disagrees with what `targetSize` actually was.
            let previewActive = shouldPersistVisible && uiState.isMediaPreviewVisible
            uiState.closedContentSize = scaled(previewActive ? mediaPreviewSize : visualClosedSize)
        }

        // `.hover` draws `targetSize` but must not *occupy* less than the
        // closed window does — see `hoverWindowSize`'s doc comment for the
        // open/closed flicker that caused.
        let windowSize = uiState.mode == .hover
            ? NotchWindowController.hoverWindowSize(contentSize: targetSize, closedSize: closedSize)
            : targetSize
        let targetFrame = NotchWindowController.frame(for: scaled(windowSize), on: screenSnapshot)

        NSAnimationContext.runAnimationGroup { context in
            context.duration = (uiState.mode == .closed ? 0.25 : 0.40) * AppSettings.shared.animationSpeedScale
            context.timingFunction = CAMediaTimingFunction(controlPoints: 0.20, 0.72, 0.24, 1)
            panel.animator().setFrame(targetFrame, display: true)
        }
    }

    /// Fixed chrome around `AgentQuestionView`'s content, *excluding* the
    /// prompt text itself: the 30pt tab bar, `CellSurface`'s 7pt padding
    /// top+bottom, the header row (agent label + header/step capsules), and
    /// the two 7pt spacing gaps around the prompt. The prompt's own height
    /// is added separately from `uiState.questionPromptHeight` (live-
    /// measured — see its doc comment — since it can run to several lines
    /// and a fixed budget either clipped long prompts or wasted space on
    /// short ones).
    private let questionBaseHeight: CGFloat = 110
    /// One `QuestionChoiceButton` row (32pt, or 42pt when any option has a
    /// `detail` line) plus the 5pt spacing before the next row.
    private let questionOptionRowHeight: CGFloat = 37
    private let questionOptionRowHeightWithDetail: CGFloat = 47
    /// `customAnswerView`'s fixed-height `TextEditor` (74) + its 8pt spacing
    /// + the "Send answer" button (32).
    private let questionCustomAnswerHeight: CGFloat = 114
    /// One `MultiSelectChoiceRow` (34pt checkbox row) plus 5pt spacing, plus
    /// a fixed 40pt for the "Continue" confirm button + its own spacing —
    /// mirrors `questionOptionRowHeight`'s single-select math but budgets
    /// extra for the explicit confirm step multi-select needs (there's no
    /// single tap that unambiguously means "done" the way single-select
    /// has).
    private let questionMultiSelectRowHeight: CGFloat = 39
    private let questionMultiSelectConfirmHeight: CGFloat = 40
    /// The review-before-send screen's content is a capped, internally
    /// scrollable list (mirrors `ApprovalOverlayView.summaryBoxMaxHeight`'s
    /// pattern) plus a fixed "Send answers" button row, so — unlike the
    /// other branches — this doesn't need to grow with the number of
    /// questions in the batch.
    private let questionReviewHeight: CGFloat = 190
    private let questionMinHeight: CGFloat = 150

    /// Sizes the `.question` overlay to fit the *current step's* content
    /// instead of always reserving `openQuestionSize`'s full height — a
    /// short 2-option question left most of that height as dead space
    /// below the buttons (reported as looking broken, not just wasteful).
    /// Mostly mirrors `agentsOpenSize`'s "compute from known row math, cap
    /// at a max" approach, except the prompt itself is measured live
    /// (`uiState.questionPromptHeight`) rather than budgeted for a fixed
    /// line count, since prompts vary from one short line to several.
    private func questionOpenSize(for request: QuestionCenter.Request) -> CGSize {
        if uiState.questionReviewMode {
            // Self-contained: no per-question prompt row here, just the
            // fixed header + capped scrollable answer list + send button —
            // see `questionReviewHeight`'s doc comment.
            let height = max(questionReviewHeight, questionMinHeight)
            return CGSize(width: openQuestionSize.width, height: min(height, openQuestionSize.height))
        }
        let stepIndex = min(max(uiState.questionStepIndex, 0), request.questions.count - 1)
        let question = request.questions[stepIndex]
        let bodyHeight: CGFloat
        if question.options.isEmpty || uiState.questionCustomMode {
            bodyHeight = questionCustomAnswerHeight
        } else if question.isMultiSelect {
            bodyHeight = CGFloat(question.options.count) * questionMultiSelectRowHeight - 5 + questionMultiSelectConfirmHeight
        } else {
            let hasDetail = question.options.contains { !$0.detail.isEmpty }
            let rowHeight = hasDetail ? questionOptionRowHeightWithDetail : questionOptionRowHeight
            bodyHeight = CGFloat(question.options.count) * rowHeight - 5
        }
        let height = max(questionBaseHeight + uiState.questionPromptHeight + bodyHeight, questionMinHeight)
        return CGSize(width: openQuestionSize.width, height: min(height, openQuestionSize.height))
    }

    /// Fixed chrome around `ApprovalOverlayView`'s pre-decision content,
    /// *excluding* the summary box: 30pt tab bar, `CellSurface`'s 7pt
    /// padding top+bottom, the request-header row (~20pt), the tool-name
    /// row (~20pt), the cwd row (~16pt, added for the Phase 3 info-separation
    /// pass — folder icon + path, plus the dangerous-command caption when
    /// present), the outer `VStack(spacing: 8)`'s 5 gaps (header→tool→cwd→
    /// summary→spacer→buttons), the `Spacer(minLength: 10)` before the
    /// buttons, and the button row (`ApprovalActionButton`'s `minHeight:
    /// 36`, not 30 — an earlier version of this budget under-counted it,
    /// which is what made the card look cramped/pinned at the bottom: the
    /// `Spacer` was bottoming out at its minimum with no slack left). Plus
    /// a small extra margin so it errs toward comfortable rather than tight.
    /// The summary box's *text* height is measured live and capped at
    /// `ApprovalOverlayView.summaryBoxMaxHeight`, since beyond that it
    /// becomes internally scrollable instead of growing the panel further —
    /// see `ApprovalOverlayView`'s doc comment on that constant.
    private let approvalBaseHeight: CGFloat = 212
    private let approvalMinHeight: CGFloat = 195
    /// Deliberately *not* `openOverlaySize.height` (246) — the summary box
    /// has no `lineLimit`, so a long command/diff excerpt must be allowed to
    /// grow well past the old fixed size rather than being clipped by the
    /// outer frame, which would hide the dangerous part of what's being
    /// approved. Mirrors `agentsMaxHeight`'s role as a generous safety cap.
    private let approvalMaxHeight: CGFloat = 420

    private func approvalOpenSize() -> CGSize {
        let height = max(approvalBaseHeight + uiState.approvalSummaryHeight, approvalMinHeight)
        return CGSize(width: openOverlaySize.width, height: min(height, approvalMaxHeight))
    }

    /// `PlanApprovalOverlayView`'s (ExitPlanMode) content is entirely fixed —
    /// a header row plus two 38pt `PlanChoiceButton`s — so unlike the
    /// regular approval card it needs no live measurement, just a smaller
    /// constant than the `openOverlaySize` it used to reuse.
    private let planApprovalOpenSize = CGSize(width: 540, height: 202)

    /// `PlanReviewView`'s content is entirely fixed/`lineLimit`-capped
    /// (title is 1 line, summary is capped at 2, the comment field and
    /// button row are both fixed-height) — unlike question/approval, no
    /// live measurement is needed, just a smaller constant than the shared
    /// `openOverlaySize` it used to reuse.
    private let planOpenHeight: CGFloat = 190

    private var planOpenSize: CGSize {
        CGSize(width: openOverlaySize.width, height: planOpenHeight)
    }

    /// Height budget for the Agents Nook page. Unlike the other pages
    /// (fixed `openSize`), Agents shows a full vertical list of every
    /// tracked session, so a fixed height either clips content or (as
    /// reported) lets the footer action row visually float outside the
    /// card once the list plus footer exceed it. Growing the panel to fit,
    /// up to `agentsMaxVisibleRows`/`agentsMaxHeight`, is what fixes that;
    /// beyond the cap `AgentsCell.sessionList`'s own `ScrollView` takes
    /// over so the notch never grows large enough to run off-screen.
    /// `static` so the formula is testable on its own: a panel sized too
    /// small for its content clips the footer, which has shipped as a bug
    /// twice already.
    static func agentsOpenSize(sessionCount: Int, detailExpanded: Bool) -> CGSize {
        let visibleRows = max(1, min(sessionCount, Self.agentsMaxVisibleRows))
        var height = Self.agentsBaseHeight + Self.agentsRowHeight * CGFloat(visibleRows - 1)
        if detailExpanded {
            height += Self.openDetailSize.height - Self.openSize.height
        }
        return CGSize(width: Self.openSize.width, height: min(height, Self.agentsMaxHeight))
    }

    /// Whether a continued hover over the already-visible `.closed` notch
    /// should be allowed to dwell into `.hover` (a lightweight peek). Pulled
    /// out as a pure function, mirroring `computeClosedSize`/
    /// `selectScreenIndex`, so the "Attention (approval/question/plan)
    /// always wins over Hover" and "fullscreen suppresses Hover too"
    /// invariants are testable without a live window/timers.
    static func shouldEnterHover(
        currentMode: IslandMode,
        shouldPersistVisible: Bool,
        isClickPinned: Bool,
        hasPendingAttention: Bool,
        hasRealNotch: Bool
    ) -> Bool {
        // `.hover` is a NotchNook-style peek meant specifically for real
        // notched Macs; a non-notched screen must keep behaving exactly as
        // it did before `.hover` existed (compact pill only, straight to
        // Expanded on click — no intermediate hover peek).
        hasRealNotch && currentMode == .closed && shouldPersistVisible && !isClickPinned && !hasPendingAttention
    }

    func hoverChanged(_ inside: Bool) {
        guard isHovering != inside else { return }
        isHovering = inside
        hoverTask?.cancel()
        dwellTask?.cancel()
        hoverExpandTask?.cancel()
        if inside {
            hideTask?.cancel()
            if !uiState.isVisible {
                let dwellNanoseconds: UInt64 = shouldPersistVisible ? 300_000_000 : 900_000_000
                dwellTask = Task { [weak self] in
                    try? await Task.sleep(nanoseconds: dwellNanoseconds)
                    guard !Task.isCancelled, self?.isHovering == true else { return }
                    self?.showMinimal(bypassFullscreenSuppression: true)
                }
                return
            }
            // Hover never opens the panel by itself — that stays an explicit
            // click (`toggleOpen()`) so the same pointer action always has
            // the same result — but a further dwell while sitting in
            // `.closed` expands to `.hover`, a lightweight peek (song/
            // project/status/elapsed time). `shouldEnterHover` guards
            // against fullscreen suppression and any pending Attention item,
            // which always takes over via `showAttention()` instead.
            if NotchWindowController.shouldEnterHover(
                currentMode: uiState.mode,
                shouldPersistVisible: shouldPersistVisible,
                isClickPinned: isClickPinned,
                hasPendingAttention: hasPendingAttention,
                hasRealNotch: hasRealNotch
            ) {
                hoverExpandTask = Task { [weak self] in
                    try? await Task.sleep(nanoseconds: UInt64(DesignTokens.hoverExpandDelay * 1_000_000_000))
                    guard !Task.isCancelled, let self, self.isHovering else { return }
                    guard NotchWindowController.shouldEnterHover(
                        currentMode: self.uiState.mode,
                        shouldPersistVisible: self.shouldPersistVisible,
                        isClickPinned: self.isClickPinned,
                        hasPendingAttention: self.hasPendingAttention,
                        hasRealNotch: self.hasRealNotch
                    ) else { return }
                    self.setMode(.hover)
                }
            }
            return
        }
        if !shouldPersistVisible, uiState.isVisible, uiState.mode == .closed {
            scheduleHideIfIdle()
        }
        guard permissions.queue.isEmpty, questions.queue.isEmpty, plans.queue.isEmpty else { return }
        // Tray contents keep the compact badge visible, but must not trap the
        // expanded panel on screen. Explicit outside/Escape dismissal remains
        // available even while the temporary shelf contains files.
        if uiState.mode == .closed, uiState.trayHasItems { return }
        guard !isClickPinned else { return }
        hoverTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(DesignTokens.hoverCollapseDelay * 1_000_000_000))
            guard !Task.isCancelled, let self, !self.isHovering else { return }
            guard self.permissions.queue.isEmpty, self.questions.queue.isEmpty, self.plans.queue.isEmpty else { return }
            if self.uiState.mode == .closed, self.uiState.trayHasItems { return }
            guard !self.isClickPinned else { return }
            self.setMode(.closed)
        }
    }

    /// Makes the minimal notch visible without changing `mode` (it is
    /// always `.closed` while hidden, so this is a no-op on sizing).
    private func showMinimal(bypassFullscreenSuppression: Bool = false) {
        guard shouldPersistVisible || bypassFullscreenSuppression else { return }
        hideTask?.cancel()
        uiState.isVisible = true
        // Without this, the real NSPanel frame can be left at
        // `fullscreenHoverSize` (the narrow hover-only hit region used while
        // fullscreen-suppressed) even though SwiftUI now renders full-width
        // `.closed` content into it — physically clipping the right side.
        scheduleResize()
    }

    /// Opens the notch onto the first-run gesture guide. Pinned open, since
    /// the whole point is that the user hasn't yet learned the hover/click
    /// behaviour that would otherwise dismiss it out from under them.
    /// `force` is what the Settings button uses to replay it.
    func showOnboarding(force: Bool = false) {
        guard force || !AppSettings.shared.hasSeenOnboarding else { return }
        dwellTask?.cancel()
        hideTask?.cancel()
        hoverTask?.cancel()
        hoverExpandTask?.cancel()
        uiState.isShowingOnboarding = true
        uiState.isVisible = true
        isClickPinned = true
        setMode(.open)
    }

    func dismissOnboarding() {
        AppSettings.shared.hasSeenOnboarding = true
        uiState.isShowingOnboarding = false
        isClickPinned = false
        setMode(.closed)
    }

    /// Important events reveal the compact notch but never take over the
    /// current page. The user opens the actionable surface with a click.
    func showAttention() {
        guard shouldPersistVisible else {
            notifyFallbackIfNeeded()
            return
        }
        dwellTask?.cancel()
        hideTask?.cancel()
        isClickPinned = false
        uiState.isVisible = true
        syncOverlay()
        guard AppSettings.shared.autoOpenOnAttention else {
            // Badge only. The request still sits in its queue waiting — this
            // just declines to take over the screen to announce it, leaving
            // the click to the user. `scheduleHideIfIdle` won't hide it
            // either: it bails while any attention queue is non-empty.
            setMode(.closed, forceResize: true)
            return
        }
        setMode(.open, forceResize: true)
    }

    /// Fullscreen suppression means the notch UI itself cannot appear, so
    /// this is the only signal the user gets. Each queued request notifies
    /// at most once, tracked by id, so repeated `showAttention()` calls
    /// (e.g. from `refreshVisibilityForCurrentSpace`) don't re-fire it.
    private func notifyFallbackIfNeeded() {
        guard let nativeNotifier else { return }
        for permission in permissions.queue where !notifiedPermissionIDs.contains(permission.id) {
            notifiedPermissionIDs.insert(permission.id)
            let title = String(localized: "notification.permission.title", defaultValue: "\(permission.agent.displayName) needs approval")
            let body = String(localized: "notification.permission.body", defaultValue: "\(permission.toolName): \(permission.summary)")
            nativeNotifier.notify(title: title, body: body, agentGlyph: permission.agent)
        }
        for plan in plans.queue where !notifiedPlanIDs.contains(plan.id) {
            notifiedPlanIDs.insert(plan.id)
            let title = String(localized: "notification.plan.title", defaultValue: "\(plan.agent.displayName) plan ready for review")
            nativeNotifier.notify(title: title, body: plan.title, agentGlyph: plan.agent)
        }
        for question in questions.queue where !notifiedQuestionIDs.contains(question.id) {
            notifiedQuestionIDs.insert(question.id)
            let title = String(localized: "notification.question.title", defaultValue: "\(question.agent.displayName) has a question")
            nativeNotifier.notify(title: title, body: question.prompt, agentGlyph: question.agent)
        }
    }

    func showAgentActivity(urgent: Bool) {
        if uiState.mode != .open || !isClickPinned {
            uiState.activeTab = .nook
            uiState.activeView = .agents
        }
        guard shouldPersistVisible else {
            // Fullscreen suppression hides the notch UI itself, so an urgent
            // AgentNotchSession event (attention/fail) would otherwise be
            // silently dropped, unlike the permissions/plans/questions
            // queues which fall back to a native notification via
            // `notifyFallbackIfNeeded()`. That helper is queue-shaped and
            // doesn't know about session attention/fail events, so notify
            // directly here instead, throttled to avoid spamming repeats.
            if urgent { notifyAgentActivityFallbackIfNeeded() }
            return
        }
        uiState.isVisible = true
        if urgent { showAttention() }
    }

    private func notifyAgentActivityFallbackIfNeeded() {
        guard let nativeNotifier else { return }
        let now = Date()
        if let last = lastAgentActivityNotifyDate,
           now.timeIntervalSince(last) < agentActivityNotifyMinInterval {
            return
        }
        lastAgentActivityNotifyDate = now
        let title = String(localized: "notification.agentActivity.title", defaultValue: "Agent needs attention")
        let body = String(localized: "notification.agentActivity.body", defaultValue: "Open AgentNotch to see what happened")
        nativeNotifier.notify(title: title, body: body)
    }

    /// `mode: .hover`はテスト・デバッグ専用: フルスクリーン抑制やホバー実ジェスチャー
    /// なしに`.hover`を直接強制表示し、`AGENT_NOTCH_SIMULATE_NOTCH`との組み合わせで
    /// 異なるノッチ寸法でのHover外観をスクリーンショット等で目視確認できるようにする。
    func showFromCLI(mode: IslandMode = .open) {
        // An explicit CLI command is a manual override. Automatic activity,
        // questions and hover still respect fullscreen suppression.
        dwellTask?.cancel()
        hideTask?.cancel()
        if mode == .open { syncOverlay() }
        isClickPinned = true
        uiState.isVisible = true
        uiState.mode = mode
        scheduleResize()
    }

    func hideFromCLI() {
        hoverTask?.cancel()
        dwellTask?.cancel()
        hideTask?.cancel()
        isClickPinned = false
        uiState.approvalOutcome = nil
        uiState.mode = .closed
        uiState.isVisible = false
        scheduleResize()
    }

    func toggleOpen() {
        guard shouldPersistVisible || uiState.isVisible else { return }
        hideTask?.cancel()
        uiState.isVisible = true
        if uiState.mode == .open {
            isClickPinned = false
            uiState.isDetailExpanded = false
            setMode(.closed)
        } else {
            isClickPinned = true
            syncOverlay()
            if uiState.reopenTrayOnNextOpen, uiState.trayHasItems, uiState.overlay == nil {
                uiState.activeTab = .tray
            }
            setMode(.open, forceResize: true)
        }
    }

    func keepTrayOpen() {
        dwellTask?.cancel()
        hideTask?.cancel()
        isClickPinned = true
        uiState.isVisible = true
        uiState.activeTab = .tray
        uiState.reopenTrayOnNextOpen = true
        if uiState.mode != .open {
            setMode(.open)
        } else {
            scheduleResize()
        }
    }

    func releaseTrayHold() {
        isClickPinned = false
    }

    func closeExplicitly() {
        isClickPinned = false
        uiState.approvalOutcome = nil
        uiState.isDetailExpanded = false
        setMode(.closed)
    }

    private func collapseForOutsideClickIfNeeded() {
        guard uiState.isVisible,
              uiState.mode == .open,
              uiState.overlay == nil,
              permissions.queue.isEmpty,
              !panel.frame.contains(NSEvent.mouseLocation) else { return }
        closeExplicitly()
    }

    func setDetailExpanded(_ expanded: Bool) {
        guard uiState.mode == .open, uiState.overlay == nil else { return }
        guard uiState.isDetailExpanded != expanded else { return }
        uiState.isDetailExpanded = expanded
        scheduleResize()
        SoundPlayer.shared.play(.navigation)
    }

    func toggleDetailExpansion() {
        setDetailExpanded(!uiState.isDetailExpanded)
    }

    /// Shows a lightweight, transient "notice" surface for background
    /// Notification hook events that don't require a response (e.g. Claude
    /// idle nudges). Auto-dismisses after 2.5s. Never interrupts an
    /// in-progress approval outcome or an open, pinned/overlay session.
    func showNotification(title: String, message: String) {
        guard shouldPersistVisible else { return }
        guard uiState.approvalOutcome == nil else { return }
        if uiState.mode == .open, (uiState.overlay != nil || isClickPinned) { return }
        noticeAutoDismissTask?.cancel()
        uiState.noticeTitle = title
        uiState.noticeMessage = message
        uiState.isVisible = true
        setMode(.notice)
        noticeAutoDismissTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 2_500_000_000)
            guard !Task.isCancelled, let self else { return }
            self.dismissNotice()
        }
    }

    private func dismissNotice() {
        guard uiState.mode == .notice, uiState.approvalOutcome == nil else { return }
        uiState.noticeTitle = nil
        uiState.noticeMessage = nil
        setMode(.closed)
    }

    func showApprovalOutcome(allowed: Bool) {
        isClickPinned = false
        uiState.approvalOutcome = ApprovalOutcome(allowed: allowed)
        setMode(.notice)
    }

    func finishApprovalOutcome(hasPendingApproval: Bool) {
        uiState.approvalOutcome = nil
        if hasPendingApproval {
            setMode(.open)
        } else {
            setMode(.closed)
        }
    }

    func finishQuestionResponse() {
        syncOverlay()
        if permissions.queue.isEmpty, questions.queue.isEmpty, plans.queue.isEmpty {
            isClickPinned = false
            setMode(.closed)
        } else {
            setMode(.open, forceResize: true)
        }
    }

    func finishPlanResponse() {
        syncOverlay()
        if permissions.queue.isEmpty, questions.queue.isEmpty, plans.queue.isEmpty {
            isClickPinned = false
            setMode(.closed)
        } else {
            setMode(.open, forceResize: true)
        }
    }

    private func handleFrontmostChange(bundleId: String?) {
        _ = bundleId
        scheduleVisibilityRefresh()
    }

    private func scheduleVisibilityRefresh() {
        visibilityRefreshTask?.cancel()
        refreshVisibilityForCurrentSpace()
        visibilityRefreshTask = Task { [weak self] in
            // Fullscreen transitions finish after the activation/Space
            // notification. Recheck twice so the panel cannot flash back in.
            for delay in [180_000_000, 520_000_000] as [UInt64] {
                try? await Task.sleep(nanoseconds: delay)
                guard !Task.isCancelled, let self else { return }
                self.refreshVisibilityForCurrentSpace()
            }
        }
    }

    private func refreshVisibilityForCurrentSpace() {
        let wasPersisting = shouldPersistVisible
        shouldPersistVisible = !Self.isNonFinderFullscreen(on: screen)
        // The first-run guide outlives fullscreen suppression: it's the one
        // surface the user hasn't been taught to bring back, so hiding it
        // out from under them would leave the gestures unexplained with no
        // way to ask again short of Settings.
        if uiState.isShowingOnboarding { return }
        if shouldPersistVisible {
            if !wasPersisting, !permissions.queue.isEmpty || !questions.queue.isEmpty || !plans.queue.isEmpty {
                // Surface anything that arrived while fullscreen suppressed the notch.
                showAttention()
            } else {
                showMinimal()
            }
        } else if uiState.trayHasItems {
            // Files parked in the tray are otherwise unreachable once the
            // notch is fully hidden, so a non-empty tray keeps a minimal
            // pill up even under fullscreen suppression (bypassing the
            // normal suppression guard `showMinimal()` respects).
            hideTask?.cancel()
            showMinimal(bypassFullscreenSuppression: true)
        } else {
            hoverTask?.cancel()
            dwellTask?.cancel()
            hoverExpandTask?.cancel()
            hideTask?.cancel()
            isClickPinned = false
            uiState.isDetailExpanded = false
            uiState.mode = .closed
            uiState.isVisible = false
            scheduleResize()
        }
    }

    /// 600ms after becoming `.closed`, fades to hidden unless the pointer
    /// re-entered, the approval queue is non-empty, or Finder-with-Desktop
    /// is frontmost (requirements 3, 4, 5).
    private func scheduleHideIfIdle() {
        hideTask?.cancel()
        hideTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 600_000_000)
            guard !Task.isCancelled else { return }
            guard let self else { return }
            guard !self.uiState.isShowingOnboarding else { return }
            guard !self.isHovering else { return }
            guard self.permissions.queue.isEmpty, self.questions.queue.isEmpty, self.plans.queue.isEmpty else { return }
            guard !self.uiState.trayHasItems else { return }
            guard !self.shouldPersistVisible else { return }
            self.uiState.isVisible = false
        }
    }

    func cancelInteractionTimers() {
        hoverTask?.cancel()
        dwellTask?.cancel()
        hoverExpandTask?.cancel()
        hideTask?.cancel()
    }

    private func handleScroll(_ event: NSEvent) {
        guard uiState.isVisible,
              uiState.overlay == nil,
              event.window === panel || panel.frame.contains(NSEvent.mouseLocation) else { return }

        let deltaX = event.scrollingDeltaX
        let deltaY = event.scrollingDeltaY
        let isHorizontal = abs(deltaX) > abs(deltaY) * 1.15 && abs(deltaX) > 0.25

        // Compact/hover: sideways scrolling steps tracks. Vertical is left
        // alone there — opening and closing stay a click or the dwell
        // gesture, so a stray scroll over the pill can't resize the panel.
        guard uiState.mode == .open else {
            if isHorizontal { handleCompactMediaScroll(event, delta: deltaX) }
            return
        }

        if abs(deltaY) > abs(deltaX) * 1.15, abs(deltaY) > 0.25 {
            handleVerticalScroll(event, delta: deltaY)
        } else if isHorizontal {
            handleHorizontalScroll(event, delta: deltaX)
        }
    }

    /// Track-stepping via sideways scroll over the compact/hover pill. Uses
    /// the same accumulate-then-commit shape as `handleHorizontalScroll`,
    /// and can safely share its accumulator state: that one only ever runs
    /// while `.open`, this one only while not.
    private func handleCompactMediaScroll(_ event: NSEvent, delta deltaX: CGFloat) {
        guard AppSettings.shared.mediaSwipeEnabled, MediaController.shared.hasMedia else { return }

        if event.phase == .began {
            horizontalScrollTotal = 0
            didCommitCurrentScroll = false
        }

        horizontalScrollTotal += deltaX
        let isDiscreteWheel = event.phase.isEmpty && event.momentumPhase.isEmpty
        let now = event.timestamp
        let canCommit = isDiscreteWheel
            ? now - lastDiscreteScrollSwitch > 0.34
            : !didCommitCurrentScroll

        guard canCommit, abs(horizontalScrollTotal) >= 18 else {
            if event.phase == .ended || event.phase == .cancelled {
                horizontalScrollTotal = 0
                didCommitCurrentScroll = false
            }
            return
        }

        didCommitCurrentScroll = true
        lastDiscreteScrollSwitch = now
        if NotchWindowController.swipeAdvancesTrack(
            scrollTotal: horizontalScrollTotal,
            inverted: AppSettings.shared.invertMediaSwipe
        ) {
            MediaController.shared.next()
        } else {
            MediaController.shared.previous()
        }
        SoundPlayer.shared.play(.navigation)
        HapticPlayer.shared.perform(.confirm)

        if isDiscreteWheel {
            horizontalScrollTotal = 0
            didCommitCurrentScroll = false
        }
    }

    /// Whether a swipe should advance to the next track rather than go back.
    /// Swiping left (negative scroll total) advances by default — the
    /// content flicks away in the direction of travel — and `inverted`
    /// swaps that, matching the "invert media gesture" setting.
    static func swipeAdvancesTrack(scrollTotal: CGFloat, inverted: Bool) -> Bool {
        let advances = scrollTotal < 0
        return inverted ? !advances : advances
    }

    /// How far either side of today the week strip can be scrolled. Well
    /// inside `TodayModel.eventFetchRadiusDays`, so a scrolled-to day always
    /// has its events already fetched.
    static let weekStripScrollLimitDays = 21

    private func handleHorizontalScroll(_ event: NSEvent, delta deltaX: CGFloat) {

        if event.phase == .began {
            horizontalScrollTotal = 0
            didCommitCurrentScroll = false
        }

        horizontalScrollTotal += deltaX
        let isDiscreteWheel = event.phase.isEmpty && event.momentumPhase.isEmpty
        let now = event.timestamp
        let canCommit = isDiscreteWheel
            ? now - lastDiscreteScrollSwitch > 0.34
            : !didCommitCurrentScroll

        guard canCommit, abs(horizontalScrollTotal) >= 18 else {
            if event.phase == .ended || event.phase == .cancelled {
                horizontalScrollTotal = 0
                didCommitCurrentScroll = false
            }
            return
        }

        didCommitCurrentScroll = true
        lastDiscreteScrollSwitch = now
        if uiState.isHoveringWeekStrip {
            stepWeekStrip(forward: horizontalScrollTotal < 0)
        } else {
            navigatePage(forward: horizontalScrollTotal < 0)
        }

        if isDiscreteWheel {
            horizontalScrollTotal = 0
            didCommitCurrentScroll = false
        }
    }

    private func handleVerticalScroll(_ event: NSEvent, delta deltaY: CGFloat) {
        // The Agents tab hosts its own vertical `ScrollView` for the session
        // list; treating ordinary list scrolling as a "swipe to expand
        // detail" gesture there was firing accidentally, so it's excluded
        // even though Agents does have a detail panel (NotchView.hasDetailPanel).
        // Dashboard has no competing scroll view, so swipe-to-expand stays
        // enabled there (it merged Media, which had no detail panel at all,
        // with Today/System, which did — the merged tab does have one).
        guard uiState.activeView != .agents else { return }

        if event.phase == .began {
            verticalScrollTotal = 0
            didCommitCurrentVerticalScroll = false
        }

        verticalScrollTotal += deltaY
        let isDiscreteWheel = event.phase.isEmpty && event.momentumPhase.isEmpty
        let threshold: CGFloat = isDiscreteWheel ? 1.5 : 18
        let now = event.timestamp
        let canCommit = isDiscreteWheel
            ? now - lastDiscreteVerticalSwitch > 0.28
            : !didCommitCurrentVerticalScroll

        guard canCommit, abs(verticalScrollTotal) >= threshold else {
            if event.phase == .ended || event.phase == .cancelled {
                verticalScrollTotal = 0
                didCommitCurrentVerticalScroll = false
            }
            return
        }

        didCommitCurrentVerticalScroll = true
        lastDiscreteVerticalSwitch = now
        setDetailExpanded(verticalScrollTotal < 0)

        if isDiscreteWheel {
            verticalScrollTotal = 0
            didCommitCurrentVerticalScroll = false
        }
    }

    /// Steps the week strip one day forward/back, clamped so it can't be
    /// scrolled past the range `TodayModel` has actually fetched events for.
    private func stepWeekStrip(forward: Bool) {
        let limit = Self.weekStripScrollLimitDays
        let next = uiState.weekStripDayOffset + (forward ? 1 : -1)
        let clamped = min(max(next, -limit), limit)
        guard clamped != uiState.weekStripDayOffset else { return }

        let animation: Animation = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
            ? .easeOut(duration: 0.1)
            : DesignTokens.scaledContentTransition()
        withAnimation(animation) {
            uiState.weekStripDayOffset = clamped
        }
        SoundPlayer.shared.play(.navigation)
    }

    private func navigatePage(forward: Bool) {
        let animation: Animation = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
            ? .easeOut(duration: 0.14)
            : DesignTokens.scaledContentTransition()

        withAnimation(animation) {
            if uiState.activeTab == .tray {
                guard !forward else { return }
                uiState.activeTab = .nook
                // Land on the last Nook page (was hardcoded to `.system`,
                // the last case in the old 4-case enum — `.allCases.last`
                // keeps this correct regardless of how `NookView`'s cases
                // are ordered/renamed going forward).
                uiState.activeView = NookView.allCases.last ?? .agents
            } else if let index = NookView.allCases.firstIndex(of: uiState.activeView) {
                let nextIndex = forward ? index + 1 : index - 1
                if NookView.allCases.indices.contains(nextIndex) {
                    uiState.activeView = NookView.allCases[nextIndex]
                } else if forward {
                    uiState.activeTab = .tray
                }
            }
        }
        SoundPlayer.shared.play(.navigation)
    }
}
