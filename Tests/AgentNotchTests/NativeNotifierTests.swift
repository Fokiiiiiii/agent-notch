import XCTest
@testable import AgentNotch

@MainActor
final class NativeNotifierTests: XCTestCase {
    /// `renderGlyphAttachment(for:)` writes a PNG to the temp directory so it
    /// can be handed to `UNNotificationAttachment`, which copies the file
    /// into its own managed storage. Regression test for a leak where the
    /// source temp file was never removed afterwards.
    func testRenderGlyphAttachmentDoesNotLeaveTempFileBehind() throws {
        let notifier = NativeNotifier()
        let tempDir = FileManager.default.temporaryDirectory
        let before = Set(try FileManager.default.contentsOfDirectory(atPath: tempDir.path))

        guard let attachment = notifier.renderGlyphAttachment(for: .claude) else {
            throw XCTSkip("glyph rendering unavailable in this environment (e.g. headless CI)")
        }
        // The attachment itself must still be usable (points at UNNotificationAttachment's
        // own copied storage, not the now-deleted source file).
        XCTAssertFalse(attachment.identifier.isEmpty)

        let after = Set(try FileManager.default.contentsOfDirectory(atPath: tempDir.path))
        let newPNGs = after.subtracting(before).filter { $0.hasSuffix(".png") }
        XCTAssertTrue(newPNGs.isEmpty, "expected no leftover PNG temp files, found: \(newPNGs)")
    }
}
