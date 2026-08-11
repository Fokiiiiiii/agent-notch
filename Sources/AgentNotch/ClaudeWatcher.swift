import Foundation

/// Polls `~/.claude/projects/**/*.jsonl` transcripts and reflects active
/// Claude Code sessions into a `SessionStore`. Read-only.
@MainActor
final class ClaudeWatcher {
    private let store: SessionStore
    private var timer: Timer?
    private let fileManager = FileManager.default
    private let projectsURL: URL
    /// Tracks last-seen file size per transcript path, so unchanged files are skipped.
    private var lastSeenSize: [String: UInt64] = [:]
    /// Tracks last-seen modification date per transcript path, paired with size to
    /// detect content changes that don't alter the byte count.
    private var lastSeenModDate: [String: Date] = [:]
    /// Cached parsed result per transcript path, reused when the file hasn't changed.
    private var lastResult: [String: AgentSession] = [:]

    private let pollInterval: TimeInterval = 2
    private let activeWindow: TimeInterval = 30 * 60
    private let runningWindow: TimeInterval = 90
    private let tailByteCount = 64 * 1024
    private let maxTailLines = 200

    init(store: SessionStore) {
        self.store = store
        self.projectsURL = fileManager.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude/projects", isDirectory: true)
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
            let unchanged = !Self.needsReparse(
                cachedSize: lastSeenSize[path], cachedModDate: lastSeenModDate[path],
                currentSize: size, currentModDate: modDate
            )
            if unchanged, let cached = lastResult[path] {
                // Size and modification date unchanged: reuse prior parse but refresh state based on time.
                activeSessions.append(refreshState(cached, modDate: modDate, now: now))
                continue
            }

            if let session = parseSession(atPath: path, modDate: modDate, now: now) {
                lastSeenSize[path] = size
                lastSeenModDate[path] = modDate
                lastResult[path] = session
                activeSessions.append(session)
            }
        }

        let currentPaths = Set(transcripts)
        let staleKeys = lastSeenSize.keys.filter { !currentPaths.contains($0) }
        for staleKey in staleKeys {
            lastSeenSize.removeValue(forKey: staleKey)
            lastSeenModDate.removeValue(forKey: staleKey)
            lastResult.removeValue(forKey: staleKey)
        }

        store.replaceClaudeSessions(activeSessions)
    }

    private func refreshState(_ session: AgentSession, modDate: Date, now: Date) -> AgentSession {
        var updated = session
        updated.lastActivity = modDate
        updated.state = now.timeIntervalSince(modDate) <= runningWindow ? .running : .idle
        return updated
    }

    /// Whether a transcript needs to be re-parsed, given its previously cached
    /// (size, modification date) and the currently observed values. Comparing
    /// on size alone misses same-size content edits, so both must match to
    /// skip re-parsing.
    static func needsReparse(cachedSize: UInt64?, cachedModDate: Date?, currentSize: UInt64, currentModDate: Date) -> Bool {
        TranscriptTailReading.needsReparse(cachedSize: cachedSize, cachedModDate: cachedModDate, currentSize: currentSize, currentModDate: currentModDate)
    }

    /// Finds `*.jsonl` files one level below `~/.claude/projects/<project>/*.jsonl`.
    private func discoverTranscripts() -> [String] {
        guard let projectDirs = try? fileManager.contentsOfDirectory(
            at: projectsURL,
            includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey],
            options: [.skipsHiddenFiles]
        ) else {
            return []
        }

        var results: [String] = []
        for projectDir in projectDirs {
            guard let resourceValues = try? projectDir.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey]),
                  resourceValues.isDirectory == true,
                  resourceValues.isSymbolicLink != true else { continue }

            guard let files = try? fileManager.contentsOfDirectory(
                at: projectDir,
                includingPropertiesForKeys: [.isSymbolicLinkKey],
                options: [.skipsHiddenFiles]
            ) else { continue }

            for file in files {
                guard file.pathExtension == "jsonl" else { continue }
                if let rv = try? file.resourceValues(forKeys: [.isSymbolicLinkKey]), rv.isSymbolicLink == true {
                    continue
                }
                results.append(file.path)
            }
        }
        return results
    }

    /// `internal` rather than `private` so the transcript-parsing rules can
    /// be tested directly — the same reason `needsReparse` is internal. This
    /// is the app's core job (turning a Claude transcript into a session
    /// row) and was previously reachable only through the polling timer.
    func parseSession(atPath path: String, modDate: Date, now: Date) -> AgentSession? {
        guard let lines = readTailLines(atPath: path) else { return nil }

        var sessionId: String?
        var cwd: String?
        var slug: String?
        var lastMessage: String?
        var contextUsedPercent: Double?

        // Walk from the end to find the most recent metadata / message.
        for rawLine in lines.reversed() {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty else { continue }
            guard let data = line.data(using: .utf8) else { continue }
            guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { continue }

            if sessionId == nil, let sid = obj["sessionId"] as? String {
                sessionId = sid
            }
            if cwd == nil, let c = obj["cwd"] as? String {
                cwd = c
            }
            if slug == nil, let s = obj["slug"] as? String, !s.isEmpty {
                slug = s
            }

            if lastMessage == nil, (obj["type"] as? String) == "assistant" {
                if let message = obj["message"] as? [String: Any],
                   let content = message["content"] as? [[String: Any]] {
                    for item in content {
                        if let type = item["type"] as? String, type == "text",
                           let text = item["text"] as? String {
                            lastMessage = summarize(text: text)
                            break
                        } else if let type = item["type"] as? String, type == "tool_use",
                                  let name = item["name"] as? String {
                            lastMessage = "Running \(name)…"
                            break
                        }
                    }
                }
            }

            if contextUsedPercent == nil, (obj["type"] as? String) == "assistant" {
                if let message = obj["message"] as? [String: Any],
                   let usage = message["usage"] as? [String: Any] {
                    let inputTokens = (usage["input_tokens"] as? NSNumber)?.doubleValue ?? 0
                    let cacheCreation = (usage["cache_creation_input_tokens"] as? NSNumber)?.doubleValue ?? 0
                    let cacheRead = (usage["cache_read_input_tokens"] as? NSNumber)?.doubleValue ?? 0
                    let usedTokens = inputTokens + cacheCreation + cacheRead
                    if usedTokens > 0 {
                        let modelName = message["model"] as? String
                        let contextWindow = Self.contextWindowTokens(forModel: modelName)
                        contextUsedPercent = (usedTokens / contextWindow) * 100
                    }
                }
            }

            if sessionId != nil, cwd != nil, lastMessage != nil, contextUsedPercent != nil {
                break
            }
        }

        guard let sessionId, let cwd else { return nil }

        let fileStem = (path as NSString).lastPathComponent.replacingOccurrences(of: ".jsonl", with: "")
        let id = sessionId.isEmpty ? fileStem : sessionId

        let title: String
        if let slug, !slug.isEmpty, !looksLikeURLDerivedSlug(slug) {
            let spaced = slug.replacingOccurrences(of: "-", with: " ")
            title = String(spaced.prefix(40))
        } else {
            title = (cwd as NSString).lastPathComponent
        }

        let state: SessionState = now.timeIntervalSince(modDate) <= runningWindow ? .running : .idle

        return AgentSession(
            id: id,
            agent: .claude,
            title: title,
            cwd: cwd,
            lastActivity: modDate,
            state: state,
            lastMessage: lastMessage ?? "…",
            contextUsedPercent: contextUsedPercent
        )
    }

    /// Default context window (in tokens) for current Claude models when the
    /// exact figure can't be looked up. Models with an explicit extended
    /// ("1M") context variant in their name get the larger window; everything
    /// else falls back to the standard ~200k window.
    private static func contextWindowTokens(forModel model: String?) -> Double {
        guard let model = model?.lowercased() else { return 200_000 }
        if model.contains("1m") {
            return 1_000_000
        }
        return 200_000
    }

    /// Heuristically detects slugs that were derived from a URL (e.g. pasted link
    /// content) rather than a real session/topic name, so callers can fall back to
    /// the working directory for the title instead of showing an unreadable slug.
    private func looksLikeURLDerivedSlug(_ slug: String) -> Bool {
        if slug.hasPrefix("http-") || slug.hasPrefix("https-") {
            return true
        }
        let components = slug.split(separator: "-")
        if components.count >= 8 {
            return true
        }
        return false
    }

    private func summarize(text: String) -> String {
        let collapsed = text.replacingOccurrences(of: "\n", with: " ")
        return String(collapsed.prefix(80))
    }

    /// Reads the last `tailByteCount` bytes of the file and returns up to
    /// `maxTailLines` lines, split by newline, from the end.
    /// Internal (not `private`) so tests can exercise UTF-8 boundary handling directly.
    func readTailLines(atPath path: String) -> [String]? {
        TranscriptTailReading.readTailLines(atPath: path, tailByteCount: tailByteCount, maxTailLines: maxTailLines)
    }
}
