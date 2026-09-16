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
        let instance = UUID(uuidString: env["LUMINA_INSTANCE_ID"] ?? "") ?? UUID()
        let socket = env["LUMINA_SOCKET"] ?? CommandLine.arguments.dropFirst().first
            ?? LuminaPaths.agentSocketPath(
                uid: getuid(),
                tmpdir: FileManager.default.temporaryDirectory.path,
                instanceId: instance.uuidString,
                supportFallback: nil
            ).primary
        let crash = env["LUMINA_CRASH_RECOVER"] == "1" || CommandLine.arguments.contains("--crash-recover")
        let launchApps = env["LUMINA_LAUNCH_APPS"] == "1"
        let display = env["LUMINA_DISPLAY_UUID"]
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
        signal(SIGTERM) { _ in
            DispatchQueue.main.async { NSApp.terminate(nil) }
        }
        runtime.start()
        app.run()
        runtime.stop()
    }
}
#endif
