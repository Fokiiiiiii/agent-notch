import Foundation

struct UsageWindow: Sendable {
    let usedPercent: Double
    let resetDescription: String?
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
}

struct AgentUsageSnapshot: Sendable {
    let agent: AgentKind
    let primary: UsageWindow?
    let secondary: UsageWindow?
    let source: String?
    let error: String?
    let updatedAt: Date

    var compactLabel: String {
        let windows = [primary, secondary].compactMap { $0?.label }
        if !windows.isEmpty { return windows.joined(separator: " · ") }
        return error == nil ? "No usage window" : "Unavailable"
    }
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

    private nonisolated static func usageWindow(_ raw: Any?) -> UsageWindow? {
        guard let object = raw as? [String: Any], let used = object["usedPercent"] as? NSNumber else {
            return nil
        }
        return UsageWindow(
            usedPercent: used.doubleValue,
            resetDescription: object["resetDescription"] as? String,
            windowMinutes: (object["windowMinutes"] as? NSNumber)?.intValue
        )
    }

    private nonisolated static func agent(for provider: String) -> AgentKind? {
        switch provider.lowercased() {
        case "codex": return .codex
        case "claude": return .claude
        case "antigravity": return .antigravity
        case "gemini": return .gemini
        case "copilot": return .copilot
        case "cursor": return .cursor
        case "opencode": return .opencode
        default: return nil
        }
    }

    private nonisolated static func codexBarExecutable() -> String? {
        let candidates = ["/opt/homebrew/bin/codexbar", "/usr/local/bin/codexbar"]
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0) }
    }
}
