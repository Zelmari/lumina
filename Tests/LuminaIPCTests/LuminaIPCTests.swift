import Foundation
import Testing
@testable import LuminaIPC

struct CodecTests {
    @Test func workspaceRoundTrip() throws {
        let req = IPCRequest(id: "abc", cmd: "workspace", args: ["id": 3])
        let line = try encode(req)
        #expect(line.hasSuffix("\n"))
        let parsed = parseLine(line)
        guard case .request(.workspace(let id), let echo) = parsed else {
            Issue.record("expected workspace, got \(parsed)")
            return
        }
        #expect(id == 3)
        #expect(echo == "abc")
        let response = IPCResponse.success(id: echo)
        let out = try encode(response)
        #expect(out.contains("\"ok\":true"))
        #expect(out.contains("\"id\":\"abc\""))
    }

    @Test func unknownCmd() {
        let line = #"{"v":1,"id":"1","cmd":"explode","args":{}}"#
        let parsed = parseLine(line)
        guard case .error(let resp) = parsed else {
            Issue.record("expected error")
            return
        }
        #expect(resp.ok == false)
        #expect(resp.error == "unknown cmd")
    }

    @Test func missingArgs() {
        let line = #"{"v":1,"id":"1","cmd":"focus","args":{}}"#
        let parsed = parseLine(line)
        guard case .error(let resp) = parsed else {
            Issue.record("expected error")
            return
        }
        #expect(resp.error == "missing args: dir")
    }

    @Test func versionRejected() {
        let line = #"{"v":2,"id":"1","cmd":"workspace","args":{"id":3}}"#
        let parsed = parseLine(line)
        guard case .error(let resp) = parsed else {
            Issue.record("expected error")
            return
        }
        #expect(resp.error == "unsupported v")
    }

    @Test func lineTooLong() {
        let over = String(repeating: "a", count: ipcMaxLineBytes + 1)
        #expect(parseLine(over) == .lineTooLong)
    }

    @Test func extraArgsIgnored() {
        let line = #"{"v":1,"id":"x","cmd":"focus","args":{"dir":"left","unused":true}}"#
        let parsed = parseLine(line)
        guard case .request(.focus(let dir), _) = parsed else {
            Issue.record("expected focus, got \(parsed)")
            return
        }
        #expect(dir == .left)
    }

    @Test func extraCurrentToken() {
        let line = #"{"v":1,"id":"z","cmd":"current-token","args":{}}"#
        let parsed = parseLine(line, as: .extra)
        guard case .extra(.currentToken, let id) = parsed else {
            Issue.record("expected extra, got \(parsed)")
            return
        }
        #expect(id == "z")
    }
}

struct PathTests {
    @Test func agentSocketPathHelper() {
        let paths = LuminaPaths.agentSocketPath(
            uid: 501,
            tmpdir: "/tmp",
            instanceId: "abc",
            supportFallback: "/Users/me/Library/Application Support/Lumina"
        )
        #expect(paths.primary == "/tmp/lumina-501/spaces/abc/agent.sock")
        #expect(paths.fallback == "/Users/me/Library/Application Support/Lumina/spaces/abc/agent.sock")
        #expect(LuminaPaths.menuSocketPath(uid: 501, tmpdir: "/tmp") == "/tmp/lumina-501/menu.sock")
    }

    @Test func peerEuidPredicate() {
        #expect(peerEuidAllowed(peer: 501, selfEuid: 501))
        #expect(!peerEuidAllowed(peer: 0, selfEuid: 501))
    }
}

struct LogTests {
    @Test func debugOffDropsDebugLinesAndPrefixIsAgent() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let file = dir.appendingPathComponent("Lumina.log")
        let log = LuminaLog(category: .agent, fileURL: file, debugEnabled: false)
        log.debug("secret title should not appear")
        log.info("pid=1 window=42 bundle=com.apple.Terminal")
        log.info("second line")
        let text = try String(contentsOf: file, encoding: .utf8)
        #expect(!text.contains("secret title"))
        #expect(text.contains("[agent] info pid=1 window=42 bundle=com.apple.Terminal"))
        #expect(text.contains("[agent] info second line"))
        let count = text.split(separator: "\n").count
        #expect(count == 2)
    }
}

struct ArgvTests {
    @Test func argvToRequest() {
        #expect(CLIArgs.parse(["lumina", "focus", "left"])?.cmd == "focus")
        let ws = CLIArgs.parse(["lumina", "workspace", "3"])
        #expect(ws?.cmd == "workspace")
        #expect(ws?.args["id"]?.int == 3)
        let fs = CLIArgs.parse(["lumina", "fullscreen", "lumina"])
        #expect(fs?.cmd == "fullscreen")
        #expect(fs?.args["mode"]?.string == "lumina")
        #expect(CLIArgs.parse(["lumina", "list-windows"])?.cmd == "list-windows")
        #expect(CLIArgs.parse(["lumina", "list-workspaces"])?.cmd == "list-workspaces")
    }
}
