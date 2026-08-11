import SwiftUI
import UniformTypeIdentifiers
import AgentNotchCore

struct NotchView: View {
    @ObservedObject var store: SessionStore
    let controller: NotchWindowController
    @ObservedObject var permissions: PermissionCenter
    @ObservedObject var questions: QuestionCenter
    @ObservedObject var plans: PlanCenter
    @ObservedObject var attention: AttentionCenter
    @EnvironmentObject var uiState: NotchUIState
    @StateObject private var media = MediaController.shared
    @StateObject private var usageStore = AgentUsageStore.shared
    @StateObject private var todayModel = TodayModel.shared
    @ObservedObject private var settings = AppSettings.shared
    @StateObject private var systemMonitor = SystemMonitor.shared
    @StateObject private var backgroundActivity = BackgroundActivityMonitor.shared
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var trayItems: [TrayItem] = []
    @State private var selectedTrayItemID: UUID?
    @State private var isDropTargeted = false
    /// Where the Tray page's AirDrop well currently is, in the same top-left
    /// coordinate space `FileDropContainerView` reports drops in. Zero while
    /// the Tray page isn't on screen, so drops can never route to the well
    /// when it isn't visible.
    @State private var airDropWellFrame: CGRect = .zero
    @State private var isAirDropTargeted = false
    @State private var trayFeedback: String?
    @State private var pendingTrayUndo: [TrayItem] = []
    @State private var trayUndoTask: Task<Void, Never>?
    @State private var compactMediaHoverTask: Task<Void, Never>?
    @GestureState private var horizontalDrag: CGFloat = 0
    @GestureState private var verticalDrag: CGFloat = 0

    var body: some View {
        ZStack(alignment: .top) {
            Color.clear
            ZStack {
                shapeBackground
                content
            }
            .frame(
                width: uiState.mode == .closed ? uiState.closedContentSize.width : (uiState.mode == .hover ? uiState.hoverContentSize.width : nil),
                height: uiState.mode == .closed ? uiState.closedContentSize.height : (uiState.mode == .hover ? uiState.hoverContentSize.height : nil)
            )
            // The panel's real NSWindow frame is animated separately (AppKit,
            // NSAnimationContext in NotchWindowController) on its own timing
            // curve. If this SwiftUI frame animates too — even implicitly via
            // the .animation() below — the two fall out of sync mid-transition
            // and content can appear clipped against a window that has
            // already reached its final (smaller) size. Snap it instantly.
            .transaction { transaction in
                transaction.animation = nil
            }
            .clipShape(shellShape)
            .compositingGroup()
            .opacity(uiState.isVisible ? 1 : 0)
            .allowsHitTesting(uiState.isVisible)
            .animation(reduceMotion ? .easeOut(duration: 0.12) : DesignTokens.scaledSpring(), value: uiState.mode)
        }
        .contentShape(Rectangle())
        .onHover {
            controller.hoverChanged($0)
            updateCompactMediaHover($0)
        }
        .onChange(of: uiState.mode) { _, mode in
            if mode != .closed { hideCompactMediaPreview() }
            // Belt and braces on top of the mirror widget's own
            // `onDisappear` — see `stopAllViewers()`.
            if mode != .open { CameraPreviewController.shared.stopAllViewers() }
        }
        .onAppear {
            controller.installFileDropHandlers(
                targeted: { active, location in
                    let overWell = active && isOverAirDropWell(location)
                    // Mutually exclusive so only one of the two wells lights
                    // up as the pointer moves between them.
                    isAirDropTargeted = overWell
                    isDropTargeted = active && !overWell
                },
                dropped: { urls, location in
                    if isOverAirDropWell(location) {
                        sendViaAirDrop(urls)
                    } else {
                        addTrayItems(urls)
                    }
                }
            )
        }
        .onDisappear {
            compactMediaHoverTask?.cancel()
            trayUndoTask?.cancel()
            isDropTargeted = false
            isAirDropTargeted = false
            controller.removeFileDropHandlers()
            controller.cancelInteractionTimers()
        }
        .animation(.easeOut(duration: 0.24), value: uiState.isVisible)
        .environment(\.colorScheme, .dark)
    }

    /// `true` on a real (or simulated) physical notch. `hoverTopClearance` is
    /// `0` exactly when `computeHoverTopClearance`'s `hasNotch` guard is
    /// false, and positive exactly when it's true — so this is an equivalent
    /// read of the same signal without adding a second `@Published` property.
    private var hasRealNotch: Bool { uiState.hoverTopClearance > 0 }

    private var shellShape: NotchShellShape {
        let radius: CGFloat
        if uiState.mode == .open {
            radius = DesignTokens.scaledOpenRadius()
        } else if hasRealNotch {
            // .closed/.hover/.notice on a real notch: hug the physical
            // camera-housing's own corner curvature instead of the generic
            // (wider) closed radius, so the shell reads as a continuation of
            // the cutout rather than an unrelated floating pill.
            radius = DesignTokens.scaledNotchHuggingRadius()
        } else {
            radius = DesignTokens.scaledClosedRadius()
        }
        // Only `.open` gets the concave flare where the panel meets the menu
        // bar. `.closed`/`.hover`/`.notice` are the compact pill fused to the
        // bar itself — square top corners already read correctly there, and
        // an ordinary *convex* top radius was tried and rejected for looking
        // like an inward seam.
        return NotchShellShape(
            bottomRadius: radius,
            topFlareRadius: uiState.mode == .open ? DesignTokens.scaledNotchFlareRadius() : 0
        )
    }

    private var shapeBackground: some View {
        // `.hover` alone gets a faint edge + drop shadow — `.closed`/`.notice`
        // stay a flat fill (unchanged look) since they're meant to read as
        // part of the notch itself, not a floating card. `.open`'s own cells
        // already carry their own depth treatment, so this only ever applies
        // while `uiState.mode == .hover`. While media is playing, the edge
        // and shadow borrow the track's own accent color (same source
        // `mediaRow`'s waveform already uses) instead of staying plain
        // white/black — a small, low-risk echo of the album-art-driven glow
        // macOS's own Now Playing surfaces use.
        let isHover = uiState.mode == .hover
        let edgeColor: Color = (isHover && media.isPlaying) ? Color(nsColor: media.accentColor) : .white
        let edgeOpacity: Double = isHover ? (media.isPlaying ? 0.22 : 0.09) : 0
        return shellShape
            .fill(Color.black)
            .overlay(shellShape.strokeBorder(edgeColor.opacity(edgeOpacity), lineWidth: 0.75))
            .shadow(
                color: (isHover && media.isPlaying ? edgeColor : .black).opacity(isHover ? DesignTokens.cardShadowOpacity : 0),
                radius: isHover ? DesignTokens.cardShadowRadius : 0,
                y: isHover ? DesignTokens.cardShadowY : 0
            )
    }

    @ViewBuilder
    private var content: some View {
        switch uiState.mode {
        case .closed:
            compactContent
                .transition(.opacity)
        case .hover:
            hoverContent
                .transition(.opacity)
        case .notice:
            noticeContent
                .transition(.opacity)
        case .open:
            openContent
                .transition(.opacity)
        }
    }

    // MARK: - Compact (closed)

    private var selectedSession: AgentSession? {
        if let id = uiState.selectedSessionId, let match = store.sessions.first(where: { $0.id == id }) {
            return match
        }
        return store.sessions.first
    }

    private var compactContent: some View {
        Button {
            hideCompactMediaPreview()
            if shouldShowCompactMedia {
                uiState.activeTab = .nook
                uiState.activeView = .dashboard
            }
            controller.toggleOpen()
        } label: {
            Group {
                if shouldShowCompactMedia {
                    compactMediaContent
                } else {
                    compactAgentContent
                }
            }
            .padding(.horizontal, 12)
            .contentShape(Rectangle())
            .transition(.opacity)
        }
        .buttonStyle(NotchPressStyle(pressedScale: 0.985))
        .accessibilityLabel(String(localized: "notch.openAgentNotch", defaultValue: "Open AgentNotch"))
        .help(shouldShowCompactMedia ? String(localized: "notch.openMedia", defaultValue: "Open Media") : String(localized: "notch.openAgentNotch", defaultValue: "Open AgentNotch"))
        .animation(.easeOut(duration: reduceMotion ? 0.12 : 0.24), value: shouldShowCompactMedia)
    }

    // MARK: - Hover (intermediate peek)

    /// `.hover` is a lightweight, read-only peek shown after a further dwell
    /// over the already-visible `.closed` notch (see
    /// `NotchWindowController.hoverChanged(_:)`). It surfaces the same
    /// information a glance at Compact + a long hover on the media preview
    /// would give — playing media and the selected session's project/task/
    /// status/elapsed time — without taking over the full Expanded panel.
    /// A click still opens Expanded via the same `toggleOpen()` path as
    /// Compact.
    /// `.topLeading` only when a real notch reserves top clearance (rows
    /// must sit below the physical camera housing, not centered through
    /// it); otherwise `.leading` (vertical-center), matching the
    /// non-notched layout exactly as it was before notch-awareness existed.
    private var hoverPeekAlignment: Alignment {
        hasRealNotch ? .topLeading : .leading
    }

    private var hoverContent: some View {
        Button {
            controller.toggleOpen()
        } label: {
            HoverPeekView(session: selectedSession, media: media, topClearance: uiState.hoverTopClearance)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: hoverPeekAlignment)
                .contentShape(Rectangle())
        }
        .buttonStyle(NotchPressStyle(pressedScale: 0.99))
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: hoverPeekAlignment)
        .accessibilityLabel(String(localized: "notch.openAgentNotch", defaultValue: "Open AgentNotch"))
        .help(String(localized: "notch.openAgentNotch", defaultValue: "Open AgentNotch"))
    }

    private var shouldShowCompactMedia: Bool {
        media.isPlaying
            && permissions.queue.isEmpty
            && questions.queue.isEmpty
            && plans.queue.isEmpty
            && selectedSession?.state != .waitingApproval
    }

    private var compactMediaContent: some View {
        HStack(spacing: 8) {
            Group {
                if let artwork = media.artwork {
                    Image(nsImage: artwork)
                        .resizable()
                        .scaledToFill()
                } else {
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(Color.white.opacity(0.1))
                        .overlay(Image(systemName: "music.note").font(.system(size: 9, weight: .medium)))
                }
            }
            .frame(width: 22, height: 22)
            .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
            if uiState.isMediaPreviewVisible {
                VStack(alignment: .leading, spacing: 0) {
                    MarqueeText(text: media.title, size: 9.5, weight: .semibold, speed: 18)
                        .frame(height: 12)
                    Text(media.artist)
                        .font(.system(size: 7.5, weight: .medium))
                        .foregroundColor(DesignTokens.muted)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .help("\(media.title) — \(media.artist)")
                .transition(.opacity.combined(with: .offset(x: reduceMotion ? 0 : -3)))
            } else {
                Spacer(minLength: 0)
            }
            // The skip icon extends the pill alongside the waveform (both
            // visible) rather than replacing it, and only on a real (or
            // simulated) notch; on a non-notched Mac this must stay exactly
            // the plain waveform it always was.
            HStack(spacing: 4) {
                if let direction = media.activeSkipDirection, hasRealNotch {
                    Image(systemName: direction == .forward ? "forward.fill" : "backward.fill")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundColor(Color(nsColor: media.accentColor))
                        .frame(width: 14, height: 14)
                        .transition(.opacity.combined(with: .scale(scale: reduceMotion ? 1 : 0.7)))
                }
                CompactMediaWaveform(isPlaying: media.isPlaying, color: Color(nsColor: media.accentColor))
            }
            .animation(.easeOut(duration: reduceMotion ? 0.12 : 0.2), value: media.activeSkipDirection)
        }
    }

    private func updateCompactMediaHover(_ inside: Bool) {
        compactMediaHoverTask?.cancel()
        guard inside, uiState.mode == .closed, shouldShowCompactMedia else {
            hideCompactMediaPreview()
            return
        }
        compactMediaHoverTask = Task {
            try? await Task.sleep(nanoseconds: 250_000_000)
            guard !Task.isCancelled, uiState.mode == .closed, shouldShowCompactMedia else { return }
            withAnimation(.easeOut(duration: reduceMotion ? 0.12 : 0.22)) {
                uiState.isMediaPreviewVisible = true
            }
        }
    }

    private func hideCompactMediaPreview() {
        compactMediaHoverTask?.cancel()
        guard uiState.isMediaPreviewVisible else { return }
        withAnimation(.easeOut(duration: reduceMotion ? 0.1 : 0.18)) {
            uiState.isMediaPreviewVisible = false
        }
    }

    /// Shows only an unaddressed *count* from the unified attention list,
    /// not per-type text — the three call sites this replaced each had
    /// their own distinct title/subtitle ("Approval required" / "Plan ready
    /// for review" / "Agent has a question"), which duplicated the same
    /// priority logic `syncOverlay()` also hand-rolled. Only the icon still
    /// hints at the top item's type; `overlayCell(_:)` in Expanded mode is
    /// unaffected and still shows full per-type detail.
    private var compactAgentContent: some View {
        HStack(spacing: 9) {
            if let top = attention.items.first {
                Image(systemName: attentionGlyph(for: top.urgency))
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(attentionColor(for: top.urgency))
                    .frame(width: 22, height: 22)
                Text(String(localized: "compact.attentionPending", defaultValue: "\(attention.items.count) pending"))
                    .font(.system(size: 10.5, weight: .semibold))
                    .foregroundColor(.white)
                Spacer(minLength: 4)
                Text(String(localized: "compact.clickToReview", defaultValue: "Click to review"))
                    .font(.system(size: 8))
                    .foregroundColor(DesignTokens.muted)
            } else {
                GlyphBox(agent: selectedSession?.agent)
                    .layoutPriority(1)
                    .fixedSize()
                if let session = selectedSession {
                Text(session.title)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(.white)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .layoutPriority(0)
                Spacer(minLength: 4)
                HStack(spacing: 7) {
                    Circle()
                        .fill(statusColor(session.state))
                        .frame(width: 6, height: 6)
                    Text(session.agent.displayName)
                        .font(.system(size: 9))
                        .foregroundColor(DesignTokens.muted)
                        .lineLimit(1)
                }
                .layoutPriority(1)
                } else {
                    Text(String(localized: "compact.appName", defaultValue: "AgentNotch"))
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundColor(.white)
                        .layoutPriority(0)
                    Spacer(minLength: 4)
                    Text(String(localized: "compact.idle", defaultValue: "No active session"))
                        .font(.system(size: 9))
                        .foregroundColor(DesignTokens.muted)
                        .layoutPriority(1)
                }
            }
            if uiState.trayItemCount > 0, attention.items.isEmpty {
                compactTrayBadge
            }
        }
    }

    /// Same SF Symbol each type's compact/expanded card already used before
    /// unification — only the container (`compactAgentContent`) changed.
    /// Matches the icon each type's own Expanded card actually uses
    /// (`ApprovalOverlayView`'s header at `exclamationmark.triangle.fill`,
    /// `PlanReviewView`'s `list.bullet.clipboard`) rather than the
    /// pre-existing Compact-only icons, which had drifted from them (most
    /// visibly permission: a shield vs. the triangle Expanded shows for the
    /// exact same "requests permission" concept).
    private func attentionGlyph(for urgency: AttentionUrgency) -> String {
        switch urgency {
        case .permission: return "exclamationmark.triangle.fill"
        case .plan: return "list.bullet.clipboard.fill"
        case .question: return "questionmark.bubble.fill"
        }
    }

    private func attentionColor(for urgency: AttentionUrgency) -> Color {
        switch urgency {
        case .permission: return DesignTokens.orange
        case .plan: return DesignTokens.purple
        case .question: return DesignTokens.cyan
        }
    }

    private var compactTrayBadge: some View {
        HStack(spacing: 3) {
            Image(systemName: "tray.full.fill")
            Text("\(uiState.trayItemCount)")
        }
        .font(.system(size: 8.5, weight: .semibold, design: .rounded))
        .foregroundColor(.white.opacity(0.72))
        .padding(.horizontal, 6)
        .frame(height: 20)
        .background(Capsule().fill(Color.white.opacity(0.08)))
        .accessibilityLabel(String(localized: "tray.badgeAccessibilityLabel", defaultValue: "Tray, \(String(uiState.trayItemCount)) items"))
    }

    // MARK: - Compact outcome notice

    private var noticeContent: some View {
        HStack(spacing: 9) {
            if let outcome = uiState.approvalOutcome {
                Image(systemName: outcome.allowed ? "checkmark.circle.fill" : "xmark.circle.fill")
                    .font(.system(size: 16, weight: .medium))
                    .foregroundColor(outcome.allowed ? DesignTokens.green : DesignTokens.red)
                    .symbolEffect(.bounce, value: outcome)
                VStack(alignment: .leading, spacing: 1) {
                    Text(outcome.allowed ? String(localized: "notice.allowedOnce", defaultValue: "Allowed once") : String(localized: "notice.denied", defaultValue: "Denied"))
                        .font(.system(size: 10.5, weight: .semibold))
                        .foregroundColor(.white)
                    Text(outcome.allowed ? String(localized: "notice.claudeContinuing", defaultValue: "Claude is continuing") : String(localized: "notice.returnedToClaude", defaultValue: "Returned to Claude"))
                        .font(.system(size: 7.5))
                        .foregroundColor(DesignTokens.muted)
                }
            } else if let message = uiState.noticeMessage {
                GlyphBox(agent: nil)
                VStack(alignment: .leading, spacing: 1) {
                    Text(uiState.noticeTitle ?? String(localized: "notice.notification", defaultValue: "Notification"))
                        .font(.system(size: 10.5, weight: .semibold))
                        .foregroundColor(.white)
                    Text(message)
                        .font(.system(size: 7.5))
                        .foregroundColor(DesignTokens.muted)
                        .lineLimit(1)
                }
            } else {
                GlyphBox(agent: nil)
                Text(String(localized: "notice.notification", defaultValue: "Notification"))
                    .font(.system(size: 10.5, weight: .semibold))
                    .foregroundColor(.white)
            }
            Spacer()
        }
        .padding(.horizontal, 13)
        .frame(maxHeight: .infinity)
        .transition(.opacity.combined(with: .scale(scale: reduceMotion ? 1 : 0.98, anchor: .top)))
    }

    // MARK: - Open (expanded)

    private var openContent: some View {
        VStack(spacing: 7) {
            nookbar
            Group {
                if uiState.isShowingOnboarding {
                    // Takes precedence over tabs and overlays alike: this is
                    // shown before the user knows the notch does anything,
                    // so nothing else should be competing for the space.
                    OnboardingContent { controller.dismissOnboarding() }
                } else {
                    switch uiState.activeTab {
                    case .nook:
                        nookContentView
                    case .tray:
                        trayContent
                    }
                }
            }
            .transition(.asymmetric(
                insertion: .opacity.combined(with: .offset(y: reduceMotion ? 0 : 3)),
                removal: .opacity.combined(with: .offset(y: reduceMotion ? 0 : -2))
            ))
            .animation(reduceMotion ? .easeOut(duration: 0.14) : DesignTokens.scaledContentTransition(), value: contentIdentity)
            .frame(maxHeight: .infinity)
            .offset(x: reduceMotion ? 0 : horizontalDrag / 7)
            .offset(y: reduceMotion ? 0 : rubberBand(verticalDrag, limit: 36) / 8)
            .opacity(reduceMotion ? 1 : 1 - min(abs(horizontalDrag) / 900, 0.08))
        }
        // Breathing room between the panel edge and everything inside it.
        // Applies to every page (Nook's Agents/Dashboard and Tray alike)
        // because they all render inside this container — content used to
        // sit close enough to the rounded edge to look cramped against it.
        .padding(.horizontal, 16)
        .padding(.top, 9)
        .padding(.bottom, 13)
        .contentShape(Rectangle())
        .simultaneousGesture(horizontalSwipeGesture)
        .simultaneousGesture(verticalDetailGesture)
        .focusable()
        .focusEffectDisabled()
        .onMoveCommand { direction in
            if direction == .left { navigateBackward() }
            if direction == .right { navigateForward() }
        }
        .onExitCommand { controller.closeExplicitly() }
    }

    private var contentIdentity: String {
        if let overlay = uiState.overlay { return "overlay-\(String(describing: overlay))" }
        return uiState.activeTab == .tray ? "tray" : "nook-\(uiState.activeView.title)"
    }

    private var nookbar: some View {
        HStack(spacing: 6) {
            HStack(spacing: 4) {
                tabButton(title: String(localized: "notch.tab.nook", defaultValue: "Nook"), icon: "sparkles", count: 0, isActive: uiState.activeTab == .nook) {
                    selectTab(.nook)
                }
                tabButton(title: String(localized: "notch.tab.tray", defaultValue: "Tray"), icon: "tray.full", count: uiState.trayItemCount, isActive: uiState.activeTab == .tray) {
                    selectTab(.tray)
                }
            }
            Button {
                controller.closeExplicitly()
            } label: {
                Color.clear
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .frame(maxWidth: .infinity, minHeight: 24)
            .help(String(localized: "notch.clickBarToClose", defaultValue: "Click the notch bar to close"))
            AirPodsBatteryIndicator()
            CompactBatteryIndicator(monitor: systemMonitor)
            // Opens our own window rather than the SwiftUI `Settings` scene
            // — see `SettingsWindowController` for why that scene never
            // appeared in this `.accessory` app.
            Button {
                SettingsWindowController.shared.show()
            } label: {
                Image(systemName: "gearshape")
                    .font(.system(size: 13))
                    .foregroundColor(.white.opacity(0.62))
                    .frame(width: 28, height: 28)
            }
            .buttonStyle(NotchPressStyle())
            .hoverLift(cornerRadius: 8)
            .accessibilityIdentifier("notch.settings")
            .help(String(localized: "notch.settingsHelp", defaultValue: "Settings"))
            Button { controller.closeExplicitly() } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 13))
                    .foregroundColor(.white.opacity(0.62))
                    .frame(width: 28, height: 28)
            }
            .buttonStyle(NotchPressStyle())
            .hoverLift(cornerRadius: 8)
            .accessibilityIdentifier("notch.close")
            .help(String(localized: "notch.closeEscHelp", defaultValue: "Close  Esc"))
        }
        .frame(height: 30)
    }

    private func tabButton(title: String, icon: String, count: Int, isActive: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 5) {
                // The panel's width is now content-driven and can get narrow
                // (see `dashboardWidth(for:maximum:)`); without this the tab
                // label wraps to two lines rather than the bar simply being
                // tight.
                Label(title, systemImage: icon)
                    .lineLimit(1)
                    .fixedSize()
                if count > 0 {
                    Text("\(count)")
                        .font(.system(size: 9, weight: .bold, design: .rounded))
                        .padding(.horizontal, 5)
                        .frame(minHeight: 17)
                        .background(Capsule().fill(Color.white.opacity(isActive ? 0.18 : 0.10)))
                }
            }
                .font(.system(size: 11, weight: .semibold))
                .foregroundColor(isActive ? .white : .white.opacity(0.72))
                .padding(.horizontal, 10)
                .frame(height: 28)
                .background(
                    Capsule().fill(isActive ? Color.white.opacity(0.13) : Color.clear)
                )
        }
        .buttonStyle(NotchPressStyle())
        .hoverLift(cornerRadius: 14)
        .accessibilityIdentifier("notch.tab.\(title.lowercased())")
        .help(isActive ? String(localized: "notch.currentTab", defaultValue: "Current tab") : String(localized: "notch.showTab", defaultValue: "Show \(title)"))
    }

    private var nookContentView: some View {
        VStack(spacing: 4) {
            Group {
                if let overlay = uiState.overlay {
                    overlayCell(overlay)
                } else {
                    switch uiState.activeView {
                    case .agents:
                        AgentsCell(store: store, uiState: uiState)
                    case .dashboard:
                        DashboardCell(media: media, today: todayModel, uiState: uiState, settings: settings)
                    }
                }
            }
            .frame(maxHeight: .infinity)
            if uiState.overlay == nil, uiState.isDetailExpanded, hasDetailPanel(for: uiState.activeView) {
                expandedDetail
                    .transition(.opacity.combined(with: .offset(y: reduceMotion ? 0 : -3)))
            }
            if uiState.overlay == nil {
                viewTabs
            }
        }
    }

    @ViewBuilder
    private func overlayCell(_ overlay: IslandOverlay) -> some View {
        switch overlay {
        case .approval(let agent, let toolName, let summary, let extraCount, let otherAgentPending, let cwd, let isDangerous):
            if toolName == "ExitPlanMode" {
                PlanApprovalOverlayView(
                    agent: agent,
                    onAllowOnce: {
                        if let id = permissions.queue.first?.id {
                            permissions.resolve(id, behavior: "allow")
                        }
                    },
                    onDeny: {
                        if let id = permissions.queue.first?.id {
                            permissions.resolve(id, behavior: "deny")
                        }
                    },
                    onCompactOutcome: { allowed in
                        controller.showApprovalOutcome(allowed: allowed)
                    },
                    onFinishOutcome: {
                        controller.finishApprovalOutcome(hasPendingApproval: !permissions.queue.isEmpty)
                    }
                )
            } else {
                ApprovalOverlayView(
                    uiState: uiState,
                    agent: agent,
                    toolName: toolName,
                    summary: summary,
                    extraCount: extraCount,
                    otherAgentPending: otherAgentPending,
                    cwd: cwd,
                    isDangerous: isDangerous,
                    onAllowOnce: {
                        if let id = permissions.queue.first?.id {
                            permissions.resolve(id, behavior: "allow")
                        }
                    },
                    onDeny: {
                        if let id = permissions.queue.first?.id {
                            permissions.resolve(id, behavior: "deny")
                        }
                    },
                    onCompactOutcome: { allowed in
                        controller.showApprovalOutcome(allowed: allowed)
                    },
                    onFinishOutcome: {
                        controller.finishApprovalOutcome(hasPendingApproval: !permissions.queue.isEmpty)
                    }
                )
            }
        case .plan:
            if let request = plans.queue.first {
                PlanReviewView(request: request) { decision, comment in
                    plans.resolve(request.id, decision: decision, comment: comment)
                    controller.finishPlanResponse()
                }
                .id(request.id)
            }
        case .question:
            if let request = questions.queue.first {
                AgentQuestionView(request: request, uiState: uiState, extraCount: questions.queue.count - 1) { answers in
                    questions.resolve(request.id, answers: answers)
                    controller.finishQuestionResponse()
                }
                .id(request.id)
            }
        }
    }

    private var viewTabs: some View {
        HStack(spacing: 4) {
            ForEach(NookView.allCases, id: \.self) { view in
                Button {
                    selectView(view)
                } label: {
                    Label(view.title, systemImage: viewIcon(view))
                        .font(.system(size: 10, weight: .medium))
                        .foregroundColor(uiState.activeView == view ? .white : .white.opacity(0.48))
                        .padding(.horizontal, 8)
                        .frame(height: 28)
                        .background(
                            Capsule().fill(uiState.activeView == view ? Color.white.opacity(0.11) : Color.clear)
                        )
                }
                .buttonStyle(NotchPressStyle(pressedScale: 0.9))
                .hoverLift(cornerRadius: 9, strength: 0.08)
                .accessibilityLabel(view.title)
                .accessibilityAddTraits(uiState.activeView == view ? [.isSelected] : [])
                .accessibilityIdentifier("notch.view.\(view.title.lowercased())")
                .help(uiState.activeView == view ? String(localized: "nook.tab.currentView", defaultValue: "Current view") : String(localized: "nook.tab.showView", defaultValue: "Show \(view.title)"))
            }
            if hasDetailPanel(for: uiState.activeView) {
                Spacer(minLength: 2)
                Button { controller.toggleDetailExpansion() } label: {
                    Label(String(localized: "nook.tab.details", defaultValue: "Details"), systemImage: uiState.isDetailExpanded ? "chevron.up" : "chevron.down")
                        .font(.system(size: 9.5, weight: .medium))
                        .foregroundColor(.white.opacity(0.60))
                        .padding(.horizontal, 9)
                        .frame(height: 28)
                        .background(Capsule().fill(Color.white.opacity(0.055)))
                }
                .buttonStyle(NotchPressStyle(pressedScale: 0.9))
                .hoverLift(cornerRadius: 9)
                .accessibilityIdentifier("notch.details")
                .help(uiState.isDetailExpanded ? String(localized: "nook.tab.collapseDetails", defaultValue: "Collapse details") : String(localized: "nook.tab.expandDetails", defaultValue: "Expand details"))
            } else {
                Spacer(minLength: 2)
            }
        }
        .frame(height: 30)
    }

    private func viewIcon(_ view: NookView) -> String {
        switch view {
        case .agents: return "terminal"
        case .dashboard: return "square.grid.2x2"
        }
    }

    /// Agents gained a detail panel in Phase 5 (context-usage%, moved out of
    /// the always-visible row). Dashboard (formerly Today/System, which each
    /// already had one, merged with Media, which didn't need one since its
    /// metadata is fully covered by the always-visible main content) also
    /// has one — see `expandedDetail`'s `.dashboard` case.
    private func hasDetailPanel(for view: NookView) -> Bool {
        view == .agents || view == .dashboard
    }

    /// Mirrors `AgentsCell.selected`'s "explicitly selected, else first"
    /// logic at the `NotchView` level, since `expandedDetail` (unlike
    /// `AgentsCell` itself) doesn't have its own local session-selection
    /// state to read from.
    private var selectedAgentSession: AgentSession? {
        if let id = uiState.selectedSessionId, let match = store.sessions.first(where: { $0.id == id }) {
            return match
        }
        return store.sessions.first
    }

    @ViewBuilder
    private var expandedDetail: some View {
        switch uiState.activeView {
        case .agents:
            if let session = selectedAgentSession {
                DetailStrip(items: orderedDetailItems(tabId: "agents", items: [
                    ("agents.project", String(localized: "detail.agents.project", defaultValue: "Project"), cwdTail(session.cwd)),
                    ("agents.context", String(localized: "detail.agents.context", defaultValue: "Context used"), session.contextUsedPercent.map(contextUsedPercentValue) ?? String(localized: "detail.agents.contextUnavailable", defaultValue: "—")),
                ]))
            }
        case .dashboard:
            // Today's 3 items + System's 2 items = 5, too many to stay
            // legible as one 540pt-wide row (each box would get roughly
            // half the width it gets today) — kept as two stacked
            // `DetailStrip`s instead, matching each source tab's own prior
            // per-item width exactly. `tabId` keeps the pre-merge "today"/
            // "system" identifiers rather than a new "dashboard" one:
            // `tabLayouts` is inert today (see `orderedDetailItems`'s doc
            // comment) but preserving the finer-grained IDs keeps that data
            // model meaningful if a layout-editing UI is ever built.
            VStack(spacing: 6) {
                DetailStrip(items: orderedDetailItems(tabId: "today", items: [
                    ("today.location", String(localized: "detail.today.location", defaultValue: "Location"), todayLocationValue),
                    ("today.duration", String(localized: "detail.today.duration", defaultValue: "Duration"), todayDurationValue),
                    ("today.attendees", String(localized: "detail.today.attendees", defaultValue: "Attendees"), todayAttendeesValue)
                ]))
                DetailStrip(items: orderedDetailItems(tabId: "system", items: [
                    ("system.uptime", String(localized: "detail.system.uptime", defaultValue: "Uptime"), systemMonitor.uptime),
                    ("system.activity", String(localized: "detail.system.activity", defaultValue: "Also running"), systemMoreActivityValue)
                ]))
                dashboardFocusRow
            }
            .onAppear { todayModel.refresh() }
        }
    }

    /// The focus timer, moved here out of `DashboardTodaySection`. It's an
    /// AgentNotch feature with no counterpart in NotchNook's calendar
    /// widget, and having it sit in the always-visible row is part of what
    /// made that widget read as cluttered. Behind "Details" it stays one
    /// click away without competing with the calendar itself.
    private var dashboardFocusRow: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            let remaining = uiState.focusEndsAt.map { max(Int($0.timeIntervalSince(context.date)), 0) }
            let isIdle = remaining == nil || remaining == 0
            Button {
                SoundPlayer.shared.play(.action)
                HapticPlayer.shared.perform(.confirm)
                uiState.focusEndsAt = isIdle ? Date().addingTimeInterval(25 * 60) : nil
            } label: {
                Label(focusLabel(remaining), systemImage: isIdle ? "moon.fill" : "stop.fill")
                    .font(.system(size: 10, weight: .semibold))
                    .frame(maxWidth: .infinity)
                    .frame(height: 24)
                    .background(RoundedRectangle(cornerRadius: 8).fill(Color.white.opacity(0.09)))
            }
            .buttonStyle(NotchPressStyle())
            .hoverLift(cornerRadius: 8)
            .accessibilityIdentifier("today.focus")
            .help(isIdle ? String(localized: "today.startFocusHelp", defaultValue: "Start a 25 minute local focus timer") : String(localized: "today.endFocus", defaultValue: "End Focus"))
        }
    }

    private func focusLabel(_ remaining: Int?) -> String {
        guard let remaining, remaining > 0 else { return String(localized: "today.startFocus", defaultValue: "Start Focus") }
        let format = String(localized: "today.endFocusWithTime", defaultValue: "End Focus · %02d:%02d")
        return String(format: format, remaining / 60, remaining % 60)
    }

    /// Reorders/filters `items` (each `(id, label, value)`) using
    /// `AppSettings.shared.tabLayouts[tabId]`, falling back to `items`'
    /// built-in order untouched when no layout is saved for this tab (the
    /// default, until a future settings UI writes one). This is the only
    /// place `tabLayouts` currently affects rendering — the data model is
    /// otherwise inert until a layout-editing UI exists.
    private func orderedDetailItems(tabId: String, items: [(id: String, label: String, value: String)]) -> [(String, String)] {
        guard let configuration = AppSettings.shared.tabLayouts[tabId] else {
            return items.map { ($0.label, $0.value) }
        }
        let byId = Dictionary(uniqueKeysWithValues: items.map { ($0.id, $0) })
        let orderedIds = configuration.applying(to: items.map(\.id))
        return orderedIds.compactMap { byId[$0] }.map { ($0.label, $0.value) }
    }

    private var todayLocationValue: String {
        guard let event = todayModel.events.first else {
            return String(localized: "detail.today.noEvent", defaultValue: "No event")
        }
        return event.location ?? String(localized: "detail.today.locationNone", defaultValue: "No location")
    }

    private var todayDurationValue: String {
        guard let event = todayModel.events.first else {
            return String(localized: "detail.today.noEvent", defaultValue: "No event")
        }
        let minutes = max(Int(event.endDate.timeIntervalSince(event.startDate) / 60), 0)
        guard minutes > 0 else {
            return String(localized: "detail.today.durationUnknown", defaultValue: "—")
        }
        if minutes >= 60 {
            let hours = minutes / 60
            let remainder = minutes % 60
            return remainder > 0
                ? String(localized: "detail.today.durationHoursMinutes", defaultValue: "\(String(hours))h \(String(remainder))m")
                : String(localized: "detail.today.durationHours", defaultValue: "\(String(hours))h")
        }
        return String(localized: "detail.today.durationMinutes", defaultValue: "\(String(minutes)) min")
    }

    private var todayAttendeesValue: String {
        guard let event = todayModel.events.first else {
            return String(localized: "detail.today.noEvent", defaultValue: "No event")
        }
        guard let count = event.attendeeCount, count > 0 else {
            return String(localized: "detail.today.attendeesJustYou", defaultValue: "Just you")
        }
        return String(localized: "detail.today.attendeesCount", defaultValue: "\(String(count)) people")
    }

    private var systemMoreActivityValue: String {
        let extra = backgroundActivity.activities.dropFirst()
        guard !extra.isEmpty else {
            return String(localized: "detail.system.activityNone", defaultValue: "Nothing else running")
        }
        return extra.map { "\($0.title) (\($0.elapsedLabel))" }.joined(separator: ", ")
    }

    private var trayContent: some View {
        TrayCell(
            items: $trayItems,
            selectedItemID: $selectedTrayItemID,
            isTargeted: isDropTargeted,
            isAirDropTargeted: isAirDropTargeted,
            shortcuts: settings.registeredShortcuts,
            airDropWellFrame: $airDropWellFrame,
            feedback: trayFeedback,
            canUndo: !pendingTrayUndo.isEmpty
        ) { action in
            let selectedItems = selectedTrayItemID.flatMap { id in trayItems.first(where: { $0.id == id }) }.map { [$0] } ?? trayItems
            let selectedURLs = selectedItems.map(\.url)
            switch action {
            case .choose:
                chooseTrayFiles()
            case .open:
                selectedURLs.forEach { NSWorkspace.shared.open($0) }
                trayFeedback = selectedURLs.isEmpty ? String(localized: "tray.feedback.selectAFile", defaultValue: "Select a file") : String(localized: "tray.feedback.opened", defaultValue: "Opened")
            case .reveal:
                guard !selectedURLs.isEmpty else {
                    trayFeedback = String(localized: "tray.feedback.selectAFile", defaultValue: "Select a file")
                    return
                }
                NSWorkspace.shared.activateFileViewerSelecting(selectedURLs)
                trayFeedback = String(localized: "tray.feedback.shownInFinder", defaultValue: "Shown in Finder")
            case .clear:
                let clearedCount = trayItems.count
                pendingTrayUndo = trayItems
                trayItems.removeAll()
                selectedTrayItemID = nil
                syncTrayState()
                controller.releaseTrayHold()
                trayFeedback = String(localized: "tray.feedback.clearedItems", defaultValue: "Cleared \(String(clearedCount)) item\(clearedCount == 1 ? "" : "s")")
                scheduleTrayUndoExpiry()
            case .removeSelected:
                guard let selectedTrayItemID,
                      let index = trayItems.firstIndex(where: { $0.id == selectedTrayItemID }) else {
                    trayFeedback = String(localized: "tray.feedback.selectAFile", defaultValue: "Select a file")
                    return
                }
                pendingTrayUndo = [trayItems.remove(at: index)]
                self.selectedTrayItemID = trayItems.indices.contains(index) ? trayItems[index].id : trayItems.last?.id
                syncTrayState()
                trayFeedback = String(localized: "tray.feedback.removedFromTray", defaultValue: "Removed from Tray")
                scheduleTrayUndoExpiry()
            case .removeItem(let itemID):
                guard let index = trayItems.firstIndex(where: { $0.id == itemID }) else {
                    trayFeedback = String(localized: "tray.feedback.selectAFile", defaultValue: "Select a file")
                    return
                }
                pendingTrayUndo = [trayItems.remove(at: index)]
                if selectedTrayItemID == itemID {
                    selectedTrayItemID = trayItems.indices.contains(index) ? trayItems[index].id : trayItems.last?.id
                }
                syncTrayState()
                trayFeedback = String(localized: "tray.feedback.removedFromTray", defaultValue: "Removed from Tray")
                scheduleTrayUndoExpiry()
            case .undo:
                guard !pendingTrayUndo.isEmpty else { return }
                let restored = pendingTrayUndo
                pendingTrayUndo.removeAll()
                trayUndoTask?.cancel()
                for item in restored where !trayItems.contains(where: { $0.url.standardizedFileURL == item.url.standardizedFileURL }) {
                    trayItems.append(item)
                }
                selectedTrayItemID = restored.last?.id
                syncTrayState()
                controller.keepTrayOpen()
                trayFeedback = String(localized: "tray.feedback.restored", defaultValue: "Restored")
            case .copyPath:
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(selectedURLs.map(\.path).joined(separator: "\n"), forType: .string)
                trayFeedback = String(localized: "tray.feedback.pathsCopied", defaultValue: "Paths copied")
            case .airDrop:
                sendViaAirDrop(selectedURLs)
            case .runShortcut(let shortcut):
                runShortcut(shortcut, with: selectedURLs)
            case .compress:
                trayFeedback = String(localized: "tray.feedback.compressing", defaultValue: "Compressing…")
                Task {
                    trayFeedback = await compressTrayItems(selectedURLs)
                }
            case .attach:
                NSPasteboard.general.clearContents()
                NSPasteboard.general.writeObjects(selectedURLs.map { $0 as NSURL })
                trayFeedback = String(localized: "tray.feedback.readyToPaste", defaultValue: "Ready to paste into agent")
            }
        }
    }

    /// `.zero` means the Tray page (and therefore the well) isn't laid out,
    /// and `CGRect.zero.contains` would still be false for any real point —
    /// but the explicit guard keeps that from being an accident of geometry.
    private func isOverAirDropWell(_ location: CGPoint) -> Bool {
        guard uiState.activeTab == .tray, !airDropWellFrame.isEmpty else { return false }
        return airDropWellFrame.contains(location)
    }

    /// Fire-and-report: a shortcut can take arbitrarily long (it may show
    /// its own UI or wait on the network), so the Tray shows "Running…"
    /// immediately and replaces it when the run finishes.
    private func runShortcut(_ shortcut: ShortcutBinding, with urls: [URL]) {
        trayFeedback = String(localized: "tray.feedback.runningShortcut", defaultValue: "Running \(shortcut.name)…")
        Task {
            let failure = await ShortcutRunner.run(name: shortcut.name, inputPaths: urls.map(\.path))
            trayFeedback = failure ?? String(localized: "tray.feedback.shortcutFinished", defaultValue: "\(shortcut.name) finished")
        }
    }

    private func sendViaAirDrop(_ urls: [URL]) {
        guard let service = NSSharingService(named: .sendViaAirDrop), service.canPerform(withItems: urls) else {
            trayFeedback = String(localized: "tray.feedback.airDropUnavailable", defaultValue: "AirDrop unavailable")
            return
        }
        service.perform(withItems: urls)
        trayFeedback = String(localized: "tray.feedback.airDropOpened", defaultValue: "AirDrop opened")
    }

    private func addTrayItems(_ urls: [URL]) {
        trayUndoTask?.cancel()
        pendingTrayUndo.removeAll()
        for url in urls where !trayItems.contains(where: { $0.url.standardizedFileURL == url.standardizedFileURL }) {
            trayItems.append(TrayItem(url: url))
        }
        selectedTrayItemID = trayItems.last?.id
        isDropTargeted = false
        trayFeedback = urls.isEmpty ? String(localized: "tray.feedback.dropFailed", defaultValue: "Drop failed") : String(localized: "tray.feedback.savedTemporarily", defaultValue: "Saved temporarily")
        syncTrayState()
        if !trayItems.isEmpty { controller.keepTrayOpen() }
        SoundPlayer.shared.play(.action)
    }

    private func syncTrayState() {
        uiState.trayHasItems = !trayItems.isEmpty
        uiState.trayItemCount = trayItems.count
        uiState.reopenTrayOnNextOpen = !trayItems.isEmpty
    }

    private func scheduleTrayUndoExpiry() {
        trayUndoTask?.cancel()
        // Compare against the message captured at schedule time rather than
        // specific English text — the text is localized, so a literal string
        // match would silently stop working once translations are in place.
        let feedbackAtSchedule = trayFeedback
        trayUndoTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 5_000_000_000)
            guard !Task.isCancelled else { return }
            pendingTrayUndo.removeAll()
            if trayFeedback == feedbackAtSchedule {
                trayFeedback = nil
            }
        }
    }

    private func chooseTrayFiles() {
        let picker = NSOpenPanel()
        picker.allowsMultipleSelection = true
        picker.canChooseFiles = true
        picker.canChooseDirectories = true
        picker.prompt = String(localized: "tray.addToTrayPrompt", defaultValue: "Add to Tray")
        NSApp.activate(ignoringOtherApps: true)
        picker.begin { response in
            guard response == .OK else { return }
            addTrayItems(picker.urls)
        }
    }

    private func compressTrayItems(_ urls: [URL]) async -> String {
        guard !urls.isEmpty, let directory = urls.first?.deletingLastPathComponent() else { return String(localized: "tray.feedback.nothingToCompress", defaultValue: "Nothing to compress") }
        var output = directory.appendingPathComponent("AgentNotch Archive.zip")
        var suffix = 2
        while FileManager.default.fileExists(atPath: output.path) {
            output = directory.appendingPathComponent("AgentNotch Archive \(suffix).zip")
            suffix += 1
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/zip")
        process.arguments = ["-r", output.path] + urls.map(\.path)
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        let outputName = output.lastPathComponent
        return await withCheckedContinuation { continuation in
            process.terminationHandler = { finished in
                continuation.resume(returning: finished.terminationStatus == 0 ? String(localized: "tray.feedback.savedArchive", defaultValue: "Saved \(outputName)") : String(localized: "tray.feedback.compressionFailed", defaultValue: "Compression failed"))
            }
            do {
                try process.run()
            } catch {
                continuation.resume(returning: String(localized: "tray.feedback.compressionFailed", defaultValue: "Compression failed"))
            }
        }
    }

    private var horizontalSwipeGesture: some Gesture {
        DragGesture(minimumDistance: 10, coordinateSpace: .local)
            .updating($horizontalDrag) { value, state, _ in
                guard uiState.overlay == nil,
                      abs(value.translation.width) > abs(value.translation.height) else { return }
                state = rubberBand(value.translation.width, limit: 180)
            }
            .onEnded { value in
                guard uiState.overlay == nil,
                      abs(value.translation.width) > abs(value.translation.height) * 1.15 else { return }
                let projected = value.predictedEndTranslation.width
                let committed = abs(value.translation.width) > 52 || abs(projected) > 88
                guard committed else { return }
                projected < 0 ? navigateForward() : navigateBackward()
            }
    }

    // Agents is excluded because it hosts its own vertical `ScrollView` for
    // the session list (see `handleVerticalScroll`'s doc comment in
    // NotchWindow.swift) — Dashboard has no competing scroll view and does
    // have a detail panel, so it's not excluded here.
    private var verticalDetailGesture: some Gesture {
        DragGesture(minimumDistance: 10, coordinateSpace: .local)
            .updating($verticalDrag) { value, state, _ in
                guard uiState.overlay == nil,
                      uiState.activeView != .agents,
                      abs(value.translation.height) > abs(value.translation.width) else { return }
                state = value.translation.height
            }
            .onEnded { value in
                guard uiState.overlay == nil,
                      uiState.activeView != .agents,
                      abs(value.translation.height) > abs(value.translation.width) * 1.15 else { return }
                let projected = value.predictedEndTranslation.height
                let committed = abs(value.translation.height) > 34 || abs(projected) > 58
                guard committed else { return }
                controller.setDetailExpanded(projected > 0)
            }
    }

    private func rubberBand(_ value: CGFloat, limit: CGFloat) -> CGFloat {
        let magnitude = abs(value)
        let damped = (magnitude * limit * 0.55) / (limit + 0.55 * magnitude)
        return value < 0 ? -damped : damped
    }

    private func selectTab(_ tab: NotchTab) {
        guard uiState.activeTab != tab else { return }
        SoundPlayer.shared.play(.navigation)
        withAnimation(reduceMotion ? .easeOut(duration: 0.12) : DesignTokens.scaledSpring()) {
            uiState.activeTab = tab
        }
    }

    private func selectView(_ view: NookView) {
        guard uiState.activeView != view else { return }
        SoundPlayer.shared.play(.navigation)
        withAnimation(reduceMotion ? .easeOut(duration: 0.12) : DesignTokens.scaledContentTransition()) {
            uiState.activeView = view
        }
    }

    private func navigateForward() {
        if uiState.activeTab == .tray { return }
        let views = NookView.allCases
        guard let index = views.firstIndex(of: uiState.activeView) else { return }
        if index < views.count - 1 {
            selectView(views[index + 1])
        } else {
            selectTab(.tray)
        }
    }

    private func navigateBackward() {
        if uiState.activeTab == .tray {
            selectTab(.nook)
            return
        }
        let views = NookView.allCases
        guard let index = views.firstIndex(of: uiState.activeView), index > 0 else { return }
        selectView(views[index - 1])
    }
}

struct DetailStrip: View {
    let items: [(String, String)]

    var body: some View {
        HStack(spacing: 6) {
            ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                DetailBox(label: item.0) {
                    Text(item.1)
                        .font(.system(size: 8.5, weight: .medium))
                        .foregroundColor(.white.opacity(0.82))
                        .lineLimit(2)
                        .truncationMode(.tail)
                        .help(item.1)
                }
            }
        }
    }
}

/// A single labeled box used inside the expanded detail strip. Extracted so
/// callers can swap in richer content than a plain text value while keeping
/// the same box chrome/sizing.
private struct DetailBox<Content: View>: View {
    let label: String
    @ViewBuilder var content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label)
                .font(.system(size: 6.5, weight: .medium))
                .foregroundColor(DesignTokens.muted)
            content()
        }
        .frame(maxWidth: .infinity, minHeight: 42, alignment: .leading)
        .padding(.horizontal, 8)
        .background(RoundedRectangle(cornerRadius: 9).fill(Color.white.opacity(0.055)))
    }
}

/// Shared label for a usage window ("5h"/"Day"/"Week"), used by the
/// always-visible compact `UsageSummaryBar` (pinned atop the Agents cell).
private func usageWindowLabel(_ window: UsageWindow) -> String {
    switch window.windowMinutes ?? 0 {
    case 0..<360: return String(localized: "usage.window.fiveHour", defaultValue: "5h")
    case 360..<10_000: return String(localized: "usage.window.day", defaultValue: "Day")
    default: return String(localized: "usage.window.week", defaultValue: "Week")
    }
}

/// Always-visible, single-line usage summary pinned to the very top of the
/// Agents cell (above the session list), styled after the reference
/// design's "✦ 5h 11% 4h1m | 7d 2% 6h1m" bar: a sparkle glyph, then each
/// usage window as "label percent% resetIn", separated by "|". Colors each
/// window's percentage using the same green/orange/red thresholds used
/// throughout the app for quota warnings.
struct UsageSummaryBar: View {
    let agent: AgentKind
    let snapshot: AgentUsageSnapshot?

    private var windows: [(String, UsageWindow)] {
        guard let snapshot else { return [] }
        return [snapshot.primary, snapshot.secondary]
            .compactMap { $0 }
            .map { (usageWindowLabel($0), $0) }
    }

    var body: some View {
        HStack(spacing: 6) {
            glyphContent(agent, size: 9)
                .foregroundColor(.white.opacity(0.55))
                .frame(width: 12, height: 12)
            if windows.isEmpty {
                Text(snapshot?.error == nil
                     ? String(localized: "detail.agents.noUsageWindow", defaultValue: "No usage window")
                     : String(localized: "detail.agents.unavailable", defaultValue: "Unavailable"))
                    .font(.system(size: 8.5, weight: .medium))
                    .foregroundColor(.white.opacity(0.4))
            } else {
                ForEach(Array(windows.enumerated()), id: \.offset) { index, pair in
                    if index > 0 {
                        Rectangle()
                            .fill(Color.white.opacity(0.14))
                            .frame(width: 1, height: 20)
                    }
                    usagePiece(label: pair.0, window: pair.1)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .accessibilityElement(children: .combine)
    }

    /// Percentage is the primary signal, so it's rendered large and bold;
    /// the reset time is secondary and rendered small underneath as a short
    /// relative countdown ("resets in 3h") rather than CodexBar's longer
    /// absolute-datetime string, which didn't fit the compact bar.
    private func usagePiece(label: String, window: UsageWindow) -> some View {
        let clamped = min(max(window.usedPercent, 0), 100)
        let color: Color = clamped >= 95 ? DesignTokens.red : (clamped >= 80 ? DesignTokens.orange : DesignTokens.green)
        return VStack(alignment: .leading, spacing: 1) {
            HStack(spacing: 4) {
                Text(label)
                    .font(.system(size: 8.5, weight: .semibold))
                    .foregroundColor(.white.opacity(0.65))
                Text("\(Int(clamped.rounded()))%")
                    .font(.system(size: 12, weight: .bold, design: .rounded))
                    .foregroundColor(color)
            }
            if let reset = window.relativeResetDescription() {
                Text(reset)
                    .font(.system(size: 7.5, weight: .medium))
                    .foregroundColor(.white.opacity(0.38))
                    .lineLimit(1)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(String(localized: "usage.windowPercentAccessibility", defaultValue: "\(label) \(Int(clamped.rounded())) percent used"))
    }
}

// MARK: - Shared status helpers

func statusColor(_ state: SessionState) -> Color {
    switch state {
    case .running: return DesignTokens.green
    case .waitingApproval: return DesignTokens.orange
    case .done: return DesignTokens.doneGray
    case .failed: return DesignTokens.red
    case .idle: return DesignTokens.doneGray
    }
}

func elapsedString(_ session: AgentSession) -> String {
    let interval = Date().timeIntervalSince(session.lastActivity)
    let minutes = max(0, Int(interval / 60))
    return "\(minutes)m"
}

func cwdTail(_ cwd: String) -> String {
    URL(fileURLWithPath: cwd).lastPathComponent
}

/// Buckets `sessions` by `cwd` (project), preserving `sessions`' own
/// ordering (most-recent-first, per `SessionStore`) — the first occurrence
/// of each `cwd` anchors that group's position, so a newly-active
/// session's project still surfaces near the top rather than group order
/// being alphabetical or otherwise disconnected from recency. Pulled out
/// as a pure function so the ordering logic is testable without
/// constructing a `SessionStore`/view — see `AgentsCell.groupedSessions`.
func groupSessionsByProject(_ sessions: [AgentSession]) -> [(cwd: String, sessions: [AgentSession])] {
    var order: [String] = []
    var buckets: [String: [AgentSession]] = [:]
    for session in sessions {
        if buckets[session.cwd] == nil {
            order.append(session.cwd)
        }
        buckets[session.cwd, default: []].append(session)
    }
    return order.map { (cwd: $0, sessions: buckets[$0] ?? []) }
}

/// Plain "NN%" value string for the Agents detail panel (`DetailStrip`
/// only takes label/value strings). Context-usage percentage moved out of
/// the always-visible session row into the detail panel as part of
/// Phase 5's "row shows agent/project/activity/state/elapsed only" pass.
func contextUsedPercentValue(_ percent: Double) -> String {
    let clamped = min(max(percent, 0), 100)
    return "\(Int(clamped.rounded()))%"
}

func sessionStateLabel(_ state: SessionState) -> String {
    switch state {
    case .running: return String(localized: "agents.state.running", defaultValue: "Running")
    case .waitingApproval: return String(localized: "agents.state.needsAttention", defaultValue: "Needs attention")
    case .done: return String(localized: "agents.state.done", defaultValue: "Done")
    case .idle: return String(localized: "agents.state.paused", defaultValue: "Paused")
    case .failed: return String(localized: "agents.state.failed", defaultValue: "Failed")
    }
}
