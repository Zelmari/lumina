import Foundation
import Testing
@testable import LuminaLayout

struct WindowIdentityTests {
    @Test func uniqueCloseFrameWins() {
        let ax = Rect(x: 0, y: 0, w: 800, h: 600)
        let id = pickCGWindowId(
            axFrame: ax,
            candidates: [
                (1, Rect(x: 4, y: 2, w: 800, h: 600)),
                (2, Rect(x: 810, y: 0, w: 800, h: 600)),
            ]
        )
        #expect(id == 1)
    }

    @Test func hugeMismatchIsNil() {
        let id = pickCGWindowId(
            axFrame: Rect(x: 0, y: 0, w: 64, h: 64),
            candidates: [(9, Rect(x: 0, y: 0, w: 800, h: 600))]
        )
        #expect(id == nil)
    }

    @Test func ambiguousSideBySideIsNil() {
        let ax = Rect(x: 8, y: 48, w: 723, h: 907)
        let id = pickCGWindowId(
            axFrame: ax,
            candidates: [
                (1, Rect(x: 8, y: 48, w: 723, h: 907)),
                (2, Rect(x: 8, y: 48, w: 723, h: 907)),
            ]
        )
        #expect(id == nil)
    }

    @Test func excludingRemovesWinner() {
        let ax = Rect(x: 0, y: 0, w: 800, h: 600)
        let id = pickCGWindowId(
            axFrame: ax,
            candidates: [
                (1, Rect(x: 0, y: 0, w: 800, h: 600)),
                (2, Rect(x: 810, y: 0, w: 800, h: 600)),
            ],
            excluding: [1]
        )
        #expect(id == 2)
    }

    @Test func axFrameLooksOnScreenIgnoresWrongId() {
        let frame = Rect(x: 8, y: 48, w: 1454, h: 907)
        #expect(axFrameLooksOnScreen(frame: frame, onScreenFrames: [frame]))
        #expect(!axFrameLooksOnScreen(frame: frame, onScreenFrames: [Rect(x: 2000, y: 0, w: 400, h: 300)]))
        #expect(!axFrameLooksOnScreen(frame: Rect(x: 0, y: 0, w: 64, h: 64), onScreenFrames: [frame]))
    }
}
