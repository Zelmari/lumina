import Foundation
import Testing
@testable import LuminaLayout

struct VerifyTests {
    private let usable = Rect(x: 0, y: 0, w: 1000, h: 800)

    @Test func emptySessionIsClean() {
        let session = Session.empty(spaceCount: 3)
        #expect(verifySession(session, usable: usable, gaps: .default).isEmpty)
    }

    @Test func validSpiralHasNoIssues() {
        var session = Session.empty(spaceCount: 3)
        session = session.insertSpiral(space: SpaceId.require(1), newLeaf: WindowRef(cgWindowId: 1, pid: 1), usableIsWide: true)
        session = session.insertSpiral(space: SpaceId.require(1), newLeaf: WindowRef(cgWindowId: 2, pid: 2), usableIsWide: true)
        session = session.insertSpiral(space: SpaceId.require(1), newLeaf: WindowRef(cgWindowId: 3, pid: 3), usableIsWide: true)
        #expect(verifySession(session, usable: usable, gaps: .default).isEmpty)
    }

    @Test func visibleWindowOnHiddenWorkspaceIsAnIssue() {
        var session = Session.empty(spaceCount: 3)
        session = session.insertSpiral(space: SpaceId.require(2), newLeaf: WindowRef(cgWindowId: 7, pid: 7), usableIsWide: true)
        // Space 2 is inactive but its window was never stashed.
        let issues = verifySession(session, usable: usable, gaps: .default)
        #expect(issues.contains { $0.kind == "visible-on-hidden-workspace" })
    }

    @Test func stashedWindowOnHiddenWorkspaceIsClean() {
        var session = Session.empty(spaceCount: 3)
        session = session.insertSpiral(space: SpaceId.require(2), newLeaf: WindowRef(cgWindowId: 7, pid: 7), usableIsWide: true)
        session = session.markStashed(space: SpaceId.require(2), ids: [7])
        #expect(verifySession(session, usable: usable, gaps: .default).isEmpty)
    }

    @Test func fullscreenRequiresSiblingsStashed() {
        var session = Session.empty(spaceCount: 1)
        session = session.insertSpiral(space: SpaceId.require(1), newLeaf: WindowRef(cgWindowId: 1, pid: 1), usableIsWide: true)
        session = session.insertSpiral(space: SpaceId.require(1), newLeaf: WindowRef(cgWindowId: 2, pid: 2), usableIsWide: true)
        let leaf = session[SpaceId.require(1)]!.leaf(containing: 1)!.id
        session = session.enterLuminaFS(space: SpaceId.require(1), leaf: leaf)
        #expect(verifySession(session, usable: usable, gaps: .default).isEmpty)
        // A sibling visibly back on screen is an issue.
        var space = session[SpaceId.require(1)]!
        for (id, var node) in space.nodes {
            if var w = node.leaf, w.cgWindowId == 2 {
                w.role = .tiled
                node.leaf = w
                space.nodes[id] = node
            }
        }
        session.spaces[SpaceId.require(1)] = space
        let issues = verifySession(session, usable: usable, gaps: .default)
        #expect(issues.contains { $0.kind == "visible-under-fullscreen" })
    }

    @Test func missingSiblingLeafIsALayoutHole() {
        var session = Session.empty(spaceCount: 1)
        session = session.insertSpiral(space: SpaceId.require(1), newLeaf: WindowRef(cgWindowId: 1, pid: 1), usableIsWide: true)
        session = session.insertSpiral(space: SpaceId.require(1), newLeaf: WindowRef(cgWindowId: 2, pid: 2), usableIsWide: true)
        var space = session[SpaceId.require(1)]!
        // Drop one leaf from the node table; the container still splits the
        // usable rect, so the remaining tile spans only half of it.
        if let victim = space.leaf(containing: 2)?.id {
            space.nodes.removeValue(forKey: victim)
        }
        session.spaces[SpaceId.require(1)] = space
        let issues = verifySession(session, usable: usable, gaps: .default)
        #expect(issues.contains { $0.kind == "layout-hole" })
    }

    @Test func duplicateWindowAcrossWorkspacesIsAnIssue() {
        var session = Session.empty(spaceCount: 2)
        session = session.insertSpiral(space: SpaceId.require(1), newLeaf: WindowRef(cgWindowId: 5, pid: 5), usableIsWide: true)
        session = session.insertSpiral(space: SpaceId.require(2), newLeaf: WindowRef(cgWindowId: 5, pid: 5), usableIsWide: true)
        let issues = verifySession(session, usable: usable, gaps: .default)
        #expect(issues.contains { $0.kind == "duplicate-window" })
    }

    @Test func staleFocusIsAnIssue() {
        var session = Session.empty(spaceCount: 1)
        session = session.insertSpiral(space: SpaceId.require(1), newLeaf: WindowRef(cgWindowId: 5, pid: 5), usableIsWide: true)
        var space = session[SpaceId.require(1)]!
        space.focusedWindow = 99
        session.spaces[SpaceId.require(1)] = space
        let issues = verifySession(session, usable: usable, gaps: .default)
        #expect(issues.contains { $0.kind == "stale-focus" })
    }
}
