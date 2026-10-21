import Foundation

/// Line-based control protocol over a Unix socket: the CLI writes one command
/// line, the agent answers with one line and closes the connection.
enum IPC {
    static let maxCommandLength = 1024
    static let clientTimeout: TimeInterval = 2

    static var defaultSocketPath: String {
        let dir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Logiminus", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("control.sock").path
    }

    static func address(_ path: String) -> sockaddr_un {
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        withUnsafeMutableBytes(of: &addr.sun_path) { buf in
            path.utf8CString.withUnsafeBytes { src in buf.copyMemory(from: UnsafeRawBufferPointer(rebasing: src.prefix(buf.count - 1))) }
        }
        return addr
    }

    /// Socket options shared by both ends: no SIGPIPE on a vanished peer, bounded reads.
    private static func prepare(_ fd: Int32, timeout: TimeInterval) {
        var on: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
        var tv = timeval(tv_sec: Int(timeout), tv_usec: Int32((timeout - timeout.rounded(.down)) * 1_000_000))
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
    }

    private static func writeAll(_ fd: Int32, _ s: String) -> Bool {
        var bytes = Array(s.utf8)[...]
        while !bytes.isEmpty {
            let n = bytes.withUnsafeBytes { write(fd, $0.baseAddress, $0.count) }
            if n <= 0 { return false }
            bytes = bytes.dropFirst(n)
        }
        return true
    }

    /// Sends a command to a running agent. Returns nil when no agent is listening.
    static func send(_ command: String, path: String = defaultSocketPath, timeout: TimeInterval = 5) -> String? {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return nil }
        defer { close(fd) }
        prepare(fd, timeout: timeout)
        var addr = address(path)
        let ok = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        guard ok == 0, writeAll(fd, command + "\n") else { return nil }
        var out = Data()
        var buf = [UInt8](repeating: 0, count: 4096)
        while true {
            let n = read(fd, &buf, buf.count)
            if n <= 0 { break }
            out.append(contentsOf: buf[0..<n])
        }
        return String(decoding: out, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    enum ServerError: Error { case alreadyRunning, socket(Int32) }

    final class Server {
        let path: String
        private var fd: Int32 = -1
        private var inode: ino_t = 0
        private var source: DispatchSourceRead?
        private let acceptQueue = DispatchQueue(label: "logiminus.ipc.accept")
        private let clientQueue = DispatchQueue(label: "logiminus.ipc.client", attributes: .concurrent)
        private let handler: (String) -> String
        private let handlerQueue: DispatchQueue

        /// `handler` is invoked on `handlerQueue` (the main queue in the agent).
        init(path: String = IPC.defaultSocketPath, handlerQueue: DispatchQueue = .main, handler: @escaping (String) -> String) {
            self.path = path
            self.handlerQueue = handlerQueue
            self.handler = handler
        }

        func start() throws {
            // Never take over a socket another live instance is serving.
            if IPC.send("ping", path: path, timeout: 1) != nil { throw ServerError.alreadyRunning }
            unlink(path)   // stale socket of a crashed instance
            fd = socket(AF_UNIX, SOCK_STREAM, 0)
            guard fd >= 0 else { throw ServerError.socket(errno) }
            var addr = address(path)
            let r = withUnsafePointer(to: &addr) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
            }
            guard r == 0, listen(fd, 8) == 0 else { throw ServerError.socket(errno) }
            // Accepted sockets inherit SO_NOSIGPIPE from here. Setting it after accept is too
            // late when the client already hung up: setsockopt then fails on the dead socket.
            var on: Int32 = 1
            setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
            chmod(path, 0o600)
            var st = stat()
            if stat(path, &st) == 0 { inode = st.st_ino }
            let src = DispatchSource.makeReadSource(fileDescriptor: fd, queue: acceptQueue)
            src.setEventHandler { [weak self] in self?.accept() }
            src.resume()
            source = src
        }

        func stop() {
            source?.cancel()
            source = nil
            if fd >= 0 { close(fd); fd = -1 }
            // Only remove the socket file if it is still ours.
            var st = stat()
            if inode != 0, stat(path, &st) == 0, st.st_ino == inode { unlink(path) }
            inode = 0
        }

        private func accept() {
            let client = Darwin.accept(fd, nil, nil)
            guard client >= 0 else { return }
            // Each client is served independently, so a stalled one cannot block the others.
            clientQueue.async { [weak self] in self?.serve(client) }
        }

        private func serve(_ client: Int32) {
            defer { close(client) }
            IPC.prepare(client, timeout: IPC.clientTimeout)
            var data = Data()
            var buf = [UInt8](repeating: 0, count: 256)
            while !data.contains(UInt8(ascii: "\n")) && data.count <= IPC.maxCommandLength {
                let n = read(client, &buf, buf.count)
                if n <= 0 { break }
                data.append(contentsOf: buf[0..<n])
            }
            let reply: String
            if data.count > IPC.maxCommandLength {
                reply = "error: command too long"
            } else {
                let line = String(decoding: data, as: UTF8.self).split(separator: "\n").first.map(String.init) ?? ""
                let cmd = line.trimmingCharacters(in: .whitespacesAndNewlines)
                if cmd.isEmpty { return }
                reply = cmd == "ping" ? "pong" : handlerQueue.sync { handler(cmd) }
            }
            _ = IPC.writeAll(client, reply + "\n")
        }
    }
}
