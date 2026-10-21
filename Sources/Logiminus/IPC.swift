import Foundation

/// Line-based control protocol over a Unix socket: the CLI writes one command
/// line, the agent answers with one line and closes the connection.
enum IPC {
    static var socketPath: String {
        let dir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Logiminus", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("control.sock").path
    }

    private static func address() -> sockaddr_un {
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let path = socketPath
        withUnsafeMutableBytes(of: &addr.sun_path) { buf in
            path.utf8CString.withUnsafeBytes { src in buf.copyMemory(from: UnsafeRawBufferPointer(rebasing: src.prefix(buf.count - 1))) }
        }
        return addr
    }

    /// Sends a command to a running agent. Returns nil when no agent is listening.
    static func send(_ command: String, timeout: TimeInterval = 5) -> String? {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return nil }
        defer { close(fd) }
        var addr = address()
        let ok = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        guard ok == 0 else { return nil }
        var tv = timeval(tv_sec: Int(timeout), tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        let line = command + "\n"
        _ = line.withCString { write(fd, $0, strlen($0)) }
        var out = Data()
        var buf = [UInt8](repeating: 0, count: 4096)
        while true {
            let n = read(fd, &buf, buf.count)
            if n <= 0 { break }
            out.append(contentsOf: buf[0..<n])
        }
        return String(decoding: out, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    final class Server {
        private var fd: Int32 = -1
        private var source: DispatchSourceRead?
        private let queue = DispatchQueue(label: "logiminus.ipc")
        private let handler: (String) -> String

        /// `handler` is invoked on the main queue.
        init(handler: @escaping (String) -> String) { self.handler = handler }

        func start() throws {
            let path = socketPath
            unlink(path)
            fd = socket(AF_UNIX, SOCK_STREAM, 0)
            var addr = address()
            let r = withUnsafePointer(to: &addr) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
            }
            guard r == 0, listen(fd, 8) == 0 else { throw POSIXError(.EADDRINUSE) }
            chmod(path, 0o600)
            let src = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
            src.setEventHandler { [weak self] in self?.accept() }
            src.resume()
            source = src
        }

        func stop() {
            source?.cancel()
            if fd >= 0 { close(fd) }
            unlink(socketPath)
        }

        private func accept() {
            let client = Darwin.accept(fd, nil, nil)
            guard client >= 0 else { return }
            var data = Data()
            var buf = [UInt8](repeating: 0, count: 1024)
            while !data.contains(UInt8(ascii: "\n")) {
                let n = read(client, &buf, buf.count)
                if n <= 0 { break }
                data.append(contentsOf: buf[0..<n])
            }
            let cmd = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            let reply = DispatchQueue.main.sync { handler(cmd) } + "\n"
            _ = reply.withCString { write(client, $0, strlen($0)) }
            close(client)
        }
    }
}
