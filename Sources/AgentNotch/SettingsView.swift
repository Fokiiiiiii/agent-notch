import AppKit
import SwiftUI

/// Owns the settings window.
///
/// Not the SwiftUI `Settings` scene: in this `.accessory` app that scene
/// never actually opened. `NSApp.sendAction(Selector(("showSettingsWindow:")))`
/// returned `true` — claiming something had handled it — while no window
/// appeared, and `SettingsLink` (its supported replacement) behaved the
/// same. A plain `NSWindow` is created on demand instead, the same approach
/// the welcome screen's window originally used and the only one observed to
/// work here.
@MainActor
final class SettingsWindowController {
    static let shared = SettingsWindowController()

    private var window: NSWindow?

    private init() {}

    func show() {
        if let window {
            NSApp.activate(ignoringOtherApps: true)
            window.makeKeyAndOrderFront(nil)
            return
        }

        let hosting = NSHostingController(rootView: SettingsView(settings: AppSettings.shared))
        let window = NSWindow(contentViewController: hosting)
        window.title = String(localized: "settings.windowTitle", defaultValue: "AgentNotch Settings")
        window.styleMask = [.titled, .closable]
        // Kept alive across closes so reopening restores the previous tab
        // rather than rebuilding from scratch.
        window.isReleasedWhenClosed = false
        window.center()
        self.window = window

        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }
}

/// The app's settings window contents, split into tabs the
/// way macOS settings windows conventionally are — a single scrolling Form
/// had grown long enough that unrelated controls (a gesture toggle, a
/// permission warning, an animation slider) sat side by side with nothing
/// tying them together.
///
/// Every control here is bound to an `AppSettings` property that's genuinely
/// read somewhere else in the app — see each property's own doc comment in
/// `AppSettings.swift` for its consuming call sites. Properties that are
/// only persisted but not yet consumed anywhere (`languageOverride`) get no
/// control here on purpose, per the Phase 7 roadmap note:
/// "未実装・未接続の項目はUIに表示しない" (don't surface controls for
/// unimplemented/unwired settings). `tabLayouts` graduated out of that list
/// once `DashboardCell` started building its row from it — see the Nook tab.
struct SettingsView: View {
    @ObservedObject var settings: AppSettings
    @State private var selection: SettingsTab = .general

    var body: some View {
        VStack(spacing: 0) {
            tabBar
            Divider()
            Group {
                switch selection {
                case .general: GeneralSettingsTab(settings: settings)
                case .gestures: GestureSettingsTab(settings: settings)
                case .nook: NookSettingsTab(settings: settings)
                case .agents: AgentSettingsTab(settings: settings)
                case .permissions: PermissionSettingsTab()
                case .about: AboutSettingsTab()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(width: 520, height: 430)
    }

    /// Hand-rolled rather than `TabView` + `.tabItem`: that renders as a
    /// plain text segmented control here, dropping the SF Symbols entirely.
    /// An icon-over-label row is both what the reference settings windows
    /// use and what makes the tabs scannable at a glance.
    private var tabBar: some View {
        HStack(spacing: 2) {
            ForEach(SettingsTab.allCases) { tab in
                Button {
                    selection = tab
                } label: {
                    VStack(spacing: 3) {
                        Image(systemName: tab.icon)
                            .font(.system(size: 19, weight: .regular))
                            .frame(height: 22)
                        Text(tab.title)
                            .font(.system(size: 11))
                    }
                    .foregroundColor(selection == tab ? .accentColor : .primary.opacity(0.8))
                    .frame(width: 84, height: 52)
                    .background(
                        RoundedRectangle(cornerRadius: 7)
                            .fill(selection == tab ? Color.accentColor.opacity(0.15) : .clear)
                    )
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(tab.title)
                .accessibilityAddTraits(selection == tab ? [.isButton, .isSelected] : [.isButton])
                .accessibilityIdentifier("settings.tab.\(tab.rawValue)")
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity)
    }
}

enum SettingsTab: String, CaseIterable, Identifiable {
    case general, gestures, nook, agents, permissions, about

    var id: String { rawValue }

    var icon: String {
        switch self {
        case .general: return "gearshape"
        case .gestures: return "hand.draw"
        case .nook: return "square.grid.2x2"
        case .agents: return "terminal"
        case .permissions: return "lock.shield"
        case .about: return "info.circle"
        }
    }

    var title: String {
        switch self {
        case .general: return String(localized: "settings.tab.general", defaultValue: "General")
        case .gestures: return String(localized: "settings.tab.gestures", defaultValue: "Gestures")
        case .nook: return String(localized: "settings.tab.nook", defaultValue: "Nook")
        case .agents: return String(localized: "settings.tab.agents", defaultValue: "Agents")
        case .permissions: return String(localized: "settings.tab.permissions", defaultValue: "Permissions")
        case .about: return String(localized: "settings.tab.about", defaultValue: "About")
        }
    }
}

// MARK: - General

private struct GeneralSettingsTab: View {
    @ObservedObject var settings: AppSettings
    @ObservedObject private var visualizer = AudioVisualizer.shared

    /// Only shown once the user has actually asked for the visualizer —
    /// a stale error from a previous session shouldn't sit under a toggle
    /// that's currently off.
    private var visualizerError: String? {
        settings.visualizerEnabled ? visualizer.errorMessage : nil
    }

    var body: some View {
        Form {
            Section(String(localized: "settings.section.feedback", defaultValue: "Feedback")) {
                Toggle(String(localized: "settings.soundEffects", defaultValue: "Sound effects"), isOn: $settings.soundEnabled)
                    .help(String(localized: "settings.soundEffectsHelp", defaultValue: "Plays a short tone for approvals, questions, and other notch events."))
                Toggle(String(localized: "settings.hapticFeedback", defaultValue: "Haptic feedback"), isOn: $settings.hapticsEnabled)
                    .help(String(localized: "settings.hapticFeedbackHelp", defaultValue: "Pulses the trackpad for approvals, questions, and other notch events (Force Touch trackpads only)."))
            }

            Section(String(localized: "settings.section.visualizer", defaultValue: "Visualizer")) {
                Toggle(String(localized: "settings.visualizer", defaultValue: "React to system audio"), isOn: Binding(
                    get: { settings.visualizerEnabled },
                    set: { newValue in
                        settings.visualizerEnabled = newValue
                        AudioVisualizer.shared.setEnabled(newValue)
                    }
                ))
                .help(String(localized: "settings.visualizerHelp", defaultValue: "Drives the compact waveform from what's actually playing, instead of a looping animation."))
                Text(String(localized: "settings.visualizerPermissionNote", defaultValue: "Needs Screen Recording permission — macOS has no other way to read system audio. AgentNotch never captures the screen itself. After granting it, quit and reopen AgentNotch."))
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if let error = visualizerError {
                    Text(error)
                        .font(.caption)
                        .foregroundColor(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            Section(String(localized: "settings.section.appearance", defaultValue: "Appearance")) {
                ScaleRow(
                    title: String(localized: "settings.panelSize", defaultValue: "Panel size"),
                    help: String(localized: "settings.panelSizeHelp", defaultValue: "Scales the notch panel's width and height."),
                    value: $settings.uiScale,
                    range: 0.8...1.3,
                    defaultValue: 1.0
                )
                ScaleRow(
                    title: String(localized: "settings.cornerRoundness", defaultValue: "Corner roundness"),
                    help: String(localized: "settings.cornerRoundnessHelp", defaultValue: "Scales the panel's corner radius."),
                    value: $settings.cornerRadiusScale,
                    range: 0.5...1.5,
                    defaultValue: 1.0
                )
                ScaleRow(
                    title: String(localized: "settings.animationSpeed", defaultValue: "Animation speed"),
                    help: String(localized: "settings.animationSpeedHelp", defaultValue: "Scales how long spring/fade animations take. Lower is faster."),
                    value: $settings.animationSpeedScale,
                    range: 0.5...2.0,
                    defaultValue: 1.0,
                    formatter: { String(format: "%.1f×", $0) }
                )
            }
        }
        .formStyle(.grouped)
    }
}

// MARK: - Gestures

private struct GestureSettingsTab: View {
    @ObservedObject var settings: AppSettings

    var body: some View {
        Form {
            Section(String(localized: "settings.section.media", defaultValue: "Media")) {
                Toggle(String(localized: "settings.mediaSwipe", defaultValue: "Swipe sideways to change track"), isOn: $settings.mediaSwipeEnabled)
                    .help(String(localized: "settings.mediaSwipeHelp", defaultValue: "Scroll sideways over the compact notch to skip tracks. While the notch is open the same gesture switches pages instead."))
                Toggle(String(localized: "settings.invertMediaSwipe", defaultValue: "Invert track-change direction"), isOn: $settings.invertMediaSwipe)
                    .disabled(!settings.mediaSwipeEnabled)
                    .help(String(localized: "settings.invertMediaSwipeHelp", defaultValue: "By default swiping left plays the next track."))
            }

            Section(String(localized: "settings.section.builtInGestures", defaultValue: "Built in")) {
                gestureRow(
                    icon: "arrow.up.and.down",
                    text: String(localized: "onboarding.swipeVertical", defaultValue: "Swipe up or down to open, close, or hide the notch")
                )
                gestureRow(
                    icon: "cursorarrow.click.2",
                    text: String(localized: "onboarding.click", defaultValue: "Click to open the Nook, where your widgets live")
                )
                gestureRow(
                    icon: "tray.and.arrow.down.fill",
                    text: String(localized: "onboarding.dragDrop", defaultValue: "Drag and drop files onto the notch to stash them in the Tray")
                )
            }
        }
        .formStyle(.grouped)
    }

    /// Read-only reference for the gestures that have no setting to change —
    /// they're listed so this tab answers "what gestures exist?", not only
    /// "which ones can I configure?".
    private func gestureRow(icon: String, text: String) -> some View {
        HStack(spacing: 10) {
            Image(systemName: icon)
                .foregroundColor(.secondary)
                .frame(width: 18)
            Text(text)
                .font(.callout)
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.vertical, 1)
    }
}

// MARK: - Nook

/// Controls which widgets the Dashboard page shows and in what order.
/// Writes `AppSettings.tabLayouts[DashboardWidget.layoutKey]`, which
/// `DashboardCell` reads on every render.
private struct NookSettingsTab: View {
    @ObservedObject var settings: AppSettings
    @State private var installedShortcuts: [String] = []

    /// Every widget, in the user's order, with the ones they've hidden
    /// appended — the list has to show hidden widgets too, or there'd be no
    /// way to turn one back on.
    private var rows: [DashboardWidget] {
        let visible = DashboardWidget.resolved(from: settings.tabLayouts[DashboardWidget.layoutKey])
        return visible + DashboardWidget.allCases.filter { !visible.contains($0) }
    }

    private var configuration: TabLayoutConfiguration {
        settings.tabLayouts[DashboardWidget.layoutKey] ?? TabLayoutConfiguration(widgets: [])
    }

    var body: some View {
        Form {
            Section(String(localized: "settings.section.dashboardWidgets", defaultValue: "Dashboard widgets")) {
                ForEach(Array(rows.enumerated()), id: \.element.id) { index, widget in
                    HStack(spacing: 10) {
                        Image(systemName: widget.symbolName)
                            .foregroundColor(.secondary)
                            .frame(width: 18)
                        Toggle(widget.displayName, isOn: binding(for: widget))
                        Spacer(minLength: 8)
                        // Plain up/down buttons rather than `.onMove`: this
                        // Form isn't a `List`, and a two-item row reorders
                        // fine without drag affordances.
                        Button {
                            move(widget, by: -1)
                        } label: {
                            Image(systemName: "chevron.up")
                        }
                        .disabled(index == 0)
                        .accessibilityLabel(String(localized: "settings.moveWidgetUp", defaultValue: "Move up"))
                        Button {
                            move(widget, by: 1)
                        } label: {
                            Image(systemName: "chevron.down")
                        }
                        .disabled(index == rows.count - 1)
                        .accessibilityLabel(String(localized: "settings.moveWidgetDown", defaultValue: "Move down"))
                    }
                    .padding(.vertical, 2)
                }
                Text(String(localized: "settings.dashboardWidgetsHelp", defaultValue: "Widgets are laid out left to right in this order. The notch panel keeps its width, so the widgets share it."))
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.vertical, 2)
            }

            Section(String(localized: "settings.section.shortcuts", defaultValue: "Shortcuts")) {
                ForEach(settings.registeredShortcuts) { shortcut in
                    HStack(spacing: 10) {
                        Image(systemName: "bolt")
                            .foregroundColor(.secondary)
                            .frame(width: 18)
                        Text(shortcut.name)
                        Spacer(minLength: 8)
                        Button(role: .destructive) {
                            settings.registeredShortcuts.removeAll { $0.id == shortcut.id }
                        } label: {
                            Image(systemName: "minus.circle")
                        }
                        .accessibilityLabel(String(localized: "settings.removeShortcut", defaultValue: "Remove shortcut"))
                    }
                    .padding(.vertical, 2)
                }

                if installedShortcuts.isEmpty {
                    // Either Shortcuts has none, or `shortcuts list` failed —
                    // both leave the user with nothing to pick, so say so
                    // rather than showing an empty menu.
                    Text(String(localized: "settings.noShortcutsFound", defaultValue: "No shortcuts found. Create one in the Shortcuts app, then reopen this window."))
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.vertical, 2)
                } else {
                    Menu(String(localized: "settings.addShortcut", defaultValue: "Add shortcut…")) {
                        ForEach(unregisteredShortcuts, id: \.self) { name in
                            Button(name) {
                                settings.registeredShortcuts.append(ShortcutBinding(name: name))
                            }
                        }
                    }
                    .disabled(unregisteredShortcuts.isEmpty)
                }

                Text(String(localized: "settings.shortcutsHelp", defaultValue: "Registered shortcuts appear in the Tray's ⋯ menu. Running one passes the selected Tray files to it as input."))
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.vertical, 2)
            }

            Section {
                Button(String(localized: "settings.resetLayout", defaultValue: "Reset to default layout")) {
                    settings.tabLayouts[DashboardWidget.layoutKey] = nil
                }
                .disabled(settings.tabLayouts[DashboardWidget.layoutKey] == nil)
            }
        }
        .formStyle(.grouped)
        // Read once per appearance rather than on every render: each call
        // spawns `shortcuts list`, and the user's shortcut set doesn't change
        // while this window sits open.
        .onAppear { installedShortcuts = ShortcutRunner.installedNames() }
    }

    private var unregisteredShortcuts: [String] {
        let taken = Set(settings.registeredShortcuts.map(\.name))
        return installedShortcuts.filter { !taken.contains($0) }
    }

    private func binding(for widget: DashboardWidget) -> Binding<Bool> {
        Binding(
            // Falls back to the widget's own default, not a blanket `true`:
            // an opt-in widget with nothing stored yet is off, and the
            // toggle has to say so.
            get: { item(for: widget)?.isVisible ?? widget.isEnabledByDefault },
            set: { newValue in
                var config = normalized()
                if let index = config.widgets.firstIndex(where: { $0.id == widget.id }) {
                    config.widgets[index].isVisible = newValue
                }
                settings.tabLayouts[DashboardWidget.layoutKey] = config
            }
        )
    }

    private func item(for widget: DashboardWidget) -> WidgetLayoutItem? {
        configuration.widgets.first { $0.id == widget.id }
    }

    /// A stored configuration can be partial (`applying(to:)` tolerates
    /// that), but editing needs every widget present with a concrete order,
    /// so the first edit materializes the full list in its current order.
    private func normalized() -> TabLayoutConfiguration {
        let ordered = rows
        let existing = Dictionary(uniqueKeysWithValues: configuration.widgets.map { ($0.id, $0) })
        let widgets = ordered.enumerated().map { index, widget -> WidgetLayoutItem in
            var item = existing[widget.id]
                // `WidgetLayoutItem`'s own `isVisible` default is `true`, so
                // materializing an opt-in widget without this would silently
                // switch it on the first time any row is edited.
                ?? WidgetLayoutItem(id: widget.id, isVisible: widget.isEnabledByDefault, order: index)
            item.order = index
            item.displayName = widget.displayName
            return item
        }
        return TabLayoutConfiguration(widgets: widgets)
    }

    private func move(_ widget: DashboardWidget, by offset: Int) {
        var ordered = rows
        guard let from = ordered.firstIndex(of: widget) else { return }
        let to = from + offset
        guard ordered.indices.contains(to) else { return }
        ordered.swapAt(from, to)
        var config = normalized()
        for (index, widget) in ordered.enumerated() {
            if let position = config.widgets.firstIndex(where: { $0.id == widget.id }) {
                config.widgets[position].order = index
            }
        }
        settings.tabLayouts[DashboardWidget.layoutKey] = config
    }
}

// MARK: - Agents

/// AgentNotch's own tab — the part of this app that has no counterpart in a
/// general-purpose notch utility. Covers how agent requests interrupt you,
/// and whether the CLI hooks that feed them are installed at all.
private struct AgentSettingsTab: View {
    @ObservedObject var settings: AppSettings
    /// Re-read on appear: `agent-notch setup` can be run from a terminal
    /// while this window is open, and nothing notifies us.
    @State private var hasIntegrationHelper = AgentIntegration.isHelperInstalled

    var body: some View {
        Form {
            Section(String(localized: "settings.section.requests", defaultValue: "Requests")) {
                Toggle(String(localized: "settings.autoOpenOnAttention", defaultValue: "Open the notch for approvals and questions"), isOn: $settings.autoOpenOnAttention)
                    .help(String(localized: "settings.autoOpenOnAttentionHelp", defaultValue: "When off, an incoming request only shows the compact badge and waits for you to click it — nothing is auto-approved either way."))
            }

            Section(String(localized: "settings.section.integration", defaultValue: "CLI integration")) {
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 6) {
                        Image(systemName: hasIntegrationHelper ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                            .foregroundColor(hasIntegrationHelper ? .green : .orange)
                        Text(hasIntegrationHelper
                             ? String(localized: "settings.integrationInstalled", defaultValue: "Integration helper installed")
                             : String(localized: "settings.integrationMissing", defaultValue: "Integration helper not found"))
                            .font(.callout.weight(.medium))
                    }
                    Text(String(localized: "settings.integrationHelp", defaultValue: "Hooks let Claude and Codex send approvals, questions, and session status to the notch. Run this in a terminal to install or repair them:"))
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    // Shown as copyable text rather than run from a button:
                    // the helper is interactive and its output matters, so
                    // it belongs in a terminal the user can actually read.
                    Text(verbatim: "agent-notch setup")
                        .font(.system(.caption, design: .monospaced))
                        .textSelection(.enabled)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 3)
                        .background(RoundedRectangle(cornerRadius: 5).fill(Color.secondary.opacity(0.12)))
                }
                .padding(.vertical, 2)
            }
        }
        .formStyle(.grouped)
        .onAppear { hasIntegrationHelper = AgentIntegration.isHelperInstalled }
    }
}

/// Where the CLI's `setup` subcommand looks for its installer, mirrored here
/// so Settings can report whether integration was ever set up. Kept in sync
/// with `agent-notch-bridge/main.swift`'s own path.
enum AgentIntegration {
    static var helperURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".agent-notch/bin/setup-integrations")
    }

    static var isHelperInstalled: Bool {
        FileManager.default.isExecutableFile(atPath: helperURL.path)
    }
}

// MARK: - Permissions

/// Surfaces the permissions AgentNotch can't function fully without, and
/// which otherwise fail silently: notifications (see `NativeNotifier`'s
/// "best-effort only" doc comment), Accessibility for media keys, and
/// Reminders for the Today widget's agenda line. All are shown whether
/// granted or not, so this tab always answers "is it set up?" rather than
/// only appearing when something is broken.
private struct PermissionSettingsTab: View {
    @ObservedObject private var notifier = NativeNotifier.shared
    /// Reminder access is requested here rather than from the notch itself:
    /// the Today widget has one agenda line and no room for a second
    /// permission button next to the calendar one.
    @ObservedObject private var today = TodayModel.shared
    /// Accessibility trust can be granted in System Settings while this
    /// window is open, and nothing notifies us — re-read it when the view
    /// reappears (tab switch) so it can't sit indefinitely stale.
    @State private var isAccessibilityTrusted = MediaKeyMonitor.isAccessibilityTrusted

    var body: some View {
        Form {
            Section(String(localized: "settings.section.notifications", defaultValue: "Notifications")) {
                permissionRow(
                    granted: notifier.isAuthorized,
                    // Before the async system prompt resolves, `isAuthorized`
                    // is still false for a perfectly healthy install — don't
                    // call that denied.
                    pending: !notifier.didRequestAuthorization,
                    description: String(localized: "settings.notificationsPurpose", defaultValue: "Lets AgentNotch alert you when the notch itself isn't visible (for example, in full screen)."),
                    detail: notifier.lastAuthorizationError,
                    actionTitle: String(localized: "settings.openNotificationSettings", defaultValue: "Open Notification Settings…"),
                    action: { openSystemSettings("x-apple.systempreferences:com.apple.Notifications-Settings.extension") }
                )
            }

            Section(String(localized: "settings.section.reminders", defaultValue: "Reminders")) {
                permissionRow(
                    granted: today.canReadReminders,
                    pending: today.reminderAuthorizationStatus == .notDetermined,
                    description: String(localized: "settings.remindersPurpose", defaultValue: "Shows reminders due today in the Dashboard's calendar widget, alongside your events."),
                    detail: nil,
                    actionTitle: String(localized: "settings.grantReminders", defaultValue: "Allow Reminders Access…"),
                    action: { today.requestRemindersAccess() }
                )
            }

            Section(String(localized: "settings.section.mediaKeys", defaultValue: "Media keys")) {
                permissionRow(
                    granted: isAccessibilityTrusted,
                    pending: false,
                    description: String(localized: "settings.mediaKeysNeedAccessibility", defaultValue: "Allow Accessibility access to show a skip indicator when you press the media keys."),
                    detail: nil,
                    actionTitle: String(localized: "settings.grantAccessibility", defaultValue: "Allow Accessibility Access…"),
                    action: { MediaKeyMonitor.requestAccessibilityTrust() }
                )
            }
        }
        .formStyle(.grouped)
        .onAppear { isAccessibilityTrusted = MediaKeyMonitor.isAccessibilityTrusted }
    }

    @ViewBuilder
    private func permissionRow(
        granted: Bool,
        pending: Bool,
        description: String,
        detail: String?,
        actionTitle: String,
        action: @escaping () -> Void
    ) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: granted ? "checkmark.circle.fill" : (pending ? "clock" : "exclamationmark.triangle.fill"))
                    .foregroundColor(granted ? .green : (pending ? .secondary : .orange))
                Text(granted
                     ? String(localized: "settings.permissionGranted", defaultValue: "Allowed")
                     : (pending
                        ? String(localized: "settings.permissionPending", defaultValue: "Not requested yet")
                        : String(localized: "settings.permissionMissing", defaultValue: "Not allowed")))
                    .font(.callout.weight(.medium))
            }
            Text(description)
                .font(.caption)
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if let detail {
                Text(detail)
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            if !granted {
                Button(actionTitle, action: action)
                    .buttonStyle(.link)
            }
        }
        .padding(.vertical, 2)
    }

    /// Same `NSWorkspace.shared.open` pattern as `CompactBatteryIndicator`'s
    /// own settings link in `NotchView.swift` — duplicated locally rather
    /// than shared because that one is `private` to its own file.
    private func openSystemSettings(_ rawURL: String) {
        guard let url = URL(string: rawURL) else { return }
        NSWorkspace.shared.open(url)
    }
}

// MARK: - About

private struct AboutSettingsTab: View {
    var body: some View {
        Form {
            Section {
                VStack(alignment: .leading, spacing: 2) {
                    Text(String(localized: "settings.title", defaultValue: "AgentNotch Settings"))
                        .font(.title2.bold())
                    Text(String(localized: "settings.version", defaultValue: "Version \(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0")"))
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                .padding(.vertical, 2)
            }

            Section(String(localized: "settings.section.help", defaultValue: "Help")) {
                Button(String(localized: "settings.showWelcome", defaultValue: "Show Welcome Screen…")) {
                    NotificationCenter.default.post(name: .agentNotchReplayOnboarding, object: nil)
                }
                .help(String(localized: "settings.showWelcomeHelp", defaultValue: "Reopens the gesture guide shown on first launch."))
            }
        }
        .formStyle(.grouped)
    }
}

// MARK: - Shared rows

/// One labeled slider row with a live value readout and a reset button that
/// only appears once the value has actually drifted from `defaultValue` —
/// keeps the common (untouched) case visually quiet.
private struct ScaleRow: View {
    let title: String
    let help: String
    @Binding var value: Double
    let range: ClosedRange<Double>
    let defaultValue: Double
    var formatter: (Double) -> String = { String(format: "%.0f%%", $0 * 100) }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(title)
                Spacer()
                Text(formatter(value))
                    .foregroundColor(.secondary)
                    .monospacedDigit()
                if abs(value - defaultValue) > 0.001 {
                    Button(String(localized: "settings.reset", defaultValue: "Reset")) {
                        value = defaultValue
                    }
                    .buttonStyle(.plain)
                    .foregroundColor(.accentColor)
                    .font(.caption)
                }
            }
            Slider(value: $value, in: range)
        }
        .help(help)
        .padding(.vertical, 2)
    }
}
