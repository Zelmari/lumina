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
        case .missing(let msg):
            return .error(IPCResponse.failure(id: request.id, error: msg))
        case .unknown:
            return .error(IPCResponse.failure(id: request.id, error: "unknown cmd"))
        }
    }
    switch parseAgentCmd(cmd: request.cmd, args: request.args) {
    case .ok(let cmd):
        return .request(cmd, id: request.id)
    case .missing(let msg):
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

public enum IPCCodecError: Error {
    case encodeFailed
}

private enum CmdParse<T> {
    case ok(T)
    case missing(String)
    case unknown
}

private func parseAgentCmd(cmd: String, args: [String: JSONValue]) -> CmdParse<AgentCmd> {
    switch cmd {
    case "workspace":
        if let s = args["id"]?.string {
            if s == "prev" { return .ok(.workspacePrev) }
            if s == "next" { return .ok(.workspaceNext) }
        }
        guard let id = args["id"]?.int else { return .missing("missing args: id") }
        return .ok(.workspace(id: normalizeWorkspaceId(id)))
    case "move-node-to-workspace":
        guard let id = args["id"]?.int else { return .missing("missing args: id") }
        return .ok(.moveNodeToWorkspace(id: normalizeWorkspaceId(id)))
    case "focus":
        guard let dir = args["dir"]?.string, let d = DirectionArg(rawValue: dir) else {
            return .missing("missing args: dir")
        }
        return .ok(.focus(dir: d))
    case "swap":
        guard let dir = args["dir"]?.string, let d = DirectionArg(rawValue: dir) else {
            return .missing("missing args: dir")
        }
        return .ok(.swap(dir: d))
    case "resize":
        guard let delta = args["delta"]?.string, let d = ResizeArg(rawValue: delta) else {
            return .missing("missing args: delta")
        }
        return .ok(.resize(delta: d))
    case "balance": return .ok(.balance)
    case "float-toggle": return .ok(.floatToggle)
    case "fullscreen":
        guard let mode = args["mode"]?.string, let m = FullscreenMode(rawValue: mode) else {
            return .missing("missing args: mode")
        }
        return .ok(.fullscreen(mode: m))
    case "close": return .ok(.close)
    case "pause": return .ok(.pause)
    case "resume": return .ok(.resume)
    case "reload": return .ok(.reload)
    case "quit": return .ok(.quit)
    case "list-windows": return .ok(.listWindows)
    case "list-workspaces": return .ok(.listWorkspaces)
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
