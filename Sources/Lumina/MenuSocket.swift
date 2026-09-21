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
        try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: dir)
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
        let n = read(fd, &tmp, tmp.count)
        if n > 0 {
            buffer.append(contentsOf: tmp.prefix(n))
            if buffer.count > ipcMaxLineBytes { close(fd); return }
            let line = String(data: buffer, encoding: .utf8) ?? ""
            let parsed = parseLine(line.trimmingCharacters(in: .newlines), as: .extra)
            let response: IPCResponse
            switch parsed {
            case .extra(let cmd, let id):
                response = onCommand?(cmd, id) ?? .failure(id: id, error: "no handler")
            case .error(let e):
                response = e
            default:
                response = .failure(id: "", error: "unknown cmd")
            }
            if let data = try? encode(response).data(using: .utf8) {
                _ = data.withUnsafeBytes { write(fd, $0.baseAddress, data.count) }
            }
        }
        close(fd)
    }
}

enum Client {
    static func request(socketPath: String, cmd: String, args: [String: JSONValue], role: IPCRole) -> IPCResponse? {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return nil }
        defer { close(fd) }
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let pathBytes = Array(socketPath.utf8)
        withUnsafeMutablePointer(to: &addr.sun_path) { ptr in
            ptr.withMemoryRebound(to: UInt8.self, capacity: 104) { buf in
                for (i, b) in pathBytes.enumerated() where i < 103 { buf[i] = b }
            }
        }
        let ok = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) == 0
            }
        }
        guard ok else { return nil }
        let req = IPCRequest(id: UUID().uuidString, cmd: cmd, args: args)
        guard let line = try? encode(req), let data = line.data(using: .utf8) else { return nil }
        _ = data.withUnsafeBytes { write(fd, $0.baseAddress, data.count) }
        var buf = [UInt8](repeating: 0, count: 1 << 16)
        let n = read(fd, &buf, buf.count)
        guard n > 0, let text = String(bytes: buf.prefix(n), encoding: .utf8) else { return nil }
        let decoder = JSONDecoder()
        return try? decoder.decode(IPCResponse.self, from: Data(text.utf8))
    }
}
#endif
