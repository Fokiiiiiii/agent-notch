import SwiftUI
import UniformTypeIdentifiers

struct NotchView: View {
    @ObservedObject var store: SessionStore
    let controller: NotchWindowController
    @ObservedObject var permissions: PermissionCenter
    @EnvironmentObject var uiState: NotchUIState
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var trayItems: [TrayItem] = []
    @State private var isDropTargeted = false
    @State private var trayFeedback: String?
    @GestureState private var horizontalDrag: CGFloat = 0
    @GestureState private var verticalDrag: CGFloat = 0

    var body: some View {
        ZStack(alignment: .top) {
            Color.clear
            ZStack {
                shapeBackground
                content
            }
            .clipShape(shellShape)
            .compositingGroup()
            .opacity(uiState.isVisible ? 1 : 0)
            .allowsHitTesting(uiState.isVisible)
            .animation(DesignTokens.spring, value: uiState.mode)
        }
        .contentShape(Rectangle())
        .onHover { controller.hoverChanged($0) }
        .onDisappear { controller.cancelInteractionTimers() }
        .animation(.easeOut(duration: 0.18), value: uiState.isVisible)
        .environment(\.colorScheme, .dark)
    }

    private var shellShape: UnevenRoundedRectangle {
        let radius = uiState.mode == .open ? DesignTokens.openRadius : DesignTokens.closedRadius
        return UnevenRoundedRectangle(
            topLeadingRadius: 0,
            bottomLeadingRadius: radius,
            bottomTrailingRadius: radius,
            topTrailingRadius: 0,
            style: .continuous
        )
    }

    private var shapeBackground: some View {
        shellShape.fill(Color.black)
    }

    @ViewBuilder
    private var content: some View {
        switch uiState.mode {
        case .closed:
            compactContent
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
            controller.toggleOpen()
        } label: {
            HStack(spacing: 9) {
                GlyphBox(agent: selectedSession?.agent)
                if let session = selectedSession {
                    Text(session.title)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundColor(.white)
                        .lineLimit(1)
                        .truncationMode(.tail)
                    Spacer(minLength: 4)
                    HStack(spacing: 7) {
                        Circle()
                            .fill(statusColor(session.state))
                            .frame(width: 6, height: 6)
                        Text(session.agent.displayName)
                            .font(.system(size: 9))
                            .foregroundColor(DesignTokens.muted)
                    }
                } else {
                    Text("AgentNotch")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundColor(.white)
                    Spacer(minLength: 4)
                    Text("idle")
                        .font(.system(size: 9))
                        .foregroundColor(DesignTokens.muted)
                }
            }
            .padding(.horizontal, 12)
            .contentShape(Rectangle())
        }
        .buttonStyle(NotchPressStyle(pressedScale: 0.985))
        .accessibilityLabel("Open AgentNotch")
        .help("Open AgentNotch")
    }

    // MARK: - Notice (structure only; nothing triggers this mode yet)

    private var noticeContent: some View {
        HStack(spacing: 9) {
            if let outcome = uiState.approvalOutcome {
                Image(systemName: outcome.allowed ? "checkmark.circle.fill" : "xmark.circle.fill")
                    .font(.system(size: 16, weight: .medium))
                    .foregroundColor(outcome.allowed ? DesignTokens.green : DesignTokens.red)
                    .symbolEffect(.bounce, value: outcome)
                VStack(alignment: .leading, spacing: 1) {
                    Text(outcome.allowed ? "Allowed once" : "Denied")
                        .font(.system(size: 10.5, weight: .semibold))
                        .foregroundColor(.white)
                    Text(outcome.allowed ? "Claude is continuing" : "Returned to Claude")
                        .font(.system(size: 7.5))
                        .foregroundColor(DesignTokens.muted)
                }
            } else {
                GlyphBox(agent: nil)
                Text("Notification")
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
                    trayPlaceholder
                }
            }
            .id(contentIdentity)
            .transition(.asymmetric(
                insertion: .opacity.combined(with: .offset(y: reduceMotion ? 0 : 3)),
                removal: .opacity.combined(with: .offset(y: reduceMotion ? 0 : -2))
            ))
            .animation(reduceMotion ? .easeOut(duration: 0.14) : DesignTokens.contentTransition, value: contentIdentity)
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
            if direction == .left { navigateForward() }
            if direction == .right { navigateBackward() }
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
                tabButton(title: "Nook", icon: "sparkles", isActive: uiState.activeTab == .nook) {
                    selectTab(.nook)
                }
                tabButton(title: "Tray", icon: "tray.full", isActive: uiState.activeTab == .tray) {
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
            .help("Click the notch bar to close")
            Button { controller.closeExplicitly() } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 13))
                    .foregroundColor(.white.opacity(0.62))
                    .frame(width: 24, height: 24)
            }
            .buttonStyle(NotchPressStyle())
            .hoverLift(cornerRadius: 8)
            .help("Close  Esc")
        }
        .frame(height: 26)
    }

    private func tabButton(title: String, icon: String, isActive: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(title, systemImage: icon)
                .font(.system(size: 10.5, weight: .semibold))
                .foregroundColor(isActive ? .white : .white.opacity(0.72))
                .padding(.horizontal, 9)
                .frame(height: 24)
                .background(
                    Capsule().fill(isActive ? Color.white.opacity(0.13) : Color.clear)
                )
        }
        .buttonStyle(NotchPressStyle())
        .hoverLift(cornerRadius: 14)
        .help(isActive ? "Current tab" : "Show \(title)")
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
                        MediaCell()
                    case .today:
                        TodayCell()
                    case .system:
                        SystemCell()
                    }
                }
            }
            .frame(maxHeight: .infinity)
            if uiState.overlay == nil, uiState.isDetailExpanded {
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
        case .approval(let toolName, let summary, let extraCount):
            ApprovalOverlayView(
                toolName: toolName,
                summary: summary,
                extraCount: extraCount,
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
        case .plan:
            PlanReviewView { uiState.overlay = nil }
        case .question:
            AgentQuestionView { uiState.overlay = nil }
        }
    }

    private var viewTabs: some View {
        HStack(spacing: 4) {
            ForEach(NookView.allCases, id: \.self) { view in
                Button {
                    selectView(view)
                } label: {
                    Label(view.title, systemImage: viewIcon(view))
                        .font(.system(size: 7.5, weight: .medium))
                        .foregroundColor(uiState.activeView == view ? .white : .white.opacity(0.48))
                        .padding(.horizontal, 7)
                        .frame(height: 18)
                        .background(
                            Capsule().fill(uiState.activeView == view ? Color.white.opacity(0.11) : Color.clear)
                        )
                }
                .buttonStyle(NotchPressStyle(pressedScale: 0.9))
                .hoverLift(cornerRadius: 9, strength: 0.08)
                .accessibilityLabel(view.title)
                .help(uiState.activeView == view ? "Show or hide details" : "Show \(view.title)")
            }
            Spacer(minLength: 2)
            Button { controller.toggleDetailExpansion() } label: {
                Image(systemName: uiState.isDetailExpanded ? "chevron.up" : "chevron.down")
                    .font(.system(size: 8, weight: .semibold))
                    .foregroundColor(.white.opacity(0.48))
                    .frame(width: 22, height: 18)
                    .background(Capsule().fill(Color.white.opacity(0.055)))
            }
            .buttonStyle(NotchPressStyle(pressedScale: 0.9))
            .hoverLift(cornerRadius: 9)
            .help(uiState.isDetailExpanded ? "Collapse details" : "Expand details")
        }
        .frame(height: 20)
    }

    private func viewIcon(_ view: NookView) -> String {
        switch view {
        case .agents: return "terminal"
        case .media: return "play.fill"
        case .today: return "calendar"
        case .system: return "gauge.with.dots.needle.50percent"
        }
    }

    @ViewBuilder
    private var expandedDetail: some View {
        switch uiState.activeView {
        case .agents:
            DetailStrip(items: [
                ("Repository", selectedSession.map { URL(fileURLWithPath: $0.cwd).lastPathComponent } ?? "—"),
                ("Activity", selectedSession?.lastMessage ?? "No active session"),
                ("Usage", "5h 11% · 7d 2%")
            ])
        case .media:
            DetailStrip(items: [("Output", "MacBook Pro"), ("Quality", "Lossless · 24-bit"), ("Up Next", "Midnight City")])
        case .today:
            DetailStrip(items: [("Next", "Design sync · 10:30"), ("Focus", "2h available"), ("Calendar", "Studio")])
        case .system:
            DetailStrip(items: [("CPU", "18% · 48°C"), ("Network", "42 MB/s"), ("Docker", "Layer 12 of 18")])
        }
    }

    private var trayPlaceholder: some View {
        TrayCell(items: $trayItems, isTargeted: isDropTargeted, feedback: trayFeedback) { action in
            switch action {
            case .clear:
                trayItems.removeAll()
                trayFeedback = nil
            case .copyPath:
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(trayItems.first?.url.path ?? "", forType: .string)
                trayFeedback = "Path copied"
            case .airDrop:
                trayFeedback = "Ready for AirDrop"
            case .compress:
                trayFeedback = "Compress queued"
            case .attach:
                trayFeedback = "Attached to agent"
            }
        }
        .onDrop(of: [UTType.fileURL], isTargeted: $isDropTargeted) { providers in
            var accepted = false
            for provider in providers where provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
                accepted = true
                provider.loadDataRepresentation(forTypeIdentifier: UTType.fileURL.identifier) { data, _ in
                    guard let data,
                          let string = String(data: data, encoding: .utf8),
                          let url = URL(string: string) else { return }
                    Task { @MainActor in
                        guard !trayItems.contains(where: { $0.url == url }) else { return }
                        trayItems.append(TrayItem(url: url))
                        trayFeedback = "Saved temporarily"
                    }
                }
            }
            return accepted
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
                      abs(value.translation.height) > abs(value.translation.width) else { return }
                state = value.translation.height
            }
            .onEnded { value in
                guard uiState.overlay == nil,
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
        if uiState.activeTab == tab {
            controller.toggleDetailExpansion()
            return
        }
        SoundPlayer.shared.play(.navigation)
        withAnimation(reduceMotion ? .easeOut(duration: 0.12) : DesignTokens.spring) {
            uiState.activeTab = tab
        }
    }

    private func selectView(_ view: NookView) {
        if uiState.activeView == view {
            controller.toggleDetailExpansion()
            return
        }
        SoundPlayer.shared.play(.navigation)
        withAnimation(reduceMotion ? .easeOut(duration: 0.12) : DesignTokens.contentTransition) {
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
                VStack(alignment: .leading, spacing: 2) {
                    Text(item.0)
                        .font(.system(size: 6.5, weight: .medium))
                        .foregroundColor(DesignTokens.muted)
                    Text(item.1)
                        .font(.system(size: 8.5, weight: .medium))
                        .foregroundColor(.white.opacity(0.82))
                        .lineLimit(2)
                        .truncationMode(.tail)
                        .help(item.1)
                }
                .frame(maxWidth: .infinity, minHeight: 42, alignment: .leading)
                .padding(.horizontal, 8)
                .background(RoundedRectangle(cornerRadius: 9).fill(Color.white.opacity(0.055)))
            }
        }
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

// MARK: - Glyph

@ViewBuilder
private func glyphContent(_ agent: AgentKind?, size: CGFloat) -> some View {
    switch agent {
    case .claude:
        Text("✦").font(.system(size: size))
    case .codex:
        Text("›_").font(.system(size: size - 1, weight: .bold, design: .monospaced))
    case .antigravity:
        Image(systemName: "paperplane.fill").font(.system(size: size))
    case .gemini:
        Text("✦").font(.system(size: size))
    case .copilot:
        Image(systemName: "infinity").font(.system(size: size, weight: .semibold))
    case .cursor:
        Image(systemName: "cursorarrow").font(.system(size: size))
    case .opencode:
        Text(">_").font(.system(size: size - 1, weight: .bold, design: .monospaced))
    case .aider:
        Text("A").font(.system(size: size - 1, weight: .bold, design: .rounded))
    case .goose:
        Image(systemName: "bird.fill").font(.system(size: size))
    case .none:
        Text("⌁").font(.system(size: size + 1))
    }
}

private struct GlyphBox: View {
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
            .animation(.easeOut(duration: reduceMotion ? 0.01 : 0.14), value: hovering)
    }
}

private extension View {
    func hoverLift(cornerRadius: CGFloat = 8, strength: Double = 0.055) -> some View {
        modifier(HoverLiftModifier(cornerRadius: cornerRadius, strength: strength))
    }
}

// MARK: - Agents cell (implemented)

private struct AgentsCell: View {
    @ObservedObject var store: SessionStore
    @ObservedObject var uiState: NotchUIState
    @State private var pausedSessionIDs: Set<String> = []
    @State private var actionFeedback: String?

    private var selected: AgentSession? {
        if let id = uiState.selectedSessionId, let match = store.sessions.first(where: { $0.id == id }) {
            return match
        }
        return store.sessions.first
    }

    private var others: [AgentSession] {
        guard let selected else { return [] }
        return store.sessions.filter { $0.id != selected.id }
    }

    var body: some View {
        cellShape
            .overlay(
                VStack(alignment: .leading, spacing: 5) {
                    if let selected {
                        heroRow(selected)
                        activityRow(selected)
                        Spacer(minLength: 0)
                        footerRow
                    } else {
                        Spacer(minLength: 0)
                        Text("No active sessions")
                            .font(.system(size: 10))
                            .foregroundColor(DesignTokens.muted)
                            .frame(maxWidth: .infinity, alignment: .center)
                        Spacer(minLength: 0)
                    }
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 9)
            )
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

    private func heroRow(_ session: AgentSession) -> some View {
        HStack(spacing: 7) {
            RoundedRectangle(cornerRadius: 9)
                .fill(Color.white.opacity(0.09))
                .frame(width: 28, height: 28)
                .overlay(
                    glyphContent(session.agent, size: 9)
                        .foregroundColor(.white)
                )
            VStack(alignment: .leading, spacing: 2) {
                Text(session.title)
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundColor(.white)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Text("\(session.agent.displayName) · \(cwdTail(session.cwd))")
                    .font(.system(size: 8))
                    .foregroundColor(DesignTokens.muted)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            Spacer(minLength: 4)
            VStack(alignment: .trailing, spacing: 2) {
                Text(elapsedString(session))
                    .font(.system(size: 8))
                    .foregroundColor(.white.opacity(0.42))
                Text("5h 11% · 7d 2%")
                    .font(.system(size: 7, design: .monospaced))
                    .foregroundColor(.white.opacity(0.34))
            }
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 5)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(Color.white.opacity(0.065))
        )
        .contentShape(Rectangle())
        .hoverLift(cornerRadius: 10, strength: 0.04)
        .onTapGesture(count: 2) {
            SoundPlayer.shared.play(.navigation)
            Jumper.jump(to: session)
        }
        .help("Double-click to return to \(session.agent.displayName)")
    }

    private func activityRow(_ session: AgentSession) -> some View {
        HStack(spacing: 6) {
            Circle()
                .fill(statusColor(session.state))
                .frame(width: 6, height: 6)
            Text(session.lastMessage)
                .font(.system(size: 8.5))
                .foregroundColor(.white.opacity(0.58))
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: 0)
            if let actionFeedback {
                Text(actionFeedback)
                    .font(.system(size: 7))
                    .foregroundColor(DesignTokens.muted)
                    .lineLimit(1)
            }
        }
        .padding(.horizontal, 6)
        .frame(height: 20)
    }

    private var footerRow: some View {
        HStack(spacing: 4) {
            ForEach(others.prefix(2)) { session in
                Button {
                    SoundPlayer.shared.play(.navigation)
                    withAnimation(DesignTokens.contentTransition) {
                        uiState.selectedSessionId = session.id
                    }
                } label: {
                    HStack(spacing: 4) {
                        Circle().fill(statusColor(session.state)).frame(width: 5, height: 5)
                        Text(session.agent.displayName)
                            .font(.system(size: 7.5, weight: .medium))
                            .lineLimit(1)
                    }
                    .foregroundColor(.white.opacity(0.62))
                    .padding(.horizontal, 7)
                    .frame(height: 24)
                    .background(RoundedRectangle(cornerRadius: 8).fill(Color.white.opacity(0.055)))
                }
                .buttonStyle(NotchPressStyle())
                .hoverLift(cornerRadius: 8)
                .help("Show \(session.title)")
            }
            Spacer(minLength: 4)
            MiniButton(
                title: selected.map { pausedSessionIDs.contains($0.id) ? "Resume" : "Pause" } ?? "Pause",
                icon: selected.map { pausedSessionIDs.contains($0.id) ? "play.fill" : "pause.fill" } ?? "pause.fill",
                helpText: "Pause or resume this agent"
            ) {
                guard let selected else { return }
                if pausedSessionIDs.contains(selected.id) {
                    pausedSessionIDs.remove(selected.id)
                    actionFeedback = "Resume requested"
                } else {
                    pausedSessionIDs.insert(selected.id)
                    actionFeedback = "Pause requested"
                }
            }
            MiniButton(title: "Stop", icon: "stop.fill", isDanger: true, helpText: "Stop this agent") {
                actionFeedback = "Stop requested"
            }
            MiniButton(title: "Terminal", icon: "terminal", helpText: "Return to Terminal") {
                if let selected {
                    Jumper.jump(to: selected)
                }
            }
        }
    }

    private func cwdTail(_ cwd: String) -> String {
        URL(fileURLWithPath: cwd).lastPathComponent
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
            .font(.system(size: 8.5, weight: isPrimary ? .semibold : .regular))
            .foregroundColor(textColor)
            .padding(.horizontal, 8)
            .frame(height: 24)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(backgroundColor)
            )
        }
        .buttonStyle(NotchPressStyle())
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.14), value: hovering)
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
    }
}

private struct MediaCell: View {
    @State private var isPlaying = true
    @State private var progress = 0.43
    @State private var volume = 0.72

    var body: some View {
        CellSurface {
            HStack(spacing: 12) {
                RoundedRectangle(cornerRadius: 12)
                    .fill(LinearGradient(colors: [.purple.opacity(0.9), .blue.opacity(0.7), .black], startPoint: .topLeading, endPoint: .bottomTrailing))
                    .frame(width: 68, height: 68)
                    .overlay(Image(systemName: "waveform").font(.system(size: 21, weight: .light)).foregroundColor(.white.opacity(0.82)))
                VStack(alignment: .leading, spacing: 7) {
                    Text("Night Drive").font(.system(size: 12, weight: .semibold)).lineLimit(1)
                    Text("Neon Coast · Apple Music").font(.system(size: 9)).foregroundColor(DesignTokens.muted).lineLimit(1)
                    Slider(value: $progress).controlSize(.mini).tint(.white.opacity(0.9))
                    HStack {
                        MediaControlButton(icon: "backward.fill", help: "Previous") { progress = max(0, progress - 0.08) }
                        MediaControlButton(icon: isPlaying ? "pause.fill" : "play.fill", help: isPlaying ? "Pause" : "Play", prominent: true) { isPlaying.toggle() }
                        MediaControlButton(icon: "forward.fill", help: "Next") { progress = min(1, progress + 0.08) }
                        Spacer()
                        Image(systemName: "speaker.fill").foregroundColor(DesignTokens.muted)
                        Slider(value: $volume).frame(width: 74).controlSize(.mini)
                    }
                    .font(.system(size: 11))
                }
            }
            .foregroundColor(.white)
        }
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
                .frame(width: prominent ? 26 : 20, height: 22)
                .background(Circle().fill(Color.white.opacity(prominent ? 0.11 : 0)))
        }
        .buttonStyle(NotchPressStyle())
        .hoverLift(cornerRadius: 11, strength: 0.08)
        .help(help)
    }
}

private struct TodayCell: View {
    @State private var focusRunning = false

    var body: some View {
        CellSurface {
            HStack(spacing: 14) {
                VStack(spacing: 1) {
                    Text("19").font(.system(size: 34, weight: .light, design: .rounded))
                    Text("JUL · SUN").font(.system(size: 8, weight: .semibold)).tracking(0.7).foregroundColor(DesignTokens.muted)
                }
                .frame(width: 76)
                Divider().overlay(DesignTokens.line)
                VStack(alignment: .leading, spacing: 8) {
                    ScheduleRow(time: "10:30", title: "Design sync", detail: "Studio · 30 min")
                    ScheduleRow(time: "13:00", title: "AgentNotch review", detail: "Focus block · 1 hr")
                    Spacer(minLength: 0)
                    Button {
                        SoundPlayer.shared.play(.action)
                        focusRunning.toggle()
                    } label: {
                        Label(focusRunning ? "End Focus · 21:42" : "Start Focus", systemImage: focusRunning ? "timer" : "moon.fill")
                            .font(.system(size: 9, weight: .medium)).frame(height: 24).padding(.horizontal, 9)
                            .background(RoundedRectangle(cornerRadius: 8).fill(Color.white.opacity(0.09)))
                    }
                    .buttonStyle(NotchPressStyle())
                    .hoverLift(cornerRadius: 8)
                    .help(focusRunning ? "End Focus" : "Start Focus")
                }
            }.foregroundColor(.white)
        }
    }
}

private struct ScheduleRow: View {
    let time: String
    let title: String
    let detail: String
    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Text(time).font(.system(size: 8, design: .monospaced)).foregroundColor(DesignTokens.muted).frame(width: 34, alignment: .leading)
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(.system(size: 10, weight: .semibold)).lineLimit(1)
                Text(detail).font(.system(size: 8)).foregroundColor(DesignTokens.muted).lineLimit(1)
            }
        }
    }
}

private struct SystemCell: View {
    @State private var dockerProgress = 0.68
    @State private var downloadProgress = 0.34

    var body: some View {
        CellSurface {
            VStack(spacing: 5) {
                HStack(spacing: 6) {
                    SystemMetric(icon: "battery.75percent", title: "Battery", value: "78%", detail: "4h 12m")
                    SystemMetric(icon: "memorychip", title: "Memory", value: "11.4 GB", detail: "of 24 GB")
                    SystemMetric(icon: "externaldrive", title: "Storage", value: "214 GB", detail: "available")
                }
                TaskProgress(icon: "shippingbox.fill", title: "Docker · Building api", progress: dockerProgress, detail: "Layer 12 of 18")
                TaskProgress(icon: "arrow.down.circle.fill", title: "Download · Xcode 18", progress: downloadProgress, detail: "2.1 of 6.2 GB")
            }.foregroundColor(.white)
        }
    }
}

private struct SystemMetric: View {
    let icon: String, title: String, value: String, detail: String
    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: icon).font(.system(size: 9.5)).foregroundColor(.white.opacity(0.72))
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(.system(size: 6.5)).foregroundColor(DesignTokens.muted)
                Text(value).font(.system(size: 8.5, weight: .semibold)).lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 6)
        .frame(height: 28)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.white.opacity(0.055)))
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

private enum TrayAction { case airDrop, compress, copyPath, attach, clear }

private struct TrayCell: View {
    @Binding var items: [TrayItem]
    let isTargeted: Bool
    let feedback: String?
    let action: (TrayAction) -> Void

    var body: some View {
        CellSurface {
            VStack(spacing: 8) {
                if items.isEmpty {
                    RoundedRectangle(cornerRadius: 11)
                        .strokeBorder(Color.white.opacity(isTargeted ? 0.55 : 0.16), style: StrokeStyle(lineWidth: 1, dash: [4, 4]))
                        .overlay(VStack(spacing: 4) { Image(systemName: "arrow.down.doc"); Text("Drop files into the notch").font(.system(size: 9, weight: .medium)); Text("Temporary shelf · nothing leaves this Mac").font(.system(size: 7)).foregroundColor(DesignTokens.muted) })
                } else {
                    HStack(spacing: 8) {
                        ForEach(items.prefix(5)) { item in
                            VStack(spacing: 4) {
                                RoundedRectangle(cornerRadius: 9).fill(Color.white.opacity(0.08)).frame(width: 50, height: 50)
                                    .overlay(Image(systemName: iconName(for: item.url)).font(.system(size: 19)).foregroundColor(.white.opacity(0.8)))
                                Text(item.url.lastPathComponent).font(.system(size: 7)).lineLimit(1).frame(width: 58)
                            }
                        }
                        Spacer(minLength: 0)
                    }
                }
                HStack(spacing: 5) {
                    TrayButton("AirDrop", "airplayaudio", action: { action(.airDrop) })
                    TrayButton("Compress", "archivebox", action: { action(.compress) })
                    TrayButton("Copy Path", "doc.on.doc", action: { action(.copyPath) })
                    TrayButton("AI Attach", "paperclip", action: { action(.attach) })
                    Spacer()
                    if let feedback { Text(feedback).font(.system(size: 7)).foregroundColor(DesignTokens.muted) }
                    Button {
                        SoundPlayer.shared.play(.deny)
                        action(.clear)
                    } label: {
                        Image(systemName: "trash")
                            .frame(width: 24, height: 22)
                            .background(RoundedRectangle(cornerRadius: 8).fill(Color.white.opacity(0.055)))
                    }
                    .buttonStyle(NotchPressStyle())
                    .hoverLift(cornerRadius: 8)
                    .help("Clear Tray")
                    .disabled(items.isEmpty)
                }
            }.foregroundColor(.white)
        }
    }

    private func iconName(for url: URL) -> String {
        switch url.pathExtension.lowercased() {
        case "png", "jpg", "jpeg", "heic": return "photo"
        case "pdf": return "doc.richtext"
        case "md", "txt": return "doc.text"
        default: return "doc.fill"
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
                .font(.system(size: 7.5))
                .padding(.horizontal, 8)
                .frame(height: 24)
                .background(RoundedRectangle(cornerRadius: 8).fill(Color.white.opacity(0.08)))
        }
        .buttonStyle(NotchPressStyle())
        .hoverLift(cornerRadius: 8)
        .help(title)
    }
}

private struct PlanReviewView: View {
    @State private var comment = ""
    let dismiss: () -> Void
    var body: some View {
        CellSurface {
            VStack(alignment: .leading, spacing: 7) {
                Label("Plan Review", systemImage: "list.bullet.clipboard").font(.system(size: 10, weight: .semibold))
                Text("Refactor authentication middleware").font(.system(size: 11, weight: .semibold))
                Text("1. Extract token validation  2. Add refresh path  3. Run auth tests").font(.system(size: 8)).foregroundColor(DesignTokens.muted).lineLimit(2)
                TextField("Add a comment…", text: $comment).textFieldStyle(.plain).font(.system(size: 9)).padding(7).background(RoundedRectangle(cornerRadius: 7).fill(Color.white.opacity(0.07)))
                HStack {
                    MiniButton(title: "Changes", icon: "arrow.uturn.backward", isDanger: true, helpText: "Request changes", action: dismiss)
                    MiniButton(title: "Approve", icon: "checkmark", isPrimary: true, helpText: "Approve plan", action: dismiss)
                    MiniButton(title: "Terminal", icon: "terminal", helpText: "Open the full plan in Terminal", action: dismiss)
                }
            }.foregroundColor(.white)
        }
    }
}

private struct AgentQuestionView: View {
    let dismiss: () -> Void
    var body: some View {
        CellSurface {
            VStack(alignment: .leading, spacing: 6) {
                Label("Claude asks", systemImage: "message.fill")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundColor(DesignTokens.cyan)
                Text("Which deployment target?")
                    .font(.system(size: 12, weight: .medium))
                QuestionChoiceButton(shortcut: "⌘1", key: "1", title: "Production", action: dismiss)
                QuestionChoiceButton(shortcut: "⌘2", key: "2", title: "Staging", action: dismiss)
                QuestionChoiceButton(shortcut: "⌘3", key: "3", title: "Local only", action: dismiss)
            }.foregroundColor(.white)
        }
    }
}

private struct QuestionChoiceButton: View {
    let shortcut: String
    let key: KeyEquivalent
    let title: String
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button {
            SoundPlayer.shared.play(.approve)
            action()
        } label: {
            HStack(spacing: 8) {
                Text(shortcut)
                    .font(.system(size: 8, weight: .semibold, design: .rounded))
                    .foregroundColor(DesignTokens.cyan.opacity(0.85))
                    .frame(width: 28, height: 20)
                    .background(RoundedRectangle(cornerRadius: 6).fill(DesignTokens.cyan.opacity(0.15)))
                Text(title).font(.system(size: 10, weight: .medium))
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.system(size: 8, weight: .semibold))
                    .foregroundColor(.white.opacity(hovering ? 0.65 : 0.25))
            }
            .padding(.horizontal, 8)
            .frame(height: 28)
            .background(RoundedRectangle(cornerRadius: 9).fill(DesignTokens.cyan.opacity(hovering ? 0.16 : 0.09)))
        }
        .buttonStyle(NotchPressStyle())
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.14), value: hovering)
        .keyboardShortcut(key, modifiers: .command)
        .help("Choose \(title)")
    }
}

// MARK: - Approval overlay (driven by PermissionCenter.queue)

private struct ApprovalOverlayView: View {
    let toolName: String
    let summary: String
    var extraCount: Int = 0
    var onAllowOnce: () -> Void = {}
    var onDeny: () -> Void = {}
    var onCompactOutcome: (Bool) -> Void = { _ in }
    var onFinishOutcome: () -> Void = {}
    @State private var decision: ApprovalDecision?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        CellSurface {
            Group {
                if let decision {
                    VStack(spacing: 8) {
                        Image(systemName: decision == .allow ? "checkmark.circle.fill" : "xmark.circle.fill")
                            .font(.system(size: 28, weight: .medium))
                            .foregroundColor(decision == .allow ? DesignTokens.green : DesignTokens.red)
                            .symbolEffect(.bounce, value: decision)
                        Text(decision == .allow ? "Allowed once" : "Denied")
                            .font(.system(size: 13, weight: .semibold))
                        Text(decision == .allow ? "Claude can continue this action" : "Claude will return to the task")
                            .font(.system(size: 8.5))
                            .foregroundColor(DesignTokens.muted)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .transition(.opacity.combined(with: .scale(scale: reduceMotion ? 1 : 0.97)))
                } else {
                    VStack(alignment: .leading, spacing: 7) {
                        HStack(spacing: 6) {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .font(.system(size: 9))
                                .foregroundColor(DesignTokens.orange)
                            Text("Claude requests permission")
                                .font(.system(size: 9, weight: .medium))
                                .foregroundColor(DesignTokens.muted)
                            Spacer()
                            if extraCount > 0 {
                                Text("+\(extraCount)")
                                    .font(.system(size: 8, weight: .semibold))
                                    .padding(.horizontal, 6)
                                    .frame(height: 18)
                                    .background(Capsule().fill(Color.white.opacity(0.09)))
                            }
                        }
                        HStack(spacing: 7) {
                            Image(systemName: toolSymbol)
                                .foregroundColor(DesignTokens.orange)
                                .frame(width: 16)
                            Text(toolName)
                                .font(.system(size: 12, weight: .semibold, design: .rounded))
                            Text(summary)
                                .font(.system(size: 10, design: .monospaced))
                                .foregroundColor(.white.opacity(0.72))
                                .lineLimit(1)
                                .truncationMode(.middle)
                        }
                        Text(summary.isEmpty ? "Review this action before Claude continues." : summary)
                            .font(.system(size: 8, design: .monospaced))
                            .foregroundColor(.white.opacity(0.58))
                            .padding(.horizontal, 8)
                            .frame(maxWidth: .infinity, minHeight: 30, alignment: .leading)
                            .background(RoundedRectangle(cornerRadius: 8).fill(Color.black.opacity(0.28)))
                        Spacer(minLength: 2)
                        HStack(spacing: 8) {
                            ApprovalActionButton(title: "Deny", shortcut: "⌘N", icon: "xmark", role: .deny) { decide(.deny) }
                            ApprovalActionButton(title: "Allow once", shortcut: "⌘Y", icon: "checkmark", role: .allow) { decide(.allow) }
                        }
                    }
                    .transition(.opacity)
                }
            }
            .animation(reduceMotion ? .easeOut(duration: 0.12) : DesignTokens.spring, value: decision)
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
        withAnimation(reduceMotion ? .easeOut(duration: 0.12) : DesignTokens.spring) {
            decision = newDecision
        }
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: reduceMotion ? 180_000_000 : 300_000_000)
            onCompactOutcome(newDecision == .allow)
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            if newDecision == .allow {
                onAllowOnce()
            } else {
                onDeny()
            }
            onFinishOutcome()
        }
    }
}

private enum ApprovalDecision { case allow, deny }

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
            .font(.system(size: 10, weight: .medium))
            .foregroundColor(foreground)
            .padding(.horizontal, 11)
            .frame(maxWidth: .infinity, minHeight: 30)
            .background(RoundedRectangle(cornerRadius: 9).fill(background))
        }
        .buttonStyle(NotchPressStyle())
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.14), value: hovering)
        .keyboardShortcut(role == .allow ? KeyEquivalent("y") : KeyEquivalent("n"), modifiers: .command)
        .help(role == .allow ? "Allow this action once" : "Deny this action")
    }

    private var foreground: Color { role == .allow ? .black : .white.opacity(0.86) }
    private var background: Color {
        role == .allow ? Color.white.opacity(hovering ? 1 : 0.94) : Color.white.opacity(hovering ? 0.16 : 0.1)
    }
}
