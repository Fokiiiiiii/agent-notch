import XCTest
@testable import AgentNotch

/// A Tray entry outlives the drop that created it — it can be opened,
/// revealed, compressed, or AirDropped minutes later. These cover what the
/// Tray is allowed to keep a reference to.
final class TrayIntakeTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("tray-intake-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    @discardableResult
    private func makeFile(_ name: String, contents: String = "x") throws -> URL {
        let url = directory.appendingPathComponent(name)
        try contents.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    private func accept(_ dropped: [URL], existing: [URL] = []) -> [URL] {
        TrayIntake.acceptable(dropped: dropped, existing: existing)
    }

    // MARK: - Existence

    func testOrdinaryFileIsAccepted() throws {
        let file = try makeFile("a.txt")
        XCTAssertEqual(accept([file]).map(\.lastPathComponent), ["a.txt"])
    }

    /// A file deleted between the drag starting and finishing would sit in
    /// the shelf looking valid until the user acted on it.
    func testNonexistentPathIsDropped() {
        let ghost = directory.appendingPathComponent("gone.txt")
        XCTAssertTrue(accept([ghost]).isEmpty)
    }

    func testNonFileURLsAreDropped() throws {
        let file = try makeFile("real.txt")
        let link = URL(string: "https://example.com/x.txt")!
        XCTAssertEqual(accept([link, file]).map(\.lastPathComponent), ["real.txt"])
    }

    // MARK: - Symlinks

    /// AirDrop and Finder-reveal act on the target anyway, and sending a
    /// symlink to another Mac produces a link that resolves to nothing.
    func testSymlinkIsResolvedToItsTarget() throws {
        let target = try makeFile("target.txt")
        let link = directory.appendingPathComponent("link.txt")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)

        let accepted = accept([link])
        XCTAssertEqual(accepted.count, 1)
        XCTAssertEqual(accepted[0].lastPathComponent, "target.txt")
    }

    /// A symlink whose target is gone resolves to a path that doesn't
    /// exist, so it must be dropped rather than kept as a broken entry.
    func testDanglingSymlinkIsDropped() throws {
        let link = directory.appendingPathComponent("dangling.txt")
        try FileManager.default.createSymbolicLink(
            at: link,
            withDestinationURL: directory.appendingPathComponent("never-existed.txt")
        )
        XCTAssertTrue(accept([link]).isEmpty)
    }

    /// Two different links to one file are one file — keeping both would put
    /// duplicate rows in the shelf that act identically.
    func testTwoSymlinksToTheSameFileCollapseToOneEntry() throws {
        let target = try makeFile("shared.txt")
        for name in ["l1.txt", "l2.txt"] {
            try FileManager.default.createSymbolicLink(
                at: directory.appendingPathComponent(name),
                withDestinationURL: target
            )
        }
        let accepted = accept([
            directory.appendingPathComponent("l1.txt"),
            directory.appendingPathComponent("l2.txt"),
        ])
        XCTAssertEqual(accepted.count, 1)
    }

    // MARK: - Duplicates

    func testFileAlreadyInTheTrayIsNotAddedTwice() throws {
        let file = try makeFile("dup.txt")
        XCTAssertTrue(accept([file], existing: [file]).isEmpty)
    }

    /// The existing entry may have been stored resolved while the new drop
    /// arrives as a link (or vice versa) — both sides are normalised before
    /// comparing.
    func testSymlinkMatchingAnExistingResolvedEntryIsRejected() throws {
        let target = try makeFile("t.txt")
        let link = directory.appendingPathComponent("l.txt")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)
        XCTAssertTrue(accept([link], existing: [target]).isEmpty)
    }

    func testTheSameFileTwiceInOneDropIsAddedOnce() throws {
        let file = try makeFile("once.txt")
        XCTAssertEqual(accept([file, file]).count, 1)
    }

    // MARK: - Batch size

    /// Dragging a large folder's worth of files onto a horizontal strip is
    /// far more likely to be a slip than an intention.
    func testDropIsCappedAndKeepsTheFirstFiles() throws {
        var files: [URL] = []
        for i in 0..<(TrayIntake.maxItemsPerDrop + 10) {
            files.append(try makeFile(String(format: "f%03d.txt", i)))
        }
        let accepted = accept(files)
        XCTAssertEqual(accepted.count, TrayIntake.maxItemsPerDrop)
        XCTAssertEqual(accepted.first?.lastPathComponent, "f000.txt")
    }

    // MARK: - Feedback

    /// "Drop failed" should reflect what survived filtering, not how many
    /// paths arrived — a drop of only dangling references is a failed drop.
    func testADropOfOnlyInvalidPathsCountsAsFailed() {
        let ghost = directory.appendingPathComponent("nope.txt")
        XCTAssertTrue(TrayIntake.isEmptyResult(dropped: [ghost], accepted: []))
    }

    func testAnEmptyDropIsNotReportedAsAFailedOne() {
        XCTAssertFalse(TrayIntake.isEmptyResult(dropped: [], accepted: []))
    }

    func testASuccessfulDropIsNotReportedAsFailed() throws {
        let file = try makeFile("ok.txt")
        XCTAssertFalse(TrayIntake.isEmptyResult(dropped: [file], accepted: [file]))
    }
}
