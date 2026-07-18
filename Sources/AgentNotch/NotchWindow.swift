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

@MainActor
final class NotchUIState: ObservableObject {
    @Published var mode: IslandMode = .closed
    @Published var activeTab: NotchTab = .nook
    @Published var activeView: NookView = .agents
    @Published var overlay: IslandOverlay? = nil
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
    private let noticeSize = CGSize(width: 400, height: 64)
    private let openSize = CGSize(width: 520, height: 180)
    private let openOverlaySize = CGSize(width: 520, height: 220)
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
    private var workspaceObserver: NSObjectProtocol?
    private var spaceObserver: NSObjectProtocol?

    /// Whether the pointer is currently inside the notch. Consulted by
    /// AppDelegate before auto-collapsing after the permission queue drains.
    private(set) var isHovering = false

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

        self.closedSize = CGSize(width: max(notchWidth + 24, 240), height: max(notchHeight, 36))

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
    }

    deinit {
        if let workspaceObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(workspaceObserver)
        }
        if let spaceObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(spaceObserver)
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
            context.duration = uiState.mode == .closed ? 0.16 : 0.24
            context.timingFunction = CAMediaTimingFunction(controlPoints: 0.22, 0.78, 0.28, 1)
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
            guard uiState.mode == .closed else { return }
            hoverTask = Task { [weak self] in
                try? await Task.sleep(nanoseconds: 200_000_000)
                guard !Task.isCancelled, self?.isHovering == true else { return }
                self?.setMode(.open)
            }
            return
        }
        guard permissions.queue.isEmpty else { return }
        hoverTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 140_000_000)
            guard !Task.isCancelled, let self, !self.isHovering else { return }
            guard self.permissions.queue.isEmpty else { return }
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
        uiState.isVisible = true
        setMode(.open)
    }

    func toggleOpen() {
        hideTask?.cancel()
        uiState.isVisible = true
        setMode(uiState.mode == .open ? .closed : .open)
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
}
