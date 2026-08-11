import SwiftUI
import AgentNotchCore

// The permission-approval and ExitPlanMode surfaces.

// MARK: - Approval overlay (driven by PermissionCenter.queue)

struct ApprovalOverlayView: View {
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
    var cwd: String = ""
    /// Best-effort heuristic flag from `DangerousCommandDetector` — see its
    /// doc comment. Escalates the command box's border/caption, not the
    /// header icon (which stays orange for every permission request, so the
    /// color language doesn't collide with `.deny`'s red).
    var isDangerous: Bool = false
    var onAllowOnce: () -> Void = {}
    var onDeny: () -> Void = {}
    var onCompactOutcome: (Bool) -> Void = { _ in }
    var onFinishOutcome: () -> Void = {}
    @State private var decision: ApprovalDecision?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isInteractive = false

    /// Caps how tall the command/diff box grows before it becomes
    /// internally scrollable — keeps `approvalOpenSize()`'s height budget
    /// (see `NotchWindowController`) bounded even for very long commands,
    /// instead of the box (and the whole panel) growing without limit.
    private static let summaryBoxMaxHeight: CGFloat = 140

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
                                .lineLimit(1)
                                .truncationMode(.middle)
                            Text(summary)
                                .font(.system(size: 11.5, design: .monospaced))
                                .foregroundColor(.white.opacity(0.72))
                                .lineLimit(1)
                                .truncationMode(.middle)
                        }
                        if !cwd.isEmpty {
                            HStack(spacing: 5) {
                                Image(systemName: "folder")
                                    .font(.system(size: 9))
                                    .foregroundColor(DesignTokens.muted)
                                Text(cwdTail(cwd))
                                    .font(.system(size: 10, design: .monospaced))
                                    .foregroundColor(DesignTokens.muted)
                                    .lineLimit(1)
                                    .truncationMode(.head)
                                Spacer(minLength: 6)
                                if isDangerous {
                                    Label(String(localized: "approval.dangerousCommand", defaultValue: "Review carefully"), systemImage: "exclamationmark.triangle.fill")
                                        .font(.system(size: 9, weight: .semibold))
                                        .foregroundColor(DesignTokens.red)
                                        .lineLimit(1)
                                }
                            }
                        }
                        ScrollView {
                            Text(summary.isEmpty ? String(localized: "approval.reviewAction", defaultValue: "Review this action before \(agent.displayName) continues.") : summary)
                                .font(.system(size: 11, design: .monospaced))
                                .foregroundColor(isDangerous ? DesignTokens.red.opacity(0.85) : .white.opacity(0.58))
                                .padding(.horizontal, 9)
                                .padding(.vertical, 8)
                                .frame(maxWidth: .infinity, minHeight: 34, alignment: .leading)
                                // No `lineLimit` on this Text on purpose — it's
                                // a command/diff excerpt the user must review
                                // before approving, so it must never truncate.
                                // Measure its real (unbounded) height so long
                                // content that exceeds the box's own capped
                                // `.frame(maxHeight:)` below stays reachable by
                                // scrolling instead of being silently clipped
                                // by the panel's own `approvalMaxHeight` cap.
                                .onGeometryChange(for: CGFloat.self, of: { $0.size.height }) { newHeight in
                                    uiState.approvalSummaryHeight = min(newHeight, Self.summaryBoxMaxHeight)
                                }
                        }
                        .frame(maxHeight: Self.summaryBoxMaxHeight)
                        .background(RoundedRectangle(cornerRadius: 8).fill(Color.black.opacity(0.28)))
                        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(isDangerous ? DesignTokens.red.opacity(0.45) : .clear, lineWidth: 1))
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
            armDwellGuard($isInteractive)
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
        HapticPlayer.shared.perform(newDecision == .allow ? .confirm : .reject)
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

#Preview("Approval — dangerous command") {
    ApprovalOverlayView(
        uiState: NotchUIState(),
        agent: .claude,
        toolName: "Bash",
        summary: "sudo rm -rf /tmp/build-artifacts && git push --force origin main",
        extraCount: 2,
        otherAgentPending: .codex,
        cwd: "/Users/chaos/Documents/agent-notch/Sources/AgentNotch",
        isDangerous: true
    )
    .frame(width: 540, height: 260)
    .background(Color.black)
}

#Preview("Approval — ordinary file edit") {
    ApprovalOverlayView(
        uiState: NotchUIState(),
        agent: .codex,
        toolName: "Edit",
        summary: "/Users/chaos/Documents/agent-notch/Sources/AgentNotch/NotchView.swift",
        cwd: "/Users/chaos/Documents/agent-notch"
    )
    .frame(width: 540, height: 220)
    .background(Color.black)
}

enum ApprovalDecision { case allow, deny }

// MARK: - Plan approval overlay (ExitPlanMode)

struct PlanApprovalOverlayView: View {
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
            armDwellGuard($isInteractive)
        }
    }

    private func decide(_ newDecision: ApprovalDecision) {
        guard decision == nil else { return }
        SoundPlayer.shared.play(newDecision == .allow ? .approve : .deny)
        HapticPlayer.shared.perform(newDecision == .allow ? .confirm : .reject)
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

#Preview("Plan approval (ExitPlanMode)") {
    PlanApprovalOverlayView(agent: .claude)
        .frame(width: 540, height: 190)
        .background(Color.black)
}

struct PlanChoiceButton: View {
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
        // Mirrors ApprovalActionButton's ⌘Y/⌘N convention (allow/deny) —
        // "Yes, approve" and "No, keep planning" are the same affirmative/
        // negative pair, just for a plan instead of a permission request.
        .keyboardShortcut(isPrimary ? KeyEquivalent("y") : KeyEquivalent("n"), modifiers: .command)
        .help(detail)
        .accessibilityLabel(title)
        .accessibilityHint(detail)
    }

    private var foreground: Color { isPrimary ? .black : .white.opacity(0.86) }
    private var background: Color {
        isPrimary ? Color.white.opacity(hovering ? 1 : 0.94) : Color.white.opacity(hovering ? 0.1 : 0.0)
    }
}

struct ApprovalActionButton: View {
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
        .accessibilityLabel(title)
        .accessibilityHint(role == .allow ? String(localized: "approval.allowOnceHelp", defaultValue: "Allow this action once") : String(localized: "approval.denyHelp", defaultValue: "Deny this action"))
    }

    private var foreground: Color { role == .allow ? .black : .white.opacity(0.86) }
    private var background: Color {
        role == .allow ? Color.white.opacity(hovering ? 1 : 0.94) : Color.white.opacity(hovering ? 0.16 : 0.1)
    }
}
