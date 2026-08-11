import SwiftUI
import AppKit

// The agent-question and plan-review surfaces, including their
// single-select, multi-select, and free-text answer controls.

struct PlanReviewView: View {
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

#Preview("Plan review card") {
    PlanReviewView(
        request: PlanCenter.Request(
            agent: .claude,
            sessionID: "preview",
            cwd: "/Users/chaos/Documents/agent-notch",
            title: "Add multi-select support to AskUserQuestion",
            summary: "Extend SubQuestion with an isMultiSelect flag, render toggleable checkbox rows instead of single-shot buttons, and add a review-before-send confirmation step.",
            connection: nil,
            occurredAt: Date()
        ),
        resolve: { _, _ in }
    )
    .frame(width: 540, height: 190)
    .background(Color.black)
}

/// Arms an "interactive" binding after `DesignTokens.dwellGuardDelay`
/// (150ms), starting from `false`. Shared by `AgentQuestionView`,
/// `ApprovalOverlayView`, and `PlanApprovalOverlayView` — the dwell guard
/// against a fast double-click/double-Enter firing two actions before
/// SwiftUI re-renders disabled state.
func armDwellGuard(_ isInteractive: Binding<Bool>) {
    isInteractive.wrappedValue = false
    Task { @MainActor in
        try? await Task.sleep(nanoseconds: UInt64(DesignTokens.dwellGuardDelay * 1_000_000_000))
        isInteractive.wrappedValue = true
    }
}

struct AgentQuestionView: View {
    let request: QuestionCenter.Request
    /// Step/mode live on `uiState` rather than local `@State` so
    /// `NotchWindowController.questionOpenSize(for:)` can size the panel to
    /// fit the *current* step's content instead of one fixed size for the
    /// whole batch (see its doc comment). Reset in `.onAppear` — `.id(request.id)`
    /// at the call site still forces a fresh view per request, but `uiState`
    /// itself is long-lived and wouldn't otherwise reset between requests.
    @ObservedObject var uiState: NotchUIState
    /// Other question batches waiting behind this one — mirrors
    /// `ApprovalOverlayView`'s `extraCount`/`+N` badge so a second queued
    /// batch (e.g. from a different agent) doesn't sit invisibly behind the
    /// one currently shown.
    var extraCount: Int = 0
    /// Called exactly once, with every sub-question's answer collected —
    /// `request.connection` is shared across the whole batch and can only
    /// be responded to a single time (see `QuestionCenter.resolve(_:answers:)`).
    let onComplete: ([String]) -> Void
    @State private var collectedAnswers: [String] = []
    @State private var customAnswer = ""
    @State private var multiSelectedOptionIDs: Set<UUID> = []
    @FocusState private var customFieldFocused: Bool
    @State private var isInteractive = false
    /// Every other overlay (`ApprovalOverlayView`/`PlanApprovalOverlayView`)
    /// already reads this; AgentQuestionView's step/mode transitions didn't.
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var currentQuestion: QuestionCenter.SubQuestion { request.questions[uiState.questionStepIndex] }

    /// Drops the `.offset(y:)` component under Reduce Motion — a vertical
    /// slide is exactly the kind of motion that setting asks apps to avoid;
    /// a plain opacity crossfade still communicates the step changed.
    private var stepTransition: AnyTransition {
        reduceMotion ? .opacity : .opacity.combined(with: .offset(y: 2))
    }

    var body: some View {
        CellSurface {
            VStack(alignment: .leading, spacing: 7) {
                headerRow
                if uiState.questionReviewMode {
                    reviewView
                } else {
                    Text(currentQuestion.prompt)
                        .font(.system(size: 14, weight: .medium))
                        .tracking(-0.1)
                        .lineLimit(4)
                        .fixedSize(horizontal: false, vertical: true)
                        .help(currentQuestion.prompt)
                        // Measures this Text's own (unstretched) rendered
                        // height — it can run to several lines, so the panel
                        // is sized to fit it live instead of budgeting a
                        // fixed line count (which either clipped long
                        // prompts or wasted space on short ones). See
                        // `uiState.questionPromptHeight`.
                        .onGeometryChange(for: CGFloat.self, of: { $0.size.height }) { newHeight in
                            uiState.questionPromptHeight = newHeight
                        }
                    Group {
                        if uiState.questionCustomMode {
                            customAnswerView
                                .transition(stepTransition)
                        } else if currentQuestion.isMultiSelect {
                            multiSelectView
                                .transition(stepTransition)
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
                            .transition(stepTransition)
                        }
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
            uiState.questionReviewMode = false
            multiSelectedOptionIDs = []
            armInteractivity()
        }
    }

    /// Re-armed on every step transition (not just the view's initial
    /// appearance) — the 150ms dwell guard exists to stop a fast
    /// double-click/double-Enter from firing two answers before SwiftUI
    /// re-renders disabled state, a hazard that's identical when moving
    /// from one sub-question to the next within the same view instance.
    private func armInteractivity() {
        armDwellGuard($isInteractive)
    }

    private var headerRow: some View {
        HStack(spacing: 6) {
            Label(
                uiState.questionReviewMode
                    ? String(localized: "question.reviewHeader", defaultValue: "Review your answers")
                    : String(localized: "question.asks", defaultValue: "\(request.agent.displayName) asks"),
                systemImage: request.agent.symbolName
            )
            .font(.system(size: 12, weight: .semibold))
            .foregroundColor(request.agent == .codex ? .white.opacity(0.9) : DesignTokens.cyan)
            if !uiState.questionReviewMode {
                Text(currentQuestion.header)
                    .font(.system(size: 9.5, weight: .medium))
                    .foregroundColor(DesignTokens.muted)
                    .lineLimit(1)
                    .padding(.horizontal, 6)
                    .frame(height: 20)
                    .background(Capsule().fill(Color.white.opacity(0.07)))
                if request.questions.count > 1 {
                    HStack(spacing: 5) {
                        Text("\(uiState.questionStepIndex + 1)/\(request.questions.count)")
                            .font(.system(size: 9.5, weight: .medium))
                            .foregroundColor(DesignTokens.muted)
                            .lineLimit(1)
                        // Which sub-questions are already answered vs. still
                        // ahead — the plain "N/M" text alone doesn't make
                        // that legible at a glance.
                        HStack(spacing: 3) {
                            ForEach(0..<request.questions.count, id: \.self) { index in
                                Circle()
                                    .fill(
                                        index < uiState.questionStepIndex ? DesignTokens.cyan
                                        : index == uiState.questionStepIndex ? Color.white.opacity(0.8)
                                        : Color.white.opacity(0.18)
                                    )
                                    .frame(width: 5, height: 5)
                            }
                        }
                    }
                    .padding(.horizontal, 6)
                    .frame(height: 20)
                    .background(Capsule().fill(Color.white.opacity(0.07)))
                }
            }
            Spacer(minLength: 4)
            if !uiState.questionReviewMode {
                if extraCount > 0 {
                    Text(String(localized: "question.extraCount", defaultValue: "+\(String(extraCount))"))
                        .font(.system(size: 10.5, weight: .semibold))
                        .padding(.horizontal, 6)
                        .frame(height: 18)
                        .background(Capsule().fill(Color.white.opacity(0.09)))
                }
                if !currentQuestion.options.isEmpty {
                    Button(uiState.questionCustomMode ? String(localized: "question.choices", defaultValue: "Choices") : String(localized: "question.other", defaultValue: "Other…")) {
                        withAnimation(reduceMotion ? .easeOut(duration: 0.08) : .easeOut(duration: 0.20)) {
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

    /// Toggleable checkbox-style rows for a `multiSelect` sub-question —
    /// unlike single-select, no single tap unambiguously means "done", so a
    /// separate confirm button combines the current selection into one
    /// comma-joined answer and advances.
    private var multiSelectView: some View {
        VStack(spacing: 5) {
            ForEach(Array(currentQuestion.options.enumerated()), id: \.element.id) { index, option in
                MultiSelectChoiceRow(
                    title: option.label,
                    detail: option.detail,
                    isSelected: multiSelectedOptionIDs.contains(option.id),
                    key: index < 9 ? KeyEquivalent(Character("\(index + 1)")) : nil
                ) {
                    if multiSelectedOptionIDs.contains(option.id) {
                        multiSelectedOptionIDs.remove(option.id)
                    } else {
                        multiSelectedOptionIDs.insert(option.id)
                    }
                }
                .disabled(!isInteractive)
            }
            Button(action: confirmMultiSelect) {
                Text(String(localized: "question.continueButton", defaultValue: "Continue"))
                    .font(.system(size: 11, weight: .semibold))
                    .frame(maxWidth: .infinity, minHeight: 32)
                    .foregroundColor(.black)
                    .background(RoundedRectangle(cornerRadius: 8).fill(DesignTokens.cyan.opacity((!isInteractive || multiSelectedOptionIDs.isEmpty) ? 0.4 : 0.92)))
            }
            .buttonStyle(NotchPressStyle())
            .disabled(!isInteractive || multiSelectedOptionIDs.isEmpty)
            .keyboardShortcut(.return, modifiers: .command)
        }
    }

    /// The read-only screen shown after the last sub-question is answered —
    /// every answer is visible together before it's actually sent back to
    /// the (blocked) agent, since `resolve(_:answers:)` can only respond
    /// once. No per-answer editing here (that would need backward step
    /// navigation); the user can only confirm-send as a whole.
    private var reviewView: some View {
        VStack(alignment: .leading, spacing: 8) {
            ScrollView {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(Array(zip(request.questions, collectedAnswers)), id: \.0.id) { question, answer in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(question.header)
                                .font(.system(size: 9.5, weight: .semibold))
                                .foregroundColor(DesignTokens.muted)
                            Text(answer)
                                .font(.system(size: 11.5))
                                .foregroundColor(.white.opacity(0.85))
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
                .padding(.vertical, 4)
            }
            .frame(maxHeight: 108)
            Button(action: confirmSend) {
                Text(String(localized: "question.sendAllAnswers", defaultValue: "Send answers"))
                    .font(.system(size: 11, weight: .semibold))
                    .frame(maxWidth: .infinity, minHeight: 32)
                    .foregroundColor(.black)
                    .background(RoundedRectangle(cornerRadius: 8).fill(DesignTokens.cyan.opacity(0.92)))
            }
            .buttonStyle(NotchPressStyle())
            .disabled(!isInteractive)
            .keyboardShortcut(.return, modifiers: .command)
        }
    }

    private func submitCustomAnswer() {
        let value = customAnswer.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return }
        SoundPlayer.shared.play(.approve)
        advance(with: value)
    }

    private func confirmMultiSelect() {
        let labels = currentQuestion.options.filter { multiSelectedOptionIDs.contains($0.id) }.map(\.label)
        guard !labels.isEmpty else { return }
        SoundPlayer.shared.play(.approve)
        advance(with: labels.joined(separator: ", "))
    }

    private func confirmSend() {
        guard isInteractive else { return }
        isInteractive = false
        onComplete(collectedAnswers)
    }

    private func advance(with value: String) {
        var next = collectedAnswers
        next.append(value)
        multiSelectedOptionIDs = []
        if uiState.questionStepIndex + 1 < request.questions.count {
            collectedAnswers = next
            uiState.questionStepIndex += 1
            customAnswer = ""
            uiState.questionCustomMode = currentQuestion.options.isEmpty
            armInteractivity()
        } else {
            collectedAnswers = next
            uiState.questionReviewMode = true
            armInteractivity()
        }
    }
}

#Preview("Question — single-select, multi-question batch") {
    AgentQuestionView(
        request: QuestionCenter.Request(
            agent: .claude,
            sessionID: "preview",
            questions: [
                QuestionCenter.SubQuestion(
                    sourceQuestionID: "0",
                    prompt: "Which approach should I take for the retry logic?",
                    header: "Retry strategy",
                    options: [
                        QuestionCenter.Option(label: "Exponential backoff", detail: "Doubles the delay after each failure"),
                        QuestionCenter.Option(label: "Fixed interval", detail: "Retries every 2 seconds"),
                    ],
                    isMultiSelect: false
                ),
                QuestionCenter.SubQuestion(sourceQuestionID: "1", prompt: "Should I add a test for this?", header: "Testing", options: [], isMultiSelect: false),
            ],
            connection: nil,
            occurredAt: Date()
        ),
        uiState: NotchUIState(),
        extraCount: 1,
        onComplete: { _ in }
    )
    .frame(width: 540, height: 220)
    .background(Color.black)
}

#Preview("Question — multi-select") {
    AgentQuestionView(
        request: QuestionCenter.Request(
            agent: .codex,
            sessionID: "preview",
            questions: [
                QuestionCenter.SubQuestion(
                    sourceQuestionID: "0",
                    prompt: "Which features should be enabled for this build?",
                    header: "Features",
                    options: [
                        QuestionCenter.Option(label: "Dark mode", detail: ""),
                        QuestionCenter.Option(label: "Notifications", detail: ""),
                        QuestionCenter.Option(label: "Background sync", detail: ""),
                    ],
                    isMultiSelect: true
                ),
            ],
            connection: nil,
            occurredAt: Date()
        ),
        uiState: NotchUIState(),
        onComplete: { _ in }
    )
    .frame(width: 540, height: 260)
    .background(Color.black)
}

struct QuestionChoiceButton: View {
    let shortcut: String
    let key: KeyEquivalent
    let title: String
    let detail: String
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button {
            SoundPlayer.shared.play(.approve)
            HapticPlayer.shared.perform(.confirm)
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
        .accessibilityLabel(title)
        .accessibilityHint(detail)
    }
}

/// A toggleable row for `multiSelect` sub-questions — same visual family as
/// `QuestionChoiceButton` (same padding/row-height/hover pattern) but with a
/// persistent checkbox glyph instead of a one-shot chevron, since selecting
/// this option doesn't advance the question by itself.
struct MultiSelectChoiceRow: View {
    let title: String
    let detail: String
    let isSelected: Bool
    /// `nil` for the 10th+ option — `KeyEquivalent(Character(...))` can only
    /// hold a single grapheme cluster, so a two-digit index has no valid
    /// shortcut to assign (unlike `QuestionChoiceButton`'s existing
    /// `⌘1`-`⌘9` callers, which don't guard this; this row's own callers do,
    /// so it never sees an out-of-range index in the first place).
    var key: KeyEquivalent?
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        let button = Button(action: action) {
            HStack(spacing: 9) {
                Image(systemName: isSelected ? "checkmark.square.fill" : "square")
                    .font(.system(size: 14))
                    .foregroundColor(isSelected ? DesignTokens.cyan : .white.opacity(0.35))
                    .frame(width: 20)
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
            }
            .padding(.horizontal, 10)
            .frame(minHeight: detail.isEmpty ? 32 : 42)
            .background(RoundedRectangle(cornerRadius: 9).fill(Color.white.opacity(hovering ? 0.12 : (isSelected ? 0.09 : 0.065))))
        }
        .buttonStyle(NotchPressStyle())
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.18), value: hovering)
        .help(String(localized: "question.toggleSelectionHelp", defaultValue: "Toggle \(title)"))
        .accessibilityLabel(title)
        .accessibilityHint(detail)
        .accessibilityAddTraits(isSelected ? [.isSelected] : [])

        if let key {
            button.keyboardShortcut(key, modifiers: .command)
        } else {
            button
        }
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
struct SendAnswerButton: View {
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
        .keyboardShortcut(.return, modifiers: .command)
    }
}
