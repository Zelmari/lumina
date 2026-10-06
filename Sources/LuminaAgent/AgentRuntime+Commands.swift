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

extension AgentRuntime {
    func handleBound(_ command: BoundCommand) {
        handleBoundBody(command)
        publishStatus()
    }

    private func handleBoundBody(_ command: BoundCommand) {
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
                let entering = !adapter.isFullscreen(el)
                adapter.setFullscreen(el, entering)
                if !entering {
                    // Exit can leave the green-button zoom engaged. setFrame
                    // is ignored until that zoom is cleared, so the window
                    // stays one outer-gap larger than its tile. The replacement
                    // window is handled again from the layout pass.
                    _ = unzoomIfScreenSized(el, id: id)
                    applyFrames()
                }
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
             .accessibilityPrompt, .debugAX, .ping, .subscribe,
             .pause, .resume, .reload:
            // Resume and reload have to run while paused. Leaving them in
            // the guard below swallows `resume` and the agent stays paused.
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
            publishStatus()
            return .success(id: id)
        case .resume:
            if !displayGone {
                userPaused = false
                if isCurrent { registerHotkeys() }
                startOrStopFFM()
                refreshOriginalsFromLive()
            }
            publishStatus()
            return .success(id: id)
        case .reload:
            if let error = reloadConfig() {
                return .failure(id: id, error: error)
            }
            publishStatus()
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
        case .status(let full):
            return .success(id: id, data: statusJSON(full: full))
        case .ping:
            // The socket server normally answers pings without reaching the
            // mutation queue; this keeps direct callers working.
            return .success(id: id, data: .object(["pong": .bool(true)]))
        case .subscribe:
            // The socket server intercepts subscribe before the mutation
            // queue; this keeps direct callers working.
            return .success(id: id)
        case .markCurrent:
            recomputeCurrentToken(reason: .start)
            publishStatus()
            return .success(id: id)
        case .yield:
            isCurrent = false
            unregisterHotkeys()
            startOrStopFFM()
            publishStatus()
            return .success(id: id)
        case .accessibilityPrompt:
            requestAgentAXPrompt()
            return .success(id: id)
        case .debugAX(let pid):
            let windows = adapter.windows(pid: pid)
            return .success(id: id, data: .object([
                "pid": .int(Int(pid)),
                "bundleId": .string(adapter.bundleId(pid: pid) ?? ""),
                "windowCount": .int(windows.count),
                "windows": .array(windows.map { adapter.debugElementJSON($0) }),
            ]))
        case .debugWindows:
            return .success(id: id, data: debugWindowsJSON())
        }
    }
}
#endif
