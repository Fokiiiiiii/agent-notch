import AppKit
import Combine
import EventKit
import Foundation
import IOKit.ps

struct TodayEvent: Identifiable {
    let id: String
    let startDate: Date
    let title: String
    let calendar: String
}

@MainActor
final class TodayModel: ObservableObject {
    @Published private(set) var events: [TodayEvent] = []
    @Published private(set) var authorizationStatus = EKEventStore.authorizationStatus(for: .event)
    @Published private(set) var errorMessage: String?

    private let store = EKEventStore()

    init() {
        if authorizationStatus == .fullAccess {
            refresh()
        }
    }

    var canReadCalendar: Bool {
        authorizationStatus == .fullAccess
    }

    func requestAccess() {
        Task {
            do {
                let granted = try await store.requestFullAccessToEvents()
                authorizationStatus = EKEventStore.authorizationStatus(for: .event)
                if granted { refresh() }
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    func refresh() {
        guard canReadCalendar else { return }
        let calendar = Calendar.current
        let start = calendar.startOfDay(for: Date())
        let end = calendar.date(byAdding: .day, value: 1, to: start) ?? Date().addingTimeInterval(86_400)
        let predicate = store.predicateForEvents(withStart: start, end: end, calendars: nil)
        events = store.events(matching: predicate)
            .filter { !$0.isAllDay }
            .prefix(4)
            .map {
                TodayEvent(
                    id: $0.eventIdentifier ?? UUID().uuidString,
                    startDate: $0.startDate,
                    title: $0.title ?? "Untitled event",
                    calendar: $0.calendar.title
                )
            }
    }
}

@MainActor
final class MediaController: ObservableObject {
    @Published private(set) var source = "No media"
    @Published private(set) var title = "Nothing Playing"
    @Published private(set) var artist = "Open Music or Spotify"
    @Published private(set) var isPlaying = false
    @Published private(set) var position = 0.0
    @Published private(set) var duration = 1.0
    @Published private(set) var isConnected = false

    private var timer: AnyCancellable?

    init() {
        timer = Timer.publish(every: 2, on: .main, in: .common)
            .autoconnect()
            .sink { [weak self] _ in
                guard self?.isConnected == true else { return }
                self?.refresh()
            }
    }

    var progress: Double {
        guard duration > 0 else { return 0 }
        return min(max(position / duration, 0), 1)
    }

    func togglePlayback() { run(command: "playpause") }
    func previous() { run(command: "previous track") }
    func next() { run(command: "next track") }
    func connect() {
        isConnected = true
        refresh()
    }

    private func activeBundleID() -> String? {
        let running = NSWorkspace.shared.runningApplications
        if running.contains(where: { $0.bundleIdentifier == "com.apple.Music" }) { return "com.apple.Music" }
        if running.contains(where: { $0.bundleIdentifier == "com.spotify.client" }) { return "com.spotify.client" }
        return nil
    }

    private func refresh() {
        guard let bundleID = activeBundleID() else {
            source = "No media"
            title = "Nothing Playing"
            artist = "Open Music or Spotify"
            isPlaying = false
            position = 0
            duration = 1
            return
        }

        let application = bundleID == "com.apple.Music" ? "Music" : "Spotify"
        let script = """
        tell application "\(application)"
            if player state is stopped then return "stopped"
            set trackName to name of current track
            set artistName to artist of current track
            set trackDuration to duration of current track
            set trackPosition to player position
            set playingNow to (player state is playing)
            return trackName & "|||" & artistName & "|||" & trackDuration & "|||" & trackPosition & "|||" & playingNow
        end tell
        """
        var error: NSDictionary?
        guard let value = NSAppleScript(source: script)?.executeAndReturnError(&error).stringValue,
              value != "stopped" else {
            source = application
            title = "Nothing Playing"
            artist = application
            isPlaying = false
            return
        }
        let parts = value.components(separatedBy: "|||")
        guard parts.count == 5 else { return }
        source = application
        title = parts[0]
        artist = parts[1]
        duration = Double(parts[2]) ?? 1
        position = Double(parts[3]) ?? 0
        isPlaying = parts[4].lowercased() == "true"
    }

    private func run(command: String) {
        guard let bundleID = activeBundleID() else { return }
        let application = bundleID == "com.apple.Music" ? "Music" : "Spotify"
        var error: NSDictionary?
        NSAppleScript(source: "tell application \"\(application)\" to \(command)")?
            .executeAndReturnError(&error)
        refresh()
    }
}

@MainActor
final class SystemMonitor: ObservableObject {
    @Published private(set) var batteryLevel: Int?
    @Published private(set) var isCharging = false
    @Published private(set) var memoryUsed = "—"
    @Published private(set) var memoryDetail = ""
    @Published private(set) var storageAvailable = "—"
    @Published private(set) var storageDetail = ""
    @Published private(set) var uptime = "—"

    private var timer: AnyCancellable?
    private let formatter: ByteCountFormatter = {
        let formatter = ByteCountFormatter()
        formatter.allowedUnits = [.useGB]
        formatter.countStyle = .memory
        return formatter
    }()

    init() {
        refresh()
        timer = Timer.publish(every: 3, on: .main, in: .common)
            .autoconnect()
            .sink { [weak self] _ in self?.refresh() }
    }

    func refresh() {
        refreshBattery()
        refreshMemory()
        refreshStorage()
        let seconds = ProcessInfo.processInfo.systemUptime
        let days = Int(seconds / 86_400)
        let hours = Int(seconds.truncatingRemainder(dividingBy: 86_400) / 3_600)
        uptime = days > 0 ? "\(days)d \(hours)h" : "\(hours)h"
    }

    private func refreshBattery() {
        guard let snapshot = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let sources = IOPSCopyPowerSourcesList(snapshot)?.takeRetainedValue() as? [CFTypeRef],
              let source = sources.first,
              let description = IOPSGetPowerSourceDescription(snapshot, source)?.takeUnretainedValue() as? [String: Any] else {
            batteryLevel = nil
            isCharging = false
            return
        }
        batteryLevel = description[kIOPSCurrentCapacityKey] as? Int
        let state = description[kIOPSPowerSourceStateKey] as? String
        isCharging = state == kIOPSACPowerValue
    }

    private func refreshMemory() {
        let total = Int64(ProcessInfo.processInfo.physicalMemory)
        var pageSize: vm_size_t = 0
        host_page_size(mach_host_self(), &pageSize)
        var statistics = vm_statistics64()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64_data_t>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &statistics) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return }
        let usedPages = UInt64(statistics.active_count + statistics.inactive_count + statistics.wire_count + statistics.compressor_page_count)
        let used = min(Int64(usedPages * UInt64(pageSize)), total)
        memoryUsed = formatter.string(fromByteCount: used)
        memoryDetail = "of \(formatter.string(fromByteCount: total))"
    }

    private func refreshStorage() {
        guard let values = try? URL(fileURLWithPath: NSHomeDirectory()).resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey, .volumeTotalCapacityKey]) else { return }
        if let available = values.volumeAvailableCapacityForImportantUsage {
            storageAvailable = formatter.string(fromByteCount: available)
        }
        if let total = values.volumeTotalCapacity {
            storageDetail = "of \(formatter.string(fromByteCount: Int64(total)))"
        }
    }
}
