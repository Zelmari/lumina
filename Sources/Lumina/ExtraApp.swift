#if os(macOS)
import AppKit
import Darwin
import Foundation
import LuminaIPC
import LuminaLayout

@main
struct ExtraApp {
    static func main() {
        var uts = utsname()
        uname(&uts)
        let machine = withUnsafePointer(to: &uts.machine) { ptr in
            ptr.withMemoryRebound(to: CChar.self, capacity: 256) { String(cString: $0) }
        }
        if machine != "arm64" {
            let alert = NSAlert()
            alert.messageText = "Lumina requires Apple silicon"
            alert.informativeText = "Intel Macs are not supported in v1."
            alert.runModal()
            return
        }
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        let controller = ExtraController()
        controller.start()
        app.run()
    }
}

final class ExtraController: NSObject, @unchecked Sendable {
    let log = LuminaLog(category: .extra, fileURL: LuminaLog.defaultFileURL())
    let status = StatusItemController()
    let registry: RegistryStore
    let spawner = AgentSpawner()
    var menuServer: MenuSocketServer?
    var firstRun: FirstRunController?
    var launchAtLoginWanted = false
    let supportRoot: String
    let uid: uid_t
    let tmpdir: String

    override init() {
        uid = getuid()
        tmpdir = FileManager.default.temporaryDirectory.path
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        supportRoot = home + "/Library/Application Support/Lumina"
        registry = RegistryStore(path: LuminaPaths.instancesPath(supportRoot: supportRoot))
        super.init()
    }

    func start() {
        log.info("menu extra start")
        writeDefaultConfigIfNeeded()
        status.onDigit = { [weak self] n in self?.sendToCurrent(.workspace(id: n)) }
        status.onOpenConfig = { [weak self] in self?.openConfig() }
        status.onReload = { [weak self] in self?.sendToCurrent(.reload) }
        status.onPauseResume = { [weak self] in self?.togglePause() }
        status.onStart = { [weak self] in self?.startOnThisSpace() }
        status.onLaunchAtLogin = { [weak self] in self?.toggleLogin() }
        status.onQuitThisSpace = { [weak self] in self?.quitCurrent() }
        status.onQuitAll = { [weak self] in self?.quitAll() }
        status.install()
        let menuPath = LuminaPaths.resolvedMenuSocketPath(uid: uid, tmpdir: tmpdir)
        let server = MenuSocketServer(path: menuPath, log: log)
        server.onCommand = { [weak self] cmd, id in self?.handleExtra(cmd, id: id) ?? .failure(id: id, error: "gone") }
        try? server.start()
        menuServer = server
        bootRegistry()
        maybeFirstRun()
        Timer.scheduledTimer(withTimeInterval: 0.8, repeats: true) { [weak self] _ in
            self?.pollStatus()
        }
    }

    func writeDefaultConfigIfNeeded() {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let path = LuminaPaths.configPath(home: home)
        if !FileManager.default.fileExists(atPath: path) {
            let dir = (path as NSString).deletingLastPathComponent
            try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
            try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: dir)
            if let url = Bundle.module.url(forResource: "lumina", withExtension: "toml"),
               let data = try? Data(contentsOf: url)
            {
                try? data.write(to: URL(fileURLWithPath: path))
            } else {
                try? Config.bundledDefaultTOML.write(toFile: path, atomically: true, encoding: .utf8)
            }
        }
    }

    func bootRegistry() {
        let kern = kernBootUUID() ?? ""
        let current = registry.load()
        let live = current.agents.filter { kill($0.pid, 0) == 0 }
        switch extraLaunchDecision(registryBootUUID: current.bootSessionUUID.isEmpty ? nil : current.bootSessionUUID, kernBootUUID: kern, livePids: live.map(\.pid)) {
        case .freshStart:
            unstashAllSessions()
            registry.save(InstanceRegistry(bootSessionUUID: kern, lastCurrentInstanceId: nil, agents: []))
            startOnThisSpace(runLaunchApps: true)
        case .reattach:
            registry.save(InstanceRegistry(bootSessionUUID: kern, lastCurrentInstanceId: current.lastCurrentInstanceId, agents: live))
            for agent in live {
                spawner.watch(pid: agent.pid) { [weak self] in
                    self?.agentDied(agent)
                }
            }
            pollStatus()
        }
    }

    func startOnThisSpace(runLaunchApps: Bool = false) {
        let current = registry.load()
        let live = current.agents.filter { kill($0.pid, 0) == 0 }
        let presence: [AgentPresence] = live.map { rec in
            let status = fetchAgentStatus(socket: rec.socket)
            return AgentPresence(
                instanceId: rec.instanceId,
                isCurrent: status?.isCurrent ?? false,
                hasOnScreenIncludingSlivers: status?.hasOnScreenIncludingSlivers ?? false
            )
        }
        switch startAttachDecision(agents: presence, lastCurrent: current.lastCurrentInstanceId) {
        case .alreadyCurrent(let id):
            var next = current
            next.lastCurrentInstanceId = id
            registry.save(next)
            if let rec = live.first(where: { $0.instanceId == id }) {
                sendTo(instance: rec.instanceId, socket: rec.socket, .markCurrent)
            }
            pollStatus()
        case .attach(let id):
            var next = current
            next.lastCurrentInstanceId = id
            registry.save(next)
            if let rec = live.first(where: { $0.instanceId == id }) {
                sendTo(instance: rec.instanceId, socket: rec.socket, .markCurrent)
            }
            pollStatus()
        case .spawn:
            spawnAgent(runLaunchApps: runLaunchApps || current.agents.isEmpty)
        }
    }

    func spawnAgent(runLaunchApps: Bool) {
        let id = UUID()
        let socket = LuminaPaths.resolvedAgentSocketPath(
            uid: uid,
            tmpdir: tmpdir,
            instanceId: id.uuidString,
            supportFallback: supportRoot
        )
        let display = currentDisplayUUID()
        spawner.spawn(
            instanceId: id,
            socket: socket,
            displayUUID: display,
            crashRecover: false,
            runLaunchApps: runLaunchApps
        ) { [weak self] pid in
            guard let self else { return }
            guard let pid else {
                self.log.error("spawn failed")
                return
            }
            var next = self.registry.load()
            next.agents.append(InstanceRecord(instanceId: id, pid: pid, displayUUID: display ?? "", socket: socket))
            next.lastCurrentInstanceId = id
            self.registry.save(next)
            self.spawner.watch(pid: pid) { [weak self] in
                self?.agentDied(InstanceRecord(instanceId: id, pid: pid, displayUUID: display ?? "", socket: socket))
            }
            self.pollStatus()
        }
    }

    func currentDisplayUUID() -> String? {
        guard let screen = NSScreen.main ?? NSScreen.screens.first else { return nil }
        guard let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID else {
            return nil
        }
        let uuid = CGDisplayCreateUUIDFromDisplayID(number).takeRetainedValue()
        return CFUUIDCreateString(nil, uuid) as String
    }

    func fetchAgentStatus(socket: String) -> AgentStatus? {
        guard let resp = Client.request(socketPath: socket, cmd: "status", args: [:], role: .agent),
              let obj = resp.data?.object
        else { return nil }
        return AgentStatus(
            secureInput: obj["secureInput"]?.bool ?? false,
            axTrusted: obj["axTrusted"]?.bool ?? false,
            configError: obj["configError"]?.string,
            paused: obj["paused"]?.bool ?? false,
            instanceId: obj["instanceId"]?.string,
            space: obj["space"]?.int,
            displayGone: obj["displayGone"]?.bool ?? false,
            hotkeyError: obj["hotkeyError"]?.string,
            spaceCount: obj["spaceCount"]?.int,
            isCurrent: obj["isCurrent"]?.bool ?? false,
            hasOnScreenIncludingSlivers: obj["hasOnScreenIncludingSlivers"]?.bool ?? false,
            skylightSpaceId: obj["skylightSpaceId"]?.int.map { UInt64($0) }
        )
    }

    func agentDied(_ record: InstanceRecord) {
        let followedQuit = spawner.quitPids.contains(record.pid)
        switch pidDeathAction(followedQuit: followedQuit) {
        case .removeNoRestart:
            var reg = registry.load()
            reg.agents.removeAll { $0.instanceId == record.instanceId }
            if reg.lastCurrentInstanceId == record.instanceId { reg.lastCurrentInstanceId = nil }
            registry.save(reg)
        case .restartCrashRecover:
            spawner.spawn(
                instanceId: record.instanceId,
                socket: record.socket,
                displayUUID: record.displayUUID.isEmpty ? nil : record.displayUUID,
                crashRecover: true,
                runLaunchApps: false
            ) { [weak self] pid in
                guard let self, let pid else { return }
                var reg = self.registry.load()
                if let idx = reg.agents.firstIndex(where: { $0.instanceId == record.instanceId }) {
                    reg.agents[idx].pid = pid
                }
                self.registry.save(reg)
                self.spawner.watch(pid: pid) { [weak self] in
                    self?.agentDied(InstanceRecord(instanceId: record.instanceId, pid: pid, displayUUID: record.displayUUID, socket: record.socket))
                }
                self.pollStatus()
            }
            return
        }
        pollStatus()
    }

    func handleExtra(_ cmd: ExtraCmd, id: String) -> IPCResponse {
        switch cmd {
        case .currentToken:
            if let token = registry.load().lastCurrentInstanceId {
                return .success(id: id, data: .object(["instanceId": .string(token.uuidString)]))
            }
            return .failure(id: id, error: "no current instance")
        case .start:
            startOnThisSpace()
            return .success(id: id)
        case .quitAll:
            quitAll()
            return .success(id: id)
        case .openConfig:
            openConfig()
            return .success(id: id)
        case .status:
            return .success(id: id, data: currentStatusJSON())
        }
    }

    func sendToCurrent(_ cmd: AgentCmd) {
        guard let rec = currentRecord() else { return }
        sendTo(instance: rec.instanceId, socket: rec.socket, cmd)
    }

    func sendTo(instance: UUID, socket: String, _ cmd: AgentCmd) {
        _ = instance
        Client.request(socketPath: socket, cmd: agentCmdName(cmd), args: agentCmdArgs(cmd), role: .agent)
    }

    func currentRecord() -> InstanceRecord? {
        let reg = registry.load()
        if let id = reg.lastCurrentInstanceId {
            return reg.agents.first { $0.instanceId == id && kill($0.pid, 0) == 0 }
        }
        return reg.agents.first { kill($0.pid, 0) == 0 }
    }

    func pollStatus() {
        let reg = registry.load()
        let live = reg.agents.filter { kill($0.pid, 0) == 0 }
        var claimants: [(InstanceRecord, AgentStatus)] = []
        for rec in live {
            if let status = fetchAgentStatus(socket: rec.socket), status.isCurrent {
                claimants.append((rec, status))
            }
        }
        let winnerId = pickCurrentAgent(claimants: claimants.map(\.0.instanceId), lastCurrent: reg.lastCurrentInstanceId)
        if let winnerId, let pair = claimants.first(where: { $0.0.instanceId == winnerId }) {
            let rec = pair.0
            let st = pair.1
            if reg.lastCurrentInstanceId != rec.instanceId {
                var next = reg
                next.lastCurrentInstanceId = rec.instanceId
                if let sky = st.skylightSpaceId, let idx = next.agents.firstIndex(where: { $0.instanceId == rec.instanceId }) {
                    next.agents[idx].skylightSpaceId = sky
                }
                registry.save(next)
            }
            status.updateCurrent(
                spaceCount: st.spaceCount ?? 5,
                focused: st.space ?? 1,
                paused: st.paused,
                loginEnabled: LoginService.enabled,
                warning: extraWarning(status: st)
            )
        } else {
            status.updateEmpty(loginEnabled: LoginService.enabled)
        }
    }

    func currentStatusJSON() -> JSONValue {
        .object([
            "instanceId": currentRecord().map { .string($0.instanceId.uuidString) } ?? .null
        ])
    }

    func togglePause() {
        if status.pausedNow {
            sendToCurrent(.resume)
        } else {
            sendToCurrent(.pause)
        }
    }

    func quitCurrent() {
        guard let rec = currentRecord() else { return }
        spawner.quitPids.insert(rec.pid)
        sendTo(instance: rec.instanceId, socket: rec.socket, .quit)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            if kill(rec.pid, 0) == 0 { kill(rec.pid, SIGTERM) }
            var reg = self?.registry.load() ?? InstanceRegistry(bootSessionUUID: "")
            reg.agents.removeAll { $0.instanceId == rec.instanceId }
            self?.registry.save(reg)
            self?.pollStatus()
        }
    }

    func quitAll() {
        let agents = registry.load().agents
        for a in agents {
            spawner.quitPids.insert(a.pid)
            sendTo(instance: a.instanceId, socket: a.socket, .quit)
        }
        DispatchQueue.global().async { [weak self] in
            for a in agents {
                let deadline = Date().addingTimeInterval(0.5)
                while Date() < deadline, kill(a.pid, 0) == 0 { usleep(20000) }
                if kill(a.pid, 0) == 0 { kill(a.pid, SIGTERM) }
            }
            usleep(200_000)
            self?.registry.save(InstanceRegistry(bootSessionUUID: kernBootUUID() ?? "", agents: []))
            DispatchQueue.main.async { NSApp.terminate(nil) }
        }
    }

    func openConfig() {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let path = LuminaPaths.configPath(home: home)
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        proc.arguments = ["-t", path]
        try? proc.run()
        proc.waitUntilExit()
        if proc.terminationStatus != 0 {
            let p2 = Process()
            p2.executableURL = URL(fileURLWithPath: "/usr/bin/open")
            p2.arguments = ["-a", "TextEdit", path]
            try? p2.run()
        }
    }

    func toggleLogin() {
        #if os(macOS)
        if #available(macOS 13.0, *) {
            LoginService.toggle()
            pollStatus()
        }
        #endif
    }

    func maybeFirstRun() {
        let flag = supportRoot + "/first-run-done"
        firstRun = FirstRunController(flagPath: flag, extra: self)
        firstRun?.sheetIfNeeded()
    }

    func unstashAllSessions() {
        let root = supportRoot + "/spaces"
        guard let dirs = try? FileManager.default.contentsOfDirectory(atPath: root) else { return }
        for dir in dirs {
            let path = root + "/" + dir + "/session.json"
            guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
                  let file = try? SessionFile.decode(data)
            else { continue }
            _ = file.stash
            try? FileManager.default.removeItem(atPath: path)
        }
        try? FileManager.default.removeItem(atPath: registry.path)
    }
}

func agentCmdName(_ cmd: AgentCmd) -> String {
    switch cmd {
    case .workspace: return "workspace"
    case .workspacePrev: return "workspace"
    case .workspaceNext: return "workspace"
    case .moveNodeToWorkspace: return "move-node-to-workspace"
    case .focus: return "focus"
    case .swap: return "swap"
    case .resize: return "resize"
    case .balance: return "balance"
    case .floatToggle: return "float-toggle"
    case .fullscreen: return "fullscreen"
    case .close: return "close"
    case .pause: return "pause"
    case .resume: return "resume"
    case .reload: return "reload"
    case .quit: return "quit"
    case .listWindows: return "list-windows"
    case .listWorkspaces: return "list-workspaces"
    case .status: return "status"
    case .markCurrent: return "mark-current"
    }
}

func agentCmdArgs(_ cmd: AgentCmd) -> [String: JSONValue] {
    switch cmd {
    case .workspace(let id): return ["id": .int(id)]
    case .workspacePrev: return ["id": .string("prev")]
    case .workspaceNext: return ["id": .string("next")]
    case .moveNodeToWorkspace(let id): return ["id": .int(id)]
    case .focus(let d): return ["dir": .string(d.rawValue)]
    case .swap(let d): return ["dir": .string(d.rawValue)]
    case .resize(let d): return ["delta": .string(d.rawValue)]
    case .fullscreen(let m): return ["mode": .string(m.rawValue)]
    default: return [:]
    }
}
#endif
