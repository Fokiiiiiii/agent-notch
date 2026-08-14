import SwiftUI
import AppKit

// The Dashboard page and its widgets (media, calendar, mirror), plus the
// shared cell surface and the indicators that sit in the nook bar.

// MARK: - Nook pages

/// Sizing/padding container for a Nook page. It used to also draw a
/// translucent grey plate (`.ultraThinMaterial` + a black wash + a hairline
/// border); that plate read as a second background floating inside the notch
/// panel, which the Dashboard page had already dropped. The rectangle stays
/// because it's what claims the available space — only the fill and stroke
/// are gone, so every page now sits directly on the panel.
struct CellSurface<Content: View>: View {
    let content: Content

    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    var body: some View {
        RoundedRectangle(cornerRadius: DesignTokens.cellRadius)
            .fill(Color.clear)
            // 10 rather than 7: every card in the app is drawn through this,
            // and at 7 the contents sat visibly tight against the rounded
            // border on all of them.
            .overlay(content.padding(10))
    }
}

/// The merged Media/Today/System page — a single flat panel with the three
/// sections arranged side-by-side, separated by thin dividers, and each
/// trimmed to its most glanceable content. Replaces a first pass that
/// stacked three full-size, individually-`CellSurface`d cards vertically
/// (macOS Control Center's "grid of cards" pattern) — user feedback called
/// that "just three things thrown together" and pointed at NotchNook's own
/// reference screenshot instead, which lays Media/Calendar out in one row
/// inside a single panel. System is deliberately reduced to one glanceable
/// metric (battery) per explicit follow-up feedback that the original
/// 3-card/background-activity System section was "about half unnecessary
/// information" — the dropped detail (memory, storage, uptime, background
/// activity) remains reachable through this tab's `expandedDetail` panel.
struct DashboardCell: View {
    @ObservedObject var media: MediaController
    @ObservedObject var today: TodayModel
    @ObservedObject var uiState: NotchUIState
    @ObservedObject var settings: AppSettings

    /// No `CellSurface` here: NotchNook's widgets sit directly on the panel's
    /// own dark background and are separated by hairline vertical rules, not
    /// by their own tinted cards. Wrapping these in `CellSurface` produced
    /// the washed-out grey slab the design was explicitly asked not to have.
    ///
    /// The row is built from `settings.tabLayouts`, so which widgets appear
    /// and in what order comes from the Nook settings tab rather than being
    /// hardcoded here.
    private var widgets: [DashboardWidget] {
        DashboardWidget.resolved(from: settings.tabLayouts[DashboardWidget.layoutKey])
    }

    var body: some View {
        HStack(alignment: .center, spacing: 0) {
            if widgets.isEmpty {
                emptyState
            } else {
                ForEach(Array(widgets.enumerated()), id: \.element.id) { index, widget in
                    if index > 0 { widgetDivider }
                    widgetView(for: widget)
                }
            }
        }
        .padding(.horizontal, 4)
        .padding(.vertical, 6)
        .onAppear {
            today.refresh()
            // Always open on today; a strip left scrolled to some other week
            // from a previous visit is disorienting.
            uiState.weekStripDayOffset = 0
        }
    }

    /// Each widget carries its own width rule (`preferredWidth`), so adding
    /// one doesn't mean editing the row's layout as well.
    @ViewBuilder
    private func widgetView(for widget: DashboardWidget) -> some View {
        let content = Group {
            switch widget {
            case .media:
                DashboardMediaSection(media: media)
            case .today:
                DashboardTodaySection(model: today, uiState: uiState)
            case .camera:
                DashboardCameraSection()
            }
        }
        if let width = widget.preferredWidth {
            content.frame(width: width, alignment: .leading)
        } else {
            content.frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    /// Reachable by turning every widget off in Settings. Says so plainly
    /// rather than leaving a blank panel that reads as a rendering bug.
    private var emptyState: some View {
        Text(String(localized: "dashboard.noWidgets", defaultValue: "No widgets enabled — turn some on in Settings ▸ Nook"))
            .font(.system(size: 11))
            .foregroundColor(DesignTokens.muted)
            .frame(maxWidth: .infinity, alignment: .center)
    }

    /// Hairline rule between widgets — the only separator NotchNook uses.
    /// Runs nearly the full height of the row, as it does in the reference
    /// screenshots, rather than floating as a short stub in the middle.
    private var widgetDivider: some View {
        Divider()
            .overlay(DesignTokens.line)
            .padding(.vertical, 2)
            .padding(.horizontal, 14)
    }
}

/// Live webcam mirror. Off by default (see `isEnabledByDefault`) and
/// capturing only while this view is on screen — `addViewer`/`removeViewer`
/// tie the camera's indicator light to something the user can actually see.
struct DashboardCameraSection: View {
    @ObservedObject private var controller = CameraPreviewController.shared

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 10)
                .fill(Color.white.opacity(0.05))
            if controller.isRunning {
                CameraPreviewView(session: controller.session)
                    .clipShape(RoundedRectangle(cornerRadius: 10))
            } else {
                placeholder
            }
        }
        .frame(maxHeight: .infinity)
        .padding(.vertical, 2)
        .onAppear { controller.addViewer() }
        .onDisappear { controller.removeViewer() }
        .accessibilityLabel(String(localized: "widget.camera", defaultValue: "Mirror"))
    }

    /// Covers three states with one shape so the widget's size never shifts:
    /// starting up, no camera/denied, and access not yet requested.
    private var placeholder: some View {
        VStack(spacing: 5) {
            Image(systemName: controller.errorMessage == nil ? "web.camera" : "exclamationmark.triangle")
                .font(.system(size: 15))
                .foregroundColor(DesignTokens.muted)
            if let message = controller.errorMessage {
                Text(message)
                    .font(.system(size: 9))
                    .foregroundColor(DesignTokens.muted)
                    .multilineTextAlignment(.center)
                    .lineLimit(2)
            }
        }
        .padding(.horizontal, 6)
    }
}

/// Artwork-forward layout modeled on NotchNook's own reference screenshot
/// (large square artwork, bold title allowed to wrap to two lines, controls
/// beneath) rather than the single-line-marquee/small-icon treatment this
/// file's other Media surfaces (`compactMediaContent`, `HoverPeekView`) use
/// — those stay on `MarqueeText` since they're width-constrained in ways
/// this wider Dashboard section isn't.
struct DashboardMediaSection: View {
    @ObservedObject var media: MediaController

    var body: some View {
        HStack(spacing: 14) {
            ZStack {
                RoundedRectangle(cornerRadius: 11)
                    .fill(LinearGradient(colors: [.purple.opacity(0.75), .blue.opacity(0.55), .black], startPoint: .topLeading, endPoint: .bottomTrailing))
                if let artwork = media.artwork {
                    Image(nsImage: artwork)
                        .resizable()
                        .scaledToFill()
                } else {
                    Image(systemName: media.hasMedia ? "waveform" : "music.note")
                        .font(.system(size: 24, weight: .light))
                        .foregroundColor(.white.opacity(0.82))
                }
            }
            .frame(width: 68, height: 68)
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).stroke(Color.white.opacity(0.08), lineWidth: 0.5))
            VStack(alignment: .leading, spacing: 4) {
                // Marquee-scrolled (rather than truncated) so a long title
                // stays fully readable, matching the compact/hover media
                // rows elsewhere in the app — see `MarqueeText`. The leading
                // glyph says at a glance what kind of thing is playing
                // (podcast/video/song) without spending a text line on it.
                HStack(spacing: 5) {
                    if media.hasMedia {
                        Image(systemName: mediaSourceIcon(forBundleIdentifier: media.sourceBundleIdentifier))
                            .font(.system(size: 10))
                            .foregroundColor(DesignTokens.muted)
                            .accessibilityHidden(true)
                    }
                    MarqueeText(text: media.hasMedia ? media.title : String(localized: "media.noMediaPlaying", defaultValue: "No media playing"), size: 13, weight: .bold, speed: 18)
                }
                .frame(height: 16)
                Text(media.hasMedia ? media.artist : (media.isConnected ? media.source : String(localized: "media.unavailable", defaultValue: "Unavailable")))
                    .font(.system(size: 10.5))
                    .foregroundColor(DesignTokens.muted)
                    .lineLimit(1)
                    .help(media.artist)
                if media.hasMedia, !media.album.isEmpty {
                    Text(media.album)
                        .font(.system(size: 9.5))
                        .foregroundColor(DesignTokens.mutedFaint)
                        .lineLimit(1)
                        .help(media.album)
                }
                Spacer(minLength: 0)
                if media.hasMedia {
                    HStack(spacing: 6) {
                        MediaControlButton(icon: "backward.fill", help: String(localized: "media.previous", defaultValue: "Previous"), action: media.previous)
                        MediaControlButton(icon: media.isPlaying ? "pause.fill" : "play.fill", help: media.isPlaying ? String(localized: "media.pause", defaultValue: "Pause") : String(localized: "media.play", defaultValue: "Play"), prominent: true, action: media.togglePlayback)
                        MediaControlButton(icon: "forward.fill", help: String(localized: "media.next", defaultValue: "Next"), action: media.next)
                    }
                } else {
                    Button {
                        SoundPlayer.shared.play(.action)
                        media.refresh()
                    } label: {
                        Label(String(localized: "media.checkNowPlaying", defaultValue: "Check Now Playing"), systemImage: "arrow.clockwise")
                            .font(.system(size: 9, weight: .medium))
                            .padding(.horizontal, 9)
                            .frame(height: 22)
                            .background(RoundedRectangle(cornerRadius: 7).fill(Color.white.opacity(0.09)))
                    }
                    .buttonStyle(NotchPressStyle())
                    .hoverLift(cornerRadius: 7)
                    .help(String(localized: "media.checkNowPlayingHelp", defaultValue: "Check the current macOS media session"))
                }
            }
            .frame(height: 68, alignment: .top)
        }
        .foregroundColor(.white)
    }
}

struct CompactMediaWaveform: View {
    let isPlaying: Bool
    let color: Color
    @ObservedObject private var visualizer = AudioVisualizer.shared
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        TimelineView(.animation(minimumInterval: 0.16, paused: reduceMotion || !isPlaying)) { context in
            let phase = context.date.timeIntervalSinceReferenceDate * 5.5
            let live = visualizer.amplitude
            HStack(alignment: .center, spacing: 2) {
                ForEach(0..<4, id: \.self) { index in
                    Capsule()
                        .fill(color.opacity(index == 2 ? 1 : 0.72))
                        .frame(width: 2, height: 4 + 9 * barLevel(index: index, phase: phase, live: live))
                }
            }
            .frame(width: 16, height: 16)
            .shadow(color: color.opacity(0.3), radius: 3)
        }
        .accessibilityHidden(true)
    }

    /// Falls back to the synthetic `sin()` animation whenever there's no
    /// live signal (`idleAmplitude`) — the visualizer is off by default, so
    /// this is the ordinary path, not an error path.
    private func barLevel(index: Int, phase: Double, live: Double) -> Double {
        if reduceMotion { return 0.45 }
        guard live >= 0 else {
            return 0.35 + abs(sin(phase + Double(index) * 1.35)) * 0.65
        }
        // Bars still differ from each other while driven by one number:
        // the outer pair reacts a little less than the middle, which reads
        // as a level meter rather than four identical bars.
        let weight = index == 2 ? 1.0 : (index == 1 ? 0.85 : 0.68)
        return 0.12 + live * weight * 0.88
    }
}

struct MarqueeText: View {
    let text: String
    let size: CGFloat
    let weight: Font.Weight
    let speed: CGFloat
    @EnvironmentObject private var uiState: NotchUIState
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private let leadingPause: TimeInterval = 1.1
    @State private var startDate = Date()

    var body: some View {
        GeometryReader { proxy in
            let textWidth = measuredWidth
            let overflow = max(textWidth - proxy.size.width, 0)
            let overflows = overflow > 1
            // Paused while the notch is hidden — see `CompactMediaWaveform`.
            // At 30 re-evaluations a second this is the more expensive of
            // the two timelines.
            TimelineView(.animation(minimumInterval: 1 / 30, paused: reduceMotion || !overflows || !uiState.isVisible)) { context in
                let offset = marqueeOffset(at: context.date, overflow: overflow)

                label
                    .offset(x: overflows && !reduceMotion ? -offset : 0)
                    .frame(maxHeight: .infinity, alignment: .center)
            }
        }
        .clipped()
        .onChange(of: text) { _, _ in startDate = Date() }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(text)
    }

    private var label: some View {
        Text(text)
            .font(.system(size: size, weight: weight))
            .foregroundColor(.white)
            .lineLimit(1)
            .fixedSize(horizontal: true, vertical: false)
    }

    private func marqueeOffset(at date: Date, overflow: CGFloat) -> CGFloat {
        let movingDuration = TimeInterval(overflow / speed)
        let endPause: TimeInterval = 0.8
        let cycle = max(leadingPause + movingDuration + endPause + movingDuration, 0.1)
        let elapsed = date.timeIntervalSince(startDate).truncatingRemainder(dividingBy: cycle)
        if elapsed <= leadingPause { return 0 }
        if elapsed <= leadingPause + movingDuration {
            return CGFloat(elapsed - leadingPause) * speed
        }
        if elapsed <= leadingPause + movingDuration + endPause { return overflow }
        let returnElapsed = elapsed - leadingPause - movingDuration - endPause
        return max(overflow - CGFloat(returnElapsed) * speed, 0)
    }

    private var measuredWidth: CGFloat {
        let appKitWeight: NSFont.Weight
        switch weight {
        case .bold: appKitWeight = .bold
        case .semibold: appKitWeight = .semibold
        case .medium: appKitWeight = .medium
        default: appKitWeight = .regular
        }
        return (text as NSString).size(withAttributes: [.font: NSFont.systemFont(ofSize: size, weight: appKitWeight)]).width
    }
}

struct MediaControlButton: View {
    let icon: String
    let help: String
    var prominent = false
    let action: () -> Void

    var body: some View {
        Button {
            SoundPlayer.shared.play(.action)
            action()
        } label: {
            Image(systemName: icon)
                .font(.system(size: 14))
                .frame(width: prominent ? 30 : 24, height: 24)
                .background(Circle().fill(Color.white.opacity(prominent ? 0.11 : 0)))
        }
        .buttonStyle(NotchPressStyle())
        .hoverLift(cornerRadius: 12, strength: 0.08)
        .help(help)
        .accessibilityLabel(help)
    }
}

/// A month label + five-day strip + centered agenda line, matching the
/// calendar widget in NotchNook's reference screenshots. Five columns (not
/// seven): the reference shows five, and seven left each column too narrow
/// for today's enlarged number.
///
/// Deliberately holds nothing but calendar information — the focus timer and
/// the "grant calendar access" button that used to sit here are AgentNotch
/// additions with no counterpart in the reference, and crowding them into
/// this widget is what made it read as cluttered. The focus timer now lives
/// in `NotchView.expandedDetail`; requesting access is folded into the
/// agenda line itself.
struct DashboardTodaySection: View {
    @ObservedObject var model: TodayModel
    @ObservedObject var uiState: NotchUIState

    /// The day the strip is centered on — today, shifted by however far the
    /// user has scrolled the strip (`NotchWindowController.stepWeekStrip`).
    private var selectedDate: Date {
        Calendar.current.date(byAdding: .day, value: uiState.weekStripDayOffset, to: Date()) ?? Date()
    }

    private var weekStripDays: [WeekStripDay] {
        centeredWeekStrip(around: selectedDate, count: 5)
    }

    private var selectedDayEvents: [TodayEvent] {
        TodayModel.events(on: selectedDate, in: model.nearbyEvents)
    }

    var body: some View {
        VStack(spacing: 8) {
            HStack(spacing: 10) {
                monthBlock
                weekStrip
            }
            agendaLine
        }
        .foregroundColor(.white)
        // Scrolling sideways anywhere over this widget steps the strip a day
        // at a time; elsewhere in the panel the same gesture switches pages.
        // `NotchWindowController.handleHorizontalScroll` reads this flag to
        // tell the two apart.
        .onHover { uiState.isHoveringWeekStrip = $0 }
        .onDisappear { uiState.isHoveringWeekStrip = false }
    }

    /// Month label mirroring NotchNook's reference screenshot ("Sep" next to
    /// the week strip). Follows the strip as it's scrolled, so the month
    /// always names the days actually on screen. `Date.formatted` follows
    /// the system locale, so no new localization key is needed (same
    /// precedent as `weekday(.narrow)` below).
    private var monthBlock: some View {
        Text(selectedDate.formatted(.dateTime.month(.abbreviated)))
            .font(.system(size: 18, weight: .bold, design: .rounded))
            .foregroundColor(.white.opacity(0.9))
    }

    /// Week-of-dates strip. Pure `Calendar` date arithmetic — independent of
    /// EventKit authorization, so it renders identically whether or not
    /// calendar access has been granted.
    private var weekStrip: some View {
        HStack(spacing: 4) {
            ForEach(weekStripDays, id: \.date) { day in
                WeekDayColumn(date: day.date, hasEvent: hasEvent(on: day.date))
                    .frame(maxWidth: .infinity)
            }
        }
    }

    /// Whether any day in the fetched window has something scheduled — this
    /// is what puts the small dot under a date. Reads `nearbyEvents` (a wide
    /// window around today) rather than `events` (today only), so days other
    /// than today can be marked too.
    private func hasEvent(on date: Date) -> Bool {
        model.nearbyEvents.contains { Calendar.current.isDate($0.startDate, inSameDayAs: date) }
    }

    /// Small icon above a single line of text, centered under the strip —
    /// the reference screenshot's "Nothing for today" treatment. All three
    /// states (an event, no events, no access yet) use this one shape so the
    /// widget's height never shifts between them.
    @ViewBuilder
    private var agendaLine: some View {
        if !model.canReadCalendar {
            Button {
                SoundPlayer.shared.play(.action)
                model.requestAccess()
            } label: {
                agendaBody(
                    icon: "calendar.badge.plus",
                    text: String(localized: "today.showCalendarEvents", defaultValue: "Show today's Calendar events"),
                    color: .white.opacity(0.8)
                )
            }
            .buttonStyle(NotchPressStyle())
            .accessibilityIdentifier("today.enable-calendar")
            .help(model.errorMessage ?? String(localized: "today.allowAccessHelp", defaultValue: "Allow access to today's events"))
        } else if let reminder = nextReminder, isReminderSoonerThanFirstEvent(reminder) {
            // An overdue or imminent reminder outranks a later event: it's
            // the thing actually needing attention now.
            agendaBody(
                icon: reminder.isOverdue ? "exclamationmark.circle" : "checklist",
                text: "\(reminder.title)  \(reminder.dueDate.formatted(.dateTime.hour().minute()))",
                color: reminder.isOverdue ? DesignTokens.orange : .white.opacity(0.85)
            )
            .help(reminder.title)
        } else if let event = selectedDayEvents.first {
            agendaBody(
                icon: "calendar",
                text: "\(event.title)  \(eventTimeRange(event))",
                color: .white.opacity(0.85)
            )
            .help(event.title)
        } else if Calendar.current.isDateInToday(selectedDate) {
            agendaBody(
                icon: "calendar.badge.checkmark",
                text: String(localized: "today.nothingForToday", defaultValue: "Nothing for today"),
                color: DesignTokens.muted
            )
        } else {
            // Scrolled off today: name the day, since "Nothing for today"
            // would be describing a different date than the one on screen.
            agendaBody(
                icon: "calendar.badge.checkmark",
                text: String(localized: "today.nothingScheduledOn", defaultValue: "Nothing on \(selectedDate.formatted(.dateTime.month().day()))"),
                color: DesignTokens.muted
            )
        }
    }

    /// Reminders are only fetched for today, so they're only offered while
    /// the strip is actually showing today — on a scrolled-to date they'd be
    /// describing a different day than the one on screen.
    private var nextReminder: TodayReminder? {
        guard Calendar.current.isDateInToday(selectedDate) else { return nil }
        return model.reminders.first
    }

    /// Which of the two competing lines gets the single agenda slot. Overdue
    /// reminders always win; otherwise whichever comes first by time.
    private func isReminderSoonerThanFirstEvent(_ reminder: TodayReminder) -> Bool {
        if reminder.isOverdue { return true }
        guard let event = selectedDayEvents.first else { return true }
        return reminder.dueDate < event.startDate
    }

    private func agendaBody(icon: String, text: String, color: Color) -> some View {
        VStack(spacing: 3) {
            Image(systemName: icon)
                .font(.system(size: 10))
                .foregroundColor(DesignTokens.muted)
            Text(text)
                .font(.system(size: 10, weight: .medium))
                .foregroundColor(color)
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity)
    }

    /// "16:00–17:00"-style range mirroring NotchNook's reference screenshot,
    /// which shows an event's start/end time alongside its title.
    private func eventTimeRange(_ event: TodayEvent) -> String {
        let start = event.startDate.formatted(.dateTime.hour().minute())
        let end = event.endDate.formatted(.dateTime.hour().minute())
        return "\(start)–\(end)"
    }
}

/// One column of `DashboardTodaySection`'s week strip: a narrow weekday
/// letter above the day-of-month number, today's rendered larger and in the
/// accent color — mirrors NotchNook's reference screenshot's calendar.
struct WeekDayColumn: View {
    let date: Date
    let hasEvent: Bool

    private var isToday: Bool { Calendar.current.isDateInToday(date) }
    private var isWeekend: Bool { Calendar.current.isDateInWeekend(date) }

    /// The bare day number, never a locale-formatted date. `.dateTime.day()`
    /// renders as "8日" under a Japanese locale, which overflowed the column
    /// and truncated today's own number to "•••" — the bug that made the
    /// current day invisible on screen.
    private var dayNumber: String {
        String(Calendar.current.component(.day, from: date))
    }

    var body: some View {
        VStack(spacing: 2) {
            Text(date.formatted(.dateTime.weekday(.narrow)))
                .font(.system(size: 7.5, weight: .medium))
                .foregroundColor(isToday ? .white.opacity(0.9) : DesignTokens.muted)
            Text(dayNumber)
                .font(.system(size: isToday ? 16 : 10.5, weight: isToday ? .bold : .regular, design: .rounded))
                .foregroundColor(numberColor)
                .frame(height: 19, alignment: .center)
            Circle()
                .fill(DesignTokens.cyan)
                .frame(width: 3.5, height: 3.5)
                .opacity(hasEvent ? 1 : 0)
        }
        .frame(height: 37)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityLabel)
        .accessibilityAddTraits(isToday ? [.isSelected] : [])
    }

    /// Three tiers only — today, weekend, weekday. An earlier revision also
    /// faded each column by its distance from today; stacking that on top of
    /// the color tiers is what read as "weird colors", and the reference
    /// screenshots have no such fade.
    private var numberColor: Color {
        if isToday { return DesignTokens.cyan }
        if isWeekend { return DesignTokens.orange.opacity(0.75) }
        return .white.opacity(0.5)
    }

    private var accessibilityLabel: String {
        let base = date.formatted(.dateTime.weekday(.wide).day())
        guard hasEvent else { return base }
        return String(localized: "today.weekDayHasEvent", defaultValue: "\(base), has an event")
    }
}

/// One day in `DashboardTodaySection`'s week strip: the date itself, plus
/// its signed offset from today (0 = today, negative = past, positive =
/// future). The offset is what makes "the strip is centered on today"
/// checkable in `centeredWeekStrip`'s tests.
struct WeekStripDay: Equatable {
    let date: Date
    let offset: Int
}

/// The notch panel's outline: square-cornered at the top where it meets the
/// menu bar, rounded at the bottom, and — when `topFlareRadius > 0` —
/// joined to the bar by a *concave* curve on each top corner.
///
/// That flare is the piece `UnevenRoundedRectangle` can't express. An
/// ordinary corner radius bends toward the panel's interior, which reads as
/// the panel being a separate slab tucked under the bar. Curving the other
/// way makes the top edge the widest point, with the body tucking in
/// beneath it, so the panel looks like it grows out of the bar.
///
/// `InsettableShape` because `shapeBackground` strokes it with
/// `strokeBorder`, which insets by half the line width to keep the stroke
/// inside the fill.
struct NotchShellShape: Shape, InsettableShape {
    var bottomRadius: CGFloat
    /// `0` draws plain square top corners (every mode except `.open`).
    var topFlareRadius: CGFloat
    var insetAmount: CGFloat = 0

    func path(in rect: CGRect) -> Path {
        let r = rect.insetBy(dx: insetAmount, dy: insetAmount)
        // Never let the curves overlap on a panel too small to hold them.
        let bottom = min(bottomRadius, r.width / 2, r.height / 2)
        let flare = min(topFlareRadius, r.width / 2, r.height / 2)

        var path = Path()
        // Top-left, at the panel's widest point.
        path.move(to: CGPoint(x: r.minX, y: r.minY))
        if flare > 0 {
            // Curve away from the interior: down and inward, leaving the
            // corner scooped out rather than filled in.
            path.addQuadCurve(
                to: CGPoint(x: r.minX + flare, y: r.minY + flare),
                control: CGPoint(x: r.minX + flare, y: r.minY)
            )
            path.addLine(to: CGPoint(x: r.minX + flare, y: r.maxY - bottom))
            path.addQuadCurve(
                to: CGPoint(x: r.minX + flare + bottom, y: r.maxY),
                control: CGPoint(x: r.minX + flare, y: r.maxY)
            )
            path.addLine(to: CGPoint(x: r.maxX - flare - bottom, y: r.maxY))
            path.addQuadCurve(
                to: CGPoint(x: r.maxX - flare, y: r.maxY - bottom),
                control: CGPoint(x: r.maxX - flare, y: r.maxY)
            )
            path.addLine(to: CGPoint(x: r.maxX - flare, y: r.minY + flare))
            path.addQuadCurve(
                to: CGPoint(x: r.maxX, y: r.minY),
                control: CGPoint(x: r.maxX - flare, y: r.minY)
            )
        } else {
            path.addLine(to: CGPoint(x: r.minX, y: r.maxY - bottom))
            path.addQuadCurve(
                to: CGPoint(x: r.minX + bottom, y: r.maxY),
                control: CGPoint(x: r.minX, y: r.maxY)
            )
            path.addLine(to: CGPoint(x: r.maxX - bottom, y: r.maxY))
            path.addQuadCurve(
                to: CGPoint(x: r.maxX, y: r.maxY - bottom),
                control: CGPoint(x: r.maxX, y: r.maxY)
            )
            path.addLine(to: CGPoint(x: r.maxX, y: r.minY))
        }
        path.closeSubpath()
        return path
    }

    func inset(by amount: CGFloat) -> NotchShellShape {
        var copy = self
        copy.insetAmount += amount
        return copy
    }
}

/// An SF Symbol describing what kind of thing is playing, chosen from the
/// now-playing source's bundle identifier: a mic for spoken audio, a screen
/// for video, a note for everything else. Matching is on substrings rather
/// than an exhaustive bundle-id list so unlisted apps from the same family
/// (regional Podcasts builds, Spotify betas, Chromium forks) still land on
/// the right glyph.
func mediaSourceIcon(forBundleIdentifier identifier: String?) -> String {
    guard let identifier, !identifier.isEmpty else { return "music.note" }
    let id = identifier.lowercased()
    if id.contains("podcast") || id.contains("overcast") || id.contains("pocketcast") || id.contains("audible") {
        return "mic.fill"
    }
    if id.contains("safari") || id.contains("chrome") || id.contains("chromium") || id.contains("brave")
        || id.contains("firefox") || id.contains("arc") || id.contains("vlc") || id.contains("iina")
        || id.contains("quicktime") || id.contains("appletv") || id.contains(".tv") {
        return "play.rectangle.fill"
    }
    return "music.note"
}

/// Returns `count` consecutive days centered on `referenceDate` — `(count-1)/2`
/// days before it, `referenceDate` itself, and the rest after. Pure/`Calendar`-
/// parameterized so it's directly testable, same pattern as
/// `NotchWindowController.computeClosedSize`.
func centeredWeekStrip(around referenceDate: Date, count: Int, calendar: Calendar = .current) -> [WeekStripDay] {
    guard count > 0 else { return [] }
    let before = (count - 1) / 2
    return (0..<count).compactMap { index -> WeekStripDay? in
        let offset = index - before
        guard let date = calendar.date(byAdding: .day, value: offset, to: referenceDate) else { return nil }
        return WeekStripDay(date: date, offset: offset)
    }
}

/// Connected AirPods' battery, next to the Mac's own. Renders nothing at
/// all when the feature is off or nothing is connected — an empty slot
/// beside the battery would be worse than no slot, and this way the bar's
/// layout is unchanged for anyone not using it.
struct AirPodsBatteryIndicator: View {
    @ObservedObject private var monitor = AirPodsBatteryMonitor.shared
    @ObservedObject private var settings = AppSettings.shared

    var body: some View {
        if settings.airPodsStatusEnabled,
           let battery = monitor.battery,
           let label = AirPodsBatteryMonitor.summaryLabel(for: battery) {
            HStack(spacing: 3) {
                Image(systemName: "airpods.gen3")
                    .font(.system(size: 11))
                Text(label)
                    .font(.system(size: 9, weight: .medium))
            }
            .foregroundColor(.white.opacity(0.62))
            .frame(height: 28)
            .accessibilityElement(children: .combine)
            .accessibilityLabel(battery.name)
            .accessibilityValue(label)
            .help(battery.name)
        }
    }
}

/// Reduced to a single glanceable metric (battery) — see `DashboardCell`'s
/// doc comment for why the original 3-card + background-activity layout
/// was cut. Memory/storage/uptime/background-activity remain reachable via
/// `NotchView.expandedDetail`'s `.dashboard` case (Today/System `DetailStrip`
/// rows), which this section does not duplicate.
struct CompactBatteryIndicator: View {
    @ObservedObject var monitor: SystemMonitor

    var body: some View {
        Button {
            openSystemSettings("x-apple.systempreferences:com.apple.Battery-Settings.extension")
        } label: {
            HStack(spacing: 3) {
                Image(systemName: monitor.isCharging ? "battery.100percent.bolt" : batteryIcon)
                    .font(.system(size: 11))
                if let level = monitor.batteryLevel {
                    Text("\(level)%")
                        .font(.system(size: 9, weight: .medium))
                }
            }
            .foregroundColor(.white.opacity(0.62))
            .frame(height: 28)
        }
        .buttonStyle(NotchPressStyle())
        .hoverLift(cornerRadius: 8)
        .accessibilityLabel(String(localized: "system.battery", defaultValue: "Battery"))
        .accessibilityValue(monitor.batteryLevel.map { "\($0)%" } ?? String(localized: "system.acPower", defaultValue: "AC"))
        .help(monitor.batteryLevel == nil ? String(localized: "system.noBatteryDetected", defaultValue: "No battery detected") : batteryDetail)
    }

    /// The pre-merge `SystemCell` hardcoded `"battery.75percent"` for every
    /// non-charging level; picking the closest SF Symbol bucket here is a
    /// (small, incidental) correctness fix alongside the redesign.
    private var batteryIcon: String {
        guard let level = monitor.batteryLevel else { return "battery.100percent" }
        switch level {
        case ..<20: return "battery.25percent"
        case ..<50: return "battery.50percent"
        case ..<80: return "battery.75percent"
        default: return "battery.100percent"
        }
    }

    private var batteryDetail: String {
        guard let remaining = monitor.timeRemainingLabel else {
            return monitor.isCharging ? String(localized: "system.charging", defaultValue: "Charging") : String(localized: "system.openSettings", defaultValue: "Open settings")
        }
        return monitor.isCharging ? String(localized: "system.chargingRemaining", defaultValue: "Charging · \(remaining) remaining") : String(localized: "system.remaining", defaultValue: "\(remaining) remaining")
    }

    private func openSystemSettings(_ rawURL: String) {
        guard let url = URL(string: rawURL) else { return }
        NSWorkspace.shared.open(url)
    }
}
