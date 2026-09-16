import Foundation

public enum CLIArgs {
    public static func parse(_ argv: [String]) -> IPCRequest? {
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
                return IPCRequest(id: id, cmd: "workspace", args: ["id": .int(n)])
            }
            return IPCRequest(id: id, cmd: "workspace")
        case "move-node-to-workspace":
            if args.count >= 2, let n = Int(args[1]) {
                return IPCRequest(id: id, cmd: "move-node-to-workspace", args: ["id": .int(n)])
            }
            return IPCRequest(id: id, cmd: "move-node-to-workspace")
        case "fullscreen":
            if args.count >= 2 {
                return IPCRequest(id: id, cmd: "fullscreen", args: ["mode": .string(args[1])])
            }
            return IPCRequest(id: id, cmd: "fullscreen")
        case "float-toggle", "balance", "close", "pause", "resume", "reload", "quit",
             "list-windows", "list-workspaces", "status",
             "start", "quit-all", "open-config", "current-token":
            return IPCRequest(id: id, cmd: head)
        case "debug":
            return IPCRequest(id: id, cmd: "debug")
        default:
            return IPCRequest(id: id, cmd: head)
        }
    }

    public static func isExtraCommand(_ cmd: String) -> Bool {
        ["start", "quit-all", "open-config", "current-token"].contains(cmd)
    }
}
