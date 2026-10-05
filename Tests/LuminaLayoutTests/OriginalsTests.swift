import Foundation
import Testing
@testable import LuminaLayout

struct OriginalsTests {
    private let usable = Rect(x: 8, y: 41, w: 1454, h: 907)
    private let gaps = Gaps(inner: 8, outer: 8)

    @Test func fullUsableIsAnEngineFrame() {
        #expect(looksLikeEngineFrame(usable, usable: usable, gaps: gaps))
    }

    @Test func halfAndQuarterTilesAreEngineFrames() {
        // 3-window dwindle: half-width column and quarter tiles, gap-aware.
        let halfWidth = Rect(x: 8, y: 41, w: 723, h: 907)
        let bottomRight = Rect(x: 739, y: 499, w: 723, h: 449)
        #expect(looksLikeEngineFrame(halfWidth, usable: usable, gaps: gaps))
        #expect(looksLikeEngineFrame(bottomRight, usable: usable, gaps: gaps))
        let quarter = Rect(x: 739, y: 499, w: 723, h: 449)
        #expect(looksLikeEngineFrame(quarter, usable: usable, gaps: gaps))
    }

    @Test func normalWindowFramesAreTrusted() {
        let safari = Rect(x: 174, y: 162, w: 1073, h: 632)
        let vscode = Rect(x: 174, y: 81, w: 1165, h: 725)
        #expect(!looksLikeEngineFrame(safari, usable: usable, gaps: gaps))
        #expect(!looksLikeEngineFrame(vscode, usable: usable, gaps: gaps))
    }

    @Test func smallSquareWindowIsTrusted() {
        // Discord's real 300x300 is near the /3 height but not the width.
        let discord = Rect(x: 585, y: 189, w: 300, h: 300)
        #expect(!looksLikeEngineFrame(discord, usable: usable, gaps: gaps))
    }

    @Test func parkSliverAndOffDisplayAreNotTiles() {
        let park = Rect(x: 1462, y: 948, w: 723, h: 449)
        let offDisplay = Rect(x: -2000, y: 41, w: 723, h: 449)
        #expect(!looksLikeEngineFrame(park, usable: usable, gaps: gaps))
        #expect(!looksLikeEngineFrame(offDisplay, usable: usable, gaps: gaps))
    }

    @Test func nonUniformFractionIsTrusted() {
        // 60% width is not an engine split.
        let frame = Rect(x: 8, y: 41, w: 872, h: 907)
        #expect(!looksLikeEngineFrame(frame, usable: usable, gaps: gaps))
    }
}
