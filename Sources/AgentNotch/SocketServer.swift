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
    private var onClose: (() -> Void)?

    init(fd: Int32) {
        self.fd = fd
    }

    /// Registers a callback fired exactly once, the moment
    /// `respond(json:)`/`respond(behavior:)` or `closeWithoutResponse()`
    /// first decides this connection is done — whichever happens first.
    /// Registering a callback also delegates fd ownership to the caller
    /// (see `closeOrDelegate`): from this point on, `SocketConnection`
    /// itself never calls `Darwin.close(fd)`; it trusts the callback to
    /// arrange that. `SocketServer` wires this (see `acceptLoop`) to cancel
    /// the connection's `DispatchSourceRead`, whose cancel handler both
    /// performs the actual `Darwin.close(fd)` and drops the entry from
    /// `connections`, in that order — see `SocketServer.detach(_:)`'s doc
    /// comment for why the ordering matters. Left `nil` (a safe no-op, fd
    /// ownership stays here) by callers that construct a `SocketConnection`
    /// directly, e.g. tests' `SocketConnection(fd: -1)` fakes.
    func setOnClose(_ callback: @escaping () -> Void) {
        lock.lock()
        onClose = callback
        lock.unlock()
    }

    /// Writes `{"behavior":"allow"|"deny"}\n` and closes the connection.
    func respond(behavior: String) {
        respond(json: ["behavior": behavior])
    }

    func respond(json: [String: Any]) {
        lock.lock()
        guard !isClosed else {
            lock.unlock()
            return
        }
        isClosed = true
        let callback = onClose
        lock.unlock()

        guard var data = try? JSONSerialization.data(withJSONObject: json) else {
            closeOrDelegate(callback)
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
        closeOrDelegate(callback)
    }

    /// Closes without writing a response (used for non-blocking events).
    func closeWithoutResponse() {
        lock.lock()
        guard !isClosed else {
            lock.unlock()
            return
        }
        isClosed = true
        let callback = onClose
        lock.unlock()

        closeOrDelegate(callback)
    }

    /// When a close callback is registered (production: `SocketServer`'s
    /// `acceptLoop`), fd ownership has been delegated to the caller of
    /// `setOnClose` — this method must NOT close `fd` itself. Closing here
    /// directly, before the matching `DispatchSourceRead` is cancelled,
    /// would free the descriptor number for the kernel to hand back to a
    /// brand-new `accept()` while that still-live read source keeps
    /// watching the same number (a window that used to be effectively
    /// unbounded before `setOnClose` existed, and would otherwise still be
    /// one async hop wide even with it). Instead, only `callback()` runs —
    /// which cancels the read source — and its cancel handler (see
    /// `acceptLoop`) performs `Darwin.close(fd)` only once GCD has fully
    /// unregistered the descriptor from the queue, closing that window to
    /// zero. Callers that never register a callback (e.g. tests' bare
    /// `SocketConnection(fd: -1)` fakes) keep the original close-it-here
    /// behavior.
    private func closeOrDelegate(_ callback: (() -> Void)?) {
        if let callback {
            callback()
        } else {
            Darwin.close(fd)
        }
    }
}

/// Upper bound on bytes buffered per connection before the client is
/// treated as malformed/malicious and disconnected. Legitimate NDJSON hook
/// envelopes are a few KB at most; 1 MiB gives generous headroom without
/// letting an unbounded client grow memory indefinitely.
private let maxIncomingBufferBytes = 1 * 1024 * 1024

/// Per-connection read state. Only touched from `queue` — mirrors
/// `SocketServer.connections`' own `nonisolated(unsafe)` discipline (single-
/// queue confinement, not compiler-checked isolation). `@unchecked Sendable`
/// silences the warning `SocketConnection.setOnClose`'s callback (see
/// `acceptLoop`) triggers by capturing an `IncomingConnection` across a
/// `workQueue.async` boundary — it is not required for the code to compile
/// under this package's Swift 5 language mode, but the annotation's claim is
/// still true and worth asserting explicitly: every access to this class's
/// *mutable* state (`buffer`/`source`/`eventDelivered`) happens on `queue`
/// (`acceptLoop`, `handleReadable`, `detach`, and the read source's cancel
/// handler all run there); `fd`/`connection` are `let` and read from
/// off-queue code (e.g. `Task { @MainActor in ... }` in `handleReadable`)
/// safely regardless.
private final class IncomingConnection: @unchecked Sendable {
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
    private let onStartupFailure: (() -> Void)?

    private let queue = DispatchQueue(label: "com.chaos.agent-notch.socket")
    private let socketPath: String

    // Only ever touched from `queue`.
    nonisolated(unsafe) private var listenFD: Int32 = -1
    nonisolated(unsafe) private var acceptSource: DispatchSourceRead?
    nonisolated(unsafe) private var connections: [Int32: IncomingConnection] = [:]

    /// `socketPath`: `nil` (the production default) uses the real
    /// `~/.agent-notch/run/agent-notch.sock`; tests pass an isolated
    /// temporary path so they never touch the real socket a live app (or
    /// other concurrent Claude Code/Codex sessions on the same Mac) might
    /// be using.
    init(socketPath: String? = nil, onEvent: @escaping (HookEvent) -> Void, onCancel: @escaping (SocketConnection) -> Void = { _ in }, onStartupFailure: (() -> Void)? = nil) {
        self.onEvent = onEvent
        self.onCancel = onCancel
        self.onStartupFailure = onStartupFailure
        if let socketPath {
            self.socketPath = socketPath
        } else {
            let dir = FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent(".agent-notch/run", isDirectory: true)
            self.socketPath = dir.appendingPathComponent("agent-notch.sock").path
        }
    }

    /// Test-only: the number of currently-tracked connections, read safely
    /// from any thread by hopping onto `queue`. Not called by any
    /// production code path — exists so tests can prove `detach(_:)` really
    /// removes an entry instead of just trusting that it compiles. Must NOT
    /// be called from `queue` itself (e.g. from inside `detach(_:)` or a
    /// read source's event/cancel handler) — `queue.sync` from the queue it
    /// targets is a guaranteed deadlock. Always safe from `@MainActor`,
    /// which is the only caller today (`SocketServerTests`).
    func debugConnectionCount() -> Int {
        queue.sync { connections.count }
    }

    /// Cancels the listening socket's accept source and every open
    /// connection's read source. Not called by production code today — the
    /// real app is a menu-bar-resident process with no shutdown moment, so
    /// `acceptSource`'s existing `setCancelHandler { Darwin.close(fd) }`
    /// (see `start()`) would otherwise never actually fire. Exists so
    /// `SocketServerTests` can deterministically tear a server down between
    /// test methods instead of leaking listener/read sources for the life
    /// of the `xctest` process. `queue.sync` (not `.async`) so the caller
    /// can rely on teardown having fully happened by the time this returns
    /// — same pattern as `debugConnectionCount()`; do not call this from
    /// `queue` itself for the same deadlock reason.
    func stop() {
        queue.sync {
            acceptSource?.cancel()
            acceptSource = nil
            for incoming in connections.values {
                incoming.source?.cancel()
                incoming.source = nil
            }
            connections.removeAll()
        }
    }

    func start() {
        let fm = FileManager.default
        let dirPath = (socketPath as NSString).deletingLastPathComponent
        try? fm.createDirectory(atPath: dirPath, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try? fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: dirPath)

        unlink(socketPath)

        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else {
            failStartup("socket() failed")
            return
        }

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let pathBytes = Array(socketPath.utf8CString)
        guard pathBytes.count <= MemoryLayout.size(ofValue: addr.sun_path) else {
            failStartup("socket path too long")
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
            failStartup("bind() failed")
            Darwin.close(fd)
            return
        }

        guard listen(fd, 16) == 0 else {
            failStartup("listen() failed")
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
            readSource.setCancelHandler { [weak self, weak incoming] in
                // `SocketConnection.closeOrDelegate` intentionally does NOT
                // close `fd` itself once a close callback is registered
                // (see its doc comment) — fd ownership lives here instead,
                // so the close only happens after GCD has fully
                // unregistered `clientFD` from `queue`. This is what
                // eliminates the window where the kernel could recycle the
                // descriptor number into a brand-new `accept()` while this
                // read source might still be live and watching it.
                Darwin.close(clientFD)
                // Identity-checked, like `detach(_:)` — by the time GCD
                // actually runs this (asynchronously, some time after
                // `.cancel()`), the fd may already have been recycled by a
                // newer `accept()` occupying this same dictionary slot.
                // Only remove the entry if it's still genuinely this
                // connection's.
                guard let self, let incoming, self.connections[clientFD] === incoming else { return }
                self.connections.removeValue(forKey: clientFD)
            }
            incoming.source = readSource

            // Fires the moment this connection's SocketConnection closes
            // its fd — from any thread, e.g. a MainActor button action
            // resolving a pending permission, or App.swift's synchronous
            // AgentNotchPing reply. Cancels the matching read source and
            // drops it from `connections` in lockstep, instead of leaving
            // a zombie source registered on a descriptor number the kernel
            // is now free to hand back to a brand-new `accept()` — see
            // `detach(_:)`. Both captures are weak: `incoming`'s only
            // strong owners are `connections[clientFD]` and (until
            // cancelled) its own read source's handler closures; a strong
            // capture here would keep both it and this very
            // `SocketConnection` alive forever.
            incoming.connection.setOnClose { [weak self, weak incoming] in
                guard let self, let incoming else { return }
                workQueue.async {
                    self.detach(incoming)
                }
            }

            readSource.resume()
        }
    }

    /// Cancels `incoming`'s read source (if not already cancelled) and
    /// drops it from `connections` if it's still that fd's current
    /// occupant. Must run on `queue`. The single choke point for tearing
    /// down a connection's server-side bookkeeping: both the EOF/malformed-
    /// input branches in `handleReadable` (already running on `queue`) and
    /// `SocketConnection`'s close callback (fired from `respond`/
    /// `closeWithoutResponse`, which always hops onto `queue` first — see
    /// `acceptLoop`) funnel through it. Idempotent — safe to call more than
    /// once for the same connection, and safe even if the fd has since been
    /// recycled by a newer `accept()` (the identity check below leaves that
    /// newer connection's dictionary entry untouched).
    nonisolated private func detach(_ incoming: IncomingConnection) {
        if let source = incoming.source {
            incoming.source = nil
            source.cancel()
        }
        if connections[incoming.fd] === incoming {
            connections.removeValue(forKey: incoming.fd)
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
            detach(incoming)
            if incoming.eventDelivered {
                // The client (bridge process) went away before the user
                // responded — e.g. the hook's own timeout killed it. Tell
                // the relevant Center to drop this from its queue, *and*
                // close the fd (safe/idempotent via `isClosed`): previously
                // only the Center-side removal happened here, leaking the
                // fd forever on every early disconnect of this kind.
                incoming.connection.closeWithoutResponse()
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
            detach(incoming)
            incoming.connection.closeWithoutResponse()
            return
        }

        guard !incoming.eventDelivered, let newlineIndex = incoming.buffer.firstIndex(of: 0x0A) else {
            return
        }

        let lineData = incoming.buffer[incoming.buffer.startIndex..<newlineIndex]
        incoming.eventDelivered = true

        guard let event = Self.parseEvent(lineData, connection: incoming.connection) else {
            detach(incoming)
            incoming.connection.closeWithoutResponse()
            return
        }

        if event.connection != nil {
            // Keep the read source alive: it now watches for an unexpected
            // client disconnect while the app awaits a response — either an
            // async user decision (PermissionRequest/question/plan review),
            // or, for AgentNotchPing, the synchronous reply App.swift writes
            // moments from now on the main actor. Either way this window is
            // bounded and self-cleaning: `SocketConnection.setOnClose`
            // (wired in `acceptLoop`) guarantees `detach(_:)` runs the
            // instant `respond`/`closeWithoutResponse` closes this fd, so
            // even high-frequency pings never leave a lingering entry.
        } else {
            detach(incoming)
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

    /// Common failure path for every early-return in `start()`. Previously
    /// these four cases (`socket()`, path-too-long, `bind()`, `listen()`)
    /// only ever wrote to stderr — invisible in a GUI app the user launched
    /// via Finder/Login Items, so a bind conflict (e.g. another AgentNotch
    /// process already holding the socket) left the app looking like it
    /// started fine while silently never receiving a single hook event.
    /// `onStartupFailure` is best-effort notification only, same policy as
    /// `NativeNotifier` itself — no retry, no fallback transport.
    private func failStartup(_ message: String) {
        logError(message)
        onStartupFailure?()
    }
}
