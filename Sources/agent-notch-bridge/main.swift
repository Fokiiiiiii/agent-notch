import Foundation
import Darwin

// Hooks bridge CLI: forwards a single hook stdin JSON event to the AgentNotch
// app over a Unix domain socket. For PermissionRequest events it blocks
// waiting for the app's allow/deny decision and prints it to stdout. Any
// failure along the way must exit 0 with no stdout, so Claude Code falls
// back to its normal prompt.
//
// `--codex '<json>'` mode: Codex's `notify` mechanism invokes the notify
// program with the event JSON as a single argv element (not stdin). That
// JSON is translated into a synthetic hook payload and sent fire-and-forget
// (no response is awaited, no stdout is ever produced, always exit 0).

private func fail() -> Never {
    exit(0)
}

private func readStdinToEOF() -> Data {
    var data = Data()
    while true {
        let chunk = FileHandle.standardInput.availableData
        if chunk.isEmpty { break }
        data.append(chunk)
    }
    return data
}

/// Opens a fresh connection to the app's Unix socket. Returns -1 on any
/// failure (never throws/exits, so callers can decide how to fail).
private func connectSocket() -> Int32 {
    let socketPath = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".agent-notch/run/agent-notch.sock", isDirectory: false)
        .path

    let fd = socket(AF_UNIX, SOCK_STREAM, 0)
    guard fd >= 0 else { return -1 }

    var addr = sockaddr_un()
    addr.sun_family = sa_family_t(AF_UNIX)
    let pathBytes = Array(socketPath.utf8CString) // includes trailing NUL
    guard pathBytes.count <= MemoryLayout.size(ofValue: addr.sun_path) else {
        Darwin.close(fd)
        return -1
    }
    withUnsafeMutableBytes(of: &addr.sun_path) { raw in
        let ptr = raw.bindMemory(to: CChar.self)
        for (i, b) in pathBytes.enumerated() {
            ptr[i] = b
        }
    }

    let connectResult = withUnsafePointer(to: &addr) { ptr -> Int32 in
        ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockPtr in
            connect(fd, sockPtr, socklen_t(MemoryLayout<sockaddr_un>.size))
        }
    }
    guard connectResult == 0 else {
        Darwin.close(fd)
        return -1
    }
    return fd
}

/// Writes a single NDJSON envelope line. Returns false on any failure.
private func writeEnvelope(_ payload: [String: Any], to fd: Int32) -> Bool {
    let envelope: [String: Any] = [
        "v": 1,
        "kind": "hook",
        "payload": payload,
    ]
    guard var envelopeData = try? JSONSerialization.data(withJSONObject: envelope) else {
        return false
    }
    envelopeData.append(0x0A)

    return envelopeData.withUnsafeBytes { raw in
        guard let base = raw.baseAddress else { return false }
        var totalWritten = 0
        while totalWritten < raw.count {
            let n = Darwin.write(fd, base + totalWritten, raw.count - totalWritten)
            if n <= 0 { return false }
            totalWritten += n
        }
        return true
    }
}

private func readResponseLine(from fd: Int32) -> Data? {
    var buffer = Data()
    while true {
        var byte: UInt8 = 0
        let n = Darwin.read(fd, &byte, 1)
        guard n > 0 else { return nil }
        if byte == 0x0A { return buffer }
        buffer.append(byte)
    }
}

private func cliExit(_ message: String, code: Int32 = 0) -> Never {
    let handle = code == 0 ? FileHandle.standardOutput : FileHandle.standardError
    handle.write(Data((message + "\n").utf8))
    exit(code)
}

private let cliHelp = """
AgentNotch CLI

  agent-notch ping
  agent-notch show | hide | toggle
  agent-notch setup [--all]
  agent-notch run --agent AGENT [--id ID] [--title TEXT] -- COMMAND [ARG...]
  agent-notch session <start|update|done|fail|attention|pause|remove>
      [--id ID] [--agent AGENT]
      [--title TEXT] [--message TEXT] [--cwd PATH]
"""

private func option(_ name: String, in arguments: [String]) -> String? {
    guard let index = arguments.firstIndex(of: name), arguments.indices.contains(index + 1) else { return nil }
    return arguments[index + 1]
}

private let supportedAgents = ["claude", "codex", "antigravity", "gemini", "copilot", "cursor", "opencode", "aider", "goose"]

private func sendCLIEvent(_ payload: [String: Any]) -> Bool {
    let fd = connectSocket()
    guard fd >= 0 else { return false }
    let sent = writeEnvelope(payload, to: fd)
    Darwin.close(fd)
    return sent
}

private func runSetup(arguments: [String]) -> Never {
    let script = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".agent-notch/bin/setup-integrations")
    guard FileManager.default.isExecutableFile(atPath: script.path) else {
        cliExit("agent-notch: setup helper is not installed", code: 1)
    }
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/bin/bash")
    process.arguments = [script.path] + arguments
    process.standardInput = FileHandle.standardInput
    process.standardOutput = FileHandle.standardOutput
    process.standardError = FileHandle.standardError
    do { try process.run() } catch { cliExit("agent-notch: setup failed: \(error.localizedDescription)", code: 1) }
    process.waitUntilExit()
    exit(process.terminationStatus)
}

private func runWrappedCommand(arguments: [String]) -> Never {
    guard let separator = arguments.firstIndex(of: "--"), arguments.indices.contains(separator + 1) else {
        cliExit("agent-notch: run requires -- COMMAND [ARG...]", code: 2)
    }
    let options = Array(arguments[..<separator])
    let command = Array(arguments[(separator + 1)...])
    let agent = option("--agent", in: options) ?? "claude"
    guard supportedAgents.contains(agent) else { cliExit("agent-notch: invalid agent: \(agent)", code: 2) }
    let cwd = FileManager.default.currentDirectoryPath
    let id = option("--id", in: options) ?? "\(agent)-\(UUID().uuidString.lowercased())"
    let title = option("--title", in: options) ?? command[0]

    func event(_ action: String, message: String) -> [String: Any] {
        [
            "hook_event_name": "AgentNotchSession",
            "session_id": id,
            "cwd": cwd,
            "tool_input": ["action": action, "agent": agent, "title": title, "message": message],
        ]
    }

    guard sendCLIEvent(event("start", message: "Running \(command[0])…")) else {
        cliExit("agent-notch: app is not running", code: 1)
    }

    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
    process.arguments = command
    process.standardInput = FileHandle.standardInput
    process.standardOutput = FileHandle.standardOutput
    process.standardError = FileHandle.standardError
    do {
        try process.run()
    } catch {
        _ = sendCLIEvent(event("fail", message: error.localizedDescription))
        cliExit("agent-notch: could not launch \(command[0]): \(error.localizedDescription)", code: 127)
    }
    process.waitUntilExit()
    let succeeded = process.terminationStatus == 0
    _ = sendCLIEvent(event(succeeded ? "done" : "fail", message: succeeded ? "Command completed" : "Exited with status \(process.terminationStatus)"))
    exit(process.terminationStatus)
}

private func runAgentHook(agent: String) -> Never {
    guard supportedAgents.contains(agent) else { fail() }
    let data = readStdinToEOF()
    guard let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { fail() }

    let rawEvent = (object["hook_event_name"] as? String)
        ?? (object["eventName"] as? String)
        ?? (object["type"] as? String)
        ?? "update"
    let lowerEvent = rawEvent.lowercased()
    let action: String
    if lowerEvent.contains("start") || lowerEvent == "session.created" {
        action = "start"
    } else if lowerEvent.contains("error") || lowerEvent.contains("fail") {
        action = "fail"
    } else if lowerEvent.contains("permission") || lowerEvent.contains("notification") {
        action = "attention"
    } else if lowerEvent.contains("end") || lowerEvent.contains("stop") || lowerEvent == "session.idle" || lowerEvent == "afteragent" {
        action = "done"
    } else {
        action = "update"
    }

    let nestedSession = object["session"] as? [String: Any]
    let sessionId = (object["session_id"] as? String)
        ?? (object["sessionId"] as? String)
        ?? (nestedSession?["id"] as? String)
        ?? "\(agent):\(FileManager.default.currentDirectoryPath)"
    let cwd = (object["cwd"] as? String) ?? FileManager.default.currentDirectoryPath
    let toolName = (object["tool_name"] as? String) ?? (object["toolName"] as? String)
    let message = (object["message"] as? String)
        ?? (object["notification_message"] as? String)
        ?? toolName.map { "Running \($0)…" }
        ?? rawEvent
    let title = URL(fileURLWithPath: cwd).lastPathComponent

    _ = sendCLIEvent([
        "hook_event_name": "AgentNotchSession",
        "session_id": sessionId,
        "cwd": cwd,
        "tool_input": ["action": action, "agent": agent, "title": title, "message": message],
    ])
    // Native hook hosts require valid, quiet JSON on stdout.
    cliExit("{}")
}

private func runCLI(arguments: [String]) -> Never {
    guard let command = arguments.first else { cliExit(cliHelp) }
    if command == "help" || command == "--help" || command == "-h" {
        cliExit(cliHelp)
    }
    if command == "setup" {
        runSetup(arguments: Array(arguments.dropFirst()))
    }
    if command == "run" {
        runWrappedCommand(arguments: Array(arguments.dropFirst()))
    }

    let payload: [String: Any]
    let waitsForResponse: Bool
    switch command {
    case "ping":
        payload = ["hook_event_name": "AgentNotchPing", "session_id": "cli", "cwd": FileManager.default.currentDirectoryPath]
        waitsForResponse = true
    case "show", "hide", "toggle":
        payload = ["hook_event_name": "AgentNotch\(command.capitalized)", "session_id": "cli", "cwd": FileManager.default.currentDirectoryPath]
        waitsForResponse = false
    case "session":
        guard arguments.count >= 2 else { cliExit("agent-notch: missing session action", code: 2) }
        let action = arguments[1]
        let allowedActions = ["start", "update", "done", "fail", "attention", "pause", "remove"]
        guard allowedActions.contains(action) else { cliExit("agent-notch: invalid session action: \(action)", code: 2) }
        let agent = option("--agent", in: arguments) ?? "claude"
        guard supportedAgents.contains(agent) else {
            cliExit("agent-notch: invalid agent: \(agent)", code: 2)
        }
        let cwd = option("--cwd", in: arguments) ?? FileManager.default.currentDirectoryPath
        let id = option("--id", in: arguments) ?? "\(agent):\(cwd)"
        var input: [String: Any] = ["action": action, "agent": agent]
        if let title = option("--title", in: arguments) { input["title"] = title }
        if let message = option("--message", in: arguments) { input["message"] = message }
        payload = [
            "hook_event_name": "AgentNotchSession",
            "session_id": id,
            "cwd": cwd,
            "tool_input": input,
        ]
        waitsForResponse = false
    default:
        cliExit("agent-notch: unknown command: \(command)\n\n\(cliHelp)", code: 2)
    }

    let fd = connectSocket()
    guard fd >= 0 else { cliExit("agent-notch: app is not running", code: 1) }
    guard writeEnvelope(payload, to: fd) else {
        Darwin.close(fd)
        cliExit("agent-notch: failed to send event", code: 1)
    }

    if waitsForResponse {
        guard let data = readResponseLine(from: fd), let response = String(data: data, encoding: .utf8) else {
            Darwin.close(fd)
            cliExit("agent-notch: app disconnected", code: 1)
        }
        Darwin.close(fd)
        cliExit(response)
    }

    Darwin.close(fd)
    cliExit("ok")
}

let executableName = URL(fileURLWithPath: CommandLine.arguments[0]).lastPathComponent
if executableName == "agent-notch" {
    runCLI(arguments: Array(CommandLine.arguments.dropFirst()))
}
if CommandLine.arguments.count >= 2, CommandLine.arguments[1] == "--cli" {
    runCLI(arguments: Array(CommandLine.arguments.dropFirst(2)))
}
if CommandLine.arguments.count >= 3, CommandLine.arguments[1] == "--agent-hook" {
    runAgentHook(agent: CommandLine.arguments[2])
}

// MARK: - Codex notify mode

/// `--codex '<json>'`: Codex passes the notify event JSON as argv, not
/// stdin. Fields observed in Codex's notify payloads include `type`
/// (e.g. "agent-turn-complete"), `turn-id`, `thread-id`, and `cwd`.
if CommandLine.arguments.count >= 3, CommandLine.arguments[1] == "--codex" {
    let jsonArg = CommandLine.arguments[2]
    guard let jsonData = jsonArg.data(using: .utf8),
          let codexObject = (try? JSONSerialization.jsonObject(with: jsonData)) as? [String: Any]
    else {
        fail()
    }

    let sessionId = (codexObject["thread-id"] as? String)
        ?? (codexObject["turn-id"] as? String)
        ?? ""
    let cwd = (codexObject["cwd"] as? String) ?? ""

    let payload: [String: Any] = [
        "hook_event_name": "CodexTurnComplete",
        "session_id": sessionId,
        "cwd": cwd,
    ]

    let fd = connectSocket()
    guard fd >= 0 else { fail() }
    _ = writeEnvelope(payload, to: fd)
    // Fire-and-forget: no response is awaited from the app.
    Darwin.close(fd)
    exit(0)
}

let inputData = readStdinToEOF()
guard !inputData.isEmpty,
      let hookObject = (try? JSONSerialization.jsonObject(with: inputData)) as? [String: Any]
else {
    fail()
}

let eventName = (hookObject["hook_event_name"] as? String) ?? "Unknown"

let fd = connectSocket()
guard fd >= 0 else { fail() }

guard writeEnvelope(hookObject, to: fd) else {
    Darwin.close(fd)
    fail()
}

guard eventName == "PermissionRequest" else {
    Darwin.close(fd)
    fail()
}

// Block (no timeout) waiting for exactly one NDJSON response line.
guard let responseBuffer = readResponseLine(from: fd) else {
    Darwin.close(fd)
    fail()
}
Darwin.close(fd)

guard let responseObj = (try? JSONSerialization.jsonObject(with: responseBuffer)) as? [String: Any],
      let behavior = responseObj["behavior"] as? String,
      behavior == "allow" || behavior == "deny"
else {
    fail()
}

let output: [String: Any] = [
    "hookSpecificOutput": [
        "hookEventName": "PermissionRequest",
        "decision": [
            "behavior": behavior,
        ],
    ],
]

if let outData = try? JSONSerialization.data(withJSONObject: output),
   let outStr = String(data: outData, encoding: .utf8) {
    print(outStr)
}
exit(0)
