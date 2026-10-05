import Foundation

public let ipcProtocolVersion = 1
public let ipcMaxLineBytes = 1_048_576

public struct IPCRequest: Equatable, Sendable, Codable {
    public var v: Int
    public var id: String
    public var cmd: String
    public var args: [String: JSONValue]

    public init(v: Int = ipcProtocolVersion, id: String, cmd: String, args: [String: JSONValue] = [:]) {
        self.v = v
        self.id = id
        self.cmd = cmd
        self.args = args
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.v = try c.decode(Int.self, forKey: .v)
        self.id = try c.decode(String.self, forKey: .id)
        self.cmd = try c.decode(String.self, forKey: .cmd)
        self.args = try c.decodeIfPresent([String: JSONValue].self, forKey: .args) ?? [:]
    }
}

public struct IPCResponse: Equatable, Sendable, Codable {
    public var v: Int
    public var id: String
    public var ok: Bool
    public var error: String?
    public var data: JSONValue?

    public init(v: Int = ipcProtocolVersion, id: String, ok: Bool, error: String? = nil, data: JSONValue? = nil) {
        self.v = v
        self.id = id
        self.ok = ok
        self.error = error
        self.data = data
    }

    public static func success(id: String, data: JSONValue? = nil) -> IPCResponse {
        IPCResponse(id: id, ok: true, data: data)
    }

    public static func failure(id: String, error: String) -> IPCResponse {
        IPCResponse(id: id, ok: false, error: error)
    }
}

public enum ParseResult: Equatable, Sendable {
    case request(AgentCmd, id: String)
    case extra(ExtraCmd, id: String)
    case error(IPCResponse)
    case lineTooLong
}

public enum DirectionArg: String, Equatable, Sendable, Codable {
    case left, down, up, right
}

public enum ResizeArg: String, Equatable, Sendable, Codable {
    case grow, shrink
}

public enum FullscreenMode: String, Equatable, Sendable, Codable {
    case lumina, native
}

public enum AgentCmd: Equatable, Sendable {
    case workspace(id: Int)
    case workspacePrev
    case workspaceNext
    case moveNodeToWorkspace(id: Int)
    case focus(dir: DirectionArg)
    case swap(dir: DirectionArg)
    case resize(delta: ResizeArg)
    case balance
    case floatToggle
    case fullscreen(mode: FullscreenMode)
    case close
    case pause
    case resume
    case reload
    case quit
    case listWindows
    case listWorkspaces
    case verify
    /// `full` adds diagnostics that cost a WindowServer enumeration; the menu
    /// extra polls with false.
    case status(full: Bool)
    /// Transport-only liveness probe. The socket server answers it without
    /// hopping onto the mutation queue, so it measures raw IPC round trips.
    case ping
    /// Extra-only: swipe-back attach without SkyLight (reason `start`).
    case markCurrent
    /// This agent is no longer the current Space. Drop hotkeys and stop mutating.
    case yield
    /// Show the Accessibility grant prompt again (freshly reset TCC record).
    case accessibilityPrompt
    /// Dump an app's AX attribute names and tab-related values.
    case debugAX(pid: Int32)
    case debugWindows
}

/// Option-0 and `lumina workspace 0` mean space 10. `SpaceId` itself stays 1...10.
public func normalizeWorkspaceId(_ id: Int) -> Int {
    id == 0 ? 10 : id
}

public enum ExtraCmd: Equatable, Sendable {
    case currentToken
    case start
    case quitAll
    case openConfig
    case grantAccessibility
    case status
}

public enum JSONValue: Equatable, Sendable, Codable {
    case null
    case bool(Bool)
    case int(Int)
    case double(Double)
    case string(String)
    case array([JSONValue])
    case object([String: JSONValue])

    public init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self = .null; return }
        if let v = try? c.decode(Bool.self) { self = .bool(v); return }
        if let v = try? c.decode(Int.self) { self = .int(v); return }
        if let v = try? c.decode(Double.self) { self = .double(v); return }
        if let v = try? c.decode(String.self) { self = .string(v); return }
        if let v = try? c.decode([JSONValue].self) { self = .array(v); return }
        if let v = try? c.decode([String: JSONValue].self) { self = .object(v); return }
        throw DecodingError.dataCorruptedError(in: c, debugDescription: "unsupported JSON value")
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .null: try c.encodeNil()
        case .bool(let v): try c.encode(v)
        case .int(let v): try c.encode(v)
        case .double(let v): try c.encode(v)
        case .string(let v): try c.encode(v)
        case .array(let v): try c.encode(v)
        case .object(let v): try c.encode(v)
        }
    }

    /// JSON has no integer type, so a whole `.double` decodes back as `.int`.
    /// Treat those cases as the same number instead of reporting a spurious
    /// mismatch after a round-trip.
    public static func == (lhs: JSONValue, rhs: JSONValue) -> Bool {
        switch (lhs, rhs) {
        case (.null, .null):
            return true
        case (.bool(let a), .bool(let b)):
            return a == b
        case (.int(let a), .int(let b)):
            return a == b
        case (.double(let a), .double(let b)):
            return a == b
        case (.int(let a), .double(let b)):
            return Double(a) == b
        case (.double(let a), .int(let b)):
            return a == Double(b)
        case (.string(let a), .string(let b)):
            return a == b
        case (.array(let a), .array(let b)):
            return a == b
        case (.object(let a), .object(let b)):
            return a == b
        default:
            return false
        }
    }

    public var string: String? {
        if case .string(let s) = self { return s }
        return nil
    }

    public var int: Int? {
        switch self {
        case .int(let i):
            return i
        case .double(let d):
            // `Int(exactly:)` is nil for NaN/infinity and for values outside
            // Int's range; `Int(d)` traps on `1e30` and could kill the agent
            // from one malformed IPC line.
            return Int(exactly: d)
        default:
            return nil
        }
    }

    public var bool: Bool? {
        if case .bool(let b) = self { return b }
        return nil
    }

    public var object: [String: JSONValue]? {
        if case .object(let o) = self { return o }
        return nil
    }

    public var array: [JSONValue]? {
        if case .array(let a) = self { return a }
        return nil
    }
}

extension JSONValue: ExpressibleByStringLiteral {
    public init(stringLiteral value: String) { self = .string(value) }
}

extension JSONValue: ExpressibleByIntegerLiteral {
    public init(integerLiteral value: Int) { self = .int(value) }
}

extension JSONValue: ExpressibleByBooleanLiteral {
    public init(booleanLiteral value: Bool) { self = .bool(value) }
}

extension JSONValue: ExpressibleByDictionaryLiteral {
    public init(dictionaryLiteral elements: (String, JSONValue)...) {
        self = .object(Dictionary(uniqueKeysWithValues: elements))
    }
}

