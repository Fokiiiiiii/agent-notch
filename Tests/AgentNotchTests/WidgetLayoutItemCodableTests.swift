import XCTest
@testable import AgentNotch

/// Regression guard for `WidgetLayoutItem`'s hand-written `Decodable`
/// conformance (Phase 6 of the redesign roadmap): a layout saved by an
/// older build — before `displayName`/`alignment`/`priority`/`minWidth`/
/// `preferredWidth`/`showsInCompact`/`showsInHover`/`showsInExpanded`/
/// `fullscreenBehavior` existed — must still decode without throwing, with
/// every new field falling back to its documented default.
final class WidgetLayoutItemCodableTests: XCTestCase {
    func testDecodesOldShapeJSONWithOnlyTheOriginalFourFields() throws {
        let json = """
        {"id": "media.sources", "isVisible": true, "order": 2, "sizeScale": 1.0}
        """.data(using: .utf8)!

        let item = try JSONDecoder().decode(WidgetLayoutItem.self, from: json)

        XCTAssertEqual(item.id, "media.sources")
        XCTAssertEqual(item.isVisible, true)
        XCTAssertEqual(item.order, 2)
        XCTAssertEqual(item.sizeScale, 1.0)
        // New fields fall back to their defaults rather than throwing.
        XCTAssertEqual(item.displayName, "")
        XCTAssertEqual(item.alignment, .leading)
        XCTAssertEqual(item.priority, 0)
        XCTAssertEqual(item.minWidth, 0)
        XCTAssertEqual(item.preferredWidth, 0)
        XCTAssertEqual(item.showsInCompact, true)
        XCTAssertEqual(item.showsInHover, true)
        XCTAssertEqual(item.showsInExpanded, true)
        XCTAssertEqual(item.fullscreenBehavior, .hoverOnly)
    }

    func testDecodesMinimalJSONWithOnlyRequiredFields() throws {
        // `id` and `order` are the only fields without a default value.
        let json = """
        {"id": "agents.list", "order": 0}
        """.data(using: .utf8)!

        let item = try JSONDecoder().decode(WidgetLayoutItem.self, from: json)

        XCTAssertEqual(item.id, "agents.list")
        XCTAssertEqual(item.order, 0)
        XCTAssertEqual(item.isVisible, true)
    }

    func testRoundTripsThroughEncodeAndDecode() throws {
        let original = WidgetLayoutItem(
            id: "tray.items",
            displayName: "Tray",
            isVisible: false,
            alignment: .trailing,
            order: 3,
            priority: 2,
            minWidth: 40,
            preferredWidth: 80,
            showsInCompact: false,
            showsInHover: true,
            showsInExpanded: true,
            fullscreenBehavior: .hide,
            sizeScale: 1.5
        )

        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(WidgetLayoutItem.self, from: data)

        XCTAssertEqual(decoded, original)
    }

    func testTabLayoutConfigurationStillDecodesAnArrayOfOldShapeWidgets() throws {
        // `TabLayoutConfiguration` is the actually-persisted type
        // (`AppSettings.tabLayouts`) — confirm the backward-compat
        // guarantee holds through it too, not just the bare item type.
        let json = """
        {"widgets": [{"id": "a", "order": 0}, {"id": "b", "isVisible": false, "order": 1}]}
        """.data(using: .utf8)!

        let config = try JSONDecoder().decode(TabLayoutConfiguration.self, from: json)

        XCTAssertEqual(config.widgets.count, 2)
        XCTAssertEqual(config.applying(to: ["a", "b", "c"]), ["a", "c"])
    }
}
