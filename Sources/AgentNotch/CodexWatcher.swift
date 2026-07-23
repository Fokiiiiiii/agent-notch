import Foundation

/// Polls `~/.codex/sessions/YYYY/MM/DD/rollout-*.jsonl` transcripts and
/// reflects active Codex sessions into a `SessionStore`. Read-only.
///
/// Rollout line shapes observed in the wild (see real files for ground
/// truth): `{"type":"session_meta","payload":{"cwd":...,"session_id":...}}`,
/// `{"type":"turn_context","payload":{"cwd":...}}` (repeated per turn — the
/// most reliable place to find `cwd` within a tail read of a long file),
/// `{"type":"event_msg","payload":{"type":"agent_message","message":...}}`,
/// and `{"type":"response_item","payload":{"type":"function_call"|"custom_tool_call","name":...}}`.
@MainActor
final class CodexWatcher {
    private let store: SessionStore
    private var timer: Timer?
    private let fileManager = FileManager.default
    private let sessionsURL: URL
    /// Tracks last-seen file size per transcript path, so unchanged files are skipped.
    private var lastSeenSize: [String: UInt64] = [:]
    /// Cached parsed result per transcript path, reused when the file hasn't changed.
    private var lastResult: [String: AgentSession] = [:]

    private let pollInterval: TimeInterval = 2
    private let activeWindow: TimeInterval = 30 * 60
    private let runningWindow: TimeInterval = 90
    private let tailByteCount = 64 * 1024
    private let maxTailLines = 400

    init(store: SessionStore) {
        self.store = store
        self.sessionsURL = fileManager.homeDirectoryForCurrentUser
            .appendingPathComponent(".codex/sessions", isDirectory: true)
    }

    func start() {
        scan()
        let timer = Timer(timeInterval: pollInterval, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.scan()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    private func scan() {
        let transcripts = discoverTranscripts()
        let now = Date()
        var activeSessions: [AgentSession] = []

        for path in transcripts {
            guard let attrs = try? fileManager.attributesOfItem(atPath: path) else { continue }
            guard let modDate = attrs[.modificationDate] as? Date else { continue }
            guard now.timeIntervalSince(modDate) <= activeWindow else { continue }

            let size = (attrs[.size] as? UInt64) ?? 0
            if lastSeenSize[path] == size, let cached = lastResult[path] {
                // Size unchanged: reuse prior parse but refresh state based on time.
                activeSessions.append(refreshState(cached, modDate: modDate, now: now))
                continue
            }

            if let session = parseSession(atPath: path, modDate: modDate, now: now) {
                lastSeenSize[path] = size
                lastResult[path] = session
                activeSessions.append(session)
            }
        }

        store.replaceSessions(agent: .codex, activeSessions)
    }

    private func refreshState(_ session: AgentSession, modDate: Date, now: Date) -> AgentSession {
        var updated = session
        updated.lastActivity = modDate
        updated.state = now.timeIntervalSince(modDate) <= runningWindow ? .running : .idle
        return updated
    }

    /// Finds `rollout-*.jsonl` files under `~/.codex/sessions/YYYY/MM/DD/`,
    /// restricted to today's and yesterday's date directories (three levels:
    /// year/month/day) — enough given `activeWindow` is only 30 minutes.
    private func discoverTranscripts() -> [String] {
        let calendar = Calendar(identifier: .gregorian)
        let today = Date()
        guard let yesterday = calendar.date(byAdding: .day, value: -1, to: today) else {
            return discoverTranscripts(forDay: today)
        }
        return discoverTranscripts(forDay: yesterday) + discoverTranscripts(forDay: today)
    }

    private func discoverTranscripts(forDay day: Date) -> [String] {
        let calendar = Calendar(identifier: .gregorian)
        let components = calendar.dateComponents([.year, .month, .day], from: day)
        guard let year = components.year, let month = components.month, let dayNum = components.day else {
            return []
        }

        let dayURL = sessionsURL
            .appendingPathComponent(String(format: "%04d", year), isDirectory: true)
            .appendingPathComponent(String(format: "%02d", month), isDirectory: true)
            .appendingPathComponent(String(format: "%02d", dayNum), isDirectory: true)

        guard let files = try? fileManager.contentsOfDirectory(
            at: dayURL,
            includingPropertiesForKeys: [.isSymbolicLinkKey],
            options: [.skipsHiddenFiles]
        ) else {
            return []
        }

        var results: [String] = []
        for file in files {
            guard file.pathExtension == "jsonl" else { continue }
            guard file.lastPathComponent.hasPrefix("rollout-") else { continue }
            if let rv = try? file.resourceValues(forKeys: [.isSymbolicLinkKey]), rv.isSymbolicLink == true {
                continue
            }
            results.append(file.path)
        }
        return results
    }

    private func parseSession(atPath path: String, modDate: Date, now: Date) -> AgentSession? {
        guard let lines = readTailLines(atPath: path) else { return nil }

        var cwd: String?
        var lastMessage: String?
        var contextUsedPercent: Double?

        // Walk from the end to find the most recent cwd / agent message / command.
        for rawLine in lines.reversed() {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty else { continue }
            guard let data = line.data(using: .utf8) else { continue }
            guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { continue }

            let topType = obj["type"] as? String
            let payload = obj["payload"] as? [String: Any]

            if cwd == nil, let c = payload?["cwd"] as? String, !c.isEmpty {
                cwd = c
            }

            if lastMessage == nil, topType == "event_msg", (payload?["type"] as? String) == "agent_message" {
                if let message = payload?["message"] as? String {
                    lastMessage = summarize(text: message)
                }
            }

            if lastMessage == nil, topType == "response_item" {
                let payloadType = payload?["type"] as? String
                if payloadType == "function_call" || payloadType == "custom_tool_call",
                   let name = payload?["name"] as? String {
                    lastMessage = summarize(text: "Running \(name)…")
                }
            }

            if contextUsedPercent == nil, topType == "event_msg", (payload?["type"] as? String) == "token_count" {
                if let info = payload?["info"] as? [String: Any],
                   let totalUsage = info["total_token_usage"] as? [String: Any],
                   let totalTokens = (totalUsage["total_tokens"] as? NSNumber)?.doubleValue,
                   let contextWindow = (info["model_context_window"] as? NSNumber)?.doubleValue,
                   contextWindow > 0 {
                    contextUsedPercent = (totalTokens / contextWindow) * 100
                }
            }

            if cwd != nil, lastMessage != nil, contextUsedPercent != nil {
                break
            }
        }

        guard let cwd else { return nil }

        let fileStem = (path as NSString).lastPathComponent.replacingOccurrences(of: ".jsonl", with: "")
        let id = Self.extractUUID(from: fileStem) ?? fileStem

        let title = (cwd as NSString).lastPathComponent
        let state: SessionState = now.timeIntervalSince(modDate) <= runningWindow ? .running : .idle

        return AgentSession(
            id: id,
            agent: .codex,
            title: title,
            cwd: cwd,
            lastActivity: modDate,
            state: state,
            lastMessage: lastMessage ?? "…",
            contextUsedPercent: contextUsedPercent
        )
    }

    /// Extracts the trailing UUID from a rollout file stem, e.g.
    /// `rollout-2026-07-18T18-55-35-019f74a7-1745-7272-b68b-1e0e3ba44a09` ->
    /// `019f74a7-1745-7272-b68b-1e0e3ba44a09`.
    private static func extractUUID(from stem: String) -> String? {
        let pattern = #"[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        let range = NSRange(stem.startIndex..<stem.endIndex, in: stem)
        guard let match = regex.firstMatch(in: stem, range: range), let matchRange = Range(match.range, in: stem) else {
            return nil
        }
        return String(stem[matchRange])
    }

    private func summarize(text: String) -> String {
        let collapsed = text.replacingOccurrences(of: "\n", with: " ")
        return String(collapsed.prefix(80))
    }

    /// Reads the last `tailByteCount` bytes of the file and returns up to
    /// `maxTailLines` lines, split by newline, from the end.
    private func readTailLines(atPath path: String) -> [String]? {
        guard let handle = FileHandle(forReadingAtPath: path) else { return nil }
        defer { try? handle.close() }

        let fileSize: UInt64
        do {
            fileSize = try handle.seekToEnd()
        } catch {
            return nil
        }

        let readSize = min(UInt64(tailByteCount), fileSize)
        let offset = fileSize - readSize
        do {
            try handle.seek(toOffset: offset)
        } catch {
            return nil
        }

        guard let data = try? handle.read(upToCount: Int(readSize)) else { return nil }
        guard let text = String(data: data, encoding: .utf8) else { return nil }

        var lines = text.components(separatedBy: "\n")
        if lines.count > maxTailLines {
            lines = Array(lines.suffix(maxTailLines))
        }
        return lines
    }
}
