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
    static let shared = MediaController()

    @Published private(set) var source = "No media"
    @Published private(set) var title = "Nothing Playing"
    @Published private(set) var artist = "Play media in any app"
    @Published private(set) var isPlaying = false
    @Published private(set) var position = 0.0
    @Published private(set) var duration = 1.0
    @Published private(set) var isConnected = false
    @Published private(set) var hasMedia = false
    @Published private(set) var artwork: NSImage?
    @Published private(set) var accentColor = NSColor.white

    private var timer: AnyCancellable?
    private var refreshInFlight = false
    private var artworkIdentifier: String?
    private let adapterScriptPath: String?
    private let adapterLibraryPath: String?

    init() {
        adapterScriptPath = Bundle.main.resourceURL?
            .appendingPathComponent("mediaremote-adapter.pl").path
        adapterLibraryPath = Bundle.main.resourceURL?
            .appendingPathComponent("MediaRemoteAdapter.dylib").path
        isConnected = adapterScriptPath.map(FileManager.default.fileExists) == true
            && adapterLibraryPath.map(FileManager.default.fileExists) == true
        refresh()
        timer = Timer.publish(every: 1.5, on: .main, in: .common)
            .autoconnect()
            .sink { [weak self] _ in
                self?.refresh()
            }
    }

    var progress: Double {
        guard duration > 0 else { return 0 }
        return min(max(position / duration, 0), 1)
    }

    func togglePlayback() { send(command: 2) }
    func previous() { send(command: 5) }
    func next() { send(command: 4) }
    func connect() { refresh() }

    func refresh() {
        guard !refreshInFlight,
              let script = adapterScriptPath,
              let library = adapterLibraryPath else { return }
        refreshInFlight = true
        Task {
            let snapshot = await Task.detached(priority: .utility) {
                SystemMediaBridge.read(script: script, library: library)
            }.value
            refreshInFlight = false
            apply(snapshot)
        }
    }

    private func apply(_ snapshot: SystemMediaSnapshot?) {
        guard let snapshot else {
            source = isConnected ? "System media" : "Media unavailable"
            title = "Nothing Playing"
            artist = isConnected ? "Play media in any app" : "Media adapter is missing"
            isPlaying = false
            position = 0
            duration = 1
            hasMedia = false
            artwork = nil
            artworkIdentifier = nil
            accentColor = .white
            return
        }

        let application = snapshot.bundleIdentifier.flatMap {
            NSRunningApplication.runningApplications(withBundleIdentifier: $0).first?.localizedName
        }
        source = application ?? snapshot.bundleIdentifier ?? "System media"
        title = snapshot.title
        artist = snapshot.artist?.isEmpty == false ? snapshot.artist! : source
        isPlaying = snapshot.isPlaying
        position = snapshot.position
        duration = max(snapshot.duration, 1)
        hasMedia = true
        let nextArtworkIdentifier = snapshot.itemIdentifier ?? "\(snapshot.title)|\(snapshot.artist ?? "")"
        if nextArtworkIdentifier != artworkIdentifier {
            artworkIdentifier = nextArtworkIdentifier
            artwork = snapshot.artworkData.flatMap(NSImage.init(data:))
            accentColor = artwork.flatMap(Self.averageArtworkColor) ?? .white
        }
    }

    private func send(command: Int) {
        guard let script = adapterScriptPath, let library = adapterLibraryPath else { return }
        Task {
            _ = await Task.detached(priority: .userInitiated) {
                SystemMediaBridge.send(command: command, script: script, library: library)
            }.value
            refresh()
        }
    }

    private static func averageArtworkColor(_ image: NSImage) -> NSColor? {
        guard let data = image.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: data),
              bitmap.pixelsWide > 0, bitmap.pixelsHigh > 0 else { return nil }

        let stepX = max(bitmap.pixelsWide / 12, 1)
        let stepY = max(bitmap.pixelsHigh / 12, 1)
        var red = 0.0, green = 0.0, blue = 0.0, weightTotal = 0.0

        for y in stride(from: stepY / 2, to: bitmap.pixelsHigh, by: stepY) {
            for x in stride(from: stepX / 2, to: bitmap.pixelsWide, by: stepX) {
                guard let color = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB) else { continue }
                let brightness = max(color.redComponent, color.greenComponent, color.blueComponent)
                let minimum = min(color.redComponent, color.greenComponent, color.blueComponent)
                let saturation = brightness > 0 ? (brightness - minimum) / brightness : 0
                guard color.alphaComponent > 0.4, brightness > 0.12, brightness < 0.96 else { continue }
                let weight = 0.25 + saturation
                red += color.redComponent * weight
                green += color.greenComponent * weight
                blue += color.blueComponent * weight
                weightTotal += weight
            }
        }

        guard weightTotal > 0 else { return nil }
        let average = NSColor(
            calibratedRed: red / weightTotal,
            green: green / weightTotal,
            blue: blue / weightTotal,
            alpha: 1
        )
        var hue = CGFloat.zero, saturation = CGFloat.zero, brightness = CGFloat.zero, alpha = CGFloat.zero
        average.getHue(&hue, saturation: &saturation, brightness: &brightness, alpha: &alpha)
        guard saturation > 0.12 else { return NSColor(calibratedWhite: max(brightness, 0.78), alpha: 1) }
        return NSColor(
            calibratedHue: hue,
            saturation: max(saturation, 0.55),
            brightness: max(brightness, 0.72),
            alpha: 1
        )
    }
}

private struct SystemMediaSnapshot: Sendable {
    let bundleIdentifier: String?
    let title: String
    let artist: String?
    let isPlaying: Bool
    let position: Double
    let duration: Double
    let artworkData: Data?
    let itemIdentifier: String?
}

private enum SystemMediaBridge {
    static func read(script: String, library: String) -> SystemMediaSnapshot? {
        guard let data = run(script: script, library: library, arguments: ["get"]),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let title = object["title"] as? String,
              !title.isEmpty else { return nil }

        let artworkData: Data?
        if let encoded = object["artworkData"] as? String {
            artworkData = Data(base64Encoded: encoded)
        } else {
            artworkData = nil
        }
        return SystemMediaSnapshot(
            bundleIdentifier: object["bundleIdentifier"] as? String,
            title: title,
            artist: object["artist"] as? String,
            isPlaying: object["playing"] as? Bool ?? false,
            position: number(object["elapsedTimeNow"] ?? object["elapsedTime"]),
            duration: number(object["duration"]),
            artworkData: artworkData,
            itemIdentifier: object["contentItemIdentifier"] as? String
        )
    }

    @discardableResult
    static func send(command: Int, script: String, library: String) -> Bool {
        run(script: script, library: library, arguments: ["send", String(command)]) != nil
    }

    private static func number(_ value: Any?) -> Double {
        (value as? NSNumber)?.doubleValue ?? 0
    }

    private static func run(script: String, library: String, arguments: [String]) -> Data? {
        let process = Process()
        let output = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/perl")
        process.arguments = [script, library] + arguments
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            let data = output.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            return process.terminationStatus == 0 ? data : nil
        } catch {
            return nil
        }
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
