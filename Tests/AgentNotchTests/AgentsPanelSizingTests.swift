import XCTest
@testable import AgentNotch

/// The Agents page grows with the number of tracked sessions. Getting this
/// wrong clips the footer — which has shipped as a visible bug twice — so
/// the formula is pinned here rather than only eyeballed on screen.
@MainActor
final class AgentsPanelSizingTests: XCTestCase {
    private func height(sessions: Int, detail: Bool = false) -> CGFloat {
        NotchWindowController.agentsOpenSize(sessionCount: sessions, detailExpanded: detail).height
    }

    /// Zero sessions still renders the empty state, which needs the same
    /// room as one row — a panel sized for "no rows" would collapse onto it.
    func testEmptyListIsSizedLikeASingleRow() {
        XCTAssertEqual(height(sessions: 0), height(sessions: 1), accuracy: 0.01)
        XCTAssertEqual(height(sessions: 0), NotchWindowController.agentsBaseHeight, accuracy: 0.01)
    }

    func testEachAdditionalSessionAddsExactlyOneRow() {
        for count in 1..<NotchWindowController.agentsMaxVisibleRows {
            XCTAssertEqual(
                height(sessions: count + 1) - height(sessions: count),
                NotchWindowController.agentsRowHeight,
                accuracy: 0.01,
                "row \(count + 1) did not add one row's height"
            )
        }
    }

    /// Past the visible-row cap the list scrolls instead of growing, so the
    /// panel must stop expanding — otherwise a busy machine with a dozen
    /// agents would push it off the bottom of the screen.
    func testGrowthStopsAtTheVisibleRowCap() {
        let atCap = height(sessions: NotchWindowController.agentsMaxVisibleRows)
        XCTAssertEqual(height(sessions: NotchWindowController.agentsMaxVisibleRows + 1), atCap, accuracy: 0.01)
        XCTAssertEqual(height(sessions: 50), atCap, accuracy: 0.01)
    }

    /// `agentsMaxHeight` is the second safety net behind the row cap. The
    /// formula must stay under it at its own worst case, or the cap would be
    /// silently doing the sizing instead of the row count.
    func testWorstCaseStaysUnderTheHardCeiling() {
        let worst = height(sessions: 999, detail: true)
        XCTAssertLessThanOrEqual(worst, NotchWindowController.agentsMaxHeight)
    }

    func testExpandingDetailAddsTheDetailStripsHeight() {
        let delta = NotchWindowController.openDetailSize.height - NotchWindowController.openSize.height
        XCTAssertEqual(height(sessions: 2, detail: true) - height(sessions: 2), delta, accuracy: 0.01)
        XCTAssertGreaterThan(delta, 0)
    }

    /// A negative count can only come from a bug upstream, but it must not
    /// produce a panel smaller than the empty state.
    func testNegativeCountIsTreatedAsEmpty() {
        XCTAssertEqual(height(sessions: -5), height(sessions: 0), accuracy: 0.01)
    }

    /// Agents keeps the fixed panel width — only the Dashboard's width is
    /// content-driven.
    func testWidthIsIndependentOfSessionCount() {
        let widths = [0, 1, 5, 40].map {
            NotchWindowController.agentsOpenSize(sessionCount: $0, detailExpanded: false).width
        }
        XCTAssertEqual(Set(widths).count, 1)
        XCTAssertEqual(widths[0], NotchWindowController.openSize.width)
    }
}
