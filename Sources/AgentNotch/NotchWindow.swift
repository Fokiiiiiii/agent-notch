import AppKit
import SwiftUI
import Combine

private final class KeyableNotchPanel: NSPanel {
    override var canBecomeKey: Bool { true }
}

private final class FileDropContainerView: NSView {
    var fileDropHandler: (([URL]) -> Void)?
    var fileDragStateHandler: ((Bool) -> Void)?

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
        fileDragStateHandler?(true)
        return .copy
    }

    override func draggingExited(_ sender: NSDraggingInfo?) {
        fileDragStateHandler?(false)
    }

    override func draggingEnded(_ sender: NSDraggingInfo) {
        fileDragStateHandler?(false)
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        let urls = fileURLs(from: sender)
        fileDragStateHandler?(false)
        guard !urls.isEmpty else { return false }
        fileDropHandler?(urls)
        return true
    }

    private func fileURLs(from draggingInfo: NSDraggingInfo) -> [URL] {
        let options: [NSPasteboard.ReadingOptionKey: Any] = [.urlReadingFileURLsOnly: true]
        let values = draggingInfo.draggingPasteboard.readObjects(forClasses: [NSURL.self], options: options) ?? []
        return values.compactMap { ($0 as? NSURL) as URL? }
    }
}

/// The three sizes the notch window/panel can take.
enum IslandMode {
    case closed, notice, open
}

/// Which page is shown inside the "Nook" tab of the open panel.
enum NookView: CaseIterable {
    case agents, media, today, system

    var title: String {
        switch self {
        case .agents: return String(localized: "nook.tab.agents", defaultValue: "Agents")
        case .media: return String(localized: "nook.tab.media", defaultValue: "Media")
        case .today: return String(localized: "nook.tab.today", defaultValue: "Today")
        case .system: return String(localized: "nook.tab.system", defaultValue: "System")
        }
    }
}

/// Which top-level tab is active inside the open panel.
enum NotchTab {
    case nook, tray
}

/// Inline approval, plan, and agent-question surfaces displayed in the Nook.
enum IslandOverlay: Equatable {
    case approval(agent: AgentKind, toolName: String, summary: String, extraCount: Int)
    case plan
    case question
}

struct ApprovalOutcome: Equatable {
    let allowed: Bool
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
    /// The fixed on-screen size of the `.closed`-mode notch shape. Shared
    /// with `NotchWindowController` so the panel's real frame can grow
    /// (invisibly, for file-drag hit-testing) without the visible shape
    /// growing along with it.
    @Published var closedContentSize: CGSize = CGSize(width: 220, height: 34)
    /// Whether the notch is visible at all (fully independent of `mode`,
    /// which only tracks compact/notice/open *sizing* once visible). See
    /// `NotchWindowController`'s visibility state machine.
    @Published var isVisible: Bool = false

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
    private let nativeNotifier: NativeNotifier?
    private let screen: NSScreen
    private var closedSize: CGSize
    /// Narrower than `closedSize`: used only while fullscreen-suppressed, so the
    /// long-hover peek doesn't collide with a fullscreen app's own top-edge
    /// chrome-reveal gesture (which typically spans the full screen width).
    private let fullscreenHoverSize: CGSize
    private var mediaPreviewSize: CGSize
    private let noticeSize = CGSize(width: 320, height: 50)
    private let openSize = CGSize(width: 540, height: 206)
    private let trayOpenSize = CGSize(width: 560, height: 222)
    private let openDetailSize = CGSize(width: 540, height: 264)
    private let openOverlaySize = CGSize(width: 540, height: 246)
    private let openQuestionSize = CGSize(width: 540, height: 316)
    /// Height for the Agents tab with exactly one tracked session (the
    /// selected-row detail lines plus usage bar and footer already exceed
    /// `openSize.height`, which is what caused the footer button to visually
    /// float outside the card). Derived empirically from `AgentsCell`'s
    /// layout (usage bar ~27pt + selected row ~70pt + footer 30pt + padding
    ////spacing) plus the chrome above/below it (nookbar, view tabs).
    private let agentsBaseHeight: CGFloat = 246
    /// Extra height contributed by each additional, unselected session row
    /// (row height + list spacing) once more than one session is tracked.
    private let agentsRowHeight: CGFloat = 36
    /// Sessions beyond this count no longer grow the panel further —
    /// `AgentsCell.sessionList`'s own `ScrollView` takes over instead, so
    /// the notch never grows large enough to run off-screen.
    private let agentsMaxVisibleRows = 4
    /// Absolute ceiling on the Agents tab height, independent of session
    /// count, as a second safety net alongside `agentsMaxVisibleRows`.
    private let agentsMaxHeight: CGFloat = 340
    private var hoverTask: Task<Void, Never>?
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
    private var workspaceObserver: NSObjectProtocol?
    private var spaceObserver: NSObjectProtocol?
    private var scrollMonitor: Any?
    private var outsideClickLocalMonitor: Any?
    private var outsideClickGlobalMonitor: Any?
    private var horizontalScrollTotal: CGFloat = 0
    private var didCommitCurrentScroll = false
    private var lastDiscreteScrollSwitch: TimeInterval = 0
    private var verticalScrollTotal: CGFloat = 0
    private var didCommitCurrentVerticalScroll = false
    private var lastDiscreteVerticalSwitch: TimeInterval = 0
    /// Ids of permission/question/plan requests already surfaced via a
    /// fallback native notification (fullscreen suppression), so the same
    /// event never notifies twice as visibility toggles.
    private var notifiedPermissionIDs: Set<UUID> = []
    private var notifiedQuestionIDs: Set<UUID> = []
    private var notifiedPlanIDs: Set<UUID> = []

    /// Whether the pointer is currently inside the notch. Consulted by
    /// AppDelegate before auto-collapsing after the permission queue drains.
    private(set) var isHovering = false
    var isPinnedOpen: Bool { isClickPinned && uiState.mode == .open }
    var debugMode: String {
        switch uiState.mode { case .closed: return "closed"; case .notice: return "notice"; case .open: return "open" }
    }
    var debugOverlay: String {
        guard let overlay = uiState.overlay else { return "none" }
        switch overlay { case .approval: return "approval"; case .plan: return "plan"; case .question: return "question" }
    }
    var debugVisible: Bool { uiState.isVisible }
    var debugPersists: Bool { shouldPersistVisible }
    let debugScreenInfo: [String: Any]

    /// True if the given screen's backing display is the Mac's built-in
    /// panel (as opposed to an external monitor). Uses the live `CGDirectDisplayID`
    /// rather than any hardcoded model table, so it holds across all Mac models.
    private static func isBuiltInDisplay(_ screen: NSScreen) -> Bool {
        guard let screenNumber = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else {
            return false
        }
        let displayID = CGDirectDisplayID(screenNumber.uint32Value)
        return CGDisplayIsBuiltin(displayID) != 0
    }

    /// Picks the screen to anchor the notch window to. Preference order:
    /// built-in display with a notch, then built-in display (no notch),
    /// then any screen reporting a notch-like safe area, then the system
    /// default, then simply the first available screen.
    private static func selectScreen() -> NSScreen? {
        if let builtinWithNotch = NSScreen.screens.first(where: { isBuiltInDisplay($0) && $0.safeAreaInsets.top > 0 }) {
            return builtinWithNotch
        }
        if let builtin = NSScreen.screens.first(where: { isBuiltInDisplay($0) }) {
            return builtin
        }
        if let anyNotch = NSScreen.screens.first(where: { $0.safeAreaInsets.top > 0 }) {
            return anyNotch
        }
        return NSScreen.main ?? NSScreen.screens.first
    }

    /// Derives the visible `.closed`-mode shape size from the physically
    /// measured notch width/height. Pulled out as a pure function so the
    /// margin/floor logic can be exercised without constructing a window.
    static func computeClosedSize(notchWidth: CGFloat, notchHeight: CGFloat) -> CGSize {
        CGSize(
            width: max(notchWidth + DesignTokens.notchSafeMargin, DesignTokens.compactMinContentWidth, 220),
            height: max(notchHeight, 34)
        )
    }

    init(store: SessionStore, permissions: PermissionCenter, questions: QuestionCenter, plans: PlanCenter, nativeNotifier: NativeNotifier? = nil) {
        self.store = store
        self.permissions = permissions
        self.questions = questions
        self.plans = plans
        self.nativeNotifier = nativeNotifier

        let resolvedScreen = NotchWindowController.selectScreen() ?? NSScreen()
        self.screen = resolvedScreen

        let notchHeight: CGFloat = resolvedScreen.safeAreaInsets.top > 0 ? resolvedScreen.safeAreaInsets.top : 32

        // auxiliaryTop{Left,Right}Area の測定値には稀に負値や画面幅の大半を占める
        // ような異常値が返るケースがあるため、妥当な範囲外ならフォールバックする。
        var notchWidth: CGFloat = 200
        let hasAuxiliaryAreas = resolvedScreen.auxiliaryTopLeftArea != nil && resolvedScreen.auxiliaryTopRightArea != nil
        if let leftArea = resolvedScreen.auxiliaryTopLeftArea, let rightArea = resolvedScreen.auxiliaryTopRightArea {
            let measured = resolvedScreen.frame.width - leftArea.width - rightArea.width
            if measured > 0 && measured <= resolvedScreen.frame.width * 0.5 {
                notchWidth = measured
            }
        }

        // 見た目のノッチサイズ（NotchViewが.closedモード時に固定描画するサイズ）
        let visualClosedSize = NotchWindowController.computeClosedSize(notchWidth: notchWidth, notchHeight: notchHeight)
        self.mediaPreviewSize = CGSize(width: max(notchWidth + 116, 316), height: max(notchHeight, 34))
        let isBuiltIn = NotchWindowController.isBuiltInDisplay(resolvedScreen)
        self.debugScreenInfo = [
            "safeAreaInsetsTop": resolvedScreen.safeAreaInsets.top,
            "hasAuxiliaryAreas": hasAuxiliaryAreas,
            "auxiliaryTopLeftWidth": resolvedScreen.auxiliaryTopLeftArea?.width ?? 0,
            "auxiliaryTopRightWidth": resolvedScreen.auxiliaryTopRightArea?.width ?? 0,
            "screenFrameWidth": resolvedScreen.frame.width,
            "notchWidth": notchWidth,
            "notchHeight": notchHeight,
            "visualClosedWidth": visualClosedSize.width,
            "visualClosedHeight": visualClosedSize.height,
            "isBuiltInDisplay": isBuiltIn,
        ]
        // closedSize は実際のウィンドウフレーム（ファイルドロップの当たり判定を兼ねる）。
        // 見た目より一回り大きくして常時ドロップを受け付けやすくする。控えめな増分に留め、
        // 他アプリのツールバー等をブロックしすぎないようにする（幅+40, 高さ+70）。
        self.closedSize = CGSize(width: visualClosedSize.width + 40, height: visualClosedSize.height + 70)
        self.fullscreenHoverSize = CGSize(width: min(closedSize.width, 140), height: closedSize.height)
        self.uiState.closedContentSize = CGSize(
            width: visualClosedSize.width * AppSettings.shared.uiScale,
            height: visualClosedSize.height * AppSettings.shared.uiScale
        )

        let initialScale = AppSettings.shared.uiScale
        let initialFrame = NotchWindowController.frame(
            for: CGSize(width: closedSize.width * initialScale, height: closedSize.height * initialScale),
            on: resolvedScreen
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

        let notchView = NotchView(store: store, controller: self, permissions: permissions, questions: questions, plans: plans)
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
                self.resizeForCurrentState()
            }
            .store(in: &cancellables)

        uiState.$isMediaPreviewVisible
            .dropFirst()
            .sink { [weak self] _ in
                guard let self, self.uiState.mode == .closed else { return }
                self.resizeForCurrentState()
            }
            .store(in: &cancellables)

        uiState.$activeTab
            .dropFirst()
            .sink { [weak self] _ in
                guard let self, self.uiState.mode == .open else { return }
                self.resizeForCurrentState()
            }
            .store(in: &cancellables)

        // Switching into/out of the Agents Nook page changes which sizing
        // branch `resizeForCurrentState` takes (fixed `openSize` vs. the
        // session-count-driven `agentsOpenSize`).
        uiState.$activeView
            .dropFirst()
            .sink { [weak self] _ in
                guard let self, self.uiState.mode == .open else { return }
                self.resizeForCurrentState()
            }
            .store(in: &cancellables)

        // The Agents tab's height tracks how many sessions are tracked, so
        // sessions appearing/disappearing while the tab is open must resize
        // the panel live (this is what lets the notch "grow" instead of
        // clipping/overlapping content, per the user's request).
        store.$sessions
            .dropFirst()
            .sink { [weak self] _ in
                guard let self,
                      self.uiState.mode == .open,
                      self.uiState.activeTab == .nook,
                      self.uiState.activeView == .agents else { return }
                self.resizeForCurrentState()
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

    private func syncOverlay() {
        uiState.activeTab = .nook
        if let first = permissions.queue.first {
            uiState.overlay = .approval(
                agent: first.agent,
                toolName: first.toolName,
                summary: first.summary,
                extraCount: permissions.queue.count - 1
            )
        } else if !plans.queue.isEmpty {
            uiState.overlay = .plan
        } else if !questions.queue.isEmpty {
            uiState.overlay = .question
        } else {
            uiState.overlay = nil
        }
    }

    deinit {
        visibilityRefreshTask?.cancel()
        noticeAutoDismissTask?.cancel()
        if let workspaceObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(workspaceObserver)
        }
        if let spaceObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(spaceObserver)
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

    /// Applies `AppSettings.uiScale` to a base panel size immediately before
    /// it's turned into a screen frame. Base size constants (`closedSize`,
    /// `openSize`, etc.) stay untouched so they keep documenting the
    /// 1.0-scale defaults.
    private func scaled(_ size: CGSize) -> CGSize {
        let scale = AppSettings.shared.uiScale
        return CGSize(width: size.width * scale, height: size.height * scale)
    }

    private static func frame(for size: CGSize, on screen: NSScreen) -> NSRect {
        let x = screen.frame.midX - size.width / 2
        let y = screen.frame.maxY - size.height
        return NSRect(x: x, y: y, width: size.width, height: size.height)
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
        return unionRect.width >= screenFrame.width - 12 && unionRect.height >= screenFrame.height - 12
    }

    func showWindow() {
        panel.orderFrontRegardless()
    }

    func installFileDropHandlers(
        targeted: @escaping (Bool) -> Void,
        dropped: @escaping ([URL]) -> Void
    ) {
        fileDropView.fileDragStateHandler = { [weak self] active in
            guard let self else { return }
            targeted(active)
            if active {
                self.uiState.isVisible = true
                self.uiState.activeTab = .tray
                self.setMode(.open)
            }
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
        guard uiState.mode != mode || forceResize else { return }
        if mode != .closed {
            uiState.isMediaPreviewVisible = false
        }
        uiState.mode = mode
        resizeForCurrentState()
        if mode == .closed {
            scheduleHideIfIdle()
        } else {
            hideTask?.cancel()
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
        case .notice:
            targetSize = noticeSize
        case .open:
            if uiState.overlay == .question {
                targetSize = openQuestionSize
            } else if uiState.hasOverlay {
                targetSize = openOverlaySize
            } else {
                if uiState.activeTab == .tray {
                    targetSize = trayOpenSize
                } else if uiState.activeView == .agents {
                    targetSize = agentsOpenSize(sessionCount: store.sessions.count, detailExpanded: uiState.isDetailExpanded)
                } else {
                    targetSize = uiState.isDetailExpanded ? openDetailSize : openSize
                }
            }
        }

        let targetFrame = NotchWindowController.frame(for: scaled(targetSize), on: screen)

        NSAnimationContext.runAnimationGroup { context in
            context.duration = uiState.mode == .closed ? 0.25 : 0.40
            context.timingFunction = CAMediaTimingFunction(controlPoints: 0.20, 0.72, 0.24, 1)
            panel.animator().setFrame(targetFrame, display: true)
        }
    }

    /// Height budget for the Agents Nook page. Unlike the other pages
    /// (fixed `openSize`), Agents shows a full vertical list of every
    /// tracked session, so a fixed height either clips content or (as
    /// reported) lets the footer action row visually float outside the
    /// card once the list plus footer exceed it. Growing the panel to fit,
    /// up to `agentsMaxVisibleRows`/`agentsMaxHeight`, is what fixes that;
    /// beyond the cap `AgentsCell.sessionList`'s own `ScrollView` takes
    /// over so the notch never grows large enough to run off-screen.
    private func agentsOpenSize(sessionCount: Int, detailExpanded: Bool) -> CGSize {
        let visibleRows = max(1, min(sessionCount, agentsMaxVisibleRows))
        var height = agentsBaseHeight + agentsRowHeight * CGFloat(visibleRows - 1)
        if detailExpanded {
            height += openDetailSize.height - openSize.height
        }
        return CGSize(width: openSize.width, height: min(height, agentsMaxHeight))
    }

    func hoverChanged(_ inside: Bool) {
        guard isHovering != inside else { return }
        isHovering = inside
        hoverTask?.cancel()
        dwellTask?.cancel()
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
            // Hover reveals the compact notch when hidden, but never changes
            // its mode. Opening is an explicit click so the same pointer
            // action always has the same result.
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
            try? await Task.sleep(nanoseconds: 140_000_000)
            guard !Task.isCancelled, let self, !self.isHovering else { return }
            guard self.permissions.queue.isEmpty, self.questions.queue.isEmpty, self.plans.queue.isEmpty else { return }
            if self.uiState.mode == .closed, self.uiState.trayHasItems { return }
            guard !self.isClickPinned else { return }
            self.setMode(.closed)
        }
    }

    /// Called on dwell-band hover changes (the always-present top-8px hit
    /// region in `NotchView`). Only relevant while hidden: 300ms of
    /// continuous hover reveals the minimal notch.
    func dwellHoverChanged(_ inside: Bool) {
        hoverChanged(inside)
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
        resizeForCurrentState()
    }

    /// Shows the notch immediately and expands it, from any starting state
    /// (including fully hidden). Used by AppDelegate for PermissionRequest
    /// auto-expansion (requirement 6).
    func forceShow() {
        guard shouldPersistVisible else { return }
        syncOverlay()
        dwellTask?.cancel()
        hideTask?.cancel()
        isClickPinned = false
        uiState.isVisible = true
        setMode(.open)
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
        guard shouldPersistVisible else { return }
        uiState.isVisible = true
        if urgent { showAttention() }
    }

    func showFromCLI() {
        // An explicit CLI command is a manual override. Automatic activity,
        // questions and hover still respect fullscreen suppression.
        dwellTask?.cancel()
        hideTask?.cancel()
        syncOverlay()
        isClickPinned = true
        uiState.isVisible = true
        uiState.mode = .open
        resizeForCurrentState()
    }

    func hideFromCLI() {
        hoverTask?.cancel()
        dwellTask?.cancel()
        hideTask?.cancel()
        isClickPinned = false
        uiState.approvalOutcome = nil
        uiState.mode = .closed
        uiState.isVisible = false
        resizeForCurrentState()
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
            resizeForCurrentState()
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
        resizeForCurrentState()
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
        if shouldPersistVisible {
            if !wasPersisting, !permissions.queue.isEmpty || !questions.queue.isEmpty || !plans.queue.isEmpty {
                // Surface anything that arrived while fullscreen suppressed the notch.
                showAttention()
            } else {
                showMinimal()
            }
        } else {
            hoverTask?.cancel()
            dwellTask?.cancel()
            hideTask?.cancel()
            isClickPinned = false
            uiState.isDetailExpanded = false
            uiState.mode = .closed
            uiState.isVisible = false
            resizeForCurrentState()
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
        hideTask?.cancel()
    }

    private func handleScroll(_ event: NSEvent) {
        guard uiState.isVisible,
              uiState.mode == .open,
              uiState.overlay == nil,
              event.window === panel || panel.frame.contains(NSEvent.mouseLocation) else { return }

        let deltaX = event.scrollingDeltaX
        let deltaY = event.scrollingDeltaY
        if abs(deltaY) > abs(deltaX) * 1.15, abs(deltaY) > 0.25 {
            handleVerticalScroll(event, delta: deltaY)
        } else if abs(deltaX) > abs(deltaY) * 1.15, abs(deltaX) > 0.25 {
            handleHorizontalScroll(event, delta: deltaX)
        }
    }

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
        navigatePage(forward: horizontalScrollTotal < 0)

        if isDiscreteWheel {
            horizontalScrollTotal = 0
            didCommitCurrentScroll = false
        }
    }

    private func handleVerticalScroll(_ event: NSEvent, delta deltaY: CGFloat) {
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

    private func navigatePage(forward: Bool) {
        let animation: Animation = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
            ? .easeOut(duration: 0.14)
            : DesignTokens.contentTransition

        withAnimation(animation) {
            if uiState.activeTab == .tray {
                guard !forward else { return }
                uiState.activeTab = .nook
                uiState.activeView = .system
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
