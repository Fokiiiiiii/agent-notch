import SwiftUI

/// Design tokens mirrored from the design mock `Mac Dynamic Island.dc.html`.
/// Keep these in sync with the mock's `:root` CSS custom properties.
enum DesignTokens {
    // Accent colors
    static let green = Color(red: 0x69 / 255, green: 0xD5 / 255, blue: 0x8A / 255)
    static let orange = Color(red: 0xF0 / 255, green: 0xA4 / 255, blue: 0x51 / 255)
    static let red = Color(red: 0xED / 255, green: 0x77 / 255, blue: 0x71 / 255)
    static let cyan = Color(red: 0x68 / 255, green: 0xCC / 255, blue: 0xE3 / 255)
    /// Same pastel family/saturation as the other four accents. Gives a plan
    /// review its own identity in `attentionColor(for:)` instead of a flat
    /// near-white, without colliding with green (approve/done), red (deny),
    /// orange (permission), or cyan (question).
    static let purple = Color(red: 0xB1 / 255, green: 0x8A / 255, blue: 0xF0 / 255)

    // Neutral text/surface colors
    static let muted = Color.white.opacity(0.48)
    static let line = Color.white.opacity(0.085)

    /// "done" status dot color (`#AEB4BF` in the mock).
    static let doneGray = Color(red: 0xAE / 255, green: 0xB4 / 255, blue: 0xBF / 255)

    // Shell geometry
    static let closedRadius: CGFloat = 15
    static let openRadius: CGFloat = 24

    /// Safe margin added to the physically-measured notch width when deriving
    /// the visible `.closed`-mode shape. Wider than the old fixed `+20pt` to
    /// leave more headroom for content around the physical notch cutout.
    static let notchSafeMargin: CGFloat = 32

    /// Tighter margin used only when a real physical notch is present
    /// (`hasNotch == true` in `NotchWindowController.computeClosedSize`), so
    /// the `.closed` pill hugs the camera-housing cutout instead of reusing
    /// the generic virtual-notch margin. Approximate — tune after visual QA
    /// via `AGENT_NOTCH_SIMULATE_NOTCH` (no physical-notch dev machine to
    /// measure against directly).
    static let notchHuggingMargin: CGFloat = 16

    /// Bottom-corner radius used for `.closed`/`.hover`/`.notice` only when a
    /// real notch is present, approximating the physical camera housing's own
    /// corner curvature so the virtual shell's edge continues it rather than
    /// visibly diverging from it. Approximate — tune after visual QA.
    static let notchHuggingRadius: CGFloat = 10

    /// Minimum width `compactAgentContent` (see `NotchView.swift`) needs to
    /// avoid clipping: 22pt icon + spacing + status text + horizontal padding
    /// (12pt each side), estimated conservatively.
    static let compactMinContentWidth: CGFloat = 160

    /// Hover-driven panels should settle without overshoot. A critically
    /// damped response also remains interruptible when the pointer reverses.
    static let spring = Animation.spring(response: 0.42, dampingFraction: 0.92)
    static let contentTransition = Animation.easeInOut(duration: 0.30)

    /// Corner radius shared by `CellSurface` and `AgentsCell.cellShape` — was
    /// the literal `14` duplicated in both places (and not routed through
    /// `AppSettings.cornerRadiusScale` the way `closedRadius`/`openRadius`
    /// are). Kept as a plain (unscaled) constant for now, matching those two
    /// call sites' prior behavior exactly.
    static let cellRadius: CGFloat = 14

    // MARK: - Shadow (currently: `.hover`'s shell only, see `NotchView.shapeBackground`)
    static let cardShadowOpacity: Double = 0.35
    static let cardShadowRadius: CGFloat = 12
    static let cardShadowY: CGFloat = 6

    // MARK: - Hover dwell timing
    //
    // Read by `NotchWindowController`'s `hoverExpandTask`/`hoverTask` —
    // values are the same hand-tuned 220ms/140ms this session settled on
    // before these were pulled out into named constants (see those two
    // call sites for the dwell-guard logic these delays gate).
    static let hoverExpandDelay: TimeInterval = 0.22
    static let hoverCollapseDelay: TimeInterval = 0.14

    /// Double-tap/double-Enter dwell guard: an interactive control disarms
    /// itself for this long right after appearing (or after a step
    /// transition), so a fast repeat click/keypress can't fire the same
    /// action twice before SwiftUI has re-rendered the disabled state.
    /// Shared by `AgentQuestionView`, `ApprovalOverlayView`, and
    /// `PlanApprovalOverlayView` via `NotchView.armDwellGuard(_:)`.
    static let dwellGuardDelay: TimeInterval = 0.15
}

extension DesignTokens {
    // Every function below takes `settings: AppSettings? = nil` rather than
    // `= .shared` directly: a default-argument expression referencing
    // `AppSettings.shared` (a @MainActor-isolated static property) from a
    // parameter default is evaluated in a context Swift's default-argument
    // synthesis doesn't treat as @MainActor-isolated, which is a warning
    // today and a hard error under the Swift 6 language mode. `nil` is a
    // plain, isolation-free literal; `.shared` is only touched inside the
    // (already @MainActor) function body via `settings ?? .shared`. Every
    // call site stays the same zero-argument syntax (`scaledClosedRadius()`
    // etc.) — passing `nil` explicitly is equivalent to omitting it.

    /// `closedRadius` scaled by `AppSettings.cornerRadiusScale`. Used by
    /// `NotchView.shellShape` for `.closed`/`.hover`/`.notice`'s corner
    /// radius (`.open` uses `scaledOpenRadius` instead).
    @MainActor
    static func scaledClosedRadius(_ settings: AppSettings? = nil) -> CGFloat {
        closedRadius * (settings ?? .shared).cornerRadiusScale
    }

    /// `openRadius` scaled by `AppSettings.cornerRadiusScale`. Used by
    /// `NotchView.shellShape` for `.open`'s corner radius.
    @MainActor
    static func scaledOpenRadius(_ settings: AppSettings? = nil) -> CGFloat {
        openRadius * (settings ?? .shared).cornerRadiusScale
    }

    /// `notchHuggingRadius` scaled by `AppSettings.cornerRadiusScale`.
    @MainActor
    static func scaledNotchHuggingRadius(_ settings: AppSettings? = nil) -> CGFloat {
        notchHuggingRadius * (settings ?? .shared).cornerRadiusScale
    }

    /// `spring` scaled by `AppSettings.animationSpeedScale`. A larger scale
    /// lengthens `response` (slower settle); a smaller scale shortens it.
    /// `dampingFraction` is left untouched since it's a ratio, not a duration.
    @MainActor
    static func scaledSpring(_ settings: AppSettings? = nil) -> Animation {
        .spring(response: 0.42 * (settings ?? .shared).animationSpeedScale, dampingFraction: 0.92)
    }

    /// `contentTransition` scaled by `AppSettings.animationSpeedScale`.
    @MainActor
    static func scaledContentTransition(_ settings: AppSettings? = nil) -> Animation {
        .easeInOut(duration: 0.30 * (settings ?? .shared).animationSpeedScale)
    }
}
