import Foundation
import Darwin

/// A single parsed hook event received from the bridge CLI.
struct HookEvent {
    let eventName: String
    let sessionId: String
    let cwd: String
    let toolName: String?
    let toolInput: [String: Any]
    /// Non-nil for blocking PermissionRequest and AskUserQuestion events.
    let connection: SocketConnection?
}

/// Wraps an accepted client file descriptor. Blocking approval and question
/// hooks keep it open until the user responds in the notch.
final class SocketConnection {
    private let fd: Int32
    private let lock = NSLock()
    private var isClosed = false

    init(fd: Int32) {
        self.fd = fd
    }

    /// Writes `{"behavior":"allow"|"deny"}\n` and closes the connection.
    func respond(behavior: String) {
        respond(json: ["behavior": behavior])
    }

    func respond(json: [String: Any]) {
        lock.lock()
        defer { lock.unlock() }
        guard !isClosed else { return }
        isClosed = true
        guard var data = try? JSONSerialization.data(withJSONObject: json) else {
            Darwin.close(fd)
            return
        }
        data.append(0x0A)
        _ = data.withUnsafeBytes { raw -> Int in
            guard let base = raw.baseAddress else { return 0 }
            var written = 0
            while written < raw.count {
                let n = Darwin.write(fd, base + written, raw.count - written)
                if n <= 0 { break }
                written += n
            }
            return written
        }
        Darwin.close(fd)
    }

    /// Closes without writing a response (used for non-blocking events).
    func closeWithoutResponse() {
        lock.lock()
        defer { lock.unlock() }
        guard !isClosed else { return }
        isClosed = true
        Darwin.close(fd)
    }
}

/// Upper bound on bytes buffered per connection before the client is
/// treated as malformed/malicious and disconnected. Legitimate NDJSON hook
/// envelopes are a few KB at most; 1 MiB gives generous headroom without
/// letting an unbounded client grow memory indefinitely.
private let maxIncomingBufferBytes = 1 * 1024 * 1024

/// Per-connection read state. Only touched from `queue`.
private final class IncomingConnection {
    let fd: Int32
    let connection: SocketConnection
    var buffer = Data()
    var source: DispatchSourceRead?
    var eventDelivered = false

    init(fd: Int32) {
        self.fd = fd
        self.connection = SocketConnection(fd: fd)
    }
}

/// Listens on `~/.agent-notch/run/agent-notch.sock` for NDJSON hook events
/// forwarded by the bridge CLI. Implemented with raw BSD sockets + GCD
/// (Network.framework's AF_UNIX support is unreliable for this use case).
@MainActor
final class SocketServer {
    private let onEvent: (HookEvent) -> Void
    private let onCancel: (SocketConnection) -> Void

    private let queue = DispatchQueue(label: "com.chaos.agent-notch.socket")
    private let socketPath: String

    // Only ever touched from `queue`.
    nonisolated(unsafe) private var listenFD: Int32 = -1
    nonisolated(unsafe) private var acceptSource: DispatchSourceRead?
    nonisolated(unsafe) private var connections: [Int32: IncomingConnection] = [:]

    init(onEvent: @escaping (HookEvent) -> Void, onCancel: @escaping (SocketConnection) -> Void = { _ in }) {
        self.onEvent = onEvent
        self.onCancel = onCancel
        let dir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".agent-notch/run", isDirectory: true)
        self.socketPath = dir.appendingPathComponent("agent-notch.sock").path
    }

    func start() {
        let fm = FileManager.default
        let dirPath = (socketPath as NSString).deletingLastPathComponent
        try? fm.createDirectory(atPath: dirPath, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try? fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: dirPath)

        unlink(socketPath)

        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else {
            logError("socket() failed")
            return
        }

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let pathBytes = Array(socketPath.utf8CString)
        guard pathBytes.count <= MemoryLayout.size(ofValue: addr.sun_path) else {
            logError("socket path too long")
            Darwin.close(fd)
            return
        }
        withUnsafeMutableBytes(of: &addr.sun_path) { raw in
            let ptr = raw.bindMemory(to: CChar.self)
            for (i, b) in pathBytes.enumerated() {
                ptr[i] = b
            }
        }

        let bindResult = withUnsafePointer(to: &addr) { ptr -> Int32 in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockPtr in
                bind(fd, sockPtr, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard bindResult == 0 else {
            logError("bind() failed")
            Darwin.close(fd)
            return
        }

        guard listen(fd, 16) == 0 else {
            logError("listen() failed")
            Darwin.close(fd)
            return
        }

        // Non-blocking accept: the accept loop drains until EWOULDBLOCK.
        // A blocking listen socket would wedge the serial queue on the
        // second accept() call and starve every per-connection read source.
        let flags = fcntl(fd, F_GETFL, 0)
        _ = fcntl(fd, F_SETFL, flags | O_NONBLOCK)

        self.listenFD = fd

        let deliverEvent = onEvent
        let deliverCancel = onCancel
        let workQueue = queue

        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        source.setEventHandler { [weak self] in
            self?.acceptLoop(deliverEvent: deliverEvent, deliverCancel: deliverCancel, workQueue: workQueue)
        }
        source.setCancelHandler {
            Darwin.close(fd)
        }
        source.resume()
        self.acceptSource = source
    }

    /// Runs on `queue`. Accepts every pending connection and wires up a
    /// per-connection read source.
    nonisolated private func acceptLoop(
        deliverEvent: @escaping (HookEvent) -> Void,
        deliverCancel: @escaping (SocketConnection) -> Void,
        workQueue: DispatchQueue
    ) {
        while true {
            let clientFD = accept(listenFD, nil, nil)
            guard clientFD >= 0 else { return }
            let incoming = IncomingConnection(fd: clientFD)
            connections[clientFD] = incoming

            let readSource = DispatchSource.makeReadSource(fileDescriptor: clientFD, queue: workQueue)
            readSource.setEventHandler { [weak self] in
                self?.handleReadable(incoming, deliverEvent: deliverEvent, deliverCancel: deliverCancel)
            }
            readSource.setCancelHandler { [weak self] in
                self?.connections.removeValue(forKey: clientFD)
            }
            incoming.source = readSource
            readSource.resume()
        }
    }

    /// Runs on `queue`.
    nonisolated private func handleReadable(
        _ incoming: IncomingConnection,
        deliverEvent: @escaping (HookEvent) -> Void,
        deliverCancel: @escaping (SocketConnection) -> Void
    ) {
        var chunk = [UInt8](repeating: 0, count: 4096)
        let n = chunk.withUnsafeMutableBytes { raw -> Int in
            Darwin.read(incoming.fd, raw.baseAddress, raw.count)
        }

        if n < 0, errno == EAGAIN || errno == EWOULDBLOCK || errno == EINTR {
            return
        }

        if n <= 0 {
            // EOF or a terminal socket error: client disconnected.
            incoming.source?.cancel()
            if incoming.eventDelivered {
                Task { @MainActor in
                    deliverCancel(incoming.connection)
                }
            } else {
                incoming.connection.closeWithoutResponse()
            }
            return
        }

        incoming.buffer.append(contentsOf: chunk[0..<n])

        if incoming.buffer.count > maxIncomingBufferBytes {
            // Client sent more than a well-formed hook envelope ever should
            // without a newline: treat it as malformed/malicious and drop it.
            incoming.source?.cancel()
            incoming.connection.closeWithoutResponse()
            return
        }

        guard !incoming.eventDelivered, let newlineIndex = incoming.buffer.firstIndex(of: 0x0A) else {
            return
        }

        let lineData = incoming.buffer[incoming.buffer.startIndex..<newlineIndex]
        incoming.eventDelivered = true

        guard let event = Self.parseEvent(lineData, connection: incoming.connection) else {
            incoming.source?.cancel()
            incoming.connection.closeWithoutResponse()
            return
        }

        if event.connection != nil {
            // Keep the read source alive: it now watches for an unexpected
            // client disconnect while the app awaits Allow/Deny.
        } else {
            incoming.source?.cancel()
            incoming.connection.closeWithoutResponse()
        }

        Task { @MainActor in
            deliverEvent(event)
        }
    }

    nonisolated private static func parseEvent(_ lineData: Data, connection: SocketConnection) -> HookEvent? {
        guard let envelope = (try? JSONSerialization.jsonObject(with: lineData)) as? [String: Any],
              let payload = envelope["payload"] as? [String: Any]
        else {
            return nil
        }

        let eventName = (payload["hook_event_name"] as? String) ?? "Unknown"
        let sessionId = (payload["session_id"] as? String) ?? ""
        let cwd = (payload["cwd"] as? String) ?? ""
        let toolName = payload["tool_name"] as? String
        var toolInput = (payload["tool_input"] as? [String: Any]) ?? [:]
        if let message = payload["message"] as? String { toolInput["message"] = message }
        if let type = payload["notification_type"] as? String { toolInput["notification_type"] = type }
        let isQuestion = eventName == "PreToolUse"
            && (toolName == "AskUserQuestion" || toolName == "request_user_input")
        let isAgentNotchQuestion = eventName == "AgentNotchQuestion"
        let isPlanReview = eventName == "AgentNotchPlanReview"

        return HookEvent(
            eventName: eventName,
            sessionId: sessionId,
            cwd: cwd,
            toolName: toolName,
            toolInput: toolInput,
            connection: eventName == "PermissionRequest" || eventName == "AgentNotchPing" || isQuestion || isAgentNotchQuestion || isPlanReview ? connection : nil
        )
    }

    private func logError(_ message: String) {
        FileHandle.standardError.write("agent-notch: \(message)\n".data(using: .utf8)!)
    }
}
