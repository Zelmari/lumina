#if os(macOS)
import AppKit
import ApplicationServices
import Carbon
import Foundation
import LuminaLayout
import LuminaIPC

public final class AgentRuntime: NSObject {
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
    public var lastSkyLightId: UInt64?
    public var axTrusted: Bool { AXIsProcessTrusted() }
    public var hotkeys = Hotkeys()
    public var secureInput = false
    public var configError: String?
    public var lastSpaceChange = Date.distantPast
    public var pasteboardCount: Int = 0
    public var moveStart: (UInt32, Point, Int)?
    public var createDebounce: DispatchWorkItem?
    public var resizeDebounce: DispatchWorkItem?

    let log: LuminaLog
    let adapter: AXAdapter
    let observers = AXObserverHub()
    let skyLight = SkyLightClient()
    var server: AgentSocketServer?
    var elements: [UInt32: AXUIElement] = [:]
    var ffmTimer: DispatchSourceTimer?
    var secureTimer: DispatchSourceTimer?
    var configWatcher: DispatchSourceFileSystemObject?
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
        self.config = loadOrDefault(text: text)
        self.session = Session.empty(spaceCount: config.spaceCount, instanceId: instanceId)
        super.init()
        _ = displayUUID
    }

    public func start() {
        adapter.setSystemTimeout()
        adapter.menuBarScreenMaxY = menuBarMaxY()
        bound = BoundDisplay.resolve(menuBarMaxY: adapter.menuBarScreenMaxY, focusedCenter: nil)
        if !axTrusted {
            log.info("AX not trusted; idling")
        }
        hotkeys.isPaused = { [weak self] in
            guard let self else { return true }
            return self.userPaused || self.displayGone || !self.isCurrent
        }
        hotkeys.onCommand = { [weak self] cmd in
            self?.handleBound(cmd)
        }
        if shouldRegisterHotkeys(isCurrent: isCurrent, paused: userPaused || displayGone) {
            hotkeys.register(bindings: config.bindings)
        }
        do {
            let server = AgentSocketServer(path: socketPath, log: log)
            server.onCommand = { [weak self] cmd, id in
                self?.handleAgent(cmd, id: id) ?? IPCResponse.failure(id: id, error: "gone")
            }
            try server.start()
            self.server = server
        } catch {
            log.error("socket failed")
        }
        installWorkspaceObservers()
        watchConfig()
        pollSecureInput()
        if axTrusted {
            bootLayout()
        }
        log.info("agent start instance=\(instanceId) crashRecover=\(crashRecover)")
    }

    public func stop() {
        unstashAll()
        writeSession(stash: [])
        hotkeys.unregister()
        server?.stop()
        ffmTimer?.cancel()
        secureTimer?.cancel()
        configWatcher?.cancel()
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
        session.nativeFSWindows = []
        if runLaunchApps {
            launchConfiguredApps()
        }
        let windows = collectManagedWindows()
        let tileable: [WindowRef]
        let floaters: [WindowRef]
        if config.launchTiling.isAliasFloatExisting {
            tileable = []
            floaters = windows
        } else {
            tileable = windows.filter { classifyWindow($0) == .tiled }.map(\.0)
            floaters = windows.filter { classifyWindow($0) == .floating }.map(\.0)
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
        applyFrames()
        watchRunningApps()
    }

    func classifyWindow(_ window: WindowRef) -> ClassifyResult {
        guard let el = elements[window.cgWindowId], let bound else { return .tiled }
        let onScreen = Set(onScreenCGWindows(intersecting: bound.axFrame).compactMap { $0[kCGWindowNumber as String] as? UInt32 })
        guard let (input, _, _) = classifyInput(from: el, adapter: adapter, bound: bound, onScreenIds: onScreen) else {
            return .tiled
        }
        return classify(input, rules: config.windowRules)
    }

    func collectManagedWindows() -> [(WindowRef)] {
        guard let bound else { return [] }
        var out: [WindowRef] = []
        let cg = onScreenCGWindows(intersecting: bound.axFrame)
        let onScreenIds = Set(cg.compactMap { $0[kCGWindowNumber as String] as? UInt32 })
        let apps = NSWorkspace.shared.runningApplications
        for app in apps {
            let pid = app.processIdentifier
            observers.watch(pid: pid)
            for el in adapter.windows(pid: pid) {
                guard let (input, id, _) = classifyInput(from: el, adapter: adapter, bound: bound, onScreenIds: onScreenIds) else { continue }
                let result = classify(input, rules: config.windowRules)
                if result == .unmanaged || result == .ignored { continue }
                elements[id] = el
                let frame = adapter.frame(of: el) ?? Rect(x: 0, y: 0, w: 0, h: 0)
                var w = WindowRef(cgWindowId: id, pid: pid, bundleId: app.bundleIdentifier, role: result == .floating ? .floating : .tiled, lastOnscreenFrame: frame)
                if result == .floating { w.role = .floating }
                out.append(w)
            }
        }
        // front-to-back: CG list is front-to-back already (index 0 frontmost)
        let order = cg.compactMap { $0[kCGWindowNumber as String] as? UInt32 }
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
        for app in NSWorkspace.shared.runningApplications {
            observers.watch(pid: app.processIdentifier)
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
        if let app = n.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication {
            MutationQueue.shared.hop { self.observers.watch(pid: app.processIdentifier) }
        }
    }

    @objc func appTerminated(_ n: Notification) {
        if let app = n.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication {
            MutationQueue.shared.hop {
                self.observers.unwatch(pid: app.processIdentifier)
                self.dropPid(app.processIdentifier)
            }
        }
    }

    @objc func appHidden(_ n: Notification) {
        if let app = n.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication {
            MutationQueue.shared.hop { self.adapter.unhide(pid: app.processIdentifier) }
        }
    }

    @objc func appActivated(_ n: Notification) {
        guard !userPaused, isCurrent else { return }
        if let app = n.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication {
            MutationQueue.shared.hop { self.switchToWindowOf(pid: app.processIdentifier) }
        }
    }

    @objc func spaceChanged(_ n: Notification) {
        lastSpaceChange = Date()
        MutationQueue.shared.hop { self.recomputeCurrentToken(reason: .spaceChange) }
    }

    @objc func didWake(_ n: Notification) {
        MutationQueue.shared.hop {
            self.recomputeCurrentToken(reason: .wake)
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
        case kAXWindowCreatedNotification:
            debounceCreate { self.onCreate(element) }
        case kAXUIElementDestroyedNotification:
            if let id = adapter.windowId(for: element) {
                session = session.removeWindow(space: session.focusedSpace, cgWindowId: id)
                elements[id] = nil
                applyFrames()
            }
        case kAXFocusedWindowChangedNotification:
            if let id = adapter.windowId(for: element), owned(id) {
                var space = session.current
                space.focusedWindow = id
                if let leaf = space.leaf(containing: id) {
                    space.lastTiledLeaf = leaf.id
                }
                session.spaces[session.focusedSpace] = space
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
            adapter.deminiaturize(element)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
                self?.adapter.deminiaturize(element)
            }
        default:
            break
        }
    }

    func debounceCreate(_ work: @escaping () -> Void) {
        createDebounce?.cancel()
        let item = DispatchWorkItem { work() }
        createDebounce = item
        MutationQueue.shared.queue.asyncAfter(deadline: .now() + 0.04, execute: item)
    }

    func onCreate(_ element: AXUIElement) {
        guard let bound else { return }
        let onScreen = Set(onScreenCGWindows(intersecting: bound.axFrame).compactMap { $0[kCGWindowNumber as String] as? UInt32 })
        guard let (input, id, pid) = classifyInput(from: element, adapter: adapter, bound: bound, onScreenIds: onScreen) else { return }
        let result = classify(input, rules: config.windowRules)
        if result == .unmanaged || result == .ignored { return }
        elements[id] = element
        let frame = adapter.frame(of: element) ?? Rect(x: 0, y: 0, w: 0, h: 0)
        let window = WindowRef(cgWindowId: id, pid: pid, bundleId: adapter.bundleId(pid: pid), role: .tiled, lastOnscreenFrame: frame)
        let usable = bound.usableRect(gaps: config.gaps)
        if session.current.luminaFullscreen != nil {
            session = session.insertWhileLuminaFS(space: session.focusedSpace, window: window, result: result, usableIsWide: usableIsWide(usable))
            if result == .tiled { stash(ids: [id]) }
        } else if result == .floating {
            var space = session.current
            var w = window
            w.role = .floating
            space.floating.append(w)
            session.spaces[session.focusedSpace] = space
        } else {
            session = session.insertSpiral(space: session.focusedSpace, newLeaf: window, usableIsWide: usableIsWide(usable))
            let mins = minSizes()
            let (clamped, floated) = session.clampOverflow(space: session.focusedSpace, minSizes: mins, usable: usable, gaps: config.gaps, preferFloat: session.current.lastTiledLeaf)
            session = clamped
            _ = floated
        }
        applyFrames()
    }

    func onMovedOrResized(_ element: AXUIElement, resized: Bool) {
        guard let id = adapter.windowId(for: element) else { return }
        if let w = lookup(id), adapter.shouldIgnoreAXGeometry(window: w) { return }
        if !resized {
            handleTitleBarMove(id: id, element: element)
            return
        }
        resizeDebounce?.cancel()
        let item = DispatchWorkItem { [weak self] in
            self?.handleUntaggedResize(id: id, element: element)
        }
        resizeDebounce = item
        MutationQueue.shared.queue.asyncAfter(deadline: .now() + 0.05, execute: item)
    }

    func handleUntaggedResize(id: UInt32, element: AXUIElement) {
        guard let bound, let frame = adapter.frame(of: element) else { return }
        let usable = bound.usableRect(gaps: config.gaps)
        let pidAlive = adapter.pid(of: element).map { kill($0, 0) == 0 } ?? false
        let onScreen = Set(onScreenCGWindows(intersecting: bound.axFrame).compactMap { $0[kCGWindowNumber as String] as? UInt32 })
        let signals = NativeFSSignals(
            missingFromOnScreen: !onScreen.contains(id),
            pidAlive: pidAlive,
            spaceChangeRecently: Date().timeIntervalSince(lastSpaceChange) < 1.0,
            axFullscreen: adapter.isFullscreen(element),
            skyLightIdChanged: skyLightChanged()
        )
        if isNativeFullscreen(signals), let leaf = session.current.leaf(containing: id) {
            session = session.detachNativeFS(space: session.focusedSpace, nodeId: leaf.id)
            applyFrames()
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
        if start == nil {
            moveStart = (id, frame.center, nowCount)
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
                applyFrames()
            }
            moveStart = nil
        }
    }

    func onTitleChanged(_ element: AXUIElement) {
        guard let bound, let id = adapter.windowId(for: element) else { return }
        let onScreen = Set(onScreenCGWindows(intersecting: bound.axFrame).compactMap { $0[kCGWindowNumber as String] as? UInt32 })
        guard let (input, _, _) = classifyInput(from: element, adapter: adapter, bound: bound, onScreenIds: onScreen) else { return }
        let result = classify(input, rules: config.windowRules)
        if result == .tiled, session.current.floating.contains(where: { $0.cgWindowId == id }) {
            session = session.floatToggle(space: session.focusedSpace, usableIsWide: usableIsWide(bound.usableRect(gaps: config.gaps)))
            applyFrames()
        }
    }

    func handleBound(_ command: BoundCommand) {
        if userPaused || displayGone || !isCurrent { return }
        switch command {
        case .focus(let dir):
            focusDir(dir)
        case .swap(let dir):
            if let target = spatialTarget(dir) {
                session = session.swap(space: session.focusedSpace, a: focusedId() ?? 0, b: target.cgWindowId)
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
                let usable = bound?.usableRect(gaps: config.gaps) ?? Rect(x: 0, y: 0, w: 1, h: 1)
                session = session.moveNodeToWorkspace(id, usableIsWide: usableIsWide(usable))
                restashOffspace()
                applyFrames()
                writeSession()
            }
        case .balance:
            session = session.balance(space: session.focusedSpace)
            applyFrames()
        case .fullscreenLumina:
            session = session.toggleLuminaFS(space: session.focusedSpace)
            if session.current.luminaFullscreen != nil { stashSiblings() }
            applyFrames()
        case .fullscreenNative:
            if let id = focusedId(), let el = elements[id] {
                adapter.setFullscreen(el, true)
            }
        case .floatToggle:
            let usable = bound?.usableRect(gaps: config.gaps) ?? Rect(x: 0, y: 0, w: 1, h: 1)
            session = session.floatToggle(space: session.focusedSpace, usableIsWide: usableIsWide(usable))
            applyFrames()
        case .close:
            if let id = focusedId(), let el = elements[id] {
                adapter.pressClose(of: el)
            }
        }
    }

    func handleAgent(_ cmd: AgentCmd, id: String) -> IPCResponse {
        switch cmd {
        case .workspace(let n):
            if let space = resolveWorkspace(id: n, count: session.spaceCount) { switchSpace(space) }
            return .success(id: id)
        case .workspacePrev:
            handleBound(.workspacePrev); return .success(id: id)
        case .workspaceNext:
            handleBound(.workspaceNext); return .success(id: id)
        case .moveNodeToWorkspace(let n):
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
            hotkeys.unregister()
            return .success(id: id)
        case .resume:
            if !displayGone {
                userPaused = false
                if isCurrent { hotkeys.register(bindings: config.bindings) }
            }
            return .success(id: id)
        case .reload:
            reloadConfig()
            return .success(id: id)
        case .quit:
            stop()
            DispatchQueue.main.async { NSApp.terminate(nil) }
            return .success(id: id)
        case .listWindows:
            return .success(id: id, data: listWindowsJSON())
        case .listWorkspaces:
            return .success(id: id, data: listWorkspacesJSON())
        case .status:
            return .success(id: id, data: statusJSON())
        }
    }

    func applyFrames() {
        if userPaused || displayGone || !isCurrent { return }
        guard let bound else { return }
        let started = Date()
        let usable = bound.usableRect(gaps: config.gaps)
        let space = session.current
        let rects = frames(space: space, usable: usable, gaps: config.gaps)
        let fs = space.luminaFullscreen
        for (nodeId, rect) in rects {
            if MutationQueue.shared.shouldSkip(started: started) {
                log.info("layout pass exceeded 200ms; skipping remaining windows")
                break
            }
            if let fs, fs != nodeId { continue }
            guard var node = space.nodes[nodeId], var window = node.leaf, let el = elements[window.cgWindowId] else { continue }
            window.lastOnscreenFrame = rect
            let result = adapter.setFrame(rect, of: el, tag: &window)
            node.leaf = window
            var s = session.spaces[session.focusedSpace]!
            s.setNode(node)
            session.spaces[session.focusedSpace] = s
            if result == .failed {
                session = session.floatLeaf(space: session.focusedSpace, nodeId: nodeId).0
            }
        }
        if let fs, let node = space.nodes[fs], var window = node.leaf, let el = elements[window.cgWindowId] {
            _ = adapter.setFrame(usable, of: el, tag: &window)
        }
        for floater in space.floating where floater.role == .floating {
            if let el = elements[floater.cgWindowId], floater.lastOnscreenFrame.w > 2 {
                var w = floater
                _ = adapter.setFrame(w.lastOnscreenFrame, of: el, tag: &w)
            }
        }
    }

    func switchSpace(_ id: SpaceId) {
        guard id != session.focusedSpace else { return }
        stash(ids: Set(session.visibleIds(on: session.focusedSpace)))
        session = session.switchTo(id)
        unstashSpace(id)
        applyFrames()
        writeSession()
    }

    func switchSpaceBy(_ transform: (Session) -> Session) {
        stash(ids: Set(session.visibleIds(on: session.focusedSpace)))
        session = transform(session)
        unstashSpace(session.focusedSpace)
        applyFrames()
        writeSession()
    }

    func stash(ids: Set<UInt32>) {
        guard let bound else { return }
        let dockRight = bound.axVisibleFrame.maxX < bound.axFrame.maxX
        for id in ids {
            guard let el = elements[id] else { continue }
            let current = adapter.frame(of: el)
            if let current, !isSliver(current), var space = session.spaces[session.focusedSpace] {
                if var node = space.leaf(containing: id) {
                    node.leaf?.lastOnscreenFrame = current
                    space.setNode(node)
                }
                if let idx = space.floating.firstIndex(where: { $0.cgWindowId == id }) {
                    space.floating[idx].lastOnscreenFrame = current
                }
                session.spaces[session.focusedSpace] = space
            }
            let height = current?.h ?? 8
            let sliver = stashFrame(for: height, display: DisplayFrame(axFrame: bound.axFrame, axVisibleFrame: bound.axVisibleFrame), dockRight: dockRight)
            if var dummy = lookup(id) {
                _ = adapter.setFrame(sliver, of: el, tag: &dummy)
            }
        }
    }

    func stashSiblings() {
        let fs = session.current.nodes[session.current.luminaFullscreen ?? NodeId(raw: 0)]?.leaf?.cgWindowId
        let ids = Set(session.visibleIds(on: session.focusedSpace).filter { $0 != fs })
        stash(ids: ids)
    }

    func unstashSpace(_ id: SpaceId) {
        guard let space = session.spaces[id] else { return }
        for node in space.tiledLeaves() {
            if let w = node.leaf, let el = elements[w.cgWindowId] {
                var ww = w
                _ = adapter.setFrame(w.lastOnscreenFrame, of: el, tag: &ww)
            }
        }
        for w in space.floating {
            if let el = elements[w.cgWindowId] {
                var ww = w
                _ = adapter.setFrame(w.lastOnscreenFrame, of: el, tag: &ww)
            }
        }
    }

    func unstashAll() {
        for spaceId in session.spaces.keys { unstashSpace(spaceId) }
    }

    func unstashLeftovers() -> [StashEntry] {
        var entries: [StashEntry] = []
        if let data = try? Data(contentsOf: URL(fileURLWithPath: sessionPath)),
           let file = try? SessionFile.decode(data)
        {
            entries.append(contentsOf: file.stash)
        }
        if let bound {
            let cg = onScreenCGWindows(intersecting: bound.axFrame)
            for row in cg {
                guard let id = row[kCGWindowNumber as String] as? UInt32,
                      let pid = row[kCGWindowOwnerPID as String] as? pid_t,
                      let bounds = row[kCGWindowBounds as String] as? [String: CGFloat]
                else { continue }
                let rect = Rect(x: Double(bounds["X"] ?? 0), y: Double(bounds["Y"] ?? 0), w: Double(bounds["Width"] ?? 0), h: Double(bounds["Height"] ?? 0))
                if isSliver(rect) {
                    entries.append(StashEntry(cgWindowId: id, pid: pid, bundleId: nil, lastOnscreenFrame: rect))
                }
            }
        }
        for e in entries {
            if let el = adapter.axWindow(pid: e.pid, cgWindowId: e.cgWindowId) {
                elements[e.cgWindowId] = el
                var w = WindowRef(cgWindowId: e.cgWindowId, pid: e.pid, bundleId: e.bundleId, lastOnscreenFrame: e.lastOnscreenFrame)
                _ = adapter.setFrame(e.lastOnscreenFrame, of: el, tag: &w)
            }
        }
        return entries
    }

    func restashOffspace() {
        for (id, _) in session.spaces where id != session.focusedSpace {
            stash(ids: Set(session.visibleIds(on: id)))
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
            stash: entries
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
        guard let target = spatialTarget(dir), let el = elements[target.cgWindowId] else { return }
        adapter.setFocused(el)
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
        let (after, _) = session.resize(
            space: session.focusedSpace,
            focusedLeaf: leaf.id,
            delta: delta,
            minSizes: minSizes(),
            usable: usable,
            gaps: config.gaps
        )
        session = after
        applyFrames()
    }

    func minSizes() -> [UInt32: Size] { [:] }

    func focusedId() -> UInt32? { session.current.focusedWindow }

    func owned(_ id: UInt32) -> Bool {
        session.current.leaf(containing: id) != nil || session.current.floating.contains(where: { $0.cgWindowId == id })
    }

    func lookup(_ id: UInt32) -> WindowRef? {
        session.current.leaf(containing: id)?.leaf ?? session.current.floating.first(where: { $0.cgWindowId == id })
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
        let ids = elements.filter { adapter.pid(of: $0.value) == pid }.map(\.key)
        for id in ids {
            session = session.removeWindow(space: session.focusedSpace, cgWindowId: id)
            session.nativeFSWindows.removeAll { $0.cgWindowId == id }
            elements[id] = nil
        }
        applyFrames()
    }

    func switchToWindowOf(pid: pid_t) {
        for (spaceId, space) in session.spaces {
            let hit = space.tiledLeaves().first { $0.leaf?.pid == pid }?.leaf?.cgWindowId
                ?? space.floating.first { $0.pid == pid }?.cgWindowId
            if let hit, spaceId != session.focusedSpace {
                var s = session
                s.spaces[spaceId]?.focusedWindow = hit
                session = s
                switchSpace(spaceId)
                return
            }
        }
    }

    func recomputeCurrentToken(reason: CurrentReason) {
        guard let bound else { return }
        let cg = onScreenCGWindows(intersecting: bound.axFrame)
        let large = cg.contains { row in
            guard let b = row[kCGWindowBounds as String] as? [String: CGFloat] else { return false }
            return isLargeOnScreen(width: Double(b["Width"] ?? 0), height: Double(b["Height"] ?? 0))
                && ownedPid(row[kCGWindowOwnerPID as String] as? pid_t)
        }
        let cur = skyLight.currentSpaceId(displayUUID: bound.uuid)
        let became = recomputeCurrent(
            reason: reason,
            skyLightCurrent: cur,
            skyLightSelf: lastSkyLightId,
            skyLightOthers: [],
            hasLargeOnScreen: large,
            isLastCurrent: isCurrent,
            otherClaims: false
        )
        if let cur { lastSkyLightId = lastSkyLightId ?? cur }
        if became && !isCurrent {
            isCurrent = true
            reconcile()
            if !userPaused { hotkeys.register(bindings: config.bindings) }
        } else if !became && isCurrent {
            isCurrent = false
            hotkeys.unregister()
        }
        if reason == .start {
            isCurrent = true
            if !userPaused { hotkeys.register(bindings: config.bindings) }
            reconcile()
        }
    }

    func ownedPid(_ pid: pid_t?) -> Bool {
        guard let pid else { return false }
        return elements.values.contains { adapter.pid(of: $0) == pid }
    }

    func reconcile() {
        let live = collectManagedWindows()
        let liveIds = Set(live.map(\.cgWindowId))
        for node in session.current.tiledLeaves() {
            if let id = node.leaf?.cgWindowId, !liveIds.contains(id) {
                session = session.remove(space: session.focusedSpace, node: node.id)
            }
        }
        for w in live {
            let known = session.spaces.values.contains { space in
                space.leaf(containing: w.cgWindowId) != nil || space.floating.contains(where: { $0.cgWindowId == w.cgWindowId })
            }
            if !known, classifyWindow(w) == .tiled {
                let usable = bound?.usableRect(gaps: config.gaps) ?? Rect(x: 0, y: 0, w: 1, h: 1)
                session = session.insertSpiral(space: session.focusedSpace, newLeaf: w, usableIsWide: usableIsWide(usable))
            }
        }
        applyFrames()
        restashOffspace()
    }

    func handleDisplayChange() {
        adapter.menuBarScreenMaxY = menuBarMaxY()
        let available = NSScreen.screens.compactMap { BoundDisplay.from(screen: $0, menuBarMaxY: adapter.menuBarScreenMaxY)?.uuid }
        guard let bound else { return }
        if shouldStayPausedForDisplay(boundUUID: bound.uuid, availableUUIDs: available) {
            displayGone = true
            hotkeys.unregister()
            log.info("display gone uuid=\(bound.uuid)")
            return
        }
        if displayGone, shouldAutoResume(userPaused: userPaused, boundUUID: bound.uuid, availableUUIDs: available) {
            displayGone = false
            self.bound = BoundDisplay.resolve(menuBarMaxY: adapter.menuBarScreenMaxY, focusedCenter: nil)
            if isCurrent, !userPaused { hotkeys.register(bindings: config.bindings) }
            applyFrames()
            restashOffspace()
        }
    }

    func skyLightChanged() -> Bool {
        guard let bound, let cur = skyLight.currentSpaceId(displayUUID: bound.uuid) else { return false }
        if lastSkyLightId == nil { lastSkyLightId = cur; return false }
        if lastSkyLightId != cur {
            lastSkyLightId = cur
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

    func reloadConfig() {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let text = (try? String(contentsOfFile: LuminaPaths.configPath(home: home), encoding: .utf8)) ?? ""
        let (next, error) = applyReload(current: config, newText: text)
        configError = error
        if error == nil {
            let oldCount = session.spaceCount
            config = next
            if next.spaceCount != oldCount {
                session = session.applySpaceCount(next.spaceCount, usableIsWide: usableIsWide(bound?.usableRect(gaps: next.gaps) ?? Rect(x: 0, y: 0, w: 1, h: 1)))
            }
            if isCurrent, !userPaused { hotkeys.register(bindings: next.bindings) }
            startOrStopFFM()
            applyFrames()
        }
    }

    func watchConfig() {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let dir = (LuminaPaths.configPath(home: home) as NSString).deletingLastPathComponent
        let fd = open(dir, O_EVTONLY)
        guard fd >= 0 else { return }
        let src = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: [.write, .rename, .delete], queue: MutationQueue.shared.queue)
        src.setEventHandler { [weak self] in
            self?.reloadConfig()
        }
        src.setCancelHandler { close(fd) }
        src.resume()
        configWatcher = src
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
        if shouldIgnoreFFM(mouseButtonsDown: NSEvent.pressedMouseButtons != 0, generationInFlight: false) { return }
        let loc = NSEvent.mouseLocation
        let ax = Point(x: Double(loc.x), y: menuBarMaxY() - Double(loc.y))
        if let hit = spatialWindows().first(where: { $0.frame.contains(point: ax) }), hit.cgWindowId != focusedId() {
            if let el = elements[hit.cgWindowId] { adapter.setFocused(el) }
        }
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

    func statusJSON() -> JSONValue {
        .object([
            "secureInput": .bool(secureInput),
            "axTrusted": .bool(axTrusted),
            "configError": configError.map { .string($0) } ?? .null,
            "paused": .bool(userPaused || displayGone),
            "instanceId": .string(instanceId.uuidString),
            "space": .int(session.focusedSpace.raw),
        ])
    }
}

#endif
