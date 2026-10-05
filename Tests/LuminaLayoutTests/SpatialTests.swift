import Foundation
import Testing
@testable import LuminaLayout

struct SpatialTests {
    private let tileA = SpatialWindow(
        id: NodeId(raw: 1),
        role: .tiled,
        frame: Rect(x: 0, y: 0, w: 400, h: 400),
        cgWindowId: 10
    )
    /// Center is at x=550, which is NOT left of A.center (200). Left edge x=100 IS left of A's center.
    private let tileOverlappingLeft = SpatialWindow(
        id: NodeId(raw: 2),
        role: .tiled,
        frame: Rect(x: 100, y: 0, w: 900, h: 400),
        cgWindowId: 11
    )

    @Test func tiledEligibilityUsesFrameNotCenter() {
        let from = tileA
        let candidate = tileOverlappingLeft
        #expect(candidate.frame.minX < from.frame.center.x)
        #expect(!(candidate.frame.center.x < from.frame.center.x))
        let winner = focusSpatial(windows: [from, candidate], from: from, dir: .left)
        #expect(winner?.cgWindowId == 11)
    }

    @Test func tileInStripWinsOverNearerFloater() {
        let from = SpatialWindow(role: .tiled, frame: Rect(x: 400, y: 0, w: 200, h: 200), cgWindowId: 1)
        let tile = SpatialWindow(role: .tiled, frame: Rect(x: 0, y: 0, w: 200, h: 200), cgWindowId: 2)
        // Floater center is in-direction and nearer than the tile's center.
        let floater = SpatialWindow(role: .floating, frame: Rect(x: 300, y: 0, w: 40, h: 40), cgWindowId: 3)
        let winner = focusSpatial(windows: [from, tile, floater], from: from, dir: .left)
        #expect(winner?.cgWindowId == 2)
    }

    @Test func tieBreaksToLowerCGWindowID() {
        let from = SpatialWindow(role: .tiled, frame: Rect(x: 200, y: 0, w: 100, h: 100), cgWindowId: 1)
        let a = SpatialWindow(role: .tiled, frame: Rect(x: 0, y: 0, w: 100, h: 100), cgWindowId: 20)
        let b = SpatialWindow(role: .tiled, frame: Rect(x: 0, y: 0, w: 100, h: 100), cgWindowId: 5)
        let winner = focusSpatial(windows: [from, a, b], from: from, dir: .left)
        #expect(winner?.cgWindowId == 5)
    }

    @Test func twoFloaterSwapIsFramesOnly() {
        var session = Session.empty(spaceCount: 1)
        var space = session[SpaceId.require(1)]!
        space.floating = [
            WindowRef(cgWindowId: 1, pid: 1, role: .floating, lastOnscreenFrame: Rect(x: 0, y: 0, w: 10, h: 10)),
            WindowRef(cgWindowId: 2, pid: 2, role: .floating, lastOnscreenFrame: Rect(x: 50, y: 50, w: 10, h: 10)),
        ]
        session.spaces[SpaceId.require(1)] = space
        session = session.swap(space: SpaceId.require(1), a: 1, b: 2)
        let after = session[SpaceId.require(1)]!
        #expect(after.root == nil)
        #expect(after.floating[0].lastOnscreenFrame == Rect(x: 50, y: 50, w: 10, h: 10))
        #expect(after.floating[1].lastOnscreenFrame == Rect(x: 0, y: 0, w: 10, h: 10))
        #expect(after.floating[0].role == .floating)
        #expect(after.floating[1].role == .floating)
    }

    @Test func tileFloaterRoleExchange() {
        var session = Session.empty(spaceCount: 1)
        session = session.insertSpiral(
            space: SpaceId.require(1),
            newLeaf: WindowRef(cgWindowId: 1, pid: 1, role: .tiled, lastOnscreenFrame: Rect(x: 0, y: 0, w: 100, h: 100)),
            usableIsWide: true
        )
        var space = session[SpaceId.require(1)]!
        space.floating.append(
            WindowRef(cgWindowId: 2, pid: 2, role: .floating, lastOnscreenFrame: Rect(x: 9, y: 9, w: 20, h: 20))
        )
        session.spaces[SpaceId.require(1)] = space
        let ratiosBefore = space.nodes[space.root!]?.ratio
        session = session.swap(space: SpaceId.require(1), a: 1, b: 2)
        let after = session[SpaceId.require(1)]!
        #expect(after.nodes[after.root!]?.leaf?.cgWindowId == 2)
        #expect(after.nodes[after.root!]?.leaf?.role == .tiled)
        #expect(after.floating.count == 1)
        #expect(after.floating[0].cgWindowId == 1)
        #expect(after.floating[0].role == .floating)
        // The displaced tile takes the floater's old spot; keeping its own
        // tile frame stacked it on top of the window now occupying the tile.
        #expect(after.floating[0].lastOnscreenFrame == Rect(x: 9, y: 9, w: 20, h: 20))
        #expect(after.nodes[after.root!]?.ratio == ratiosBefore)
    }

    @Test func twoTileSwapPreservesRatios() {
        var session = Session.empty(spaceCount: 1)
        session = session.insertSpiral(
            space: SpaceId.require(1),
            newLeaf: WindowRef(cgWindowId: 1, pid: 1),
            usableIsWide: true
        )
        session = session.insertSpiral(
            space: SpaceId.require(1),
            newLeaf: WindowRef(cgWindowId: 2, pid: 2),
            usableIsWide: true
        )
        var space = session[SpaceId.require(1)]!
        var root = space.nodes[space.root!]!
        root.ratio = [0.3, 0.7]
        space.setNode(root)
        session.spaces[SpaceId.require(1)] = space
        session = session.swap(space: SpaceId.require(1), a: 1, b: 2)
        let after = session[SpaceId.require(1)]!
        let newRoot = after.nodes[after.root!]!
        #expect(newRoot.ratio == [0.3, 0.7])
        #expect(after.nodes[newRoot.children[0]]!.leaf?.cgWindowId == 2)
        #expect(after.nodes[newRoot.children[1]]!.leaf?.cgWindowId == 1)
        #expect(newRoot.children == root.children)
    }

    @Test func noCandidateReturnsNil() {
        let from = SpatialWindow(role: .tiled, frame: Rect(x: 0, y: 0, w: 100, h: 100), cgWindowId: 1)
        #expect(focusSpatial(windows: [from], from: from, dir: .left) == nil)
        let rightOnly = SpatialWindow(role: .tiled, frame: Rect(x: 200, y: 0, w: 100, h: 100), cgWindowId: 2)
        #expect(focusSpatial(windows: [from, rightOnly], from: from, dir: .left) == nil)
    }
}
