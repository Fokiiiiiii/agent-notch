import Foundation

/// Append-only log of hook deliveries (`~/.agent-notch/events.log`), used to
/// diagnose "the agent fired but nothing appeared in the notch".
///
/// It grew without bound: the app is a permanent resident, every hook
/// appends a line, and nothing ever trimmed it. The lines record project
/// paths and tool names, so an unbounded file is both a disk-usage problem
/// and a slowly accumulating record of what the user has been working on.
/// One rotation generation caps it while still keeping enough history to be
/// useful for the debugging it exists for.
enum EventLog {
    /// Rotate past this size. A hook line is ~80 bytes, so half a mebibyte
    /// is on the order of 6,000 events — comfortably more than any debugging
    /// session needs, and small enough that the two generations together
    /// stay under a mebibyte.
    static let maxBytes: UInt64 = 512 * 1024

    /// Owner-only: these lines name the directories the user works in.
    static let filePermissions = 0o600

    static var defaultURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".agent-notch/events.log")
    }

    /// Pure, so the threshold is testable without writing megabytes to disk.
    /// The check happens *before* appending: a line is never split across a
    /// rotation.
    static func shouldRotate(currentSize: UInt64) -> Bool {
        currentSize >= maxBytes
    }

    /// Appends one line, rotating first if the file has reached its cap.
    /// Every failure is silent by design — this is diagnostics, and losing a
    /// log line must never disturb hook delivery.
    static func append(_ line: String, to url: URL = defaultURL) {
        let fileManager = FileManager.default
        if let handle = try? FileHandle(forWritingTo: url) {
            // `seekToEnd` returns the size, so the cap costs no extra stat.
            let size = (try? handle.seekToEnd()) ?? 0
            if shouldRotate(currentSize: size) {
                try? handle.close()
                rotate(at: url, fileManager: fileManager)
                create(line, at: url, fileManager: fileManager)
                return
            }
            try? handle.write(contentsOf: Data(line.utf8))
            try? handle.close()
        } else {
            create(line, at: url, fileManager: fileManager)
        }
    }

    /// Moves the current log aside to `<name>.1`, replacing any previous
    /// generation. Exactly one generation is kept — older history has no
    /// diagnostic value and would reintroduce unbounded growth.
    static func rotate(at url: URL, fileManager: FileManager = .default) {
        let previous = url.appendingPathExtension("1")
        try? fileManager.removeItem(at: previous)
        try? fileManager.moveItem(at: url, to: previous)
    }

    private static func create(_ line: String, at url: URL, fileManager: FileManager) {
        fileManager.createFile(
            atPath: url.path,
            contents: Data(line.utf8),
            attributes: [.posixPermissions: filePermissions]
        )
    }
}
