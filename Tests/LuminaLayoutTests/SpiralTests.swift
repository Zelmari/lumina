import Foundation
import Testing
@testable import LuminaLayout

private func win(_ id: UInt32, frame: Rect = Rect(x: 0, y: 0, w: 800, h: 600)) -> WindowRef {
    WindowRef(cgWindowId: id, pid: Int32(id), bundleId: "test.\(id)", role: .tiled, lastOnscreenFrame: frame)
}

private let space1 = SpaceId.require(1)

struct SpiralTests {
    @Test func firstInsertBecomesRootLeaf() {
        var session = Session.empty(spaceCount: 1, instanceId: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!)
        session = session.insertSpiral(space: space1, newLeaf: win(1), usableIsWide: true)
        let space = session[space1]!
        #expect(space.root != nil)
        let root = space.nodes[space.root!]!
        #expect(root.isLeaf)
        #expect(root.leaf?.cgWindowId == 1)
        #expect(space.focusedWindow == 1)
        #expect(space.lastTiledLeaf == root.id)
    }

    @Test func secondInsertOnWideIsHorizontalEqualRatio() {
        var session = Session.empty(spaceCount: 1)
        session = session.insertSpiral(space: space1, newLeaf: win(1), usableIsWide: true)
        session = session.insertSpiral(space: space1, newLeaf: win(2), usableIsWide: true)
        let space = session[space1]!
        let root = space.nodes[space.root!]!
        #expect(!root.isLeaf)
        #expect(root.axis == .horizontal)
        #expect(root.children.count == 2)
        #expect(root.ratio == [0.5, 0.5])
        let left = space.nodes[root.children[0]]!
        let right = space.nodes[root.children[1]]!
        #expect(left.leaf?.cgWindowId == 1)
        #expect(right.leaf?.cgWindowId == 2)
        #expect(space.focusedWindow == 2)
    }

    @Test func thirdInsertAlternatesToVertical() {
        var session = Session.empty(spaceCount: 1)
        session = session.insertSpiral(space: space1, newLeaf: win(1), usableIsWide: true)
        session = session.insertSpiral(space: space1, newLeaf: win(2), usableIsWide: true)
        // Focus is window 2 (the new leaf). Third insert splits that child.
        session = session.insertSpiral(space: space1, newLeaf: win(3), usableIsWide: true)
        let space = session[space1]!
        let root = space.nodes[space.root!]!
        #expect(root.axis == .horizontal)
        let old = space.nodes[root.children[0]]!
        let split = space.nodes[root.children[1]]!
        #expect(old.leaf?.cgWindowId == 1)
        #expect(!split.isLeaf)
        #expect(split.axis == .vertical)
        #expect(split.ratio == [0.5, 0.5])
        #expect(space.nodes[split.children[0]]!.leaf?.cgWindowId == 2)
        #expect(space.nodes[split.children[1]]!.leaf?.cgWindowId == 3)
    }

    @Test func tallFirstSplitIsVertical() {
        var session = Session.empty(spaceCount: 1)
        session = session.insertSpiral(space: space1, newLeaf: win(1), usableIsWide: false)
        session = session.insertSpiral(space: space1, newLeaf: win(2), usableIsWide: false)
        let root = session[space1]!.nodes[session[space1]!.root!]!
        #expect(root.axis == .vertical)
        #expect(root.children.count == 2)
    }

    @Test func closeNonRootPromotesSibling() {
        var session = Session.empty(spaceCount: 1)
        session = session.insertSpiral(space: space1, newLeaf: win(1), usableIsWide: true)
        session = session.insertSpiral(space: space1, newLeaf: win(2), usableIsWide: true)
        let spaceBefore = session[space1]!
        let root = spaceBefore.nodes[spaceBefore.root!]!
        let newLeaf = spaceBefore.nodes[root.children[1]]!
        session = session.remove(space: space1, node: newLeaf.id)
        let space = session[space1]!
        let newRoot = space.nodes[space.root!]!
        #expect(newRoot.isLeaf)
        #expect(newRoot.leaf?.cgWindowId == 1)
        #expect(newRoot.parent == nil)
        #expect(space.nodes.count == 1)
    }

    @Test func closeLastTiledEmptiesRoot() {
        var session = Session.empty(spaceCount: 1)
        session = session.insertSpiral(space: space1, newLeaf: win(1), usableIsWide: true)
        let rootId = session[space1]!.root!
        session = session.remove(space: space1, node: rootId)
        let space = session[space1]!
        #expect(space.root == nil)
        #expect(space.nodes.isEmpty)
        #expect(session.spaces[space1] != nil)
    }

    @Test func insertAfterEmptyTreeWorks() {
        var session = Session.empty(spaceCount: 1)
        session = session.insertSpiral(space: space1, newLeaf: win(1), usableIsWide: true)
        let firstRoot = session[space1]!.root!
        session = session.remove(space: space1, node: firstRoot)
        session = session.insertSpiral(space: space1, newLeaf: win(2), usableIsWide: true)
        let space = session[space1]!
        #expect(space.root != nil)
        #expect(space.nodes[space.root!]!.leaf?.cgWindowId == 2)
    }

    @Test func axisDoesNotFlipWhenUsableIsWideLaterDiffers() {
        var session = Session.empty(spaceCount: 1)
        session = session.insertSpiral(space: space1, newLeaf: win(1), usableIsWide: true)
        session = session.insertSpiral(space: space1, newLeaf: win(2), usableIsWide: true)
        // Later insert on a "tall" usable still splits the focused child with opposite-of-parent,
        // and the stored root axis stays horizontal.
        session = session.insertSpiral(space: space1, newLeaf: win(3), usableIsWide: false)
        let root = session[space1]!.nodes[session[space1]!.root!]!
        #expect(root.axis == .horizontal)
        let split = session[space1]!.nodes[root.children[1]]!
        #expect(split.axis == .vertical)
    }

    @Test func rebindWindowIdKeepsLeafAndUpdatesFocus() {
        var session = Session.empty(spaceCount: 1)
        session = session.insertSpiral(space: space1, newLeaf: win(10), usableIsWide: true)
        session = session.insertSpiral(space: space1, newLeaf: win(20), usableIsWide: true)
        session = session.rebindWindowId(space: space1, from: 20, to: 99)
        let space = session[space1]!
        #expect(space.leaf(containing: 20) == nil)
        #expect(space.leaf(containing: 99)?.leaf?.cgWindowId == 99)
        #expect(space.leaf(containing: 10)?.leaf?.cgWindowId == 10)
        #expect(space.focusedWindow == 99)
    }

    @Test func rebindWindowIdNoopsOnCollision() {
        var session = Session.empty(spaceCount: 1)
        session = session.insertSpiral(space: space1, newLeaf: win(10), usableIsWide: true)
        session = session.insertSpiral(space: space1, newLeaf: win(20), usableIsWide: true)
        let before = session
        session = session.rebindWindowId(space: space1, from: 20, to: 10)
        #expect(session == before)
    }

    @Test func sessionWideRebindUpdatesWindowOnNonFocusedSpace() {
        let space2 = SpaceId.require(2)
        var session = Session.empty(spaceCount: 2)
        session = session.insertSpiral(space: space1, newLeaf: win(10), usableIsWide: true)
        session = session.insertSpiral(space: space2, newLeaf: win(20), usableIsWide: true)
        session = session.rebindWindowId(from: 20, to: 99)
        #expect(session.focusedSpace == space1)
        #expect(session[space1]!.leaf(containing: 10)?.leaf?.cgWindowId == 10)
        #expect(session[space1]!.focusedWindow == 10)
        #expect(session[space2]!.leaf(containing: 20) == nil)
        #expect(session[space2]!.leaf(containing: 99)?.leaf?.cgWindowId == 99)
    }

    @Test func sessionWideRebindUpdatesFloatingOnNonFocusedSpace() {
        let space2 = SpaceId.require(2)
        var session = Session.empty(spaceCount: 2)
        var space = session[space2]!
        space.floating = [win(30)]
        space.focusedWindow = 30
        session.spaces[space2] = space
        session = session.rebindWindowId(from: 30, to: 99)
        #expect(!session[space2]!.floating.contains(where: { $0.cgWindowId == 30 }))
        #expect(session[space2]!.floating.first?.cgWindowId == 99)
        #expect(session[space2]!.focusedWindow == 99)
    }

    @Test func sessionWideRebindUpdatesNativeFSWindow() {
        var session = Session.empty(spaceCount: 1)
        session.nativeFSWindows = [win(40)]
        session = session.rebindWindowId(from: 40, to: 99)
        #expect(session.nativeFSWindows.first?.cgWindowId == 99)
    }

    @Test func sessionWideRebindRewritesFocusedWindowOnOwningSpace() {
        let space2 = SpaceId.require(2)
        var session = Session.empty(spaceCount: 2)
        session = session.insertSpiral(space: space2, newLeaf: win(10), usableIsWide: true)
        session = session.insertSpiral(space: space2, newLeaf: win(20), usableIsWide: true)
        #expect(session[space2]!.focusedWindow == 20)
        session = session.rebindWindowId(from: 20, to: 99)
        #expect(session[space2]!.focusedWindow == 99)
    }

    @Test func tileFloaterSplitsIntoTree() {
        var session = Session.empty(spaceCount: 1)
        session = session.insertSpiral(space: space1, newLeaf: win(1), usableIsWide: true)
        var space = session[space1]!
        var floater = win(2)
        floater.role = .floating
        space.floating = [floater]
        session.spaces[space1] = space
        session = session.tileFloater(space: space1, cgWindowId: 2, usableIsWide: true)
        let after = session[space1]!
        #expect(!after.floating.contains(where: { $0.cgWindowId == 2 }))
        #expect(after.tiledLeaves().contains(where: { $0.leaf?.cgWindowId == 2 }))
        #expect(after.leaf(containing: 2)?.leaf?.role == .tiled)
        let root = after.nodes[after.root!]!
        #expect(!root.isLeaf)
        #expect(root.children.count == 2)
    }

    @Test func tileFloaterIgnoresUnknownId() {
        var session = Session.empty(spaceCount: 1)
        session = session.insertSpiral(space: space1, newLeaf: win(1), usableIsWide: true)
        let before = session
        session = session.tileFloater(space: space1, cgWindowId: 99, usableIsWide: true)
        #expect(session == before)
    }

    @Test func tileFloaterOnEmptySpaceBecomesRootLeaf() {
        var session = Session.empty(spaceCount: 1)
        var space = session[space1]!
        var floater = win(5)
        floater.role = .floating
        space.floating = [floater]
        session.spaces[space1] = space
        session = session.tileFloater(space: space1, cgWindowId: 5, usableIsWide: true)
        let after = session[space1]!
        #expect(after.floating.isEmpty)
        let root = after.nodes[after.root!]!
        #expect(root.isLeaf)
        #expect(root.leaf?.cgWindowId == 5)
        #expect(root.leaf?.role == .tiled)
        #expect(after.focusedWindow == 5)
    }

    @Test func spaceContainingFindsOtherWorkspace() {
        let space2 = SpaceId.require(2)
        var session = Session.empty(spaceCount: 2)
        session = session.insertSpiral(space: space1, newLeaf: win(10), usableIsWide: true)
        session = session.insertSpiral(space: space2, newLeaf: win(20), usableIsWide: true)
        #expect(session.spaceContaining(cgWindowId: 10) == space1)
        #expect(session.spaceContaining(cgWindowId: 20) == space2)
        #expect(session.spaceContaining(cgWindowId: 99) == nil)
        #expect(session.allWindowIds == Set([10, 20]))
    }
}
