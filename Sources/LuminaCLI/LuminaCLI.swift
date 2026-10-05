#if os(macOS)
import Darwin
import Foundation
import LuminaIPC
import LuminaLayout

@main
enum LuminaCLI {
    static func main() {
        // Ctrl-C on a hung request closes the client fd; the server must not
        // die from the resulting SIGPIPE.
        signal(SIGPIPE, SIG_IGN)
        let argv = CommandLine.arguments
        if let early = CLIArgs.earlyExit(argv) {
            switch early {
            case .version:
                writeOut("lumina 0.1.0")
            case .help:
                writeOut(CLIArgs.usage)
            case .debug:
                writeOut("LUMINA_DEBUG=\(ProcessInfo.processInfo.environment["LUMINA_DEBUG"] ?? "0")")
            }
            exit(0)
        }
        let log = LuminaLog(category: .cli, fileURL: LuminaLog.defaultFileURL())
        let uid = getuid()
        let tmp = FileManager.default.temporaryDirectory.path
        let menu = LuminaPaths.resolvedMenuSocketPath(uid: uid, tmpdir: tmp)
        if argv.count > 1, argv[1] == "bench" {
            exit(runBench(argv: argv, menu: menu, log: log))
        }
        guard let request = CLIArgs.parse(argv) else {
            if argv.count > 1 {
                log.error("unknown command: \(argv[1])")
            }
            writeOut(CLIArgs.usage)
            exit(1)
        }
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
        let path = agentSocket(menu: menu)
        guard let path else {
            log.error("agent not running on this Space")
            exit(2)
        }
        guard let resp = unixRequest(path: path, request: request) else {
            log.error("agent not running on this Space")
            exit(2)
        }
        if request.cmd == "debug-windows" {
            exit(writeDebugDump(resp, log: log))
        }
        printResponse(resp, log: log)
        if request.cmd == "verify" {
            // `lumina verify` is a test primitive: a clean report is exit 0,
            // any invariant violation is exit 1, even though the IPC succeeded.
            let clean = resp.data?.object?["ok"]?.bool ?? false
            exit(resp.ok && clean ? 0 : 1)
        }
        exit(resp.ok ? 0 : 1)
    }

    static func writeDebugDump(_ resp: IPCResponse, log: LuminaLog) -> Int32 {
        guard resp.ok else {
            log.error("debug-windows failed: \(resp.error ?? "unknown error")")
            return 1
        }
        guard let data = resp.data else {
            log.error("debug-windows failed: agent returned no data")
            return 1
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let encoded = try? encoder.encode(data) else {
            log.error("debug-windows failed: response is not encodable")
            return 1
        }
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let dir = home + "/Library/Application Support/Lumina/debug"
        let timestamp = ISO8601DateFormatter().string(from: Date())
        let path = dir + "/windows-\(timestamp).json"
        do {
            try FileManager.default.createDirectory(
                atPath: dir,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: dir)
            try encoded.write(to: URL(fileURLWithPath: path), options: .atomic)
        } catch {
            log.error("debug-windows failed: cannot write \(path): \(error.localizedDescription)")
            return 1
        }
        writeOut(path)
        return 0
    }

    static func agentSocket(menu: String) -> String? {
        let uid = getuid()
        let tmp = FileManager.default.temporaryDirectory.path
        return preferredSocket() ?? {
            guard let token = currentToken(menu: menu) else { return nil }
            return LuminaPaths.resolvedAgentSocketPath(
                uid: uid,
                tmpdir: tmp,
                instanceId: token,
                supportFallback: FileManager.default.homeDirectoryForCurrentUser.path + "/Library/Application Support/Lumina"
            )
        }()
    }

    /// `lumina bench`: one connection, N sequential pings, RTT percentiles.
    /// Exit 1 when the p95 exceeds `--max-p95-ms` or a ping times out, so the
    /// harness can gate on latency. Exit 2 when there is no agent.
    static func runBench(argv: [String], menu: String, log: LuminaLog) -> Int32 {
        guard let options = CLIArgs.parseBench(argv) else {
            log.error("invalid bench flags")
            writeOut(CLIArgs.usage)
            return 1
        }
        guard let path = agentSocket(menu: menu), let fd = LuminaSocket.connect(path: path) else {
            log.error("agent not running on this Space")
            return 2
        }
        defer { close(fd) }
        var stats = LatencyStats(capacity: Swift.max(options.count, 1))
        var timeouts = 0
        let clock = ContinuousClock()
        for index in 0..<(options.warmup + options.count) {
            let request = IPCRequest(id: UUID().uuidString, cmd: "ping")
            guard let line = try? encode(request), let data = line.data(using: .utf8),
                  LuminaSocket.writeAll(fd, data)
            else {
                log.error("bench: write failed")
                return 2
            }
            let start = clock.now
            guard let payload = LuminaSocket.readLine(fd, deadline: 2.0),
                  let response = try? decodeResponse(payload), response.ok
            else {
                timeouts += 1
                break
            }
            if index >= options.warmup {
                stats.record(milliseconds: (clock.now - start) / .milliseconds(1))
            }
        }
        func number(_ value: Double?) -> JSONValue {
            value.map { .double($0) } ?? .null
        }
        let data = JSONValue.object([
            "count": .int(stats.count),
            "warmup": .int(options.warmup),
            "timeouts": .int(timeouts),
            "rttMs": .object([
                "min": number(stats.min),
                "p50": number(stats.p50),
                "p95": number(stats.p95),
                "max": number(stats.max),
                "mean": number(stats.mean),
            ]),
        ])
        printResponse(IPCResponse.success(id: "bench", data: data), log: log)
        if timeouts > 0 { return 1 }
        if let maxP95 = options.maxP95Ms, let p95 = stats.p95, p95 > maxP95 {
            log.error("bench: p95 \(String(format: "%.2f", p95))ms exceeds \(maxP95)ms")
            return 1
        }
        return 0
    }

    static func preferredSocket() -> String? {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let path = LuminaPaths.instancesPath(supportRoot: home + "/Library/Application Support/Lumina")
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
              let registry = try? InstanceRegistry.decode(data)
        else { return nil }
        return preferredAgentSocket(registry: registry, pidAlive: { kill($0, 0) == 0 })
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
        guard let fd = LuminaSocket.connect(path: path) else { return nil }
        defer { close(fd) }
        guard let line = try? encode(request), let data = line.data(using: .utf8) else { return nil }
        // Read until the newline: a large `debug-windows`/`list-windows`
        // response can arrive in several reads, and one `read` used to fail
        // the decode and report "agent not running".
        guard LuminaSocket.writeAll(fd, data), let payload = LuminaSocket.readLine(fd, deadline: 2.0) else {
            return nil
        }
        return try? decodeResponse(payload)
    }

    static func printResponse(_ resp: IPCResponse, log: LuminaLog) {
        if resp.ok {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            if let data = resp.data, let encoded = try? encoder.encode(data),
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
