import Foundation
import Testing
@testable import LuminaLayout

private func pwin(_ id: UInt32) -> WindowRef {
    WindowRef(cgWindowId: id, pid: Int32(id), bundleId: "test.\(id)", role: .tiled)
}

private let pspace = SpaceId.require(1)
private let usable = Rect(x: 0, y: 0, w: 1000, h: 800)
private let gaps = Gaps(inner: 8, outer: 8)

struct PredictTests {
    @Test func firstLeafPredictsTheWholeUsableRect() {
        let session = Session.empty(spaceCount: 1)
        let predicted = session.predictedTile(
            space: pspace,
            window: pwin(9),
            usable: usable,
            gaps: gaps,
            usableIsWide: true
        )
        let inserted = session.insertSpiral(space: pspace, newLeaf: pwin(9), usableIsWide: true)
        let space = inserted[pspace]!
        let real = frames(space: space, usable: usable, gaps: gaps)[space.root!]
        #expect(predicted == real)
    }

    @Test func secondLeafPredictsExactlyWhatAdoptionGets() {
        var session = Session.empty(spaceCount: 1)
        session = session.insertSpiral(space: pspace, newLeaf: pwin(1), usableIsWide: true)
        let predicted = session.predictedTile(
            space: pspace,
            window: pwin(2),
            usable: usable,
            gaps: gaps,
            usableIsWide: true
        )
        let adopted = session.insertSpiral(space: pspace, newLeaf: pwin(2), usableIsWide: true)
        let space = adopted[pspace]!
        let node = space.leaf(containing: 2)!
        let real = frames(space: space, usable: usable, gaps: gaps)[node.id]
        #expect(predicted == real)
        // A split must differ from the first window's rect.
        #expect(predicted != frames(space: space, usable: usable, gaps: gaps)[space.leaf(containing: 1)!.id])
    }

    @Test func doesNotMutateTheSession() {
        var session = Session.empty(spaceCount: 1)
        session = session.insertSpiral(space: pspace, newLeaf: pwin(1), usableIsWide: true)
        let before = session
        _ = session.predictedTile(
            space: pspace,
            window: pwin(2),
            usable: usable,
            gaps: gaps,
            usableIsWide: true
        )
        #expect(session == before)
    }

    @Test func returnsNilDuringLuminaFullscreen() {
        var session = Session.empty(spaceCount: 1)
        session = session.insertSpiral(space: pspace, newLeaf: pwin(1), usableIsWide: true)
        let root = session[pspace]!.root
        session.spaces[pspace]?.luminaFullscreen = root
        #expect(
            session.predictedTile(
                space: pspace,
                window: pwin(2),
                usable: usable,
                gaps: gaps,
                usableIsWide: true
            ) == nil
        )
    }

    @Test func returnsNilWhenTheLeafWouldImmediatelyFloat() {
        var session = Session.empty(spaceCount: 1)
        session = session.insertSpiral(space: pspace, newLeaf: pwin(1), usableIsWide: true)
        // Two windows that both demand more width than the display: the new
        // leaf is the one clampOverflow floats, so there is no tile to predict.
        let huge = [
            UInt32(1): Size(w: 5000, h: 5000),
            UInt32(2): Size(w: 5000, h: 5000),
        ]
        #expect(
            session.predictedTile(
                space: pspace,
                window: pwin(2),
                usable: usable,
                gaps: gaps,
                usableIsWide: true,
                minSizes: huge
            ) == nil
        )
    }

    @Test func returnsNilForAnUnknownSpace() {
        let session = Session.empty(spaceCount: 1)
        let other = SpaceId.require(2)
        #expect(
            session.predictedTile(
                space: other,
                window: pwin(9),
                usable: usable,
                gaps: gaps,
                usableIsWide: true
            ) == nil
        )
    }
}
