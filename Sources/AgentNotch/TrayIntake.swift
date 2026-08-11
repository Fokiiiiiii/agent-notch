import Foundation

/// Normalises what a drop actually puts in the Tray.
///
/// Everything here comes from the user's own drag, so this is not a defence
/// against an attacker — it's about the Tray holding references that still
/// mean something later. A Tray entry outlives the drop: it can be opened,
/// revealed in Finder, compressed, or handed to AirDrop minutes afterwards,
/// so a dangling or indirect reference turns into a confusing failure at the
/// moment the user acts on it, far from the drop that caused it.
enum TrayIntake {
    /// Cap on how many files one drop can add. Dragging a large folder's
    /// worth of files onto the notch is far more likely to be a slip than an
    /// intention, and the shelf is a horizontal strip — a few dozen entries
    /// is already past the point of being usable.
    static let maxItemsPerDrop = 50

    /// Resolves and filters `dropped`, skipping anything already in
    /// `existing`.
    ///
    /// - Symlinks and aliases are resolved to what they point at. AirDrop
    ///   and Finder-reveal both act on the target anyway, and sending a
    ///   symlink to another Mac produces a link that resolves to nothing
    ///   there.
    /// - Paths that don't exist are dropped: a file deleted between the drag
    ///   starting and finishing would otherwise sit in the shelf looking
    ///   valid until acted on.
    /// - Duplicates are removed, both against `existing` and within the drop
    ///   itself (two symlinks to one file collapse into one entry).
    static func acceptable(
        dropped: [URL],
        existing: [URL],
        fileManager: FileManager = .default
    ) -> [URL] {
        var seen = Set(existing.map { $0.resolvingSymlinksInPath().standardizedFileURL })
        var accepted: [URL] = []

        for url in dropped where url.isFileURL {
            let resolved = url.resolvingSymlinksInPath().standardizedFileURL
            guard fileManager.fileExists(atPath: resolved.path) else { continue }
            guard !seen.contains(resolved) else { continue }
            seen.insert(resolved)
            accepted.append(resolved)
            if accepted.count == maxItemsPerDrop { break }
        }
        return accepted
    }

    /// Whether a drop had usable content at all — the caller shows "Drop
    /// failed" when it didn't, and that message should reflect the files
    /// that survived filtering rather than the raw count.
    static func isEmptyResult(dropped: [URL], accepted: [URL]) -> Bool {
        accepted.isEmpty && !dropped.isEmpty
    }
}
