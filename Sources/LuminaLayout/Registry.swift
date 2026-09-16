import Foundation

public struct InstanceRecord: Equatable, Sendable, Codable {
    public var instanceId: UUID
    public var pid: Int32
    public var skylightSpaceId: UInt64?
    public var displayUUID: String
    public var socket: String

    public init(
        instanceId: UUID,
        pid: Int32,
        skylightSpaceId: UInt64? = nil,
        displayUUID: String,
        socket: String
    ) {
        self.instanceId = instanceId
        self.pid = pid
        self.skylightSpaceId = skylightSpaceId
        self.displayUUID = displayUUID
        self.socket = socket
    }
}

public struct InstanceRegistry: Equatable, Sendable, Codable {
    public var bootSessionUUID: String
    public var lastCurrentInstanceId: UUID?
    public var agents: [InstanceRecord]

    public init(
        bootSessionUUID: String,
        lastCurrentInstanceId: UUID? = nil,
        agents: [InstanceRecord] = []
    ) {
        self.bootSessionUUID = bootSessionUUID
        self.lastCurrentInstanceId = lastCurrentInstanceId
        self.agents = agents
    }

    public static func decode(_ data: Data) throws -> InstanceRegistry {
        try JSONDecoder().decode(InstanceRegistry.self, from: data)
    }

    public static func encode(_ registry: InstanceRegistry) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(registry)
    }
}

public enum ExtraLaunchDecision: Equatable, Sendable {
    case reattach
    case freshStart
}

public func extraLaunchDecision(
    registryBootUUID: String?,
    kernBootUUID: String,
    livePids: [Int32]
) -> ExtraLaunchDecision {
    if registryBootUUID != kernBootUUID { return .freshStart }
    if livePids.isEmpty { return .freshStart }
    return .reattach
}

public enum PidDeathAction: Equatable, Sendable {
    case restartCrashRecover
    case removeNoRestart
}

public func pidDeathAction(followedQuit: Bool) -> PidDeathAction {
    followedQuit ? .removeNoRestart : .restartCrashRecover
}

public func skipAlreadyRunning(bundleId: String, running: [String]) -> Bool {
    running.contains(bundleId)
}

public struct AgentStatus: Equatable, Sendable, Codable {
    public var secureInput: Bool
    public var axTrusted: Bool
    public var configError: String?
    public var paused: Bool
    public var instanceId: String?
    public var space: Int?
    public var displayGone: Bool
    public var hotkeyError: String?
    public var spaceCount: Int?
    public var isCurrent: Bool
    public var hasOnScreenIncludingSlivers: Bool
    public var skylightSpaceId: UInt64?

    public init(
        secureInput: Bool = false,
        axTrusted: Bool = false,
        configError: String? = nil,
        paused: Bool = false,
        instanceId: String? = nil,
        space: Int? = nil,
        displayGone: Bool = false,
        hotkeyError: String? = nil,
        spaceCount: Int? = nil,
        isCurrent: Bool = false,
        hasOnScreenIncludingSlivers: Bool = false,
        skylightSpaceId: UInt64? = nil
    ) {
        self.secureInput = secureInput
        self.axTrusted = axTrusted
        self.configError = configError
        self.paused = paused
        self.instanceId = instanceId
        self.space = space
        self.displayGone = displayGone
        self.hotkeyError = hotkeyError
        self.spaceCount = spaceCount
        self.isCurrent = isCurrent
        self.hasOnScreenIncludingSlivers = hasOnScreenIncludingSlivers
        self.skylightSpaceId = skylightSpaceId
    }
}

public enum ExtraWarning: Equatable, Sendable {
    case none
    case secureInput
    case axDenied
    case configInvalid
    case displayGone
    case hotkeyFailed

    public var tooltip: String? {
        switch self {
        case .none: return nil
        case .secureInput: return "hotkeys blocked: Secure Input"
        case .axDenied: return "Accessibility is required for Lumina Agent"
        case .configInvalid: return "config error: keeping last good lumina.toml"
        case .displayGone: return "display gone"
        case .hotkeyFailed: return "failed to register Option hotkeys"
        }
    }
}

public func extraWarning(status: AgentStatus) -> ExtraWarning {
    if !status.axTrusted { return .axDenied }
    if status.displayGone { return .displayGone }
    if status.secureInput { return .secureInput }
    if status.configError != nil { return .configInvalid }
    if status.hotkeyError != nil { return .hotkeyFailed }
    return .none
}
