#if os(macOS)
import AppKit
import Carbon
import Darwin
import Foundation
import LuminaIPC
import LuminaLayout

@main
struct AgentApp {
    static func main() {
        signal(SIGPIPE, SIG_IGN)
        let env = ProcessInfo.processInfo.environment
        var argv = Array(CommandLine.arguments.dropFirst())
        func takeFlag(_ flag: String) -> String? {
            guard let i = argv.firstIndex(of: flag), i + 1 < argv.count else { return nil }
            let value = argv[i + 1]
            argv.removeSubrange(i...i + 1)
            return value
        }
        let instance = UUID(uuidString: env["LUMINA_INSTANCE_ID"] ?? takeFlag("--instance-id") ?? "") ?? UUID()
        let socket = env["LUMINA_SOCKET"] ?? takeFlag("--socket") ?? argv.first
            ?? LuminaPaths.resolvedAgentSocketPath(
                uid: getuid(),
                tmpdir: FileManager.default.temporaryDirectory.path,
                instanceId: instance.uuidString,
                supportFallback: FileManager.default.homeDirectoryForCurrentUser.path
                    + "/Library/Application Support/Lumina"
            )
        let crash = env["LUMINA_CRASH_RECOVER"] == "1" || argv.contains("--crash-recover")
        let launchApps = env["LUMINA_LAUNCH_APPS"] == "1" || argv.contains("--launch-apps")
        let display = env["LUMINA_DISPLAY_UUID"] ?? takeFlag("--display")
        let log = LuminaLog(category: .agent, fileURL: LuminaLog.defaultFileURL())
        log.info("lumina-agent boot instance=\(instance)")
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        let runtime = AgentRuntime(
            instanceId: instance,
            socketPath: socket,
            displayUUID: display,
            crashRecover: crash,
            runLaunchApps: launchApps,
            log: log
        )
        signal(SIGTERM, SIG_IGN)
        let term = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
        term.setEventHandler {
            runtime.stop()
            NSApp.terminate(nil)
        }
        term.resume()
        Self.termSource = term
        runtime.start()
        app.run()
        runtime.stop()
    }

    nonisolated(unsafe) private static var termSource: DispatchSourceSignal?
}
#endif
