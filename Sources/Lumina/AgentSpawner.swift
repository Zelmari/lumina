#if os(macOS)
import Darwin
import Foundation
import LuminaIPC

private typealias DisclaimResponsibility = @convention(c) (UnsafeMutablePointer<posix_spawnattr_t?>, Int32) -> Int32

/// `RTLD_DEFAULT` is `((void *)-2)`, which Swift cannot import.
nonisolated(unsafe) private let dlDefault = UnsafeMutableRawPointer(bitPattern: -2)

final class AgentSpawner: @unchecked Sendable {
    var quitPids: Set<pid_t> = []
    private let log = LuminaLog(category: .extra, fileURL: LuminaLog.defaultFileURL())
    private var loggedMissingDisclaim = false
    private lazy var disclaim: DisclaimResponsibility? = {
        guard let dlDefault, let sym = dlsym(dlDefault, "responsibility_spawnattrs_setdisclaim") else { return nil }
        return unsafeBitCast(sym, to: DisclaimResponsibility.self)
    }()

    func spawn(
        instanceId: UUID,
        socket: String,
        displayUUID: String?,
        crashRecover: Bool,
        runLaunchApps: Bool,
        unstashFrom: String? = nil,
        completion: @escaping @Sendable (pid_t?) -> Void
    ) {
        var env = ProcessInfo.processInfo.environment
        env["LUMINA_INSTANCE_ID"] = instanceId.uuidString
        env["LUMINA_SOCKET"] = socket
        env["LUMINA_CRASH_RECOVER"] = crashRecover ? "1" : "0"
        env["LUMINA_LAUNCH_APPS"] = runLaunchApps ? "1" : "0"
        if let unstashFrom { env["LUMINA_UNSTASH_FROM"] = unstashFrom }
        if let displayUUID { env["LUMINA_DISPLAY_UUID"] = displayUUID }

        var arguments = [
            "--instance-id", instanceId.uuidString,
            "--socket", socket,
        ]
        if let displayUUID {
            arguments += ["--display", displayUUID]
        }
        if crashRecover { arguments.append("--crash-recover") }
        if runLaunchApps { arguments.append("--launch-apps") }

        guard let exe = Self.nestedAgentExecutable() else {
            log.error("agent app missing")
            completion(nil)
            return
        }

        log.info("launching agent \(exe.path)")
        let pid = posixSpawn(exe: exe.path, arguments: arguments, env: env)
        if let pid, pid > 0 {
            log.info("spawned agent pid=\(pid)")
            completion(pid)
        } else {
            log.error("posix_spawn failed exe=\(exe.path)")
            completion(nil)
        }
    }

    func watch(pid: pid_t, onExit: @escaping () -> Void) {
        let src = DispatchSource.makeProcessSource(identifier: pid, eventMask: .exit, queue: .main)
        src.setEventHandler {
            src.cancel()
            onExit()
        }
        src.resume()
    }

    static func nestedAgentAppURL() -> URL? {
        let names = ["Lumina Agent.app", "lumina-agent.app"]
        for name in names {
            let nested = Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/\(name)")
            let exe = nested.appendingPathComponent("Contents/MacOS/lumina-agent")
            if FileManager.default.isExecutableFile(atPath: exe.path) { return nested }
        }
        return nil
    }

    static func nestedAgentExecutable() -> URL? {
        nestedAgentAppURL()?.appendingPathComponent("Contents/MacOS/lumina-agent")
    }

    private func posixSpawn(exe: String, arguments: [String], env: [String: String]) -> pid_t? {
        let argvStrings = [exe] + arguments
        let envStrings = env.map { "\($0.key)=\($0.value)" }
        var cArgv = argvStrings.map { strdup($0) }
        cArgv.append(nil)
        var cEnv = envStrings.map { strdup($0) }
        cEnv.append(nil)
        defer {
            cArgv.dropLast().forEach { free($0) }
            cEnv.dropLast().forEach { free($0) }
        }

        var attr: posix_spawnattr_t?
        posix_spawnattr_init(&attr)
        defer { posix_spawnattr_destroy(&attr) }

        // Detach so extra quit does not kill the agent (DESIGN §3 / BP-31).
        let setsid: Int16 = 0x0400
        posix_spawnattr_setflags(&attr, setsid)
        // Child must own TCC, otherwise AXIsProcessTrusted follows the extra.
        if let disclaim {
            _ = disclaim(&attr, 1)
        } else if !loggedMissingDisclaim {
            loggedMissingDisclaim = true
            log.info("responsibility_spawnattrs_setdisclaim missing; AX identity may follow the extra")
        }

        var pid: pid_t = 0
        let rc = cArgv.withUnsafeMutableBufferPointer { argvBuf in
            cEnv.withUnsafeMutableBufferPointer { envBuf in
                posix_spawn(&pid, exe, nil, &attr, argvBuf.baseAddress, envBuf.baseAddress)
            }
        }
        if rc != 0 {
            log.error("posix_spawn errno=\(rc) \(String(cString: strerror(rc)))")
            return nil
        }
        return pid
    }
}
#endif
