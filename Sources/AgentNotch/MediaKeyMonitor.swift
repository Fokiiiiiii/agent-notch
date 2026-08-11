import AppKit
import ApplicationServices

/// Which way a hardware media-key/remote skip moved — used only to pick
/// which SF Symbol to flash as feedback, never to trigger playback control
/// ourselves (macOS has already routed the actual skip to whichever app is
/// the current Now Playing target by the time this fires).
enum SkipDirection: Equatable, Sendable {
    case forward
    case backward
}

/// Global media-key monitoring, split into a pure decoder (testable without
/// a real `NSEvent`) and a thin class that wires it to `NSEvent`'s global
/// monitor. `NX_KEYTYPE_*` values come from `<IOKit/hidsystem/ev_keymap.h>`;
/// hardcoded here (with the header's names in comments) since these are C
/// `#define` macros with no Swift-visible import in this SwiftPM package.
enum MediaKeyDecoder {
    /// The `NSEvent.subtype.rawValue` macOS reports for media-key
    /// `.systemDefined` events (there is no dedicated `NSEvent.EventSubtype`
    /// case for this — AppKit reuses the same raw value `.screenChanged`
    /// happens to have).
    private static let mediaKeySubtype: Int16 = 8
    private static let keyDownState = 0xA

    private static let nxKeyTypePlay: Int32 = 16
    private static let nxKeyTypeNext: Int32 = 17
    private static let nxKeyTypePrevious: Int32 = 18
    private static let nxKeyTypeFast: Int32 = 19
    private static let nxKeyTypeRewind: Int32 = 20

    static func decodeSkipDirection(subtypeRawValue: Int16, data1: Int) -> SkipDirection? {
        guard subtypeRawValue == mediaKeySubtype else { return nil }
        let keyCode = Int32((data1 & 0xFFFF0000) >> 16)
        let keyState = (data1 & 0x0000FF00) >> 8
        guard keyState == keyDownState else { return nil }
        switch keyCode {
        case nxKeyTypeNext, nxKeyTypeFast:
            return .forward
        case nxKeyTypePrevious, nxKeyTypeRewind:
            return .backward
        case nxKeyTypePlay:
            return nil
        default:
            return nil
        }
    }
}

/// Wraps `NSEvent.addGlobalMonitorForEvents(matching: .systemDefined)` to
/// observe hardware media-key/remote skip presses. Passive observer only —
/// `onSkip` must never call back into playback control (see call site).
// Main-actor isolated: its only owner (`MediaController`) is, `onSkip`
// updates published UI state, and the global event monitor's callback hops
// here anyway. Saying so lets `self` be referenced from that hop without an
// escape hatch.
@MainActor
final class MediaKeyMonitor {
    var onSkip: ((SkipDirection) -> Void)?

    // Read from the nonisolated `deinit`; see there for why that's safe.
    nonisolated(unsafe) private var monitor: Any?

    /// Whether Accessibility trust has been granted, checked *without*
    /// prompting.
    static var isAccessibilityTrusted: Bool {
        AXIsProcessTrusted()
    }

    /// Shows the system's Accessibility prompt. Only ever called from an
    /// explicit user action (the Settings button) — never on launch.
    /// `kAXTrustedCheckOptionPrompt` re-asks on *every* call while trust is
    /// missing, so having `start()` do it meant a system dialog on every
    /// single app start for anyone who hadn't granted it.
    static func requestAccessibilityTrust() {
        // The key is spelled out rather than read from
        // `kAXTrustedCheckOptionPrompt`: that symbol is a global `var` in the
        // C headers, which isn't concurrency-safe to reference. Its value is
        // a documented, stable constant.
        _ = AXIsProcessTrustedWithOptions(["AXTrustedCheckOptionPrompt": true] as CFDictionary)
    }

    func start() {
        guard monitor == nil else { return }
        // Global `.systemDefined` media-key delivery is gated behind
        // Accessibility trust. Install the monitor regardless: without
        // trust it simply never fires, which costs only the skip indicator,
        // and asking here would nag on every launch.
        monitor = NSEvent.addGlobalMonitorForEvents(matching: .systemDefined) { [weak self] event in
            guard let self,
                  let direction = MediaKeyDecoder.decodeSkipDirection(subtypeRawValue: event.subtype.rawValue, data1: event.data1)
            else { return }
            // Hop with the direction only. `onSkip` is a non-`Sendable`
            // closure, so reading it here and carrying it into the task
            // would send it across a concurrency boundary; reading it on the
            // main actor instead keeps it on one side.
            Task { @MainActor in self.onSkip?(direction) }
        }
    }

    func stop() {
        if let monitor {
            NSEvent.removeMonitor(monitor)
        }
        monitor = nil
    }

    deinit {
        // `deinit` is nonisolated even on a main-actor type, so it can't call
        // `stop()`. The monitor token is only written on `start()`/`stop()`
        // and read once here, so unregistering it directly is equivalent —
        // same treatment as the observer tokens in `NotchWindow.swift`.
        if let monitor {
            NSEvent.removeMonitor(monitor)
        }
    }
}
