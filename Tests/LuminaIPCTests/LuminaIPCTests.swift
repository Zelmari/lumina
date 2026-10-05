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

    @Test func invalidArgValuesAreNotReportedAsMissing() {
        let focus = parseLine(#"{"v":1,"id":"1","cmd":"focus","args":{"dir":"sideways"}}"#)
        guard case .error(let focusErr) = focus else {
            Issue.record("expected error, got \(focus)")
            return
        }
        #expect(focusErr.error == "invalid args: dir=sideways")

        let workspace = parseLine(#"{"v":1,"id":"2","cmd":"workspace","args":{"id":"zero"}}"#)
        guard case .error(let workspaceErr) = workspace else {
            Issue.record("expected error, got \(workspace)")
            return
        }
        #expect(workspaceErr.error == "invalid args: id=zero")

        let fullscreen = parseLine(#"{"v":1,"id":"3","cmd":"fullscreen","args":{"mode":true}}"#)
        guard case .error(let fullscreenErr) = fullscreen else {
            Issue.record("expected error, got \(fullscreen)")
            return
        }
        #expect(fullscreenErr.error == "invalid args: mode=true")
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

    @Test func debugWindowsParses() {
        let line = #"{"v":1,"id":"d","cmd":"debug-windows","args":{}}"#
        let parsed = parseLine(line)
        guard case .request(.debugWindows, let id) = parsed else {
            Issue.record("expected debug-windows, got \(parsed)")
            return
        }
        #expect(id == "d")
    }

    @Test func requestWithoutArgsDecodes() throws {
        let line = #"{"v":1,"id":"x","cmd":"status"}"#
        let parsed = parseLine(line)
        guard case .request(.status, let id) = parsed else {
            Issue.record("expected status, got \(parsed)")
            return
        }
        #expect(id == "x")
        let direct = try JSONDecoder().decode(IPCRequest.self, from: Data(line.utf8))
        #expect(direct.args.isEmpty)
    }

    @Test func jsonValueWholeDoubleRoundTrips() throws {
        let encoder = JSONEncoder()
        let decoder = JSONDecoder()
        let whole = try decoder.decode(JSONValue.self, from: encoder.encode(JSONValue.double(3.0)))
        #expect(whole == .double(3.0))
        #expect(whole == .int(3))
        #expect(JSONValue.int(3) == .double(3.0))
        let fractional = try decoder.decode(JSONValue.self, from: encoder.encode(JSONValue.double(3.5)))
        #expect(fractional == .double(3.5))
        #expect(fractional != .int(3))
    }

    @Test func jsonValueIntDoesNotTrapOnHugeOrNonFiniteDoubles() throws {
        // `Int(1e30)` and `Int(.infinity)` used to trap, so one malformed IPC
        // line could kill the agent.
        #expect(JSONValue.double(1e30).int == nil)
        #expect(JSONValue.double(-1e30).int == nil)
        #expect(JSONValue.double(.infinity).int == nil)
        #expect(JSONValue.double(.nan).int == nil)
        #expect(JSONValue.double(42.0).int == 42)
        let line = #"{"v":1,"id":"1","cmd":"workspace","args":{"id":1e30}}"#
        guard case .error(let response) = parseLine(line) else {
            Issue.record("expected an error response")
            return
        }
        #expect(response.error?.contains("id") == true)
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
        #expect(unixSocketPathFits(paths.primary))
        #expect(unixSocketPathFits(paths.fallback ?? ""))
    }

    @Test func longTmpdirResolvesToFittingAgentSocket() {
        let tmpdir = "/var/folders/lf/gqssmzzn47z1rt274bk0cc780000gn/T"
        let uuid = "8A29DD3F-0A9E-4CF5-8B1B-F2FDBED3BE43"
        let support = "/Users/zelmari/Library/Application Support/Lumina"
        let paths = LuminaPaths.agentSocketPath(
            uid: 501,
            tmpdir: tmpdir,
            instanceId: uuid,
            supportFallback: support
        )
        #expect(!unixSocketPathFits(paths.primary))
        #expect(!unixSocketPathFits(paths.fallback ?? ""))
        let resolved = LuminaPaths.resolvedAgentSocketPath(
            uid: 501,
            tmpdir: tmpdir,
            instanceId: uuid,
            supportFallback: support
        )
        // Primary and the support fallback are too long, so the tmpdir
        // fallback is the first candidate that fits; pin it exactly so a
        // candidate reorder cannot silently pass.
        #expect(resolved == "\(tmpdir)/lumina-501/\(uuid).sock")
        #expect(unixSocketPathFits(resolved))
        #expect(
            LuminaPaths.resolvedAgentSocketPath(
                uid: 501,
                tmpdir: tmpdir,
                instanceId: uuid,
                supportFallback: support
            ) == resolved
        )
    }

    @Test func supportFallbackWinsWhenItFits() {
        let tmpdir = "/var/folders/lf/gqssmzzn47z1rt274bk0cc780000gn/T"
        let uuid = "8A29DD3F-0A9E-4CF5-8B1B-F2FDBED3BE43"
        let support = "/tmp/lumina-support"
        let paths = LuminaPaths.agentSocketPath(
            uid: 501,
            tmpdir: tmpdir,
            instanceId: uuid,
            supportFallback: support
        )
        #expect(!unixSocketPathFits(paths.primary))
        #expect(unixSocketPathFits(paths.fallback ?? ""))
        let resolved = LuminaPaths.resolvedAgentSocketPath(
            uid: 501,
            tmpdir: tmpdir,
            instanceId: uuid,
            supportFallback: support
        )
        #expect(resolved == paths.fallback)
    }

    @Test func overlongInstanceIdShortensFinalFallback() {
        let instanceId = String(repeating: "a", count: 100)
        let resolved = LuminaPaths.resolvedAgentSocketPath(
            uid: 501,
            tmpdir: "/var/folders/lf/gqssmzzn47z1rt274bk0cc780000gn/T",
            instanceId: instanceId,
            supportFallback: "/Users/zelmari/Library/Application Support/Lumina"
        )
        #expect(unixSocketPathFits(resolved))
        #expect(resolved == "/tmp/lumina-501/2885d0ac2e5a9d79.sock")
    }

    @Test func shortTmpdirKeepsDesignedAgentSocket() {
        let resolved = LuminaPaths.resolvedAgentSocketPath(
            uid: 501,
            tmpdir: "/tmp",
            instanceId: "abc",
            supportFallback: "/Users/me/Library/Application Support/Lumina"
        )
        #expect(resolved == "/tmp/lumina-501/spaces/abc/agent.sock")
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
        #expect(CLIArgs.parse(["lumina", "workspace", "0"])?.args["id"]?.int == 10)
        #expect(CLIArgs.parse(["lumina", "move-node-to-workspace", "0"])?.args["id"]?.int == 10)
        #expect(CLIArgs.parse(["lumina", "focus", "version"])?.cmd == "focus")
        #expect(CLIArgs.earlyExit(["lumina", "version"]) == .version)
        #expect(CLIArgs.earlyExit(["lumina", "debug"]) == .debug)
        #expect(CLIArgs.earlyExit(["lumina", "focus", "version"]) == nil)
        #expect(CLIArgs.parse(["lumina", "debug"]) == nil)
        #expect(CLIArgs.earlyExit(["lumina", "debug-windows"]) == nil)
        #expect(CLIArgs.parse(["lumina", "debug-windows"])?.cmd == "debug-windows")
        let zero = #"{"v":1,"id":"z","cmd":"workspace","args":{"id":0}}"#
        guard case .request(.workspace(let zeroId), _) = parseLine(zero) else {
            Issue.record("expected workspace 0, got \(parseLine(zero))")
            return
        }
        #expect(zeroId == 10)
        guard case .request(.yield, _) = parseLine(#"{"v":1,"id":"y","cmd":"yield","args":{}}"#) else {
            Issue.record("expected yield")
            return
        }
        let mark = #"{"v":1,"id":"m","cmd":"mark-current","args":{}}"#
        let parsed = parseLine(mark)
        guard case .request(.markCurrent, let id) = parsed else {
            Issue.record("expected mark-current, got \(parsed)")
            return
        }
        #expect(id == "m")
    }
}
