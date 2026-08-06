import SwiftUI
import UniformTypeIdentifiers

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
    @StateObject private var todayModel = TodayModel()
    @StateObject private var systemMonitor = SystemMonitor()
    @StateObject private var backgroundActivity = BackgroundActivityMonitor()
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var trayItems: [TrayItem] = []
    @State private var selectedTrayItemID: UUID?
    @State private var isDropTargeted = false
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
            .animation(DesignTokens.scaledSpring(), value: uiState.mode)
        }
        .contentShape(Rectangle())
        .onHover {
            controller.hoverChanged($0)
            updateCompactMediaHover($0)
        }
        .onChange(of: uiState.mode) { _, mode in
            if mode != .closed { hideCompactMediaPreview() }
        }
        .onAppear {
            controller.installFileDropHandlers(
                targeted: { isDropTargeted = $0 },
                dropped: { urls in addTrayItems(urls) }
            )
        }
        .onDisappear {
            compactMediaHoverTask?.cancel()
            trayUndoTask?.cancel()
            isDropTargeted = false
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

    private var shellShape: UnevenRoundedRectangle {
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
        return UnevenRoundedRectangle(
            topLeadingRadius: 0,
            bottomLeadingRadius: radius,
            bottomTrailingRadius: radius,
            topTrailingRadius: 0,
            style: .continuous
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
            .shadow(color: (isHover && media.isPlaying ? edgeColor : .black).opacity(isHover ? 0.35 : 0), radius: isHover ? 12 : 0, y: isHover ? 6 : 0)
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
                uiState.activeView = .media
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
                switch uiState.activeTab {
                case .nook:
                    nookContentView
                case .tray:
                    trayContent
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
        .padding(.horizontal, 12)
        .padding(.top, 6)
        .padding(.bottom, 10)
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
            Button {
                NSApp.activate(ignoringOtherApps: true)
                NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
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
                Label(title, systemImage: icon)
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
                    case .media:
                        MediaCell(media: media)
                    case .today:
                        TodayCell(focusEndsAt: $uiState.focusEndsAt)
                    case .system:
                        SystemCell()
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
        case .approval(let agent, let toolName, let summary, let extraCount, let otherAgentPending):
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
                AgentQuestionView(request: request, uiState: uiState) { answers in
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
        case .media: return "play.fill"
        case .today: return "calendar"
        case .system: return "gauge.with.dots.needle.50percent"
        }
    }

    /// Agents and Media have no detail panel: their metadata is fully
    /// covered by the always-visible main content, so a separate panel
    /// would only repeat it. System and Today surface additional data here.
    private func hasDetailPanel(for view: NookView) -> Bool {
        view == .system || view == .today
    }

    @ViewBuilder
    private var expandedDetail: some View {
        switch uiState.activeView {
        case .agents, .media:
            EmptyView()
        case .today:
            DetailStrip(items: orderedDetailItems(tabId: "today", items: [
                ("today.location", String(localized: "detail.today.location", defaultValue: "Location"), todayLocationValue),
                ("today.duration", String(localized: "detail.today.duration", defaultValue: "Duration"), todayDurationValue),
                ("today.attendees", String(localized: "detail.today.attendees", defaultValue: "Attendees"), todayAttendeesValue)
            ]))
            .onAppear { todayModel.refresh() }
        case .system:
            DetailStrip(items: orderedDetailItems(tabId: "system", items: [
                ("system.uptime", String(localized: "detail.system.uptime", defaultValue: "Uptime"), systemMonitor.uptime),
                ("system.activity", String(localized: "detail.system.activity", defaultValue: "Also running"), systemMoreActivityValue)
            ]))
        }
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
                if let service = NSSharingService(named: .sendViaAirDrop), service.canPerform(withItems: selectedURLs) {
                    service.perform(withItems: selectedURLs)
                    trayFeedback = String(localized: "tray.feedback.airDropOpened", defaultValue: "AirDrop opened")
                } else {
                    trayFeedback = String(localized: "tray.feedback.airDropUnavailable", defaultValue: "AirDrop unavailable")
                }
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

    private var verticalDetailGesture: some Gesture {
        DragGesture(minimumDistance: 10, coordinateSpace: .local)
            .updating($verticalDrag) { value, state, _ in
                guard uiState.overlay == nil,
                      uiState.activeView != .agents, uiState.activeView != .media,
                      abs(value.translation.height) > abs(value.translation.width) else { return }
                state = value.translation.height
            }
            .onEnded { value in
                guard uiState.overlay == nil,
                      uiState.activeView != .agents, uiState.activeView != .media,
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

private struct DetailStrip: View {
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
private struct UsageSummaryBar: View {
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

func sessionStateLabel(_ state: SessionState) -> String {
    switch state {
    case .running: return String(localized: "agents.state.running", defaultValue: "Running")
    case .waitingApproval: return String(localized: "agents.state.needsAttention", defaultValue: "Needs attention")
    case .done: return String(localized: "agents.state.done", defaultValue: "Done")
    case .idle: return String(localized: "agents.state.paused", defaultValue: "Paused")
    case .failed: return String(localized: "agents.state.failed", defaultValue: "Failed")
    }
}

// MARK: - Glyph

struct ClaudeBloomGlyph: View {
    var size: CGFloat
    var color: Color = .orange

    var body: some View {
        Canvas { context, canvasSize in
            let center = CGPoint(x: canvasSize.width / 2, y: canvasSize.height / 2)
            let petalLength = canvasSize.height * 0.46
            let petalWidth = canvasSize.width * 0.15
            var petal = Path()
            petal.move(to: .zero)
            petal.addQuadCurve(to: CGPoint(x: 0, y: -petalLength), control: CGPoint(x: petalWidth, y: -petalLength * 0.5))
            petal.addQuadCurve(to: .zero, control: CGPoint(x: -petalWidth, y: -petalLength * 0.5))
            petal.closeSubpath()

            for i in 0..<6 {
                var layer = context
                layer.translateBy(x: center.x, y: center.y)
                layer.rotate(by: .degrees(Double(i) * 60))
                layer.fill(petal, with: .color(color))
            }
            let coreRadius = canvasSize.width * 0.09
            let coreRect = CGRect(x: center.x - coreRadius, y: center.y - coreRadius, width: coreRadius * 2, height: coreRadius * 2)
            context.fill(Path(ellipseIn: coreRect), with: .color(color))
        }
        .frame(width: size, height: size)
    }
}

struct CodexBlobGlyph: View {
    var size: CGFloat
    var color: Color = .white

    var body: some View {
        Canvas { context, canvasSize in
            let w = canvasSize.width
            let h = canvasSize.height
            let lumps: [(CGFloat, CGFloat, CGFloat)] = [
                (0.50, 0.40, 0.34),
                (0.27, 0.56, 0.28),
                (0.73, 0.56, 0.28),
                (0.50, 0.66, 0.30),
                (0.38, 0.32, 0.22),
                (0.63, 0.32, 0.22),
            ]
            for (cx, cy, r) in lumps {
                let rect = CGRect(x: (cx * w) - (r * w / 2), y: (cy * h) - (r * h / 2), width: r * w, height: r * h)
                context.fill(Path(ellipseIn: rect), with: .color(color.opacity(0.92)))
            }
        }
        .frame(width: size, height: size)
    }
}

struct AntigravityGlyph: View {
    var size: CGFloat

    var body: some View {
        ZStack {
            Circle()
                .fill(LinearGradient(
                    colors: [.cyan, .blue, .purple],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                ))
                .frame(width: size * 0.68, height: size * 0.68)
                .shadow(color: .cyan.opacity(0.4), radius: 2)
            
            Ellipse()
                .stroke(LinearGradient(
                    colors: [.white, .cyan.opacity(0.8), .clear],
                    startPoint: .top,
                    endPoint: .bottom
                ), lineWidth: size * 0.08)
                .frame(width: size * 1.0, height: size * 0.32)
                .rotationEffect(.degrees(-22))
        }
        .frame(width: size, height: size)
    }
}

struct GeminiGlyph: View {
    var size: CGFloat

    var body: some View {
        Canvas { context, canvasSize in
            let w = canvasSize.width
            let h = canvasSize.height
            let r = min(w, h) / 2
            
            var path = Path()
            path.move(to: CGPoint(x: w/2, y: h/2 - r))
            path.addQuadCurve(to: CGPoint(x: w/2 + r, y: h/2), control: CGPoint(x: w/2 + r*0.12, y: h/2 - r*0.12))
            path.addQuadCurve(to: CGPoint(x: w/2, y: h/2 + r), control: CGPoint(x: w/2 + r*0.12, y: h/2 + r*0.12))
            path.addQuadCurve(to: CGPoint(x: w/2 - r, y: h/2), control: CGPoint(x: w/2 - r*0.12, y: h/2 + r*0.12))
            path.addQuadCurve(to: CGPoint(x: w/2, y: h/2 - r), control: CGPoint(x: w/2 - r*0.12, y: h/2 - r*0.12))
            path.closeSubpath()
            
            let gradient = GraphicsContext.Shading.linearGradient(
                Gradient(colors: [
                    Color(red: 0.3, green: 0.5, blue: 1.0),
                    Color(red: 0.7, green: 0.3, blue: 0.9),
                    Color(red: 1.0, green: 0.6, blue: 0.3)
                ]),
                startPoint: CGPoint(x: 0, y: 0),
                endPoint: CGPoint(x: w, y: h)
            )
            context.fill(path, with: gradient)
        }
        .frame(width: size, height: size)
    }
}

struct CopilotGlyph: View {
    var size: CGFloat

    var body: some View {
        Canvas { context, canvasSize in
            let w = canvasSize.width
            let h = canvasSize.height
            
            // Background / head base
            let headRect = CGRect(x: w*0.16, y: h*0.22, width: w*0.68, height: h*0.56)
            let headPath = Path(roundedRect: headRect, cornerRadius: w*0.18)
            
            let headGradient = GraphicsContext.Shading.linearGradient(
                Gradient(colors: [Color(red: 0.5, green: 0.45, blue: 0.95), Color(red: 0.35, green: 0.3, blue: 0.8)]),
                startPoint: CGPoint(x: w*0.16, y: h*0.22),
                endPoint: CGPoint(x: w*0.84, y: h*0.78)
            )
            context.fill(headPath, with: headGradient)
            
            // Visor
            let visorRect = CGRect(x: w*0.26, y: h*0.34, width: w*0.48, height: h*0.24)
            let visorPath = Path(roundedRect: visorRect, cornerRadius: w*0.06)
            context.fill(visorPath, with: .color(.black.opacity(0.85)))
            
            // Ears / headphones
            let earL = CGRect(x: w*0.06, y: h*0.34, width: w*0.1, height: h*0.28)
            let earR = CGRect(x: w*0.84, y: h*0.34, width: w*0.1, height: h*0.28)
            context.fill(Path(roundedRect: earL, cornerRadius: w*0.04), with: .color(Color(red: 0.4, green: 0.35, blue: 0.85)))
            context.fill(Path(roundedRect: earR, cornerRadius: w*0.04), with: .color(Color(red: 0.4, green: 0.35, blue: 0.85)))
            
            // Eyes
            let eyeSize = w*0.08
            let eyeL = CGRect(x: w*0.36, y: h*0.42, width: eyeSize, height: eyeSize)
            let eyeR = CGRect(x: w*0.56, y: h*0.42, width: eyeSize, height: eyeSize)
            context.fill(Path(ellipseIn: eyeL), with: .color(.cyan))
            context.fill(Path(ellipseIn: eyeR), with: .color(.cyan))
        }
        .frame(width: size, height: size)
    }
}

struct CursorGlyph: View {
    var size: CGFloat

    var body: some View {
        Canvas { context, canvasSize in
            let w = canvasSize.width
            let h = canvasSize.height
            
            var path = Path()
            path.move(to: CGPoint(x: w*0.18, y: h*0.12))
            path.addLine(to: CGPoint(x: w*0.82, y: h*0.52))
            path.addLine(to: CGPoint(x: w*0.48, y: h*0.56))
            path.addLine(to: CGPoint(x: w*0.62, y: h*0.88))
            path.addLine(to: CGPoint(x: w*0.48, y: h*0.94))
            path.addLine(to: CGPoint(x: w*0.34, y: h*0.62))
            path.addLine(to: CGPoint(x: w*0.12, y: h*0.52))
            path.closeSubpath()
            
            let gradient = GraphicsContext.Shading.linearGradient(
                Gradient(colors: [Color(red: 0.2, green: 0.8, blue: 0.95), Color(red: 0.1, green: 0.4, blue: 0.8)]),
                startPoint: CGPoint(x: w*0.18, y: h*0.12),
                endPoint: CGPoint(x: w*0.62, y: h*0.88)
            )
            context.fill(path, with: gradient)
        }
        .frame(width: size, height: size)
    }
}

struct OpenCodeGlyph: View {
    var size: CGFloat

    var body: some View {
        HStack(spacing: 0.5) {
            Text(">")
                .font(.system(size: size * 0.82, weight: .bold, design: .monospaced))
                .foregroundColor(Color(red: 0.2, green: 0.85, blue: 0.5))
                .shadow(color: Color(red: 0.2, green: 0.85, blue: 0.5).opacity(0.7), radius: 1.5)
            Text("_")
                .font(.system(size: size * 0.82, weight: .bold, design: .monospaced))
                .foregroundColor(Color(red: 0.2, green: 0.85, blue: 0.5))
                .shadow(color: Color(red: 0.2, green: 0.85, blue: 0.5).opacity(0.7), radius: 1.5)
        }
        .frame(width: size, height: size)
    }
}

struct AiderGlyph: View {
    var size: CGFloat

    var body: some View {
        Canvas { context, canvasSize in
            let w = canvasSize.width
            let h = canvasSize.height
            let center = CGPoint(x: w/2, y: h/2)
            let outerR = w * 0.45
            let innerR = w * 0.20
            
            let outerPath = Path(ellipseIn: CGRect(x: center.x - outerR, y: center.y - outerR, width: outerR * 2, height: outerR * 2))
            context.fill(outerPath, with: .color(.white))
            
            for angle in [45.0, 135.0, 225.0, 315.0] {
                var stripe = Path()
                stripe.move(to: center)
                stripe.addArc(center: center, radius: outerR + 1, startAngle: .degrees(angle - 18), endAngle: .degrees(angle + 18), clockwise: false)
                stripe.closeSubpath()
                context.fill(stripe, with: .color(Color(red: 0.95, green: 0.3, blue: 0.3)))
            }
            
            let innerPath = Path(ellipseIn: CGRect(x: center.x - innerR, y: center.y - innerR, width: innerR * 2, height: innerR * 2))
            context.blendMode = .clear
            context.fill(innerPath, with: .color(.black))
        }
        .frame(width: size, height: size)
    }
}

struct GooseGlyph: View {
    var size: CGFloat

    var body: some View {
        Canvas { context, canvasSize in
            let w = canvasSize.width
            let h = canvasSize.height
            
            let headR = w * 0.24
            let headCenter = CGPoint(x: w * 0.45, y: h * 0.38)
            let headPath = Path(ellipseIn: CGRect(x: headCenter.x - headR, y: headCenter.y - headR, width: headR * 2, height: headR * 2))
            context.fill(headPath, with: .color(.white))
            
            var neckPath = Path()
            neckPath.move(to: CGPoint(x: headCenter.x - headR * 0.8, y: headCenter.y + headR * 0.2))
            neckPath.addQuadCurve(to: CGPoint(x: w * 0.2, y: h * 0.95), control: CGPoint(x: w * 0.26, y: h * 0.65))
            neckPath.addLine(to: CGPoint(x: w * 0.62, y: h * 0.95))
            neckPath.addQuadCurve(to: CGPoint(x: headCenter.x + headR * 0.8, y: headCenter.y + headR * 0.2), control: CGPoint(x: w * 0.56, y: h * 0.65))
            neckPath.closeSubpath()
            context.fill(neckPath, with: .color(.white))
            
            let eyeR = w * 0.045
            let eyeRect = CGRect(x: headCenter.x + headR * 0.12, y: headCenter.y - headR * 0.35, width: eyeR * 2, height: eyeR * 2)
            context.fill(Path(ellipseIn: eyeRect), with: .color(.black))
            
            var beakPath = Path()
            beakPath.move(to: CGPoint(x: headCenter.x + headR * 0.65, y: headCenter.y - headR * 0.08))
            beakPath.addLine(to: CGPoint(x: w * 0.92, y: headCenter.y + headR * 0.12))
            beakPath.addLine(to: CGPoint(x: headCenter.x + headR * 0.42, y: headCenter.y + headR * 0.32))
            beakPath.closeSubpath()
            context.fill(beakPath, with: .color(Color(red: 0.98, green: 0.6, blue: 0.15)))
        }
        .frame(width: size, height: size)
    }
}

struct LocalIconView: View {
    let agent: AgentKind
    let size: CGFloat
    let fallback: () -> AnyView

    var body: some View {
        if let image = loadLocalIcon() {
            Image(nsImage: image)
                .resizable()
                .scaledToFit()
                .frame(width: size, height: size)
        } else {
            fallback()
        }
    }

    private func loadLocalIcon() -> NSImage? {
        let homeDir = NSHomeDirectory()
        let path = "\(homeDir)/.agent-notch/icons/\(agent.rawValue).png"
        return NSImage(contentsOfFile: path)
    }
}

@ViewBuilder
func glyphContent(_ agent: AgentKind?, size: CGFloat) -> some View {
    if let agent = agent {
        LocalIconView(agent: agent, size: size) {
            AnyView(fallbackGlyphContent(agent, size: size))
        }
    } else {
        Text("⌁").font(.system(size: size + 1))
    }
}

@ViewBuilder
func fallbackGlyphContent(_ agent: AgentKind, size: CGFloat) -> some View {
    switch agent {
    case .claude:
        ClaudeBloomGlyph(size: size, color: .orange)
    case .codex:
        CodexBlobGlyph(size: size, color: .white)
    case .antigravity:
        AntigravityGlyph(size: size)
    case .gemini:
        GeminiGlyph(size: size)
    case .copilot:
        CopilotGlyph(size: size)
    case .cursor:
        CursorGlyph(size: size)
    case .opencode:
        OpenCodeGlyph(size: size)
    case .aider:
        AiderGlyph(size: size)
    case .goose:
        GooseGlyph(size: size)
    case .mistral, .deepseek, .kimi, .zcode, .trae, .mimocode, .droid, .qoder, .qwen, .codebuddy, .workbuddy, .kiro, .hermes, .amp, .pi, .ohmypi, .gajae:
        // Bespoke fallback: SF Symbol + brand accent color.
        Image(systemName: agent.symbolName)
            .font(.system(size: size * 0.7, weight: .semibold))
            .foregroundStyle(agent.accentColor)
            .frame(width: size, height: size)
    }
}

struct GlyphBox: View {
    let agent: AgentKind?

    var body: some View {
        RoundedRectangle(cornerRadius: 7)
            .fill(Color.white.opacity(0.1))
            .frame(width: 22, height: 22)
            .overlay(
                glyphContent(agent, size: 10)
                    .foregroundColor(.white)
            )
    }
}

// MARK: - Native interaction feedback

private struct NotchPressStyle: ButtonStyle {
    var pressedScale: CGFloat = 0.97

    func makeBody(configuration: Configuration) -> some View {
        NotchPressedBody(configuration: configuration, pressedScale: pressedScale)
    }
}

private struct NotchPressedBody: View {
    let configuration: ButtonStyle.Configuration
    let pressedScale: CGFloat
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        configuration.label
            .scaleEffect(configuration.isPressed && !reduceMotion ? pressedScale : 1)
            .opacity(configuration.isPressed ? 0.82 : 1)
            .animation(.easeOut(duration: reduceMotion ? 0.01 : 0.11), value: configuration.isPressed)
    }
}

private struct HoverLiftModifier: ViewModifier {
    let cornerRadius: CGFloat
    let strength: Double
    @State private var hovering = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        content
            .background(
                RoundedRectangle(cornerRadius: cornerRadius)
                    .fill(Color.white.opacity(hovering ? strength : 0))
            )
            .scaleEffect(hovering && !reduceMotion ? 1.012 : 1)
            .onHover { hovering = $0 }
            .animation(.easeOut(duration: reduceMotion ? 0.01 : 0.18), value: hovering)
    }
}

private extension View {
    func hoverLift(cornerRadius: CGFloat = 8, strength: Double = 0.055) -> some View {
        modifier(HoverLiftModifier(cornerRadius: cornerRadius, strength: strength))
    }
}

// MARK: - Hover peek (intermediate state)

/// Content for `IslandMode.hover`. Deliberately its own type rather than a
/// reuse of `compactAgentContent`/`compactMediaContent` (both stay
/// unchanged — Compact keeps its narrow left/right-of-notch role): Hover has
/// room to show media *and* session info together rather than choosing one.
private struct HoverPeekView: View {
    let session: AgentSession?
    @ObservedObject var media: MediaController
    /// Extra space to leave empty above the rows on a real notched Mac —
    /// `0` on a non-notched screen, which keeps this exactly as it was
    /// before notch-awareness was added (see
    /// `NotchUIState.hoverTopClearance`'s doc comment for why this exists:
    /// the physical camera housing is opaque, not just a rendering
    /// boundary, so content placed under it is genuinely invisible).
    var topClearance: CGFloat = 0
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Group {
            if topClearance > 0 {
                notchAwareContent
            } else {
                legacyContent
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        // Non-notched (topClearance == 0): vertical-center, exactly as
        // before. Notched: top-anchor — `notchAwareContent` places its own
        // icon band flush with the top instead of relying on padding.
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: topClearance > 0 ? .topLeading : .leading)
    }

    private var legacyContent: some View {
        VStack(alignment: .leading, spacing: 7) {
            if media.isPlaying {
                mediaRow
            }
            if let session {
                sessionRow(session)
            } else if !media.isPlaying {
                emptyRow
            }
        }
    }

    // MARK: - Notch-aware content (real notch only)

    /// On a real (or simulated) notch, the physical camera housing sits at
    /// the top-center and is opaque — a small icon anchored to the pill's
    /// left/right edge clears it (the pill is always widened well past the
    /// notch's own width, see `computeHoverSize`), but full-width content
    /// does not. So: a thin icon band flush with the top (icon left, a
    /// small status accessory right, nothing in the center where the
    /// housing sits), then the info text below it — never media and
    /// session simultaneously, matching how little room a peek should take.
    private var notchAwareContent: some View {
        VStack(alignment: .leading, spacing: 6) {
            iconBand
            primaryInfo
        }
    }

    /// Media gets its own title (marquee-scrolled if it overflows, matching
    /// the previous design) + artist line, since both were legible before
    /// this redesign and truncating the artist away entirely lost real
    /// information. Session/idle stay a single line — there's no
    /// second-line equivalent to a session the way there is a track's artist.
    @ViewBuilder
    private var primaryInfo: some View {
        if media.isPlaying {
            VStack(alignment: .leading, spacing: 0) {
                MarqueeText(text: media.title, size: 12, weight: .semibold, speed: 18)
                    .frame(height: 15)
                Text(media.artist)
                    .font(.system(size: 9, weight: .medium))
                    .foregroundColor(DesignTokens.muted)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
        } else if let session {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(session.title)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(.white)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Spacer(minLength: 4)
                Text(elapsedString(session))
                    .font(.system(size: 9, design: .rounded))
                    .foregroundColor(DesignTokens.muted)
                    .lineLimit(1)
            }
        } else {
            Text(String(localized: "compact.idle", defaultValue: "No active session"))
                .font(.system(size: 12, weight: .semibold))
                .foregroundColor(.white)
                .lineLimit(1)
                .truncationMode(.tail)
        }
    }

    private var iconBand: some View {
        HStack(spacing: 0) {
            leadingGlyph
            Spacer(minLength: 0)
            trailingAccessory
        }
        .frame(height: max(topClearance, 24))
    }

    private var leadingGlyph: some View {
        Group {
            if media.isPlaying, let artwork = media.artwork {
                Image(nsImage: artwork)
                    .resizable()
                    .scaledToFill()
            } else if media.isPlaying {
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(Color.white.opacity(0.1))
                    .overlay(Image(systemName: "music.note").font(.system(size: 10, weight: .medium)))
            } else {
                GlyphBox(agent: session?.agent)
            }
        }
        // Matches `GlyphBox`'s own dimensions (22×22, cornerRadius 7)
        // exactly, instead of re-wrapping it in a differently-sized/rounded
        // frame — avoids a ~1pt double-clip mismatch on the idle path.
        .frame(width: 22, height: 22)
        .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
        .overlay(alignment: .bottomTrailing) {
            if let direction = media.activeSkipDirection {
                skipBadge(direction)
            }
        }
        .animation(.easeOut(duration: reduceMotion ? 0.12 : 0.2), value: media.activeSkipDirection)
    }

    /// A small dark circular badge flashed at the corner of the album art
    /// on a hardware media-key/remote skip press, matching macOS's own
    /// "Now Playing" HUD app-icon-badge convention — auto-clears itself via
    /// `MediaController.activeSkipDirection`, no local timer needed here.
    private func skipBadge(_ direction: SkipDirection) -> some View {
        Image(systemName: direction == .forward ? "forward.fill" : "backward.fill")
            .font(.system(size: 7, weight: .bold))
            .foregroundColor(.white)
            .frame(width: 14, height: 14)
            .background(Circle().fill(Color.black.opacity(0.55)))
            .overlay(Circle().stroke(Color.white.opacity(0.15), lineWidth: 0.5))
            .offset(x: 2, y: 2)
            .transition(.opacity.combined(with: .scale(scale: reduceMotion ? 1 : 0.6)))
    }

    @ViewBuilder
    private var trailingAccessory: some View {
        if media.isPlaying {
            CompactMediaWaveform(isPlaying: true, color: Color(nsColor: media.accentColor))
        } else if let session {
            Circle()
                .fill(statusColor(session.state))
                .frame(width: 6, height: 6)
        } else {
            // Fully idle (no media, no session): keep the icon band
            // left/right-balanced instead of leaving the right side empty.
            Circle()
                .fill(DesignTokens.muted)
                .frame(width: 6, height: 6)
        }
    }

    private var mediaRow: some View {
        HStack(spacing: 8) {
            Group {
                if let artwork = media.artwork {
                    Image(nsImage: artwork)
                        .resizable()
                        .scaledToFill()
                } else {
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(Color.white.opacity(0.1))
                        .overlay(Image(systemName: "music.note").font(.system(size: 10, weight: .medium)))
                }
            }
            .frame(width: 26, height: 26)
            .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
            .overlay(alignment: .bottomTrailing) {
                if let direction = media.activeSkipDirection {
                    skipBadge(direction)
                }
            }
            .animation(.easeOut(duration: reduceMotion ? 0.12 : 0.2), value: media.activeSkipDirection)
            VStack(alignment: .leading, spacing: 0) {
                MarqueeText(text: media.title, size: 10.5, weight: .semibold, speed: 18)
                    .frame(height: 13)
                Text(media.artist)
                    .font(.system(size: 8.5, weight: .medium))
                    .foregroundColor(DesignTokens.muted)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            Spacer(minLength: 4)
            CompactMediaWaveform(isPlaying: media.isPlaying, color: Color(nsColor: media.accentColor))
        }
    }

    private func sessionRow(_ session: AgentSession) -> some View {
        HStack(spacing: 8) {
            GlyphBox(agent: session.agent)
                .fixedSize()
            VStack(alignment: .leading, spacing: 1) {
                Text(cwdTail(session.cwd))
                    .font(.system(size: 8.5, weight: .medium))
                    .foregroundColor(DesignTokens.muted)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Text(session.title)
                    .font(.system(size: 10.5, weight: .semibold))
                    .foregroundColor(.white)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            Spacer(minLength: 4)
            VStack(alignment: .trailing, spacing: 1) {
                HStack(spacing: 5) {
                    Circle()
                        .fill(statusColor(session.state))
                        .frame(width: 6, height: 6)
                    Text(sessionStateLabel(session.state))
                        .font(.system(size: 8.5, weight: .medium))
                        .foregroundColor(DesignTokens.muted)
                        .lineLimit(1)
                }
                Text(elapsedString(session))
                    .font(.system(size: 8.5, design: .rounded))
                    .foregroundColor(DesignTokens.muted)
            }
        }
    }

    private var emptyRow: some View {
        HStack(spacing: 8) {
            GlyphBox(agent: nil)
            Text(String(localized: "compact.idle", defaultValue: "No active session"))
                .font(.system(size: 10.5, weight: .semibold))
                .foregroundColor(.white)
            Spacer(minLength: 0)
        }
    }
}

// MARK: - Agents cell (implemented)

private struct AgentsCell: View {
    @ObservedObject var store: SessionStore
    @ObservedObject var uiState: NotchUIState
    @ObservedObject private var usageStore = AgentUsageStore.shared
    @State private var actionFeedback: String?

    private var selected: AgentSession? {
        if let id = uiState.selectedSessionId, let match = store.sessions.first(where: { $0.id == id }) {
            return match
        }
        return store.sessions.first
    }

    var body: some View {
        cellShape
            .overlay(
                VStack(alignment: .leading, spacing: 6) {
                    if let selected {
                        UsageSummaryBar(agent: selected.agent, snapshot: usageStore.snapshots[selected.agent])
                        sessionList
                            .frame(maxHeight: .infinity)
                        footerRow
                    } else {
                        emptyState
                    }
                }
                .padding(.horizontal, 11)
                .padding(.vertical, 10)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            )
            // `NotchWindowController` grows the panel to fit the session
            // list (see `agentsOpenSize`), but this clip is kept as a
            // defensive backstop: without it, content taller than the
            // panel's animated-in-progress frame (or an unexpectedly long
            // row) overflows the card's rounded-rect visually instead of
            // being contained/scrolled, which is what produced the
            // "floating Terminal button" bug report.
            .clipShape(RoundedRectangle(cornerRadius: 14))
    }

    /// Full vertical list of every tracked session, most-recent/selected
    /// first. Only the selected row expands to show the last user message
    /// and current activity; the rest stay single-line so several sessions
    /// fit without crowding the notch. Scrolls when they don't all fit.
    private var sessionList: some View {
        ScrollView(.vertical, showsIndicators: false) {
            VStack(alignment: .leading, spacing: 4) {
                ForEach(store.sessions) { session in
                    sessionRow(session, isSelected: session.id == selected?.id)
                }
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 7) {
            Label(String(localized: "agents.watchingForActivity", defaultValue: "Watching for agent activity"), systemImage: "antenna.radiowaves.left.and.right")
                .font(.system(size: 12, weight: .semibold))
                .foregroundColor(.white.opacity(0.88))
            Text(String(localized: "agents.watchingForActivityDetail", defaultValue: "Claude Code, Codex and compatible CLIs appear here automatically."))
                .font(.system(size: 10))
                .foregroundColor(DesignTokens.muted)
                .multilineTextAlignment(.center)
                .lineLimit(2)
            HStack(spacing: 6) {
                agentChip(String(localized: "agents.chip.claudeCode", defaultValue: "Claude Code"), symbol: "sparkle")
                agentChip(String(localized: "agents.chip.codex", defaultValue: "Codex"), symbol: "chevron.left.forwardslash.chevron.right")
                agentChip(String(localized: "agents.chip.terminal", defaultValue: "Terminal"), symbol: "terminal")
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityElement(children: .combine)
    }

    private func agentChip(_ title: String, symbol: String) -> some View {
        Label(title, systemImage: symbol)
            .font(.system(size: 9.5, weight: .medium))
            .foregroundColor(.white.opacity(0.62))
            .padding(.horizontal, 8)
            .frame(height: 24)
            .background(Capsule().fill(Color.white.opacity(0.055)))
    }

    private var cellShape: some View {
        RoundedRectangle(cornerRadius: 14)
            .fill(.ultraThinMaterial)
            .overlay(RoundedRectangle(cornerRadius: 14).fill(Color.black.opacity(0.34)))
            .overlay(
                RoundedRectangle(cornerRadius: 14)
                    .stroke(Color.white.opacity(0.055), lineWidth: 1)
            )
    }

    /// One row per tracked session. Selected/first row expands to show the
    /// last user activity (`agents.lastMessage`); the rest stay compact,
    /// title-only rows with an agent badge and elapsed time — mirrors the
    /// competitor reference layout of a single always-visible session list.
    private func sessionRow(_ session: AgentSession, isSelected: Bool) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 8) {
                RoundedRectangle(cornerRadius: 7)
                    .fill(Color.white.opacity(0.09))
                    .frame(width: isSelected ? 26 : 22, height: isSelected ? 26 : 22)
                    .overlay(
                        glyphContent(session.agent, size: isSelected ? 10 : 9)
                            .foregroundColor(.white)
                    )
                Circle().fill(statusColor(session.state)).frame(width: 6, height: 6)
                Text(session.title)
                    .font(.system(size: isSelected ? 11.5 : 11, weight: .semibold))
                    .foregroundColor(.white)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .layoutPriority(1)
                Spacer(minLength: 4)
                if !isSelected, let percent = session.contextUsedPercent {
                    compactContextBadge(percent)
                }
                agentBadge(session.agent)
                Text(elapsedString(session))
                    .font(.system(size: 9, design: .rounded))
                    .foregroundColor(.white.opacity(0.5))
                    .frame(minWidth: 22, alignment: .trailing)
            }
            if isSelected {
                HStack(spacing: 6) {
                    Text(String(localized: "agents.agentAndCwd", defaultValue: "\(session.agent.displayName) · \(cwdTail(session.cwd))"))
                        .font(.system(size: 9))
                        .foregroundColor(DesignTokens.muted)
                        .lineLimit(1)
                        .truncationMode(.tail)
                    if let percent = session.contextUsedPercent {
                        Spacer(minLength: 4)
                        contextUsageLabel(percent)
                    }
                }
                .padding(.leading, 34)
                HStack(spacing: 6) {
                    Text(session.lastMessage)
                        .font(.system(size: 10))
                        .foregroundColor(.white.opacity(0.68))
                        .lineLimit(1)
                        .truncationMode(.tail)
                    Spacer(minLength: 0)
                    if let actionFeedback {
                        Text(actionFeedback)
                            .font(.system(size: 8.5))
                            .foregroundColor(DesignTokens.muted)
                            .lineLimit(1)
                    }
                }
                .padding(.leading, 34)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, isSelected ? 6 : 5)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(Color.white.opacity(isSelected ? 0.065 : 0.03))
        )
        .contentShape(Rectangle())
        .hoverLift(cornerRadius: 10, strength: 0.04)
        .onTapGesture(count: 2) {
            SoundPlayer.shared.play(.navigation)
            Jumper.jump(to: session)
        }
        .onTapGesture(count: 1) {
            guard !isSelected else { return }
            SoundPlayer.shared.play(.navigation)
            withAnimation(DesignTokens.scaledContentTransition()) {
                uiState.selectedSessionId = session.id
            }
        }
        .help(String(localized: "agents.doubleClickToReturn", defaultValue: "Double-click to return to \(session.agent.displayName)"))
    }

    /// Rounded-pill agent-name badge, matching the reference design's
    /// per-row "Claude"/"Codex"/"Gemini" pill. Terminal-app badges are
    /// omitted: `AgentSession` doesn't currently carry which terminal a
    /// session is running in, so adding that pairing is left for later.
    /// Color for a context-window usage percentage, matching `UsageBar`'s
    /// green/orange/red thresholds elsewhere in the notch.
    private func contextUsageColor(_ percent: Double) -> Color {
        let clamped = min(max(percent, 0), 100)
        if clamped >= 95 { return DesignTokens.red }
        if clamped >= 80 { return DesignTokens.orange }
        return DesignTokens.green
    }

    /// Tiny "NN%" tag shown on compact (non-selected) session rows when
    /// `contextUsedPercent` is available, kept minimal to avoid crowding
    /// the single-line layout.
    private func compactContextBadge(_ percent: Double) -> some View {
        let clamped = min(max(percent, 0), 100)
        return Text("\(Int(clamped.rounded()))%")
            .font(.system(size: 7.5, weight: .semibold, design: .rounded))
            .foregroundColor(contextUsageColor(percent))
            .frame(minWidth: 18, alignment: .trailing)
            .accessibilityLabel(String(localized: "agents.contextUsedPercentAccessibility", defaultValue: "Context window \(Int(clamped.rounded())) percent used"))
    }

    /// "Context NN%" label shown in the expanded selected-session row.
    private func contextUsageLabel(_ percent: Double) -> some View {
        let clamped = min(max(percent, 0), 100)
        return Text(String(localized: "agents.contextUsedPercent", defaultValue: "Context \(Int(clamped.rounded()))%"))
            .font(.system(size: 8.5, weight: .medium))
            .foregroundColor(contextUsageColor(percent))
            .lineLimit(1)
    }

    private func agentBadge(_ agent: AgentKind) -> some View {
        Text(agent.displayName)
            .font(.system(size: 8.5, weight: .semibold))
            .foregroundColor(agent.accentColor)
            .padding(.horizontal, 6)
            .frame(height: 16)
            .background(Capsule().fill(agent.accentColor.opacity(0.16)))
            .lineLimit(1)
    }

    private var footerRow: some View {
        HStack(spacing: 4) {
            Spacer(minLength: 4)
            if let selected, selected.isManagedProcess {
                MiniButton(
                    title: selected.state == .idle ? String(localized: "agents.action.resume", defaultValue: "Resume") : String(localized: "agents.action.pause", defaultValue: "Pause"),
                    icon: selected.state == .idle ? "play.fill" : "pause.fill",
                    helpText: selected.state == .idle ? String(localized: "agents.action.resumeHelp", defaultValue: "Resume the managed process") : String(localized: "agents.action.pauseHelp", defaultValue: "Pause the managed process")
                ) {
                    let action: ManagedSessionAction = selected.state == .idle ? .resume : .pause
                    actionFeedback = store.controlManagedSession(id: selected.id, action: action) ? nil : String(localized: "agents.action.controlFailed", defaultValue: "Could not control process")
                }
                MiniButton(title: String(localized: "agents.action.stop", defaultValue: "Stop"), icon: "stop.fill", isDanger: true, helpText: String(localized: "agents.action.stopHelp", defaultValue: "Stop the managed process")) {
                    actionFeedback = store.controlManagedSession(id: selected.id, action: .stop) ? String(localized: "agents.action.stopping", defaultValue: "Stopping…") : String(localized: "agents.action.stopFailed", defaultValue: "Could not stop process")
                }
            }
            MiniButton(title: String(localized: "agents.action.terminal", defaultValue: "Terminal"), icon: "terminal", helpText: String(localized: "agents.action.terminalHelp", defaultValue: "Return to Terminal")) {
                if let selected {
                    Jumper.jump(to: selected)
                }
            }
        }
    }

}

private struct MiniButton: View {
    let title: String
    var icon: String? = nil
    var shortcut: String? = nil
    var isDanger: Bool = false
    var isPrimary: Bool = false
    var helpText: String? = nil
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button {
            SoundPlayer.shared.play(.action)
            action()
        } label: {
            HStack(spacing: 4) {
                if let icon { Image(systemName: icon).font(.system(size: 8, weight: .semibold)) }
                Text(title)
                if let shortcut {
                    Text(shortcut).foregroundColor(textColor.opacity(0.55))
                }
            }
            .font(.system(size: 10.5, weight: isPrimary ? .semibold : .regular))
            .foregroundColor(textColor)
            .padding(.horizontal, 8)
            .frame(height: 30)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(backgroundColor)
            )
        }
        .buttonStyle(NotchPressStyle())
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.18), value: hovering)
        .help(helpText ?? title)
    }

    private var textColor: Color {
        if isPrimary { return .black }
        if isDanger { return Color(red: 0xF0 / 255, green: 0xA0 / 255, blue: 0x9B / 255) }
        return .white.opacity(0.72)
    }

    private var backgroundColor: Color {
        if isPrimary { return Color(white: hovering ? 1 : 0.965) }
        if isDanger { return DesignTokens.red.opacity(hovering ? 0.22 : 0.13) }
        return Color.white.opacity(hovering ? 0.14 : 0.085)
    }
}

// MARK: - Nook pages

private struct CellSurface<Content: View>: View {
    let content: Content
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    var body: some View {
        RoundedRectangle(cornerRadius: 14)
            .fill(reduceTransparency ? AnyShapeStyle(Color(white: 0.075)) : AnyShapeStyle(.ultraThinMaterial))
            .overlay(RoundedRectangle(cornerRadius: 14).fill(Color.black.opacity(reduceTransparency ? 0 : 0.32)))
            .overlay(RoundedRectangle(cornerRadius: 14).stroke(Color.white.opacity(0.065), lineWidth: 0.75))
            .overlay(content.padding(7))
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
    }
}

private struct MediaCell: View {
    @ObservedObject var media: MediaController

    var body: some View {
        CellSurface {
            HStack(spacing: 10) {
                ZStack {
                    RoundedRectangle(cornerRadius: 12)
                        .fill(LinearGradient(colors: [.purple.opacity(0.75), .blue.opacity(0.55), .black], startPoint: .topLeading, endPoint: .bottomTrailing))
                    if let artwork = media.artwork {
                        Image(nsImage: artwork)
                            .resizable()
                            .scaledToFill()
                    } else {
                        Image(systemName: media.hasMedia ? "waveform" : "music.note")
                            .font(.system(size: 21, weight: .light))
                            .foregroundColor(.white.opacity(0.82))
                    }
                }
                .frame(width: 58, height: 58)
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).stroke(Color.white.opacity(0.08), lineWidth: 0.5))
                VStack(alignment: .leading, spacing: 5) {
                    MarqueeText(text: media.title, size: 12, weight: .semibold, speed: 24)
                        .frame(height: 16)
                        .help(media.title)
                    Text(media.artist)
                        .font(.system(size: 10))
                        .foregroundColor(DesignTokens.muted)
                        .lineLimit(1)
                        .help(media.artist)
                    ProgressView(value: media.progress)
                        .progressViewStyle(.linear)
                        .tint(Color(nsColor: media.accentColor))
                        .accessibilityLabel(String(localized: "media.playbackProgress", defaultValue: "Playback progress"))
                        .accessibilityValue(timeLabel)
                    HStack {
                        if media.hasMedia {
                            MediaControlButton(icon: "backward.fill", help: String(localized: "media.previous", defaultValue: "Previous"), action: media.previous)
                            MediaControlButton(icon: media.isPlaying ? "pause.fill" : "play.fill", help: media.isPlaying ? String(localized: "media.pause", defaultValue: "Pause") : String(localized: "media.play", defaultValue: "Play"), prominent: true, action: media.togglePlayback)
                            MediaControlButton(icon: "forward.fill", help: String(localized: "media.next", defaultValue: "Next"), action: media.next)
                        } else {
                            Button {
                                SoundPlayer.shared.play(.action)
                                media.refresh()
                            } label: {
                                Label(String(localized: "media.checkNowPlaying", defaultValue: "Check Now Playing"), systemImage: "arrow.clockwise")
                                    .font(.system(size: 8.5, weight: .medium))
                                    .padding(.horizontal, 9)
                                    .frame(height: 24)
                                    .background(RoundedRectangle(cornerRadius: 8).fill(Color.white.opacity(0.09)))
                            }
                            .buttonStyle(NotchPressStyle())
                            .hoverLift(cornerRadius: 8)
                            .help(String(localized: "media.checkNowPlayingHelp", defaultValue: "Check the current macOS media session"))
                        }
                        Spacer()
                        Text(media.hasMedia ? timeLabel : (media.isConnected ? media.source : String(localized: "media.unavailable", defaultValue: "Unavailable")))
                            .font(.system(size: 9, design: .rounded))
                            .foregroundColor(DesignTokens.muted)
                        if media.hasMedia {
                            Text(media.source)
                                .font(.system(size: 9))
                                .foregroundColor(DesignTokens.muted)
                                .lineLimit(1)
                                .help(media.source)
                        }
                    }
                    .font(.system(size: 11))
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .foregroundColor(.white)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
        }
    }

    private var timeLabel: String {
        guard media.hasMedia, media.duration > 1 else { return String(localized: "media.positionUnavailable", defaultValue: "Position unavailable") }
        func format(_ seconds: Double) -> String {
            let value = max(Int(seconds.rounded()), 0)
            return String(format: "%d:%02d", value / 60, value % 60)
        }
        return "\(format(media.position)) / \(format(media.duration))"
    }
}

private struct CompactMediaWaveform: View {
    let isPlaying: Bool
    let color: Color
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        TimelineView(.animation(minimumInterval: 0.16, paused: reduceMotion || !isPlaying)) { context in
            let phase = context.date.timeIntervalSinceReferenceDate * 5.5
            HStack(alignment: .center, spacing: 2) {
                ForEach(0..<4, id: \.self) { index in
                    let level = reduceMotion ? 0.45 : 0.35 + abs(sin(phase + Double(index) * 1.35)) * 0.65
                    Capsule()
                        .fill(color.opacity(index == 2 ? 1 : 0.72))
                        .frame(width: 2, height: 4 + 9 * level)
                }
            }
            .frame(width: 16, height: 16)
            .shadow(color: color.opacity(0.3), radius: 3)
        }
        .accessibilityHidden(true)
    }
}

private struct MarqueeText: View {
    let text: String
    let size: CGFloat
    let weight: Font.Weight
    let speed: CGFloat
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private let leadingPause: TimeInterval = 1.1
    @State private var startDate = Date()

    var body: some View {
        GeometryReader { proxy in
            let textWidth = measuredWidth
            let overflow = max(textWidth - proxy.size.width, 0)
            let overflows = overflow > 1
            TimelineView(.animation(minimumInterval: 1 / 30, paused: reduceMotion || !overflows)) { context in
                let offset = marqueeOffset(at: context.date, overflow: overflow)

                label
                    .offset(x: overflows && !reduceMotion ? -offset : 0)
                    .frame(maxHeight: .infinity, alignment: .center)
            }
        }
        .clipped()
        .onChange(of: text) { _, _ in startDate = Date() }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(text)
    }

    private var label: some View {
        Text(text)
            .font(.system(size: size, weight: weight))
            .foregroundColor(.white)
            .lineLimit(1)
            .fixedSize(horizontal: true, vertical: false)
    }

    private func marqueeOffset(at date: Date, overflow: CGFloat) -> CGFloat {
        let movingDuration = TimeInterval(overflow / speed)
        let endPause: TimeInterval = 0.8
        let cycle = max(leadingPause + movingDuration + endPause + movingDuration, 0.1)
        let elapsed = date.timeIntervalSince(startDate).truncatingRemainder(dividingBy: cycle)
        if elapsed <= leadingPause { return 0 }
        if elapsed <= leadingPause + movingDuration {
            return CGFloat(elapsed - leadingPause) * speed
        }
        if elapsed <= leadingPause + movingDuration + endPause { return overflow }
        let returnElapsed = elapsed - leadingPause - movingDuration - endPause
        return max(overflow - CGFloat(returnElapsed) * speed, 0)
    }

    private var measuredWidth: CGFloat {
        let appKitWeight: NSFont.Weight
        switch weight {
        case .bold: appKitWeight = .bold
        case .semibold: appKitWeight = .semibold
        case .medium: appKitWeight = .medium
        default: appKitWeight = .regular
        }
        return (text as NSString).size(withAttributes: [.font: NSFont.systemFont(ofSize: size, weight: appKitWeight)]).width
    }
}

private struct MediaControlButton: View {
    let icon: String
    let help: String
    var prominent = false
    let action: () -> Void

    var body: some View {
        Button {
            SoundPlayer.shared.play(.action)
            action()
        } label: {
            Image(systemName: icon)
                .frame(width: prominent ? 32 : 28, height: 30)
                .background(Circle().fill(Color.white.opacity(prominent ? 0.11 : 0)))
        }
        .buttonStyle(NotchPressStyle())
        .hoverLift(cornerRadius: 11, strength: 0.08)
        .help(help)
    }
}

private struct TodayCell: View {
    @StateObject private var model = TodayModel()
    @Binding var focusEndsAt: Date?

    var body: some View {
        CellSurface {
            TimelineView(.periodic(from: .now, by: 1)) { context in
                let remaining = focusEndsAt.map { max(Int($0.timeIntervalSince(context.date)), 0) }
                if model.canReadCalendar {
                    calendarContent(remaining: remaining)
                } else {
                    calendarPermissionContent(remaining: remaining)
                }
            }
            .foregroundColor(.white)
        }
        .onAppear { model.refresh() }
    }

    private func calendarContent(remaining: Int?) -> some View {
        HStack(spacing: 14) {
            VStack(spacing: 1) {
                Text(Date.now.formatted(.dateTime.day()))
                    .font(.system(size: 34, weight: .light, design: .rounded))
                Text(Date.now.formatted(.dateTime.month(.abbreviated).weekday(.abbreviated)).uppercased())
                    .font(.system(size: 9.5, weight: .semibold))
                    .tracking(0.5)
                    .foregroundColor(DesignTokens.muted)
            }
            .frame(width: 76)
            Divider().overlay(DesignTokens.line)
            VStack(alignment: .leading, spacing: 7) {
                if model.events.isEmpty {
                    Label(String(localized: "today.noMoreEventsToday", defaultValue: "No more events today"), systemImage: "calendar.badge.checkmark")
                        .font(.system(size: 10.5, weight: .medium))
                        .foregroundColor(.white.opacity(0.72))
                } else {
                    ForEach(model.events.prefix(2)) { event in
                        ScheduleRow(
                            time: event.startDate.formatted(date: .omitted, time: .shortened),
                            title: event.title,
                            detail: event.calendar
                        )
                    }
                }
                Spacer(minLength: 0)
                focusButton(remaining: remaining, prominent: false)
            }
        }
    }

    private func calendarPermissionContent(remaining: Int?) -> some View {
        VStack(spacing: 8) {
            Label(remaining == nil || remaining == 0 ? String(localized: "today.focusFor25Minutes", defaultValue: "Focus for 25 minutes") : String(localized: "today.focusIsActive", defaultValue: "Focus is active"), systemImage: remaining == nil || remaining == 0 ? "moon.stars.fill" : "timer")
                .font(.system(size: 12, weight: .semibold))
            Text(remaining == nil || remaining == 0 ? String(localized: "today.focusLocalTimerDescription", defaultValue: "A local timer keeps the current task in view.") : String(localized: "today.focusContinuesDescription", defaultValue: "The timer continues when you switch views or close the Nook."))
                .font(.system(size: 10))
                .foregroundColor(DesignTokens.muted)
                .multilineTextAlignment(.center)
            focusButton(remaining: remaining, prominent: true)
            Button {
                SoundPlayer.shared.play(.action)
                model.requestAccess()
            } label: {
                Label(String(localized: "today.showCalendarEvents", defaultValue: "Show today's Calendar events"), systemImage: "calendar.badge.plus")
                    .font(.system(size: 10, weight: .medium))
                    .padding(.horizontal, 10)
                    .frame(height: 28)
                    .background(RoundedRectangle(cornerRadius: 8).fill(Color.white.opacity(0.06)))
            }
            .buttonStyle(NotchPressStyle())
            .hoverLift(cornerRadius: 8)
            .accessibilityIdentifier("today.enable-calendar")
            .help(String(localized: "today.allowAccessHelp", defaultValue: "Allow access to today's events"))
            if let error = model.errorMessage {
                Text(error)
                    .font(.system(size: 9.5))
                    .foregroundColor(DesignTokens.red)
                    .lineLimit(1)
                    .help(error)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func focusButton(remaining: Int?, prominent: Bool) -> some View {
        Button {
            SoundPlayer.shared.play(.action)
            focusEndsAt = remaining == nil || remaining == 0 ? Date().addingTimeInterval(25 * 60) : nil
        } label: {
            Label(focusLabel(remaining), systemImage: remaining == nil || remaining == 0 ? "moon.fill" : "stop.fill")
                .font(.system(size: 10.5, weight: .semibold))
                .padding(.horizontal, 12)
                .frame(height: prominent ? 32 : 30)
                .background(RoundedRectangle(cornerRadius: 9).fill(Color.white.opacity(prominent ? 0.14 : 0.09)))
        }
        .buttonStyle(NotchPressStyle())
        .hoverLift(cornerRadius: 9)
        .accessibilityIdentifier("today.focus")
        .help(remaining == nil || remaining == 0 ? String(localized: "today.startFocusHelp", defaultValue: "Start a 25 minute local focus timer") : String(localized: "today.endFocus", defaultValue: "End Focus"))
    }

    private func focusLabel(_ remaining: Int?) -> String {
        guard let remaining, remaining > 0 else { return String(localized: "today.startFocus", defaultValue: "Start Focus") }
        let format = String(localized: "today.endFocusWithTime", defaultValue: "End Focus · %02d:%02d")
        return String(format: format, remaining / 60, remaining % 60)
    }
}

private struct ScheduleRow: View {
    let time: String
    let title: String
    let detail: String
    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Text(time).font(.system(size: 9.5, design: .monospaced)).foregroundColor(DesignTokens.muted).frame(width: 38, alignment: .leading)
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(.system(size: 10.5, weight: .semibold)).lineLimit(1)
                Text(detail).font(.system(size: 9.5)).foregroundColor(DesignTokens.muted).lineLimit(1)
            }
        }
    }
}

private struct SystemCell: View {
    @StateObject private var monitor = SystemMonitor()
    @StateObject private var background = BackgroundActivityMonitor()

    var body: some View {
        CellSurface {
            VStack(spacing: 5) {
                if let activity = background.activities.first {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack(spacing: 10) {
                            Image(systemName: activity.symbol)
                                .font(.system(size: 20, weight: .medium))
                                .foregroundColor(.white.opacity(0.82))
                                .frame(width: 34, height: 34)
                                .background(RoundedRectangle(cornerRadius: 9).fill(Color.white.opacity(0.07)))
                            VStack(alignment: .leading, spacing: 3) {
                                Text(activity.title).font(.system(size: 12, weight: .semibold))
                                Text(activity.detail).font(.system(size: 10)).foregroundColor(DesignTokens.muted).lineLimit(1)
                            }
                            Spacer()
                            ProgressView().controlSize(.small).tint(.white.opacity(0.8))
                        }
                        HStack {
                            Label(String(localized: "system.runningInBackground", defaultValue: "Running in background"), systemImage: "clock.arrow.circlepath")
                                .font(.system(size: 9.5, weight: .medium))
                                .foregroundColor(.white.opacity(0.58))
                            if background.activities.count > 1 {
                                Text(String(localized: "system.moreActivities", defaultValue: "+\(String(background.activities.count - 1)) more"))
                                    .font(.system(size: 9.5, weight: .medium))
                                    .foregroundColor(DesignTokens.muted)
                            }
                            Spacer()
                            activityMonitorButton
                        }
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 10)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(RoundedRectangle(cornerRadius: 11).fill(Color.white.opacity(0.055)))
                    .help(activity.detail)
                } else {
                    HStack(spacing: 6) {
                        SystemActionCard(
                            icon: monitor.isCharging ? "battery.100percent.bolt" : "battery.75percent",
                            title: monitor.batteryLevel == nil ? String(localized: "system.power", defaultValue: "Power") : String(localized: "system.battery", defaultValue: "Battery"),
                            value: monitor.batteryLevel.map { "\($0)%" } ?? String(localized: "system.acPower", defaultValue: "AC power"),
                            detail: monitor.batteryLevel == nil ? String(localized: "system.noBatteryDetected", defaultValue: "No battery detected") : batteryDetail
                        ) { openSystemSettings("x-apple.systempreferences:com.apple.Battery-Settings.extension") }
                        SystemActionCard(icon: "memorychip", title: String(localized: "system.memory", defaultValue: "Memory"), value: monitor.memoryUsed, detail: monitor.memoryDetail) {
                            NSWorkspace.shared.open(URL(fileURLWithPath: "/System/Applications/Utilities/Activity Monitor.app"))
                        }
                        SystemActionCard(icon: "externaldrive", title: String(localized: "system.freeStorage", defaultValue: "Free storage"), value: monitor.storageAvailable, detail: monitor.storageDetail) {
                            openSystemSettings("x-apple.systempreferences:com.apple.settings.Storage")
                        }
                    }
                    HStack(spacing: 7) {
                        Image(systemName: "checkmark.circle")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundColor(.white.opacity(0.55))
                        VStack(alignment: .leading, spacing: 1) {
                            Text(String(localized: "system.noActiveBackgroundWork", defaultValue: "No active background work"))
                                .font(.system(size: 10.5, weight: .medium))
                            Text(String(localized: "system.noActiveBackgroundWorkDetail", defaultValue: "Builds, Git transfers and downloads appear here"))
                                .font(.system(size: 9.5))
                                .foregroundColor(DesignTokens.muted)
                        }
                        Spacer()
                        activityMonitorButton
                    }
                    .padding(.horizontal, 8)
                    .frame(height: 36)
                    .background(RoundedRectangle(cornerRadius: 9).fill(Color.white.opacity(0.045)))
                }
            }.foregroundColor(.white)
        }
    }

    private var batteryDetail: String {
        guard let remaining = monitor.timeRemainingLabel else {
            return monitor.isCharging ? String(localized: "system.charging", defaultValue: "Charging") : String(localized: "system.openSettings", defaultValue: "Open settings")
        }
        return monitor.isCharging ? String(localized: "system.chargingRemaining", defaultValue: "Charging · \(remaining) remaining") : String(localized: "system.remaining", defaultValue: "\(remaining) remaining")
    }

    private var activityMonitorButton: some View {
        Button {
            NSWorkspace.shared.open(URL(fileURLWithPath: "/System/Applications/Utilities/Activity Monitor.app"))
        } label: {
            Label(String(localized: "system.activityMonitor", defaultValue: "Activity Monitor"), systemImage: "gauge.with.dots.needle.50percent")
                .font(.system(size: 9.5, weight: .medium))
                .padding(.horizontal, 10)
                .frame(height: 30)
                .background(RoundedRectangle(cornerRadius: 8).fill(Color.white.opacity(0.075)))
        }
        .buttonStyle(NotchPressStyle())
        .hoverLift(cornerRadius: 8)
        .accessibilityIdentifier("system.activity-monitor")
    }

    private func openSystemSettings(_ rawURL: String) {
        guard let url = URL(string: rawURL) else { return }
        NSWorkspace.shared.open(url)
    }
}

private struct SystemStatus: View {
    let icon: String, title: String, value: String
    var body: some View {
        HStack(spacing: 7) {
            Image(systemName: icon).font(.system(size: 9.5)).foregroundColor(.white.opacity(0.7))
            Text(title).font(.system(size: 8)).foregroundColor(DesignTokens.muted)
            Spacer()
            Text(value).font(.system(size: 8.5, weight: .medium)).lineLimit(1)
        }
        .padding(.horizontal, 8)
        .frame(height: 25)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.white.opacity(0.045)))
    }
}

private struct SystemActionCard: View {
    let icon: String, title: String, value: String, detail: String
    let action: () -> Void
    var body: some View {
        Button {
            SoundPlayer.shared.play(.action)
            action()
        } label: {
            HStack(spacing: 7) {
                Image(systemName: icon).font(.system(size: 12)).foregroundColor(.white.opacity(0.76))
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.system(size: 9.5)).foregroundColor(DesignTokens.muted)
                    Text(value).font(.system(size: 11, weight: .semibold)).lineLimit(1)
                    Text(detail).font(.system(size: 9)).foregroundColor(.white.opacity(0.46)).lineLimit(1)
                }
                Spacer(minLength: 0)
                Image(systemName: "chevron.right")
                    .font(.system(size: 8, weight: .semibold))
                    .foregroundColor(.white.opacity(0.24))
            }
            .padding(.horizontal, 9)
            .frame(maxWidth: .infinity, minHeight: 48)
            .background(RoundedRectangle(cornerRadius: 10).fill(Color.white.opacity(0.055)))
        }
        .buttonStyle(NotchPressStyle())
        .hoverLift(cornerRadius: 10)
        .help(String(localized: "system.openDetailsHelp", defaultValue: "Open \(title) details"))
    }
}

private struct TaskProgress: View {
    let icon: String, title: String, progress: Double, detail: String
    var body: some View {
        HStack(spacing: 7) {
            Image(systemName: icon).font(.system(size: 9.5)).frame(width: 14).foregroundColor(.white.opacity(0.72))
            VStack(alignment: .leading, spacing: 2) {
                HStack { Text(title).font(.system(size: 8.5, weight: .medium)).lineLimit(1); Spacer(); Text(detail).font(.system(size: 6.5)).foregroundColor(DesignTokens.muted) }
                ProgressView(value: progress).progressViewStyle(.linear).tint(.white.opacity(0.72))
            }
        }
        .frame(height: 25)
    }
}

private struct TrayItem: Identifiable {
    let id = UUID()
    let url: URL
}

private enum TrayAction { case choose, open, reveal, airDrop, compress, copyPath, attach, removeSelected, removeItem(UUID), clear, undo }

private struct TrayCell: View {
    @Binding var items: [TrayItem]
    @Binding var selectedItemID: UUID?
    let isTargeted: Bool
    let feedback: String?
    let canUndo: Bool
    let action: (TrayAction) -> Void

    var body: some View {
        CellSurface {
            VStack(spacing: 8) {
                trayShelf
                HStack(spacing: 6) {
                    Text(statusLabel)
                        .font(.system(size: 10, weight: .medium))
                        .foregroundColor(.white.opacity(0.68))
                        .lineLimit(1)
                        .truncationMode(.middle)
                    if let feedback {
                        Text(feedback)
                            .font(.system(size: 9.5))
                            .foregroundColor(DesignTokens.muted)
                            .lineLimit(1)
                    }
                    if canUndo {
                        Button(String(localized: "tray.undo", defaultValue: "Undo")) { action(.undo) }
                            .buttonStyle(.plain)
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundColor(.white.opacity(0.86))
                            .accessibilityIdentifier("tray.undo")
                    }
                    Spacer(minLength: 4)
                    if items.isEmpty {
                        TrayButton(String(localized: "tray.chooseFiles", defaultValue: "Choose Files"), "plus", action: { action(.choose) })
                    } else {
                        TrayButton(String(localized: "tray.open", defaultValue: "Open"), "arrow.up.forward.app", action: { action(.open) })
                        TrayButton(String(localized: "tray.finder", defaultValue: "Finder"), "folder", action: { action(.reveal) })
                        TrayButton(String(localized: "tray.airDrop", defaultValue: "AirDrop"), "airplayaudio", action: { action(.airDrop) })
                        TrayButton(String(localized: "tray.copyForAgent", defaultValue: "Copy for Agent"), "paperclip", action: { action(.attach) })
                        Menu {
                            Button(String(localized: "tray.compress", defaultValue: "Compress"), systemImage: "archivebox") { action(.compress) }
                            Button(String(localized: "tray.copyPath", defaultValue: "Copy Path"), systemImage: "doc.on.doc") { action(.copyPath) }
                            Divider()
                            Button(String(localized: "tray.removeSelected", defaultValue: "Remove Selected"), systemImage: "minus.circle", role: .destructive) { action(.removeSelected) }
                            Button(String(localized: "tray.clearAll", defaultValue: "Clear All"), systemImage: "trash", role: .destructive) {
                                SoundPlayer.shared.play(.deny)
                                action(.clear)
                            }
                        } label: {
                            Image(systemName: "ellipsis")
                                .frame(width: 30, height: 30)
                                .background(RoundedRectangle(cornerRadius: 8).fill(Color.white.opacity(0.08)))
                        }
                        .menuStyle(.borderlessButton)
                        .menuIndicator(.hidden)
                        .help(String(localized: "tray.moreFileActionsHelp", defaultValue: "More file actions"))
                    }
                }
            }.foregroundColor(.white)
        }
    }

    private var statusLabel: String {
        guard !items.isEmpty else { return String(localized: "tray.isEmpty", defaultValue: "Tray is empty") }
        guard let selectedItemID,
              let selected = items.first(where: { $0.id == selectedItemID }) else {
            return String(localized: "tray.itemCount", defaultValue: "\(String(items.count)) item\(items.count == 1 ? "" : "s")")
        }
        return String(localized: "tray.selectedItemCount", defaultValue: "\(selected.url.lastPathComponent) · \(String(items.count)) item\(items.count == 1 ? "" : "s")")
    }

    @ViewBuilder
    private var trayShelf: some View {
        if items.isEmpty {
            Button {
                action(.choose)
            } label: {
                RoundedRectangle(cornerRadius: 13)
                    .strokeBorder(Color.white.opacity(isTargeted ? 0.58 : 0.18), style: StrokeStyle(lineWidth: 1.2, dash: [5, 5]))
                    .background(RoundedRectangle(cornerRadius: 13).fill(Color.white.opacity(isTargeted ? 0.08 : 0.025)))
                    .overlay(
                        HStack(spacing: 11) {
                            Image(systemName: "tray.and.arrow.down.fill")
                                .font(.system(size: 21, weight: .medium))
                            VStack(alignment: .leading, spacing: 3) {
                                Text(String(localized: "tray.dropFilesHere", defaultValue: "Drop files here"))
                                    .font(.system(size: 12, weight: .semibold))
                                Text(String(localized: "tray.clickToChoose", defaultValue: "or click to choose from Finder"))
                                    .font(.system(size: 8.5))
                                    .foregroundColor(DesignTokens.muted)
                            }
                        }
                    )
            }
            .buttonStyle(NotchPressStyle())
            .help(String(localized: "tray.addFilesHelp", defaultValue: "Add files to the temporary Tray"))
        } else {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(items) { item in
                        // The card (select/open/drag-out) and the remove
                        // button used to share the same corner with only a
                        // 4pt offset between them, so a slightly imprecise
                        // click on one could trigger the other (e.g. trying
                        // to grab the remove "x" instead starting a drag).
                        // Reserving top/trailing padding around the card
                        // gives the "x" its own dead zone outside the card's
                        // hit-test bounds instead of overlapping it.
                        ZStack(alignment: .topTrailing) {
                            Button {
                                selectedItemID = item.id
                            } label: {
                                VStack(spacing: 5) {
                                    Image(nsImage: NSWorkspace.shared.icon(forFile: item.url.path))
                                        .resizable()
                                        .scaledToFit()
                                        .frame(width: 42, height: 42)
                                    Text(item.url.lastPathComponent)
                                        .font(.system(size: 9.5, weight: .medium))
                                        .lineLimit(1)
                                        .truncationMode(.middle)
                                        .frame(width: 68)
                                }
                                .padding(.horizontal, 7)
                                .padding(.vertical, 8)
                                .background(
                                    RoundedRectangle(cornerRadius: 11)
                                        .fill(Color.white.opacity(selectedItemID == item.id ? 0.14 : 0.055))
                                )
                                .overlay(
                                    RoundedRectangle(cornerRadius: 11)
                                        .stroke(Color.white.opacity(selectedItemID == item.id ? 0.20 : 0.04), lineWidth: 1)
                                )
                            }
                            .buttonStyle(NotchPressStyle())
                            .help(item.url.path)
                            .simultaneousGesture(TapGesture(count: 2).onEnded { NSWorkspace.shared.open(item.url) })
                            .onDrag {
                                selectedItemID = item.id
                                return NSItemProvider(contentsOf: item.url) ?? NSItemProvider()
                            }
                            .padding(.top, 7)
                            .padding(.trailing, 7)

                            Button {
                                action(.removeItem(item.id))
                            } label: {
                                Image(systemName: "xmark.circle.fill")
                                    .font(.system(size: 13, weight: .medium))
                                    .foregroundColor(.white.opacity(0.85))
                                    .background(Circle().fill(Color.black.opacity(0.35)))
                            }
                            .buttonStyle(.plain)
                            .frame(width: 22, height: 22)
                            .contentShape(Circle())
                            .help(String(localized: "tray.removeItemHelp", defaultValue: "Remove \(item.url.lastPathComponent) from Tray"))
                        }
                    }
                    Button { action(.choose) } label: {
                        Image(systemName: "plus")
                            .font(.system(size: 15, weight: .medium))
                            .frame(width: 42, height: 64)
                            .background(RoundedRectangle(cornerRadius: 11).fill(Color.white.opacity(0.04)))
                    }
                    .buttonStyle(NotchPressStyle())
                    .help(String(localized: "tray.addMoreFiles", defaultValue: "Add more files"))
                }
                .padding(.horizontal, 2)
            }
        }
    }
}

private struct TrayButton: View {
    let title: String, icon: String, action: () -> Void
    init(_ title: String, _ icon: String, action: @escaping () -> Void) { self.title = title; self.icon = icon; self.action = action }
    var body: some View {
        Button {
            SoundPlayer.shared.play(.action)
            action()
        } label: {
            Label(title, systemImage: icon)
                .font(.system(size: 10, weight: .medium))
                .padding(.horizontal, 10)
                .frame(height: 30)
                .background(RoundedRectangle(cornerRadius: 8).fill(Color.white.opacity(0.08)))
        }
        .buttonStyle(NotchPressStyle())
        .hoverLift(cornerRadius: 8)
        .accessibilityIdentifier("tray.action.\(title.lowercased().replacingOccurrences(of: " ", with: "-"))")
        .help(title)
    }
}

private struct PlanReviewView: View {
    let request: PlanCenter.Request
    @State private var comment = ""
    @FocusState private var commentFocused: Bool
    let resolve: (String, String) -> Void
    var body: some View {
        CellSurface {
            VStack(alignment: .leading, spacing: 7) {
                Label(String(localized: "plan.reviewHeader", defaultValue: "\(request.agent.displayName) · Plan Review"), systemImage: "list.bullet.clipboard").font(.system(size: 11, weight: .semibold))
                Text(request.title).font(.system(size: 12, weight: .semibold)).lineLimit(1).help(request.title)
                Text(request.summary).font(.system(size: 10)).foregroundColor(DesignTokens.muted).lineLimit(2).help(request.summary)
                TextField(String(localized: "plan.addCommentPlaceholder", defaultValue: "Add a comment…"), text: $comment)
                    .textFieldStyle(.plain)
                    .font(.system(size: 10.5))
                    .padding(.horizontal, 9)
                    .frame(height: 30)
                    .background(RoundedRectangle(cornerRadius: 8).fill(Color.white.opacity(0.07)))
                    .overlay(RoundedRectangle(cornerRadius: 8).stroke(commentFocused ? Color.white.opacity(0.24) : .clear, lineWidth: 1))
                    .focused($commentFocused)
                    .onExitCommand { commentFocused = false }
                HStack {
                    MiniButton(title: String(localized: "plan.changesButton", defaultValue: "Changes"), icon: "arrow.uturn.backward", isDanger: true, helpText: String(localized: "plan.requestChangesHelp", defaultValue: "Request changes")) { resolve("request_changes", comment) }
                    MiniButton(title: String(localized: "plan.approveButton", defaultValue: "Approve"), icon: "checkmark", isPrimary: true, helpText: String(localized: "plan.approvePlanHelp", defaultValue: "Approve plan")) { resolve("approve", comment) }
                    MiniButton(title: String(localized: "plan.terminalButton", defaultValue: "Terminal"), icon: "terminal", helpText: String(localized: "plan.openInTerminalHelp", defaultValue: "Open the working directory in Terminal")) {
                        NSWorkspace.shared.open(URL(fileURLWithPath: request.cwd))
                    }
                }
            }.foregroundColor(.white)
        }
    }
}

private struct AgentQuestionView: View {
    let request: QuestionCenter.Request
    /// Step/mode live on `uiState` rather than local `@State` so
    /// `NotchWindowController.questionOpenSize(for:)` can size the panel to
    /// fit the *current* step's content instead of one fixed size for the
    /// whole batch (see its doc comment). Reset in `.onAppear` — `.id(request.id)`
    /// at the call site still forces a fresh view per request, but `uiState`
    /// itself is long-lived and wouldn't otherwise reset between requests.
    @ObservedObject var uiState: NotchUIState
    /// Called exactly once, with every sub-question's answer collected —
    /// `request.connection` is shared across the whole batch and can only
    /// be responded to a single time (see `QuestionCenter.resolve(_:answers:)`).
    let onComplete: ([String]) -> Void
    @State private var collectedAnswers: [String] = []
    @State private var customAnswer = ""
    @FocusState private var customFieldFocused: Bool
    @State private var isInteractive = false

    private var currentQuestion: QuestionCenter.SubQuestion { request.questions[uiState.questionStepIndex] }

    var body: some View {
        CellSurface {
            VStack(alignment: .leading, spacing: 7) {
                HStack(spacing: 6) {
                    Label(String(localized: "question.asks", defaultValue: "\(request.agent.displayName) asks"), systemImage: request.agent.symbolName)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundColor(request.agent == .codex ? .white.opacity(0.9) : DesignTokens.cyan)
                    Text(currentQuestion.header)
                        .font(.system(size: 9.5, weight: .medium))
                        .foregroundColor(DesignTokens.muted)
                        .lineLimit(1)
                        .padding(.horizontal, 6)
                        .frame(height: 20)
                        .background(Capsule().fill(Color.white.opacity(0.07)))
                    if request.questions.count > 1 {
                        Text("\(uiState.questionStepIndex + 1)/\(request.questions.count)")
                            .font(.system(size: 9.5, weight: .medium))
                            .foregroundColor(DesignTokens.muted)
                            .lineLimit(1)
                            .padding(.horizontal, 6)
                            .frame(height: 20)
                            .background(Capsule().fill(Color.white.opacity(0.07)))
                    }
                    Spacer(minLength: 4)
                    if !currentQuestion.options.isEmpty {
                        Button(uiState.questionCustomMode ? String(localized: "question.choices", defaultValue: "Choices") : String(localized: "question.other", defaultValue: "Other…")) {
                            withAnimation(.easeOut(duration: 0.20)) {
                                uiState.questionCustomMode.toggle()
                            }
                            customFieldFocused = uiState.questionCustomMode
                        }
                        .buttonStyle(NotchPressStyle())
                        .font(.system(size: 9.5, weight: .medium))
                        .foregroundColor(.white.opacity(0.66))
                        .padding(.horizontal, 7)
                        .frame(height: 24)
                        .background(Capsule().fill(Color.white.opacity(0.07)))
                        .help(uiState.questionCustomMode ? String(localized: "question.showChoicesHelp", defaultValue: "Show choices") : String(localized: "question.otherHelp", defaultValue: "Type another answer"))
                    }
                }
                Text(currentQuestion.prompt)
                    .font(.system(size: 14, weight: .medium))
                    .tracking(-0.1)
                    .lineLimit(4)
                    .fixedSize(horizontal: false, vertical: true)
                    .help(currentQuestion.prompt)
                    // Measures this Text's own (unstretched) rendered height —
                    // it can run to several lines, so the panel is sized to
                    // fit it live instead of budgeting a fixed line count
                    // (which either clipped long prompts or wasted space on
                    // short ones). See `uiState.questionPromptHeight`.
                    .onGeometryChange(for: CGFloat.self, of: { $0.size.height }) { newHeight in
                        uiState.questionPromptHeight = newHeight
                    }
                Group {
                    if uiState.questionCustomMode {
                        customAnswerView
                            .transition(.opacity.combined(with: .offset(y: 2)))
                    } else {
                        VStack(spacing: 5) {
                            ForEach(Array(currentQuestion.options.enumerated()), id: \.element.id) { index, option in
                                QuestionChoiceButton(
                                    shortcut: "⌘\(index + 1)",
                                    key: KeyEquivalent(Character("\(index + 1)")),
                                    title: option.label,
                                    detail: option.detail
                                ) { advance(with: option.label) }
                                .disabled(!isInteractive)
                            }
                        }
                        .transition(.opacity.combined(with: .offset(y: 2)))
                    }
                }
            }
            .foregroundColor(.white)
            // Without a top-aligned frame here, CellSurface's plain
            // .overlay() centers the content instead — the window itself is
            // now sized to fit (`questionOpenSize(for:)`), but any rounding
            // slack should still collect below the prompt, not above it.
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        }
        .onAppear {
            uiState.questionStepIndex = 0
            uiState.questionCustomMode = request.questions[0].options.isEmpty
            armInteractivity()
        }
    }

    /// Re-armed on every step transition (not just the view's initial
    /// appearance) — the 150ms dwell guard exists to stop a fast
    /// double-click/double-Enter from firing two answers before SwiftUI
    /// re-renders disabled state, a hazard that's identical when moving
    /// from one sub-question to the next within the same view instance.
    private func armInteractivity() {
        isInteractive = false
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 150_000_000)
            isInteractive = true
        }
    }

    private var customAnswerView: some View {
        VStack(alignment: .leading, spacing: 8) {
            ZStack(alignment: .topLeading) {
                if customAnswer.isEmpty {
                    Text(String(localized: "question.typeYourAnswer", defaultValue: "Type your answer…"))
                        .font(.system(size: 12))
                        .foregroundColor(DesignTokens.muted)
                        .padding(.horizontal, 12)
                        .padding(.top, 10)
                        .allowsHitTesting(false)
                }
                TextEditor(text: $customAnswer)
                    .font(.system(size: 12))
                    .scrollContentBackground(.hidden)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 6)
                    .frame(height: 74)
                    .focused($customFieldFocused)
                    .onExitCommand { customFieldFocused = false }
            }
            .background(RoundedRectangle(cornerRadius: 11).fill(Color.white.opacity(0.06)))
            .overlay(RoundedRectangle(cornerRadius: 11).stroke(customFieldFocused ? Color.white.opacity(0.28) : Color.white.opacity(0.05), lineWidth: 1))
            SendAnswerButton(
                isEnabled: isInteractive && !customAnswer.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                action: submitCustomAnswer
            )
        }
    }

    private func submitCustomAnswer() {
        let value = customAnswer.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return }
        SoundPlayer.shared.play(.approve)
        advance(with: value)
    }

    private func advance(with value: String) {
        var next = collectedAnswers
        next.append(value)
        if uiState.questionStepIndex + 1 < request.questions.count {
            collectedAnswers = next
            uiState.questionStepIndex += 1
            customAnswer = ""
            uiState.questionCustomMode = currentQuestion.options.isEmpty
            armInteractivity()
        } else {
            onComplete(next)
        }
    }
}

private struct QuestionChoiceButton: View {
    let shortcut: String
    let key: KeyEquivalent
    let title: String
    let detail: String
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button {
            SoundPlayer.shared.play(.approve)
            action()
        } label: {
            HStack(spacing: 9) {
                Text(shortcut)
                    .font(.system(size: 9, weight: .semibold, design: .rounded))
                    .foregroundColor(.white.opacity(0.62))
                    .frame(width: 28, height: 20)
                    .background(RoundedRectangle(cornerRadius: 5).fill(Color.white.opacity(0.09)))
                VStack(alignment: .leading, spacing: 1) {
                    Text(title)
                        .font(.system(size: 12, weight: .medium))
                        .lineLimit(1)
                        .truncationMode(.tail)
                    if !detail.isEmpty {
                        Text(detail)
                            .font(.system(size: 10))
                            .foregroundColor(DesignTokens.muted)
                            .lineLimit(1)
                            .truncationMode(.tail)
                    }
                }
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundColor(.white.opacity(hovering ? 0.65 : 0.25))
            }
            .padding(.horizontal, 10)
            .frame(minHeight: detail.isEmpty ? 32 : 42)
            .background(RoundedRectangle(cornerRadius: 9).fill(Color.white.opacity(hovering ? 0.12 : 0.065)))
        }
        .buttonStyle(NotchPressStyle())
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.18), value: hovering)
        .keyboardShortcut(key, modifiers: .command)
        .help(detail.isEmpty ? String(localized: "question.chooseHelp", defaultValue: "Choose \(title)") : String(localized: "question.choiceHelpWithDetail", defaultValue: "\(title)\n\(detail)"))
    }
}

/// The free-text answer's submit button. Pulled out of `customAnswerView` so
/// it can carry its own hover state. Reported as blending into the
/// background: the fill/foreground (`white.opacity(0.92)`/black) is high
/// contrast on paper, but it sat directly against `CellSurface`'s
/// `.ultraThinMaterial` — a live, backdrop-dependent blur whose rendered
/// brightness isn't fixed by this code. A dark stroke plus a shadow keeps the
/// button's own edge legible regardless of what the material renders behind
/// it, and the hover brighten now matches `ApprovalActionButton`'s allow role
/// (`0.92 → 1.0`) instead of having no hover feedback at all.
private struct SendAnswerButton: View {
    let isEnabled: Bool
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Label(String(localized: "question.sendAnswer", defaultValue: "Send answer"), systemImage: "arrow.up")
                .font(.system(size: 10.5, weight: .semibold))
                .frame(maxWidth: .infinity, minHeight: 32)
                .foregroundColor(.black)
                // Tinted with the question flow's own accent (DesignTokens.cyan,
                // matching attentionColor(for: .question)) instead of plain
                // white — ties the CTA to the card it lives in rather than
                // reading as a generic OS-style button. Still light enough for
                // black text to stay high-contrast.
                .background(RoundedRectangle(cornerRadius: 8).fill(DesignTokens.cyan.opacity(hovering ? 1 : 0.92)))
                .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color.black.opacity(0.16), lineWidth: 1))
                .shadow(color: DesignTokens.cyan.opacity(0.35), radius: 4, y: 1)
        }
        .buttonStyle(NotchPressStyle())
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.18), value: hovering)
        .disabled(!isEnabled)
        .help(String(localized: "question.sendAnswer", defaultValue: "Send answer"))
    }
}

// MARK: - Approval overlay (driven by PermissionCenter.queue)

private struct ApprovalOverlayView: View {
    @ObservedObject var uiState: NotchUIState
    let agent: AgentKind
    let toolName: String
    let summary: String
    var extraCount: Int = 0
    /// Set when at least one of the `extraCount` queued requests behind this
    /// one is from a different agent — see `IslandOverlay.approval`'s doc
    /// comment for why this exists (a lingering older request from one agent
    /// otherwise makes the shown agent's label look wrong when a different
    /// agent's brand-new request is actually the one waiting behind it).
    var otherAgentPending: AgentKind? = nil
    var onAllowOnce: () -> Void = {}
    var onDeny: () -> Void = {}
    var onCompactOutcome: (Bool) -> Void = { _ in }
    var onFinishOutcome: () -> Void = {}
    @State private var decision: ApprovalDecision?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isInteractive = false

    var body: some View {
        CellSurface {
            Group {
                if let decision {
                    VStack(spacing: 8) {
                        Image(systemName: decision == .allow ? "checkmark.circle.fill" : "xmark.circle.fill")
                            .font(.system(size: 30, weight: .medium))
                            .foregroundColor(decision == .allow ? DesignTokens.green : DesignTokens.red)
                            .symbolEffect(.bounce, value: decision)
                        Text(decision == .allow ? String(localized: "approval.allowedOnce", defaultValue: "Allowed once") : String(localized: "approval.denied", defaultValue: "Denied"))
                            .font(.system(size: 14, weight: .semibold))
                            .tracking(-0.1)
                        Text(decision == .allow ? String(localized: "approval.canContinue", defaultValue: "\(agent.displayName) can continue this action") : String(localized: "approval.willReturn", defaultValue: "\(agent.displayName) will return to the task"))
                            .font(.system(size: 9.5))
                            .foregroundColor(DesignTokens.muted)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .transition(.opacity.combined(with: .scale(scale: reduceMotion ? 1 : 0.97)))
                } else {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack(spacing: 6) {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .font(.system(size: 10))
                                .foregroundColor(DesignTokens.orange)
                            Text(String(localized: "approval.requestsPermission", defaultValue: "\(agent.displayName) requests permission"))
                                .font(.system(size: 12, weight: .medium))
                                .foregroundColor(DesignTokens.muted)
                            Spacer()
                            if extraCount > 0 {
                                Text(otherAgentPending.map {
                                    String(localized: "approval.extraCountOtherAgent", defaultValue: "+\(String(extraCount)) (\($0.displayName))")
                                } ?? String(localized: "approval.extraCount", defaultValue: "+\(String(extraCount))"))
                                .font(.system(size: 10.5, weight: .semibold))
                                    .padding(.horizontal, 6)
                                    .frame(height: 18)
                                    .background(Capsule().fill(Color.white.opacity(0.09)))
                            }
                        }
                        HStack(spacing: 7) {
                            Image(systemName: toolSymbol)
                                .foregroundColor(DesignTokens.orange)
                                .frame(width: 18)
                            Text(toolName)
                                .font(.system(size: 14, weight: .semibold, design: .rounded))
                                .tracking(-0.1)
                            Text(summary)
                                .font(.system(size: 11.5, design: .monospaced))
                                .foregroundColor(.white.opacity(0.72))
                                .lineLimit(1)
                                .truncationMode(.middle)
                        }
                        Text(summary.isEmpty ? String(localized: "approval.reviewAction", defaultValue: "Review this action before \(agent.displayName) continues.") : summary)
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundColor(.white.opacity(0.58))
                            .padding(.horizontal, 9)
                            .frame(maxWidth: .infinity, minHeight: 34, alignment: .leading)
                            .background(RoundedRectangle(cornerRadius: 8).fill(Color.black.opacity(0.28)))
                            // No `lineLimit` on this Text on purpose — it's a
                            // command/diff excerpt the user must review before
                            // approving, so it must never truncate. Measure
                            // its real height instead, so the panel grows to
                            // fit it exactly rather than budgeting a fixed
                            // size. See `uiState.approvalSummaryHeight`.
                            .onGeometryChange(for: CGFloat.self, of: { $0.size.height }) { newHeight in
                                uiState.approvalSummaryHeight = newHeight
                            }
                        Spacer(minLength: 10)
                        HStack(spacing: 8) {
                            ApprovalActionButton(title: String(localized: "approval.deny", defaultValue: "Deny"), shortcut: "⌘N", icon: "xmark", role: .deny) { decide(.deny) }
                                .disabled(!isInteractive)
                            ApprovalActionButton(title: String(localized: "approval.allowOnce", defaultValue: "Allow once"), shortcut: "⌘Y", icon: "checkmark", role: .allow) { decide(.allow) }
                                .disabled(!isInteractive)
                        }
                    }
                    .transition(.opacity)
                }
            }
            .animation(reduceMotion ? .easeOut(duration: 0.12) : DesignTokens.scaledSpring(), value: decision)
        }
        .onAppear {
            isInteractive = false
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 150_000_000)
                isInteractive = true
            }
        }
    }

    private var toolSymbol: String {
        switch toolName.lowercased() {
        case "edit", "write": return "pencil.line"
        case "bash": return "terminal"
        case "read": return "doc.text.magnifyingglass"
        default: return "lock.shield"
        }
    }

    private func decide(_ newDecision: ApprovalDecision) {
        guard decision == nil else { return }
        SoundPlayer.shared.play(newDecision == .allow ? .approve : .deny)
        withAnimation(reduceMotion ? .easeOut(duration: 0.12) : DesignTokens.scaledSpring()) {
            decision = newDecision
        }
        // Resolve immediately — Claude Code's blocking hook must never wait on animation timing.
        if newDecision == .allow {
            onAllowOnce()
        } else {
            onDeny()
        }
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: reduceMotion ? 250_000_000 : 550_000_000)
            onCompactOutcome(newDecision == .allow)
            try? await Task.sleep(nanoseconds: reduceMotion ? 900_000_000 : 1_800_000_000)
            onFinishOutcome()
        }
    }
}

private enum ApprovalDecision { case allow, deny }

// MARK: - Plan approval overlay (ExitPlanMode)

private struct PlanApprovalOverlayView: View {
    let agent: AgentKind
    var onAllowOnce: () -> Void = {}
    var onDeny: () -> Void = {}
    var onCompactOutcome: (Bool) -> Void = { _ in }
    var onFinishOutcome: () -> Void = {}
    @State private var decision: ApprovalDecision?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isInteractive = false

    var body: some View {
        CellSurface {
            Group {
                if let decision {
                    VStack(spacing: 8) {
                        Image(systemName: decision == .allow ? "checkmark.circle.fill" : "xmark.circle.fill")
                            .font(.system(size: 30, weight: .medium))
                            .foregroundColor(decision == .allow ? DesignTokens.green : DesignTokens.red)
                            .symbolEffect(.bounce, value: decision)
                        Text(decision == .allow ? String(localized: "plan.approved", defaultValue: "Plan approved") : String(localized: "plan.keptPlanning", defaultValue: "Kept planning"))
                            .font(.system(size: 14, weight: .semibold))
                            .tracking(-0.1)
                        Text(decision == .allow ? String(localized: "plan.willStartImplementing", defaultValue: "\(agent.displayName) will start implementing") : String(localized: "plan.willKeepRefining", defaultValue: "\(agent.displayName) will keep refining the plan"))
                            .font(.system(size: 9.5))
                            .foregroundColor(DesignTokens.muted)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .transition(.opacity.combined(with: .scale(scale: reduceMotion ? 1 : 0.97)))
                } else {
                    VStack(alignment: .leading, spacing: 7) {
                        HStack(spacing: 6) {
                            Image(systemName: "list.bullet.clipboard.fill")
                                .font(.system(size: 10))
                                .foregroundColor(DesignTokens.orange)
                            Text(String(localized: "plan.readyWithPlan", defaultValue: "\(agent.displayName) is ready with a plan"))
                                .font(.system(size: 12, weight: .medium))
                                .foregroundColor(DesignTokens.muted)
                            Spacer()
                        }
                        VStack(spacing: 5) {
                            PlanChoiceButton(title: String(localized: "plan.yesAutoMode", defaultValue: "Yes"), detail: String(localized: "plan.yesAutoModeDetail", defaultValue: "Approve and start implementing"), isPrimary: true) { decide(.allow) }
                                .disabled(!isInteractive)
                            PlanChoiceButton(title: String(localized: "plan.noKeepPlanning", defaultValue: "No, keep planning"), detail: String(localized: "plan.noKeepPlanningDetail", defaultValue: "Send back for more revisions"), isPrimary: false) { decide(.deny) }
                                .disabled(!isInteractive)
                        }
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                    .transition(.opacity)
                }
            }
            .animation(reduceMotion ? .easeOut(duration: 0.12) : DesignTokens.scaledSpring(), value: decision)
        }
        .onAppear {
            isInteractive = false
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 150_000_000)
                isInteractive = true
            }
        }
    }

    private func decide(_ newDecision: ApprovalDecision) {
        guard decision == nil else { return }
        SoundPlayer.shared.play(newDecision == .allow ? .approve : .deny)
        withAnimation(reduceMotion ? .easeOut(duration: 0.12) : DesignTokens.scaledSpring()) {
            decision = newDecision
        }
        // Resolve immediately — Claude Code's blocking hook must never wait on animation timing.
        if newDecision == .allow {
            onAllowOnce()
        } else {
            onDeny()
        }
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: reduceMotion ? 250_000_000 : 550_000_000)
            onCompactOutcome(newDecision == .allow)
            try? await Task.sleep(nanoseconds: reduceMotion ? 900_000_000 : 1_800_000_000)
            onFinishOutcome()
        }
    }
}

private struct PlanChoiceButton: View {
    let title: String
    let detail: String
    let isPrimary: Bool
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(foreground)
                Text(detail)
                    .font(.system(size: 9, weight: .regular))
                    .foregroundColor(foreground.opacity(0.62))
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 12)
            .frame(minHeight: 38, maxHeight: 38)
            .background(RoundedRectangle(cornerRadius: 8).fill(background))
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .strokeBorder(Color.white.opacity(isPrimary ? 0 : 0.28), lineWidth: 1)
            )
        }
        .buttonStyle(NotchPressStyle())
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.18), value: hovering)
        .help(detail)
    }

    private var foreground: Color { isPrimary ? .black : .white.opacity(0.86) }
    private var background: Color {
        isPrimary ? Color.white.opacity(hovering ? 1 : 0.94) : Color.white.opacity(hovering ? 0.1 : 0.0)
    }
}

private struct ApprovalActionButton: View {
    let title: String
    let shortcut: String
    let icon: String
    let role: ApprovalDecision
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: icon)
                Text(title)
                Spacer()
                Text(shortcut).foregroundColor(foreground.opacity(0.48))
            }
            .font(.system(size: 12, weight: .medium))
            .foregroundColor(foreground)
            .padding(.horizontal, 13)
            .frame(maxWidth: .infinity, minHeight: 36)
            .background(RoundedRectangle(cornerRadius: 9).fill(background))
        }
        .buttonStyle(NotchPressStyle())
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.18), value: hovering)
        .keyboardShortcut(role == .allow ? KeyEquivalent("y") : KeyEquivalent("n"), modifiers: .command)
        .help(role == .allow ? String(localized: "approval.allowOnceHelp", defaultValue: "Allow this action once") : String(localized: "approval.denyHelp", defaultValue: "Deny this action"))
    }

    private var foreground: Color { role == .allow ? .black : .white.opacity(0.86) }
    private var background: Color {
        role == .allow ? Color.white.opacity(hovering ? 1 : 0.94) : Color.white.opacity(hovering ? 0.16 : 0.1)
    }
}
