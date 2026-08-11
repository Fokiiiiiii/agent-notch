import SwiftUI
import AppKit

// The Tray page: the file shelf, the AirDrop well, and their actions.

struct TrayItem: Identifiable {
    let id = UUID()
    let url: URL
}

enum TrayAction {
    case choose, open, reveal, airDrop, compress, copyPath, attach, removeSelected, removeItem(UUID), clear, undo
    /// Run a user-registered Shortcuts shortcut with the current selection
    /// as its input.
    case runShortcut(ShortcutBinding)
}

/// SF Symbols ships no `airdrop` glyph (checked at runtime — `airplayaudio`
/// exists but reads as AirPlay), so the mark is drawn: three concentric arcs
/// opening downward over a small upward wedge, which is what the system's
/// AirDrop icon is. Meant to be `.stroke`d, not filled.
struct AirDropGlyph: Shape {
    func path(in rect: CGRect) -> Path {
        let side = min(rect.width, rect.height)
        let center = CGPoint(x: rect.midX, y: rect.midY)
        var path = Path()
        // Near-full rings with a gap at the bottom (115°→65° the long way
        // round), which is the notch in the system's AirDrop mark. Each ring
        // needs its own `move(to:)` — without it `addArc` joins to the
        // previous subpath's end and draws a stray chord across the glyph.
        for scale in [0.22, 0.34, 0.46] {
            let radius = side * scale
            let start = Angle.degrees(115)
            path.move(to: CGPoint(
                x: center.x + radius * cos(start.radians),
                y: center.y + radius * sin(start.radians)
            ))
            path.addArc(
                center: center,
                radius: radius,
                startAngle: start,
                endAngle: .degrees(65),
                clockwise: false
            )
        }
        let dot = side * 0.055
        path.addEllipse(in: CGRect(x: center.x - dot, y: center.y - dot, width: dot * 2, height: dot * 2))
        return path
    }
}

struct TrayCell: View {
    @Binding var items: [TrayItem]
    @Binding var selectedItemID: UUID?
    let isTargeted: Bool
    let isAirDropTargeted: Bool
    let shortcuts: [ShortcutBinding]
    /// Reported upward so `NotchView` can route an incoming drop to AirDrop
    /// instead of the Tray — see `isOverAirDropWell`.
    @Binding var airDropWellFrame: CGRect
    let feedback: String?
    let canUndo: Bool
    let action: (TrayAction) -> Void

    var body: some View {
        CellSurface {
            VStack(spacing: 8) {
                HStack(spacing: 8) {
                    trayShelf
                    airDropShelf
                }
                HStack(spacing: 6) {
                    Text(statusLabel)
                        .font(.system(size: 10, weight: .medium))
                        .foregroundColor(.white.opacity(0.68))
                        .lineLimit(1)
                        .truncationMode(.middle)
                    if let feedback {
                        Text(feedback)
                            .font(.system(size: 9.5))
                            .foregroundColor(DesignTokens.muted)
                            .lineLimit(1)
                    }
                    if canUndo {
                        Button(String(localized: "tray.undo", defaultValue: "Undo")) { action(.undo) }
                            .buttonStyle(.plain)
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundColor(.white.opacity(0.86))
                            .accessibilityIdentifier("tray.undo")
                    }
                    Spacer(minLength: 4)
                    if items.isEmpty {
                        TrayButton(String(localized: "tray.chooseFiles", defaultValue: "Choose Files"), "plus", action: { action(.choose) })
                    } else {
                        TrayButton(String(localized: "tray.open", defaultValue: "Open"), "arrow.up.forward.app", action: { action(.open) })
                        TrayButton(String(localized: "tray.finder", defaultValue: "Finder"), "folder", action: { action(.reveal) })
                        TrayButton(String(localized: "tray.airDrop", defaultValue: "AirDrop"), "airplayaudio", action: { action(.airDrop) })
                        TrayButton(String(localized: "tray.copyForAgent", defaultValue: "Copy for Agent"), "paperclip", action: { action(.attach) })
                        Menu {
                            Button(String(localized: "tray.compress", defaultValue: "Compress"), systemImage: "archivebox") { action(.compress) }
                            Button(String(localized: "tray.copyPath", defaultValue: "Copy Path"), systemImage: "doc.on.doc") { action(.copyPath) }
                            // Only shown once the user has registered one in
                            // Settings — an empty "Shortcuts" submenu would
                            // just be a dead end.
                            if !shortcuts.isEmpty {
                                Divider()
                                ForEach(shortcuts) { shortcut in
                                    Button(shortcut.name, systemImage: "bolt") { action(.runShortcut(shortcut)) }
                                }
                            }
                            Divider()
                            Button(String(localized: "tray.removeSelected", defaultValue: "Remove Selected"), systemImage: "minus.circle", role: .destructive) { action(.removeSelected) }
                            Button(String(localized: "tray.clearAll", defaultValue: "Clear All"), systemImage: "trash", role: .destructive) {
                                SoundPlayer.shared.play(.deny)
                                action(.clear)
                            }
                        } label: {
                            Image(systemName: "ellipsis")
                                .frame(width: 30, height: 30)
                                .background(RoundedRectangle(cornerRadius: 8).fill(Color.white.opacity(0.08)))
                        }
                        .menuStyle(.borderlessButton)
                        .menuIndicator(.hidden)
                        .help(String(localized: "tray.moreFileActionsHelp", defaultValue: "More file actions"))
                        .accessibilityLabel(String(localized: "tray.moreFileActionsHelp", defaultValue: "More file actions"))
                    }
                }
            }.foregroundColor(.white)
        }
    }

    private var statusLabel: String {
        guard !items.isEmpty else { return String(localized: "tray.isEmpty", defaultValue: "Tray is empty") }
        guard let selectedItemID,
              let selected = items.first(where: { $0.id == selectedItemID }) else {
            return String(localized: "tray.itemCount", defaultValue: "\(String(items.count)) item\(items.count == 1 ? "" : "s")")
        }
        return String(localized: "tray.selectedItemCount", defaultValue: "\(selected.url.lastPathComponent) · \(String(items.count)) item\(items.count == 1 ? "" : "s")")
    }

    /// A second, smaller well beside the Tray: dropping here hands the files
    /// straight to AirDrop instead of stashing them. Deliberately narrow —
    /// the Tray stays the primary target and this sits next to it as a
    /// shortcut, not as an equal half of the page.
    private var airDropShelf: some View {
        RoundedRectangle(cornerRadius: 13)
            .fill(DesignTokens.airDropWell.opacity(isAirDropTargeted ? 0.62 : 0.34))
            .overlay(
                RoundedRectangle(cornerRadius: 13)
                    .stroke(Color.accentColor.opacity(isAirDropTargeted ? 0.75 : 0.2), lineWidth: 1)
            )
            .overlay(alignment: .topLeading) {
                VStack(alignment: .leading, spacing: 6) {
                    AirDropGlyph()
                        .stroke(Color.accentColor, style: StrokeStyle(lineWidth: 1.6, lineCap: .round))
                        .frame(width: 19, height: 19)
                    Text(String(localized: "tray.airDrop", defaultValue: "AirDrop"))
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundColor(.white.opacity(0.92))
                }
                .padding(11)
            }
            .frame(width: 118)
            // No `.dropDestination` here: the panel's AppKit container view
            // owns the whole drag session (see `FileDropContainerView`), so a
            // SwiftUI drop target would be competing with it. This publishes
            // its frame instead and lets that one owner route the drop.
            .onGeometryChange(for: CGRect.self, of: { $0.frame(in: .global) }) { frame in
                airDropWellFrame = frame
            }
            .onDisappear { airDropWellFrame = .zero }
            .help(String(localized: "tray.airDropWellHelp", defaultValue: "Drop files here to send them with AirDrop"))
            .accessibilityLabel(String(localized: "tray.airDropWellHelp", defaultValue: "Drop files here to send them with AirDrop"))
    }

    @ViewBuilder
    private var trayShelf: some View {
        if items.isEmpty {
            Button {
                action(.choose)
            } label: {
                RoundedRectangle(cornerRadius: 13)
                    .strokeBorder(Color.white.opacity(isTargeted ? 0.58 : 0.18), style: StrokeStyle(lineWidth: 1.2, dash: [5, 5]))
                    .background(RoundedRectangle(cornerRadius: 13).fill(Color.white.opacity(isTargeted ? 0.08 : 0.025)))
                    .overlay(
                        HStack(spacing: 11) {
                            Image(systemName: "tray.and.arrow.down.fill")
                                .font(.system(size: 21, weight: .medium))
                            VStack(alignment: .leading, spacing: 3) {
                                Text(String(localized: "tray.dropFilesHere", defaultValue: "Drop files here"))
                                    .font(.system(size: 12, weight: .semibold))
                                Text(String(localized: "tray.clickToChoose", defaultValue: "or click to choose from Finder"))
                                    .font(.system(size: 8.5))
                                    .foregroundColor(DesignTokens.muted)
                            }
                        }
                    )
            }
            .buttonStyle(NotchPressStyle())
            .help(String(localized: "tray.addFilesHelp", defaultValue: "Add files to the temporary Tray"))
        } else {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(items) { item in
                        // The card (select/open/drag-out) and the remove
                        // button used to share the same corner with only a
                        // 4pt offset between them, so a slightly imprecise
                        // click on one could trigger the other (e.g. trying
                        // to grab the remove "x" instead starting a drag).
                        // Reserving top/trailing padding around the card
                        // gives the "x" its own dead zone outside the card's
                        // hit-test bounds instead of overlapping it.
                        ZStack(alignment: .topTrailing) {
                            Button {
                                selectedItemID = item.id
                            } label: {
                                VStack(spacing: 5) {
                                    Image(nsImage: NSWorkspace.shared.icon(forFile: item.url.path))
                                        .resizable()
                                        .scaledToFit()
                                        .frame(width: 42, height: 42)
                                    Text(item.url.lastPathComponent)
                                        .font(.system(size: 9.5, weight: .medium))
                                        .lineLimit(1)
                                        .truncationMode(.middle)
                                        .frame(width: 68)
                                }
                                .padding(.horizontal, 7)
                                .padding(.vertical, 8)
                                .background(
                                    RoundedRectangle(cornerRadius: 11)
                                        .fill(Color.white.opacity(selectedItemID == item.id ? 0.14 : 0.055))
                                )
                                .overlay(
                                    RoundedRectangle(cornerRadius: 11)
                                        .stroke(Color.white.opacity(selectedItemID == item.id ? 0.20 : 0.04), lineWidth: 1)
                                )
                            }
                            .buttonStyle(NotchPressStyle())
                            .help(item.url.path)
                            .simultaneousGesture(TapGesture(count: 2).onEnded { NSWorkspace.shared.open(item.url) })
                            .onDrag {
                                selectedItemID = item.id
                                return NSItemProvider(contentsOf: item.url) ?? NSItemProvider()
                            }
                            .padding(.top, 7)
                            .padding(.trailing, 7)

                            Button {
                                action(.removeItem(item.id))
                            } label: {
                                Image(systemName: "xmark.circle.fill")
                                    .font(.system(size: 13, weight: .medium))
                                    .foregroundColor(.white.opacity(0.85))
                                    .background(Circle().fill(Color.black.opacity(0.35)))
                            }
                            .buttonStyle(.plain)
                            .frame(width: 22, height: 22)
                            .contentShape(Circle())
                            .help(String(localized: "tray.removeItemHelp", defaultValue: "Remove \(item.url.lastPathComponent) from Tray"))
                            .accessibilityLabel(String(localized: "tray.removeItemHelp", defaultValue: "Remove \(item.url.lastPathComponent) from Tray"))
                        }
                    }
                    Button { action(.choose) } label: {
                        Image(systemName: "plus")
                            .font(.system(size: 15, weight: .medium))
                            .frame(width: 42, height: 64)
                            .background(RoundedRectangle(cornerRadius: 11).fill(Color.white.opacity(0.04)))
                    }
                    .buttonStyle(NotchPressStyle())
                    .help(String(localized: "tray.addMoreFiles", defaultValue: "Add more files"))
                    .accessibilityLabel(String(localized: "tray.addMoreFiles", defaultValue: "Add more files"))
                }
                .padding(.horizontal, 2)
            }
        }
    }
}

struct TrayButton: View {
    let title: String, icon: String, action: () -> Void
    init(_ title: String, _ icon: String, action: @escaping () -> Void) { self.title = title; self.icon = icon; self.action = action }
    var body: some View {
        Button {
            SoundPlayer.shared.play(.action)
            action()
        } label: {
            Label(title, systemImage: icon)
                .font(.system(size: 10, weight: .medium))
                .padding(.horizontal, 10)
                .frame(height: 30)
                .background(RoundedRectangle(cornerRadius: 8).fill(Color.white.opacity(0.08)))
        }
        .buttonStyle(NotchPressStyle())
        .hoverLift(cornerRadius: 8)
        .accessibilityIdentifier("tray.action.\(title.lowercased().replacingOccurrences(of: " ", with: "-"))")
        .help(title)
    }
}
