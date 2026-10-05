#if os(macOS)
import Darwin
import Foundation
import LuminaIPC

final class MenuSocketServer {
    private var listenFD: Int32 = -1
    private let queue = DispatchQueue(label: "com.zelmari.lumina.menu.sock")
    private var source: DispatchSourceRead?
    var onCommand: ((ExtraCmd, String) -> IPCResponse)?
    let path: String
    let log: LuminaLog

    init(path: String, log: LuminaLog) {
        self.path = path
        self.log = log
    }

    func start() throws {
        let dir = (path as NSString).deletingLastPathComponent
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        // The fallback socket path sits directly in /tmp; chmodding that shared
        // directory would lock out other users. Only private dirs (the runtime
        // root) get tightened.
        if dir != "/tmp" {
            try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: dir)
        }
        unlink(path)
        listenFD = socket(AF_UNIX, SOCK_STREAM, 0)
        guard listenFD >= 0 else { throw POSIXError(.EADDRINUSE) }
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let pathBytes = Array(path.utf8)
        withUnsafeMutablePointer(to: &addr.sun_path) { ptr in
            ptr.withMemoryRebound(to: UInt8.self, capacity: 104) { buf in
                for (i, b) in pathBytes.enumerated() where i < 103 { buf[i] = b }
            }
        }
        let len = socklen_t(MemoryLayout<sockaddr_un>.size)
        let bound = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(listenFD, $0, len) }
        }
        guard bound == 0 else {
            close(listenFD)
            listenFD = -1
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EADDRINUSE)
        }
        chmod(path, 0o600)
        listen(listenFD, 8)
        let src = DispatchSource.makeReadSource(fileDescriptor: listenFD, queue: queue)
        src.setEventHandler { [weak self] in self?.acceptOne() }
        src.resume()
        source = src
    }

    private func acceptOne() {
        let client = accept(listenFD, nil, nil)
        guard client >= 0 else { return }
        var euid: uid_t = 0
        var gid: gid_t = 0
        if getpeereid(client, &euid, &gid) != 0 || euid != geteuid() {
            close(client)
            return
        }
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
                let parsed = parseLine(line, as: .extra)
                let response: IPCResponse
                switch parsed {
                case .lineTooLong:
                    close(fd)
                    return
                case .error(let e):
                    response = e
                case .extra(let cmd, let id):
                    response = onCommand?(cmd, id) ?? .failure(id: id, error: "no handler")
                default:
                    response = .failure(id: "", error: "unknown cmd")
                }
                if let data = try? encode(response).data(using: .utf8) {
                    LuminaSocket.writeAll(fd, data)
                }
            }
        }
        close(fd)
    }
}

enum Client {
    static func request(socketPath: String, cmd: String, args: [String: JSONValue], role: IPCRole) -> IPCResponse? {
        _ = role
        guard let fd = LuminaSocket.connect(path: socketPath) else { return nil }
        defer { close(fd) }
        let req = IPCRequest(id: UUID().uuidString, cmd: cmd, args: args)
        guard let line = try? encode(req), let data = line.data(using: .utf8) else { return nil }
        // A dead or busy agent must not hang the caller forever; the extra's
        // main thread blocks on this.
        guard LuminaSocket.writeAll(fd, data), let payload = LuminaSocket.readLine(fd, deadline: 2.0) else {
            return nil
        }
        return try? decodeResponse(payload)
    }
}
#endif
