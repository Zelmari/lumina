import Foundation

public enum IPCRole: Equatable, Sendable {
    case agent
    case extra
}

public func parseLine(_ line: String, as role: IPCRole = .agent) -> ParseResult {
    let bytes = line.utf8.count
    if bytes > ipcMaxLineBytes {
        return .lineTooLong
    }
    let trimmed = line.trimmingCharacters(in: .newlines)
    guard let data = trimmed.data(using: .utf8) else {
        return .error(IPCResponse(id: "", ok: false, error: "malformed JSON"))
    }
    let decoder = JSONDecoder()
    let request: IPCRequest
    do {
        request = try decoder.decode(IPCRequest.self, from: data)
    } catch {
        return .error(IPCResponse(id: "", ok: false, error: "malformed JSON"))
    }
    if request.v != ipcProtocolVersion {
        return .error(IPCResponse.failure(id: request.id, error: "unsupported v"))
    }
    if role == .extra {
        switch parseExtraCmd(cmd: request.cmd, args: request.args) {
        case .ok(let cmd):
            return .extra(cmd, id: request.id)
        case .failure(let msg):
            return .error(IPCResponse.failure(id: request.id, error: msg))
        case .unknown:
            return .error(IPCResponse.failure(id: request.id, error: "unknown cmd"))
        }
    }
    switch parseAgentCmd(cmd: request.cmd, args: request.args) {
    case .ok(let cmd):
        return .request(cmd, id: request.id)
    case .failure(let msg):
        return .error(IPCResponse.failure(id: request.id, error: msg))
    case .unknown:
        return .error(IPCResponse.failure(id: request.id, error: "unknown cmd"))
    }
}

public func encode(_ response: IPCResponse) throws -> String {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    let data = try encoder.encode(response)
    guard var line = String(data: data, encoding: .utf8) else {
        throw IPCCodecError.encodeFailed
    }
    if !line.hasSuffix("\n") { line.append("\n") }
    return line
}

public func encode(_ request: IPCRequest) throws -> String {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    let data = try encoder.encode(request)
    guard var line = String(data: data, encoding: .utf8) else {
        throw IPCCodecError.encodeFailed
    }
    if !line.hasSuffix("\n") { line.append("\n") }
    return line
}

/// Decode a response and reject one whose protocol version is not ours.
public func decodeResponse(_ data: Data) throws -> IPCResponse {
    let response = try JSONDecoder().decode(IPCResponse.self, from: data)
    guard response.v == ipcProtocolVersion else {
        throw IPCCodecError.unsupportedVersion(response.v)
    }
    return response
}

public enum IPCCodecError: Error {
    case encodeFailed
    case unsupportedVersion(Int)
}

extension IPCCodecError: CustomStringConvertible {
    public var description: String {
        switch self {
        case .encodeFailed:
            return "failed to encode IPC message"
        case .unsupportedVersion(let v):
            return "unsupported IPC protocol version \(v) (expected \(ipcProtocolVersion))"
        }
    }
}

private enum CmdParse<T> {
    case ok(T)
    case failure(String)
    case unknown
}

/// Human-readable rendering of an argument value for error messages.
private func argValueDescription(_ value: JSONValue) -> String {
    switch value {
    case .null: return "null"
    case .bool(let b): return b ? "true" : "false"
    case .int(let i): return String(i)
    case .double(let d): return String(d)
    case .string(let s): return s
    case .array: return "array"
    case .object: return "object"
    }
}

private func parseAgentCmd(cmd: String, args: [String: JSONValue]) -> CmdParse<AgentCmd> {
    switch cmd {
    case "workspace":
        guard let raw = args["id"] else { return .failure("missing args: id") }
        if let s = raw.string {
            if s == "prev" { return .ok(.workspacePrev) }
            if s == "next" { return .ok(.workspaceNext) }
        }
        guard let id = raw.int else {
            return .failure("invalid args: id=\(argValueDescription(raw))")
        }
        return .ok(.workspace(id: normalizeWorkspaceId(id)))
    case "move-node-to-workspace":
        guard let raw = args["id"] else { return .failure("missing args: id") }
        guard let id = raw.int else {
            return .failure("invalid args: id=\(argValueDescription(raw))")
        }
        return .ok(.moveNodeToWorkspace(id: normalizeWorkspaceId(id)))
    case "focus":
        guard let raw = args["dir"] else { return .failure("missing args: dir") }
        guard let dir = raw.string, let d = DirectionArg(rawValue: dir) else {
            return .failure("invalid args: dir=\(argValueDescription(raw))")
        }
        return .ok(.focus(dir: d))
    case "swap":
        guard let raw = args["dir"] else { return .failure("missing args: dir") }
        guard let dir = raw.string, let d = DirectionArg(rawValue: dir) else {
            return .failure("invalid args: dir=\(argValueDescription(raw))")
        }
        return .ok(.swap(dir: d))
    case "resize":
        guard let raw = args["delta"] else { return .failure("missing args: delta") }
        guard let delta = raw.string, let d = ResizeArg(rawValue: delta) else {
            return .failure("invalid args: delta=\(argValueDescription(raw))")
        }
        return .ok(.resize(delta: d))
    case "balance": return .ok(.balance)
    case "float-toggle": return .ok(.floatToggle)
    case "fullscreen":
        guard let raw = args["mode"] else { return .failure("missing args: mode") }
        guard let mode = raw.string, let m = FullscreenMode(rawValue: mode) else {
            return .failure("invalid args: mode=\(argValueDescription(raw))")
        }
        return .ok(.fullscreen(mode: m))
    case "close": return .ok(.close)
    case "pause": return .ok(.pause)
    case "resume": return .ok(.resume)
    case "reload": return .ok(.reload)
    case "quit": return .ok(.quit)
    case "list-windows": return .ok(.listWindows)
    case "list-workspaces": return .ok(.listWorkspaces)
    case "verify": return .ok(.verify)
    case "status": return .ok(.status)
    case "mark-current": return .ok(.markCurrent)
    case "yield": return .ok(.yield)
    case "debug-windows": return .ok(.debugWindows)
    default: return .unknown
    }
}

private func parseExtraCmd(cmd: String, args: [String: JSONValue]) -> CmdParse<ExtraCmd> {
    _ = args
    switch cmd {
    case "current-token": return .ok(.currentToken)
    case "start": return .ok(.start)
    case "quit-all": return .ok(.quitAll)
    case "open-config": return .ok(.openConfig)
    case "status": return .ok(.status)
    default: return .unknown
    }
}
