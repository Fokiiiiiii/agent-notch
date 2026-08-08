import XCTest
@testable import AgentNotch

/// Covers the argument construction only. Actually running a shortcut needs
/// the user's own Shortcuts library and can show UI, so `run(name:inputPaths:)`
/// is verified by hand rather than here.
final class ShortcutRunnerTests: XCTestCase {
    func testArgumentsWithNoInputOmitsInputPath() {
        XCTAssertEqual(
            ShortcutRunner.arguments(name: "Make QR Code", inputPaths: []),
            ["run", "Make QR Code"]
        )
    }

    func testArgumentsPassASingleInputPath() {
        XCTAssertEqual(
            ShortcutRunner.arguments(name: "Resize", inputPaths: ["/tmp/a.png"]),
            ["run", "Resize", "--input-path", "/tmp/a.png"]
        )
    }

    /// `shortcuts run` takes `--input-path` more than once (its help spells
    /// the option `<input-path> ...`), which is how a multi-file Tray
    /// selection reaches the shortcut.
    func testArgumentsRepeatTheFlagForEachInputPath() {
        XCTAssertEqual(
            ShortcutRunner.arguments(name: "Combine", inputPaths: ["/tmp/a.pdf", "/tmp/b.pdf"]),
            ["run", "Combine", "--input-path", "/tmp/a.pdf", "--input-path", "/tmp/b.pdf"]
        )
    }

    /// An empty path would make the CLI fail outright, so it's dropped
    /// rather than passed through.
    func testArgumentsSkipEmptyInputPaths() {
        XCTAssertEqual(
            ShortcutRunner.arguments(name: "Run", inputPaths: ["", "/tmp/a.txt", ""]),
            ["run", "Run", "--input-path", "/tmp/a.txt"]
        )
    }

    /// The name is passed as one argument, never shell-quoted or split — a
    /// shortcut named with spaces has to survive intact.
    func testArgumentsKeepAMultiWordNameAsOneArgument() {
        let arguments = ShortcutRunner.arguments(name: "Take a Break", inputPaths: [])
        XCTAssertEqual(arguments.count, 2)
        XCTAssertEqual(arguments[1], "Take a Break")
    }

    func testBindingRoundTripsThroughJSON() throws {
        let binding = ShortcutBinding(name: "Text Last Image")
        let data = try JSONEncoder().encode([binding])
        let decoded = try JSONDecoder().decode([ShortcutBinding].self, from: data)
        XCTAssertEqual(decoded, [binding])
    }
}
