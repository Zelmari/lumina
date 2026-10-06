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
                // Still settling: just adopted, a write in flight, or a
                // refusal observation awaiting confirmation.
                if isYoung(w.cgWindowId) || adapter.generationInFlight(for: w.cgWindowId)
                    || overflowObservations[w.cgWindowId] != nil
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

    /// Push the strip-visible status to subscribed menu extras. Cheap no-op
    /// when nobody listens, so it is safe to call on every command.
    func publishStatus() {
        guard let server, server.hasSubscribers else { return }
        server.broadcast(event: "status", data: statusJSON(full: false))
    }

    func statusJSON(full: Bool = true) -> JSONValue {
        let usedIndices = session.spaces.values
            .filter { !$0.tiledLeaves().isEmpty || !$0.floating.isEmpty }
            .map { $0.id.raw }
        let visible = visibleWorkspaceCount(
            configured: session.spaceCount,
            focused: session.focusedSpace.raw,
            used: usedIndices
        )
        var payload: [String: JSONValue] = [
            "secureInput": .bool(secureInput),
            "axTrusted": .bool(axTrusted),
            "configError": configError.map { .string($0) } ?? .null,
            "paused": .bool(userPaused),
            "displayGone": .bool(displayGone),
            "instanceId": .string(instanceId.uuidString),
            "space": .int(session.focusedSpace.raw),
            "spaceCount": .int(session.spaceCount),
            "visibleSpaceCount": .int(visible),
            "isCurrent": .bool(isCurrent),
            "lastRefreshMs": lastRefreshSummary.map { .int($0.durationMs) } ?? .null,
            "refreshLatencyMs": refreshLatency.last.map { .double($0) } ?? .null,
            "refreshLatencyP95Ms": refreshLatency.p95.map { .double($0) } ?? .null,
            "createdLatencyP95Ms": createdLatency.p95.map { .double($0) } ?? .null,
            "launchedLatencyP95Ms": launchedLatency.p95.map { .double($0) } ?? .null,
            "hotkeyError": hotkeys.hotkeyError.map { .string($0) } ?? .null,
            "skylightSpaceId": boundSkyLightId.map { .int(Int($0)) } ?? .null,
        ]
        if full {
            // These cost a WindowServer enumeration and extra reads; the menu
            // extra polls at 1.25 Hz and never consumes them.
            payload["configDiagnostics"] = .array(config.diagnostics.map { .string($0) })
            payload["focusedWindow"] = session.current.focusedWindow.map { .int(Int($0)) } ?? .null
            payload["hasOnScreenIncludingSlivers"] = .bool(hasOnScreenIncludingSlivers())
        }
        return .object(payload)
    }

    struct RefreshSummary: Equatable, Sendable {
        var reason: String
        var added: Int
        var removed: Int
        var rebinds: Int
        var unresolved: Bool
        var durationMs: Int
    }
    func latencyJSON() -> JSONValue {
        func stats(_ stats: LatencyStats) -> JSONValue {
            func number(_ value: Double?) -> JSONValue {
                value.map { .double($0) } ?? .null
            }
            return .object([
                "samples": .int(stats.count),
                "total": .int(stats.totalRecorded),
                "lastMs": number(stats.last),
                "p50Ms": number(stats.p50),
                "p95Ms": number(stats.p95),
                "maxMs": number(stats.max),
            ])
        }
        return .object([
            "all": stats(refreshLatency),
            "created": stats(createdLatency),
            "launched": stats(launchedLatency),
        ])
    }

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
            "refreshLatency": latencyJSON(),
            "windows": .array(windows),
        ])
    }

    func debugWindowJSON(_ window: WindowRef, space: SpaceId?) -> JSONValue {
        let element = debugAXElement(for: window)
        let liveFrame = element.flatMap { adapter.frame(of: $0) }
        let axMin: JSONValue = element.map { el in
            let size = adapter.minSize(of: el)
            return .object(["w": .double(size.w), "h": .double(size.h)])
        } ?? .null
        let observed: JSONValue = observedMinSizes[window.cgWindowId].map {
            .object(["w": .double($0.w), "h": .double($0.h)])
        } ?? .null
        return .object([
            "cgWindowId": .int(Int(window.cgWindowId)),
            "pid": .int(Int(window.pid)),
            "bundleId": .string(window.bundleId ?? ""),
            "role": .string(window.role.rawValue),
            "space": space.map { .int($0.raw) } ?? .null,
            "lastOnscreenFrame": debugRectJSON(window.lastOnscreenFrame),
            "axElementResolves": .bool(element != nil),
            "liveAXFrame": liveFrame.map { debugRectJSON($0) } ?? .null,
            "axMinSize": axMin,
            "observedMinSize": observed,
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
#endif
