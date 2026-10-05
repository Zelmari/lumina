import Foundation
import Testing
@testable import LuminaLayout

private func win(_ id: UInt32) -> WindowRef {
    WindowRef(cgWindowId: id, pid: Int32(id), role: .tiled, lastOnscreenFrame: Rect(x: 0, y: 0, w: 100, h: 100))
}

private let space1 = SpaceId.require(1)
private let usable = Rect(x: 0, y: 0, w: 1000, h: 800)
private let gaps = Gaps(inner: 0, outer: 0)

struct BalanceResizeTests {
    @Test func balanceRecursiveEqualizesNested() {
        var session = Session.empty(spaceCount: 1)
        session = session.insertSpiral(space: space1, newLeaf: win(1), usableIsWide: true)
        session = session.insertSpiral(space: space1, newLeaf: win(2), usableIsWide: true)
        session = session.insertSpiral(space: space1, newLeaf: win(3), usableIsWide: true)
        var space = session[space1]!
        let rootId = space.root!
        var root = space.nodes[rootId]!
        root.ratio = [0.8, 0.2]
        space.setNode(root)
        let splitId = root.children[1]
        var split = space.nodes[splitId]!
        split.ratio = [0.9, 0.1]
        space.setNode(split)
        session.spaces[space1] = space
        session = session.balance(space: space1)
        space = session[space1]!
        #expect(space.nodes[rootId]!.ratio == [1.0, 1.0])
        #expect(space.nodes[splitId]!.ratio == [1.0, 1.0])
    }

    @Test func growFivePercentMovesParentSplit() {
        var session = Session.empty(spaceCount: 1)
        session = session.insertSpiral(space: space1, newLeaf: win(1), usableIsWide: true)
        session = session.insertSpiral(space: space1, newLeaf: win(2), usableIsWide: true)
        let space = session[space1]!
        let root = space.nodes[space.root!]!
        let focused = root.children[1]
        let (after, floated) = session.resize(
            space: space1,
            focusedLeaf: focused,
            delta: .grow,
            minSizes: [:],
            usable: usable,
            gaps: gaps
        )
        #expect(floated == nil)
        let newRoot = after[space1]!.nodes[space.root!]!
        // sum was 1.0; delta = 0.05. grow focused (index 1): [0.45, 0.55]
        #expect(abs(newRoot.ratio[0] - 0.45) < 1e-9)
        #expect(abs(newRoot.ratio[1] - 0.55) < 1e-9)
        let f = frames(space: after[space1]!, usable: usable, gaps: gaps)
        #expect(abs(f[focused]!.w - 550) < 1e-6)
        #expect(abs(f[root.children[0]]!.w - 450) < 1e-6)
    }

    @Test func cannotShrinkBelow80pt() {
        // usable 200 wide, two tiles, inner 0 → 100 each. 80pt floor: shrink limited.
        let small = Rect(x: 0, y: 0, w: 200, h: 400)
        var session = Session.empty(spaceCount: 1)
        session = session.insertSpiral(space: space1, newLeaf: win(1), usableIsWide: true)
        session = session.insertSpiral(space: space1, newLeaf: win(2), usableIsWide: true)
        let space = session[space1]!
        let root = space.nodes[space.root!]!
        let focused = root.children[1]
        var current = session
        for _ in 0..<30 {
            let (next, floated) = current.resize(
                space: space1,
                focusedLeaf: focused,
                delta: .shrink,
                minSizes: [:],
                usable: small,
                gaps: gaps
            )
            #expect(floated == nil)
            current = next
        }
        let f = frames(space: current[space1]!, usable: small, gaps: gaps)
        #expect(f[focused]!.w + 1e-6 >= 80)
        #expect(f[root.children[0]]!.w + 1e-6 >= 80)
    }

    @Test func siblingMinConflictFloatsTheOffendingLeaf() {
        // usable 400, 50/50 (200 each). win2's minimum (250) exceeds its
        // span. Dwindle splits are not rebalanced: win2 floats and win1
        // keeps the whole width.
        let box = Rect(x: 0, y: 0, w: 400, h: 400)
        var session = Session.empty(spaceCount: 1)
        session = session.insertSpiral(space: space1, newLeaf: win(1), usableIsWide: true)
        session = session.insertSpiral(space: space1, newLeaf: win(2), usableIsWide: true)
        let mins: [UInt32: Size] = [1: Size(w: 150, h: 0), 2: Size(w: 250, h: 0)]
        let (after, floated) = session.clampOverflow(
            space: space1,
            minSizes: mins,
            usable: box,
            gaps: gaps
        )
        #expect(floated.map(\.cgWindowId) == [2])
        let space = after[space1]!
        #expect(space.nodes[space.root!]?.leaf?.cgWindowId == 1)
        let f = frames(space: space, usable: box, gaps: gaps)
        #expect(f.values.first!.w == 400)
    }

    @Test func bothMinsOverflowFloatsOversizedLeaf() {
        let box = Rect(x: 0, y: 0, w: 200, h: 400)
        var session = Session.empty(spaceCount: 1)
        session = session.insertSpiral(space: space1, newLeaf: win(1), usableIsWide: true)
        session = session.insertSpiral(space: space1, newLeaf: win(2), usableIsWide: true)
        let mins: [UInt32: Size] = [1: Size(w: 150, h: 0), 2: Size(w: 150, h: 0)]
        let focused = session[space1]!.lastTiledLeaf!
        let (after, floated) = session.clampOverflow(
            space: space1,
            minSizes: mins,
            usable: box,
            gaps: gaps,
            preferFloat: focused
        )
        #expect(floated.count == 1)
        #expect(floated[0].cgWindowId == 2)
        let space = after[space1]!
        #expect(space.floating.contains(where: { $0.cgWindowId == 2 }))
        #expect(space.nodes[space.root!]?.leaf?.cgWindowId == 1)
        let f = frames(space: space, usable: box, gaps: gaps)
        #expect(f.count == 1)
        #expect(f.values.first!.w == 200)
    }

    @Test func nestedMinSizeFloatsInsteadOfRebalancing() {
        // win1 | (win2 over win3), root skewed 0.9/0.1. The right column's
        // minimum (300) exceeds its 50pt span; its leaves float rather than
        // the root ratio being widened.
        let box = Rect(x: 0, y: 0, w: 500, h: 400)
        var session = Session.empty(spaceCount: 1)
        session = session.insertSpiral(space: space1, newLeaf: win(1), usableIsWide: true)
        session = session.insertSpiral(space: space1, newLeaf: win(2), usableIsWide: true)
        session = session.insertSpiral(space: space1, newLeaf: win(3), usableIsWide: true)
        var space = session[space1]!
        let root = space.nodes[space.root!]!
        var skewed = root
        skewed.ratio = [0.9, 0.1]
        space.setNode(skewed)
        session.spaces[space1] = space
        let mins: [UInt32: Size] = [
            1: Size(w: 100, h: 0),
            2: Size(w: 300, h: 0),
            3: Size(w: 300, h: 0),
        ]
        let (after, floated) = session.clampOverflow(space: space1, minSizes: mins, usable: box, gaps: gaps)
        #expect(floated.map(\.cgWindowId) == [2, 3])
        let clamped = after[space1]!
        #expect(clamped.nodes[clamped.root!]?.leaf?.cgWindowId == 1)
    }

    @Test func overflowResolvesRootBeforeNestedContainer() {
        // root [win1 | (win2 / win3)]. Root cannot fit 150+150 wide and the
        // nested vertical split cannot fit 300+300 tall. Root-first order
        // floats the root's last leaf (win2) before the nested split's (win3).
        let box = Rect(x: 0, y: 0, w: 200, h: 400)
        var session = Session.empty(spaceCount: 1)
        session = session.insertSpiral(space: space1, newLeaf: win(1), usableIsWide: true)
        session = session.insertSpiral(space: space1, newLeaf: win(2), usableIsWide: true)
        session = session.insertSpiral(space: space1, newLeaf: win(3), usableIsWide: true)
        let mins: [UInt32: Size] = [
            1: Size(w: 150, h: 0),
            2: Size(w: 150, h: 300),
            3: Size(w: 150, h: 300),
        ]
        let (after, floated) = session.clampOverflow(
            space: space1,
            minSizes: mins,
            usable: box,
            gaps: gaps
        )
        #expect(floated.map(\.cgWindowId) == [2, 3])
        let space = after[space1]!
        #expect(space.floating.map(\.cgWindowId) == [2, 3])
        #expect(space.nodes[space.root!]?.leaf?.cgWindowId == 1)
    }

    @Test func floatingLuminaFSLeafUnstashesSiblings() {
        var session = Session.empty(spaceCount: 1)
        session = session.insertSpiral(space: space1, newLeaf: win(1), usableIsWide: true)
        session = session.insertSpiral(space: space1, newLeaf: win(2), usableIsWide: true)
        let fsLeaf = session[space1]!.leaf(containing: 1)!.id
        session = session.enterLuminaFS(space: space1, leaf: fsLeaf)
        #expect(session[space1]!.leaf(containing: 2)?.leaf?.role == .stashed)
        let (after, floated) = session.floatLeaf(space: space1, nodeId: fsLeaf)
        #expect(floated?.cgWindowId == 1)
        let space = after[space1]!
        #expect(space.luminaFullscreen == nil)
        #expect(space.leaf(containing: 2)?.leaf?.role == .tiled)
        #expect(space.floating.contains(where: { $0.cgWindowId == 1 }))
    }

    @Test func resizeIgnoredForFloatingAndSingleLeaf() {
        var session = Session.empty(spaceCount: 1)
        session = session.insertSpiral(space: space1, newLeaf: win(1), usableIsWide: true)
        let root = session[space1]!.root!
        let (after, floated) = session.resize(
            space: space1,
            focusedLeaf: root,
            delta: .grow,
            minSizes: [:],
            usable: usable,
            gaps: gaps
        )
        #expect(floated == nil)
        #expect(after[space1]!.nodes[root]!.leaf?.cgWindowId == 1)

        var floatingSession = Session.empty(spaceCount: 1)
        floatingSession = floatingSession.insertSpiral(space: space1, newLeaf: win(8), usableIsWide: true)
        floatingSession = floatingSession.insertSpiral(space: space1, newLeaf: win(9), usableIsWide: true)
        var space = floatingSession[space1]!
        // Keep the floater in the tree next to a tiled sibling so `resize`
        // reaches the role guard instead of bailing at the node lookup.
        let floaterId = space.lastTiledLeaf!
        var floater = space.nodes[floaterId]!.leaf!
        floater.role = .floating
        var floaterNode = space.nodes[floaterId]!
        floaterNode.leaf = floater
        space.setNode(floaterNode)
        floatingSession.spaces[space1] = space
        let (after2, floated2) = floatingSession.resize(
            space: space1,
            focusedLeaf: floaterId,
            delta: .grow,
            minSizes: [:],
            usable: usable,
            gaps: gaps
        )
        #expect(floated2 == nil)
        #expect(after2 == floatingSession)
    }
}
