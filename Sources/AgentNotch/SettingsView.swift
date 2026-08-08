import SwiftUI

/// The app's settings window (SwiftUI `Settings` scene). Every control here
/// is bound to an `AppSettings` property that's genuinely read somewhere
/// else in the app — see each property's own doc comment in
/// `AppSettings.swift` for its consuming call sites. Properties that are
/// only persisted but not yet consumed anywhere (`languageOverride`,
/// `tabLayouts`) get no control here on purpose, per the Phase 7 roadmap
/// note: "未実装・未接続の項目はUIに表示しない" (don't surface controls for
/// unimplemented/unwired settings). The one exception is the notification
/// status section below: it doesn't bind to an `AppSettings` property at
/// all — it surfaces `NativeNotifier.shared`'s live authorization state
/// (previously visible only via `agent-notch ping`'s debug JSON) plus a
/// link out to System Settings, since a denied/unauthorized notification
/// permission otherwise fails completely silently (see `NativeNotifier`'s
/// own "best-effort only" doc comment).
struct SettingsView: View {
    @ObservedObject var settings: AppSettings
    @ObservedObject private var notifier = NativeNotifier.shared

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
            }

            Section(String(localized: "settings.section.general", defaultValue: "General")) {
                Toggle(String(localized: "settings.soundEffects", defaultValue: "Sound effects"), isOn: $settings.soundEnabled)
                    .help(String(localized: "settings.soundEffectsHelp", defaultValue: "Plays a short tone for approvals, questions, and other notch events."))
                Toggle(String(localized: "settings.hapticFeedback", defaultValue: "Haptic feedback"), isOn: $settings.hapticsEnabled)
                    .help(String(localized: "settings.hapticFeedbackHelp", defaultValue: "Pulses the trackpad for approvals, questions, and other notch events (Force Touch trackpads only)."))
            }

            Section(String(localized: "settings.section.gestures", defaultValue: "Gestures")) {
                Toggle(String(localized: "settings.mediaSwipe", defaultValue: "Swipe sideways to change track"), isOn: $settings.mediaSwipeEnabled)
                    .help(String(localized: "settings.mediaSwipeHelp", defaultValue: "Scroll sideways over the compact notch to skip tracks. While the notch is open the same gesture switches pages instead."))
                Toggle(String(localized: "settings.invertMediaSwipe", defaultValue: "Invert track-change direction"), isOn: $settings.invertMediaSwipe)
                    .disabled(!settings.mediaSwipeEnabled)
                    .help(String(localized: "settings.invertMediaSwipeHelp", defaultValue: "By default swiping left plays the next track."))
            }

            // Only shown once authorization has actually been requested and
            // came back denied — never on cold start, where `isAuthorized`
            // is still `false` simply because the async system prompt
            // hasn't resolved yet (that transient state would otherwise
            // flash a false warning on every launch).
            if notifier.didRequestAuthorization, !notifier.isAuthorized {
                Section(String(localized: "settings.section.notifications", defaultValue: "Notifications")) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(String(localized: "settings.notificationsDenied", defaultValue: "Notifications are off. AgentNotch can't alert you when the notch itself isn't visible (e.g. while in full screen)."))
                            .font(.callout)
                        if let error = notifier.lastAuthorizationError {
                            Text(error)
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                        Button(String(localized: "settings.openNotificationSettings", defaultValue: "Open Notification Settings…")) {
                            openSystemSettings("x-apple.systempreferences:com.apple.Notifications-Settings.extension")
                        }
                        .buttonStyle(.link)
                    }
                    .padding(.vertical, 2)
                }
            }

            Section(String(localized: "settings.section.appearance", defaultValue: "Appearance")) {
                scaleRow(
                    title: String(localized: "settings.panelSize", defaultValue: "Panel size"),
                    help: String(localized: "settings.panelSizeHelp", defaultValue: "Scales the notch panel's width and height."),
                    value: $settings.uiScale,
                    range: 0.8...1.3,
                    defaultValue: 1.0
                )
                scaleRow(
                    title: String(localized: "settings.cornerRoundness", defaultValue: "Corner roundness"),
                    help: String(localized: "settings.cornerRoundnessHelp", defaultValue: "Scales the panel's corner radius."),
                    value: $settings.cornerRadiusScale,
                    range: 0.5...1.5,
                    defaultValue: 1.0
                )
                scaleRow(
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
        .frame(width: 400, height: 340)
    }

    /// One labeled slider row with a live value readout and a reset button
    /// that only appears once the value has actually drifted from
    /// `defaultValue` — keeps the common (untouched) case visually quiet.
    private func scaleRow(
        title: String,
        help: String,
        value: Binding<Double>,
        range: ClosedRange<Double>,
        defaultValue: Double,
        formatter: @escaping (Double) -> String = { String(format: "%.0f%%", $0 * 100) }
    ) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(title)
                Spacer()
                Text(formatter(value.wrappedValue))
                    .foregroundColor(.secondary)
                    .monospacedDigit()
                if abs(value.wrappedValue - defaultValue) > 0.001 {
                    Button(String(localized: "settings.reset", defaultValue: "Reset")) {
                        value.wrappedValue = defaultValue
                    }
                    .buttonStyle(.plain)
                    .foregroundColor(.accentColor)
                    .font(.caption)
                }
            }
            Slider(value: value, in: range)
        }
        .help(help)
        .padding(.vertical, 2)
    }

    /// Same `NSWorkspace.shared.open` pattern as `SystemCell.openSystemSettings`
    /// in `NotchView.swift` — duplicated locally rather than shared because
    /// that one is `private` to its own file.
    private func openSystemSettings(_ rawURL: String) {
        guard let url = URL(string: rawURL) else { return }
        NSWorkspace.shared.open(url)
    }
}
