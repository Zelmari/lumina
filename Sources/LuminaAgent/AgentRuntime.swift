#if os(macOS)
import AppKit
import ApplicationServices
import Carbon
import CoreFoundation
import Darwin
import Foundation
import LuminaLayout
import LuminaIPC

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
    public var lastSkyLightId: UInt64?
    public var axTrusted: Bool { AXIsProcessTrusted() }
    public var hotkeys = Hotkeys()
    public var secureInput = false
    public var configError: String?
    public var lastSpaceChange = Date.distantPast
    public var lastLuminaSpaceChange = Date.distantPast
    public var pasteboardCount: Int = 0
    public var moveStart: (UInt32, Point, Int)?
    public var createDebounce: DispatchWorkItem?
    public var resizeDebounce: DispatchWorkItem?
    public var configDebounce: DispatchWorkItem?
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
        hotkeys.isPaused = { [weak self] in
            guard let self else { return true }
            return self.userPaused || self.displayGone || !self.isCurrent
        }
        hotkeys.onCommand = { [weak self] cmd in
            self?.handleBound(cmd)
        }
        if shouldRegisterHotkeys(isCurrent: isCurrent, paused: userPaused || displayGone) {
            hotkeys.register(bindings: config.bindings)
            if let err = hotkeys.hotkeyError { log.error("hotkeys \(err)") }
            else { log.info("hotkeys registered \(config.bindings.count)") }
        }
        do {
            let server = AgentSocketServer(path: socketPath, log: log)
            server.onCommand = { [weak self] cmd, id in
                self?.handleAgent(cmd, id: id) ?? IPCResponse.failure(id: id, error: "gone")
            }
            try server.start()
            self.server = server
        } catch {
            log.error("socket failed path=\(socketPath) \(error)")
        }
        installWorkspaceObservers()
        watchConfig()
        pollSecureInput()
        log.info(
            "agent start instance=\(instanceId) crashRecover=\(crashRecover) axTrusted=\(axTrusted) bundle=\(Bundle.main.bundleIdentifier ?? "?")"
        )
        if axTrusted {
            bootLayoutIfNeeded()
        } else {
            log.info("AX not trusted; waiting (will prompt as Lumina Agent if still denied)")
            pollUntilAXTrusted()
        }
    }

    public func stop() {
        unstashAll()
        rescueOffscreenWindows()
        writeSession(stash: [])
        hotkeys.unregister()
        server?.stop()
        ffmTimer?.cancel()
        secureTimer?.cancel()
        axPollTimer?.cancel()
        configWatcher?.cancel()
        configDebounce?.cancel()
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
        applyFrames()
        watchRunningApps()
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
                self.bootLayoutIfNeeded()
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

    func collectManagedWindows() -> [(WindowRef)] {
        guard let bound else { return [] }
        var out: [WindowRef] = []
        let cg = onScreenCGWindows(intersecting: bound.axFrame)
        let onScreenIds = Set(cg.compactMap(cgWindowID))
        let apps = NSWorkspace.shared.runningApplications
        for app in apps {
            let pid = app.processIdentifier
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
                let result = classify(input, rules: config.windowRules)
                log.info(
                    "classify \(app.bundleIdentifier ?? "?") '\(input.title ?? "")' role=\(input.role ?? "?") sub=\(input.subrole ?? "?") zoom=\(input.hasZoomButton) \(Int(input.width))x\(Int(input.height)) layerHUD=\(input.layerOrIsHUD) -> \(result) id=\(id)"
                )
                if result == .unmanaged || result == .ignored { continue }
                observers.watchWindow(el, pid: pid)
                adapter.rememberWindowId(id, for: el)
                elements[id] = el
                let frame = adapter.frame(of: el) ?? Rect(x: 0, y: 0, w: 0, h: 0)
                var w = WindowRef(cgWindowId: id, pid: pid, bundleId: app.bundleIdentifier, role: result == .floating ? .floating : .tiled, lastOnscreenFrame: frame)
                if result == .floating { w.role = .floating }
                out.append(w)
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
            let pid = app.processIdentifier
            DispatchQueue.main.async { self.observers.watch(pid: pid) }
            MutationQueue.shared.queue.asyncAfter(deadline: .now() + 0.2) { [weak self] in
                self?.adoptWindows(pid: pid)
            }
            MutationQueue.shared.queue.asyncAfter(deadline: .now() + 0.55) { [weak self] in
                self?.adoptWindows(pid: pid)
            }
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
            MutationQueue.shared.hop {
                self.adoptWindows(pid: app.processIdentifier)
                if Date().timeIntervalSince(self.lastLuminaSpaceChange) > 0.8 {
                    self.switchToWindowOf(pid: app.processIdentifier)
                }
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
            debounceCreate(pid: pid)
            onCreate(element)
        case kAXUIElementDestroyedNotification:
            handleDestroy(element)
        case kAXFocusedWindowChangedNotification:
            let win = adapter.focusedWindow(of: element)
                ?? adapter.focusedWindow(of: AXUIElementCreateApplication(pid))
            guard let win, let id = adapter.windowId(for: win) else { return }
            if ownedAnywhere(id) {
                observers.watchWindow(win, pid: pid)
                if owned(id) {
                    rememberFocus(id)
                } else if let sid = session.spaceContaining(cgWindowId: id), sid != session.focusedSpace {
                    stash(ids: [id], space: sid)
                }
            } else {
                onCreate(win)
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
            let retryId = adapter.windowId(for: element)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
                guard let self, let retryId, let el = self.elements[retryId] else { return }
                self.adapter.deminiaturize(el)
            }
        default:
            break
        }
    }

    func debounceCreate(pid: pid_t) {
        createDebounce?.cancel()
        let item = DispatchWorkItem { [weak self] in
            self?.adoptWindows(pid: pid)
        }
        createDebounce = item
        MutationQueue.shared.queue.asyncAfter(deadline: .now() + 0.08, execute: item)
    }

    func adoptWindows(pid: pid_t, apply: Bool = true) {
        observers.watch(pid: pid)
        var claimed = session.allWindowIds.union(elements.keys)
        for el in adapter.windows(pid: pid) {
            onCreate(el, claimed: &claimed, apply: false)
        }
        if apply { applyFrames() }
    }

    func onCreate(_ element: AXUIElement) {
        var claimed = session.allWindowIds.union(elements.keys)
        onCreate(element, claimed: &claimed, apply: true)
    }

    func onCreate(_ element: AXUIElement, claimed: inout Set<UInt32>, apply: Bool = true) {
        guard let bound else { return }
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
            log.info("onCreate skip stashed-away role=\(adapter.role(of: element) ?? "?")")
            return
        }
        let peekId = adapter.windowId(for: element, excluding: claimed)
        let peekPid = adapter.pid(of: element)
        if let peekId, let peekPid, let sid = otherSpace(pid: peekPid, id: peekId, element: element) {
            claimed.insert(peekId)
            restashPid(peekPid, on: sid)
            return
        }
        if let frame = adapter.frame(of: element), shouldPullOnScreen(frame),
           peekPid.map({ ownedWindows(pid: $0).isEmpty }) ?? true
        {
            var dummy = WindowRef(cgWindowId: 0, pid: peekPid ?? 0, lastOnscreenFrame: frame)
            _ = adapter.setFrame(usableRestoreRect(frame), of: element, tag: &dummy)
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
            claimed.insert(id)
            observers.watchWindow(element, pid: pid)
            adapter.rememberWindowId(id, for: element)
            elements[id] = element
            return
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
            "onCreate \(input.bundleId ?? "?") '\(input.title ?? "")' role=\(input.role ?? "?") sub=\(input.subrole ?? "?") zoom=\(input.hasZoomButton) \(Int(input.width))x\(Int(input.height)) center=\(input.centerOnBoundDisplay) onScreen=\(input.isOnScreen) -> \(result) id=\(id)"
        )
        if result == .unmanaged || result == .ignored { return }
        claimed.insert(id)
        observers.watchWindow(element, pid: pid)
        adapter.rememberWindowId(id, for: element)
        elements[id] = element
        let frame = adapter.frame(of: element) ?? Rect(x: 0, y: 0, w: 0, h: 0)
        var window = WindowRef(cgWindowId: id, pid: pid, bundleId: adapter.bundleId(pid: pid), role: .tiled, lastOnscreenFrame: frame)
        let usable = bound.usableRect(gaps: config.gaps)
        if session.current.luminaFullscreen != nil {
            session = session.insertWhileLuminaFS(space: session.focusedSpace, window: window, result: result, usableIsWide: usableIsWide(usable))
            if result == .tiled { stash(ids: [id]) }
        } else if result == .floating {
            window.role = .floating
            var space = session.current
            space.floating.append(window)
            session.spaces[session.focusedSpace] = space
        } else {
            pruneGhostLeaves(space: session.focusedSpace)
            session = session.insertSpiral(space: session.focusedSpace, newLeaf: window, usableIsWide: usableIsWide(usable))
            let mins = minSizes()
            let (clamped, floated) = session.clampOverflow(space: session.focusedSpace, minSizes: mins, usable: usable, gaps: config.gaps, preferFloat: session.current.lastTiledLeaf)
            session = clamped
            placeFloated(floated)
        }
        if apply { applyFrames() }
    }

    func trackedId(matching element: AXUIElement) -> UInt32? {
        if let id = adapter.cachedWindowId(for: element), ownedAnywhere(id) || elements[id] != nil {
            return id
        }
        return elements.first(where: { CFEqual($0.value, element) })?.key
    }

    func staleOwnedWindow(pid: pid_t, liveId: UInt32, element: AXUIElement) -> UInt32? {
        let live = Set(
            (CGWindowListCopyWindowInfo([.excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? [])
                .compactMap(cgWindowID)
        )
        let ownedForPid = session.current.tiledLeaves().compactMap(\.leaf).filter { $0.pid == pid }
            + session.current.floating.filter { $0.pid == pid }
        let stale = ownedForPid.filter { !live.contains($0.cgWindowId) && $0.cgWindowId != liveId }
        guard stale.count == 1, !owned(liveId) else { return nil }
        let old = stale[0].cgWindowId
        guard let el = elements[old], CFEqual(el, element) else { return nil }
        return old
    }

    func rebindOwned(from: UInt32, to: UInt32, element: AXUIElement, pid: pid_t) {
        session = session.rebindWindowId(space: session.focusedSpace, from: from, to: to)
        elements[from] = nil
        adapter.forgetWindowId(from)
        adapter.rememberWindowId(to, for: element)
        elements[to] = element
        observers.watchWindow(element, pid: pid)
        if session.current.focusedWindow == from {
            rememberFocus(to)
        }
    }

    func handleDestroy(_ element: AXUIElement) {
        let cached = adapter.cachedWindowId(for: element)
        let live = Set(
            (CGWindowListCopyWindowInfo([.excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? [])
                .compactMap(cgWindowID)
        )
        let before = session.allWindowIds
        if let id = cached {
            if live.contains(id) {
                log.info("destroy skipped; cg window still live id=\(id)")
            } else {
                log.info("destroy remove id=\(id)")
                let wasFS = session.current.luminaFullscreen != nil
                    && session.current.nodes[session.current.luminaFullscreen!]?.leaf?.cgWindowId == id
                if wasFS {
                    session = session.closeFocused(space: session.focusedSpace)
                    unstashSpace(session.focusedSpace)
                } else {
                    session = session.removeWindow(space: session.focusedSpace, cgWindowId: id)
                }
                elements[id] = nil
                adapter.forgetWindowId(id)
            }
        } else {
            log.info("destroy without cached id role=\(adapter.role(of: element) ?? "?")")
        }
        pruneMissingWindows()
        if session.allWindowIds != before {
            recoverManagedWindows()
        }
        applyFrames()
    }

    func isOffEveryDisplay(_ rect: Rect) -> Bool {
        let frames = NSScreen.screens.compactMap { BoundDisplay.from(screen: $0, menuBarMaxY: menuBarMaxY())?.axFrame }
        return !frames.contains { $0.contains(point: rect.center) }
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
        let onScreen = Set(onScreenCGWindows(intersecting: bound.axFrame).compactMap(cgWindowID))
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
        let onScreen = Set(onScreenCGWindows(intersecting: bound.axFrame).compactMap(cgWindowID))
        guard let (input, _, _) = classifyInput(from: element, adapter: adapter, bound: bound, onScreenIds: onScreen) else { return }
        let result = classify(input, rules: config.windowRules)
        if result == .tiled, session.current.floating.contains(where: { $0.cgWindowId == id }) {
            session = session.floatToggle(space: session.focusedSpace, usableIsWide: usableIsWide(bound.usableRect(gaps: config.gaps)))
            applyFrames()
        }
    }

    func handleBound(_ command: BoundCommand) {
        if userPaused || displayGone || !isCurrent { return }
        log.info("command \(command.commandString)")
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
                guard let focused = focusedId() else {
                    log.info("move-node-to-workspace \(n) skipped: no focused window")
                    return
                }
                rememberFocus(focused)
                let usable = bound?.usableRect(gaps: config.gaps) ?? Rect(x: 0, y: 0, w: 1, h: 1)
                let from = session.focusedSpace.raw
                session = session.moveNodeToWorkspace(id, usableIsWide: usableIsWide(usable))
                log.info("move-node-to-workspace window=\(focused) \(from)->\(id.raw) focusedSpace=\(session.focusedSpace.raw)")
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
        case .markCurrent:
            recomputeCurrentToken(reason: .start)
            return .success(id: id)
        case .yield:
            isCurrent = false
            hotkeys.unregister()
            return .success(id: id)
        }
    }

    func applyFrames(retryingAfterGhosts: Bool = false) {
        if userPaused || displayGone || !isCurrent { return }
        refreshBound()
        guard let bound else { return }
        let started = Date()
        let usable = bound.usableRect(gaps: config.gaps)
        let space = session.current
        let rects = frames(space: space, usable: usable, gaps: config.gaps)
        let fs = space.luminaFullscreen
        var ghosts: [UInt32] = []
        for (nodeId, rect) in rects {
            if MutationQueue.shared.shouldSkip(started: started) {
                log.info("layout pass exceeded 200ms; skipping remaining windows")
                break
            }
            if let fs, fs != nodeId { continue }
            guard var node = space.nodes[nodeId], var window = node.leaf,
                  let el = resolvedElement(for: window)
            else {
                if let node = space.nodes[nodeId], let window = node.leaf {
                    log.info("applyFrames skip missing AX window=\(window.cgWindowId) bundle=\(window.bundleId ?? "?")")
                    ghosts.append(window.cgWindowId)
                }
                continue
            }
            window.lastOnscreenFrame = rect
            let result = adapter.setFrame(rect, of: el, tag: &window)
            node.leaf = window
            var s = session.spaces[session.focusedSpace]!
            s.setNode(node)
            session.spaces[session.focusedSpace] = s
            if result == .failed {
                log.info("setFrame failed window=\(window.cgWindowId); leaving tiled")
            }
        }
        if let fs, let node = space.nodes[fs], var window = node.leaf, let el = resolvedElement(for: window) {
            _ = adapter.setFrame(usable, of: el, tag: &window)
        }
        for floater in space.floating where floater.role == .floating {
            var w = floater
            w.lastOnscreenFrame = usableRestoreRect(w.lastOnscreenFrame)
            if let el = resolvedElement(for: w) {
                _ = adapter.setFrame(w.lastOnscreenFrame, of: el, tag: &w)
            }
            if var s = session.spaces[session.focusedSpace],
               let idx = s.floating.firstIndex(where: { $0.cgWindowId == w.cgWindowId })
            {
                s.floating[idx].lastOnscreenFrame = w.lastOnscreenFrame
                session.spaces[session.focusedSpace] = s
            }
        }
        if !ghosts.isEmpty, !retryingAfterGhosts {
            for id in ghosts {
                log.info("prune ghost window=\(id)")
                session = session.removeWindow(space: session.focusedSpace, cgWindowId: id)
                elements[id] = nil
                adapter.forgetWindowId(id)
            }
            applyFrames(retryingAfterGhosts: true)
        }
    }

    func switchSpace(_ id: SpaceId) {
        guard id != session.focusedSpace else { return }
        lastLuminaSpaceChange = Date()
        stash(ids: Set(session.visibleIds(on: session.focusedSpace)))
        session = session.switchTo(id)
        unstashSpace(id)
        applyFrames()
        restashOffspace()
        writeSession()
    }

    func switchSpaceBy(_ transform: (Session) -> Session) {
        lastLuminaSpaceChange = Date()
        stash(ids: Set(session.visibleIds(on: session.focusedSpace)))
        session = transform(session)
        unstashSpace(session.focusedSpace)
        applyFrames()
        restashOffspace()
        writeSession()
    }

    func stash(ids: Set<UInt32>, space spaceId: SpaceId? = nil) {
        guard let bound else { return }
        let spaceId = spaceId ?? session.focusedSpace
        let dockRight = bound.axVisibleFrame.maxX < bound.axFrame.maxX
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
            if let current, !isSliver(current), var space = session.spaces[spaceId] {
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
            let display = DisplayFrame(axFrame: bound.axFrame, axVisibleFrame: bound.axVisibleFrame)
            let parked = stashFrame(for: height, display: display, dockRight: dockRight, lastWidth: width)
            _ = adapter.setStashFrame(parked, of: el, tag: &window)
            if let after = adapter.frame(of: el) ?? cgWindowRect(id: id), after.intersects(bound.axVisibleFrame) {
                // Min-size apps ignore 1×8. Keep 1px on-display and hang the rest above the menu bar.
                let hang = Rect(
                    x: parked.x,
                    y: bound.axFrame.minY - after.h + parked.h,
                    w: after.w,
                    h: after.h
                )
                _ = adapter.setStashFrame(hang, of: el, tag: &window)
                if let still = adapter.frame(of: el) ?? cgWindowRect(id: id), still.intersects(bound.axVisibleFrame) {
                    log.info(
                        "stash still on desktop window=\(id) bundle=\(window.bundleId ?? "?") \(Int(still.w))x\(Int(still.h)) @\(Int(still.x)),\(Int(still.y))"
                    )
                }
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

    func unstashSpace(_ id: SpaceId) {
        guard let space = session.spaces[id] else { return }
        for node in space.tiledLeaves() {
            if let w = node.leaf { restoreWindow(w) }
        }
        for w in space.floating { restoreWindow(w) }
        pruneGhostLeaves(space: id)
    }

    func unstashAll() {
        for spaceId in session.spaces.keys { unstashSpace(spaceId) }
        unstashOrphanSlivers()
        rescueOffscreenWindows()
    }

    func pruneMissingWindows() {
        let info = CGWindowListCopyWindowInfo([.excludeDesktopElements], kCGNullWindowID)
            as? [[String: Any]] ?? []
        let live = Set(info.compactMap(cgWindowID))
        for spaceId in Array(session.spaces.keys) {
            for id in session.visibleIds(on: spaceId) where !live.contains(id) {
                log.info("prune missing window=\(id)")
                session = session.removeWindow(space: spaceId, cgWindowId: id)
                elements[id] = nil
                adapter.forgetWindowId(id)
            }
        }
    }

    func pruneGhostLeaves(space spaceId: SpaceId) {
        guard let space = session.spaces[spaceId] else { return }
        let windows = space.tiledLeaves().compactMap(\.leaf) + space.floating
        for w in windows where !hasAXElement(w) {
            log.info("prune ghost window=\(w.cgWindowId) bundle=\(w.bundleId ?? "?") space=\(spaceId)")
            session = session.removeWindow(space: spaceId, cgWindowId: w.cgWindowId)
            elements[w.cgWindowId] = nil
            adapter.forgetWindowId(w.cgWindowId)
        }
    }

    func hasAXElement(_ window: WindowRef) -> Bool {
        if let el = elements[window.cgWindowId], adapter.pid(of: el) == window.pid {
            return true
        }
        return adapter.axWindow(pid: window.pid, cgWindowId: window.cgWindowId) != nil
    }

    func recoverManagedWindows() {
        rebindStaleWindowIds()
        pruneGhostLeaves(space: session.focusedSpace)
        for app in NSWorkspace.shared.runningApplications {
            adoptWindows(pid: app.processIdentifier, apply: false)
        }
    }

    func rebindStaleWindowIds() {
        let info = CGWindowListCopyWindowInfo([.excludeDesktopElements], kCGNullWindowID)
            as? [[String: Any]] ?? []
        let live = Set(info.compactMap(cgWindowID))
        for spaceId in Array(session.spaces.keys) {
            guard let space = session.spaces[spaceId] else { continue }
            let ownedWindows = space.tiledLeaves().compactMap(\.leaf) + space.floating
            for w in ownedWindows where !live.contains(w.cgWindowId) {
                let excluding = Set(session.visibleIds(on: spaceId).filter { $0 != w.cgWindowId })
                guard let el = elements[w.cgWindowId] else { continue }
                guard let newId = adapter.windowId(for: el, excluding: excluding), newId != w.cgWindowId else { continue }
                log.info("rebind stale \(w.cgWindowId) -> \(newId) bundle=\(w.bundleId ?? "?")")
                session = session.rebindWindowId(space: spaceId, from: w.cgWindowId, to: newId)
                elements[w.cgWindowId] = nil
                adapter.forgetWindowId(w.cgWindowId)
                adapter.rememberWindowId(newId, for: el)
                elements[newId] = el
            }
        }
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
        if let cur = cgWindowRect(id: w.cgWindowId), isSliver(cur), let el2 = resolvedElement(for: w) {
            log.info("unstash still sliver window=\(w.cgWindowId); retry usable")
            _ = adapter.setFrame(usableRestoreRect(Rect(x: 0, y: 0, w: 1, h: 1)), of: el2, tag: &w)
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

    func placeFloated(_ windows: [WindowRef]) {
        for orig in windows {
            var w = orig
            w.lastOnscreenFrame = usableRestoreRect(w.lastOnscreenFrame)
            if let el = resolvedElement(for: w) {
                _ = adapter.setFrame(w.lastOnscreenFrame, of: el, tag: &w)
            }
            if var space = session.spaces[session.focusedSpace],
               let idx = space.floating.firstIndex(where: { $0.cgWindowId == w.cgWindowId })
            {
                space.floating[idx] = w
                session.spaces[session.focusedSpace] = space
            }
            log.info("floated overflow window=\(w.cgWindowId) bundle=\(w.bundleId ?? "?")")
        }
    }

    func isOurProcess(_ pid: pid_t) -> Bool {
        pid == getpid() || adapter.bundleId(pid: pid)?.hasPrefix("com.zelmari.lumina") == true
    }

    func rescueOffscreenWindows() {
        let info = CGWindowListCopyWindowInfo([.excludeDesktopElements], kCGNullWindowID)
            as? [[String: Any]] ?? []
        for row in info {
            guard let id = cgWindowID(row), let pid = cgOwnerPID(row), let rect = cgWindowRect(row) else { continue }
            if isOurProcess(pid) { continue }
            if cgWindowLayer(row) > 0 { continue }
            guard isStrayOffscreen(rect) else { continue }
            let w = lookup(id)
                ?? session.spaces.values.compactMap { $0.leaf(containing: id)?.leaf }.first
                ?? WindowRef(cgWindowId: id, pid: pid, bundleId: adapter.bundleId(pid: pid), lastOnscreenFrame: usableRestoreRect(rect))
            log.info("rescue offscreen window=\(id) pid=\(pid) \(Int(rect.w))x\(Int(rect.h))")
            restoreWindow(w)
        }
    }

    func resolvedElement(for window: WindowRef) -> AXUIElement? {
        if let el = elements[window.cgWindowId], adapter.pid(of: el) == window.pid {
            return el
        }
        adapter.forgetWindowId(window.cgWindowId)
        if let el = adapter.axWindow(pid: window.pid, cgWindowId: window.cgWindowId) {
            elements[window.cgWindowId] = el
            return el
        }
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
        if isOurStashSliver(rect) || isSliver(rect) { return true }
        guard let bound else { return false }
        let display = DisplayFrame(axFrame: bound.axFrame, axVisibleFrame: bound.axVisibleFrame)
        if isStashedOffDisplay(rect, display: display) { return true }
        return display.axFrame.intersects(rect) && !display.axVisibleFrame.intersects(rect)
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
        let real = adapter.windows(pid: pid).filter(isTileCandidate)
        if real.count <= owned.count {
            return elsewhere[0].0
        }
        return nil
    }

    func restashPid(_ pid: pid_t, on spaceId: SpaceId) {
        let ids = Set(ownedWindows(pid: pid).filter { $0.0 == spaceId }.map(\.1.cgWindowId))
        guard !ids.isEmpty else { return }
        log.info("restash pid=\(pid) space=\(spaceId) ids=\(ids)")
        stash(ids: ids, space: spaceId)
    }

    func unstashOrphanSlivers() {
        let ownedPids = Set(session.spaces.values.flatMap { space in
            space.tiledLeaves().compactMap { $0.leaf?.pid } + space.floating.map(\.pid)
        })
        let info = CGWindowListCopyWindowInfo([.excludeDesktopElements], kCGNullWindowID)
            as? [[String: Any]] ?? []
        for row in info {
            guard let id = cgWindowID(row), let pid = cgOwnerPID(row), let rect = cgWindowRect(row) else { continue }
            guard ownedPids.contains(pid), isOurStashSliver(rect) else { continue }
            let w = lookup(id)
                ?? session.spaces.values.compactMap { $0.leaf(containing: id)?.leaf }.first
                ?? WindowRef(cgWindowId: id, pid: pid, bundleId: nil, lastOnscreenFrame: usableRestoreRect(rect))
            restoreWindow(w)
        }
    }

    func unstashLeftovers() -> [StashEntry] {
        var entries: [StashEntry] = []
        if let data = try? Data(contentsOf: URL(fileURLWithPath: sessionPath)),
           let file = try? SessionFile.decode(data)
        {
            entries.append(contentsOf: file.stash.filter { !isSliver($0.lastOnscreenFrame) || $0.lastOnscreenFrame.h >= 8 })
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
            let restore = known.flatMap { isSliver($0.lastOnscreenFrame) ? nil : $0.lastOnscreenFrame }
                ?? usableRestoreRect(rect)
            entries.append(StashEntry(cgWindowId: id, pid: pid, bundleId: known?.bundleId, lastOnscreenFrame: restore))
        }
        for e in entries {
            let w = WindowRef(cgWindowId: e.cgWindowId, pid: e.pid, bundleId: e.bundleId, lastOnscreenFrame: usableRestoreRect(e.lastOnscreenFrame))
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

    func minSizes() -> [UInt32: Size] {
        var out: [UInt32: Size] = [:]
        for (id, el) in elements {
            let size = adapter.minSize(of: el)
            if size != .unknown { out[id] = size }
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
        var space = session.current
        space.focusedWindow = id
        if let leaf = space.leaf(containing: id) {
            space.lastTiledLeaf = leaf.id
        }
        session.spaces[session.focusedSpace] = space
    }

    func frontmostOwnedWindow() -> UInt32? {
        guard let bound else { return nil }
        for row in onScreenCGWindows(intersecting: bound.axFrame) {
            guard let id = cgWindowID(row), owned(id) else { continue }
            return id
        }
        return session.current.tiledLeaves().first?.leaf?.cgWindowId
            ?? session.current.floating.first?.cgWindowId
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
            adapter.forgetWindowId(id)
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
            guard let b = cgWindowRect(row) else { return false }
            return isLargeOnScreen(width: b.w, height: b.h)
                && ownedPid(cgOwnerPID(row))
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
            refreshBound()
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
            self?.configDebounce?.cancel()
            let item = DispatchWorkItem { self?.reloadConfig() }
            self?.configDebounce = item
            MutationQueue.shared.queue.asyncAfter(deadline: .now() + 0.05, execute: item)
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
            "paused": .bool(userPaused),
            "displayGone": .bool(displayGone),
            "instanceId": .string(instanceId.uuidString),
            "space": .int(session.focusedSpace.raw),
            "spaceCount": .int(session.spaceCount),
            "isCurrent": .bool(isCurrent),
            "hasOnScreenIncludingSlivers": .bool(hasOnScreenIncludingSlivers()),
            "hotkeyError": hotkeys.hotkeyError.map { .string($0) } ?? .null,
            "skylightSpaceId": lastSkyLightId.map { .int(Int($0)) } ?? .null,
        ])
    }
}

#endif
