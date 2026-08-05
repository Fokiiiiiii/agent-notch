import XCTest
@testable import AgentNotch

/// Regression tests for `MediaKeyDecoder.decodeSkipDirection`, the pure
/// bit-decoding logic behind the media-key skip indicator (see
/// `MediaKeyMonitor.swift`). No real `NSEvent` is constructed — `data1` is
/// hand-built from the same key-code/key-state bit layout the decoder uses,
/// matching `ScreenGeometryTests`' style of hand-deriving expected values.
final class MediaKeyMonitorTests: XCTestCase {

    private let mediaKeySubtype: Int16 = 8
    private let keyDown = 0xA
    private let keyUp = 0xB

    private func data1(keyCode: Int32, keyState: Int) -> Int {
        (Int(keyCode) << 16) | (keyState << 8)
    }

    func testDecodesNextKeyDownAsForward() {
        let direction = MediaKeyDecoder.decodeSkipDirection(
            subtypeRawValue: mediaKeySubtype,
            data1: data1(keyCode: 17, keyState: keyDown)
        )
        XCTAssertEqual(direction, .forward)
    }

    func testDecodesFastKeyDownAsForward() {
        let direction = MediaKeyDecoder.decodeSkipDirection(
            subtypeRawValue: mediaKeySubtype,
            data1: data1(keyCode: 19, keyState: keyDown)
        )
        XCTAssertEqual(direction, .forward)
    }

    func testDecodesPreviousKeyDownAsBackward() {
        let direction = MediaKeyDecoder.decodeSkipDirection(
            subtypeRawValue: mediaKeySubtype,
            data1: data1(keyCode: 18, keyState: keyDown)
        )
        XCTAssertEqual(direction, .backward)
    }

    func testDecodesRewindKeyDownAsBackward() {
        let direction = MediaKeyDecoder.decodeSkipDirection(
            subtypeRawValue: mediaKeySubtype,
            data1: data1(keyCode: 20, keyState: keyDown)
        )
        XCTAssertEqual(direction, .backward)
    }

    func testIgnoresKeyUp() {
        // Only the key-down edge should fire the indicator — otherwise a
        // single physical press would fire it twice (down and up).
        for keyCode: Int32 in [17, 18, 19, 20] {
            let direction = MediaKeyDecoder.decodeSkipDirection(
                subtypeRawValue: mediaKeySubtype,
                data1: data1(keyCode: keyCode, keyState: keyUp)
            )
            XCTAssertNil(direction, "expected keyCode \(keyCode) key-up to be ignored")
        }
    }

    func testIgnoresPlayPauseKey() {
        // NX_KEYTYPE_PLAY is not a skip — must not be misread as one.
        let direction = MediaKeyDecoder.decodeSkipDirection(
            subtypeRawValue: mediaKeySubtype,
            data1: data1(keyCode: 16, keyState: keyDown)
        )
        XCTAssertNil(direction)
    }

    func testIgnoresWrongSubtype() {
        // Only `.systemDefined` media-key events (subtype 8) are relevant —
        // any other subtype must be ignored even with an otherwise-valid data1.
        let direction = MediaKeyDecoder.decodeSkipDirection(
            subtypeRawValue: 0,
            data1: data1(keyCode: 17, keyState: keyDown)
        )
        XCTAssertNil(direction)
    }

    func testIgnoresUnknownKeyCode() {
        let direction = MediaKeyDecoder.decodeSkipDirection(
            subtypeRawValue: mediaKeySubtype,
            data1: data1(keyCode: 999, keyState: keyDown)
        )
        XCTAssertNil(direction)
    }
}
