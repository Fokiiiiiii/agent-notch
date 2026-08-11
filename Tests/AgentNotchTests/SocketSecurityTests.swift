import XCTest
@testable import AgentNotch

/// The socket is a control channel: whatever reaches it can raise approval
/// prompts and read back what the app answers. These pin the access controls
/// around it.
final class SocketSecurityTests: XCTestCase {
    private var directory: URL!
    private var socketPath: String!

    override func setUpWithError() throws {
        // A short path — `sockaddr_un.sun_path` is only 104 bytes, and the
        // default temp directory plus a UUID can approach that.
        directory = URL(fileURLWithPath: "/tmp").appendingPathComponent("an-sec-\(UUID().uuidString.prefix(8))")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        socketPath = directory.appendingPathComponent("s.sock").path
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    private func startServer() -> SocketServer {
        let server = SocketServer(socketPath: socketPath, onEvent: { _ in }, onCancel: { _ in })
        server.start()
        return server
    }

    // MARK: - File permissions

    /// The containing directory is 0700, but the socket's own mode used to
    /// be whatever `umask` produced (0755 in practice). A control channel
    /// shouldn't depend on a directory bit alone.
    func testSocketIsOwnerOnly() throws {
        let server = startServer()
        defer { server.stop() }

        let attributes = try FileManager.default.attributesOfItem(atPath: socketPath)
        let mode = try XCTUnwrap(attributes[.posixPermissions] as? NSNumber).uint16Value
        XCTAssertEqual(mode & 0o777, 0o600, "socket mode was \(String(mode & 0o777, radix: 8))")
    }

    /// Group and other must have no access at all — not merely no write.
    func testSocketDeniesGroupAndOther() throws {
        let server = startServer()
        defer { server.stop() }

        let attributes = try FileManager.default.attributesOfItem(atPath: socketPath)
        let mode = try XCTUnwrap(attributes[.posixPermissions] as? NSNumber).uint16Value
        XCTAssertEqual(mode & 0o077, 0, "group/other bits are set")
    }

    // MARK: - Peer identity

    /// Connections are accepted only from this user. Both ends of a
    /// socketpair are this process, so the check must pass here — a false
    /// negative would reject every legitimate hook.
    func testPeerFromSameUserIsAccepted() throws {
        var fds: [Int32] = [0, 0]
        XCTAssertEqual(socketpair(AF_UNIX, SOCK_STREAM, 0, &fds), 0)
        defer { Darwin.close(fds[0]); Darwin.close(fds[1]) }
        XCTAssertTrue(SocketServer.peerIsSameUser(fds[0]))
    }

    /// An fd with no peer credentials (a plain pipe, or one already closed)
    /// must be rejected rather than treated as trusted: failing to identify
    /// the peer is not a reason to accept it.
    func testUnidentifiablePeerIsRejected() throws {
        var fds: [Int32] = [0, 0]
        XCTAssertEqual(pipe(&fds), 0)
        defer { Darwin.close(fds[0]); Darwin.close(fds[1]) }
        XCTAssertFalse(SocketServer.peerIsSameUser(fds[0]), "a pipe has no peer identity to trust")
        XCTAssertFalse(SocketServer.peerIsSameUser(-1), "an invalid descriptor must not pass")
    }

    // MARK: - Instance takeover

    /// `start()` unlinks the path before binding, so without this guard a
    /// second process would silently take over the channel and receive every
    /// subsequent hook event.
    func testSecondServerRefusesToStealALiveSocket() throws {
        let first = startServer()
        defer { first.stop() }
        XCTAssertTrue(SocketServer.isSocketLive(at: socketPath))

        // `onStartupFailure` is `@Sendable`, so the counter has to be too.
        let failures = FailureCounter()
        let second = SocketServer(
            socketPath: socketPath,
            onEvent: { _ in },
            onCancel: { _ in },
            onStartupFailure: { failures.increment() }
        )
        second.start()
        defer { second.stop() }

        XCTAssertEqual(failures.value, 1, "the second instance must report a startup failure")
        // The original is still the one listening.
        XCTAssertTrue(SocketServer.isSocketLive(at: socketPath))
    }

    /// A socket file left behind by a crash is not a live listener, so
    /// startup must still clean it up and bind — otherwise the app would
    /// refuse to start after any hard quit.
    func testStaleSocketFileIsNotMistakenForALiveListener() throws {
        FileManager.default.createFile(atPath: socketPath, contents: Data())
        XCTAssertFalse(SocketServer.isSocketLive(at: socketPath))

        let server = startServer()
        defer { server.stop() }
        XCTAssertTrue(SocketServer.isSocketLive(at: socketPath), "should have replaced the stale file and bound")
    }

    func testMissingPathIsNotLive() {
        XCTAssertFalse(SocketServer.isSocketLive(at: directory.appendingPathComponent("nothing.sock").path))
    }
}

private final class FailureCounter: @unchecked Sendable {
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
