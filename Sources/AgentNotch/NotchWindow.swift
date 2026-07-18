import AppKit
import SwiftUI
import Combine

private final class KeyableNotchPanel: NSPanel {
    override var canBecomeKey: Bool { true }
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
        case .agents: return "Agents"
        case .media: return "Media"
        case .today: return "Today"
        case .system: return "System"
        }
    }
}

/// Which top-level tab is active inside the open panel.
enum NotchTab {
    case nook, tray
}

/// Structural placeholder for the approval/plan/question overlays. Only
/// `.approval` has a real view today, driven by `PermissionCenter.queue`'s
/// head element (see `NotchWindowController`'s subscription below).
enum IslandOverlay: Equatable {
    case approval(toolName: String, summary: String, extraCount: Int)
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
    @Published var selectedSessionId: String? = nil
    /// Whether the notch is visible at all (fully independent of `mode`,
    /// which only tracks compact/notice/open *sizing* once visible). See
    /// `NotchWindowController`'s visibility state machine.
    @Published var isVisible: Bool = false

    var hasOverlay: Bool { overlay != nil }
}

@MainActor
final class NotchWindowController: NSObject {
    private let panel: NSPanel
    private let uiState = NotchUIState()
    private let store: SessionStore
    private let permissions: PermissionCenter
    private let screen: NSScreen
    private var closedSize: CGSize
    private let noticeSize = CGSize(width: 320, height: 50)
    private let openSize = CGSize(width: 484, height: 168)
    private let openOverlaySize = CGSize(width: 484, height: 196)
    private var hoverTask: Task<Void, Never>?
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
    private var shouldPersistVisible = true
    private var isClickPinned = false
    private var workspaceObserver: NSObjectProtocol?
    private var spaceObserver: NSObjectProtocol?
    private var scrollMonitor: Any?
    private var horizontalScrollTotal: CGFloat = 0
    private var didCommitCurrentScroll = false
    private var lastDiscreteScrollSwitch: TimeInterval = 0

    /// Whether the pointer is currently inside the notch. Consulted by
    /// AppDelegate before auto-collapsing after the permission queue drains.
    private(set) var isHovering = false
    var isPinnedOpen: Bool { isClickPinned && uiState.mode == .open }

    init(store: SessionStore, permissions: PermissionCenter) {
        self.store = store
        self.permissions = permissions

        let chosenScreen = NSScreen.screens.first(where: { $0.safeAreaInsets.top > 0 }) ?? NSScreen.main
        let resolvedScreen = chosenScreen ?? NSScreen.screens.first ?? NSScreen()
        self.screen = resolvedScreen

        let notchHeight: CGFloat = resolvedScreen.safeAreaInsets.top > 0 ? resolvedScreen.safeAreaInsets.top : 32

        var notchWidth: CGFloat = 200
        if let leftArea = resolvedScreen.auxiliaryTopLeftArea, let rightArea = resolvedScreen.auxiliaryTopRightArea {
            notchWidth = resolvedScreen.frame.width - leftArea.width - rightArea.width
        }

        self.closedSize = CGSize(width: max(notchWidth + 20, 220), height: max(notchHeight, 34))

        let initialFrame = NotchWindowController.frame(
            for: closedSize,
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
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        panel.isMovable = false
        panel.hidesOnDeactivate = false
        panel.setFrame(initialFrame, display: false)

        self.panel = panel

        super.init()

        let notchView = NotchView(store: store, controller: self, permissions: permissions)
            .environmentObject(uiState)
        let hostingView = NSHostingView(rootView: notchView)
        panel.contentView = hostingView

        // Overlay presence changes the target height while already `.open`
        // (e.g. an approval overlay appearing/disappearing).
        uiState.$overlay
            .dropFirst()
            .sink { [weak self] _ in
                guard let self, self.uiState.mode == .open else { return }
                self.resizeForCurrentState()
            }
            .store(in: &cancellables)

        // Drives `uiState.overlay` from the live PermissionCenter queue: the
        // head request becomes the `.approval` overlay, with the remaining
        // count surfaced as `extraCount`. AppDelegate handles opening the
        // panel and the post-drain auto-collapse; this just keeps the
        // overlay content in sync with the queue.
        permissions.$queue
            .sink { [weak self] queue in
                guard let self else { return }
                if let first = queue.first {
                    self.uiState.activeTab = .nook
                    self.uiState.overlay = .approval(
                        toolName: first.toolName,
                        summary: first.summary,
                        extraCount: queue.count - 1
                    )
                } else {
                    self.uiState.overlay = nil
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
                self?.refreshVisibilityForCurrentSpace()
            }
        }

        scrollMonitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
            self?.handleHorizontalScroll(event)
            return event
        }
    }

    deinit {
        if let workspaceObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(workspaceObserver)
        }
        if let spaceObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(spaceObserver)
        }
        if let scrollMonitor {
            NSEvent.removeMonitor(scrollMonitor)
        }
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
        return windows.contains { info in
            guard (info[kCGWindowOwnerPID as String] as? pid_t) == app.processIdentifier,
                  (info[kCGWindowLayer as String] as? Int) == 0,
                  let boundsDictionary = info[kCGWindowBounds as String] as? NSDictionary,
                  let bounds = CGRect(dictionaryRepresentation: boundsDictionary as CFDictionary) else { return false }
            return bounds.width >= screenFrame.width - 2 && bounds.height >= screenFrame.height - 2
        }
    }

    func showWindow() {
        panel.orderFrontRegardless()
    }

    /// Replaces the old `setExpanded(_:)`. Animates the panel frame to the
    /// size for `mode` (and, for `.open`, to the taller overlay size when
    /// `uiState.hasOverlay` is true).
    func setMode(_ mode: IslandMode) {
        guard uiState.mode != mode else { return }
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
            targetSize = closedSize
        case .notice:
            targetSize = noticeSize
        case .open:
            targetSize = uiState.hasOverlay ? openOverlaySize : openSize
        }

        let targetFrame = NotchWindowController.frame(for: targetSize, on: screen)

        NSAnimationContext.runAnimationGroup { context in
            context.duration = uiState.mode == .closed ? 0.20 : 0.32
            context.timingFunction = CAMediaTimingFunction(controlPoints: 0.20, 0.72, 0.24, 1)
            panel.animator().setFrame(targetFrame, display: true)
        }
    }

    func hoverChanged(_ inside: Bool) {
        guard isHovering != inside else { return }
        isHovering = inside
        hoverTask?.cancel()
        dwellTask?.cancel()
        if inside {
            hideTask?.cancel()
            if !uiState.isVisible {
                dwellTask = Task { [weak self] in
                    try? await Task.sleep(nanoseconds: 300_000_000)
                    guard !Task.isCancelled, self?.isHovering == true else { return }
                    self?.showMinimal()
                }
                return
            }
            // Hover reveals the compact notch when hidden, but never changes
            // its mode. Opening is an explicit click so the same pointer
            // action always has the same result.
            return
        }
        guard permissions.queue.isEmpty else { return }
        guard !isClickPinned else { return }
        hoverTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 140_000_000)
            guard !Task.isCancelled, let self, !self.isHovering else { return }
            guard self.permissions.queue.isEmpty else { return }
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
    private func showMinimal() {
        hideTask?.cancel()
        uiState.isVisible = true
    }

    /// Shows the notch immediately and expands it, from any starting state
    /// (including fully hidden). Used by AppDelegate for PermissionRequest
    /// auto-expansion (requirement 6).
    func forceShow() {
        dwellTask?.cancel()
        hideTask?.cancel()
        isClickPinned = false
        uiState.isVisible = true
        setMode(.open)
    }

    func toggleOpen() {
        hideTask?.cancel()
        uiState.isVisible = true
        if uiState.mode == .open {
            isClickPinned = false
            setMode(.closed)
        } else {
            isClickPinned = true
            setMode(.open)
        }
    }

    func closeExplicitly() {
        isClickPinned = false
        uiState.approvalOutcome = nil
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

    private func handleFrontmostChange(bundleId: String?) {
        _ = bundleId
        // Give AppKit a moment to finish moving the new key window to its
        // Space before measuring its bounds.
        Task { [weak self] in
            try? await Task.sleep(nanoseconds: 80_000_000)
            guard !Task.isCancelled else { return }
            self?.refreshVisibilityForCurrentSpace()
        }
    }

    private func refreshVisibilityForCurrentSpace() {
        shouldPersistVisible = !Self.isNonFinderFullscreen(on: screen)
        if shouldPersistVisible {
            showMinimal()
        } else if permissions.queue.isEmpty, !isHovering {
            isClickPinned = false
            setMode(.closed)
            scheduleHideIfIdle()
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
            guard self.permissions.queue.isEmpty else { return }
            guard !self.shouldPersistVisible else { return }
            self.uiState.isVisible = false
        }
    }

    func cancelInteractionTimers() {
        hoverTask?.cancel()
        dwellTask?.cancel()
        hideTask?.cancel()
    }

    private func handleHorizontalScroll(_ event: NSEvent) {
        guard uiState.isVisible,
              uiState.mode == .open,
              uiState.overlay == nil,
              event.window === panel || panel.frame.contains(NSEvent.mouseLocation) else { return }

        let deltaX = event.scrollingDeltaX
        let deltaY = event.scrollingDeltaY
        guard abs(deltaX) > abs(deltaY) * 1.15, abs(deltaX) > 0.25 else { return }

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
