import SwiftUI

// The press/hover feedback shared by every custom button in the notch.

// MARK: - Native interaction feedback

/// Internal rather than file-private: `OnboardingContent` lives in its own
/// file but is still notch chrome, and its button has to press like every
/// other button in the panel.
struct NotchPressStyle: ButtonStyle {
    var pressedScale: CGFloat = 0.97

    func makeBody(configuration: Configuration) -> some View {
        NotchPressedBody(configuration: configuration, pressedScale: pressedScale)
    }
}

struct NotchPressedBody: View {
    let configuration: ButtonStyle.Configuration
    let pressedScale: CGFloat
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        configuration.label
            .scaleEffect(configuration.isPressed && !reduceMotion ? pressedScale : 1)
            .opacity(isEnabled ? (configuration.isPressed ? 0.82 : 1) : 0.4)
            .animation(.easeOut(duration: reduceMotion ? 0.01 : 0.11), value: configuration.isPressed)
            .animation(.easeOut(duration: reduceMotion ? 0.01 : 0.11), value: isEnabled)
    }
}

struct HoverLiftModifier: ViewModifier {
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

extension View {
    /// Internal for the same reason as `NotchPressStyle`: `OnboardingContent`
    /// is in its own file but is still part of the notch's chrome.
    func hoverLift(cornerRadius: CGFloat = 8, strength: Double = 0.055) -> some View {
        modifier(HoverLiftModifier(cornerRadius: cornerRadius, strength: strength))
    }
}
