import SwiftUI
import UniformTypeIdentifiers

struct NotchView: View {
    @ObservedObject var store: SessionStore
    let controller: NotchWindowController
    @ObservedObject var permissions: PermissionCenter
    @EnvironmentObject var uiState: NotchUIState
    @State private var trayItems: [TrayItem] = []
    @State private var isDropTargeted = false
    @State private var trayFeedback: String?

    var body: some View {
        ZStack(alignment: .top) {
            Color.black.opacity(0.001)
            ZStack {
                shapeBackground
                content
            }
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

    private var shapeBackground: some View {
        let radius: CGFloat = uiState.mode == .open ? DesignTokens.openRadius : DesignTokens.closedRadius
        let shape = UnevenRoundedRectangle(
            topLeadingRadius: 0,
            bottomLeadingRadius: radius,
            bottomTrailingRadius: radius,
            topTrailingRadius: 0
        )
        return shape
            .fill(Color.black)
            .shadow(color: DesignTokens.shellShadowColor, radius: DesignTokens.shellShadowRadius, y: DesignTokens.shellShadowY)
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
        .padding(.horizontal, 14)
        .contentShape(Rectangle())
        .onTapGesture { controller.toggleOpen() }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
        .accessibilityLabel("Open AgentNotch")
        .accessibilityAction { controller.toggleOpen() }
    }

    // MARK: - Notice (structure only; nothing triggers this mode yet)

    private var noticeContent: some View {
        // TODO: no notification source is wired up yet. This mirrors the
        // mock's `.compact.notice-content` layout so IslandMode.notice has a
        // real view once a trigger exists.
        HStack(alignment: .top, spacing: 9) {
            GlyphBox(agent: nil)
            VStack(alignment: .leading, spacing: 2) {
                Text("Notification")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(.white)
                Text(" ")
                    .font(.system(size: 9))
                    .foregroundColor(DesignTokens.muted)
            }
            Spacer()
        }
        .padding(.horizontal, 14)
        .padding(.top, 8)
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
            .frame(maxHeight: .infinity)
        }
        .padding(.horizontal, 14)
        .padding(.top, 8)
        .padding(.bottom, 13)
    }

    private var nookbar: some View {
        HStack(spacing: 6) {
            HStack(spacing: 4) {
                tabButton(title: "Nook", icon: "sparkles", isActive: uiState.activeTab == .nook) {
                    uiState.activeTab = .nook
                }
                tabButton(title: "Tray", icon: "tray.full", isActive: uiState.activeTab == .tray) {
                    uiState.activeTab = .tray
                }
            }
            Spacer()
            Button { controller.closeExplicitly() } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 13))
                    .foregroundColor(.white.opacity(0.62))
                    .frame(width: 27, height: 27)
            }
            .buttonStyle(.plain)
        }
        .frame(height: 29)
    }

    private func tabButton(title: String, icon: String, isActive: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(title, systemImage: icon)
                .font(.system(size: 10.5, weight: .semibold))
                .foregroundColor(isActive ? .white : .white.opacity(0.72))
                .padding(.horizontal, 10)
                .frame(height: 27)
                .background(
                    Capsule().fill(isActive ? Color.white.opacity(0.13) : Color.clear)
                )
        }
        .buttonStyle(.plain)
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
            viewDots
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
                }
            )
        case .plan:
            PlanReviewView { uiState.overlay = nil }
        case .question:
            AgentQuestionView { uiState.overlay = nil }
        }
    }

    private var viewDots: some View {
        HStack(spacing: 6) {
            ForEach(NookView.allCases, id: \.self) { view in
                Button {
                    uiState.activeView = view
                } label: {
                    RoundedRectangle(cornerRadius: 4)
                        .fill(uiState.activeView == view ? Color.white.opacity(0.72) : Color.white.opacity(0.22))
                        .frame(width: uiState.activeView == view ? 14 : 5, height: 5)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(view.title)
            }
        }
        .frame(height: 10)
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
            .fill(DesignTokens.surface2)
            .overlay(
                RoundedRectangle(cornerRadius: 14)
                    .stroke(Color.white.opacity(0.035), lineWidth: 1)
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
        .onTapGesture(count: 2) {
            Jumper.jump(to: session)
        }
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
                    uiState.selectedSessionId = session.id
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
                .buttonStyle(.plain)
                .help(session.title)
            }
            Spacer(minLength: 4)
            MiniButton(title: selected.map { pausedSessionIDs.contains($0.id) ? "Resume" : "Pause" } ?? "Pause") {
                guard let selected else { return }
                if pausedSessionIDs.contains(selected.id) {
                    pausedSessionIDs.remove(selected.id)
                    actionFeedback = "Resume requested"
                } else {
                    pausedSessionIDs.insert(selected.id)
                    actionFeedback = "Pause requested"
                }
            }
            MiniButton(title: "Stop", isDanger: true) {
                actionFeedback = "Stop requested"
            }
            MiniButton(title: "Terminal") {
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
    var isDanger: Bool = false
    var isPrimary: Bool = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 8.5, weight: isPrimary ? .semibold : .regular))
                .foregroundColor(textColor)
                .padding(.horizontal, 8)
                .frame(height: 24)
                .background(
                    RoundedRectangle(cornerRadius: 8)
                        .fill(backgroundColor)
                )
        }
        .buttonStyle(.plain)
    }

    private var textColor: Color {
        if isPrimary { return .black }
        if isDanger { return Color(red: 0xF0 / 255, green: 0xA0 / 255, blue: 0x9B / 255) }
        return .white.opacity(0.72)
    }

    private var backgroundColor: Color {
        if isPrimary { return Color(white: 0.965) }
        if isDanger { return DesignTokens.red.opacity(0.13) }
        return Color.white.opacity(0.085)
    }
}

// MARK: - Nook pages

private struct CellSurface<Content: View>: View {
    let content: Content

    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    var body: some View {
        RoundedRectangle(cornerRadius: 14)
            .fill(DesignTokens.surface2)
            .overlay(RoundedRectangle(cornerRadius: 14).stroke(DesignTokens.line.opacity(0.45), lineWidth: 1))
            .overlay(content.padding(9))
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
                    .frame(width: 82, height: 82)
                    .overlay(Image(systemName: "waveform").font(.system(size: 24, weight: .light)).foregroundColor(.white.opacity(0.82)))
                VStack(alignment: .leading, spacing: 7) {
                    Text("Night Drive").font(.system(size: 12, weight: .semibold)).lineLimit(1)
                    Text("Neon Coast · Apple Music").font(.system(size: 9)).foregroundColor(DesignTokens.muted).lineLimit(1)
                    Slider(value: $progress).controlSize(.mini).tint(.white.opacity(0.9))
                    HStack {
                        Button { progress = max(0, progress - 0.08) } label: { Image(systemName: "backward.fill") }
                        Button { isPlaying.toggle() } label: { Image(systemName: isPlaying ? "pause.fill" : "play.fill").frame(width: 22) }
                        Button { progress = min(1, progress + 0.08) } label: { Image(systemName: "forward.fill") }
                        Spacer()
                        Image(systemName: "speaker.fill").foregroundColor(DesignTokens.muted)
                        Slider(value: $volume).frame(width: 74).controlSize(.mini)
                    }
                    .font(.system(size: 11))
                    .buttonStyle(.plain)
                }
            }
            .foregroundColor(.white)
        }
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
                    Button { focusRunning.toggle() } label: {
                        Label(focusRunning ? "End Focus · 21:42" : "Start Focus", systemImage: focusRunning ? "timer" : "moon.fill")
                            .font(.system(size: 9, weight: .medium)).frame(height: 24).padding(.horizontal, 9)
                            .background(RoundedRectangle(cornerRadius: 8).fill(Color.white.opacity(0.09)))
                    }.buttonStyle(.plain)
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
            VStack(spacing: 8) {
                HStack(spacing: 8) {
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
        HStack(spacing: 6) {
            Image(systemName: icon).font(.system(size: 11)).foregroundColor(.white.opacity(0.72))
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(.system(size: 7)).foregroundColor(DesignTokens.muted)
                Text(value).font(.system(size: 9, weight: .semibold)).lineLimit(1)
            }
            Spacer(minLength: 0)
        }.padding(7).background(RoundedRectangle(cornerRadius: 9).fill(Color.white.opacity(0.055)))
    }
}

private struct TaskProgress: View {
    let icon: String, title: String, progress: Double, detail: String
    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: icon).frame(width: 16).foregroundColor(.white.opacity(0.72))
            VStack(alignment: .leading, spacing: 4) {
                HStack { Text(title).font(.system(size: 9, weight: .medium)).lineLimit(1); Spacer(); Text(detail).font(.system(size: 7)).foregroundColor(DesignTokens.muted) }
                ProgressView(value: progress).progressViewStyle(.linear).tint(.white.opacity(0.72))
            }
        }
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
                    Button { action(.clear) } label: { Image(systemName: "trash").frame(width: 24, height: 22) }.buttonStyle(.plain).disabled(items.isEmpty)
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
        Button(action: action) { Label(title, systemImage: icon).font(.system(size: 7.5)).padding(.horizontal, 8).frame(height: 24).background(RoundedRectangle(cornerRadius: 8).fill(Color.white.opacity(0.08))) }.buttonStyle(.plain)
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
                HStack { MiniButton(title: "Request Changes", isDanger: true, action: dismiss); MiniButton(title: "Approve Plan", isPrimary: true, action: dismiss); MiniButton(title: "Open Terminal", action: dismiss) }
            }.foregroundColor(.white)
        }
    }
}

private struct AgentQuestionView: View {
    @State private var answer = ""
    let dismiss: () -> Void
    var body: some View {
        CellSurface {
            VStack(alignment: .leading, spacing: 7) {
                Label("Agent Question", systemImage: "questionmark.bubble").font(.system(size: 10, weight: .semibold))
                Text("Which compatibility target should I use?").font(.system(size: 11, weight: .semibold))
                HStack { MiniButton(title: "macOS 14", isPrimary: true, action: dismiss); MiniButton(title: "macOS 13", action: dismiss); MiniButton(title: "Current only", action: dismiss) }
                TextField("Write another answer…", text: $answer).textFieldStyle(.plain).font(.system(size: 9)).padding(7).background(RoundedRectangle(cornerRadius: 7).fill(Color.white.opacity(0.07)))
                HStack { Spacer(); MiniButton(title: "Send Answer", isPrimary: true, action: dismiss) }
            }.foregroundColor(.white)
        }
    }
}

// MARK: - Approval overlay (driven by PermissionCenter.queue)

private struct ApprovalOverlayView: View {
    let toolName: String
    let summary: String
    var extraCount: Int = 0
    var onAllowOnce: () -> Void = {}
    var onDeny: () -> Void = {}
    // NOTE: the mock also has "This Session" and "Edit" buttons here; per
    // spec they are intentionally left out for now.

    var body: some View {
        CellSurface {
            VStack(alignment: .leading, spacing: 5) {
                    HStack(spacing: 6) {
                        Circle()
                            .fill(DesignTokens.orange)
                            .frame(width: 6, height: 6)
                        Text("Permission Request · Claude")
                            .font(.system(size: 8))
                            .foregroundColor(DesignTokens.muted)
                        if extraCount > 0 {
                            Spacer(minLength: 4)
                            Text("+\(extraCount) more")
                                .font(.system(size: 7, weight: .medium))
                                .foregroundColor(.white.opacity(0.55))
                                .padding(.horizontal, 5)
                                .padding(.vertical, 2)
                                .background(
                                    Capsule().fill(Color.white.opacity(0.08))
                                )
                        }
                    }
                    Text(toolName)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundColor(.white)
                        .lineLimit(2)
                    Text(summary)
                        .font(.system(size: 7.5, design: .monospaced))
                        .foregroundColor(.white.opacity(0.6))
                        .padding(6)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(
                            RoundedRectangle(cornerRadius: 6)
                                .fill(Color.white.opacity(0.04))
                        )
                Spacer(minLength: 4)
                HStack(spacing: 5) {
                    MiniButton(title: "Allow Once", isPrimary: true, action: onAllowOnce)
                    MiniButton(title: "Deny", isDanger: true, action: onDeny)
                }
            }
        }
    }
}
