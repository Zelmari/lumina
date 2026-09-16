import Foundation
import Testing
@testable import LuminaLayout

private func win(_ id: UInt32, w: Double = 800, h: Double = 600) -> WindowRef {
    WindowRef(cgWindowId: id, pid: Int32(id), role: .tiled, lastOnscreenFrame: Rect(x: 0, y: 0, w: w, h: h))
}

struct LaunchTilingTests {
    @Test func zOrderThreeWindowsFrontmostKeepsHalfAndRefocus() {
        var session = Session.empty(spaceCount: 1)
        let windows = [win(1), win(2), win(3)]
        session = session.applyLaunchTiling(
            spaceId: SpaceId.require(1),
            policy: .zOrder,
            windows: windows,
            usableIsWide: true
        )
        let space = session[SpaceId.require(1)]!
        #expect(space.focusedWindow == 1)
        let root = space.nodes[space.root!]!
        #expect(space.nodes[root.children[0]]!.leaf?.cgWindowId == 1)
        let usable = Rect(x: 0, y: 0, w: 1000, h: 800)
        let f = frames(space: space, usable: usable, gaps: Gaps(inner: 0, outer: 0))
        let w1 = f[root.children[0]]!
        #expect(abs(w1.w - 500) < 1e-6)
        #expect(space.lastTiledLeaf == root.children[0])
    }

    @Test func aliasPutsAllInFloating() {
        var session = Session.empty(spaceCount: 1)
        session = session.applyLaunchTiling(
            spaceId: SpaceId.require(1),
            policy: .floatExisting,
            windows: [win(1), win(2), win(3)],
            usableIsWide: true
        )
        let space = session[SpaceId.require(1)]!
        #expect(space.root == nil)
        #expect(space.floating.map(\.cgWindowId) == [1, 2, 3])
        #expect(space.floating.allSatisfy { $0.role == .floating })

        var session2 = Session.empty(spaceCount: 1)
        session2 = session2.applyLaunchTiling(
            spaceId: SpaceId.require(1),
            policy: .newOnly,
            windows: [win(1)],
            usableIsWide: true
        )
        #expect(session2[SpaceId.require(1)]!.root == nil)
        #expect(session2[SpaceId.require(1)]!.floating.count == 1)
    }

    @Test func emptyListIsNoOp() {
        let session = Session.empty(spaceCount: 1)
        let after = session.applyLaunchTiling(
            spaceId: SpaceId.require(1),
            policy: .zOrder,
            windows: [],
            usableIsWide: true
        )
        #expect(after == session)
    }

    @Test func rebuildSpaceIdCrashVsFresh() {
        #expect(rebuildSpaceId(crashRecover: true, sessionFocused: 3, spaceCount: 5).raw == 3)
        #expect(rebuildSpaceId(crashRecover: true, sessionFocused: 9, spaceCount: 5).raw == 1)
        #expect(rebuildSpaceId(crashRecover: false, sessionFocused: 3, spaceCount: 5).raw == 1)
        #expect(rebuildSpaceId(crashRecover: true, sessionFocused: 0, spaceCount: 5).raw == 1)
    }
}
