#if os(macOS)
import Darwin
import Foundation
import LuminaIPC

@main
enum LuminaCLI {
    static func main() {
        let argv = CommandLine.arguments
        if let early = CLIArgs.earlyExit(argv) {
            switch early {
            case .version:
                writeOut("lumina 0.1.0")
            case .debug:
                writeOut("LUMINA_DEBUG=1")
            }
            exit(0)
        }
        let log = LuminaLog(category: .cli, fileURL: LuminaLog.defaultFileURL())
        guard let request = CLIArgs.parse(argv) else {
            log.error("usage: lumina <cmd> [args]")
            exit(1)
        }
        let uid = getuid()
        let tmp = FileManager.default.temporaryDirectory.path
        let menu = LuminaPaths.resolvedMenuSocketPath(uid: uid, tmpdir: tmp)
        if CLIArgs.isExtraCommand(request.cmd) || request.cmd == "start" {
            if let resp = unixRequest(path: menu, request: request) {
                printResponse(resp, log: log)
                exit(resp.ok ? 0 : 1)
            }
            if request.cmd == "start" {
                let proc = Process()
                proc.executableURL = URL(fileURLWithPath: "/usr/bin/open")
                proc.arguments = ["-a", "Lumina"]
                try? proc.run()
                let deadline = Date().addingTimeInterval(2)
                while Date() < deadline {
                    usleep(100_000)
                    if let resp = unixRequest(path: menu, request: request) {
                        printResponse(resp, log: log)
                        exit(resp.ok ? 0 : 1)
                    }
                }
            }
            log.error("menu extra not running")
            exit(1)
        }
        guard let token = currentToken(menu: menu) else {
            log.error("agent not running on this Space")
            exit(2)
        }
        let path = LuminaPaths.resolvedAgentSocketPath(
            uid: uid,
            tmpdir: tmp,
            instanceId: token,
            supportFallback: FileManager.default.homeDirectoryForCurrentUser.path + "/Library/Application Support/Lumina"
        )
        guard let resp = unixRequest(path: path, request: request) else {
            log.error("agent not running on this Space")
            exit(2)
        }
        printResponse(resp, log: log)
        exit(resp.ok ? 0 : 1)
    }

    static func currentToken(menu: String) -> String? {
        let req = IPCRequest(id: UUID().uuidString, cmd: "current-token")
        if let resp = unixRequest(path: menu, request: req) {
            return resp.data?.object?["instanceId"]?.string
        }
        return instancesFileToken()
    }

    static func instancesFileToken() -> String? {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let path = LuminaPaths.instancesPath(supportRoot: home + "/Library/Application Support/Lumina")
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }
        if let id = obj["lastCurrentInstanceId"] as? String { return id }
        if let agents = obj["agents"] as? [[String: Any]],
           let first = agents.first?["instanceId"] as? String
        {
            return first
        }
        return nil
    }

    static func unixRequest(path: String, request: IPCRequest) -> IPCResponse? {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return nil }
        defer { close(fd) }
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
                connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) == 0
            }
        }
        guard ok else { return nil }
        guard let line = try? encode(request), let data = line.data(using: .utf8) else { return nil }
        _ = data.withUnsafeBytes { write(fd, $0.baseAddress, data.count) }
        var buf = [UInt8](repeating: 0, count: 1 << 16)
        let n = read(fd, &buf, buf.count)
        guard n > 0 else { return nil }
        return try? JSONDecoder().decode(IPCResponse.self, from: Data(buf.prefix(n)))
    }

    static func printResponse(_ resp: IPCResponse, log: LuminaLog) {
        if resp.ok {
            if let data = resp.data, let encoded = try? JSONEncoder().encode(data),
               let s = String(data: encoded, encoding: .utf8)
            {
                writeOut(s)
            } else {
                writeOut("ok")
            }
        } else {
            log.error(resp.error ?? "error")
        }
    }

    static func writeOut(_ s: String) {
        if let data = (s + "\n").data(using: .utf8) {
            try? FileHandle.standardOutput.write(contentsOf: data)
        }
    }
}
#endif
