import SwiftUI
import AgentNotchCore

// The Agents page: the session list, its per-row actions, and the
// footer controls.

// MARK: - Agents cell (implemented)

struct AgentsCell: View {
    @ObservedObject var store: SessionStore
    @ObservedObject var uiState: NotchUIState
    @ObservedObject private var usageStore = AgentUsageStore.shared
    @State private var actionFeedback: String?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var selected: AgentSession? {
        if let id = uiState.selectedSessionId, let match = store.sessions.first(where: { $0.id == id }) {
            return match
        }
        return store.sessions.first
    }

    var body: some View {
        cellShape
            .overlay(
                // Laid out like the Dashboard page: no card plates, regions
                // separated by hairline rules on the bare panel, so both Nook
                // pages read as one surface instead of two visual systems.
                VStack(alignment: .leading, spacing: 0) {
                    if let selected {
                        UsageSummaryBar(agent: selected.agent, snapshot: usageStore.snapshots[selected.agent])
                            .padding(.bottom, 7)
                        sectionDivider
                        sessionList
                            .padding(.vertical, 7)
                            .frame(maxHeight: .infinity)
                        sectionDivider
                        footerRow
                            .padding(.top, 7)
                    } else {
                        emptyState
                    }
                }
                .padding(.horizontal, 4)
                .padding(.vertical, 6)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            )
            // `NotchWindowController` grows the panel to fit the session
            // list (see `agentsOpenSize`), but this clip is kept as a
            // defensive backstop: without it, content taller than the
            // panel's animated-in-progress frame (or an unexpectedly long
            // row) overflows the card's rounded-rect visually instead of
            // being contained/scrolled, which is what produced the
            // "floating Terminal button" bug report.
            .clipShape(RoundedRectangle(cornerRadius: DesignTokens.cellRadius))
    }

    /// Full vertical list of every tracked session, most-recent/selected
    /// first. Only the selected row expands to show the last user message
    /// and current activity; the rest stay single-line so several sessions
    /// fit without crowding the notch. Scrolls when they don't all fit.
    /// Sessions from the same project (`cwd`) are grouped together — e.g.
    /// Claude and Codex both running against the same repo read as one
    /// project instead of two unrelated rows.
    private var sessionList: some View {
        ScrollView(.vertical, showsIndicators: false) {
            VStack(alignment: .leading, spacing: 4) {
                ForEach(groupedSessions, id: \.cwd) { group in
                    if groupedSessions.count > 1 {
                        projectHeader(group.cwd)
                    }
                    ForEach(group.sessions) { session in
                        sessionRow(session, isSelected: session.id == selected?.id)
                    }
                }
            }
        }
    }

    private var groupedSessions: [(cwd: String, sessions: [AgentSession])] {
        groupSessionsByProject(store.sessions)
    }

    /// Only shown when there's more than one distinct project — a single
    /// header for the common (one-project) case would just repeat what's
    /// already implied by context without adding information.
    private func projectHeader(_ cwd: String) -> some View {
        Text(cwdTail(cwd))
            .font(.system(size: 8.5, weight: .semibold))
            .foregroundColor(DesignTokens.muted)
            .textCase(.uppercase)
            .tracking(0.3)
            .lineLimit(1)
            .truncationMode(.head)
            .padding(.leading, 2)
            .padding(.top, 2)
            .accessibilityAddTraits(.isHeader)
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

    /// Agents is the one page that doesn't go through `CellSurface`, so it
    /// keeps its own shape — stripped of the grey plate for the same reason
    /// (see `CellSurface`), leaving a plain sizing container.
    private var cellShape: some View {
        RoundedRectangle(cornerRadius: DesignTokens.cellRadius)
            .fill(Color.clear)
    }

    /// Horizontal counterpart of the Dashboard's `widgetDivider` — same
    /// hairline, same token, rotated for a vertically stacked page.
    private var sectionDivider: some View {
        Divider()
            .overlay(DesignTokens.line)
            .padding(.horizontal, 6)
    }

    /// One row per tracked session. Selected/first row expands to show the
    /// last user activity (`agents.lastMessage`); the rest stay compact,
    /// title-only rows with an agent badge and elapsed time — mirrors the
    /// competitor reference layout of a single always-visible session list.
    private func sessionRow(_ session: AgentSession, isSelected: Bool) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 8) {
                // Fixed 24pt regardless of selection: the row already grows
                // by two lines when selected, and resizing the icon on top of
                // that made the list jump around on every click.
                RoundedRectangle(cornerRadius: 7)
                    .fill(Color.white.opacity(0.09))
                    .frame(width: 24, height: 24)
                    .overlay(
                        glyphContent(session.agent, size: 9.5)
                            .foregroundColor(.white)
                    )
                Circle().fill(statusColor(session.state)).frame(width: 6, height: 6)
                Text(session.title)
                    .font(.system(size: 11.5, weight: .semibold))
                    .foregroundColor(.white.opacity(isSelected ? 1 : 0.78))
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .layoutPriority(1)
                Spacer(minLength: 4)
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
                }
                .padding(.leading, 32)
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
                .padding(.leading, 32)
            }
        }
        .padding(.leading, 10)
        .padding(.trailing, 8)
        .padding(.vertical, isSelected ? 6 : 5)
        // Selection used to be a filled grey plate behind every row (a
        // lighter one behind the unselected ones), which is exactly the
        // stacked-panel look the Dashboard page dropped. A single accent
        // rail marks the selected row instead, and the agent's own colour
        // says which agent it belongs to.
        .overlay(alignment: .leading) {
            if isSelected {
                Capsule()
                    .fill(session.agent.accentColor)
                    .frame(width: 2.5)
                    .padding(.vertical, 3)
            }
        }
        .contentShape(Rectangle())
        .hoverLift(cornerRadius: 10, strength: 0.04)
        .onTapGesture(count: 2) {
            jumpToSession(session)
        }
        .onTapGesture(count: 1) {
            selectSession(session, isSelected: isSelected)
        }
        .help(String(localized: "agents.doubleClickToReturn", defaultValue: "Double-click to return to \(session.agent.displayName)"))
        // The tap gestures above are invisible to VoiceOver, unlike every
        // other interactive element in this file (all `Button`-based). This
        // row has two distinct actions on one control — select (default
        // activation) and jump-to-Terminal (a named custom action) — the
        // standard VoiceOver idiom for "primary action on activate,
        // secondary action via the Actions rotor".
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(String(localized: "agents.sessionAccessibilityLabel", defaultValue: "\(session.title), \(session.agent.displayName)"))
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : [.isButton])
        .accessibilityHint(String(localized: "agents.sessionAccessibilityHint", defaultValue: "Double-tap to select. Use the actions rotor to jump to Terminal."))
        .accessibilityAction {
            selectSession(session, isSelected: isSelected)
        }
        .accessibilityAction(named: String(localized: "agents.jumpToTerminalAction", defaultValue: "Jump to Terminal")) {
            jumpToSession(session)
        }
    }

    private func jumpToSession(_ session: AgentSession) {
        SoundPlayer.shared.play(.navigation)
        Jumper.jump(to: session)
    }

    private func selectSession(_ session: AgentSession, isSelected: Bool) {
        guard !isSelected else { return }
        SoundPlayer.shared.play(.navigation)
        withAnimation(reduceMotion ? .easeOut(duration: 0.12) : DesignTokens.scaledContentTransition()) {
            uiState.selectedSessionId = session.id
        }
    }

    /// Rounded-pill agent-name badge, matching the reference design's
    /// per-row "Claude"/"Codex"/"Gemini" pill. Terminal-app badges are
    /// omitted: `AgentSession` doesn't currently carry which terminal a
    /// session is running in, so adding that pairing is left for later.

    private func agentBadge(_ agent: AgentKind) -> some View {
        Text(agent.displayName)
            .font(.system(size: 8.5, weight: .semibold))
            .foregroundColor(agent.accentColor)
            .padding(.horizontal, 6)
            .frame(height: 16)
            .background(Capsule().fill(agent.accentColor.opacity(0.16)))
            .lineLimit(1)
    }

    /// Stop (SIGTERM, irreversible) is deliberately placed apart from
    /// Pause/Terminal — both a real gap and a non-destructive button
    /// (Terminal) between them — instead of sitting immediately next to
    /// Pause where a hurried click could hit the wrong one. It also carries
    /// `requiresConfirmation` (arm-then-confirm, see `MiniButton`).
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
            }
            MiniButton(title: String(localized: "agents.action.terminal", defaultValue: "Terminal"), icon: "terminal", helpText: String(localized: "agents.action.terminalHelp", defaultValue: "Return to Terminal")) {
                if let selected {
                    Jumper.jump(to: selected)
                }
            }
            if let selected, selected.isManagedProcess {
                Spacer(minLength: 8)
                MiniButton(
                    title: String(localized: "agents.action.stop", defaultValue: "Stop"),
                    icon: "stop.fill",
                    isDanger: true,
                    helpText: String(localized: "agents.action.stopHelp", defaultValue: "Stop the managed process"),
                    requiresConfirmation: true
                ) {
                    actionFeedback = store.controlManagedSession(id: selected.id, action: .stop) ? String(localized: "agents.action.stopping", defaultValue: "Stopping…") : String(localized: "agents.action.stopFailed", defaultValue: "Could not stop process")
                }
            }
        }
    }

}

struct MiniButton: View {
    let title: String
    var icon: String? = nil
    var shortcut: String? = nil
    var isDanger: Bool = false
    var isPrimary: Bool = false
    var helpText: String? = nil
    /// When true, the first tap arms a "Confirm?" state instead of firing
    /// `action()` immediately — a second tap within `confirmWindow` actually
    /// confirms it; the arm auto-reverts if that second tap doesn't come.
    /// Used for irreversible actions (Stop sends SIGTERM to the managed
    /// process) so a stray or hurried tap can't silently trigger them.
    var requiresConfirmation: Bool = false
    let action: () -> Void
    @State private var hovering = false
    @State private var isArmed = false
    @State private var armTask: Task<Void, Never>?
    /// Debounces rapid repeated taps regardless of `requiresConfirmation` —
    /// covers the general "no double-fire" case, not just the confirm flow.
    @State private var isCoolingDown = false

    private static let confirmWindow: UInt64 = 3_000_000_000
    private static let tapCooldown: UInt64 = 400_000_000

    var body: some View {
        Button {
            guard !isCoolingDown else { return }
            isCoolingDown = true
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: Self.tapCooldown)
                isCoolingDown = false
            }
            if requiresConfirmation && !isArmed {
                SoundPlayer.shared.play(.navigation)
                armTask?.cancel()
                isArmed = true
                armTask = Task { @MainActor in
                    try? await Task.sleep(nanoseconds: Self.confirmWindow)
                    if !Task.isCancelled { isArmed = false }
                }
                return
            }
            armTask?.cancel()
            isArmed = false
            SoundPlayer.shared.play(.action)
            action()
        } label: {
            HStack(spacing: 4) {
                if let icon { Image(systemName: isArmed ? "exclamationmark.triangle.fill" : icon).font(.system(size: 8, weight: .semibold)) }
                Text(isArmed ? String(localized: "miniButton.confirmPrompt", defaultValue: "Confirm \(title)?") : title)
                if let shortcut, !isArmed {
                    Text(shortcut).foregroundColor(textColor.opacity(0.55))
                }
            }
            .font(.system(size: 10.5, weight: isPrimary || isArmed ? .semibold : .regular))
            .foregroundColor(isArmed ? DesignTokens.red : textColor)
            .padding(.horizontal, 8)
            .frame(height: 30)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(isArmed ? DesignTokens.red.opacity(0.22) : backgroundColor)
            )
        }
        .buttonStyle(NotchPressStyle())
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.18), value: hovering)
        .animation(.easeOut(duration: 0.15), value: isArmed)
        .help(isArmed ? String(localized: "miniButton.confirmPromptHelp", defaultValue: "Tap again to confirm") : (helpText ?? title))
        .accessibilityLabel(isArmed ? String(localized: "miniButton.confirmPrompt", defaultValue: "Confirm \(title)?") : title)
        .accessibilityHint(isArmed ? String(localized: "miniButton.confirmPromptHelp", defaultValue: "Tap again to confirm") : (helpText ?? ""))
        .onDisappear { armTask?.cancel() }
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
