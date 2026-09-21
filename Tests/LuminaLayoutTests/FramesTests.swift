import Foundation
import Testing
@testable import LuminaLayout

private func win(_ id: UInt32) -> WindowRef {
    WindowRef(cgWindowId: id, pid: Int32(id), role: .tiled, lastOnscreenFrame: Rect(x: 0, y: 0, w: 100, h: 100))
}

private let space1 = SpaceId.require(1)
private let usable = Rect(x: 8, y: 8, w: 800, h: 600)
private let gaps = Gaps(inner: 8, outer: 8)

struct FramesTests {
    @Test func singleChildGetsUsableNoInner() {
        var session = Session.empty(spaceCount: 1)
        session = session.insertSpiral(space: space1, newLeaf: win(1), usableIsWide: true)
        let space = session[space1]!
        let f = frames(space: space, usable: usable, gaps: gaps)
        #expect(f.count == 1)
        #expect(f[space.root!] == usable)
    }

    @Test func twoChildrenHorizontalShareInnerGap() {
        var session = Session.empty(spaceCount: 1)
        session = session.insertSpiral(space: space1, newLeaf: win(1), usableIsWide: true)
        session = session.insertSpiral(space: space1, newLeaf: win(2), usableIsWide: true)
        let space = session[space1]!
        let f = frames(space: space, usable: usable, gaps: gaps)
        let root = space.nodes[space.root!]!
        let left = f[root.children[0]]!
        let right = f[root.children[1]]!
        #expect(left.w == 396)
        #expect(right.w == 396)
        #expect(left.x == 8)
        #expect(right.x == 8 + 396 + 8)
        #expect(left.h == 600)
        #expect(right.h == 600)
        #expect(right.x - (left.x + left.w) == 8)
    }

    @Test func twoChildrenVertical() {
        var session = Session.empty(spaceCount: 1)
        session = session.insertSpiral(space: space1, newLeaf: win(1), usableIsWide: false)
        session = session.insertSpiral(space: space1, newLeaf: win(2), usableIsWide: false)
        let space = session[space1]!
        let f = frames(space: space, usable: usable, gaps: gaps)
        let root = space.nodes[space.root!]!
        let top = f[root.children[0]]!
        let bottom = f[root.children[1]]!
        let available = usable.h - 8
        #expect(top.h == available / 2)
        #expect(bottom.h == available / 2)
        #expect(bottom.y - (top.y + top.h) == 8)
        #expect(top.w == usable.w)
    }

    @Test func floaterDoesNotChangeFrames() {
        var session = Session.empty(spaceCount: 1)
        session = session.insertSpiral(space: space1, newLeaf: win(1), usableIsWide: true)
        session = session.insertSpiral(space: space1, newLeaf: win(2), usableIsWide: true)
        var space = session[space1]!
        let before = frames(space: space, usable: usable, gaps: gaps)
        space.floating.append(
            WindowRef(cgWindowId: 99, pid: 99, role: .floating, lastOnscreenFrame: Rect(x: 0, y: 0, w: 10, h: 10))
        )
        let after = frames(space: space, usable: usable, gaps: gaps)
        #expect(before == after)
        #expect(after.count == 2)
    }

    @Test func nestedThreeWindowsDeterministic() {
        // Frontmost-first: win1 root, win2 splits it 50/50 H, win3 splits focused (win2) V.
        var session = Session.empty(spaceCount: 1)
        session = session.insertSpiral(space: space1, newLeaf: win(1), usableIsWide: true)
        session = session.insertSpiral(space: space1, newLeaf: win(2), usableIsWide: true)
        session = session.insertSpiral(space: space1, newLeaf: win(3), usableIsWide: true)
        let space = session[space1]!
        let f = frames(space: space, usable: usable, gaps: gaps)
        #expect(f.count == 3)
        let root = space.nodes[space.root!]!
        let w1 = f[root.children[0]]!
        #expect(abs(w1.w - 396) < 0.0001)
        let split = space.nodes[root.children[1]]!
        let w2 = f[split.children[0]]!
        let w3 = f[split.children[1]]!
        #expect(abs(w2.w - 396) < 0.0001)
        #expect(abs(w3.w - 396) < 0.0001)
        #expect(abs(w2.h + w3.h + 8 - 600) < 0.0001)
    }

    @Test func oddWidthGivesRemainderToLastSibling() {
        let odd = Rect(x: 0, y: 0, w: 801, h: 100)
        var session = Session.empty(spaceCount: 1)
        session = session.insertSpiral(space: space1, newLeaf: win(1), usableIsWide: true)
        session = session.insertSpiral(space: space1, newLeaf: win(2), usableIsWide: true)
        let space = session[space1]!
        let f = frames(space: space, usable: odd, gaps: Gaps(inner: 0, outer: 0))
        let root = space.nodes[space.root!]!
        let left = f[root.children[0]]!
        let right = f[root.children[1]]!
        #expect(left.w + right.w == 801)
        #expect(left.w == 401 || left.w == 400)
        #expect(right.w == 801 - left.w)
        #expect(left.w.rounded() == left.w)
        #expect(right.w.rounded() == right.w)
    }

    @Test func emptyRootReturnsEmpty() {
        let space = Space(id: space1)
        #expect(frames(space: space, usable: usable, gaps: gaps).isEmpty)
    }
}
