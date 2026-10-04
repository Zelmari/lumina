#if os(macOS)
import Darwin
import Foundation
import LuminaIPC

public final class AgentSocketServer {
    private var listenFD: Int32 = -1
    private let queue = DispatchQueue(label: "com.zelmari.lumina.agent.sock")
    private var source: DispatchSourceRead?
    public var onCommand: ((AgentCmd, String) -> IPCResponse)?
    private let log: LuminaLog
    public let path: String

    public init(path: String, log: LuminaLog) {
        self.path = path
        self.log = log
    }

    public func start() throws {
        let dir = (path as NSString).deletingLastPathComponent
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: dir)
        unlink(path)
        listenFD = socket(AF_UNIX, SOCK_STREAM, 0)
        guard listenFD >= 0 else { throw POSIXError(.EADDRINUSE) }
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let maxLen = unixSocketPathMaxBytes
        let pathBytes = Array(path.utf8)
        guard pathBytes.count <= maxLen else {
            close(listenFD)
            listenFD = -1
            throw POSIXError(.ENAMETOOLONG)
        }
        withUnsafeMutablePointer(to: &addr.sun_path) { ptr in
            ptr.withMemoryRebound(to: UInt8.self, capacity: maxLen + 1) { buf in
                for (i, b) in pathBytes.enumerated() { buf[i] = b }
                buf[pathBytes.count] = 0
            }
        }
        let len = socklen_t(MemoryLayout<sockaddr_un>.size)
        let bindOK = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(listenFD, $0, len) == 0
            }
        }
        guard bindOK else {
            let code = POSIXError.Code(rawValue: errno) ?? .EADDRINUSE
            close(listenFD)
            listenFD = -1
            throw POSIXError(code)
        }
        chmod(path, 0o600)
        guard listen(listenFD, 8) == 0 else {
            let code = POSIXError.Code(rawValue: errno) ?? .EADDRINUSE
            close(listenFD)
            listenFD = -1
            throw POSIXError(code)
        }
        let src = DispatchSource.makeReadSource(fileDescriptor: listenFD, queue: queue)
        src.setEventHandler { [weak self] in self?.acceptOne() }
        src.resume()
        source = src
        log.info("agent socket \(path)")
    }

    public func stop() {
        source?.cancel()
        source = nil
        if listenFD >= 0 { close(listenFD); listenFD = -1 }
        unlink(path)
    }

    private func acceptOne() {
        let client = accept(listenFD, nil, nil)
        guard client >= 0 else { return }
        var euid: uid_t = 0
        var egid: gid_t = 0
        if getpeereid(client, &euid, &egid) != 0 || !peerEuidAllowed(peer: euid, selfEuid: geteuid()) {
            close(client)
            return
        }
        // A client that stops reading must not block the serial queue in
        // write; time the send out so a stalled reader fails instead.
        var sendTimeout = timeval(tv_sec: 2, tv_usec: 0)
        _ = setsockopt(
            client,
            SOL_SOCKET,
            SO_SNDTIMEO,
            &sendTimeout,
            socklen_t(MemoryLayout<timeval>.size)
        )
        queue.async { self.serve(client) }
    }

    private func serve(_ fd: Int32) {
        var buffer = Data()
        var tmp = [UInt8](repeating: 0, count: 4096)
        while true {
            let n = read(fd, &tmp, tmp.count)
            if n <= 0 { break }
            buffer.append(contentsOf: tmp.prefix(n))
            if buffer.count > ipcMaxLineBytes {
                close(fd)
                return
            }
            while let range = buffer.firstIndex(of: 0x0A) {
                let lineData = buffer.subdata(in: buffer.startIndex..<range)
                buffer.removeSubrange(buffer.startIndex...range)
                let line = String(data: lineData, encoding: .utf8) ?? ""
                let parsed = parseLine(line, as: .agent)
                let response: IPCResponse
                switch parsed {
                case .lineTooLong:
                    close(fd)
                    return
                case .error(let err):
                    response = err
                case .request(let cmd, let id):
                    if let onCommand {
                        var captured: IPCResponse?
                        let sem = DispatchSemaphore(value: 0)
                        MutationQueue.shared.hop {
                            captured = onCommand(cmd, id)
                            sem.signal()
                        }
                        sem.wait()
                        response = captured ?? IPCResponse.failure(id: id, error: "internal")
                    } else {
                        response = IPCResponse.failure(id: id, error: "no handler")
                    }
                case .extra(_, let id):
                    response = IPCResponse.failure(id: id, error: "unknown cmd")
                }
                if let encoded = try? encode(response), let data = encoded.data(using: .utf8) {
                    guard writeAll(fd, data) else {
                        close(fd)
                        return
                    }
                }
            }
        }
        close(fd)
    }

    /// Write every byte of `data`, bounded by the client fd's `SO_SNDTIMEO`
    /// plus a total deadline. Returns false if the peer stops reading, so the
    /// caller can drop the connection instead of holding the serial queue.
    private func writeAll(_ fd: Int32, _ data: Data) -> Bool {
        let deadline = DispatchTime.now() + 2.0
        var offset = 0
        return data.withUnsafeBytes { raw -> Bool in
            guard let base = raw.baseAddress else { return true }
            while offset < data.count {
                if DispatchTime.now() >= deadline { return false }
                let n = write(fd, base + offset, data.count - offset)
                if n > 0 {
                    offset += n
                } else if n < 0 && errno == EINTR {
                    continue
                } else {
                    return false
                }
            }
            return true
        }
    }
}
#endif
