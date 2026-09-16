import Foundation
#if canImport(TOMLDecoder)
import TOMLDecoder
#endif

public struct Chord: Equatable, Hashable, Sendable {
    public var keyName: String
    public var shift: Bool
    public var keyCode: UInt32

    public init(keyName: String, shift: Bool, keyCode: UInt32) {
        self.keyName = keyName
        self.shift = shift
        self.keyCode = keyCode
    }

    public var description: String {
        shift ? "alt-shift-\(keyName)" : "alt-\(keyName)"
    }
}

public enum BoundCommand: Equatable, Sendable {
    case focus(Direction)
    case swap(Direction)
    case resize(ResizeDelta)
    case workspace(Int)
    case workspacePrev
    case workspaceNext
    case moveNodeToWorkspace(Int)
    case balance
    case fullscreenLumina
    case fullscreenNative
    case floatToggle
    case close

    public var commandString: String {
        switch self {
        case .focus(let d): return "focus \(d.rawValue)"
        case .swap(let d): return "swap \(d.rawValue)"
        case .resize(.grow): return "resize grow"
        case .resize(.shrink): return "resize shrink"
        case .workspace(let n): return "workspace \(n)"
        case .workspacePrev: return "workspace prev"
        case .workspaceNext: return "workspace next"
        case .moveNodeToWorkspace(let n): return "move-node-to-workspace \(n)"
        case .balance: return "balance"
        case .fullscreenLumina: return "fullscreen lumina"
        case .fullscreenNative: return "fullscreen native"
        case .floatToggle: return "float-toggle"
        case .close: return "close"
        }
    }

    public static func parse(_ string: String) -> BoundCommand? {
        let s = string.trimmingCharacters(in: .whitespaces)
        switch s {
        case "focus left": return .focus(.left)
        case "focus down": return .focus(.down)
        case "focus up": return .focus(.up)
        case "focus right": return .focus(.right)
        case "swap left": return .swap(.left)
        case "swap down": return .swap(.down)
        case "swap up": return .swap(.up)
        case "swap right": return .swap(.right)
        case "resize shrink": return .resize(.shrink)
        case "resize grow": return .resize(.grow)
        case "workspace prev": return .workspacePrev
        case "workspace next": return .workspaceNext
        case "balance": return .balance
        case "fullscreen lumina": return .fullscreenLumina
        case "fullscreen native": return .fullscreenNative
        case "float-toggle": return .floatToggle
        case "close": return .close
        default:
            if s.hasPrefix("workspace "), let n = Int(s.dropFirst("workspace ".count)), (1...10).contains(n) {
                return .workspace(n)
            }
            if s.hasPrefix("move-node-to-workspace "),
               let n = Int(s.dropFirst("move-node-to-workspace ".count)),
               (1...10).contains(n)
            {
                return .moveNodeToWorkspace(n)
            }
            return nil
        }
    }
}

public struct Binding: Equatable, Sendable {
    public var chord: Chord
    public var command: BoundCommand
    public init(chord: Chord, command: BoundCommand) {
        self.chord = chord
        self.command = command
    }
}

public struct Config: Equatable, Sendable {
    public var spaceCount: Int
    public var focusFollowsMouse: Bool
    public var launchTiling: LaunchTiling
    public var launchApps: [String]
    public var gaps: Gaps
    public var bindings: [Binding]
    public var windowRules: [WindowRule]
    public var unknownTopLevelKeys: [String]
    public var diagnostics: [String]

    public init(
        spaceCount: Int = 5,
        focusFollowsMouse: Bool = false,
        launchTiling: LaunchTiling = .zOrder,
        launchApps: [String] = [],
        gaps: Gaps = .default,
        bindings: [Binding] = [],
        windowRules: [WindowRule] = [],
        unknownTopLevelKeys: [String] = [],
        diagnostics: [String] = []
    ) {
        self.spaceCount = spaceCount
        self.focusFollowsMouse = focusFollowsMouse
        self.launchTiling = launchTiling
        self.launchApps = launchApps
        self.gaps = gaps
        self.bindings = bindings
        self.windowRules = windowRules
        self.unknownTopLevelKeys = unknownTopLevelKeys
        self.diagnostics = diagnostics
    }
}

public struct ConfigError: Error, Equatable, CustomStringConvertible {
    public var message: String
    public init(_ message: String) { self.message = message }
    public var description: String { message }
}

public enum VirtualKey {
    /// Matches HIToolbox/Events.h `kVK_ANSI_*` (design §28).
    public static let table: [String: UInt32] = [
        "h": 0x04,
        "j": 0x26,
        "k": 0x28,
        "l": 0x25,
        "minus": 0x1B,
        "equal": 0x18,
        "1": 0x12,
        "2": 0x13,
        "3": 0x14,
        "4": 0x15,
        "5": 0x17,
        "6": 0x16,
        "7": 0x1A,
        "8": 0x1C,
        "9": 0x19,
        "0": 0x1D,
        "leftSquareBracket": 0x21,
        "rightSquareBracket": 0x1E,
        "b": 0x0B,
        "f": 0x03,
        "q": 0x0C,
        "space": 0x31,
    ]
}

public func parseChord(_ raw: String) -> Chord? {
    let parts = raw.split(separator: "-").map(String.init)
    guard let first = parts.first, first == "alt" else { return nil }
    var shift = false
    var key: String?
    for part in parts.dropFirst() {
        if part == "shift" {
            shift = true
        } else {
            key = part
        }
    }
    guard let key, let code = VirtualKey.table[key] else { return nil }
    return Chord(keyName: key, shift: shift, keyCode: code)
}

private struct RawConfig: Decodable {
    var spaceCount: Int?
    var focusFollowsMouse: Bool?
    var launchTiling: String?
    var launchApps: [String]?
    var gaps: RawGaps?
    var bindings: [String: String]?
    var windowRule: [RawWindowRule]?

    enum CodingKeys: String, CodingKey {
        case spaceCount = "space-count"
        case focusFollowsMouse = "focus-follows-mouse"
        case launchTiling = "launch-tiling"
        case launchApps = "launch-apps"
        case gaps
        case bindings
        case windowRule = "window-rule"
    }
}

private struct RawGaps: Decodable {
    var inner: Int?
    var outer: Int?
}

private struct RawWindowRule: Decodable {
    var appId: String?
    var titleRegex: String?
    var action: String?

    enum CodingKeys: String, CodingKey {
        case appId = "app-id"
        case titleRegex = "title-regex"
        case action
    }
}

public let knownTopLevelKeys: Set<String> = [
    "space-count",
    "focus-follows-mouse",
    "launch-tiling",
    "launch-apps",
    "gaps",
    "bindings",
    "window-rule",
]

public func parseConfig(text: String, defaults: Config? = nil) -> Result<Config, ConfigError> {
    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
    if trimmed.isEmpty {
        return .success(defaults ?? Config.bundledDefault)
    }
    let (collapsed, dupNotes) = collapseDuplicateBindingKeys(trimmed)
    #if canImport(TOMLDecoder)
    let decoder = TOMLDecoder()
    let raw: RawConfig
    do {
        raw = try decoder.decode(RawConfig.self, from: collapsed)
    } catch {
        return .failure(ConfigError("invalid TOML: \(error)"))
    }
    #else
    return .failure(ConfigError("TOMLDecoder is required"))
    #endif

    var diagnostics: [String] = dupNotes
    let unknown = unknownTopLevelKeys(in: collapsed)
    for key in unknown {
        diagnostics.append("unknown key: \(key)")
    }

    guard let spaceCount = raw.spaceCount, (1...10).contains(spaceCount) else {
        return .failure(ConfigError("space-count must be an integer 1...10"))
    }
    guard let inner = raw.gaps?.inner, (0...128).contains(inner) else {
        return .failure(ConfigError("gaps.inner must be an integer 0...128"))
    }
    guard let outer = raw.gaps?.outer, (0...128).contains(outer) else {
        return .failure(ConfigError("gaps.outer must be an integer 0...128"))
    }
    guard let ffm = raw.focusFollowsMouse else {
        return .failure(ConfigError("focus-follows-mouse must be a bool"))
    }
    guard let launchRaw = raw.launchTiling, let launch = LaunchTiling(rawValue: launchRaw) else {
        return .failure(ConfigError("launch-tiling must be z-order | float-existing | new-only"))
    }

    var bindings: [Binding] = []
    var seen: [Chord: Int] = [:]
    for (chordRaw, commandRaw) in raw.bindings ?? [:] {
        guard let chord = parseChord(chordRaw) else {
            return .failure(ConfigError("unknown chord: \(chordRaw)"))
        }
        guard let command = BoundCommand.parse(commandRaw) else {
            return .failure(ConfigError("unknown command string: \(commandRaw)"))
        }
        if let existing = seen[chord] {
            diagnostics.append("duplicate chord \(chord.description); last wins")
            bindings.remove(at: existing)
            // indexes after existing shift; rebuild map
            seen = [:]
            for (i, b) in bindings.enumerated() { seen[b.chord] = i }
        }
        seen[chord] = bindings.count
        bindings.append(Binding(chord: chord, command: command))
    }

    var rules: [WindowRule] = []
    for rule in raw.windowRule ?? [] {
        guard let appId = rule.appId, !appId.isEmpty else {
            diagnostics.append("window-rule missing app-id; skipped")
            continue
        }
        guard let actionRaw = rule.action, let action = WindowRuleAction(rawValue: actionRaw) else {
            diagnostics.append("window-rule bad action; skipped")
            continue
        }
        if let pattern = rule.titleRegex {
            do {
                _ = try NSRegularExpression(pattern: pattern)
            } catch {
                diagnostics.append("bad title-regex \(pattern); skipped rule")
                continue
            }
        }
        rules.append(WindowRule(appId: appId, titleRegex: rule.titleRegex, action: action))
    }

    return .success(
        Config(
            spaceCount: spaceCount,
            focusFollowsMouse: ffm,
            launchTiling: launch,
            launchApps: raw.launchApps ?? [],
            gaps: Gaps(inner: inner, outer: outer),
            bindings: bindings,
            windowRules: rules,
            unknownTopLevelKeys: unknown,
            diagnostics: diagnostics
        )
    )
}

public func loadOrDefault(text: String?, bundledDefault: String = Config.bundledDefaultTOML) -> Config {
    guard let text, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
        switch parseConfig(text: bundledDefault) {
        case .success(let c): return c
        case .failure: return Config.bundledDefault
        }
    }
    switch parseConfig(text: text) {
    case .success(let c): return c
    case .failure: return loadOrDefault(text: nil, bundledDefault: bundledDefault)
    }
}

public func applyReload(current: Config, newText: String) -> (config: Config, error: String?) {
    switch parseConfig(text: newText) {
    case .success(let c):
        return (c, nil)
    case .failure(let e):
        return (current, e.message)
    }
}

public func resolveWorkspace(id: Int, count: Int) -> SpaceId? {
    guard let space = SpaceId.make(id), id <= count else { return nil }
    return space
}

extension Session {
    /// Dropped spaces pour onto space 1. If focusedSpace dropped, focusedSpace = 1.
    public func applySpaceCount(_ newCount: Int, usableIsWide: Bool = true) -> Session {
        let count = min(max(newCount, 1), 10)
        var session = self
        let oldCount = session.spaceCount
        if count == oldCount {
            return session
        }
        if count > oldCount {
            for i in (oldCount + 1)...count {
                let id = SpaceId.require(i)
                if session.spaces[id] == nil {
                    session.spaces[id] = Space(id: id)
                }
            }
            session.spaceCount = count
            return session
        }
        let dest = SpaceId.require(1)
        for i in stride(from: oldCount, through: count + 1, by: -1) {
            let dropped = SpaceId.require(i)
            guard let space = session.spaces[dropped] else { continue }
            let tiled = collectTiledFrontToBack(space)
            let floaters = space.floating
            for leaf in tiled {
                if let w = leaf.leaf {
                    session = session.insertSpiral(space: dest, newLeaf: w, usableIsWide: usableIsWide)
                }
            }
            if var destSpace = session.spaces[dest] {
                destSpace.floating.append(contentsOf: floaters)
                session.spaces[dest] = destSpace
            }
            session.spaces[dropped] = nil
        }
        session.spaceCount = count
        if session.focusedSpace.raw > count {
            session.focusedSpace = dest
        }
        session.spaces = session.spaces.filter { $0.key.raw <= count }
        return session
    }
}

private func collectTiledFrontToBack(_ space: Space) -> [Node] {
    guard let root = space.root else { return [] }
    var out: [Node] = []
    func walk(_ id: NodeId) {
        guard let node = space.nodes[id] else { return }
        if node.isLeaf {
            out.append(node)
        } else {
            for c in node.children { walk(c) }
        }
    }
    walk(root)
    return out
}

/// TOML tables reject duplicate keys. Collapse `[bindings]` so the last
/// assignment of a chord wins, matching the product rule.
func collapseDuplicateBindingKeys(_ text: String) -> (String, [String]) {
    var notes: [String] = []
    var lines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
    var inBindings = false
    var lastIndex: [String: Int] = [:]
    for (i, line) in lines.enumerated() {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        if trimmed.hasPrefix("[[") {
            inBindings = false
            continue
        }
        if trimmed.hasPrefix("[") {
            inBindings = trimmed == "[bindings]"
            continue
        }
        guard inBindings, !trimmed.isEmpty, !trimmed.hasPrefix("#") else { continue }
        guard let eq = trimmed.firstIndex(of: "=") else { continue }
        let key = String(trimmed[..<eq]).trimmingCharacters(in: .whitespaces)
        if let prev = lastIndex[key] {
            notes.append("duplicate chord \(key); last wins")
            lines[prev] = ""
        }
        lastIndex[key] = i
    }
    return (lines.joined(separator: "\n"), notes)
}

func unknownTopLevelKeys(in text: String) -> [String] {
    #if canImport(TOMLDecoder)
    struct AnyTop: Decodable {
        var keys: [String] = []
        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: DynamicKey.self)
            keys = container.allKeys.map(\.stringValue)
        }
    }
    struct DynamicKey: CodingKey {
        var stringValue: String
        init?(stringValue: String) { self.stringValue = stringValue }
        var intValue: Int? { nil }
        init?(intValue: Int) { nil }
    }
    if let decoded = try? TOMLDecoder().decode(AnyTop.self, from: text) {
        return decoded.keys.filter { !knownTopLevelKeys.contains($0) }.sorted()
    }
    #endif
    return []
}

extension Config {
    public static let bundledDefaultTOML: String = """
    space-count = 5
    focus-follows-mouse = false
    # z-order, float-existing, or new-only
    launch-tiling = "z-order"
    launch-apps = []                       # e.g. ["com.apple.Terminal"]

    [gaps]
    inner = 8
    outer = 8

    [bindings]
    alt-h = "focus left"
    alt-j = "focus down"
    alt-k = "focus up"
    alt-l = "focus right"
    alt-shift-h = "swap left"
    alt-shift-j = "swap down"
    alt-shift-k = "swap up"
    alt-shift-l = "swap right"
    alt-minus = "resize shrink"
    alt-equal = "resize grow"
    alt-leftSquareBracket = "workspace prev"
    alt-rightSquareBracket = "workspace next"
    alt-b = "balance"
    alt-f = "fullscreen lumina"
    alt-shift-f = "fullscreen native"
    alt-space = "float-toggle"
    alt-q = "close"
    alt-1 = "workspace 1"
    alt-2 = "workspace 2"
    alt-3 = "workspace 3"
    alt-4 = "workspace 4"
    alt-5 = "workspace 5"
    alt-6 = "workspace 6"
    alt-7 = "workspace 7"
    alt-8 = "workspace 8"
    alt-9 = "workspace 9"
    alt-0 = "workspace 10"
    alt-shift-1 = "move-node-to-workspace 1"
    alt-shift-2 = "move-node-to-workspace 2"
    alt-shift-3 = "move-node-to-workspace 3"
    alt-shift-4 = "move-node-to-workspace 4"
    alt-shift-5 = "move-node-to-workspace 5"
    alt-shift-6 = "move-node-to-workspace 6"
    alt-shift-7 = "move-node-to-workspace 7"
    alt-shift-8 = "move-node-to-workspace 8"
    alt-shift-9 = "move-node-to-workspace 9"
    alt-shift-0 = "move-node-to-workspace 10"

    [[window-rule]]
    app-id = "com.apple.systempreferences"
    action = "float"

    [[window-rule]]
    app-id = "com.apple.Preferences"
    action = "float"
    """

    public static var bundledDefault: Config {
        switch parseConfig(text: bundledDefaultTOML) {
        case .success(let c): return c
        case .failure: return Config()
        }
    }
}
