import Foundation
import SwiftUI

extension Notification.Name {
    /// Posted by Settings' "Show Welcome Screen…" button. `SettingsView`
    /// lives in its own scene with no reference to `NotchWindowController`,
    /// so the request travels as a notification the app delegate forwards.
    static let agentNotchReplayOnboarding = Notification.Name("agentnotch.replayOnboarding")
}

/// One gesture explained on the welcome screen.
struct OnboardingTip: Identifiable {
    let id = UUID()
    let icon: String
    let text: String
}

/// The gestures worth knowing before the notch is ever touched. Kept as a
/// standalone function so the list is testable without building the view.
func onboardingTips() -> [OnboardingTip] {
    [
        OnboardingTip(
            icon: "arrow.left.and.right",
            text: String(localized: "onboarding.swipeHorizontal", defaultValue: "Swipe sideways to change track")
        ),
        OnboardingTip(
            icon: "arrow.up.and.down",
            text: String(localized: "onboarding.swipeVertical", defaultValue: "Swipe up or down to open, close, or hide the notch")
        ),
        OnboardingTip(
            icon: "cursorarrow.click.2",
            text: String(localized: "onboarding.click", defaultValue: "Click to open the Nook, where your widgets live")
        ),
        OnboardingTip(
            icon: "tray.and.arrow.down.fill",
            text: String(localized: "onboarding.dragDrop", defaultValue: "Drag and drop files onto the notch to stash them in the Tray")
        ),
    ]
}

/// First-run welcome, shown *in the notch itself* rather than in a separate
/// window — the gestures it describes only exist here, so demonstrating
/// them anywhere else would be teaching them out of context.
struct OnboardingContent: View {
    let onDismiss: () -> Void

    private let tips = onboardingTips()

    var body: some View {
        VStack(spacing: 16) {
            HStack(alignment: .top, spacing: 10) {
                ForEach(tips) { tip in
                    VStack(spacing: 9) {
                        Image(systemName: tip.icon)
                            .font(.system(size: 24, weight: .light))
                            .frame(height: 28)
                            .foregroundColor(.white.opacity(0.92))
                        Text(tip.text)
                            .font(.system(size: 10))
                            .foregroundColor(.white.opacity(0.72))
                            .multilineTextAlignment(.center)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .frame(maxWidth: .infinity)
                    .accessibilityElement(children: .combine)
                }
            }
            Button {
                SoundPlayer.shared.play(.action)
                HapticPlayer.shared.perform(.confirm)
                onDismiss()
            } label: {
                Text(String(localized: "onboarding.getStarted", defaultValue: "Get Started"))
                    .font(.system(size: 11.5, weight: .semibold))
                    .foregroundColor(.white)
                    .frame(width: 200, height: 30)
                    .background(RoundedRectangle(cornerRadius: 9).fill(DesignTokens.cyan.opacity(0.28)))
                    .overlay(RoundedRectangle(cornerRadius: 9).stroke(DesignTokens.cyan.opacity(0.55), lineWidth: 0.75))
            }
            .buttonStyle(NotchPressStyle())
            .hoverLift(cornerRadius: 9)
            .accessibilityIdentifier("onboarding.dismiss")
        }
        .padding(.horizontal, 10)
        .padding(.top, 4)
    }
}
