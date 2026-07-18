import SwiftUI

/// Design tokens mirrored from the design mock `Mac Dynamic Island.dc.html`.
/// Keep these in sync with the mock's `:root` CSS custom properties.
enum DesignTokens {
    // Accent colors
    static let green = Color(red: 0x69 / 255, green: 0xD5 / 255, blue: 0x8A / 255)
    static let orange = Color(red: 0xF0 / 255, green: 0xA4 / 255, blue: 0x51 / 255)
    static let red = Color(red: 0xED / 255, green: 0x77 / 255, blue: 0x71 / 255)
    static let cyan = Color(red: 0x68 / 255, green: 0xCC / 255, blue: 0xE3 / 255)

    // Neutral text/surface colors
    static let muted = Color.white.opacity(0.48)
    static let surface = Color.white.opacity(0.075)
    static let surface2 = Color.white.opacity(0.045)
    static let line = Color.white.opacity(0.085)

    /// "done" status dot color (`#AEB4BF` in the mock).
    static let doneGray = Color(red: 0xAE / 255, green: 0xB4 / 255, blue: 0xBF / 255)

    // Shell geometry
    static let closedRadius: CGFloat = 15
    static let openRadius: CGFloat = 24

    /// Hover-driven panels should settle without overshoot. A critically
    /// damped response also remains interruptible when the pointer reverses.
    static let spring = Animation.spring(response: 0.42, dampingFraction: 0.92)
    static let contentTransition = Animation.easeInOut(duration: 0.30)
}
