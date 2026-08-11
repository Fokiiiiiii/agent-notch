import XCTest
import Darwin
@testable import AgentNotch

/// Integration-level regression tests for the `SocketServer` connection-
/// lifecycle fix: `respond(json:)`/`closeWithoutResponse()` used to close a
/// connection's fd without cancelling its `DispatchSourceRead` or removing
/// it from `connections`, leaving a zombie entry that a later `accept()`
/// reusing the same fd number could collide with. These tests run against a
/// real, isolated AF_UNIX socket (never the production
/// `~/.agent-notch/run/agent-notch.sock`), so they can't interfere with a
/// live app or another concurrent Claude Code/Codex session on the same Mac.
@MainActor
final class SocketServerTests: XCTestCase {
    override class func setUp() {
        super.setUp()
        // Event delivery (`handleReadable`) hands events to `onEvent` via
        // `Task { @MainActor in ... }`, and this test's own `onEvent`
        // handlers call `SocketConnection.respond(json:)` synchronously
        // inside that closure — a raw `Darwin.write()` to a fd whose peer
        // already closed its read end (e.g. a prior test cycle's client
        // socket, torn down before the response landed) raises SIGPIPE,
        // which defaults to terminating the whole process. App.swift
        // ignores SIGPIPE once at real app startup (see its own comment),
        // but that startup code never runs in a bare `xctest` process, so
        // tests need the same protection explicitly.
        signal(SIGPIPE, SIG_IGN)
    }

    private func makeTempSocketPath() -> String {
        // Short and under /tmp on purpose — sockaddr_un.sun_path is capped
        // at 104 bytes on macOS; NSTemporaryDirectory()'s per-process
        // /var/folders/.../T/ prefix plus a UUID-based filename can exceed
        // that and make connect()/bind() fail or silently truncate.
        "/tmp/an-test-\(UUID().uuidString.prefix(8)).sock"
    }

    /// Connects a raw AF_UNIX client to `path`, retrying briefly since
    /// `SocketServer.start()` binds/listens asynchronously relative to the
    /// caller — there's no synchronous "ready" signal to wait on instead.
    private func connectClient(to path: String) -> Int32 {
        let fd = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let pathBytes = Array(path.utf8CString)
        withUnsafeMutableBytes(of: &addr.sun_path) { raw in
            let ptr = raw.bindMemory(to: CChar.self)
            for (i, b) in pathBytes.enumerated() { ptr[i] = b }
        }
        var connected = false
        for _ in 0..<50 {
            let result = withUnsafePointer(to: &addr) { ptr -> Int32 in
                ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockPtr in
                    Darwin.connect(fd, sockPtr, socklen_t(MemoryLayout<sockaddr_un>.size))
                }
            }
            if result == 0 {
                connected = true
                break
            }
            usleep(20_000) // 20ms — plain retry delay, no MainActor work pending here
        }
        XCTAssertTrue(connected, "failed to connect to test socket at \(path)")
        return fd
    }

    private func sendPing(on fd: Int32) {
        let json = "{\"payload\":{\"hook_event_name\":\"AgentNotchPing\"}}\n"
        _ = json.utf8CString.withUnsafeBufferPointer { buf in
            Darwin.write(fd, buf.baseAddress, buf.count - 1) // drop the trailing NUL byte
        }
    }

    /// Polls `debugConnectionCount()`, yielding via `Task.sleep` between
    /// checks — critical here, not cosmetic: `handleReadable` delivers
    /// every event (including this test's own `onEvent` handler, which
    /// calls `respond()`) through `Task { @MainActor in ... }`. Since this
    /// test class is `@MainActor`, a plain blocking wait (`usleep`, or even
    /// `RunLoop.current.run` in a bare `swift test` CLI process without a
    /// real app run loop) can starve that Task indefinitely, making a
    /// perfectly-working fix look like "the connection never detaches."
    /// `await Task.sleep` actually suspends this method and returns control
    /// to the cooperative scheduler, letting the pending MainActor work run.
    private func waitForConnectionCount(_ server: SocketServer, toEqual expected: Int, timeout: TimeInterval = 2.0) async {
        let deadline = Date().addingTimeInterval(timeout)
        while server.debugConnectionCount() != expected, Date() < deadline {
            try? await Task.sleep(nanoseconds: 5_000_000) // 5ms
        }
    }

    func testRespondRemovesConnectionFromTracking() async throws {
        let path = makeTempSocketPath()
        defer { Darwin.unlink(path) }
        let receivedEvent = expectation(description: "received AgentNotchPing event")
        let capturedConnection = LockedBox<SocketConnection?>(nil)

        let server = SocketServer(socketPath: path, onEvent: { event in
            capturedConnection.value = event.connection
            receivedEvent.fulfill()
        })
        defer { server.stop() } // torn down before `path` is unlinked (LIFO defer order)
        server.start()

        let clientFD = connectClient(to: path)
        defer { Darwin.close(clientFD) }
        sendPing(on: clientFD)

        await fulfillment(of: [receivedEvent], timeout: 2.0)

        let connection = try XCTUnwrap(capturedConnection.value, "AgentNotchPing must carry a connection so App.swift can reply")
        XCTAssertGreaterThan(server.debugConnectionCount(), 0, "connection should still be tracked while a response is pending")

        connection.respond(json: ["ok": true])

        // detach() runs asynchronously (onClose hops onto the server's
        // queue) — poll briefly rather than asserting immediately.
        await waitForConnectionCount(server, toEqual: 0)
        XCTAssertEqual(server.debugConnectionCount(), 0, "respond() must remove the connection from tracking, not just close its fd")
    }

    func testHighFrequencyPingCyclesNeverLeaveGhostEntries() async throws {
        // Regression case for the originally-observed symptom: frequent
        // AgentNotchPing traffic (e.g. CLI polling) each closing a
        // connection via a synchronous respond() without ever cancelling
        // its read source, accumulating zombie `connections` entries that a
        // later accept() reusing the same fd number could collide with.
        let path = makeTempSocketPath()
        defer { Darwin.unlink(path) }

        let server = SocketServer(socketPath: path, onEvent: { event in
            event.connection?.respond(json: ["ok": true])
        })
        defer { server.stop() } // torn down before `path` is unlinked (LIFO defer order)
        server.start()

        // Fire all 50 connect+ping cycles back-to-back (a small yield
        // between sends so the accept loop keeps up, not a per-cycle
        // convergence wait) — this actually exercises rapid connection
        // churn, unlike waiting for full teardown between each one. The
        // property under test is the *aggregate* one: high-frequency ping
        // traffic must not leave a monotonically growing set of ghost
        // entries, not that each individual cycle detaches within some
        // tight per-cycle latency bound (which is sensitive to scheduler
        // load when the full test suite runs together, not a meaningful
        // regression signal on its own).
        var clientFDs: [Int32] = []
        for _ in 0..<50 {
            let clientFD = connectClient(to: path)
            sendPing(on: clientFD)
            clientFDs.append(clientFD)
            try? await Task.sleep(nanoseconds: 2_000_000) // 2ms
        }

        await waitForConnectionCount(server, toEqual: 0, timeout: 10.0)
        XCTAssertEqual(server.debugConnectionCount(), 0, "high-frequency ping traffic left ghost connection entries")

        for fd in clientFDs {
            Darwin.close(fd)
        }
    }

    func testStopCancelsAcceptSourceAndClosesConnections() async throws {
        let path = makeTempSocketPath()
        defer { Darwin.unlink(path) }
        let receivedEvent = expectation(description: "received AgentNotchPing event")

        let server = SocketServer(socketPath: path, onEvent: { event in
            // Deliberately never respond — testing that stop() tears the
            // connection down even while a response is still pending,
            // not just the already-covered "respond() cleans up" path.
            receivedEvent.fulfill()
        })
        server.start()

        let clientFD = connectClient(to: path)
        defer { Darwin.close(clientFD) }
        sendPing(on: clientFD)
        await fulfillment(of: [receivedEvent], timeout: 2.0)
        XCTAssertGreaterThan(server.debugConnectionCount(), 0, "connection should be tracked before stop()")

        server.stop()
        XCTAssertEqual(server.debugConnectionCount(), 0, "stop() must synchronously clear every tracked connection")

        // The listening socket itself should be gone too: a fresh connect()
        // attempt must fail (nothing left accepting on this path). A fresh
        // fd is required on *every* attempt, not just the first: once an
        // AF_UNIX SOCK_STREAM fd successfully connect()s, reusing that same
        // fd for a second connect() always fails with EISCONN regardless of
        // whether the listener is still alive — reusing one fd across the
        // retry loop would make this assertion pass unconditionally (a
        // false negative that can't actually detect a regression where
        // stop() stops tearing the listener down).
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let pathBytes = Array(path.utf8CString)
        withUnsafeMutableBytes(of: &addr.sun_path) { raw in
            let ptr = raw.bindMemory(to: CChar.self)
            for (i, b) in pathBytes.enumerated() { ptr[i] = b }
        }
        // `connect()` on a Unix domain socket can briefly still succeed
        // against the kernel's backlog even after the listener stops
        // accepting, so poll a few times rather than asserting on the
        // first attempt alone.
        var stillConnectable = true
        for _ in 0..<10 {
            let attemptFD = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
            defer { Darwin.close(attemptFD) }
            let result = withUnsafePointer(to: &addr) { ptr -> Int32 in
                ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockPtr in
                    Darwin.connect(attemptFD, sockPtr, socklen_t(MemoryLayout<sockaddr_un>.size))
                }
            }
            if result != 0 {
                stillConnectable = false
                break
            }
            try? await Task.sleep(nanoseconds: 20_000_000) // 20ms
        }
        XCTAssertFalse(stillConnectable, "a new connect() should fail once stop() has torn down the listening socket")
    }

    /// `socket()`/`bind()`/`listen()` failures are hard to trigger
    /// deterministically without environment-dependent setup (racing
    /// another process for the same path, permission tricks). The
    /// path-too-long guard is the one startup failure this test suite can
    /// hit reliably and portably: `sockaddr_un.sun_path` is capped at 104
    /// bytes on macOS, and a path built from a long-enough string always
    /// exceeds it regardless of filesystem state.
    func testStartupFailureCallbackFiresOnceForOversizedSocketPath() {
        let oversizedPath = "/tmp/" + String(repeating: "a", count: 200) + ".sock"
        // The callback is `@Sendable` now, so a plain captured `var` can't be
        // mutated from it. A locked counter is the same assertion, expressed
        // in a way the concurrency checker can verify.
        let failures = LockedCounter()

        let server = SocketServer(
            socketPath: oversizedPath,
            onEvent: { _ in },
            onStartupFailure: { failures.increment() }
        )
        server.start()

        XCTAssertEqual(failures.value, 1, "onStartupFailure must fire exactly once when start() can't bind an oversized path")
    }
}

/// Minimal thread-safe counter for assertions made from `@Sendable`
/// callbacks that fire on the socket's own queues.
private final class LockedBox<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: Value

    init(_ value: Value) { stored = value }

    var value: Value {
        get { lock.lock(); defer { lock.unlock() }; return stored }
        set { lock.lock(); stored = newValue; lock.unlock() }
    }
}

private final class LockedCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0

    func increment() {
        lock.lock()
        count += 1
        lock.unlock()
    }

    var value: Int {
        lock.lock()
        defer { lock.unlock() }
        return count
    }
}
