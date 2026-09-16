import Foundation

public enum LaunchTiling: String, Equatable, Sendable, Codable {
    case zOrder = "z-order"
    case floatExisting = "float-existing"
    case newOnly = "new-only"

    /// v1: `float-existing` and `new-only` share one implementation.
    public var isAliasFloatExisting: Bool {
        self == .floatExisting || self == .newOnly
    }
}

public struct LaunchWindow: Equatable, Sendable {
    public var window: WindowRef
    public init(window: WindowRef) {
        self.window = window
    }
}

extension Session {
    /// `windows` are front-to-back (index 0 = frontmost), already classified as tileable.
    public func applyLaunchTiling(
        spaceId: SpaceId,
        policy: LaunchTiling,
        windows: [WindowRef],
        usableIsWide: Bool
    ) -> Session {
        var session = self
        guard session.spaces[spaceId] != nil else { return session }
        if windows.isEmpty { return session }

        if policy.isAliasFloatExisting {
            var space = session.spaces[spaceId]!
            for var w in windows {
                w.role = .floating
                space.floating.append(w)
            }
            if space.focusedWindow == nil {
                space.focusedWindow = windows.first?.cgWindowId
            }
            session.spaces[spaceId] = space
            return session
        }

        let originalFrontmost = windows.first?.cgWindowId
        for w in windows {
            session = session.insertSpiral(space: spaceId, newLeaf: w, usableIsWide: usableIsWide)
        }
        if let front = originalFrontmost,
           let space = session.spaces[spaceId],
           let leaf = space.leaf(containing: front),
           leaf.isLeaf
        {
            var space = space
            space.focusedWindow = front
            space.lastTiledLeaf = leaf.id
            session.spaces[spaceId] = space
        }
        return session
    }
}

/// Crash recover uses last focused if still in 1…count, else space 1.
/// Quit-then-start / first bind / new boot: space 1.
public func rebuildSpaceId(crashRecover: Bool, sessionFocused: Int, spaceCount: Int) -> SpaceId {
    if crashRecover, let id = SpaceId.make(sessionFocused), sessionFocused <= spaceCount {
        return id
    }
    return SpaceId.require(1)
}
