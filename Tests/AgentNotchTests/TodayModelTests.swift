import XCTest
@testable import AgentNotch

@MainActor
final class TodayModelTests: XCTestCase {
    /// `TodayModel` used to only refresh from `init()`/`requestAccess()`, so
    /// it never picked up a midnight rollover or an out-of-band calendar
    /// edit. Regression test: confirm the periodic timer and the
    /// `.EKEventStoreChanged` subscription are both wired up on init.
    /// (Mirror is used because these are private implementation details —
    /// this only asserts the *shape* of the fix, not its exact interval.)
    func testInitWiresUpPeriodicRefreshAndEventStoreChangeSubscription() {
        let model = TodayModel()
        let mirror = Mirror(reflecting: model)

        let timer = mirror.children.first { $0.label == "timer" }?.value
        let storeChangeObserver = mirror.children.first { $0.label == "storeChangeObserver" }?.value

        XCTAssertNotNil(timer, "expected a periodic refresh timer to be set up in init()")
        XCTAssertNotNil(storeChangeObserver, "expected an .EKEventStoreChanged subscription to be set up in init()")

        // AnyCancellable? children show up as Optional(AnyCancellable) rather
        // than nil when actually assigned.
        if let timer {
            XCTAssertFalse(String(describing: timer).contains("nil"))
        }
        if let storeChangeObserver {
            XCTAssertFalse(String(describing: storeChangeObserver).contains("nil"))
        }
    }
}
