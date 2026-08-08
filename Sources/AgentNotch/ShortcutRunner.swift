import Foundation

/// A shortcut the user has pinned to the Tray, stored by name.
///
/// Name rather than identifier: `shortcuts run` accepts either, but the name
/// is what the Shortcuts app shows and what the user types in Settings, and
/// there's no supported way to look up an identifier from the CLI. The cost
/// is that renaming a shortcut breaks the binding — which surfaces as a
/// "shortcut not found" run failure rather than silently doing nothing.
struct ShortcutBinding: Codable, Identifiable, Equatable, Hashable {
    var id: UUID
    var name: String

    init(id: UUID = UUID(), name: String) {
        self.id = id
        self.name = name
    }
}

/// Runs Shortcuts shortcuts through the `shortcuts` CLI.
///
/// The CLI is used rather than an URL scheme (`shortcuts://run-shortcut`)
/// because it can take a file as input and reports whether the run actually
/// succeeded; the URL scheme does neither.
enum ShortcutRunner {
    static let executablePath = "/usr/bin/shortcuts"

    /// Present on every macOS version this app supports, but checked anyway
    /// so a missing binary reports as "unavailable" instead of throwing from
    /// `process.run()`.
    static var isAvailable: Bool {
        FileManager.default.isExecutableFile(atPath: executablePath)
    }

    /// Pure so the command shape is testable without spawning anything.
    /// `--input-path` is omitted entirely when there's no file to pass:
    /// passing an empty path makes the CLI fail rather than run with no
    /// input.
    static func arguments(name: String, inputPaths: [String]) -> [String] {
        var arguments = ["run", name]
        for path in inputPaths where !path.isEmpty {
            arguments += ["--input-path", path]
        }
        return arguments
    }

    /// Every shortcut installed for the current user, for the Settings
    /// picker. Empty when Shortcuts has none, or when the CLI fails — the
    /// caller treats both the same way (fall back to typing a name).
    static func installedNames() -> [String] {
        guard isAvailable else { return [] }
        let process = Process()
        let output = Pipe()
        process.executableURL = URL(fileURLWithPath: executablePath)
        process.arguments = ["list"]
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice

        do {
            try process.run()
        } catch {
            return []
        }
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0, let text = String(data: data, encoding: .utf8) else {
            return []
        }
        return text
            .split(separator: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }

    /// Runs `name`, optionally with files as input. Returns `nil` on success
    /// or a short message to show the user on failure.
    ///
    /// A shortcut can take arbitrarily long (it may show UI, wait on the
    /// network, or prompt), so this never blocks the caller — the whole run
    /// happens off the main actor and the result comes back when it's done.
    static func run(name: String, inputPaths: [String]) async -> String? {
        guard isAvailable else {
            return String(localized: "shortcuts.unavailable", defaultValue: "Shortcuts is unavailable")
        }
        let arguments = arguments(name: name, inputPaths: inputPaths)
        return await Task.detached(priority: .userInitiated) { () -> String? in
            let process = Process()
            let errorPipe = Pipe()
            process.executableURL = URL(fileURLWithPath: executablePath)
            process.arguments = arguments
            process.standardOutput = FileHandle.nullDevice
            process.standardError = errorPipe

            do {
                try process.run()
            } catch {
                return error.localizedDescription
            }
            // Read before waiting: a shortcut that writes more to stderr than
            // the pipe buffer holds would deadlock the other way round.
            let data = errorPipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            guard process.terminationStatus != 0 else { return nil }
            let message = String(data: data, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return message.isEmpty
                ? String(localized: "shortcuts.runFailed", defaultValue: "Shortcut failed")
                : message
        }.value
    }
}
