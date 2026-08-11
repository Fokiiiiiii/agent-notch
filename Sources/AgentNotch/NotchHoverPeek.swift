import SwiftUI

// The `.hover` peek — the intermediate state between the closed pill and
// the open panel.

// MARK: - Hover peek (intermediate state)

/// Content for `IslandMode.hover`. Deliberately its own type rather than a
/// reuse of `compactAgentContent`/`compactMediaContent` (both stay
/// unchanged — Compact keeps its narrow left/right-of-notch role): Hover has
/// room to show media *and* session info together rather than choosing one.
struct HoverPeekView: View {
    let session: AgentSession?
    @ObservedObject var media: MediaController
    /// Extra space to leave empty above the rows on a real notched Mac —
    /// `0` on a non-notched screen, which keeps this exactly as it was
    /// before notch-awareness was added (see
    /// `NotchUIState.hoverTopClearance`'s doc comment for why this exists:
    /// the physical camera housing is opaque, not just a rendering
    /// boundary, so content placed under it is genuinely invisible).
    var topClearance: CGFloat = 0
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Group {
            if topClearance > 0 {
                notchAwareContent
            } else {
                legacyContent
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        // Non-notched (topClearance == 0): vertical-center, exactly as
        // before. Notched: top-anchor — `notchAwareContent` places its own
        // icon band flush with the top instead of relying on padding.
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: topClearance > 0 ? .topLeading : .leading)
    }

    private var legacyContent: some View {
        VStack(alignment: .leading, spacing: 7) {
            if media.isPlaying {
                mediaRow
            }
            if let session {
                sessionRow(session)
            } else if !media.isPlaying {
                emptyRow
            }
        }
    }

    // MARK: - Notch-aware content (real notch only)

    /// On a real (or simulated) notch, the physical camera housing sits at
    /// the top-center and is opaque — a small icon anchored to the pill's
    /// left/right edge clears it (the pill is always widened well past the
    /// notch's own width, see `computeHoverSize`), but full-width content
    /// does not. So: a thin icon band flush with the top (icon left, a
    /// small status accessory right, nothing in the center where the
    /// housing sits), then the info text below it — never media and
    /// session simultaneously, matching how little room a peek should take.
    private var notchAwareContent: some View {
        VStack(alignment: .leading, spacing: 6) {
            iconBand
            primaryInfo
        }
    }

    /// Media gets its own title (marquee-scrolled if it overflows, matching
    /// the previous design) + artist line, since both were legible before
    /// this redesign and truncating the artist away entirely lost real
    /// information. Session/idle stay a single line — there's no
    /// second-line equivalent to a session the way there is a track's artist.
    @ViewBuilder
    private var primaryInfo: some View {
        if media.isPlaying {
            VStack(alignment: .leading, spacing: 0) {
                MarqueeText(text: media.title, size: 12, weight: .semibold, speed: 18)
                    .frame(height: 15)
                Text(media.artist)
                    .font(.system(size: 9, weight: .medium))
                    .foregroundColor(DesignTokens.muted)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
        } else if let session {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(session.title)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(.white)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Spacer(minLength: 4)
                Text(elapsedString(session))
                    .font(.system(size: 9, design: .rounded))
                    .foregroundColor(DesignTokens.muted)
                    .lineLimit(1)
            }
        } else {
            Text(String(localized: "compact.idle", defaultValue: "No active session"))
                .font(.system(size: 12, weight: .semibold))
                .foregroundColor(.white)
                .lineLimit(1)
                .truncationMode(.tail)
        }
    }

    private var iconBand: some View {
        HStack(spacing: 0) {
            leadingGlyph
            Spacer(minLength: 0)
            trailingAccessory
        }
        .frame(height: max(topClearance, 24))
    }

    private var leadingGlyph: some View {
        Group {
            if media.isPlaying, let artwork = media.artwork {
                Image(nsImage: artwork)
                    .resizable()
                    .scaledToFill()
            } else if media.isPlaying {
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(Color.white.opacity(0.1))
                    .overlay(Image(systemName: "music.note").font(.system(size: 10, weight: .medium)))
            } else {
                GlyphBox(agent: session?.agent)
            }
        }
        // Matches `GlyphBox`'s own dimensions (22×22, cornerRadius 7)
        // exactly, instead of re-wrapping it in a differently-sized/rounded
        // frame — avoids a ~1pt double-clip mismatch on the idle path.
        .frame(width: 22, height: 22)
        .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
        .overlay(alignment: .bottomTrailing) {
            if let direction = media.activeSkipDirection {
                skipBadge(direction)
            }
        }
        .animation(.easeOut(duration: reduceMotion ? 0.12 : 0.2), value: media.activeSkipDirection)
    }

    /// A small dark circular badge flashed at the corner of the album art
    /// on a hardware media-key/remote skip press, matching macOS's own
    /// "Now Playing" HUD app-icon-badge convention — auto-clears itself via
    /// `MediaController.activeSkipDirection`, no local timer needed here.
    private func skipBadge(_ direction: SkipDirection) -> some View {
        Image(systemName: direction == .forward ? "forward.fill" : "backward.fill")
            .font(.system(size: 7, weight: .bold))
            .foregroundColor(.white)
            .frame(width: 14, height: 14)
            .background(Circle().fill(Color.black.opacity(0.55)))
            .overlay(Circle().stroke(Color.white.opacity(0.15), lineWidth: 0.5))
            .offset(x: 2, y: 2)
            .transition(.opacity.combined(with: .scale(scale: reduceMotion ? 1 : 0.6)))
    }

    @ViewBuilder
    private var trailingAccessory: some View {
        if media.isPlaying {
            CompactMediaWaveform(isPlaying: true, color: Color(nsColor: media.accentColor))
        } else if let session {
            Circle()
                .fill(statusColor(session.state))
                .frame(width: 6, height: 6)
        } else {
            // Fully idle (no media, no session): keep the icon band
            // left/right-balanced instead of leaving the right side empty.
            Circle()
                .fill(DesignTokens.muted)
                .frame(width: 6, height: 6)
        }
    }

    private var mediaRow: some View {
        HStack(spacing: 8) {
            Group {
                if let artwork = media.artwork {
                    Image(nsImage: artwork)
                        .resizable()
                        .scaledToFill()
                } else {
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(Color.white.opacity(0.1))
                        .overlay(Image(systemName: "music.note").font(.system(size: 10, weight: .medium)))
                }
            }
            .frame(width: 26, height: 26)
            .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
            .overlay(alignment: .bottomTrailing) {
                if let direction = media.activeSkipDirection {
                    skipBadge(direction)
                }
            }
            .animation(.easeOut(duration: reduceMotion ? 0.12 : 0.2), value: media.activeSkipDirection)
            VStack(alignment: .leading, spacing: 0) {
                MarqueeText(text: media.title, size: 10.5, weight: .semibold, speed: 18)
                    .frame(height: 13)
                Text(media.artist)
                    .font(.system(size: 8.5, weight: .medium))
                    .foregroundColor(DesignTokens.muted)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            Spacer(minLength: 4)
            CompactMediaWaveform(isPlaying: media.isPlaying, color: Color(nsColor: media.accentColor))
        }
    }

    private func sessionRow(_ session: AgentSession) -> some View {
        HStack(spacing: 8) {
            GlyphBox(agent: session.agent)
                .fixedSize()
            VStack(alignment: .leading, spacing: 1) {
                Text(cwdTail(session.cwd))
                    .font(.system(size: 8.5, weight: .medium))
                    .foregroundColor(DesignTokens.muted)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Text(session.title)
                    .font(.system(size: 10.5, weight: .semibold))
                    .foregroundColor(.white)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            Spacer(minLength: 4)
            VStack(alignment: .trailing, spacing: 1) {
                HStack(spacing: 5) {
                    Circle()
                        .fill(statusColor(session.state))
                        .frame(width: 6, height: 6)
                    Text(sessionStateLabel(session.state))
                        .font(.system(size: 8.5, weight: .medium))
                        .foregroundColor(DesignTokens.muted)
                        .lineLimit(1)
                }
                Text(elapsedString(session))
                    .font(.system(size: 8.5, design: .rounded))
                    .foregroundColor(DesignTokens.muted)
            }
        }
    }

    private var emptyRow: some View {
        HStack(spacing: 8) {
            GlyphBox(agent: nil)
            Text(String(localized: "compact.idle", defaultValue: "No active session"))
                .font(.system(size: 10.5, weight: .semibold))
                .foregroundColor(.white)
            Spacer(minLength: 0)
        }
    }
}

#Preview("Hover — notch-aware, session") {
    HoverPeekView(
        session: AgentSession(id: "preview", agent: .claude, title: "Fix auth middleware bug", cwd: "/Users/chaos/Documents/agent-notch", lastActivity: Date(), state: .running, lastMessage: "Reading AuthMiddleware.swift"),
        media: MediaController.shared,
        topClearance: 43
    )
    .frame(width: 320, height: 90)
    .background(Color.black)
}

#Preview("Hover — notch-aware, idle") {
    HoverPeekView(session: nil, media: MediaController.shared, topClearance: 43)
        .frame(width: 320, height: 90)
        .background(Color.black)
}

#Preview("Hover — legacy (non-notched)") {
    HoverPeekView(
        session: AgentSession(id: "preview", agent: .codex, title: "Add pagination to /users", cwd: "/Users/chaos/Documents/agent-notch", lastActivity: Date(), state: .waitingApproval, lastMessage: "Waiting for your approval"),
        media: MediaController.shared,
        topClearance: 0
    )
    .frame(width: 320, height: 90)
    .background(Color.black)
}
