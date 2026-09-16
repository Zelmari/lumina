import Foundation
import Testing
@testable import LuminaLayout

struct PrimitiveTests {
    @Test func emptySessionHasSpace1() {
        let session = Session.empty(spaceCount: 5)
        #expect(session.spaceCount == 5)
        #expect(session.focusedSpace.raw == 1)
        #expect(session.paused == false)
        let space1 = session[SpaceId.require(1)]
        #expect(space1 != nil)
        #expect(space1?.root == nil)
        #expect(space1?.floating.isEmpty == true)
        for i in 1...5 {
            #expect(session[SpaceId.require(i)]?.root == nil)
        }
        #expect(session[SpaceId.require(6)] == nil || session.spaces[SpaceId.require(6)] == nil)
        #expect(session.spaces.count == 5)
    }

    @Test func rectCenterMath() {
        let r = Rect(x: 10, y: 20, w: 100, h: 50)
        #expect(r.minX == 10)
        #expect(r.maxX == 110)
        #expect(r.minY == 20)
        #expect(r.maxY == 70)
        #expect(r.center == Point(x: 60, y: 45))
        #expect(r.area == 5000)
        #expect(r.contains(point: Point(x: 10, y: 20)))
        #expect(!r.contains(point: Point(x: 110, y: 20)))
        let other = Rect(x: 50, y: 30, w: 100, h: 50)
        let inter = r.intersection(other)
        #expect(inter == Rect(x: 50, y: 30, w: 60, h: 40))
    }

    @Test func spaceIdRejectsZeroAndEleven() {
        #expect(SpaceId.make(0) == nil)
        #expect(SpaceId.make(11) == nil)
        #expect(SpaceId(raw: 0) == nil)
        #expect(SpaceId(raw: 11) == nil)
        #expect(SpaceId.make(1)?.raw == 1)
        #expect(SpaceId.make(10)?.raw == 10)
    }
}
