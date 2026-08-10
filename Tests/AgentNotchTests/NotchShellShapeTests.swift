import XCTest
import SwiftUI
@testable import AgentNotch

/// `NotchShellShape` draws the panel outline, including the concave flare
/// that joins `.open`'s top edge to the menu bar. `path(in:)` is pure
/// geometry, so it's exercised directly here rather than through a View.
final class NotchShellShapeTests: XCTestCase {
    private let rect = CGRect(x: 0, y: 0, width: 540, height: 176)

    func testFlarelessShapeFillsItsRect() {
        let shape = NotchShellShape(bottomRadius: 20, topFlareRadius: 0)
        let bounds = shape.path(in: rect).boundingRect

        XCTAssertEqual(bounds.minX, rect.minX, accuracy: 0.5)
        XCTAssertEqual(bounds.maxX, rect.maxX, accuracy: 0.5)
        XCTAssertEqual(bounds.minY, rect.minY, accuracy: 0.5)
        XCTAssertEqual(bounds.maxY, rect.maxY, accuracy: 0.5)
    }

    /// The flare curves away from the interior, so the top edge stays the
    /// widest point — the path must not spill outside the rect it was asked
    /// to fill (it's used as a `clipShape`, so anything outside is lost and
    /// would just mean the panel is drawing where it can't be seen).
    func testFlaredShapeStaysWithinItsRect() {
        let shape = NotchShellShape(bottomRadius: 20, topFlareRadius: 11)
        let bounds = shape.path(in: rect).boundingRect

        XCTAssertGreaterThanOrEqual(bounds.minX, rect.minX - 0.5)
        XCTAssertLessThanOrEqual(bounds.maxX, rect.maxX + 0.5)
        XCTAssertGreaterThanOrEqual(bounds.minY, rect.minY - 0.5)
        XCTAssertLessThanOrEqual(bounds.maxY, rect.maxY + 0.5)
    }

    /// The defining property of the flare: the corners are scooped *out*,
    /// so a point tucked into the very corner is outside the shape, while
    /// the body below the flare is at full width. An ordinary convex radius
    /// would fail the opposite way.
    func testFlareScoopsOutTheTopCorners() {
        let shape = NotchShellShape(bottomRadius: 20, topFlareRadius: 11)
        let path = shape.path(in: rect)

        // Middle of the top edge — unaffected by the corner treatment.
        XCTAssertTrue(path.contains(CGPoint(x: rect.midX, y: rect.minY + 0.5)))
        // Inside the corner, below the curve: carved away.
        XCTAssertFalse(path.contains(CGPoint(x: rect.minX + 2, y: rect.minY + 8)))
        XCTAssertFalse(path.contains(CGPoint(x: rect.maxX - 2, y: rect.minY + 8)))
        // Below the flare the body runs at its full (inset) width again.
        XCTAssertTrue(path.contains(CGPoint(x: rect.minX + 12, y: rect.minY + 40)))
        XCTAssertTrue(path.contains(CGPoint(x: rect.maxX - 12, y: rect.minY + 40)))
    }

    /// Without a flare those same corners are solid, so the two shapes are
    /// genuinely different rather than the flare being a no-op.
    func testSquareTopCornersAreSolidWithoutAFlare() {
        let path = NotchShellShape(bottomRadius: 20, topFlareRadius: 0).path(in: rect)

        XCTAssertTrue(path.contains(CGPoint(x: rect.minX + 2, y: rect.minY + 8)))
        XCTAssertTrue(path.contains(CGPoint(x: rect.maxX - 2, y: rect.minY + 8)))
    }

    /// Radii are clamped to the rect, so a panel briefly laid out smaller
    /// than its own corner radius (mid-resize) can't produce a self-crossing
    /// path.
    func testRadiiAreClampedOnATinyRect() {
        let tiny = CGRect(x: 0, y: 0, width: 12, height: 8)
        let shape = NotchShellShape(bottomRadius: 40, topFlareRadius: 40)
        let bounds = shape.path(in: tiny).boundingRect

        XCTAssertGreaterThanOrEqual(bounds.minX, tiny.minX - 0.5)
        XCTAssertLessThanOrEqual(bounds.maxX, tiny.maxX + 0.5)
        XCTAssertLessThanOrEqual(bounds.height, tiny.height + 0.5)
    }

    /// `strokeBorder` insets the shape by half the line width; the inset
    /// path must shrink rather than being ignored.
    func testInsetShrinksThePath() {
        let shape = NotchShellShape(bottomRadius: 20, topFlareRadius: 11)
        let inset = shape.inset(by: 4)

        let outerBounds = shape.path(in: rect).boundingRect
        let innerBounds = inset.path(in: rect).boundingRect

        XCTAssertGreaterThan(innerBounds.minX, outerBounds.minX)
        XCTAssertLessThan(innerBounds.maxX, outerBounds.maxX)
        XCTAssertGreaterThan(innerBounds.minY, outerBounds.minY)
        XCTAssertLessThan(innerBounds.maxY, outerBounds.maxY)
    }
}
