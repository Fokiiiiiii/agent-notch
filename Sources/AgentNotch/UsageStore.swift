import Foundation
import AgentNotchCore

struct UsageWindow: Sendable {
    let usedPercent: Double
    let resetDescription: String?
    /// Absolute reset time, when CodexBar provides one (it does for every
    /// window observed so far). Preferred over `resetDescription` for
    /// display: CodexBar's own string is a long absolute datetime (e.g.
    /// "Jul 20 at 5:20AM") that doesn't fit the compact usage bar, whereas
    /// this lets us render a short, always-fresh relative countdown instead.
    let resetsAt: Date?
    let windowMinutes: Int?

    var label: String {
        let window: String
        switch windowMinutes ?? 0 {
        case 0..<360: window = "5h"
        case 360..<10_000: window = "Day"
        default: window = "Week"
        }
        return "\(window) \(Int(usedPercent.rounded()))%"
    }

    /// Compact "resets in Xh"/"resets in Xm" style description, computed
    /// from `resetsAt` at call time so it stays accurate without needing a
    /// fresh network fetch. Falls back to the raw `resetDescription` string
    /// only when `resetsAt` is unavailable.
    func relativeResetDescription(now: Date = Date()) -> String? {
        guard let resetsAt else { return resetDescription }
        let interval = resetsAt.timeIntervalSince(now)
        guard interval > 0 else {
            return String(localized: "usage.reset.now", defaultValue: "resets now")
        }
        let totalMinutes = max(1, Int(interval / 60))
        if totalMinutes < 60 {
            return String(localized: "usage.reset.minutes", defaultValue: "resets in \(totalMinutes)m")
        }
        let hours = totalMinutes / 60
        if hours < 24 {
            return String(localized: "usage.reset.hours", defaultValue: "resets in \(hours)h")
        }
        let days = hours / 24
        return String(localized: "usage.reset.days", defaultValue: "resets in \(days)d")
    }
}

struct AgentUsageSnapshot: Sendable {
    let agent: AgentKind
    let primary: UsageWindow?
    let secondary: UsageWindow?
    let source: String?
    let error: String?
    let updatedAt: Date

}

/// Reads the same provider-normalized JSON that CodexBar exposes. The UI
/// never substitutes demo percentages: unavailable providers stay explicit.
@MainActor
final class AgentUsageStore: ObservableObject {
    static let shared = AgentUsageStore()

    @Published private(set) var snapshots: [AgentKind: AgentUsageSnapshot] = [:]
    @Published private(set) var isRefreshing = false

    private var refreshTimer: Timer?

    private init() {
        refresh()
        refreshTimer = Timer.scheduledTimer(withTimeInterval: 5 * 60, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
    }

    deinit {
        refreshTimer?.invalidate()
    }

    func refresh() {
        guard !isRefreshing else { return }
        isRefreshing = true
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let result = Self.fetchFromCodexBar()
            DispatchQueue.main.async {
                guard let self else { return }
                self.snapshots = result
                self.isRefreshing = false
            }
        }
    }

    private nonisolated static func fetchFromCodexBar() -> [AgentKind: AgentUsageSnapshot] {
        guard let executable = codexBarExecutable() else {
            return [:]
        }

        let process = Process()
        let output = Pipe()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = ["usage", "--provider", "all", "--json", "--no-color"]
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice

        do {
            try process.run()
        } catch {
            return [:]
        }

        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard let rows = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
            return [:]
        }

        var result: [AgentKind: AgentUsageSnapshot] = [:]
        for row in rows {
            guard let provider = row["provider"] as? String,
                  let agent = agent(for: provider) else { continue }
            let usage = row["usage"] as? [String: Any]
            let errorObject = row["error"] as? [String: Any]
            let error = (errorObject?["message"] as? String) ?? (row["error"] as? String)
            result[agent] = AgentUsageSnapshot(
                agent: agent,
                primary: usageWindow(usage?["primary"]),
                secondary: usageWindow(usage?["secondary"]),
                source: row["source"] as? String,
                error: error,
                updatedAt: Date()
            )
        }
        return result
    }

    private nonisolated(unsafe) static let resetsAtFormatter = ISO8601DateFormatter()

    private nonisolated static func usageWindow(_ raw: Any?) -> UsageWindow? {
        guard let object = raw as? [String: Any], let used = object["usedPercent"] as? NSNumber else {
            return nil
        }
        let resetsAt = (object["resetsAt"] as? String).flatMap { resetsAtFormatter.date(from: $0) }
        return UsageWindow(
            usedPercent: used.doubleValue,
            resetDescription: object["resetDescription"] as? String,
            resetsAt: resetsAt,
            windowMinutes: (object["windowMinutes"] as? NSNumber)?.intValue
        )
    }

    // Internal (not `private`) so tests can exercise the provider-string ->
    // AgentKind mapping directly — same pattern as ClaudeWatcher/CodexWatcher's
    // `readTailLines`/`needsReparse`.
    nonisolated static func agent(for provider: String) -> AgentKind? {
        switch provider.lowercased() {
        case "codex": return .codex
        case "claude": return .claude
        case "antigravity": return .antigravity
        case "gemini": return .gemini
        case "copilot": return .copilot
        case "cursor": return .cursor
        case "opencode": return .opencode
        case "mistral": return .mistral
        case "deepseek": return .deepseek
        case "kimi", "moonshot": return .kimi
        default: return nil
        }
    }

    private nonisolated static func codexBarExecutable() -> String? {
        let candidates = ["/opt/homebrew/bin/codexbar", "/usr/local/bin/codexbar"]
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0) }
    }
}
