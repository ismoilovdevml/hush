// A small JSON-over-unix-socket channel between the `hush` CLI and the running app.
//
// It exists because the headphones only accept one RFCOMM connection: while Hush.app holds
// channel 9, anything else trying to open it gets kIOReturnBusy. So the CLI asks the app
// instead, and only talks to the device directly when the app is not running.
import Foundation

enum ControlSocket {
    /// Per-user socket, inside the app's own support directory.
    static let path: String = {
        let dir = (NSHomeDirectory() as NSString)
            .appendingPathComponent("Library/Application Support/Hush")
        // 0700 on the directory means that even in the window between bind() and the socket's
        // own chmod, no other local user can reach the socket.
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true,
                                                 attributes: [.posixPermissions: 0o700])
        chmod(dir, 0o700)
        return (dir as NSString).appendingPathComponent("control.sock")
    }()

    /// A single request line is small JSON; cap it so a client that never sends a newline
    /// cannot grow the buffer without bound before the read timeout.
    private static let maxLineBytes = 64 * 1024

    private static func address(_ path: String) -> sockaddr_un {
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let capacity = MemoryLayout.size(ofValue: addr.sun_path)
        let bytes = Array(path.utf8.prefix(capacity - 1))
        withUnsafeMutableBytes(of: &addr.sun_path) { $0.copyBytes(from: bytes) }
        return addr
    }

    private static func writeLine(_ fd: Int32, _ object: [String: Any]) {
        guard var data = try? JSONSerialization.data(withJSONObject: object) else { return }
        data.append(0x0A)
        data.withUnsafeBytes { raw in
            var sent = 0
            while sent < raw.count {
                let n = write(fd, raw.baseAddress!.advanced(by: sent), raw.count - sent)
                if n <= 0 { return }
                sent += n
            }
        }
    }

    private static func readLine(_ fd: Int32, timeout: TimeInterval) -> [String: Any]? {
        var buffer = Data()
        var byte: UInt8 = 0
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            let n = read(fd, &byte, 1)
            if n == 1 {
                if byte == 0x0A { break }
                if buffer.count >= maxLineBytes { return nil }
                buffer.append(byte)
                continue
            }
            if n == 0 { break }
            if errno == EAGAIN || errno == EINTR { usleep(20_000); continue }
            return nil
        }
        guard !buffer.isEmpty else { return nil }
        return try? JSONSerialization.jsonObject(with: buffer) as? [String: Any]
    }

    // MARK: client

    /// Send one request to a running app. Returns nil when nothing is listening.
    static func send(_ request: [String: Any], timeout: TimeInterval = 6) -> [String: Any]? {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return nil }
        defer { close(fd) }

        var addr = address(path)
        let ok = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) == 0
            }
        }
        guard ok else { return nil }

        var tv = timeval(tv_sec: Int(timeout), tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))

        writeLine(fd, request)
        return readLine(fd, timeout: timeout)
    }

    // MARK: server

    /// Serve requests on a background thread. `handle` is invoked on the main queue and
    /// replies through its completion, so a request may wait on the headphones without
    /// blocking the run loop that delivers their answer.
    static func serve(handle: @escaping ([String: Any], @escaping ([String: Any]) -> Void) -> Void) {
        unlink(path)
        let listener = socket(AF_UNIX, SOCK_STREAM, 0)
        guard listener >= 0 else { return }

        var addr = address(path)
        let bound = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(listener, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) == 0
            }
        }
        guard bound, listen(listener, 4) == 0 else { close(listener); return }
        chmod(path, 0o600)

        Thread.detachNewThread {
            while true {
                let client = accept(listener, nil, nil)
                if client < 0 { if errno == EINTR { continue }; break }
                defer { close(client) }

                var tv = timeval(tv_sec: 5, tv_usec: 0)
                setsockopt(client, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))

                guard let request = readLine(client, timeout: 5) else { continue }
                let semaphore = DispatchSemaphore(value: 0)
                var reply: [String: Any] = ["ok": false, "error": "no reply"]
                DispatchQueue.main.async {
                    handle(request) { response in
                        reply = response
                        semaphore.signal()
                    }
                }
                _ = semaphore.wait(timeout: .now() + 8)
                writeLine(client, reply)
            }
            close(listener)
        }
    }
}
