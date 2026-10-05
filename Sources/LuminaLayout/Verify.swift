import Foundation

/// A single invariant violation in the live session. Pure, so the same
/// checks run in tests, in the agent's `verify` command, and in the harness.
public struct VerifyIssue: Equatable, Sendable {
    public var kind: String
    public var detail: String

    public init(_ kind: String, _ detail: String) {
        self.kind = kind
        self.detail = detail
    }
}

/// Check the session's invariants against a candidate layout:
///
/// - no window id appears on two workspaces,
/// - inactive workspaces keep every window stashed,
/// - a lumina-fullscreen workspace keeps every other window stashed,
/// - the focused workspace has no stashed leaves and its tiled rects sit
///   inside the usable rect without overlapping,
/// - the recorded focused window exists on its workspace.
public func verifySession(_ session: Session, usable: Rect, gaps: Gaps, slop: Double = 2) -> [VerifyIssue] {
    var issues: [VerifyIssue] = []
    var seen: [UInt32: SpaceId] = [:]

    for (sid, space) in session.spaces.sorted(by: { $0.key.raw < $1.key.raw }) {
        for node in space.tiledLeaves() {
            guard let w = node.leaf else { continue }
            if let other = seen[w.cgWindowId] {
                issues.append(VerifyIssue(
                    "duplicate-window",
                    "window \(w.cgWindowId) is on workspace \(other.raw) and \(sid.raw)"
                ))
            }
            seen[w.cgWindowId] = sid
        }
        for w in space.floating {
            if let other = seen[w.cgWindowId] {
                issues.append(VerifyIssue(
                    "duplicate-window",
                    "window \(w.cgWindowId) is on workspace \(other.raw) and \(sid.raw)"
                ))
            }
            seen[w.cgWindowId] = sid
        }
    }

    for (sid, space) in session.spaces.sorted(by: { $0.key.raw < $1.key.raw }) {
        if sid != session.focusedSpace {
            for node in space.tiledLeaves() where node.leaf?.role == .tiled {
                issues.append(VerifyIssue(
                    "visible-on-hidden-workspace",
                    "window \(node.leaf?.cgWindowId ?? 0) is visible on workspace \(sid.raw)"
                ))
            }
            for w in space.floating where w.role == .floating {
                issues.append(VerifyIssue(
                    "visible-on-hidden-workspace",
                    "floater \(w.cgWindowId) is visible on workspace \(sid.raw)"
                ))
            }
            continue
        }
        if let fs = space.luminaFullscreen {
            for node in space.tiledLeaves() where node.id != fs && node.leaf?.role != .stashed {
                issues.append(VerifyIssue(
                    "visible-under-fullscreen",
                    "window \(node.leaf?.cgWindowId ?? 0) is not stashed while fullscreen is active"
                ))
            }
            for w in space.floating where w.role != .stashed {
                issues.append(VerifyIssue(
                    "visible-under-fullscreen",
                    "floater \(w.cgWindowId) is not stashed while fullscreen is active"
                ))
            }
        } else {
            let rects = frames(space: space, usable: usable, gaps: gaps)
            let tiled = space.tiledLeaves().filter { $0.leaf?.role == .tiled }
            for node in tiled {
                guard let rect = rects[node.id] else { continue }
                if !inside(rect, usable, slop: slop) {
                    issues.append(VerifyIssue(
                        "tile-outside-usable",
                        "window \(node.leaf?.cgWindowId ?? 0) at \(Int(rect.x)),\(Int(rect.y)) \(Int(rect.w))x\(Int(rect.h)) is outside \(Int(usable.w))x\(Int(usable.h))"
                    ))
                }
            }
            // A single visible window must fill the usable rect; tiles that
            // do not span it mean the layout has a hole (a stray container or
            // a leaf the frame math skipped).
            if !tiled.isEmpty {
                var minX = Double.greatestFiniteMagnitude
                var minY = Double.greatestFiniteMagnitude
                var maxX = -Double.greatestFiniteMagnitude
                var maxY = -Double.greatestFiniteMagnitude
                for node in tiled {
                    guard let rect = rects[node.id] else { continue }
                    minX = min(minX, rect.minX)
                    minY = min(minY, rect.minY)
                    maxX = max(maxX, rect.maxX)
                    maxY = max(maxY, rect.maxY)
                }
                if abs(minX - usable.minX) > slop || abs(minY - usable.minY) > slop
                    || abs(maxX - usable.maxX) > slop || abs(maxY - usable.maxY) > slop
                {
                    issues.append(VerifyIssue(
                        "layout-hole",
                        "tiles span \(Int(maxX - minX))x\(Int(maxY - minY)) at \(Int(minX)),\(Int(minY)) but usable is \(Int(usable.w))x\(Int(usable.h)) at \(Int(usable.x)),\(Int(usable.y))"
                    ))
                }
            }
            for i in 0..<tiled.count {
                for j in (i + 1)..<tiled.count {
                    guard let a = rects[tiled[i].id], let b = rects[tiled[j].id] else { continue }
                    if a.intersection(b).area > 4 * slop * slop {
                        issues.append(VerifyIssue(
                            "tiles-overlap",
                            "windows \(tiled[i].leaf?.cgWindowId ?? 0) and \(tiled[j].leaf?.cgWindowId ?? 0) overlap"
                        ))
                    }
                }
            }
            for node in space.tiledLeaves() where node.leaf?.role == .stashed {
                issues.append(VerifyIssue(
                    "stashed-on-focused-workspace",
                    "window \(node.leaf?.cgWindowId ?? 0) is stashed on the focused workspace"
                ))
            }
        }
        if let focused = space.focusedWindow,
           space.leaf(containing: focused) == nil,
           !space.floating.contains(where: { $0.cgWindowId == focused })
        {
            issues.append(VerifyIssue(
                "stale-focus",
                "focused window \(focused) is not on workspace \(sid.raw)"
            ))
        }
    }
    return issues
}

private func inside(_ rect: Rect, _ bounds: Rect, slop: Double) -> Bool {
    rect.minX >= bounds.minX - slop
        && rect.maxX <= bounds.maxX + slop
        && rect.minY >= bounds.minY - slop
        && rect.maxY <= bounds.maxY + slop
}
