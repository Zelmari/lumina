#if os(macOS)
import Darwin
import Foundation
import LuminaIPC

final class AgentSpawner {
    var quitPids: Set<pid_t> = []

    func spawn(
        instanceId: UUID,
        socket: String,
        displayUUID: String?,
        crashRecover: Bool,
        runLaunchApps: Bool
    ) -> pid_t? {
        let agent = Self.agentURL()
        guard let agent else { return nil }
        var pid: pid_t = 0
        var attr = posix_spawnattr_t(nil as OpaquePointer?)
        posix_spawnattr_init(&attr)
        posix_spawnattr_setflags(&attr, Int16(0x0400)) // POSIX_SPAWN_SETSID
        if let disclaim = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "responsibility_spawnattrs_setdisclaim") {
            typealias Fn = @convention(c) (UnsafeMutablePointer<posix_spawnattr_t?>, Int32) -> Int32
            let fn = unsafeBitCast(disclaim, to: Fn.self)
            _ = fn(&attr, 1)
        }
        var env: [String] = []
        if let e = environ {
            var i = 0
            while let p = e[i] {
                env.append(String(cString: p))
                i += 1
            }
        }
        env.append("LUMINA_INSTANCE_ID=\(instanceId.uuidString)")
        env.append("LUMINA_SOCKET=\(socket)")
        env.append("LUMINA_CRASH_RECOVER=\(crashRecover ? "1" : "0")")
        env.append("LUMINA_LAUNCH_APPS=\(runLaunchApps ? "1" : "0")")
        if let displayUUID { env.append("LUMINA_DISPLAY_UUID=\(displayUUID)") }
        let argv = [agent.path, crashRecover ? "--crash-recover" : nil].compactMap { $0 }
        let cArgv = argv.map { strdup($0) } + [nil]
        let cEnv = env.map { strdup($0) } + [nil]
        let err = posix_spawn(&pid, agent.path, nil, &attr, cArgv, cEnv)
        for p in cArgv { if let p { free(p) } }
        for p in cEnv { if let p { free(p) } }
        posix_spawnattr_destroy(&attr)
        guard err == 0 else { return nil }
        return pid
    }

    func watch(pid: pid_t, onExit: @escaping () -> Void) {
        let src = DispatchSource.makeProcessSource(identifier: pid, eventMask: .exit, queue: .main)
        src.setEventHandler {
            src.cancel()
            onExit()
        }
        src.resume()
    }

    static func agentURL() -> URL? {
        let bundle = Bundle.main.bundleURL
        let nested = bundle.appendingPathComponent("Contents/Helpers/lumina-agent.app/Contents/MacOS/lumina-agent")
        if FileManager.default.isExecutableFile(atPath: nested.path) { return nested }
        let sibling = bundle.deletingLastPathComponent().appendingPathComponent("lumina-agent")
        if FileManager.default.isExecutableFile(atPath: sibling.path) { return sibling }
        return nil
    }
}
#endif
