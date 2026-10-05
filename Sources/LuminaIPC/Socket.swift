#if canImport(Darwin)
import Darwin
import Foundation

/// Small blocking-socket helpers shared by the menu extra and the CLI so both
/// read a full JSON line and never SIGPIPE on a vanished peer.
public enum LuminaSocket {
    /// A read deadline, not a hard error: callers retry until it expires.
    public static func setReceiveTimeout(_ fd: Int32, seconds: TimeInterval) {
        var tv = timeval(
            tv_sec: Int(seconds),
            tv_usec: suseconds_t((seconds - Double(Int(seconds))) * 1_000_000)
        )
        _ = setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
    }

    /// Write every byte or fail. A plain `write` can accept a partial line.
    @discardableResult
    public static func writeAll(_ fd: Int32, _ data: Data) -> Bool {
        data.withUnsafeBytes { raw in
            guard let base = raw.baseAddress else { return data.isEmpty }
            var offset = 0
            while offset < raw.count {
                let n = write(fd, base.advanced(by: offset), raw.count - offset)
                if n < 0 {
                    if errno == EINTR { continue }
                    return false
                }
                if n == 0 { return false }
                offset += n
            }
            return true
        }
    }

    /// Read until newline, EOF, the deadline, or `maxBytes`. Returns the
    /// payload without the newline. Responses are newline-terminated JSON
    /// lines; a single `read` can return a partial line.
    public static func readLine(
        _ fd: Int32,
        deadline: TimeInterval = 2.0,
        maxBytes: Int = ipcMaxLineBytes
    ) -> Data? {
        var buffer = Data()
        var chunk = [UInt8](repeating: 0, count: 4096)
        let end = Date().addingTimeInterval(deadline)
        while true {
            if let index = buffer.firstIndex(of: 0x0A) {
                return buffer.subdata(in: buffer.startIndex..<index)
            }
            if buffer.count > maxBytes { return nil }
            let remaining = end.timeIntervalSinceNow
            if remaining <= 0 { break }
            setReceiveTimeout(fd, seconds: min(remaining, 0.25))
            let n = read(fd, &chunk, chunk.count)
            if n < 0 {
                if errno == EINTR { continue }
                if errno == EAGAIN || errno == EWOULDBLOCK { continue }
                break
            }
            if n == 0 { break }
            buffer.append(contentsOf: chunk.prefix(n))
        }
        return buffer.isEmpty ? nil : buffer
    }

    /// Block until one newline-terminated message arrives, the peer closes, or
    /// `stop` becomes true. For long-lived subscription readers: a timeout is
    /// not an error and a partial line is never returned as complete.
    public static func readLineBlocking(
        _ fd: Int32,
        stop: () -> Bool,
        idleTick: TimeInterval = 0.25
    ) -> Data? {
        var buffer = Data()
        var chunk = [UInt8](repeating: 0, count: 4096)
        while true {
            if let index = buffer.firstIndex(of: 0x0A) {
                return buffer.subdata(in: buffer.startIndex..<index)
            }
            if buffer.count > ipcMaxLineBytes { return nil }
            if stop() { return nil }
            setReceiveTimeout(fd, seconds: idleTick)
            let n = read(fd, &chunk, chunk.count)
            if n < 0 {
                if errno == EINTR { continue }
                if errno == EAGAIN || errno == EWOULDBLOCK { continue }
                return nil
            }
            if n == 0 { return nil }
            buffer.append(contentsOf: chunk.prefix(n))
        }
    }

    /// Connect to a UNIX socket and return the fd. The caller owns it.
    public static func connect(path: String) -> Int32? {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return nil }
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let pathBytes = Array(path.utf8)
        withUnsafeMutablePointer(to: &addr.sun_path) { ptr in
            ptr.withMemoryRebound(to: UInt8.self, capacity: 104) { buf in
                for (i, b) in pathBytes.enumerated() where i < 103 { buf[i] = b }
            }
        }
        let ok = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) == 0
            }
        }
        guard ok else {
            close(fd)
            return nil
        }
        return fd
    }
}
#endif
