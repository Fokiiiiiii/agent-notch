import Combine
import Foundation
import IOBluetooth

/// Battery readings for one connected set of AirPods (or Beats). Any field
/// can be absent: single-battery models report only `single`, while the
/// earbuds report `left`/`right`/`caseLevel` and the case's level only
/// arrives while it's open.
struct AirPodsBattery: Equatable {
    let name: String
    let single: Int?
    let left: Int?
    let right: Int?
    let caseLevel: Int?

    var hasAnyReading: Bool {
        single != nil || left != nil || right != nil || caseLevel != nil
    }
}

/// Reads AirPods battery levels from IOBluetooth.
///
/// **This uses private API.** `IOBluetoothDevice` exposes no public battery
/// interface; the levels live in undocumented KVC properties
/// (`batteryPercentSingle`/`Left`/`Right`/`Case`) that Apple can rename or
/// remove in any macOS update. Everything is read through `value(forKey:)`
/// and cast with `as? NSNumber`, never force-unwrapped, so a rename
/// degrades to "no reading" instead of crashing.
///
/// Off by default and never touched until enabled: calling
/// `IOBluetoothDevice.pairedDevices()` without
/// `NSBluetoothAlwaysUsageDescription` in Info.plist makes TCC terminate
/// the process outright (verified — it aborts with
/// `__TCC_CRASHING_DUE_TO_PRIVACY_VIOLATION__`), so this must never run in
/// a build whose Info.plist lacks that key.
@MainActor
final class AirPodsBatteryMonitor: ObservableObject {
    static let shared = AirPodsBatteryMonitor()

    /// Nil whenever nothing is connected or no reading is available, which
    /// is what keeps the indicator hidden rather than showing a blank.
    @Published private(set) var battery: AirPodsBattery?

    private var timer: AnyCancellable?

    /// The undocumented keys, in the order they're read.
    private static let batteryKeys = (
        single: "batteryPercentSingle",
        left: "batteryPercentLeft",
        right: "batteryPercentRight",
        caseLevel: "batteryPercentCase"
    )

    private init() {}

    func setEnabled(_ enabled: Bool) {
        guard enabled else {
            timer?.cancel()
            timer = nil
            battery = nil
            return
        }
        guard timer == nil else { return }
        refresh()
        // 15s: battery levels move slowly, and each poll walks the paired
        // device list.
        timer = Timer.publish(every: 15, on: .main, in: .common)
            .autoconnect()
            .sink { [weak self] _ in
                self?.refresh()
            }
    }

    private func refresh() {
        battery = Self.readConnectedAirPods()
    }

    /// First connected device that reports any battery level. Not filtered
    /// by name or vendor: anything exposing these keys is something whose
    /// battery the user would want to see.
    private static func readConnectedAirPods() -> AirPodsBattery? {
        guard let devices = IOBluetoothDevice.pairedDevices() else { return nil }
        for case let device as IOBluetoothDevice in devices where device.isConnected() {
            let reading = AirPodsBattery(
                name: device.name ?? String(localized: "airpods.unnamedDevice", defaultValue: "Headphones"),
                single: percent(device, Self.batteryKeys.single),
                left: percent(device, Self.batteryKeys.left),
                right: percent(device, Self.batteryKeys.right),
                caseLevel: percent(device, Self.batteryKeys.caseLevel)
            )
            if reading.hasAnyReading { return reading }
        }
        return nil
    }

    /// `value(forKey:)` on a key the class doesn't implement raises an
    /// Objective-C exception rather than returning nil, so unknown keys are
    /// guarded by `responds(to:)` first.
    private static func percent(_ device: IOBluetoothDevice, _ key: String) -> Int? {
        guard device.responds(to: NSSelectorFromString(key)) else { return nil }
        guard let number = device.value(forKey: key) as? NSNumber else { return nil }
        let value = number.intValue
        // 0 is reported for "unknown" as often as for a flat battery, and a
        // level above 100 is nonsense — treat both as no reading.
        guard value > 0, value <= 100 else { return nil }
        return value
    }

    /// One short string for the indicator. Earbuds collapse to their lower
    /// side: at this size there's no room for "L 80% R 75%", and the lower
    /// of the two is the number that actually matters.
    nonisolated static func summaryLabel(for battery: AirPodsBattery) -> String? {
        if let single = battery.single {
            return "\(single)%"
        }
        let buds = [battery.left, battery.right].compactMap { $0 }
        if let lowest = buds.min() {
            return "\(lowest)%"
        }
        if let caseLevel = battery.caseLevel {
            return "\(caseLevel)%"
        }
        return nil
    }
}
