import XCTest
@testable import logiminus

final class IPCTests: XCTestCase {
    private var path = ""
    private let queue = DispatchQueue(label: "test.handler")

    override func setUp() {
        // sun_path is limited to 104 bytes, so keep it short.
        path = "/tmp/logiminus-test-\(getpid())-\(UInt32.random(in: 0...UInt32.max)).sock"
    }

    override func tearDown() { unlink(path) }

    private func server(_ handler: @escaping (String) -> String = { "echo \($0)" }) throws -> IPC.Server {
        let s = IPC.Server(path: path, handlerQueue: queue, handler: handler)
        try s.start()
        return s
    }

    func testRoundTrip() throws {
        let s = try server()
        defer { s.stop() }
        XCTAssertEqual(IPC.send("status", path: path), "echo status")
        XCTAssertEqual(IPC.send("ping", path: path), "pong")
    }

    func testNoAgentReturnsNil() {
        XCTAssertNil(IPC.send("status", path: path, timeout: 1))
    }

    /// A client that leaves before the reply must not kill the process with SIGPIPE.
    func testClientDisconnectingEarlyDoesNotCrash() throws {
        let s = try server { cmd in usleep(300_000); return String(repeating: "x", count: 200_000) }
        defer { s.stop() }
        let fd = rawConnect()
        _ = "status\n".withCString { write(fd, $0, strlen($0)) }
        close(fd)
        usleep(600_000)
        XCTAssertEqual(IPC.send("ping", path: path), "pong")   // still alive
    }

    /// An idle client must not block other clients.
    func testIdleClientDoesNotBlockOthers() throws {
        let s = try server()
        defer { s.stop() }
        let idle = rawConnect()
        defer { close(idle) }
        let start = Date()
        XCTAssertEqual(IPC.send("status", path: path, timeout: 3), "echo status")
        XCTAssertLessThan(Date().timeIntervalSince(start), 1)
    }

    func testOverlongCommandIsRejected() throws {
        let s = try server()
        defer { s.stop() }
        let reply = IPC.send(String(repeating: "a", count: 5000), path: path)
        XCTAssertEqual(reply, "error: command too long")
    }

    func testSecondServerRefusesAndKeepsFirstSocket() throws {
        let first = try server { _ in "first" }
        defer { first.stop() }
        let second = IPC.Server(path: path, handlerQueue: queue) { _ in "second" }
        XCTAssertThrowsError(try second.start()) { error in
            guard case IPC.ServerError.alreadyRunning = error else { return XCTFail("\(error)") }
        }
        second.stop()   // must not remove the first server's socket
        XCTAssertEqual(IPC.send("x", path: path), "first")
    }

    func testStaleSocketIsReplaced() throws {
        // A leftover socket file from a crashed agent (nobody listening).
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        var addr = IPC.address(path)
        _ = withUnsafePointer(to: &addr) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) } }
        close(fd)
        let s = try server()
        defer { s.stop() }
        XCTAssertEqual(IPC.send("ping", path: path), "pong")
    }

    private func rawConnect() -> Int32 {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        var addr = IPC.address(path)
        let r = withUnsafePointer(to: &addr) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) } }
        XCTAssertEqual(r, 0)
        return fd
    }
}
