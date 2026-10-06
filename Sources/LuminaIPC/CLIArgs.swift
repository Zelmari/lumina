import Foundation

public enum CLIEarlyExit: Equatable, Sendable {
    case version
    case help
    case debug
}

public enum CLIArgs {
    public static let usage = """
    usage: lumina <command> [args]

    focus left|down|up|right     focus the neighbouring window
    swap left|down|up|right      swap the focused window with a neighbour
    resize grow|shrink           resize the focused tile
    float-toggle                 retile a floater / float a tile
    balance                      equalize the split weights
    fullscreen lumina|native     enter/exit fullscreen
    close                        close the focused window
    workspace 1..10|prev|next    switch workspace
    move-node-to-workspace 1..10 move the focused window and follow
    list-windows                 print managed windows as JSON
    list-workspaces              print workspaces as JSON
    verify                       check tiling invariants; exit 1 on issues
    status                       print agent status as JSON
    ping                         one IPC round trip; prints pong JSON
    bench [--count N] [--warmup W] [--max-p95-ms X]
                                 measure IPC round-trip latency
    debug-windows                write a debug dump
    debug-ax <pid>               dump an app's AX attributes as JSON
    reload                       reload ~/.config/lumina/lumina.toml
    pause | resume               stop / resume managing windows
    start                        start Lumina on this Space
    quit | exit | quit-all       quit Lumina and untile every window
    open-config                  open the config file
    grant-accessibility          re-show the Accessibility grant prompt
                                 (reset TCC first to get the prompt again)
    current-token                print this Space's instance id as JSON
    version                      print the version
    debug                        print LUMINA_DEBUG; does not contact the agent
    help                         print this help

    workspace 0 is workspace 10. move-node-to-workspace 0 is the same.
    Exit 0 is success. Exit 1 is a command error or verify issues.
    Exit 2 means no agent is running on this Space.
    Commands with nothing to return print ok. Errors go to stderr.
    """

    /// `version`, `help`, `-h`, and `--help` only when they are the command, so
    /// `lumina focus version` still reaches the agent. `debug` prints the
    /// env flag and exits; it is not an agent command.
    public static func earlyExit(_ argv: [String]) -> CLIEarlyExit? {
        guard let head = argv.dropFirst().first else { return nil }
        switch head {
        case "-h", "--help", "help": return .help
        case "version": return .version
        case "debug": return .debug
        default: return nil
        }
    }

    public static func parse(_ argv: [String]) -> IPCRequest? {
        if earlyExit(argv) != nil { return nil }
        let args = Array(argv.dropFirst())
        guard let head = args.first else { return nil }
        let id = UUID().uuidString
        switch head {
        case "focus":
            guard args.count >= 2 else { return IPCRequest(id: id, cmd: "focus") }
            return IPCRequest(id: id, cmd: "focus", args: ["dir": .string(args[1])])
        case "swap":
            guard args.count >= 2 else { return IPCRequest(id: id, cmd: "swap") }
            return IPCRequest(id: id, cmd: "swap", args: ["dir": .string(args[1])])
        case "resize":
            guard args.count >= 2 else { return IPCRequest(id: id, cmd: "resize") }
            return IPCRequest(id: id, cmd: "resize", args: ["delta": .string(args[1])])
        case "workspace":
            if args.count >= 2, args[1] == "prev" || args[1] == "next" {
                return IPCRequest(id: id, cmd: "workspace", args: ["id": .string(args[1])])
            }
            if args.count >= 2, let n = Int(args[1]) {
                return IPCRequest(id: id, cmd: "workspace", args: ["id": .int(normalizeWorkspaceId(n))])
            }
            return IPCRequest(id: id, cmd: "workspace")
        case "move-node-to-workspace":
            if args.count >= 2, let n = Int(args[1]) {
                return IPCRequest(id: id, cmd: "move-node-to-workspace", args: ["id": .int(normalizeWorkspaceId(n))])
            }
            return IPCRequest(id: id, cmd: "move-node-to-workspace")
        case "fullscreen":
            if args.count >= 2 {
                return IPCRequest(id: id, cmd: "fullscreen", args: ["mode": .string(args[1])])
            }
            return IPCRequest(id: id, cmd: "fullscreen")
        case "debug-ax":
            guard args.count >= 2, let pid = Int(args[1]) else {
                return IPCRequest(id: id, cmd: "debug-ax")
            }
            return IPCRequest(id: id, cmd: "debug-ax", args: ["pid": .int(pid)])
        case "float-toggle", "balance", "close", "pause", "resume", "reload",
             "list-windows", "list-workspaces", "verify", "status", "debug-windows",
             "ping", "start", "quit-all", "open-config", "current-token", "grant-accessibility":
            return IPCRequest(id: id, cmd: head)
        case "quit", "exit":
            // `quit` exits Lumina entirely, like Hyprland's `exit`. Quitting
            // only the agent used to be respawned as a crash.
            return IPCRequest(id: id, cmd: "quit-all")
        default:
            return nil
        }
    }

    public static func isExtraCommand(_ cmd: String) -> Bool {
        ["start", "quit", "exit", "quit-all", "open-config", "current-token", "grant-accessibility"].contains(cmd)
    }

    /// Options for `lumina bench`. Kept in LuminaIPC so the parsing rules are
    /// covered by `swift test` on Linux even though the CLI itself is macOS-only.
    public struct BenchOptions: Equatable, Sendable {
        public var count: Int
        public var warmup: Int
        public var maxP95Ms: Double?

        public init(count: Int = 50, warmup: Int = 5, maxP95Ms: Double? = nil) {
            self.count = count
            self.warmup = warmup
            self.maxP95Ms = maxP95Ms
        }
    }

    /// Parse `lumina bench [--count N] [--warmup W] [--max-p95-ms X]`.
    /// Returns nil for a malformed or unknown flag so the caller can print usage.
    public static func parseBench(_ argv: [String]) -> BenchOptions? {
        var options = BenchOptions()
        var i = 2
        while i < argv.count {
            switch argv[i] {
            case "--count":
                guard i + 1 < argv.count, let n = Int(argv[i + 1]), n > 0, n <= 100_000 else { return nil }
                options.count = n
                i += 2
            case "--warmup":
                guard i + 1 < argv.count, let n = Int(argv[i + 1]), n >= 0, n <= 10_000 else { return nil }
                options.warmup = n
                i += 2
            case "--max-p95-ms":
                guard i + 1 < argv.count, let v = Double(argv[i + 1]), v.isFinite, v > 0 else { return nil }
                options.maxP95Ms = v
                i += 2
            default:
                return nil
            }
        }
        return options
    }
}
