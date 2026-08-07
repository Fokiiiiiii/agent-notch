import Foundation

/// Shared tail-reading/staleness-check logic that used to be duplicated
/// byte-for-byte (including comments) between `ClaudeWatcher` and
/// `CodexWatcher`. Both watchers keep their own `readTailLines(atPath:)`
/// instance method and `needsReparse(...)` static method — same signatures,
/// same call sites, same test coverage in `WatcherParsingTests.swift` — but
/// each now delegates its one-line body here instead of maintaining its own
/// copy. Only the two functions that were verified to be identical are
/// pulled out; `scan()`/`refreshState(_:modDate:now:)` (core polling/state-
/// transition logic) stay in each watcher untouched.
enum TranscriptTailReading {
    /// Whether a transcript needs to be re-parsed, given its previously
    /// cached (size, modification date) and the currently observed values.
    /// Comparing on size alone misses same-size content edits, so both must
    /// match to skip re-parsing.
    static func needsReparse(cachedSize: UInt64?, cachedModDate: Date?, currentSize: UInt64, currentModDate: Date) -> Bool {
        cachedSize != currentSize || cachedModDate != currentModDate
    }

    /// Reads the last `tailByteCount` bytes of the file and returns up to
    /// `maxTailLines` lines, split by newline, from the end.
    static func readTailLines(atPath path: String, tailByteCount: Int, maxTailLines: Int) -> [String]? {
        guard let handle = FileHandle(forReadingAtPath: path) else { return nil }
        defer { try? handle.close() }

        let fileSize: UInt64
        do {
            fileSize = try handle.seekToEnd()
        } catch {
            return nil
        }

        let readSize = min(UInt64(tailByteCount), fileSize)
        let offset = fileSize - readSize
        do {
            try handle.seek(toOffset: offset)
        } catch {
            return nil
        }

        guard let data = try? handle.read(upToCount: Int(readSize)) else { return nil }
        // The tail read may start mid-way through a multi-byte UTF-8 character
        // (since we cut at a fixed byte offset, not a character boundary).
        // `String(decoding:as:)` never fails; it replaces invalid sequences at
        // the cut point with U+FFFD instead of discarding the whole read.
        let text = String(decoding: data, as: UTF8.self)

        var lines = text.components(separatedBy: "\n")
        if lines.count > maxTailLines {
            lines = Array(lines.suffix(maxTailLines))
        }
        return lines
    }
}
