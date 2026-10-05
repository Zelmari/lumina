#if os(macOS)
import AppKit
import ApplicationServices
import Carbon
import CoreFoundation
import Darwin
import Foundation
import LuminaLayout
import LuminaIPC
import os

typealias WindowRef = LuminaLayout.Window

public final class AgentRuntime: NSObject, @unchecked Sendable {
    public let instanceId: UUID
    public let socketPath: String
    public let crashRecover: Bool
    public let runLaunchApps: Bool
    public var session: Session
    public var config: Config
    public var isCurrent = true
    public var userPaused = false
    public var displayGone = false
    public var bound: BoundDisplay?
    /// SkyLight id captured once, when this agent bound its display.
    public var boundSkyLightId: UInt64?
    /// Latest SkyLight id, used only to notice a native Space change.
    public var observedSkyLightId: UInt64?
    public var axTrusted: Bool { AXIsProcessTrusted() }
    public var hotkeys = Hotkeys()
    public var secureInput = false
    public var configError: String?
    public var lastSpaceChange = Date.distantPast
    public var lastLuminaSpaceChange = Date.distantPast
    /// Last native focused window synced from an app activation. AeroSpace
    /// only follows focus when this id changes; re-processing the same
    /// window caused focus ping-pong.
    var lastSyncedNativeFocusedId: UInt32?
    var lastWindowClosedAt = Date.distantPast
    public var pasteboardCount: Int = 0
    public var moveStart: (UInt32, Point, Int)?
    /// A coalesced refresh session. Events only carry a reason; the session
    /// re-reads the world. `space` is where new windows land: the focused
    /// space at the most recent scheduling event (a switch before the pass
    /// runs means the window appears where the user is).
    struct RefreshRequest {
        var reason: String
        var space: SpaceId
    }
    var pendingRefresh: RefreshRequest?
    var refreshScheduled = false
    /// Pids launched recently. An app launched hidden (or via AppleScript)
    /// has no on-screen window, so it would otherwise never be enumerated;
    /// it is unhidden and re-checked. Entries expire so every background app
    /// ever launched is not re-read on every refresh forever.
    var recentlyLaunchedPids: [pid_t: Date] = [:]
    let recentlyLaunchedWindow: TimeInterval = 20
    /// Bounded follow-up passes when a window was not resolvable yet.
    var unresolvedRefreshPasses = 0
    var refreshUnresolved = false
    /// Bounded post-launch discovery polls. A freshly launched app can create
    /// its window after the one refresh `appLaunched` schedules, and the
    /// window-created notification is easily missed while the AX observer is
    /// still installing, so keep re-reading for a few seconds.
    var launchPollsRemaining = 0
    /// When a window joined the session. Pruning never removes a window
    /// younger than the grace period; it may just not be visible to AX/CG yet.
    var bornAt: [UInt32: Date] = [:]
    /// Pre-tiling geometry by CGWindowID, including windows since pruned.
    /// Persisted via SessionFile so restarts and drop+re-adopt churn cannot
    /// replace true originals with tile rects.
    var knownOriginals: [UInt32: Rect] = [:]
    /// Consecutive-miss and failed-read bookkeeping for refresh removals.
    var removalGate = RemovalGate()
    /// Sizes an app has actually refused to shrink below. Some apps report
    /// AXMinSize 0 but clamp in practice; without this they overlap the
    /// neighbour whose tile they overflow. A refusal must be seen twice with
    /// the window keeping its old size across a shrink request.
    var observedMinSizes: [UInt32: Size] = [:]
    var overflowStrikes: [UInt32: Int] = [:]
    var clampingOverflow = false
    public var resizeDebounce: [UInt32: DispatchWorkItem] = [:]
    public var configDebounce: DispatchWorkItem?
    /// Cascade offset for quit restore when the saved original is really the
    /// engine's tile. Reset per quit.
    var restoreCascadeIndex = 0
    let preferredDisplayUUID: String?

    let log: LuminaLog
    let adapter: AXAdapter
    let observers = AXObserverHub()
    let skyLight = SkyLightClient()
    var server: AgentSocketServer?
    var elements: [UInt32: AXUIElement] = [:]
    var ffmTimer: DispatchSourceTimer?
    var secureTimer: DispatchSourceTimer?
    var axPollTimer: DispatchSourceTimer?
    var configWatcher: DispatchSourceFileSystemObject?
    var configFileWatcher: DispatchSourceFileSystemObject?
    var didBootLayout = false
    let supportRoot: String
    let sessionPath: String

    public init(instanceId: UUID, socketPath: String, displayUUID: String?, crashRecover: Bool, runLaunchApps: Bool, log: LuminaLog) {
        self.instanceId = instanceId
        self.socketPath = socketPath
        self.crashRecover = crashRecover
        self.runLaunchApps = runLaunchApps
        self.log = log
        self.adapter = AXAdapter(log: log)
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        self.supportRoot = home + "/Library/Application Support/Lumina"
        self.sessionPath = LuminaPaths.sessionPath(supportRoot: supportRoot, instanceId: instanceId.uuidString)
        let text = try? String(contentsOfFile: LuminaPaths.configPath(home: home), encoding: .utf8)
        let loaded = loadOrDefault(text: text)
        self.config = loaded.config
        self.configError = loaded.error
        self.session = Session.empty(spaceCount: config.spaceCount, instanceId: instanceId)
        self.preferredDisplayUUID = displayUUID
        super.init()
    }

    public func start() {
        adapter.setSystemTimeout()
        adapter.menuBarScreenMaxY = menuBarMaxY()
        bound = BoundDisplay.resolve(
            menuBarMaxY: adapter.menuBarScreenMaxY,
            focusedCenter: nil,
            preferredUUID: preferredDisplayUUID
        )
        if let uuid = bound?.uuid, boundSkyLightId == nil {
            boundSkyLightId = skyLight.currentSpaceId(displayUUID: uuid)
            observedSkyLightId = boundSkyLightId
        }
        do {
            let server = AgentSocketServer(path: socketPath, log: log)
            server.onCommand = { [weak self] cmd, id in
                self?.handleAgent(cmd, id: id) ?? IPCResponse.failure(id: id, error: "gone")
            }
            try server.start()
            self.server = server
        } catch {
            log.error("socket failed path=\(socketPath) \(error); exiting")
            exit(1)
        }
        hotkeys.isPaused = { [weak self] in
            guard let self else { return true }
            return self.userPaused || self.displayGone || !self.isCurrent
        }
        hotkeys.onCommand = { [weak self] cmd in
            self?.handleBound(cmd)
        }
        if shouldRegisterHotkeys(isCurrent: isCurrent, paused: userPaused || displayGone) {
            registerHotkeys()
        }
        installWorkspaceObservers()
        watchConfig()
        pollSecureInput()
        log.info(
            "agent start instance=\(instanceId) crashRecover=\(crashRecover) axTrusted=\(axTrusted) bundle=\(Bundle.main.bundleIdentifier ?? "?")"
        )
        if axTrusted {
            MutationQueue.shared.hop { [weak self] in self?.bootLayoutIfNeeded() }
        } else {
            log.info("AX not trusted; waiting (will prompt as Lumina Agent if still denied)")
            pollUntilAXTrusted()
        }
    }

    private let stopLock = NSLock()
    private var stopping = false

    func isStopping() -> Bool {
        stopLock.lock()
        defer { stopLock.unlock() }
        return stopping
    }

    /// Idempotent and serialized. `.quit` reaches this on the mutation queue
    /// and the SIGTERM path on main; running the quit restore twice raced with
    /// itself, and queued layout work used to re-tile windows after the
    /// restore. Callers that need the restore to finish should be on the
    /// mutation queue.
    public func stop() {
        stopLock.lock()
        if stopping {
            stopLock.unlock()
            return
        }
        stopping = true
        stopLock.unlock()
        pendingRefresh = nil
        refreshScheduled = false
        for item in resizeDebounce.values { item.cancel() }
        resizeDebounce.removeAll()
        configDebounce?.cancel()
        recenterAllWindows()
        writeSession(stash: [])
        unregisterHotkeys()
        server?.stop()
        ffmTimer?.cancel()
        secureTimer?.cancel()
        axPollTimer?.cancel()
        configWatcher?.cancel()
        configFileWatcher?.cancel()
    }

    /// Carbon hotkeys are main-thread only. Never sync to main from the mutation queue.
    func registerHotkeys(_ bindings: [Binding]? = nil) {
        let bindings = bindings ?? config.bindings
        let work = { [weak self] in
            guard let self else { return }
            self.hotkeys.register(bindings: bindings)
            if let err = self.hotkeys.hotkeyError { self.log.error("hotkeys \(err)") }
        }
        if Thread.isMainThread { work() } else { DispatchQueue.main.async(execute: work) }
    }

    func unregisterHotkeys() {
        let work: () -> Void = { [weak self] in self?.hotkeys.unregister() }
        if Thread.isMainThread { work() } else { DispatchQueue.main.async(execute: work) }
    }

    func bootLayout() {
        let leftovers = unstashLeftovers()
        _ = leftovers
        let focusedFromFile: Int = {
            guard crashRecover, let data = try? Data(contentsOf: URL(fileURLWithPath: sessionPath)),
                  let file = try? SessionFile.decode(data)
            else { return 1 }
            return file.focusedSpace
        }()
        let rebuild = rebuildSpaceId(crashRecover: crashRecover, sessionFocused: focusedFromFile, spaceCount: config.spaceCount)
        session.focusedSpace = rebuild
        session.paused = false
        if runLaunchApps {
            launchConfiguredApps()
        }
        let windows = collectManagedWindows()
        log.info("collectManagedWindows \(windows.count) ids=\(windows.map(\.cgWindowId))")
        let tileable: [WindowRef]
        let floaters: [WindowRef]
        if config.launchTiling.isAliasFloatExisting {
            tileable = []
            floaters = windows
        } else {
            tileable = windows.filter { classifyWindow($0) == .tiled }
            floaters = windows.filter { classifyWindow($0) == .floating }
        }
        let usable = bound.map { $0.usableRect(gaps: config.gaps) } ?? Rect(x: 0, y: 0, w: 1, h: 1)
        session = session.applyLaunchTiling(
            spaceId: rebuild,
            policy: config.launchTiling,
            windows: tileable,
            usableIsWide: usableIsWide(usable)
        )
        if var space = session.spaces[rebuild] {
            space.floating.append(contentsOf: floaters.map { w in
                var x = w; x.role = .floating; return x
            })
            session.spaces[rebuild] = space
        }
        clampOverflowOn(rebuild)
        applyFrames()
        watchRunningApps()
        startOrStopFFM()
        // Apps can drop or delay the first frame write; one cheap settle pass
        // converges the layout without waiting for the user to click.
        scheduleRefresh(reason: "bootSettle", delay: 0.6)
        log.info("bootLayout tiled=\(tileable.count) floating=\(floaters.count) usable=\(usable.w)x\(usable.h)")
    }

    func bootLayoutIfNeeded() {
        guard !didBootLayout else { return }
        didBootLayout = true
        bootLayout()
    }

    func requestAgentAXPrompt() {
        // LSUIElement agents often never surface the system AX sheet; go regular for the prompt.
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        let opts = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(opts)
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
            guard let self, !self.axTrusted else { return }
            NSApp.setActivationPolicy(.accessory)
        }
    }

    func pollUntilAXTrusted() {
        axPollTimer?.cancel()
        var prompted = false
        let timer = DispatchSource.makeTimerSource(queue: DispatchQueue.main)
        timer.schedule(deadline: .now(), repeating: 0.4)
        timer.setEventHandler { [weak self] in
            guard let self else { return }
            if self.axTrusted {
                self.axPollTimer?.cancel()
                self.axPollTimer = nil
                NSApp.setActivationPolicy(.accessory)
                self.log.info("AX trusted; starting layout")
                MutationQueue.shared.hop { [weak self] in self?.bootLayoutIfNeeded() }
                return
            }
            if !prompted {
                prompted = true
                self.log.info("AX still untrusted; prompting as Lumina Agent")
                self.requestAgentAXPrompt()
            }
        }
        timer.resume()
        axPollTimer = timer
    }

    func classifyWindow(_ window: WindowRef) -> ClassifyResult {
        guard let el = elements[window.cgWindowId], let bound else { return .tiled }
        let onScreen = Set(onScreenCGWindows(intersecting: bound.axFrame).compactMap(cgWindowID))
        guard let (input, _, _) = classifyInput(from: el, adapter: adapter, bound: bound, onScreenIds: onScreen) else {
            return .tiled
        }
        return classify(input, rules: config.windowRules)
    }

    /// The frame to remember as a window's pre-tiling geometry. A stored
    /// original is trusted unless it looks like an engine tile (stale tiles
    /// from earlier sessions must not become "originals"); a live frame is
    /// only captured when it is on screen and not tile-shaped.
    func trustedOriginal(id: UInt32, liveFrame: Rect, usable: Rect) -> Rect? {
        if let known = knownOriginals[id],
           !looksLikeEngineFrame(known, usable: usable, gaps: config.gaps)
        {
            return known
        }
        if isStashedAway(liveFrame) { return nil }
        if looksLikeEngineFrame(liveFrame, usable: usable, gaps: config.gaps) { return nil }
        return liveFrame
    }

    func collectManagedWindows() -> [(WindowRef)] {
        guard let bound else { return [] }
        let usable = bound.usableRect(gaps: config.gaps)
        let started = Date()
        var out: [WindowRef] = []
        let cg = onScreenCGWindows(intersecting: bound.axFrame)
        let onScreenIds = Set(cg.compactMap(cgWindowID))
        let ownerPids = Set(cg.compactMap(cgOwnerPID))
        let apps = NSWorkspace.shared.runningApplications
        var index = 0
        for app in apps {
            defer { index += 1 }
            if MutationQueue.shared.shouldSkip(started: started) {
                // Resume where we left off instead of dropping the tail pids.
                log.info("collectManagedWindows exceeded 200ms; continuing with \(apps.count - index) pids")
                MutationQueue.shared.queue.asyncAfter(deadline: .now() + 0.3) { [weak self] in
                    guard let self, self.isCurrent, !self.userPaused else { return }
                    self.scheduleRefresh(reason: "bootTail")
                    self.applyFrames()
                }
                break
            }
            let pid = app.processIdentifier
            if isOurProcess(pid) || !ownerPids.contains(pid) { continue }
            observers.watch(pid: pid)
            for el in adapter.windows(pid: pid) {
                let used = Set(out.map(\.cgWindowId))
                guard let (input, id, _) = classifyInput(
                    from: el,
                    adapter: adapter,
                    bound: bound,
                    onScreenIds: onScreenIds,
                    excludingWindowIds: used
                ) else { continue }
                adapter.markAccessibilityHealthy(pid: pid)
                if adapter.isAppHidden(pid: pid) {
                    // Unhide and re-check on the next pass; only a window
                    // that becomes on-screen is adopted.
                    adapter.unhide(pid: pid)
                    scheduleRefresh(reason: "unhide", delay: 0.2)
                    refreshUnresolved = true
                    continue
                }
                let result = classify(input, rules: config.windowRules)
                log.info(
                    "classify \(app.bundleIdentifier ?? "?") role=\(input.role ?? "?") sub=\(input.subrole ?? "?") -> \(result) id=\(id)"
                )
                if result == .unmanaged || result == .ignored {
                    // A window CG has not listed yet may become visible a
                    // moment later; retry instead of dropping it for good.
                    if !input.isOnScreen { refreshUnresolved = true }
                    continue
                }
                if input.isMinimized { adapter.deminiaturize(el) }
                observers.watchWindow(el, pid: pid)
                adapter.rememberWindowId(id, for: el)
                elements[id] = el
                let frame = adapter.frame(of: el) ?? Rect(x: 0, y: 0, w: 0, h: 0)
                let original = trustedOriginal(id: id, liveFrame: frame, usable: usable)
                let w = WindowRef(cgWindowId: id, pid: pid, bundleId: app.bundleIdentifier, role: result == .floating ? .floating : .tiled, lastOnscreenFrame: frame, originalFrame: original)
                knownOriginals[id] = original
                markBorn(id)
                out.append(w)
            }
        }
        if let front = NSWorkspace.shared.frontmostApplication?.processIdentifier,
           !isOurProcess(front),
           !out.contains(where: { $0.pid == front }),
           let focusedEl = adapter.focusedWindow(of: AXUIElementCreateApplication(front)),
           adapter.windowId(for: focusedEl) != nil,
           let (input, id, pid) = classifyInput(
               from: focusedEl,
               adapter: adapter,
               bound: bound,
               onScreenIds: onScreenIds,
               excludingWindowIds: Set(out.map(\.cgWindowId))
           ),
           !out.contains(where: { $0.cgWindowId == id })
        {
            let result = classify(input, rules: config.windowRules)
            if result != .unmanaged && result != .ignored {
                if input.isMinimized { adapter.deminiaturize(focusedEl) }
                observers.watchWindow(focusedEl, pid: pid)
                adapter.rememberWindowId(id, for: focusedEl)
                elements[id] = focusedEl
                let frame = adapter.frame(of: focusedEl) ?? Rect(x: 0, y: 0, w: 0, h: 0)
                let original = trustedOriginal(id: id, liveFrame: frame, usable: usable)
                let w = WindowRef(cgWindowId: id, pid: pid, bundleId: adapter.bundleId(pid: pid), role: result == .floating ? .floating : .tiled, lastOnscreenFrame: frame, originalFrame: original)
                knownOriginals[id] = original
                markBorn(id)
                out.append(w)
                log.info("adopt focused window at boot pid=\(pid) id=\(id) bundle=\(adapter.bundleId(pid: pid) ?? "?")")
            }
        }
        // front-to-back: CG list is front-to-back already (index 0 frontmost)
        let order = cg.compactMap(cgWindowID)
        out.sort { a, b in
            let ia = order.firstIndex(of: a.cgWindowId) ?? .max
            let ib = order.firstIndex(of: b.cgWindowId) ?? .max
            return ia < ib
        }
        return out
    }

    func watchRunningApps() {
        observers.onNotification = { [weak self] pid, name, element in
            MutationQueue.shared.hop {
                self?.handleAX(pid: pid, name: name, element: element)
            }
        }
        let owners = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
        for pid in Set(owners.compactMap(cgOwnerPID)) where !isOurProcess(pid) {
            observers.watch(pid: pid)
        }
        let nc = NSWorkspace.shared.notificationCenter
        nc.addObserver(self, selector: #selector(appLaunched(_:)), name: NSWorkspace.didLaunchApplicationNotification, object: nil)
        nc.addObserver(self, selector: #selector(appTerminated(_:)), name: NSWorkspace.didTerminateApplicationNotification, object: nil)
        nc.addObserver(self, selector: #selector(appHidden(_:)), name: NSWorkspace.didHideApplicationNotification, object: nil)
        nc.addObserver(self, selector: #selector(appActivated(_:)), name: NSWorkspace.didActivateApplicationNotification, object: nil)
        nc.addObserver(self, selector: #selector(spaceChanged(_:)), name: NSWorkspace.activeSpaceDidChangeNotification, object: nil)
        nc.addObserver(self, selector: #selector(didWake(_:)), name: NSWorkspace.didWakeNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(screensChanged(_:)), name: NSApplication.didChangeScreenParametersNotification, object: nil)
    }

    @objc func appLaunched(_ n: Notification) {
        guard isCurrent, !userPaused else { return }
        if let app = n.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication {
            let pid = app.processIdentifier
            DispatchQueue.main.async { self.observers.watch(pid: pid) }
            MutationQueue.shared.hop { [weak self] in
                guard let self else { return }
                self.recentlyLaunchedPids[pid] = Date()
                self.launchPollsRemaining = max(self.launchPollsRemaining, 8)
                self.scheduleRefresh(reason: "appLaunched")
            }
        }
    }

    @objc func appTerminated(_ n: Notification) {
        if let app = n.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication {
            MutationQueue.shared.hop {
                self.recentlyLaunchedPids[app.processIdentifier] = nil
                self.observers.unwatch(pid: app.processIdentifier)
                self.adapter.forgetAccessibility(pid: app.processIdentifier)
                self.dropPid(app.processIdentifier)
            }
        }
    }

    @objc func appHidden(_ n: Notification) {
        if let app = n.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication {
            MutationQueue.shared.hop {
                guard self.isCurrent, !self.userPaused, !self.ownedWindows(pid: app.processIdentifier).isEmpty else { return }
                self.adapter.unhide(pid: app.processIdentifier)
            }
        }
    }

    @objc func appActivated(_ n: Notification) {
        guard !userPaused, isCurrent else { return }
        if let app = n.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication {
            MutationQueue.shared.hop {
                self.scheduleRefresh(reason: "appActivated")
                if self.ownedWindows(pid: app.processIdentifier).isEmpty {
                    self.launchPollsRemaining = max(self.launchPollsRemaining, 3)
                }
                // A model window may already be dead (Electron AX churn). A
                // space full of ghosts must not count as occupied, or macOS
                // promoting the next app after a close drags the user away.
                // An empty workspace is a valid place to be, so only the
                // predicate decides; it declines to follow without windows.
                let hasWindows = self.session.visibleIds(on: self.session.focusedSpace).contains { id in
                    guard let w = self.windowAnywhere(id) else { return false }
                    return self.hasAXElement(w)
                }
                // Drop superseded activations (the notification can arrive
                // after another app already took focus).
                guard NSWorkspace.shared.frontmostApplication?.processIdentifier == app.processIdentifier else { return }
                let elapsedSinceClose = Date().timeIntervalSince(self.lastWindowClosedAt)
                let elapsedSinceSpaceChange = Date().timeIntervalSince(self.lastLuminaSpaceChange)
                let isWindowCloseCascade = elapsedSinceClose < 0.4
                let shouldFollow = !isWindowCloseCascade && shouldFollowAppActivation(
                    spaceHasWindows: hasWindows,
                    elapsedSinceSpaceChange: elapsedSinceSpaceChange
                )
                guard shouldFollow else {
                    self.restashOffspace()
                    return
                }
                self.syncFocusToFrontmostApp(pid: app.processIdentifier)
            }
        }
    }

    @objc func spaceChanged(_ n: Notification) {
        lastSpaceChange = Date()
        MutationQueue.shared.hop { self.recomputeCurrentToken(reason: .spaceChange) }
    }

    @objc func didWake(_ n: Notification) {
        MutationQueue.shared.hop {
            self.recomputeCurrentToken(reason: .wake)
            guard self.isCurrent else { return }
            self.applyFrames()
            self.restashOffspace()
        }
    }

    @objc func screensChanged(_ n: Notification) {
        MutationQueue.shared.hop { self.handleDisplayChange() }
    }

    func handleAX(pid: pid_t, name: String, element: AXUIElement) {
        if userPaused || displayGone || !isCurrent { return }
        switch name {
        case kAXWindowCreatedNotification, kAXUIElementDestroyedNotification:
            if name == kAXUIElementDestroyedNotification {
                lastWindowClosedAt = Date()
            }
            scheduleRefresh(reason: name)
        case kAXFocusedWindowChangedNotification:
            let win = adapter.focusedWindow(of: element)
                ?? adapter.focusedWindow(of: AXUIElementCreateApplication(pid))
            guard let win, let id = adapter.windowId(for: win) else {
                scheduleRefresh(reason: name)
                return
            }
            if ownedAnywhere(id) {
                observers.watchWindow(win, pid: pid)
                if owned(id) {
                    rememberFocus(id)
                } else if let sid = session.spaceContaining(cgWindowId: id), sid != session.focusedSpace {
                    // Focused elsewhere: remember it there too, so returning
                    // to that space restores it. Then keep it parked.
                    if var space = session.spaces[sid] {
                        space.focusedWindow = id
                        if let leaf = space.leaf(containing: id) {
                            space.lastTiledLeaf = leaf.id
                        }
                        session.spaces[sid] = space
                    }
                    stash(ids: [id], space: sid)
                }
            } else {
                // Unknown to the model: the next session adopts it.
                scheduleRefresh(reason: name)
            }
        case kAXWindowMovedNotification, kAXWindowResizedNotification:
            onMovedOrResized(element, resized: name == kAXWindowResizedNotification)
        case kAXTitleChangedNotification:
            onTitleChanged(element)
        case kAXWindowMiniaturizedNotification:
            if let id = adapter.windowId(for: element),
               let w = session.current.leaf(containing: id)?.leaf,
               adapter.shouldIgnoreAXGeometry(window: w)
            { return }
            let retryId = adapter.windowId(for: element)
            adapter.deminiaturize(element)
            MutationQueue.shared.queue.asyncAfter(deadline: .now() + 0.05) { [weak self] in
                guard let self, let retryId, let el = self.elements[retryId], self.adapter.isMinimized(el) else { return }
                self.adapter.deminiaturize(el)
            }
        default:
            break
        }
    }

    /// Coalesce every discovery event into one session. Mutation queue only.
    func scheduleRefresh(reason: String, delay: TimeInterval = 0.04) {
        guard !isStopping() else { return }
        // New windows land on the space focused when their event arrives.
        // Keeping an older request's space let a launch poll scheduled before
        // a workspace switch claim a window the user opened after it, so the
        // window appeared on the workspace they had left.
        pendingRefresh = RefreshRequest(reason: reason, space: session.focusedSpace)
        guard !refreshScheduled else { return }
        refreshScheduled = true
        MutationQueue.shared.queue.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self else { return }
            self.refreshScheduled = false
            guard let request = self.pendingRefresh else { return }
            self.pendingRefresh = nil
            self.runRefresh(reason: request.reason, space: request.space)
        }
    }

    /// Chromium/Electron can answer AXWindows with an empty or partial list.
    /// The frontmost app's focused window is still readable, so adopt it even
    /// when the enumeration misses it (AeroSpace does this on every refresh).
    @discardableResult
    func adoptFocusedWindow(
        pid: pid_t,
        live: inout [LiveWindow],
        elementsById: inout [UInt32: AXUIElement],
        onScreen: Set<UInt32>
    ) -> Bool {
        let app = AXUIElementCreateApplication(pid)
        guard let el = adapter.focusedWindow(of: app), let id = adapter.windowId(for: el) else { return false }
        guard !elementsById.keys.contains(id), !ownedAnywhere(id) else { return false }
        let frame = adapter.frame(of: el) ?? Rect(x: 0, y: 0, w: 0, h: 0)
        live.append(LiveWindow(
            cgWindowId: id,
            pid: pid,
            bundleId: adapter.bundleId(pid: pid),
            frame: frame,
            onScreen: onScreen.contains(id)
        ))
        elementsById[id] = el
        adapter.markAccessibilityHealthy(pid: pid)
        log.info("adopt focused window pid=\(pid) id=\(id) bundle=\(adapter.bundleId(pid: pid) ?? "?")")
        return true
    }

    /// One declarative pass: re-read every relevant app's AX window list, GC
    /// windows that are gone, rebind replaced ids, adopt new ones, then lay
    /// out. Convergence by repetition; no per-event repair.
    func runRefresh(reason: String, space: SpaceId) {
        guard !isStopping(), didBootLayout, isCurrent, !userPaused, !displayGone, let bound else { return }
        let refreshInterval = LuminaSignposts.pointsOfInterest.beginInterval("refresh-session")
        defer { LuminaSignposts.pointsOfInterest.endInterval("refresh-session", refreshInterval) }
        let started = Date()
        refreshUnresolved = false
        let onScreenRows = onScreenCGWindows(intersecting: bound.axFrame)
        let onScreen = Set(onScreenRows.compactMap(cgWindowID))
        var elementsById: [UInt32: AXUIElement] = [:]
        var live: [LiveWindow] = []
        var modelPids: [UInt32: Int32] = [:]
        var floatingIds: Set<UInt32> = []
        for space in session.spaces.values {
            for node in space.tiledLeaves() { if let w = node.leaf { modelPids[w.cgWindowId] = w.pid } }
            for w in space.floating {
                modelPids[w.cgWindowId] = w.pid
                if w.role == .floating || w.role == .stashed { floatingIds.insert(w.cgWindowId) }
            }
        }
        // Native-fullscreen windows are detached from the tree but still live
        // in `AXWindows`. Without them in the model, a close of any sibling
        // pairs the dead id with the fullscreen window as a rebind and grafts
        // a tile onto a window macOS owns.
        for w in session.nativeFSWindows { modelPids[w.cgWindowId] = w.pid }
        /// Pids whose AX window list did not answer this pass. Their absence
        /// from `live` is not evidence of death; removals are deferred and
        /// the unresolved retry covers newly created windows.
        var axFailedPids: Set<pid_t> = []
        let unmanagedLayeredIds: Set<UInt32> = Set(onScreenRows.compactMap { row -> UInt32? in
            guard cgWindowLayer(row) == 0, let id = cgWindowID(row), !session.allWindowIds.contains(id) else { return nil }
            return id
        })
        func hasUnmanagedOnScreen(_ pid: pid_t) -> Bool {
            onScreenRows.contains { row in
                guard let rect = cgWindowRect(row), rect.w >= 50, rect.h >= 50 else { return false }
                return cgOwnerPID(row) == pid && cgWindowLayer(row) == 0
                    && cgWindowID(row).map { unmanagedLayeredIds.contains($0) } == true
            }
        }
        func hasAnyOnScreenWindow(_ pid: pid_t) -> Bool {
            onScreenRows.contains { row in
                guard let rect = cgWindowRect(row), rect.w >= 50, rect.h >= 50 else { return false }
                return cgOwnerPID(row) == pid && cgWindowLayer(row) == 0
            }
        }
        let modelPidSet = Set(modelPids.values)
        for pid in refreshPids() {
            switch adapter.enumerateWindows(pid: pid) {
            case .failed:
                axFailedPids.insert(pid)
                if hasUnmanagedOnScreen(pid) {
                    log.info("refresh ax read failed unmanaged pid=\(pid) bundle=\(adapter.bundleId(pid: pid) ?? "?")")
                    refreshUnresolved = true
                }
            case .list(let elements):
                if elements.isEmpty {
                    // An app that owns on-screen or model windows but answers
                    // an empty AXWindows list has torn its accessibility tree
                    // down (Ghostty/Electron do this). Treat the read as
                    // failed for removal purposes and forget the wake state
                    // so it is woken again instead of looking windowless.
                    if hasAnyOnScreenWindow(pid) || modelPidSet.contains(pid) {
                        log.info("refresh ax empty pid=\(pid) bundle=\(adapter.bundleId(pid: pid) ?? "?"); will re-wake")
                        axFailedPids.insert(pid)
                        adapter.markAccessibilityUnhealthy(pid: pid)
                        // Ask directly; `resolvedElement` short-circuits on a
                        // retained element and would never re-wake.
                        adapter.wakeAccessibility(pid: pid)
                        refreshUnresolved = true
                    } else if hasUnmanagedOnScreen(pid) {
                        log.info("refresh ax empty unmanaged pid=\(pid) bundle=\(adapter.bundleId(pid: pid) ?? "?")")
                        refreshUnresolved = true
                    }
                }
                for el in elements {
                    guard let id = adapter.windowId(for: el) else {
                        log.info("refresh unresolved window id pid=\(pid) role=\(adapter.role(of: el) ?? "?")")
                        continue
                    }
                    adapter.markAccessibilityHealthy(pid: pid)
                    let frame = adapter.frame(of: el) ?? Rect(x: 0, y: 0, w: 0, h: 0)
                    live.append(LiveWindow(
                        cgWindowId: id,
                        pid: pid,
                        bundleId: adapter.bundleId(pid: pid),
                        frame: frame,
                        onScreen: onScreen.contains(id)
                    ))
                    elementsById[id] = el
                }
            }
        }
        if let front = NSWorkspace.shared.frontmostApplication?.processIdentifier, !isOurProcess(front) {
            _ = adoptFocusedWindow(pid: front, live: &live, elementsById: &elementsById, onScreen: onScreen)
        }
        let failedManaged = axFailedPids.intersection(Set(modelPids.values))
        let unmanagedFailed = onScreenRows.contains { row in
            guard let pid = cgOwnerPID(row), axFailedPids.contains(pid), !isOurProcess(pid),
                  cgWindowLayer(row) == 0, let id = cgWindowID(row) else { return false }
            return !session.allWindowIds.contains(id)
        }
        if !failedManaged.isEmpty {
            log.info("refresh ax read failed managed pids=\(failedManaged.sorted())")
        }
        if !failedManaged.isEmpty || unmanagedFailed {
            refreshUnresolved = true
        }
        // Only a just-created window may be rebound: that is the Electron
        // splash-replacement shape. A close plus an unrelated open must not
        // inherit the old window's slot on another workspace.
        let rebindable = Set((session.allWindowIds.union(session.nativeFSWindows.map(\.cgWindowId))).filter { isYoung($0) })
        let delta = reconcile(
            model: session.allWindowIds.union(session.nativeFSWindows.map(\.cgWindowId)),
            modelPids: modelPids,
            live: live,
            rebindableIds: rebindable
        )
        var removals: (real: [UInt32], deferred: [UInt32]) = (real: [], deferred: [])
        defer {
            recordRefreshSummary(
                reason: reason,
                added: delta.added.count + delta.recycled.count,
                removed: removals.real.count,
                rebinds: delta.rebinds.count,
                unresolved: refreshUnresolved,
                started: started
            )
        }
        // Check suspension before the gate classifies: a pass the lock-screen
        // guard is about to discard must not advance the miss counters.
        if shouldSuspendMassRemoval(
            modelCount: session.allWindowIds.count,
            removedCount: delta.removed.count,
            screenLocked: screenLockedOrAsleep()
        ) {
            log.info("refresh suspended mass removal removed=\(delta.removed.count) of \(session.allWindowIds.count); screen locked/asleep")
            scheduleRefresh(reason: "massLossSuspended", delay: 2.0)
            return
        }
        // A retained AX element that still answers a role read vetoes removal:
        // CG's list can omit a parked window transiently, and deleting one
        // buries it off-screen with no path back into the model. Only strict
        // success counts; a timed-out read must not pin an entry forever.
        var elementLive: Set<UInt32> = []
        for id in delta.removed {
            guard let el = elements[id], let pid = modelPids[id], adapter.pid(of: el) == pid else { continue }
            if adapter.isAliveElement(el) { elementLive.insert(id) }
        }
        removals = removalGate.classify(
            removed: delta.removed,
            cgLive: cgWindowIds(),
            pidOf: modelPids,
            axFailedPids: failedManaged,
            floatingIds: floatingIds,
            elementLive: elementLive
        )
        if !removals.deferred.isEmpty {
            log.info("refresh deferring removal ids=\(removals.deferred) (alive or cg still lists them)")
            refreshUnresolved = true
        }
        let focusedBefore = session.current.focusedWindow
        // A recycled id is torn down like a removal, then re-adopted from the
        // live enumeration below, so its old model entry must go first.
        for id in removals.real + delta.recycled { removeDestroyedWindow(id) }
        if (!delta.removed.isEmpty || !delta.recycled.isEmpty), session.current.focusedWindow != focusedBefore,
           let winner = session.current.focusedWindow
        {
            // Stay on this (possibly now empty) space; only re-home focus when
            // a sibling remains there.
            nativeFocus(winner)
        }
        for pair in delta.rebinds {
            guard let el = elementsById[pair.to] else { continue }
            if let w = windowAnywhere(pair.from) {
                log.info("refresh rebind \(pair.from) -> \(pair.to) bundle=\(w.bundleId ?? "?")")
                rebindOwned(from: pair.from, to: pair.to, element: el, pid: w.pid)
                reclassifyRebound(id: pair.to, pid: w.pid, element: el, onScreen: onScreen)
            } else if let idx = session.nativeFSWindows.firstIndex(where: { $0.cgWindowId == pair.from }) {
                // A native-fullscreen window is detached from every space, so
                // `windowAnywhere` cannot find it; move the bookmark instead
                // of leaving the old id and an unmanaged new window behind.
                var w = session.nativeFSWindows[idx]
                log.info("refresh rebind nativeFS \(pair.from) -> \(pair.to) bundle=\(w.bundleId ?? "?")")
                w.cgWindowId = pair.to
                session.nativeFSWindows[idx] = w
                if let original = knownOriginals[pair.from] {
                    knownOriginals[pair.to] = original
                    knownOriginals[pair.from] = nil
                }
                elements[pair.from] = nil
                adapter.forgetWindowId(pair.from)
                adapter.rememberWindowId(pair.to, for: el)
                elements[pair.to] = el
                if let pid = adapter.pid(of: el) { observers.watchWindow(el, pid: pid) }
            }
        }
        var claimed = session.allWindowIds.union(elements.keys).union(session.nativeFSWindows.map(\.cgWindowId))
        for id in delta.added + delta.recycled {
            guard let el = elementsById[id] else { continue }
            onCreate(el, claimed: &claimed, apply: false, space: space)
        }
        applyFrames()
        restashOffspace()
        if !delta.isEmpty || refreshUnresolved || !removals.deferred.isEmpty {
            let ms = Int(Date().timeIntervalSince(started) * 1000)
            log.info("refresh reason=\(reason) added=\(delta.added.count + delta.recycled.count) removed=\(removals.real.count) deferred=\(removals.deferred.count) rebinds=\(delta.rebinds.count) unresolved=\(refreshUnresolved) \(ms)ms")
        }
        if refreshUnresolved, unresolvedRefreshPasses < 2 {
            unresolvedRefreshPasses += 1
            scheduleRefresh(reason: "unresolved", delay: 1.0)
        } else if !refreshUnresolved {
            unresolvedRefreshPasses = 0
        }
        if launchPollsRemaining > 0 {
            launchPollsRemaining -= 1
            scheduleRefresh(reason: "launchPoll", delay: 0.75)
        }
    }

    /// The lock screen and display sleep make every AX window disappear. A
    /// refresh that sees most of the world gone must not delete the model.
    func screenLockedOrAsleep() -> Bool {
        if NSWorkspace.shared.frontmostApplication?.bundleIdentifier == "com.apple.loginwindow" { return true }
        return CGDisplayIsAsleep(CGMainDisplayID()) != 0
    }

    /// Pids worth enumerating this pass: everything we manage, everything with
    /// an on-screen window, and the frontmost app.
    func refreshPids() -> [pid_t] {
        var pids = Set<pid_t>()
        for space in session.spaces.values {
            for node in space.tiledLeaves() { if let w = node.leaf { pids.insert(w.pid) } }
            for w in space.floating { pids.insert(w.pid) }
        }
        if let bound {
            for row in onScreenCGWindows(intersecting: bound.axFrame) {
                if let pid = cgOwnerPID(row), !isOurProcess(pid) { pids.insert(pid) }
            }
        }
        if let front = NSWorkspace.shared.frontmostApplication?.processIdentifier, !isOurProcess(front) {
            pids.insert(front)
        }
        // A just-launched hidden app has no on-screen window yet.
        let cutoff = Date().addingTimeInterval(-recentlyLaunchedWindow)
        for (pid, launchedAt) in recentlyLaunchedPids where launchedAt > cutoff {
            if !isOurProcess(pid) { pids.insert(pid) }
        }
        return pids.sorted()
    }

    func onCreate(
        _ element: AXUIElement,
        claimed: inout Set<UInt32>,
        apply: Bool = true,
        space preferredSpace: SpaceId? = nil
    ) {
        guard let bound else { return }
        let targetId = preferredSpace.flatMap { session.spaces[$0] != nil ? $0 : nil } ?? session.focusedSpace
        if let existing = trackedId(matching: element), ownedAnywhere(existing) {
            claimed.insert(existing)
            if let pid = adapter.pid(of: element) {
                observers.watchWindow(element, pid: pid)
            }
            adapter.rememberWindowId(existing, for: element)
            elements[existing] = element
            if let sid = session.spaceContaining(cgWindowId: existing), sid != session.focusedSpace {
                stash(ids: [existing], space: sid)
            }
            return
        }
        if let frame = adapter.frame(of: element), isStashedAway(frame) {
            // A fresh window's first AX read can be an empty frame while it
            // animates in; that is not our park. Our parks always keep height.
            // Only skip when the app already owns model windows: an app whose
            // saved window position is a park corner (macOS restores the last
            // frame) has none yet and must be adopted and tiled, or it is
            // never managed.
            let empty = frame.w < 8 && frame.h < 8
            let pidOwnsModelWindow = adapter.pid(of: element).map { !ownedWindows(pid: $0).isEmpty } ?? false
            if !empty, pidOwnsModelWindow {
                log.info("onCreate skip stashed-away role=\(adapter.role(of: element) ?? "?")")
                return
            }
        }
        let peekId = adapter.windowId(for: element, excluding: claimed)
        let peekPid = adapter.pid(of: element)
        if let peekId, let peekPid, let sid = otherSpace(pid: peekPid, id: peekId, element: element) {
            claimed.insert(peekId)
            observers.watchWindow(element, pid: peekPid)
            adapter.rememberWindowId(peekId, for: element)
            elements[peekId] = element
            restashPid(peekPid, on: sid)
            return
        }
        let onScreen = Set(onScreenCGWindows(intersecting: bound.axFrame).compactMap(cgWindowID))
        guard let (input, id, pid) = classifyInput(
            from: element,
            adapter: adapter,
            bound: bound,
            onScreenIds: onScreen,
            excludingWindowIds: claimed
        ) else {
            log.info("onCreate skip (no window id) role=\(adapter.role(of: element) ?? "?")")
            refreshUnresolved = true
            return
        }
        if adapter.isAppHidden(pid: pid) {
            // A background launch (open/AppleScript) leaves the app hidden.
            // Unhide it and re-check next pass: only a window that actually
            // becomes on-screen is adopted, so hidden tabs and twins stay
            // out of the tree.
            adapter.unhide(pid: pid)
            scheduleRefresh(reason: "unhide", delay: 0.2)
            refreshUnresolved = true
            return
        }
        if let sid = otherSpace(pid: pid, id: id, element: element) {
            claimed.insert(id)
            observers.watchWindow(element, pid: pid)
            adapter.rememberWindowId(id, for: element)
            elements[id] = element
            restashPid(pid, on: sid)
            return
        }
        if ownedAnywhere(id) {
            // CGWindowIDs get recycled. If the previous owner is dead, forget
            // the stale binding and adopt this as a new window.
            if let current = windowAnywhere(id), hasAXElement(current) {
                claimed.insert(id)
                observers.watchWindow(element, pid: pid)
                adapter.rememberWindowId(id, for: element)
                elements[id] = element
                return
            }
            log.info("onCreate id reuse, forgetting dead owner id=\(id)")
            adapter.forgetWindowId(id)
            elements[id] = nil
        }
        if let stale = staleOwnedWindow(pid: pid, liveId: id, element: element) {
            log.info("rebind onCreate \(stale) -> \(id) bundle=\(input.bundleId ?? "?")")
            rebindOwned(from: stale, to: id, element: element, pid: pid)
            claimed.insert(id)
            if apply { applyFrames() }
            return
        }
        let result = classify(input, rules: config.windowRules)
        log.info(
            "onCreate \(input.bundleId ?? "?") role=\(input.role ?? "?") sub=\(input.subrole ?? "?") -> \(result) id=\(id)"
        )
        if input.isMinimized {
            // Adopted minimized windows are tiled; make them visible or the
            // tile is occupied by a window nobody can see.
            adapter.deminiaturize(element)
        }
        if result == .unmanaged || result == .ignored {
            // Classified from a placeholder frame (or before appearing
            // on-screen): resolve it on a later session.
            if input.width < 50 || input.height < 50 || !input.isOnScreen {
                refreshUnresolved = true
            }
            return
        }
        if result == .floating, isPlaceholderFloat(input),
           input.width < 50 || input.height < 50 || !input.isOnScreen
        {
            // A tiny or not-yet-on-screen frame with no explicit float signal
            // is a placeholder; reclassify once the app has drawn. A rule or
            // hard float is a real decision even when small, so dialogs and
            // panels are adopted instead of floating unseen forever.
            refreshUnresolved = true
            return
        }
        claimed.insert(id)
        observers.watchWindow(element, pid: pid)
        adapter.rememberWindowId(id, for: element)
        elements[id] = element
        let frame = adapter.frame(of: element) ?? Rect(x: 0, y: 0, w: 0, h: 0)
        let usable = bound.usableRect(gaps: config.gaps)
        // A park or engine-tile frame is not the user's geometry; never record
        // it as the original or quit would restore a tile (or a 1px corner).
        let original = trustedOriginal(id: id, liveFrame: frame, usable: usable)
        var window = WindowRef(cgWindowId: id, pid: pid, bundleId: adapter.bundleId(pid: pid), role: .tiled, lastOnscreenFrame: frame, originalFrame: original)
        knownOriginals[id] = original
        let target = session.spaces[targetId] ?? session.current
        if target.luminaFullscreen != nil {
            session = session.insertWhileLuminaFS(space: targetId, window: window, result: result, usableIsWide: usableIsWide(usable))
            if result == .tiled {
                stash(ids: [id], space: targetId)
            }
        } else if result == .floating {
            window.role = .floating
            var space = target
            space.floating.append(window)
            session.spaces[targetId] = space
            // An app can restore a floater at a corner park (macOS saved the
            // frame while it was hidden). Pull it into view instead of
            // leaving a 1px sliver the user cannot reach. A window on an
            // inactive space is parked by the branch below instead.
            if isStashedAway(frame), targetId == session.focusedSpace {
                placeFloated([window], space: targetId)
            }
        } else {
            session = session.insertSpiral(space: targetId, newLeaf: window, usableIsWide: usableIsWide(usable))
            let mins = minSizes()
            let (clamped, floated) = session.clampOverflow(space: targetId, minSizes: mins, usable: usable, gaps: config.gaps, preferFloat: (session.spaces[targetId] ?? target).lastTiledLeaf)
            session = clamped
            placeFloated(floated, space: targetId)
        }
        markBorn(id)
        // Adopted; stop treating the pid as a pending launch.
        recentlyLaunchedPids[pid] = nil
        if targetId != session.focusedSpace {
            // The user moved on before this window settled. It belongs to the
            // space that was focused when it appeared; stash its role and
            // park it there now, or the model reports a visible window on an
            // inactive workspace.
            session = session.markStashed(space: targetId, ids: [id])
            stash(ids: [id], space: targetId)
        }
        if apply { applyFrames() }
    }

    /// True when `.floating` was inferred from a placeholder-sized frame
    /// rather than an explicit rule or hard-float role. Those wait for the
    /// app to draw; explicit floats are adopted immediately.
    func isPlaceholderFloat(_ input: ClassifyInput) -> Bool {
        if let role = input.role, Classify.hardRoles.contains(role) { return false }
        if let sub = input.subrole, Classify.hardSubroles.contains(sub) { return false }
        if let bundle = input.bundleId, Classify.hardFloatBundleIds.contains(bundle) { return false }
        if input.isPiP || input.layerOrIsHUD || input.isVisualIntelligenceOrSiriHUD { return false }
        let ruleSaysFloat = config.windowRules.contains {
            $0.action == .float && $0.matches(bundleId: input.bundleId, title: input.title)
        }
        return !ruleSaysFloat
    }

    func trackedId(matching element: AXUIElement) -> UInt32? {
        if let id = adapter.cachedWindowId(for: element), ownedAnywhere(id) || elements[id] != nil {
            return id
        }
        return elements.first(where: { CFEqual($0.value, element) })?.key
    }

    func markBorn(_ id: UInt32) {
        bornAt[id] = Date()
        if bornAt.count > 2000 {
            let cutoff = Date().addingTimeInterval(-120)
            bornAt = bornAt.filter { $0.value > cutoff }
        }
    }

    /// True within the grace period after a window joined the session. Fresh
    /// windows are often briefly invisible to AX/CG; pruning them immediately
    /// just forces a lossy re-adopt (or loses them entirely).
    func isYoung(_ id: UInt32) -> Bool {
        guard let b = bornAt[id] else { return false }
        return Date().timeIntervalSince(b) < 5
    }

    func forgetBorn(_ id: UInt32) {
        bornAt[id] = nil
    }

    func staleOwnedWindow(pid: pid_t, liveId: UInt32, element: AXUIElement) -> UInt32? {
        let live = Set(
            (CGWindowListCopyWindowInfo([.excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? [])
                .compactMap(cgWindowID)
        )
        var ownedForPid: [WindowRef] = []
        for space in session.spaces.values {
            ownedForPid.append(contentsOf: space.tiledLeaves().compactMap(\.leaf).filter { $0.pid == pid })
            ownedForPid.append(contentsOf: space.floating.filter { $0.pid == pid })
        }
        let stale = ownedForPid.filter { !live.contains($0.cgWindowId) && $0.cgWindowId != liveId }
        let unmatched = ownedForPid.filter { !live.contains($0.cgWindowId) }
        guard stale.count == 1, unmatched.count == 1, !ownedAnywhere(liveId) else { return nil }
        return stale[0].cgWindowId
    }

    func rebindOwned(from: UInt32, to: UInt32, element: AXUIElement, pid: pid_t) {
        session = session.rebindWindowId(from: from, to: to)
        if let original = knownOriginals[from] {
            knownOriginals[to] = original
            knownOriginals[from] = nil
        }
        if let minSize = observedMinSizes[from] {
            observedMinSizes[to] = minSize
            observedMinSizes[from] = nil
        }
        overflowStrikes[from] = nil
        for sid in session.spaces.keys {
            if session.spaces[sid]?.focusedWindow == from {
                session.spaces[sid]?.focusedWindow = to
            }
        }
        elements[from] = nil
        adapter.forgetWindowId(from)
        adapter.rememberWindowId(to, for: element)
        elements[to] = element
        observers.watchWindow(element, pid: pid)
    }

    /// A rebind can swap a placeholder window for the app's real one (or the
    /// reverse). Re-run classification so a splash's floating role does not
    /// stick to the real window.
    func reclassifyRebound(id: UInt32, pid: pid_t, element: AXUIElement, onScreen: Set<UInt32>) {
        guard let bound, let window = windowAnywhere(id) else { return }
        let result: ClassifyResult
        if window.role == .luminaFS { return }
        if let (input, _, _) = classifyInput(from: element, adapter: adapter, bound: bound, onScreenIds: onScreen) {
            result = classify(input, rules: config.windowRules)
        } else {
            return
        }
        let sid = session.spaceContaining(cgWindowId: id) ?? session.focusedSpace
        guard let space = session.spaces[sid] else { return }
        let usable = bound.usableRect(gaps: config.gaps)
        if result == .tiled, space.floating.contains(where: { $0.cgWindowId == id }) {
            log.info("rebind retile window=\(id) pid=\(pid)")
            session = session.tileFloater(space: sid, cgWindowId: id, usableIsWide: usableIsWide(usable))
            clampOverflowOn(sid)
        } else if result == .floating, let leaf = space.leaf(containing: id) {
            log.info("rebind refloat window=\(id) pid=\(pid)")
            session = session.floatLeaf(space: sid, nodeId: leaf.id).0
        }
    }

    /// Per-window teardown shared by every removal path: stop the resize
    /// debounce, drop a move/resize tag, clear the native-focus sync guard,
    /// and forget every per-window map entry.
    func forgetWindowState(_ id: UInt32) {
        lastWindowClosedAt = Date()
        if lastSyncedNativeFocusedId == id {
            lastSyncedNativeFocusedId = nil
        }
        if let start = moveStart, start.0 == id {
            moveStart = nil
        }
        resizeDebounce[id]?.cancel()
        resizeDebounce[id] = nil
        if let element = elements[id] {
            // Rebound elements can be replaced without a destroyed note; drop
            // their observer registrations explicitly.
            observers.forgetWindow(element)
        }
        elements[id] = nil
        adapter.forgetWindowId(id)
        forgetBorn(id)
        knownOriginals[id] = nil
        observedMinSizes[id] = nil
        overflowStrikes[id] = nil
    }

    /// Drop a window that is really gone: close it on the focused space, remove
    /// it elsewhere, and forget every per-window map entry.
    func removeDestroyedWindow(_ id: UInt32) {
        let wasFS = session.current.luminaFullscreen != nil
            && session.current.nodes[session.current.luminaFullscreen!]?.leaf?.cgWindowId == id
        forgetWindowState(id)
        session.nativeFSWindows.removeAll { $0.cgWindowId == id }
        for spaceId in Array(session.spaces.keys) {
            if spaceId == session.focusedSpace {
                session = session.closeWindow(space: spaceId, cgWindowId: id)
            } else {
                session = session.removeWindow(space: spaceId, cgWindowId: id)
            }
        }
        if wasFS { unstashSpace(session.focusedSpace) }
    }

    func isOffEveryDisplay(_ rect: Rect) -> Bool {
        let frames = NSScreen.screens.compactMap { BoundDisplay.from(screen: $0, menuBarMaxY: menuBarMaxY())?.axFrame }
        return !frames.contains { $0.contains(point: rect.center) }
    }

    func onMovedOrResized(_ element: AXUIElement, resized: Bool) {
        guard let id = adapter.windowId(for: element) else { return }
        if let w = windowAnywhere(id), adapter.shouldIgnoreAXGeometry(window: w) {
            // A single setFrame emits several Moved/Resized notifications. Keep
            // the tag until its timer expires so the rest of the burst is not
            // mistaken for a user drag.
            return
        }
        if !resized {
            handleTitleBarMove(id: id, element: element)
            return
        }
        resizeDebounce[id]?.cancel()
        let item = DispatchWorkItem { [weak self] in
            self?.resizeDebounce[id] = nil
            self?.handleUntaggedResize(id: id, element: element)
        }
        resizeDebounce[id] = item
        MutationQueue.shared.queue.asyncAfter(deadline: .now() + 0.05, execute: item)
    }

    func handleUntaggedResize(id: UInt32, element: AXUIElement) {
        guard let bound, let frame = adapter.frame(of: element) else { return }
        let usable = bound.usableRect(gaps: config.gaps)
        // Our own layout landing late: if the frame is the model tile, this is
        // not a user resize and must not be classified as a fill.
        if let leaf = session.current.leaf(containing: id),
           let expected = frames(space: session.current, usable: usable, gaps: config.gaps)[leaf.id],
           framesClose(frame, expected, slop: 2)
        {
            return
        }
        let pidAlive = adapter.pid(of: element).map { kill($0, 0) == 0 } ?? false
        let onScreen = Set(onScreenCGWindows(intersecting: bound.axFrame).compactMap(cgWindowID))
        let signals = NativeFSSignals(
            missingFromOnScreen: !onScreen.contains(id),
            pidAlive: pidAlive,
            spaceChangeRecently: Date().timeIntervalSince(lastSpaceChange) < 1.0,
            axFullscreen: adapter.isFullscreen(element),
            skyLightIdChanged: skyLightChanged()
        )
        if isNativeFullscreen(signals), let leaf = session.current.leaf(containing: id) {
            let wasFS = session.current.luminaFullscreen == leaf.id
            session = session.detachNativeFS(space: session.focusedSpace, nodeId: leaf.id)
            // Detaching the lumina-FS leaf restores sibling roles; their
            // frames still need unstashing.
            if wasFS { unstashSpace(session.focusedSpace) }
            applyFrames()
            return
        }
        if onScreen.contains(id), !adapter.isFullscreen(element),
           let parked = session.nativeFSWindows.first(where: { $0.cgWindowId == id })
        {
            if session.spaceContaining(cgWindowId: id) != nil {
                // Already grafted back on an earlier pass; just drop the
                // stale bookmark instead of inserting a second leaf.
                session.nativeFSWindows.removeAll { $0.cgWindowId == id }
                return
            }
            let bookmarkSpace = parked.nativeFSBookmark?.spaceId ?? session.focusedSpace
            session = session.reinsertNativeFS(parked, usableIsWide: usableIsWide(usable))
            applyFrames()
            if bookmarkSpace != session.focusedSpace {
                // The window's home space is hidden; park it there rather
                // than leaving it on top of the space the user is viewing.
                stash(ids: [id], space: bookmarkSpace)
            }
            return
        }
        guard session.current.leaf(containing: id) != nil else { return }
        switch classifyInPlaceResize(frame: frame, usable: usable) {
        case .fill:
            if let leaf = session.current.leaf(containing: id) {
                session = session.enterLuminaFS(space: session.focusedSpace, leaf: leaf.id)
                stashSiblings()
                applyFrames()
            }
        case .halfQuarter, .fight:
            applyFrames()
        }
    }

    func handleTitleBarMove(id: UInt32, element: AXUIElement) {
        let nowCount = NSPasteboard.general.changeCount
        let loc = NSEvent.mouseLocation
        let axPoint = Point(x: Double(loc.x), y: menuBarMaxY() - Double(loc.y))
        let frame = adapter.frame(of: element) ?? Rect(x: 0, y: 0, w: 0, h: 0)
        let start = moveStart
        if session.current.floating.contains(where: { $0.cgWindowId == id && $0.role == .floating }) {
            if var space = session.spaces[session.focusedSpace],
               let idx = space.floating.firstIndex(where: { $0.cgWindowId == id })
            {
                // A floater the user placed themselves: quit restores this spot.
                space.floating[idx].lastOnscreenFrame = frame
                space.floating[idx].originalFrame = frame
                session.spaces[session.focusedSpace] = space
            }
            return
        }
        if start == nil {
            let origin = lookup(id)?.lastOnscreenFrame.center ?? frame.center
            moveStart = (id, origin, nowCount)
            return
        }
        guard let start, start.0 == id else { return }
        let displacement = frame.center.distance(to: start.1)
        let over = hitTile(at: axPoint)?.cgWindowId
        let probe = TitleBarSwapProbe(
            pasteboardChanged: nowCount != start.2,
            displacement: displacement,
            pointerOverTile: over != nil && over != id,
            mouseButtonsDown: NSEvent.pressedMouseButtons != 0,
            generationInFlight: adapter.generationInFlight(for: id)
        )
        if NSEvent.pressedMouseButtons == 0 {
            if shouldTitleBarSwap(probe), let other = over {
                session = session.swap(space: session.focusedSpace, a: id, b: other)
            } else if let leaf = session.current.leaf(containing: id),
                      let rect = frames(
                        space: session.current,
                        usable: bound?.usableRect(gaps: config.gaps) ?? frame,
                        gaps: config.gaps
                      )[leaf.id],
                      var window = leaf.leaf
            {
                _ = adapter.setFrame(rect, of: element, tag: &window)
                writeWindow(window)
            }
            applyFrames()
            moveStart = nil
        }
    }

    func onTitleChanged(_ element: AXUIElement) {
        guard let bound, let id = adapter.windowId(for: element) else {
            scheduleRefresh(reason: "title")
            return
        }
        guard ownedAnywhere(id) else {
            scheduleRefresh(reason: "title")
            return
        }
        let onScreen = Set(onScreenCGWindows(intersecting: bound.axFrame).compactMap(cgWindowID))
        guard let (input, _, _) = classifyInput(from: element, adapter: adapter, bound: bound, onScreenIds: onScreen) else { return }
        let result = classify(input, rules: config.windowRules)
        if result == .floating, let leaf = session.current.leaf(containing: id) {
            let (after, _) = session.floatLeaf(space: session.focusedSpace, nodeId: leaf.id)
            session = after
            applyFrames()
        } else if result == .tiled, session.current.floating.contains(where: { $0.cgWindowId == id }) {
            session = session.tileFloater(space: session.focusedSpace, cgWindowId: id, usableIsWide: usableIsWide(bound.usableRect(gaps: config.gaps)))
            applyFrames()
        }
    }

    func handleBound(_ command: BoundCommand) {
        if isStopping() || userPaused || displayGone || !isCurrent { return }
        log.info("command \(command.commandString)")
        switch command {
        case .focus(let dir):
            focusDir(dir)
        case .swap(let dir):
            if let target = spatialTarget(dir) {
                let a = focusedId() ?? 0
                let b = target.cgWindowId
                session = session.swap(space: session.focusedSpace, a: a, b: b)
                // A swap that involves a floater only exchanges
                // `lastOnscreenFrame` in the model. Push the floating side's
                // frame out before `applyFrames` syncs floaters back from the
                // live frame, or the move is undone (and a tile<->floater swap
                // leaves the displaced window under the newly tiled one).
                let floatersAfter = session.current.floating.filter {
                    $0.role == .floating && ($0.cgWindowId == a || $0.cgWindowId == b)
                }
                for w in floatersAfter {
                    guard let el = resolvedElement(for: w) else { continue }
                    var pushed = w
                    _ = adapter.setFrame(w.lastOnscreenFrame, of: el, tag: &pushed)
                    writeWindow(pushed)
                }
                applyFrames()
            }
        case .resize(let delta):
            resize(delta)
        case .workspace(let n):
            if let id = resolveWorkspace(id: n, count: session.spaceCount) {
                switchSpace(id)
            }
        case .workspacePrev:
            switchSpaceBy { $0.workspacePrev() }
        case .workspaceNext:
            switchSpaceBy { $0.workspaceNext() }
        case .moveNodeToWorkspace(let n):
            if let id = resolveWorkspace(id: n, count: session.spaceCount) {
                guard let focused = focusedId() else {
                    log.info("move-node-to-workspace \(n) skipped: no focused window")
                    return
                }
                captureSpaceSwitch(from: session.focusedSpace)
                rememberFocus(focused)
                let usable = bound?.usableRect(gaps: config.gaps) ?? Rect(x: 0, y: 0, w: 1, h: 1)
                let from = session.focusedSpace.raw
                session = session.moveNodeToWorkspace(id, usableIsWide: usableIsWide(usable))
                log.info("move-node-to-workspace window=\(focused) \(from)->\(id.raw) focusedSpace=\(session.focusedSpace.raw)")
                clampOverflowOn(id)
                // The destination may hold parked windows; bring them back
                // before laying out, like switchSpace does.
                unstashSpace(id)
                restashOffspace()
                applyFrames()
                nativeFocus(focused)
                writeSession()
            }
        case .balance:
            session = session.balance(space: session.focusedSpace)
            applyFrames()
        case .fullscreenLumina:
            let wasFS = session.current.luminaFullscreen != nil
            session = session.toggleLuminaFS(space: session.focusedSpace)
            if session.current.luminaFullscreen != nil {
                stashSiblings()
            } else if wasFS {
                // Exiting fullscreen: parked floaters need their frames back;
                // tiled siblings are re-laid-out by applyFrames.
                unstashSpace(session.focusedSpace)
            }
            applyFrames()
        case .fullscreenNative:
            if let id = focusedId(), let window = windowAnywhere(id),
               let el = resolvedElement(for: window)
            {
                // Toggle, like Hyprland's fullscreen: pressing again exits.
                adapter.setFullscreen(el, !adapter.isFullscreen(el))
            }
        case .floatToggle:
            let usable = bound?.usableRect(gaps: config.gaps) ?? Rect(x: 0, y: 0, w: 1, h: 1)
            let toggledId = focusedId()
            let wasFS = session.current.luminaFullscreen != nil
            session = session.floatToggle(space: session.focusedSpace, usableIsWide: usableIsWide(usable))
            if session.current.luminaFullscreen != nil, let toggledId,
               session.current.leaf(containing: toggledId) != nil
            {
                // Retiling a floater while lumina-fullscreen is active only
                // marks it stashed; park it or it stays on top of the FS window.
                stash(ids: [toggledId])
            } else if wasFS {
                // Floating the FS leaf exits fullscreen: bring its parked
                // floaters and siblings back on screen.
                unstashSpace(session.focusedSpace)
            }
            applyFrames()
        case .close:
            if let id = focusedId(), let window = windowAnywhere(id),
               let el = resolvedElement(for: window)
            {
                adapter.pressClose(of: el)
            }
        }
    }

    func handleAgent(_ cmd: AgentCmd, id: String) -> IPCResponse {
        if case .debugWindows = cmd { return .success(id: id, data: debugWindowsJSON()) }
        if isStopping(), case .status = cmd {
            // Let a poll during shutdown answer instead of wedging the caller.
        } else if isStopping() {
            return .failure(id: id, error: "agent is quitting")
        }
        switch cmd {
        case .status, .markCurrent, .quit, .yield, .listWindows, .listWorkspaces, .verify,
             .accessibilityPrompt:
            break
        default:
            if userPaused || displayGone || !isCurrent { return .success(id: id) }
        }
        switch cmd {
        case .workspace(let n):
            guard resolveWorkspace(id: n, count: session.spaceCount) != nil else {
                return .failure(id: id, error: "workspace \(n) out of range")
            }
            handleBound(.workspace(n))
            return .success(id: id)
        case .workspacePrev:
            handleBound(.workspacePrev); return .success(id: id)
        case .workspaceNext:
            handleBound(.workspaceNext); return .success(id: id)
        case .moveNodeToWorkspace(let n):
            guard resolveWorkspace(id: n, count: session.spaceCount) != nil else {
                return .failure(id: id, error: "workspace \(n) out of range")
            }
            handleBound(.moveNodeToWorkspace(n)); return .success(id: id)
        case .focus(let d):
            handleBound(.focus(Direction(rawValue: d.rawValue) ?? .left)); return .success(id: id)
        case .swap(let d):
            handleBound(.swap(Direction(rawValue: d.rawValue) ?? .left)); return .success(id: id)
        case .resize(let d):
            handleBound(.resize(d == .grow ? .grow : .shrink)); return .success(id: id)
        case .balance:
            handleBound(.balance); return .success(id: id)
        case .floatToggle:
            handleBound(.floatToggle); return .success(id: id)
        case .fullscreen(let mode):
            handleBound(mode == .lumina ? .fullscreenLumina : .fullscreenNative); return .success(id: id)
        case .close:
            handleBound(.close); return .success(id: id)
        case .pause:
            userPaused = true
            unregisterHotkeys()
            startOrStopFFM()
            return .success(id: id)
        case .resume:
            if !displayGone {
                userPaused = false
                if isCurrent { registerHotkeys() }
                startOrStopFFM()
                refreshOriginalsFromLive()
            }
            return .success(id: id)
        case .reload:
            if let error = reloadConfig() {
                return .failure(id: id, error: error)
            }
            return .success(id: id)
        case .quit:
            stop()
            DispatchQueue.main.async { NSApp.terminate(nil) }
            return .success(id: id)
        case .listWindows:
            return .success(id: id, data: listWindowsJSON())
        case .listWorkspaces:
            return .success(id: id, data: listWorkspacesJSON())
        case .verify:
            return .success(id: id, data: verifyWindowsJSON())
        case .status:
            return .success(id: id, data: statusJSON())
        case .markCurrent:
            recomputeCurrentToken(reason: .start)
            return .success(id: id)
        case .yield:
            isCurrent = false
            unregisterHotkeys()
            startOrStopFFM()
            return .success(id: id)
        case .accessibilityPrompt:
            requestAgentAXPrompt()
            return .success(id: id)
        case .debugWindows:
            return .success(id: id, data: debugWindowsJSON())
        }
    }

    func applyFrames() {
        if isStopping() || userPaused || displayGone || !isCurrent { return }
        refreshBound()
        guard let bound else { return }
        let applyInterval = LuminaSignposts.pointsOfInterest.beginInterval("apply-frames")
        defer { LuminaSignposts.pointsOfInterest.endInterval("apply-frames", applyInterval) }
        let started = Date()
        let usable = bound.usableRect(gaps: config.gaps)
        let space = session.current
        let rects = frames(space: space, usable: usable, gaps: config.gaps)
        let fs = space.luminaFullscreen
        let liveIds = cgWindowIds()
        var ghosts: [UInt32] = []
        var budgetBroke = false
        var visited: Set<NodeId> = []
        var overflowed = false
        for (nodeId, rect) in rects {
            if MutationQueue.shared.shouldSkip(started: started) {
                budgetBroke = true
                log.info("layout pass exceeded 200ms; rescheduling remaining windows")
                break
            }
            visited.insert(nodeId)
            // While lumina-fullscreen is active every other leaf is a parked
            // sibling and must not be written. The FS leaf itself is owned by
            // the dedicated block below, so the loop writes nothing.
            if fs != nil { continue }
            guard var node = space.nodes[nodeId], var window = node.leaf,
                  let el = resolvedElement(for: window)
            else {
                if let node = space.nodes[nodeId], let window = node.leaf, !liveIds.contains(window.cgWindowId),
                   !isYoung(window.cgWindowId)
                {
                    log.info("applyFrames missing window=\(window.cgWindowId) bundle=\(window.bundleId ?? "?")")
                    ghosts.append(window.cgWindowId)
                }
                continue
            }
            let liveBefore = adapter.frame(of: el)
            if let live = liveBefore, framesClose(live, rect, slop: 2) {
                // Already at the tile. Rewriting every frame on every pass
                // makes apps repaint and flicker for no reason.
                window.lastOnscreenFrame = rect
                node.leaf = window
                var s = session.spaces[session.focusedSpace]!
                s.setNode(node)
                session.spaces[session.focusedSpace] = s
                overflowStrikes[window.cgWindowId] = nil
                continue
            }
            window.lastOnscreenFrame = rect
            let result = adapter.setFrame(rect, of: el, tag: &window)
            node.leaf = window
            var s = session.spaces[session.focusedSpace]!
            s.setNode(node)
            session.spaces[session.focusedSpace] = s
            if result != .ok {
                // Best effort. The next refresh session re-issues the layout;
                // no model state changes because of a write result.
                if case .rejected(let err) = result {
                    log.info("setFrame rejected(\(err.rawValue)) window=\(window.cgWindowId) bundle=\(window.bundleId ?? "?"); will retry next pass")
                } else {
                    log.info("setFrame timeout window=\(window.cgWindowId) bundle=\(window.bundleId ?? "?"); will retry next pass")
                }
            }
            if let live = adapter.frame(of: el) {
                // An app that refuses to shrink below its real minimum keeps
                // its old frame across the write. That must be seen twice
                // before it becomes a minimum: one read can be a slow app
                // that simply has not applied the new size yet. A partial
                // application (neither old nor target) is not a refusal.
                let askedToShrink = (liveBefore?.w ?? 0) > rect.w + 4
                    || (liveBefore?.h ?? 0) > rect.h + 4
                let stillOverflows = live.w > rect.w + 4 || live.h > rect.h + 4
                let keptOldSize = liveBefore.map { framesClose(live, $0, slop: 4) } ?? false
                if askedToShrink, stillOverflows, keptOldSize {
                    let strikes = (overflowStrikes[window.cgWindowId] ?? 0) + 1
                    overflowStrikes[window.cgWindowId] = strikes
                    if strikes >= 2 {
                        let prior = observedMinSizes[window.cgWindowId] ?? .unknown
                        observedMinSizes[window.cgWindowId] = Size(
                            w: live.w > rect.w + 4 ? max(prior.w, live.w) : prior.w,
                            h: live.h > rect.h + 4 ? max(prior.h, live.h) : prior.h
                        )
                        overflowed = true
                    }
                } else {
                    overflowStrikes[window.cgWindowId] = nil
                }
                // A busy app can land the size but drop the position, leaving
                // the window overlapping its neighbours. Re-issue once when
                // the position is wrong. Size clamps are left alone on
                // purpose: read-back size checks retried forever on apps like
                // Ghostty.
                if abs(live.x - rect.x) > 24 || abs(live.y - rect.y) > 24 {
                    log.info("layout retry window=\(window.cgWindowId) bundle=\(window.bundleId ?? "?") live=\(Int(live.x)),\(Int(live.y)) target=\(Int(rect.x)),\(Int(rect.y))")
                    _ = adapter.setFrame(rect, of: el, tag: &window)
                    writeWindow(window)
                }
            }
        }
        if overflowed, !clampingOverflow {
            // Re-clamp with the observed minimums so the offender floats
            // instead of overlapping. The flag stops a window whose minimum
            // cannot fit at all from looping.
            clampingOverflow = true
            defer { clampingOverflow = false }
            log.info("layout overflow: clamping with observed minimum sizes")
            clampOverflowOn(session.focusedSpace)
            applyFrames()
            return
        }
        if !overflowStrikes.isEmpty, !clampingOverflow {
            // A first refusal strike needs a quick second look to confirm.
            scheduleRefresh(reason: "overflowCheck", delay: 0.2)
        }
        if let fs, let node = space.nodes[fs], let fsWindow = node.leaf {
            if var window = node.leaf, let el = resolvedElement(for: window) {
                if let live = adapter.frame(of: el), !framesClose(live, usable, slop: 2) {
                    _ = adapter.setFrame(usable, of: el, tag: &window)
                    if let retryLive = adapter.frame(of: el),
                       abs(retryLive.x - usable.x) > 24 || abs(retryLive.y - usable.y) > 24
                    {
                        _ = adapter.setFrame(usable, of: el, tag: &window)
                    }
                }
                window.lastOnscreenFrame = usable
                writeWindow(window)
            } else if !liveIds.contains(fsWindow.cgWindowId), !isYoung(fsWindow.cgWindowId) {
                // The fullscreen window died without a destroy note; the main
                // loop no longer sees it, so record the ghost here.
                log.info("applyFrames missing fullscreen window=\(fsWindow.cgWindowId)")
                ghosts.append(fsWindow.cgWindowId)
            }
        }
        if var s = session.spaces[session.focusedSpace] {
            for i in s.floating.indices where s.floating[i].role == .floating {
                guard let el = resolvedElement(for: s.floating[i]),
                      let live = adapter.frame(of: el),
                      !framesClose(live, s.floating[i].lastOnscreenFrame, slop: 2),
                      !isStashedAway(live)
                else { continue }
                // Never record a park frame as a floater's saved position: a
                // window we forgot to unstash would lose where it belongs.
                s.floating[i].lastOnscreenFrame = live
            }
            session.spaces[session.focusedSpace] = s
        }
        if !ghosts.isEmpty {
            for id in ghosts {
                log.info("prune ghost window=\(id)")
                removeDestroyedWindow(id)
            }
            applyFrames()
            return
        }
        if budgetBroke, isCurrent, !userPaused, !displayGone {
            // One continuation pass covers exactly the windows this pass
            // skipped, so a hot spot in front of the loop never leaves a tile
            // at a stale frame until some unrelated event.
            let deferredNodes = rects.keys.filter { !visited.contains($0) && $0 != fs }
            MutationQueue.shared.queue.asyncAfter(deadline: .now() + 0.15) { [weak self] in
                guard let self, self.isCurrent, !self.userPaused, !self.displayGone else { return }
                let pending = self.framePending(spaceId: self.session.focusedSpace, nodeIds: deferredNodes)
                guard !pending.isEmpty else { return }
                log.info("layout continuation windows=\(pending.count)")
                self.applyLayout(pending)
            }
        }
    }

    /// Frames for `nodeIds`, recomputed after the budget break (the tree may
    /// have moved on). All tiled leaves are returned; `applyLayout` applies
    /// exactly these rects.
    func framePending(spaceId: SpaceId, nodeIds: [NodeId]) -> [NodeId: Rect] {
        guard let bound, let space = session.spaces[spaceId] else { return [:] }
        let wanted = Set(nodeIds)
        let usable = bound.usableRect(gaps: config.gaps)
        return frames(space: space, usable: usable, gaps: config.gaps).filter { wanted.contains($0.key) }
    }

    /// Apply a subset of frames, without the ghost/budget machinery.
    func applyLayout(_ rects: [NodeId: Rect]) {
        guard !isStopping() else { return }
        let space = session.current
        let fs = space.luminaFullscreen
        for (nodeId, rect) in rects {
            if let fs, fs != nodeId { continue }
            guard var node = space.nodes[nodeId], var window = node.leaf,
                  let el = resolvedElement(for: window)
            else { continue }
            if let live = adapter.frame(of: el), framesClose(live, rect, slop: 2) { continue }
            window.lastOnscreenFrame = rect
            let result = adapter.setFrame(rect, of: el, tag: &window)
            node.leaf = window
            var s = session.spaces[session.focusedSpace]
            s?.setNode(node)
            if let s { session.spaces[session.focusedSpace] = s }
            if result != .ok {
                if case .rejected(let err) = result {
                    log.info("continuation setFrame rejected(\(err.rawValue)) window=\(window.cgWindowId)")
                } else if result == .unknown {
                    log.info("continuation setFrame timeout window=\(window.cgWindowId)")
                }
            }
            if let live = adapter.frame(of: el), abs(live.x - rect.x) > 24 || abs(live.y - rect.y) > 24 {
                log.info("continuation retry window=\(window.cgWindowId) live=\(Int(live.x)),\(Int(live.y)) target=\(Int(rect.x)),\(Int(rect.y))")
                _ = adapter.setFrame(rect, of: el, tag: &window)
                writeWindow(window)
            }
        }
    }

    func captureOnscreenFrames(for spaceId: SpaceId) {
        guard let bound else { return }
        let display = DisplayFrame(axFrame: bound.axFrame, axVisibleFrame: bound.axVisibleFrame)
        guard var space = session.spaces[spaceId] else { return }
        for (nodeId, var node) in space.nodes {
            guard var leaf = node.leaf, let el = elements[leaf.cgWindowId] ?? resolvedElement(for: leaf) else { continue }
            if let current = adapter.frame(of: el) ?? cgWindowRect(id: leaf.cgWindowId),
               shouldCaptureOnscreenFrame(role: leaf.role, frame: current, display: display) {
                leaf.lastOnscreenFrame = current
                node.leaf = leaf
                space.nodes[nodeId] = node
            }
        }
        for i in space.floating.indices {
            let id = space.floating[i].cgWindowId
            guard let el = elements[id] ?? resolvedElement(for: space.floating[i]) else { continue }
            if let current = adapter.frame(of: el) ?? cgWindowRect(id: id),
               shouldCaptureOnscreenFrame(role: space.floating[i].role, frame: current, display: display) {
                space.floating[i].lastOnscreenFrame = current
            }
        }
        session.spaces[spaceId] = space
    }

    /// Bookkeeping shared by every path that changes the focused space: stamp
    /// the switch, remember the outgoing space's focus and live frames, and
    /// drop the native-focus sync guard.
    func captureSpaceSwitch(from source: SpaceId) {
        lastLuminaSpaceChange = Date()
        captureFocusForSpaceSwitch()
        captureOnscreenFrames(for: source)
        lastSyncedNativeFocusedId = nil
    }

    func switchSpace(_ id: SpaceId) {
        guard id != session.focusedSpace else { return }
        let source = session.focusedSpace
        captureSpaceSwitch(from: source)
        // Unhide the destination first, then hide the source: fewer frames
        // cross on screen at once and there is no hole to see.
        session = session.switchTo(id)
        unstashSpace(id)
        applyFrames()
        stash(ids: Set(session.visibleIds(on: source)), space: source)
        restashOffspace()
        focusRestoredWindow(on: id)
        writeSession()
        // A dropped park or tile write settles on the next pass instead of
        // staying visible until the user clicks something.
        scheduleRefresh(reason: "switchSettle", delay: 0.4)
    }

    func switchSpaceBy(_ transform: (Session) -> Session) {
        let source = session.focusedSpace
        captureSpaceSwitch(from: source)
        session = transform(session)
        unstashSpace(session.focusedSpace)
        applyFrames()
        if session.focusedSpace != source {
            stash(ids: Set(session.visibleIds(on: source)), space: source)
        }
        restashOffspace()
        focusRestoredWindow(on: session.focusedSpace)
        writeSession()
        scheduleRefresh(reason: "switchSettle", delay: 0.4)
    }

    /// Remember the currently focused window on the outgoing space so a later
    /// return trip can restore it. Prefers the live front-to-back order over
    /// the model, which may already have diverged from real OS focus.
    func captureFocusForSpaceSwitch() {
        if let id = frontmostOwnedWindow() ?? focusedId() {
            rememberFocus(id)
        }
    }

    /// Raise and focus the destination space's restoration candidate. Moving
    /// windows on screen via AX does not focus them, so without this the user
    /// must click or cmd-tab after every workspace switch.
    func focusRestoredWindow(on id: SpaceId) {
        guard let target = session.spaces[id]?.focusRestorationCandidate() else { return }
        nativeFocus(target)
    }

    /// Apply native focus once: main, raise, activate. No retry loop; a failed
    /// activation is fixed by the next activation notification or refresh.
    /// Hidden-role windows are never raised.
    func nativeFocus(_ id: UInt32) {
        guard let window = windowAnywhere(id) else { return }
        guard window.role == .tiled || window.role == .floating || window.role == .luminaFS else {
            return
        }
        rememberFocus(id)
        guard let el = resolvedElement(for: window) else {
            log.info("focus missing AX window=\(id)")
            return
        }
        adapter.nativeFocus(el, pid: window.pid)
        log.info("focus window=\(id) space=\(session.focusedSpace.raw) bundle=\(window.bundleId ?? "?")")
    }

    /// Hide the windows of an inactive space: move them to the corner only.
    /// No verification and no retry; the next refresh/layout pass re-parks any
    /// window that did not land.
    func stash(ids: Set<UInt32>, space spaceId: SpaceId? = nil) {
        guard !isStopping(), isCurrent, let bound else { return }
        let spaceId = spaceId ?? session.focusedSpace
        let dockRight = bound.axVisibleFrame.maxX < bound.axFrame.maxX
        let display = DisplayFrame(axFrame: bound.axFrame, axVisibleFrame: bound.axVisibleFrame)
        for id in ids {
            guard var window = session.spaces[spaceId]?.leaf(containing: id)?.leaf
                    ?? session.spaces[spaceId]?.floating.first(where: { $0.cgWindowId == id })
                    ?? lookup(id),
                  let el = resolvedElement(for: window)
            else {
                log.info("stash skip missing AX window=\(id)")
                continue
            }
            let current = adapter.frame(of: el) ?? cgWindowRect(id: id)
            if let current, shouldCaptureOnscreenFrame(role: window.role, frame: current, display: display),
               var space = session.spaces[spaceId]
            {
                if var node = space.leaf(containing: id) {
                    node.leaf?.lastOnscreenFrame = current
                    space.setNode(node)
                }
                if let idx = space.floating.firstIndex(where: { $0.cgWindowId == id }) {
                    space.floating[idx].lastOnscreenFrame = current
                }
                session.spaces[spaceId] = space
            }
            let height = current?.h ?? window.lastOnscreenFrame.h
            let width = current?.w ?? window.lastOnscreenFrame.w
            let inset: Double = window.bundleId == "us.zoom.xos" ? 0 : 1
            let parked = stashFrame(for: height, display: display, dockRight: dockRight, lastWidth: width, inset: inset)
            if let live = adapter.frame(of: el), isFrameStashedAway(live, display: display) {
                // Already hidden. macOS clamps a park so a sliver stays on screen;
                // there is nothing to verify or retry. Re-park only when the window
                // is back on screen.
            } else {
                _ = adapter.setStashPosition(Point(x: parked.x, y: parked.y), of: el, tag: &window)
            }
            if var space = session.spaces[spaceId] {
                if var node = space.leaf(containing: id), let saved = node.leaf {
                    window.lastOnscreenFrame = saved.lastOnscreenFrame
                    node.leaf = window
                    space.setNode(node)
                }
                if let idx = space.floating.firstIndex(where: { $0.cgWindowId == id }) {
                    window.lastOnscreenFrame = space.floating[idx].lastOnscreenFrame
                    space.floating[idx] = window
                }
                session.spaces[spaceId] = space
            }
        }
    }

    func stashSiblings() {
        let fs = session.current.nodes[session.current.luminaFullscreen ?? NodeId(raw: 0)]?.leaf?.cgWindowId
        let ids = Set(session.visibleIds(on: session.focusedSpace).filter { $0 != fs })
        stash(ids: ids)
    }

    func unstashSpace(_ id: SpaceId, restoreOriginals: Bool = false) {
        guard let space = session.spaces[id] else { return }
        // A space with active lumina-fullscreen keeps its siblings and
        // floaters parked; applyFrames owns the FS leaf.
        guard space.luminaFullscreen == nil else { return }
        for node in space.tiledLeaves() {
            if let w = node.leaf {
                if restoreOriginals { restoreOriginal(w) } else { restoreWindow(w) }
            }
        }
        for w in space.floating {
            if restoreOriginals { restoreOriginal(w) } else { restoreWindow(w) }
        }
    }

    func hasAXElement(_ window: WindowRef) -> Bool {
        if let el = elements[window.cgWindowId], adapter.pid(of: el) == window.pid, adapter.isLiveElement(el) {
            return true
        }
        return adapter.axWindow(pid: window.pid, cgWindowId: window.cgWindowId) != nil
    }

    func restoreWindow(_ window: WindowRef) {
        var w = window
        let target = usableRestoreRect(w.lastOnscreenFrame)
        guard let el = resolvedElement(for: w) else {
            log.info("unstash missing AX window=\(w.cgWindowId) bundle=\(w.bundleId ?? "?")")
            return
        }
        // Electron often ignores a jump from a 1px sliver; bump size first.
        if let cur = cgWindowRect(id: w.cgWindowId), isSliver(cur) {
            let bump = Rect(x: target.x, y: target.y, w: max(400, min(target.w, 800)), h: max(300, min(target.h, 600)))
            _ = adapter.setFrame(bump, of: el, tag: &w)
        }
        _ = adapter.setFrame(target, of: el, tag: &w)
        // A busy app can drop the move; re-issue once when it did not land.
        if let live = adapter.frame(of: el), !framesClose(live, target, slop: 2) {
            log.info(
                "restore retry window=\(w.cgWindowId) bundle=\(w.bundleId ?? "?") live=\(Int(live.w))x\(Int(live.h)) target=\(Int(target.w))x\(Int(target.h))"
            )
            _ = adapter.setFrame(target, of: el, tag: &w)
        }
        if let cur = cgWindowRect(id: w.cgWindowId), isSliver(cur), let el2 = resolvedElement(for: w) {
            log.info("unstash still sliver window=\(w.cgWindowId); retry usable")
            _ = adapter.setFrame(usableRestoreRect(Rect(x: 0, y: 0, w: 1, h: 1)), of: el2, tag: &w)
        }
        writeWindow(w)
    }

    /// Quit path: put the window back where the user had it before tiling.
    /// A saved frame that is really the engine's tile (the app reopened at a
    /// tile-shaped frame from an earlier Lumina session) cannot untile
    /// anything, so it is rejected in favor of a cascade.
    func restoreOriginal(_ window: WindowRef) {
        var w = window
        var hadOriginal = w.originalFrame != nil
        if let original = w.originalFrame, isEngineTile(original, for: window) {
            knownOriginals[w.cgWindowId] = nil
            w.originalFrame = nil
            hadOriginal = false
        }
        if let original = w.originalFrame, let bound,
           looksLikeEngineFrame(original, usable: bound.usableRect(gaps: config.gaps), gaps: config.gaps)
        {
            // A tile-shaped frame from any earlier layout (not just the
            // current one) is not the user's geometry.
            knownOriginals[w.cgWindowId] = nil
            w.originalFrame = nil
            hadOriginal = false
        }
        w.lastOnscreenFrame = w.originalFrame ?? fallbackRestoreRect()
        let t = w.lastOnscreenFrame
        log.info("quit restore window=\(w.cgWindowId) bundle=\(w.bundleId ?? "?") original=\(hadOriginal) target=\(Int(t.w))x\(Int(t.h)) @\(Int(t.x)),\(Int(t.y))")
        restoreWindow(w)
    }

    /// True when a saved original is where the engine currently tiles this
    /// window: the app handed back a frame Lumina itself produced.
    func isEngineTile(_ rect: Rect, for window: WindowRef) -> Bool {
        guard let bound, let sid = session.spaceContaining(cgWindowId: window.cgWindowId),
              let space = session.spaces[sid],
              let leaf = space.leaf(containing: window.cgWindowId)
        else { return false }
        let tiles = frames(space: space, usable: bound.usableRect(gaps: config.gaps), gaps: config.gaps)
        guard let tile = tiles[leaf.id] else { return false }
        return framesClose(rect, tile, slop: 2)
    }

    func fallbackRestoreRect() -> Rect {
        let usable = bound?.usableRect(gaps: config.gaps) ?? Rect(x: 40, y: 48, w: 1200, h: 800)
        defer { restoreCascadeIndex += 1 }
        return cascadeRestoreRect(usable: usable, index: restoreCascadeIndex)
    }

    /// Remember a transiently-pruned window's original so a later re-adopt
    /// reuses it instead of capturing the tile rect. Real closes prune the
    /// map instead (see handleDestroy/dropPid).
    func stashKnownOriginal(_ id: UInt32) {
        if let w = windowAnywhere(id), let original = w.originalFrame {
            knownOriginals[id] = original
        }
    }

    /// Layout made while paused is the user's own: adopt it as the new
    /// originals. Parked frames are never adopted.
    func refreshOriginalsFromLive() {
        guard let bound else { return }
        let display = DisplayFrame(axFrame: bound.axFrame, axVisibleFrame: bound.axVisibleFrame)
        let usable = bound.usableRect(gaps: config.gaps)
        for spaceId in session.spaces.keys {
            guard var space = session.spaces[spaceId] else { continue }
            for (nodeId, var node) in space.nodes {
                guard var leaf = node.leaf, let el = elements[leaf.cgWindowId],
                      let live = adapter.frame(of: el),
                      !isFrameStashedAway(live, display: display),
                      !looksLikeEngineFrame(live, usable: usable, gaps: config.gaps)
                else { continue }
                leaf.originalFrame = live
                node.leaf = leaf
                space.nodes[nodeId] = node
                knownOriginals[leaf.cgWindowId] = live
            }
            for i in space.floating.indices {
                let w = space.floating[i]
                guard let el = elements[w.cgWindowId], let live = adapter.frame(of: el),
                      !isFrameStashedAway(live, display: display),
                      !looksLikeEngineFrame(live, usable: usable, gaps: config.gaps)
                else { continue }
                space.floating[i].originalFrame = live
                knownOriginals[w.cgWindowId] = live
            }
            session.spaces[spaceId] = space
        }
    }

    /// Quit path: put each managed window back where the user had it before
    /// tiling, falling back to a cascade when no usable original exists.
    func recenterAllWindows() {
        restoreCascadeIndex = 0
        for space in session.spaces.values {
            for node in space.tiledLeaves() {
                if let w = node.leaf { restoreOriginal(w) }
            }
            for w in space.floating { restoreOriginal(w) }
        }
    }

    func usableRestoreRect(_ preferred: Rect) -> Rect {
        let fallback = bound?.usableRect(gaps: config.gaps) ?? Rect(x: 40, y: 48, w: 1200, h: 800)
        guard let bound else { return fallback }
        let usable = bound.usableRect(gaps: config.gaps)
        var r = preferred
        if isSliver(r) || r.w < 200 || r.h < 150 {
            return usable
        }
        r.w = min(r.w, usable.w)
        r.h = min(r.h, usable.h)
        r.x = min(max(r.x, usable.x), usable.maxX - r.w)
        r.y = min(max(r.y, usable.y), usable.maxY - r.h)
        return r
    }

    func screenFrames() -> [Rect] {
        NSScreen.screens.compactMap { BoundDisplay.from(screen: $0, menuBarMaxY: menuBarMaxY())?.axFrame }
    }

    func shouldPullOnScreen(_ frame: Rect) -> Bool {
        guard let bound else { return false }
        if isStashedAway(frame) { return false }
        if bound.axFrame.contains(point: frame.center) { return false }
        if centerOnOtherDisplay(rect: frame, bound: bound.axFrame, screens: screenFrames()) { return false }
        return true
    }

    func isStrayOffscreen(_ frame: Rect) -> Bool {
        shouldPullOnScreen(frame) || isOurStashSliver(frame)
    }

    func placeFloated(_ windows: [WindowRef], space spaceId: SpaceId? = nil) {
        let sid = spaceId ?? session.focusedSpace
        for orig in windows {
            var w = orig
            w.lastOnscreenFrame = usableRestoreRect(w.lastOnscreenFrame)
            if let el = resolvedElement(for: w) {
                _ = adapter.setFrame(w.lastOnscreenFrame, of: el, tag: &w)
            }
            if var space = session.spaces[sid],
               let idx = space.floating.firstIndex(where: { $0.cgWindowId == w.cgWindowId })
            {
                space.floating[idx] = w
                session.spaces[sid] = space
            }
            log.info("floated overflow window=\(w.cgWindowId) bundle=\(w.bundleId ?? "?")")
        }
    }

    func isOurProcess(_ pid: pid_t) -> Bool {
        pid == getpid() || adapter.bundleId(pid: pid)?.hasPrefix("com.zelmari.lumina") == true
    }

    func cgWindowIds() -> Set<UInt32> {
        let info = CGWindowListCopyWindowInfo([.excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
        return Set(info.compactMap(cgWindowID))
    }

    func framesClose(_ a: Rect, _ b: Rect, slop: Double) -> Bool {
        abs(a.x - b.x) <= slop && abs(a.y - b.y) <= slop && abs(a.w - b.w) <= slop && abs(a.h - b.h) <= slop
    }

    func rescueOffscreenWindows(restoreOriginals: Bool = false) {
        guard let bound else { return }
        let display = DisplayFrame(axFrame: bound.axFrame, axVisibleFrame: bound.axVisibleFrame)
        let info = CGWindowListCopyWindowInfo([.excludeDesktopElements], kCGNullWindowID)
            as? [[String: Any]] ?? []
        for row in info {
            guard let id = cgWindowID(row), let pid = cgOwnerPID(row), let rect = cgWindowRect(row) else { continue }
            if isOurProcess(pid) { continue }
            let ours = lookup(id) != nil || isOurStashSliver(rect) || isCornerParked(rect, display: display)
            guard ours else { continue }
            let w = lookup(id)
                ?? WindowRef(cgWindowId: id, pid: pid, bundleId: adapter.bundleId(pid: pid), lastOnscreenFrame: usableRestoreRect(rect))
            log.info("rescue offscreen window=\(id) pid=\(pid) \(Int(rect.w))x\(Int(rect.h))")
            if restoreOriginals { restoreOriginal(w) } else { restoreWindow(w) }
        }
    }

    func resolvedElement(for window: WindowRef) -> AXUIElement? {
        if let el = elements[window.cgWindowId], adapter.pid(of: el) == window.pid, adapter.isLiveElement(el) {
            return el
        }
        adapter.forgetWindowId(window.cgWindowId)
        elements[window.cgWindowId] = nil
        if let el = adapter.axWindow(pid: window.pid, cgWindowId: window.cgWindowId) {
            elements[window.cgWindowId] = el
            return el
        }
        // Chromium/Electron keep the accessibility tree off; an owned window
        // whose element cannot be resolved is exactly when the wake matters.
        adapter.wakeAccessibility(pid: window.pid)
        log.info("no AX element for window=\(window.cgWindowId) pid=\(window.pid) bundle=\(window.bundleId ?? "?")")
        return nil
    }

    func isOurStashSliver(_ rect: Rect) -> Bool {
        guard isSliver(rect), rect.h >= 8, rect.w <= 2, let bound else { return false }
        let onRight = abs(rect.minX - (bound.axFrame.maxX - 1)) < 4
        let onLeft = abs(rect.minX - bound.axFrame.minX) < 4
        return onRight || onLeft
    }

    func isStashedAway(_ rect: Rect) -> Bool {
        guard let bound else { return isSliver(rect) }
        let display = DisplayFrame(axFrame: bound.axFrame, axVisibleFrame: bound.axVisibleFrame)
        return isFrameStashedAway(rect, display: display)
    }

    func ownedWindows(pid: pid_t) -> [(SpaceId, WindowRef)] {
        var out: [(SpaceId, WindowRef)] = []
        for (sid, space) in session.spaces {
            for w in space.tiledLeaves().compactMap(\.leaf) + space.floating where w.pid == pid {
                out.append((sid, w))
            }
        }
        return out
    }

    func isTileCandidate(_ element: AXUIElement) -> Bool {
        let role = adapter.role(of: element)
        if let role, Classify.nonWindowRoles.contains(role) { return false }
        let sub = adapter.subrole(of: element)
        if let sub, Classify.hardSubroles.contains(sub) { return false }
        if let frame = adapter.frame(of: element), isStashedAway(frame) { return false }
        if let frame = adapter.frame(of: element), frame.w >= 400, frame.h >= 300 { return true }
        return adapter.hasZoomButton(element)
    }

    func otherSpace(pid: pid_t, id: UInt32, element: AXUIElement) -> SpaceId? {
        if let sid = session.spaceContaining(cgWindowId: id), sid != session.focusedSpace {
            return sid
        }
        if let tracked = trackedId(matching: element),
           let sid = session.spaceContaining(cgWindowId: tracked),
           sid != session.focusedSpace
        {
            return sid
        }
        let owned = ownedWindows(pid: pid)
        let elsewhere = owned.filter { $0.0 != session.focusedSpace }
        guard !elsewhere.isEmpty else { return nil }
        if let found = elements.first(where: { CFEqual($0.value, element) }),
           let sid = session.spaceContaining(cgWindowId: found.key),
           sid != session.focusedSpace
        {
            return sid
        }
        return nil
    }

    func restashPid(_ pid: pid_t, on spaceId: SpaceId) {
        let ids = Set(ownedWindows(pid: pid).filter { $0.0 == spaceId }.map(\.1.cgWindowId))
        guard !ids.isEmpty else { return }
        log.info("restash pid=\(pid) space=\(spaceId) ids=\(ids)")
        stash(ids: ids, space: spaceId)
    }

    func unstashLeftovers() -> [StashEntry] {
        // CGWindowIDs are only meaningful within one boot. Session files from
        // an earlier boot must not seed frames onto recycled ids. A pending
        // directory can hold every display's session, so only claim files for
        // this agent's display, preferring this instance's own file.
        let boot = kernBootUUID() ?? ""
        let myDisplay = bound?.uuid ?? preferredDisplayUUID ?? ""
        var entries: [StashEntry] = []
        if let dir = ProcessInfo.processInfo.environment["LUMINA_UNSTASH_FROM"] {
            let names = (try? FileManager.default.contentsOfDirectory(atPath: dir)) ?? []
            var files: [(path: String, file: SessionFile)] = []
            for name in names where name.hasSuffix(".json") {
                let path = dir + "/" + name
                guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
                      let file = try? SessionFile.decode(data),
                      file.bootSessionUUID == boot
                else {
                    // Unreadable or from an earlier boot: never restorable.
                    try? FileManager.default.removeItem(atPath: path)
                    continue
                }
                files.append((path, file))
            }
            let own = files.filter { $0.file.instanceId == instanceId }
            let ordered = own.isEmpty ? files : own + files.filter { $0.file.instanceId != instanceId }
            for (path, file) in ordered {
                // Another display's agent owns this file; leave it in place.
                if !file.displayUUID.isEmpty, !myDisplay.isEmpty, file.displayUUID != myDisplay { continue }
                entries.append(contentsOf: file.stash)
                for (id, rect) in file.originals { knownOriginals[id] = rect }
                for e in file.stash {
                    if let original = e.originalFrame { knownOriginals[e.cgWindowId] = original }
                }
                try? FileManager.default.removeItem(atPath: path)
            }
            let remaining = (try? FileManager.default.contentsOfDirectory(atPath: dir)) ?? []
            if remaining.isEmpty {
                try? FileManager.default.removeItem(atPath: dir)
            }
        }
        if let data = try? Data(contentsOf: URL(fileURLWithPath: sessionPath)),
           let file = try? SessionFile.decode(data),
           file.bootSessionUUID == boot,
           file.displayUUID.isEmpty || myDisplay.isEmpty || file.displayUUID == myDisplay
        {
            entries.append(contentsOf: file.stash.filter { !isSliver($0.lastOnscreenFrame) || $0.lastOnscreenFrame.h >= 8 })
            for (id, rect) in file.originals { knownOriginals[id] = rect }
            for e in file.stash {
                if let original = e.originalFrame { knownOriginals[e.cgWindowId] = original }
            }
        }
        let info = CGWindowListCopyWindowInfo([.excludeDesktopElements], kCGNullWindowID)
            as? [[String: Any]] ?? []
        for row in info {
            guard let id = cgWindowID(row),
                  let pid = cgOwnerPID(row),
                  let rect = cgWindowRect(row),
                  isOurStashSliver(rect)
            else { continue }
            let known = entries.first { $0.cgWindowId == id }
            let restore = known.flatMap { isSliver($0.lastOnscreenFrame) ? nil : ($0.originalFrame ?? $0.lastOnscreenFrame) }
                ?? usableRestoreRect(rect)
            entries.append(StashEntry(cgWindowId: id, pid: pid, bundleId: known?.bundleId, lastOnscreenFrame: restore, originalFrame: known?.originalFrame))
        }
        for e in entries {
            let frame = usableRestoreRect(e.originalFrame ?? e.lastOnscreenFrame)
            let w = WindowRef(cgWindowId: e.cgWindowId, pid: e.pid, bundleId: e.bundleId, lastOnscreenFrame: frame, originalFrame: e.originalFrame ?? e.lastOnscreenFrame)
            restoreWindow(w)
        }
        rescueOffscreenWindows()
        return entries
    }

    func restashOffspace() {
        for (id, _) in session.spaces where id != session.focusedSpace {
            stash(ids: Set(session.visibleIds(on: id)), space: id)
        }
        if session.current.luminaFullscreen != nil { stashSiblings() }
    }

    func writeSession(stash stashOverride: [StashEntry]? = nil) {
        let entries = stashOverride ?? session.collectStashEntries(exceptSpace: session.focusedSpace)
        let file = SessionFile(
            instanceId: instanceId,
            bootSessionUUID: kernBootUUID() ?? "",
            focusedSpace: session.focusedSpace.raw,
            displayUUID: bound?.uuid ?? "",
            stash: entries,
            originals: session.collectOriginals().merging(knownOriginals) { current, _ in current }
        )
        let dir = (sessionPath as NSString).deletingLastPathComponent
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: dir)
        let tmp = sessionPath + ".tmp"
        if let data = try? SessionFile.encode(file) {
            try? data.write(to: URL(fileURLWithPath: tmp))
            rename(tmp, sessionPath)
        }
    }

    func focusDir(_ dir: Direction) {
        guard let target = spatialTarget(dir),
              let window = windowAnywhere(target.cgWindowId),
              let el = resolvedElement(for: window)
        else { return }
        // Activate the target's app: AX focus/raise alone leaves keystrokes
        // with the previous app when the neighbour is in a background app.
        adapter.nativeFocus(el, pid: window.pid)
        var space = session.current
        space.focusedWindow = target.cgWindowId
        if target.role == .tiled, let leaf = space.leaf(containing: target.cgWindowId) {
            space.lastTiledLeaf = leaf.id
        }
        session.spaces[session.focusedSpace] = space
    }

    func spatialTarget(_ dir: Direction) -> SpatialWindow? {
        guard let bound, let focused = focusedId() else { return nil }
        let usable = bound.usableRect(gaps: config.gaps)
        let rects = frames(space: session.current, usable: usable, gaps: config.gaps)
        var windows: [SpatialWindow] = []
        for node in session.current.tiledLeaves() {
            if session.current.luminaFullscreen != nil, session.current.luminaFullscreen != node.id { continue }
            if let w = node.leaf, let frame = rects[node.id] {
                windows.append(SpatialWindow(id: node.id, role: .tiled, frame: frame, cgWindowId: w.cgWindowId))
            }
        }
        for w in session.current.floating where w.role == .floating {
            windows.append(SpatialWindow(role: .floating, frame: w.lastOnscreenFrame, cgWindowId: w.cgWindowId))
        }
        guard let from = windows.first(where: { $0.cgWindowId == focused }) else { return nil }
        return focusSpatial(windows: windows, from: from, dir: dir)
    }

    func resize(_ delta: ResizeDelta) {
        guard let bound, let focused = focusedId(), let leaf = session.current.leaf(containing: focused) else { return }
        let usable = bound.usableRect(gaps: config.gaps)
        let (after, floated) = session.resize(
            space: session.focusedSpace,
            focusedLeaf: leaf.id,
            delta: delta,
            minSizes: minSizes(),
            usable: usable,
            gaps: config.gaps
        )
        session = after
        if let floated { placeFloated([floated]) }
        applyFrames()
    }

    func refreshBound() {
        adapter.menuBarScreenMaxY = menuBarMaxY()
        if let uuid = bound?.uuid ?? preferredDisplayUUID {
            bound = BoundDisplay.resolve(
                menuBarMaxY: adapter.menuBarScreenMaxY,
                focusedCenter: nil,
                preferredUUID: uuid
            ) ?? bound
        } else {
            bound = BoundDisplay.resolve(menuBarMaxY: adapter.menuBarScreenMaxY, focusedCenter: nil)
        }
    }

    /// Float any window whose minimum size cannot fit its tile, so an app that
    /// refuses to shrink cannot permanently overlap its neighbour. Falls back
    /// on the focused (newest) leaf, like the insert path.
    @discardableResult
    func clampOverflowOn(_ spaceId: SpaceId) -> Bool {
        // Only the focused space is on screen, and a lumina-fullscreen space
        // must not have its parked siblings floated back into view.
        guard spaceId == session.focusedSpace,
              session.spaces[spaceId]?.luminaFullscreen == nil,
              let bound else { return false }
        let usable = bound.usableRect(gaps: config.gaps)
        let (clamped, floated) = session.clampOverflow(
            space: spaceId,
            minSizes: minSizes(),
            usable: usable,
            gaps: config.gaps,
            preferFloat: session.spaces[spaceId]?.lastTiledLeaf
        )
        session = clamped
        if !floated.isEmpty {
            placeFloated(floated, space: spaceId)
        }
        return !floated.isEmpty
    }

    func minSizes() -> [UInt32: Size] {
        var out: [UInt32: Size] = [:]
        for (id, el) in elements {
            let size = adapter.minSize(of: el)
            if size != .unknown { out[id] = size }
        }
        for (id, size) in observedMinSizes {
            if let existing = out[id] {
                out[id] = Size(w: max(existing.w, size.w), h: max(existing.h, size.h))
            } else {
                out[id] = size
            }
        }
        return out
    }

    func focusedId() -> UInt32? {
        if let id = session.current.focusedWindow, owned(id) { return id }
        if let id = frontmostOwnedWindow() {
            rememberFocus(id)
            return id
        }
        return nil
    }

    func rememberFocus(_ id: UInt32) {
        guard windowAnywhere(id) != nil else { return }
        let sid = session.spaceContaining(cgWindowId: id) ?? session.focusedSpace
        var space = session.spaces[sid] ?? session.current
        space.focusedWindow = id
        if let leaf = space.leaf(containing: id) {
            space.lastTiledLeaf = leaf.id
        }
        session.spaces[sid] = space
    }

    func frontmostOwnedWindow() -> UInt32? {
        guard let bound else { return nil }
        let fs = session.current.luminaFullscreen
        for row in onScreenCGWindows(intersecting: bound.axFrame) {
            guard let id = cgWindowID(row), owned(id), let window = lookup(id) else { continue }
            // Parked windows (including hidden-space floaters whose 1px
            // sliver intersects the display) are never focus candidates.
            if window.role == .stashed { continue }
            if let fs, let leaf = session.current.leaf(containing: id), leaf.id != fs { continue }
            return id
        }
        if let fs {
            return session.current.nodes[fs]?.leaf?.cgWindowId
                ?? session.current.floating.first(where: { $0.role != .stashed })?.cgWindowId
        }
        return session.current.tiledLeaves().first(where: { $0.leaf?.role != .stashed })?.leaf?.cgWindowId
            ?? session.current.floating.first(where: { $0.role != .stashed })?.cgWindowId
    }

    func owned(_ id: UInt32) -> Bool {
        session.current.leaf(containing: id) != nil || session.current.floating.contains(where: { $0.cgWindowId == id })
    }

    func ownedAnywhere(_ id: UInt32) -> Bool {
        session.spaceContaining(cgWindowId: id) != nil
    }

    func lookup(_ id: UInt32) -> WindowRef? {
        session.current.leaf(containing: id)?.leaf ?? session.current.floating.first(where: { $0.cgWindowId == id })
    }

    func windowAnywhere(_ id: UInt32) -> WindowRef? {
        for space in session.spaces.values {
            if let leaf = space.leaf(containing: id)?.leaf { return leaf }
            if let floating = space.floating.first(where: { $0.cgWindowId == id }) { return floating }
        }
        return nil
    }

    func writeWindow(_ window: WindowRef) {
        for sid in session.spaces.keys {
            guard var space = session.spaces[sid] else { continue }
            if var node = space.leaf(containing: window.cgWindowId), node.leaf != nil {
                node.leaf = window
                space.setNode(node)
                session.spaces[sid] = space
                return
            }
            if let idx = space.floating.firstIndex(where: { $0.cgWindowId == window.cgWindowId }) {
                space.floating[idx] = window
                session.spaces[sid] = space
                return
            }
        }
    }

    func hitTile(at point: Point) -> SpatialWindow? {
        spatialWindows().first { $0.role == .tiled && $0.frame.contains(point: point) }
    }

    func spatialWindows() -> [SpatialWindow] {
        guard let bound else { return [] }
        let usable = bound.usableRect(gaps: config.gaps)
        let rects = frames(space: session.current, usable: usable, gaps: config.gaps)
        var windows: [SpatialWindow] = []
        for node in session.current.tiledLeaves() {
            if session.current.luminaFullscreen != nil, session.current.luminaFullscreen != node.id { continue }
            if let w = node.leaf, let frame = rects[node.id] {
                windows.append(SpatialWindow(id: node.id, role: .tiled, frame: frame, cgWindowId: w.cgWindowId))
            }
        }
        for w in session.current.floating where w.role == .floating {
            windows.append(SpatialWindow(role: .floating, frame: w.lastOnscreenFrame, cgWindowId: w.cgWindowId))
        }
        return windows
    }

    func dropPid(_ pid: pid_t) {
        let fsBefore = session.current.luminaFullscreen
        let ids = elements.filter { adapter.pid(of: $0.value) == pid }.map(\.key)
        for (_, window) in ownedWindows(pid: pid) {
            observedMinSizes[window.cgWindowId] = nil
            overflowStrikes[window.cgWindowId] = nil
        }
        for id in ids {
            for spaceId in Array(session.spaces.keys) {
                session = session.removeWindow(space: spaceId, cgWindowId: id)
            }
            forgetWindowState(id)
        }
        // A native-fullscreen window has no live element while it is on its
        // own Space, so it is not in `ids`; drop it by pid as well.
        session.nativeFSWindows.removeAll { $0.pid == pid }
        if fsBefore != nil, session.current.luminaFullscreen == nil {
            unstashSpace(session.focusedSpace)
        }
        applyFrames()
    }

    /// Adopt the frontmost app's own idea of its focused window: switch to the
    /// space containing it, or focus it if it is already here. Follow only when
    /// the native focused window id changed since the last sync; re-processing
    /// the same window caused focus ping-pong on every activation.
    func syncFocusToFrontmostApp(pid: pid_t) {
        let app = AXUIElementCreateApplication(pid)
        guard let focused = adapter.focusedWindow(of: app).flatMap({ adapter.windowId(for: $0) }),
              ownedAnywhere(focused),
              let window = windowAnywhere(focused),
              hasAXElement(window)
        else {
            restashOffspace()
            return
        }
        guard focused != lastSyncedNativeFocusedId else { return }
        lastSyncedNativeFocusedId = focused
        if let spaceId = session.spaceContaining(cgWindowId: focused), spaceId != session.focusedSpace {
            var s = session
            s.spaces[spaceId]?.focusedWindow = focused
            if let leaf = s.spaces[spaceId]?.leaf(containing: focused) {
                s.spaces[spaceId]?.lastTiledLeaf = leaf.id
            }
            session = s
            switchSpace(spaceId)
            return
        }
        nativeFocus(focused)
    }

    func recomputeCurrentToken(reason: CurrentReason) {
        guard let bound else { return }
        let cg = onScreenCGWindows(intersecting: bound.axFrame)
        let managed = managedWindowIds()
        let large = cg.contains { row in
            guard let id = cgWindowID(row), managed.contains(id), let b = cgWindowRect(row) else { return false }
            return isLargeOnScreen(width: b.w, height: b.h)
        }
        let cur = skyLight.currentSpaceId(displayUUID: bound.uuid)
        if let cur { observedSkyLightId = cur }
        let became = recomputeCurrent(
            reason: reason,
            skyLightCurrent: cur,
            skyLightSelf: boundSkyLightId,
            skyLightOthers: [],
            hasLargeOnScreen: large,
            isLastCurrent: isCurrent,
            otherClaims: false
        )
        if became && !isCurrent {
            isCurrent = true
            runRefresh(reason: "becameCurrent", space: session.focusedSpace)
            if !userPaused { registerHotkeys() }
        } else if !became && isCurrent {
            isCurrent = false
            unregisterHotkeys()
        }
        if reason == .start {
            isCurrent = true
            if !userPaused { registerHotkeys() }
            runRefresh(reason: "start", space: session.focusedSpace)
        }
        startOrStopFFM()
    }

    func managedWindowIds() -> Set<UInt32> {
        var ids = Set<UInt32>()
        for space in session.spaces.values {
            for node in space.tiledLeaves() {
                if let id = node.leaf?.cgWindowId { ids.insert(id) }
            }
            for w in space.floating { ids.insert(w.cgWindowId) }
        }
        for w in session.nativeFSWindows { ids.insert(w.cgWindowId) }
        return ids
    }

    func ownedPid(_ pid: pid_t?) -> Bool {
        guard let pid else { return false }
        return elements.values.contains { adapter.pid(of: $0) == pid }
    }

    func handleDisplayChange() {
        // Minimum sizes are display-relative; re-observe against the new one.
        observedMinSizes.removeAll()
        overflowStrikes.removeAll()
        adapter.menuBarScreenMaxY = menuBarMaxY()
        let available = NSScreen.screens.compactMap { BoundDisplay.from(screen: $0, menuBarMaxY: adapter.menuBarScreenMaxY)?.uuid }
        guard let bound else { return }
        if shouldStayPausedForDisplay(boundUUID: bound.uuid, availableUUIDs: available) {
            displayGone = true
            unregisterHotkeys()
            log.info("display gone uuid=\(bound.uuid)")
            return
        }
        if displayGone, shouldAutoResume(userPaused: userPaused, boundUUID: bound.uuid, availableUUIDs: available) {
            displayGone = false
            refreshBound()
            if isCurrent, !userPaused { registerHotkeys() }
            clampOverflowOn(session.focusedSpace)
            applyFrames()
            restashOffspace()
            return
        }
        // Still attached, but the usable geometry may have changed (scaled
        // resolution, Dock/menu bar, another display added). Re-apply so no
        // tile keeps a rect computed against the old frame.
        refreshBound()
        if isCurrent, !userPaused {
            clampOverflowOn(session.focusedSpace)
            applyFrames()
            restashOffspace()
        }
    }

    func skyLightChanged() -> Bool {
        guard let bound, let cur = skyLight.currentSpaceId(displayUUID: bound.uuid) else { return false }
        if observedSkyLightId == nil { observedSkyLightId = cur; return false }
        if observedSkyLightId != cur {
            observedSkyLightId = cur
            return true
        }
        return false
    }

    func launchConfiguredApps() {
        let running = NSWorkspace.shared.runningApplications.compactMap(\.bundleIdentifier)
        for id in config.launchApps {
            if skipAlreadyRunning(bundleId: id, running: running) { continue }
            guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: id) else {
                log.info("launch-apps skip unknown \(id)")
                continue
            }
            NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration()) { _, err in
                if err != nil { self.log.info("launch-apps failed \(id)") }
            }
        }
    }

    /// Returns the parse error when the new config was rejected, so `lumina
    /// reload` and the menu can report it instead of claiming success.
    @discardableResult
    func reloadConfig() -> String? {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let text = (try? String(contentsOfFile: LuminaPaths.configPath(home: home), encoding: .utf8)) ?? ""
        let (next, error) = applyReload(current: config, newText: text)
        configError = error
        guard error == nil else { return error }
        let oldCount = session.spaceCount
        config = next
        if next.spaceCount != oldCount {
            session = session.applySpaceCount(next.spaceCount, usableIsWide: usableIsWide(bound?.usableRect(gaps: next.gaps) ?? Rect(x: 0, y: 0, w: 1, h: 1)))
        }
        if isCurrent, !userPaused { registerHotkeys(next.bindings) }
        startOrStopFFM()
        applyFrames()
        return nil
    }

    func watchConfig() {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let path = LuminaPaths.configPath(home: home)
        let dir = (path as NSString).deletingLastPathComponent
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        watchConfigDirectory(dir)
        watchConfigFile(path)
    }

    /// Atomic replaces change the directory; in-place writes (`echo > file`)
    /// only touch the file vnode, so both are watched.
    private func watchConfigDirectory(_ dir: String) {
        let fd = open(dir, O_EVTONLY)
        guard fd >= 0 else { return }
        let src = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd,
            eventMask: [.write, .rename, .delete],
            queue: MutationQueue.shared.queue
        )
        src.setEventHandler { [weak self] in self?.scheduleConfigReload() }
        src.setCancelHandler { close(fd) }
        src.resume()
        configWatcher = src
    }

    private func watchConfigFile(_ path: String) {
        configFileWatcher?.cancel()
        configFileWatcher = nil
        let fd = open(path, O_EVTONLY)
        guard fd >= 0 else { return }
        let src = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd,
            eventMask: [.write, .delete, .rename, .extend, .attrib],
            queue: MutationQueue.shared.queue
        )
        src.setEventHandler { [weak self] in
            self?.scheduleConfigReload()
            // The vnode is stale after a replace/delete; watch the new file.
            self?.watchConfigFile(path)
        }
        src.setCancelHandler { close(fd) }
        src.resume()
        configFileWatcher = src
    }

    private func scheduleConfigReload() {
        configDebounce?.cancel()
        let item = DispatchWorkItem { [weak self] in self?.reloadConfig() }
        configDebounce = item
        MutationQueue.shared.queue.asyncAfter(deadline: .now() + 0.05, execute: item)
    }

    func startOrStopFFM() {
        ffmTimer?.cancel()
        ffmTimer = nil
        guard config.focusFollowsMouse, isCurrent, !userPaused else { return }
        let timer = DispatchSource.makeTimerSource(queue: MutationQueue.shared.queue)
        timer.schedule(deadline: .now(), repeating: 0.05)
        timer.setEventHandler { [weak self] in
            self?.ffmTick()
        }
        timer.resume()
        ffmTimer = timer
    }

    func ffmTick() {
        guard isCurrent, !userPaused, !displayGone else { return }
        // Never fight an in-progress workspace focus restoration.
        guard Date().timeIntervalSince(lastLuminaSpaceChange) > 0.5 else { return }
        let inFlight = managedWindowIds().contains { adapter.generationInFlight(for: $0) }
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            let down = NSEvent.pressedMouseButtons != 0
            let loc = NSEvent.mouseLocation
            let ax = Point(x: Double(loc.x), y: self.menuBarY() - Double(loc.y))
            MutationQueue.shared.hop {
                if shouldIgnoreFFM(mouseButtonsDown: down, generationInFlight: inFlight) { return }
                if let hit = self.spatialWindows().first(where: { $0.frame.contains(point: ax) }), hit.cgWindowId != self.focusedId() {
                    if let el = self.elements[hit.cgWindowId] { self.adapter.setFocused(el) }
                }
            }
        }
    }

    func menuBarY() -> Double {
        adapter.menuBarScreenMaxY
    }

    func pollSecureInput() {
        let timer = DispatchSource.makeTimerSource(queue: DispatchQueue.main)
        timer.schedule(deadline: .now(), repeating: 1.0)
        timer.setEventHandler { [weak self] in
            self?.secureInput = IsSecureEventInputEnabled()
        }
        timer.resume()
        secureTimer = timer
    }

    func installWorkspaceObservers() {}

    func listWindowsJSON() -> JSONValue {
        var windows: [JSONValue] = []
        for (spaceId, space) in session.spaces {
            for node in space.tiledLeaves() {
                if let w = node.leaf {
                    windows.append(.object([
                        "cgWindowId": .int(Int(w.cgWindowId)),
                        "pid": .int(Int(w.pid)),
                        "bundleId": .string(w.bundleId ?? ""),
                        "role": .string(w.role.rawValue),
                        "space": .int(spaceId.raw),
                        "x": .double(w.lastOnscreenFrame.x),
                        "y": .double(w.lastOnscreenFrame.y),
                        "w": .double(w.lastOnscreenFrame.w),
                        "h": .double(w.lastOnscreenFrame.h),
                    ]))
                }
            }
            for w in space.floating {
                windows.append(.object([
                    "cgWindowId": .int(Int(w.cgWindowId)),
                    "pid": .int(Int(w.pid)),
                    "bundleId": .string(w.bundleId ?? ""),
                    "role": .string(w.role.rawValue),
                    "space": .int(spaceId.raw),
                    "x": .double(w.lastOnscreenFrame.x),
                    "y": .double(w.lastOnscreenFrame.y),
                    "w": .double(w.lastOnscreenFrame.w),
                    "h": .double(w.lastOnscreenFrame.h),
                ]))
            }
        }
        return .object(["windows": .array(windows)])
    }

    func listWorkspacesJSON() -> JSONValue {
        let spaces: [JSONValue] = (1...session.spaceCount).compactMap { n in
            guard let id = SpaceId.make(n), let space = session.spaces[id] else { return nil }
            let count = space.tiledLeaves().count + space.floating.count
            return .object([
                "id": .int(n),
                "focused": .bool(session.focusedSpace == id),
                "windowCount": .int(count),
            ])
        }
        return .object([
            "focused": .int(session.focusedSpace.raw),
            "count": .int(session.spaceCount),
            "spaces": .array(spaces),
        ])
    }

    /// Machine-checkable invariants over the live model. An agent can run
    /// `lumina verify` after any command and fail on a non-empty list.
    func verifyWindowsJSON() -> JSONValue {
        guard let bound else {
            return .object([
                "ok": .bool(false),
                "issues": .array([.object(["kind": .string("no-display"), "detail": .string("agent has no bound display")])]),
            ])
        }
        let usable = bound.usableRect(gaps: config.gaps)
        var issues = verifySession(session, usable: usable, gaps: config.gaps)
        // A retained element that no longer answers is the pre-removal shape:
        // report it without enumerating every app (a busy app's failed read
        // would otherwise look like a dead window).
        for space in session.spaces.values {
            for w in space.tiledLeaves().compactMap(\.leaf) + space.floating {
                guard let el = elements[w.cgWindowId], adapter.pid(of: el) == w.pid else { continue }
                if !adapter.isAliveElement(el) {
                    issues.append(VerifyIssue(
                        "dead-element-window",
                        "window \(w.cgWindowId) (\(w.bundleId ?? "?")) has a dead AX element but is still in the model"
                    ))
                }
            }
        }
        // Occupancy: every tiled window on the focused space must actually be
        // sitting at its computed tile. A live window elsewhere means an
        // invisible leaf is occupying the tile.
        if session.current.luminaFullscreen == nil {
            let rects = frames(space: session.current, usable: usable, gaps: config.gaps)
            for node in session.current.tiledLeaves() where node.leaf?.role == .tiled {
                guard let w = node.leaf, let rect = rects[node.id],
                      let el = elements[w.cgWindowId], adapter.pid(of: el) == w.pid,
                      adapter.isAliveElement(el), let live = adapter.frame(of: el)
                else { continue }
                // Still settling: just adopted, a write in flight, or a first
                // overflow strike awaiting confirmation.
                if isYoung(w.cgWindowId) || adapter.generationInFlight(for: w.cgWindowId)
                    || overflowStrikes[w.cgWindowId] != nil
                {
                    continue
                }
                if !framesClose(live, rect, slop: 8) {
                    issues.append(VerifyIssue(
                        "tile-frame-mismatch",
                        "window \(w.cgWindowId) (\(w.bundleId ?? "?")) is at \(Int(live.x)),\(Int(live.y)) \(Int(live.w))x\(Int(live.h)) but its tile is \(Int(rect.x)),\(Int(rect.y)) \(Int(rect.w))x\(Int(rect.h))"
                    ))
                }
            }
        }
        // Hidden workspaces: every window must be physically parked. A role
        // of `.stashed` is not enough if the park write was dropped.
        for (sid, space) in session.spaces where sid != session.focusedSpace {
            for w in space.tiledLeaves().compactMap(\.leaf) + space.floating {
                guard let el = elements[w.cgWindowId], adapter.pid(of: el) == w.pid,
                      let live = adapter.frame(of: el),
                      !adapter.generationInFlight(for: w.cgWindowId)
                else { continue }
                if !isStashedAway(live) {
                    issues.append(VerifyIssue(
                        "hidden-window-onscreen",
                        "window \(w.cgWindowId) (\(w.bundleId ?? "?")) on workspace \(sid.raw) is on screen at \(Int(live.x)),\(Int(live.y))"
                    ))
                }
            }
        }
        return .object([
            "ok": .bool(issues.isEmpty),
            "focusedSpace": .int(session.focusedSpace.raw),
            "windowCount": .int(session.allWindowIds.count),
            "issues": .array(issues.map {
                .object(["kind": .string($0.kind), "detail": .string($0.detail)])
            }),
        ])
    }

    func hasOnScreenIncludingSlivers() -> Bool {
        guard let bound else { return false }
        let ids = Set(session.spaces.values.flatMap { space -> [UInt32] in
            space.tiledLeaves().compactMap { $0.leaf?.cgWindowId } + space.floating.map(\.cgWindowId)
        })
        guard !ids.isEmpty else { return false }
        let cg = onScreenCGWindows(intersecting: bound.axFrame)
        return cg.contains { row in
            guard let id = cgWindowID(row) else { return false }
            return ids.contains(id)
        }
    }

    func statusJSON() -> JSONValue {
        .object([
            "secureInput": .bool(secureInput),
            "axTrusted": .bool(axTrusted),
            "configError": configError.map { .string($0) } ?? .null,
            "configDiagnostics": .array(config.diagnostics.map { .string($0) }),
            "paused": .bool(userPaused),
            "displayGone": .bool(displayGone),
            "instanceId": .string(instanceId.uuidString),
            "space": .int(session.focusedSpace.raw),
            "spaceCount": .int(session.spaceCount),
            "isCurrent": .bool(isCurrent),
            "hasOnScreenIncludingSlivers": .bool(hasOnScreenIncludingSlivers()),
            "hotkeyError": hotkeys.hotkeyError.map { .string($0) } ?? .null,
            "skylightSpaceId": boundSkyLightId.map { .int(Int($0)) } ?? .null,
        ])
    }

    struct RefreshSummary: Equatable, Sendable {
        var reason: String
        var added: Int
        var removed: Int
        var rebinds: Int
        var unresolved: Bool
        var durationMs: Int
    }

    var lastRefreshSummary: RefreshSummary?

    func recordRefreshSummary(
        reason: String,
        added: Int,
        removed: Int,
        rebinds: Int,
        unresolved: Bool,
        started: Date
    ) {
        lastRefreshSummary = RefreshSummary(
            reason: reason,
            added: added,
            removed: removed,
            rebinds: rebinds,
            unresolved: unresolved,
            durationMs: Int(Date().timeIntervalSince(started) * 1000)
        )
    }

    func debugWindowsJSON() -> JSONValue {
        var windows: [JSONValue] = []
        for (spaceId, space) in session.spaces {
            for node in space.tiledLeaves() {
                if let w = node.leaf { windows.append(debugWindowJSON(w, space: spaceId)) }
            }
            for w in space.floating { windows.append(debugWindowJSON(w, space: spaceId)) }
        }
        for w in session.nativeFSWindows { windows.append(debugWindowJSON(w, space: nil)) }
        let lastRefresh: JSONValue = lastRefreshSummary.map { summary in
            .object([
                "reason": .string(summary.reason),
                "added": .int(summary.added),
                "removed": .int(summary.removed),
                "rebinds": .int(summary.rebinds),
                "unresolved": .bool(summary.unresolved),
                "durationMs": .int(summary.durationMs),
            ])
        } ?? .null
        return .object([
            "instanceId": .string(instanceId.uuidString),
            "focusedSpace": .int(session.focusedSpace.raw),
            "isCurrent": .bool(isCurrent),
            "userPaused": .bool(userPaused),
            "displayGone": .bool(displayGone),
            "boundDisplayUUID": bound.map { .string($0.uuid) } ?? .null,
            "spaceCount": .int(session.spaceCount),
            "windowCount": .int(windows.count),
            "lastRefresh": lastRefresh,
            "windows": .array(windows),
        ])
    }

    func debugWindowJSON(_ window: WindowRef, space: SpaceId?) -> JSONValue {
        let element = debugAXElement(for: window)
        let liveFrame = element.flatMap { adapter.frame(of: $0) }
        return .object([
            "cgWindowId": .int(Int(window.cgWindowId)),
            "pid": .int(Int(window.pid)),
            "bundleId": .string(window.bundleId ?? ""),
            "role": .string(window.role.rawValue),
            "space": space.map { .int($0.raw) } ?? .null,
            "lastOnscreenFrame": debugRectJSON(window.lastOnscreenFrame),
            "axElementResolves": .bool(element != nil),
            "liveAXFrame": liveFrame.map { debugRectJSON($0) } ?? .null,
        ])
    }

    func debugAXElement(for window: WindowRef) -> AXUIElement? {
        if let el = elements[window.cgWindowId], adapter.pid(of: el) == window.pid, adapter.isLiveElement(el) {
            return el
        }
        return adapter.axWindow(pid: window.pid, cgWindowId: window.cgWindowId)
    }

    func debugRectJSON(_ rect: Rect) -> JSONValue {
        .object([
            "x": .double(rect.x),
            "y": .double(rect.y),
            "w": .double(rect.w),
            "h": .double(rect.h),
        ])
    }
}

enum LuminaSignposts {
    static let pointsOfInterest = OSSignposter(subsystem: "com.zelmari.lumina", category: .pointsOfInterest)
}

#endif
