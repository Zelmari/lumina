#if os(macOS)
import AppKit
import Darwin
import Foundation
import LuminaIPC
import LuminaLayout

@main
struct ExtraApp {
    static func main() {
        // A client that hangs up mid-response must not kill the supervisor.
        signal(SIGPIPE, SIG_IGN)
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
    var pendingUnstash: String?
    var spawnInFlight = false
    private var startRetryAttempts = 0
    /// Crash-restart backoff: consecutive fast crashes per instance.
    private var crashCounts: [UUID: Int] = [:]
    private var lastCrashAt: [UUID: Date] = [:]
    /// Strong refs so a `terminationHandler` survives until the child exits.
    private var openProcesses: [Process] = []
    private let statusQueue = DispatchQueue(label: "com.zelmari.lumina.extra.status")
    private var statusTimer: DispatchSourceTimer?
    private var statusTimerInterval: TimeInterval?
    /// `LoginService.enabled` is an SMAppService XPC query. It used to run on
    /// the main thread on every status tick; a short TTL still notices an
    /// external System Settings change.
    private var cachedLoginEnabled: Bool?
    private var cachedLoginEnabledAt = Date.distantPast
    /// True when at least one agent is pushing status over a subscription;
    /// the timer then only reconciles. Accessed on the status queue.
    var hasHealthySubscriptions = false
    /// Long-lived push connections, one per live registry record.
    var subscriptions: [UUID: AgentSubscription] = [:]
    /// Latest status per instance from either a push or a poll.
    var pushedStatus: [UUID: AgentStatus] = [:]
    var healthySubscriptionIds: Set<UUID> = []

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
        status.onDigit = { [weak self] n in self?.selectSpace(n) }
        status.onOpenConfig = { [weak self] in self?.openConfig() }
        status.onGrantAccessibility = { [weak self] in self?.grantAccessibility() }
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
        do {
            try server.start()
        } catch {
            // Without this socket every CLI command claims "menu extra not
            // running"; at least leave a trail in the log.
            log.error("menu socket bind failed path=\(menuPath) \(error)")
        }
        menuServer = server
        // Free OS events beat waiting up to a timer interval: poll on native
        // Space changes, app activation, and wake.
        let nc = NSWorkspace.shared.notificationCenter
        for name in [
            NSWorkspace.activeSpaceDidChangeNotification,
            NSWorkspace.didActivateApplicationNotification,
            NSWorkspace.didWakeNotification,
        ] {
            nc.addObserver(self, selector: #selector(workspaceChanged(_:)), name: name, object: nil)
        }
        bootRegistry()
        maybeFirstRun()
        // The interval is adaptive: short while an agent is current, long when
        // there is nothing to show. Armed on the status queue, which owns it.
        statusQueue.async { [weak self] in
            self?.scheduleStatusTimer(interval: 0.25, leeway: 0.1)
            self?.reconcileSubscriptions()
        }
    }

    /// (Re)arm the status poll. Status queue only; a no-op when the interval is
    /// unchanged so every poll does not rebuild the timer.
    func scheduleStatusTimer(interval: TimeInterval, leeway: TimeInterval) {
        guard statusTimerInterval != interval else { return }
        statusTimerInterval = interval
        statusTimer?.cancel()
        let timer = DispatchSource.makeTimerSource(queue: statusQueue)
        timer.schedule(
            deadline: .now() + interval,
            repeating: interval,
            leeway: .milliseconds(Int(leeway * 1000))
        )
        timer.setEventHandler { [weak self] in self?.pollStatusBody() }
        timer.resume()
        statusTimer = timer
    }

    func writeDefaultConfigIfNeeded() {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let path = LuminaPaths.configPath(home: home)
        if !FileManager.default.fileExists(atPath: path) {
            let dir = (path as NSString).deletingLastPathComponent
            try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
            try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: dir)
            // Do not touch Bundle.module here: the assembled app never
            // contains SwiftPM's resource bundle, and the generated accessor
            // fatalErrors, killing the extra on a fresh install.
            try? Config.bundledDefaultTOML.write(toFile: path, atomically: true, encoding: .utf8)
        }
    }

    func bootRegistry() {
        let kern = kernBootUUID() ?? ""
        let current = registry.load()
        let live = current.agents.filter { kill($0.pid, 0) == 0 }
        switch extraLaunchDecision(registryBootUUID: current.bootSessionUUID.isEmpty ? nil : current.bootSessionUUID, kernBootUUID: kern, livePids: live.map(\.pid)) {
        case .freshStart:
            pendingUnstash = unstashAllSessions()
            registry.save(InstanceRegistry(bootSessionUUID: kern, lastCurrentInstanceId: nil, agents: []))
            startOnThisSpace(runLaunchApps: true)
        case .reattach:
            registry.save(InstanceRegistry(bootSessionUUID: kern, lastCurrentInstanceId: current.lastCurrentInstanceId, agents: live))
            for agent in live {
                spawner.watch(pid: agent.pid) { [weak self] in
                    self?.agentDied(agent)
                }
            }
            startOnThisSpace()
        }
    }

    func startOnThisSpace(runLaunchApps: Bool = false) {
        guard !spawnInFlight else { return }
        let current = registry.load()
        let live = current.agents.filter { kill($0.pid, 0) == 0 }
        var starting = false
        var unresponsive: [InstanceRecord] = []
        let presence: [AgentPresence] = live.map { rec in
            let status = fetchAgentStatus(socket: rec.socket)
            if status == nil {
                starting = true
                unresponsive.append(rec)
            }
            return AgentPresence(
                instanceId: rec.instanceId,
                isCurrent: status?.isCurrent ?? false,
                hasOnScreenIncludingSlivers: status?.hasOnScreenIncludingSlivers ?? false
            )
        }
        let decision = startAttachDecision(agents: presence, lastCurrent: current.lastCurrentInstanceId)
        if case .spawn = decision, starting {
            if startRetryAttempts < 3 {
                // A live pid whose socket has not bound yet is starting, not absent.
                retryStartOnThisSpace(runLaunchApps: runLaunchApps)
                pollStatus()
                return
            }
            // Still no answer after the retry budget: the pid is wedged, and
            // refusing to spawn left Start permanently dead. Replace it.
            startRetryAttempts = 0
            log.error("agents did not answer status; replacing \(unresponsive.map(\.pid))")
            for rec in unresponsive {
                spawner.quitPids.insert(rec.pid)
                kill(rec.pid, SIGTERM)
            }
            registry.mutate { reg in
                for rec in unresponsive {
                    reg.agents.removeAll { $0.instanceId == rec.instanceId }
                }
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
                self?.spawnAgent(runLaunchApps: runLaunchApps)
            }
            pollStatus()
            return
        }
        startRetryAttempts = 0
        switch decision {
        case .alreadyCurrent(let id):
            registry.mutate { $0.lastCurrentInstanceId = id }
            claimCurrent(id, among: live)
            pollStatus()
        case .attach(let id):
            registry.mutate { $0.lastCurrentInstanceId = id }
            claimCurrent(id, among: live)
            pollStatus()
        case .spawn:
            spawnAgent(runLaunchApps: runLaunchApps || current.agents.isEmpty)
        }
    }

    private func retryStartOnThisSpace(runLaunchApps: Bool) {
        guard startRetryAttempts < 3 else { return }
        startRetryAttempts += 1
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in
            self?.startOnThisSpace(runLaunchApps: runLaunchApps)
        }
    }

    func spawnAgent(runLaunchApps: Bool) {
        guard !spawnInFlight else { return }
        spawnInFlight = true
        let id = UUID()
        let socket = LuminaPaths.resolvedAgentSocketPath(
            uid: uid,
            tmpdir: tmpdir,
            instanceId: id.uuidString,
            supportFallback: supportRoot
        )
        let display = currentDisplayUUID()
        let unstashFrom = pendingUnstash
        pendingUnstash = nil
        spawner.spawn(
            instanceId: id,
            socket: socket,
            displayUUID: display,
            crashRecover: false,
            runLaunchApps: runLaunchApps,
            unstashFrom: unstashFrom
        ) { [weak self] pid in
            guard let self else { return }
            self.spawnInFlight = false
            guard let pid else {
                self.log.error("spawn failed")
                // Keep the moved session files so a later spawn can still restore frames.
                if self.pendingUnstash == nil { self.pendingUnstash = unstashFrom }
                return
            }
            self.registry.mutate { reg in
                reg.agents.append(InstanceRecord(instanceId: id, pid: pid, displayUUID: display ?? "", socket: socket))
                reg.lastCurrentInstanceId = id
            }
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
        guard let resp = Client.request(
            socketPath: socket,
            cmd: "status",
            args: ["full": .bool(false)],
            role: .agent
        ),
            let obj = resp.data?.object
        else { return nil }
        return AgentStatus(json: obj)
    }

    func agentDied(_ record: InstanceRecord) {
        statusQueue.async { [weak self] in self?.dropSubscription(record.instanceId) }
        let followedQuit = spawner.quitPids.contains(record.pid)
        switch pidDeathAction(followedQuit: followedQuit) {
        case .removeNoRestart:
            registry.mutate { reg in
                reg.agents.removeAll { $0.instanceId == record.instanceId }
                if reg.lastCurrentInstanceId == record.instanceId { reg.lastCurrentInstanceId = nil }
            }
        case .restartCrashRecover:
            // A deterministic crash used to respawn forever. Count crashes
            // inside a minute and back off; give up after a few fast ones.
            let now = Date()
            let recent = lastCrashAt[record.instanceId].map { now.timeIntervalSince($0) < 60 } ?? false
            let count = recent ? (crashCounts[record.instanceId] ?? 1) + 1 : 1
            lastCrashAt[record.instanceId] = now
            crashCounts[record.instanceId] = count
            if count > 5 {
                log.error("agent \(record.instanceId) crashed \(count) times in a minute; not restarting")
                registry.mutate { reg in
                    reg.agents.removeAll { $0.instanceId == record.instanceId }
                    if reg.lastCurrentInstanceId == record.instanceId { reg.lastCurrentInstanceId = nil }
                }
                crashCounts[record.instanceId] = nil
                lastCrashAt[record.instanceId] = nil
                pollStatus()
                return
            }
            let delay = min(0.5 * pow(2.0, Double(count - 1)), 8.0)
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                self?.respawnCrashed(record)
            }
            return
        }
        pollStatus()
    }

    private func respawnCrashed(_ record: InstanceRecord) {
        spawner.spawn(
            instanceId: record.instanceId,
            socket: record.socket,
            displayUUID: record.displayUUID.isEmpty ? nil : record.displayUUID,
            crashRecover: true,
            runLaunchApps: false
        ) { [weak self] pid in
                guard let self else { return }
                guard let pid else {
                    self.log.error("crash respawn failed")
                    self.registry.mutate { reg in
                        reg.agents.removeAll { $0.instanceId == record.instanceId }
                        if reg.lastCurrentInstanceId == record.instanceId { reg.lastCurrentInstanceId = nil }
                    }
                    self.pollStatus()
                    return
                }
                self.registry.mutate { reg in
                    if let idx = reg.agents.firstIndex(where: { $0.instanceId == record.instanceId }) {
                        reg.agents[idx].pid = pid
                    }
                }
                self.spawner.watch(pid: pid) { [weak self] in
                    self?.agentDied(InstanceRecord(instanceId: record.instanceId, pid: pid, displayUUID: record.displayUUID, socket: record.socket))
                }
                self.pollStatus()
        }
    }

    func handleExtra(_ cmd: ExtraCmd, id: String) -> IPCResponse {
        if !Thread.isMainThread {
            return DispatchQueue.main.sync { self.handleExtra(cmd, id: id) }
        }
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
        case .grantAccessibility:
            grantAccessibility()
            return .success(id: id)
        case .status:
            return .success(id: id, data: currentStatusJSON())
        case .stripButtons:
            let buttons: [JSONValue] = status.digitClickFrames().map { item in
                .object([
                    "space": .int(item.space),
                    "x": .double(Double(item.rect.origin.x)),
                    "y": .double(Double(item.rect.origin.y)),
                    "w": .double(Double(item.rect.width)),
                    "h": .double(Double(item.rect.height)),
                ])
            }
            return .success(id: id, data: .object(["buttons": .array(buttons)]))
        }
    }

    /// Ask the agent to re-show the system Accessibility prompt (works after
    /// `tccutil reset Accessibility com.zelmari.lumina.agent`) and open the
    /// Accessibility pane as a fallback when the record already exists.
    func grantAccessibility() {
        if let rec = currentRecord() {
            sendTo(instance: rec.instanceId, socket: rec.socket, .accessibilityPrompt)
        } else {
            startOnThisSpace()
        }
        openAccessibilitySettings()
    }

    func openAccessibilitySettings() {
        let urls = [
            "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?Privacy_Accessibility",
            "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility",
        ]
        for s in urls {
            if let url = URL(string: s), NSWorkspace.shared.open(url) { return }
        }
    }

    /// Strip click: highlight the digit immediately, send the command and
    /// reconcile off the main thread. Blocking main on the switch delays the
    /// very update the user is waiting for.
    func selectSpace(_ n: Int) {
        status.showPendingSpace(n)
        statusQueue.async { [weak self] in
            self?.sendToCurrent(.workspace(id: n))
            self?.pollStatus()
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
        statusQueue.async { [weak self] in self?.pollStatusBody() }
    }

    /// Cached LoginService status; see `cachedLoginEnabled`.
    func loginEnabled() -> Bool {
        let now = Date()
        if let cachedLoginEnabled, now.timeIntervalSince(cachedLoginEnabledAt) < 30 {
            return cachedLoginEnabled
        }
        let value = LoginService.enabled
        cachedLoginEnabled = value
        cachedLoginEnabledAt = now
        return value
    }

    func pollStatusBody() {
        reconcileSubscriptions()
        let reg = registry.load()
        let live = reg.agents.filter { kill($0.pid, 0) == 0 }
        var statuses: [(InstanceRecord, AgentStatus)] = []
        for rec in live {
            if let status = fetchAgentStatus(socket: rec.socket) {
                pushedStatus[rec.instanceId] = status
                statuses.append((rec, status))
            }
        }
        applyStatuses(statuses, yieldLosers: true)
    }

    /// Subscribe to every live agent and drop subscriptions for dead ones.
    /// Status queue only.
    func reconcileSubscriptions() {
        let reg = registry.load()
        let live = reg.agents.filter { kill($0.pid, 0) == 0 }
        let liveIds = Set(live.map(\.instanceId))
        for (id, sub) in subscriptions where !liveIds.contains(id) {
            sub.stop()
            subscriptions[id] = nil
            pushedStatus[id] = nil
            healthySubscriptionIds.remove(id)
        }
        hasHealthySubscriptions = !healthySubscriptionIds.isEmpty
        for rec in live where subscriptions[rec.instanceId] == nil {
            let sub = AgentSubscription(instanceId: rec.instanceId, socketPath: rec.socket, log: log)
            sub.onStatus = { [weak self] status in
                self?.statusQueue.async { self?.receivePushedStatus(rec.instanceId, status) }
            }
            sub.onHealth = { [weak self] healthy in
                self?.statusQueue.async { self?.subscriptionHealthChanged(rec.instanceId, healthy: healthy) }
            }
            subscriptions[rec.instanceId] = sub
            sub.start()
        }
    }

    func dropSubscription(_ id: UUID) {
        subscriptions[id]?.stop()
        subscriptions[id] = nil
        pushedStatus[id] = nil
        healthySubscriptionIds.remove(id)
        hasHealthySubscriptions = !healthySubscriptionIds.isEmpty
    }

    func receivePushedStatus(_ id: UUID, _ status: AgentStatus) {
        pushedStatus[id] = status
        // Timestamped for the harness: proves the strip received the switch
        // and how long after the command it arrived.
        log.info("push space=\(status.space ?? -1) at=\(Int(Date().timeIntervalSince1970 * 1000))")
        let reg = registry.load()
        let live = reg.agents.filter { kill($0.pid, 0) == 0 }
        let statuses: [(InstanceRecord, AgentStatus)] = live.compactMap { rec in
            pushedStatus[rec.instanceId].map { (rec, $0) }
        }
        // Pushes are already authoritative; winners are not re-yielded.
        applyStatuses(statuses, yieldLosers: false)
    }

    func subscriptionHealthChanged(_ id: UUID, healthy: Bool) {
        if healthy {
            healthySubscriptionIds.insert(id)
        } else {
            healthySubscriptionIds.remove(id)
        }
        hasHealthySubscriptions = !healthySubscriptionIds.isEmpty
        // Re-arm the poll at the push-backed (or unpushed) cadence.
        pollStatus()
    }

    /// Shared by polled statuses and pushed snapshots: pick the current agent,
    /// persist it, and update the strip.
    func applyStatuses(_ statuses: [(InstanceRecord, AgentStatus)], yieldLosers: Bool) {
        let reg = registry.load()
        let claimants = statuses.filter { $0.1.isCurrent }
        let winnerId = pickCurrentAgent(claimants: claimants.map(\.0.instanceId), lastCurrent: reg.lastCurrentInstanceId)
        if let winnerId, let pair = claimants.first(where: { $0.0.instanceId == winnerId }) {
            let rec = pair.0
            let st = pair.1
            if reg.lastCurrentInstanceId != rec.instanceId {
                registry.mutate { next in
                    next.lastCurrentInstanceId = rec.instanceId
                    if let sky = st.skylightSpaceId,
                       let idx = next.agents.firstIndex(where: { $0.instanceId == rec.instanceId })
                    {
                        next.agents[idx].skylightSpaceId = sky
                    }
                }
            }
            // The strip shows at least five workspaces and grows with use;
            // fall back to the configured count for older agents.
            let spaceCount = st.visibleSpaceCount ?? st.spaceCount ?? 10
            let focused = st.space ?? 1
            let paused = st.paused
            let warning = extraWarning(status: st)
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.status.updateCurrent(
                    spaceCount: spaceCount,
                    focused: focused,
                    paused: paused,
                    loginEnabled: self.loginEnabled(),
                    warning: warning
                )
            }
            // Yield losers off the poll path: an unresponsive agent used to
            // hold up the strip and the next poll for up to its socket timeout.
            if yieldLosers {
                let losers = claimants.filter { $0.0.instanceId != rec.instanceId }
                if !losers.isEmpty {
                    DispatchQueue.global(qos: .utility).async { [weak self] in
                        for pair in losers {
                            // Only one agent may hold current; losers must
                            // drop hotkeys/frames.
                            self?.sendTo(instance: pair.0.instanceId, socket: pair.0.socket, .yield)
                        }
                    }
                }
            }
        } else {
            DispatchQueue.main.async { [weak self] in
                self?.status.updateEmpty(loginEnabled: self?.loginEnabled() ?? false)
            }
        }
        // With push subscriptions a slow safety-net poll is enough; without
        // them the strip is only as fresh as this timer.
        if winnerId != nil {
            let interval: TimeInterval = hasHealthySubscriptions ? 3.0 : 0.25
            scheduleStatusTimer(interval: interval, leeway: interval * 0.4)
        } else {
            scheduleStatusTimer(interval: 1.5, leeway: 0.5)
        }
    }

    func currentStatusJSON() -> JSONValue {
        .object([
            "instanceId": currentRecord().map { .string($0.instanceId.uuidString) } ?? .null
        ])
    }

    @objc func workspaceChanged(_ notification: Notification) {
        pollStatus()
    }

    func togglePause() {
        if status.pausedNow {
            sendToCurrent(.resume)
        } else {
            sendToCurrent(.pause)
        }
        // Don't wait for the next timer tick to show the pause state.
        pollStatus()
    }

    func quitCurrent() {
        guard let rec = currentRecord() else { return }
        spawner.quitPids.insert(rec.pid)
        sendTo(instance: rec.instanceId, socket: rec.socket, .quit)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            if kill(rec.pid, 0) == 0 { kill(rec.pid, SIGTERM) }
            self?.registry.mutate { reg in
                reg.agents.removeAll { $0.instanceId == rec.instanceId }
                if reg.lastCurrentInstanceId == rec.instanceId { reg.lastCurrentInstanceId = nil }
            }
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
        // Never wait on `open` from the main thread: a cold TextEdit launch
        // would beachball the whole menu extra.
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        proc.arguments = ["-t", path]
        openProcesses.append(proc)
        proc.terminationHandler = { [weak self, weak proc] finished in
            guard let proc else { return }
            DispatchQueue.main.async {
                self?.openProcesses.removeAll { $0 === proc }
            }
            guard finished.terminationStatus != 0 else { return }
            let p2 = Process()
            p2.executableURL = URL(fileURLWithPath: "/usr/bin/open")
            p2.arguments = ["-a", "TextEdit", path]
            try? p2.run()
        }
        try? proc.run()
    }

    func toggleLogin() {
        #if os(macOS)
        if #available(macOS 13.0, *) {
            status.loginNote = LoginService.toggle()
            cachedLoginEnabled = LoginService.enabled
            cachedLoginEnabledAt = Date()
            pollStatus()
        }
        #endif
    }

    func maybeFirstRun() {
        let flag = supportRoot + "/first-run-done"
        firstRun = FirstRunController(flagPath: flag, extra: self)
        firstRun?.axTrusted = { [weak self] in
            guard let self, let rec = self.currentRecord() else { return false }
            return self.fetchAgentStatus(socket: rec.socket)?.axTrusted ?? false
        }
        firstRun?.sheetIfNeeded()
    }

    /// Move session files aside so the new agent can restore frames. Returns the directory.
    func unstashAllSessions() -> String? {
        let root = supportRoot + "/spaces"
        let pending = supportRoot + "/pending-unstash"
        try? FileManager.default.createDirectory(atPath: pending, withIntermediateDirectories: true)
        var moved = false
        if let dirs = try? FileManager.default.contentsOfDirectory(atPath: root) {
            for dir in dirs {
                let path = root + "/" + dir + "/session.json"
                guard FileManager.default.fileExists(atPath: path) else { continue }
                let dest = pending + "/" + dir + ".json"
                try? FileManager.default.removeItem(atPath: dest)
                if (try? FileManager.default.moveItem(atPath: path, toPath: dest)) != nil {
                    moved = true
                }
            }
        }
        // A failed spawn may have left moved files behind; pick them up too.
        if let leftovers = try? FileManager.default.contentsOfDirectory(atPath: pending),
           leftovers.contains(where: { $0.hasSuffix(".json") })
        {
            moved = true
        }
        try? FileManager.default.removeItem(atPath: registry.path)
        return moved ? pending : nil
    }

    func claimCurrent(_ id: UUID, among live: [InstanceRecord]) {
        for rec in live {
            if rec.instanceId == id {
                sendTo(instance: rec.instanceId, socket: rec.socket, .markCurrent)
            } else {
                sendTo(instance: rec.instanceId, socket: rec.socket, .yield)
            }
        }
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
    case .verify: return "verify"
    case .status: return "status"
    case .ping: return "ping"
    case .subscribe: return "subscribe"
    case .markCurrent: return "mark-current"
    case .yield: return "yield"
    case .accessibilityPrompt: return "accessibility-prompt"
    case .debugAX: return "debug-ax"
    case .debugWindows: return "debug-windows"
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
    case .debugAX(let pid): return ["pid": .int(Int(pid))]
    default: return [:]
    }
}
#endif
