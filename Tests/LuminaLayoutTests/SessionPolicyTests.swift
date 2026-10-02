import Foundation
import Testing
@testable import LuminaLayout

struct StashTests {
    @Test func stashFrameBottomRightVsLeft() {
        let display = DisplayFrame(
            axFrame: Rect(x: 0, y: 0, w: 1440, h: 900),
            axVisibleFrame: Rect(x: 0, y: 25, w: 1440, h: 850)
        )
        let right = stashFrame(for: 600, display: display, dockRight: false, lastWidth: 800)
        #expect(right.w == 800)
        #expect(right.h == 600)
        #expect(right.x == 1439)
        #expect(right.y == 874)
        #expect(isCornerParked(right, display: display))
        let left = stashFrame(for: 600, display: display, dockRight: true, lastWidth: 800)
        #expect(left.x == 1 - 800)
        #expect(left.w == 800)
        #expect(left.y == 874)
        #expect(isCornerParked(left, display: display))
        #expect(isStashedAway(right, display: display))
        #expect(isStashedAway(left, display: display))
        let zoom = stashFrame(for: 600, display: display, dockRight: false, lastWidth: 800, inset: 0)
        #expect(zoom.x == 1440)
        #expect(zoom.y == 875)
        let hung = Rect(x: 1439, y: -592, w: 800, h: 600)
        #expect(isStashedAway(hung, display: display))
        #expect(!display.axVisibleFrame.intersects(hung))
    }

    @Test func menuBarHangKeepsOnePointOnDisplay() {
        let display = DisplayFrame(
            axFrame: Rect(x: 0, y: 0, w: 1440, h: 900),
            axVisibleFrame: Rect(x: 0, y: 25, w: 1440, h: 850)
        )
        let after = Rect(x: 100, y: 40, w: 800, h: 600)
        let hang = menuBarHangFrame(after: after, display: display, x: 1439, inset: 1)
        #expect(hang.y == -599)
        #expect(hang.maxY == 1)
        #expect(hang.h == 600)
        #expect(isMenuBarParked(hang, display: display))
        #expect(isStashedAway(hang, display: display))
        #expect(!display.axVisibleFrame.intersects(hang))
    }

    @Test func stashedRoleDoesNotReplaceSavedFrame() {
        let display = DisplayFrame(
            axFrame: Rect(x: 0, y: 0, w: 1440, h: 900),
            axVisibleFrame: Rect(x: 0, y: 25, w: 1440, h: 850)
        )
        let tile = Rect(x: 40, y: 40, w: 700, h: 500)
        let parked = stashFrame(for: 500, display: display, dockRight: false, lastWidth: 700)
        let hang = menuBarHangFrame(after: parked, display: display, x: parked.x)
        #expect(shouldCaptureOnscreenFrame(role: .tiled, frame: tile, display: display))
        #expect(!shouldCaptureOnscreenFrame(role: .stashed, frame: tile, display: display))
        #expect(!shouldCaptureOnscreenFrame(role: .floating, frame: parked, display: display))
        #expect(!shouldCaptureOnscreenFrame(role: .tiled, frame: hang, display: display))
    }

    @Test func unlandedSetFrameDoesNotFloatAParkedWindow() {
        let display = DisplayFrame(
            axFrame: Rect(x: 0, y: 0, w: 1440, h: 900),
            axVisibleFrame: Rect(x: 0, y: 25, w: 1440, h: 850)
        )
        let parked = stashFrame(for: 500, display: display, dockRight: false, lastWidth: 700)
        let elsewhere = Rect(x: 80, y: 80, w: 400, h: 300)
        let hang = menuBarHangFrame(after: elsewhere, display: display, x: parked.x)
        #expect(unlandedSetFrameAction(live: parked, display: display, alreadyRetried: false) == .retry)
        #expect(unlandedSetFrameAction(live: parked, display: display, alreadyRetried: true) == .keepTiled)
        #expect(unlandedSetFrameAction(live: hang, display: display, alreadyRetried: true) == .keepTiled)
        #expect(unlandedSetFrameAction(live: elsewhere, display: display, alreadyRetried: false) == .retry)
        #expect(unlandedSetFrameAction(live: elsewhere, display: display, alreadyRetried: true) == .float)
    }

    @Test func tilingOpsPreserveOriginalFrame() {
        var session = Session.empty(spaceCount: 1)
        let first = Rect(x: 100, y: 100, w: 640, h: 480)
        let second = Rect(x: 200, y: 200, w: 800, h: 600)
        session = session.insertSpiral(
            space: SpaceId.require(1),
            newLeaf: WindowRef(cgWindowId: 1, pid: 1, lastOnscreenFrame: first, originalFrame: first),
            usableIsWide: true
        )
        session = session.insertSpiral(
            space: SpaceId.require(1),
            newLeaf: WindowRef(cgWindowId: 2, pid: 2, lastOnscreenFrame: second, originalFrame: second),
            usableIsWide: true
        )
        session = session.swap(space: SpaceId.require(1), a: 1, b: 2)
        #expect(session[SpaceId.require(1)]!.leaf(containing: 1)?.leaf?.originalFrame == first)
        #expect(session[SpaceId.require(1)]!.leaf(containing: 2)?.leaf?.originalFrame == second)
        let entries = session.collectStashEntries()
        #expect(entries.first(where: { $0.cgWindowId == 1 })?.originalFrame == first)
        #expect(entries.first(where: { $0.cgWindowId == 2 })?.originalFrame == second)
    }

    @Test func sessionFileRoundTripsOriginalFrame() throws {
        let tile = Rect(x: 1, y: 2, w: 3, h: 4)
        let original = Rect(x: 10, y: 20, w: 640, h: 480)
        let file = SessionFile(
            instanceId: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!,
            bootSessionUUID: "boot",
            focusedSpace: 1,
            displayUUID: "disp",
            stash: [StashEntry(cgWindowId: 10, pid: 20, bundleId: "com.apple.Terminal", lastOnscreenFrame: tile, originalFrame: original)]
        )
        let decoded = try SessionFile.decode(try SessionFile.encode(file))
        #expect(decoded == file)
        #expect(decoded.stash.first?.originalFrame == original)
        // Files written before originalFrame existed still decode, with nil.
        let legacy = """
        {"instanceId":"00000000-0000-0000-0000-000000000001","bootSessionUUID":"boot","focusedSpace":1,"displayUUID":"disp","stash":[{"cgWindowId":10,"pid":20,"bundleId":"com.apple.Terminal","lastOnscreenFrame":{"x":1,"y":2,"w":3,"h":4}}]}
        """
        let legacyFile = try SessionFile.decode(Data(legacy.utf8))
        #expect(legacyFile.stash.first?.originalFrame == nil)
        #expect(legacyFile.stash.first?.lastOnscreenFrame == tile)
    }

    @Test func sessionFileRoundTripsOriginalsMap() throws {
        let tile = Rect(x: 1, y: 2, w: 3, h: 4)
        let first = Rect(x: 10, y: 20, w: 640, h: 480)
        let second = Rect(x: 30, y: 40, w: 800, h: 600)
        let file = SessionFile(
            instanceId: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!,
            bootSessionUUID: "boot",
            focusedSpace: 1,
            displayUUID: "disp",
            stash: [StashEntry(cgWindowId: 10, pid: 20, bundleId: nil, lastOnscreenFrame: tile)],
            originals: [10 as UInt32: first, 20 as UInt32: second]
        )
        let data = try SessionFile.encode(file)
        let decoded = try SessionFile.decode(data)
        #expect(decoded == file)
        #expect(decoded.originals[10] == first)
        #expect(decoded.originals[20] == second)
        // The registry survives a JSON text round-trip (not just in-memory).
        let text = String(data: data, encoding: .utf8)!
        #expect(text.contains("\"originals\""))
        let reparsed = try SessionFile.decode(Data(text.utf8))
        #expect(reparsed == file)
    }

    @Test func legacySessionFileWithoutOriginalsDecodesToEmpty() throws {
        let legacy = """
        {"instanceId":"00000000-0000-0000-0000-000000000001","bootSessionUUID":"boot","focusedSpace":1,"displayUUID":"disp","stash":[]}
        """
        let decoded = try SessionFile.decode(Data(legacy.utf8))
        #expect(decoded.originals == [:])
    }

    @Test func collectOriginalsGathersAcrossSpacesSkippingNil() {
        var session = Session.empty(spaceCount: 2)
        let first = Rect(x: 10, y: 20, w: 640, h: 480)
        let third = Rect(x: 30, y: 40, w: 800, h: 600)
        let floated = Rect(x: 50, y: 60, w: 320, h: 240)
        session = session.insertSpiral(
            space: SpaceId.require(1),
            newLeaf: WindowRef(cgWindowId: 1, pid: 1, lastOnscreenFrame: first, originalFrame: first),
            usableIsWide: true
        )
        session = session.insertSpiral(
            space: SpaceId.require(1),
            newLeaf: WindowRef(cgWindowId: 2, pid: 2, lastOnscreenFrame: first, originalFrame: nil),
            usableIsWide: true
        )
        session = session.insertSpiral(
            space: SpaceId.require(2),
            newLeaf: WindowRef(cgWindowId: 3, pid: 3, lastOnscreenFrame: third, originalFrame: third),
            usableIsWide: true
        )
        var space1 = session[SpaceId.require(1)]!
        space1.floating.append(WindowRef(cgWindowId: 4, pid: 4, role: .floating, lastOnscreenFrame: floated, originalFrame: floated))
        space1.floating.append(WindowRef(cgWindowId: 5, pid: 5, role: .floating, lastOnscreenFrame: floated, originalFrame: nil))
        session.spaces[SpaceId.require(1)] = space1
        let got = session.collectOriginals()
        #expect(got == [1 as UInt32: first, 3 as UInt32: third, 4 as UInt32: floated])
        #expect(got[2] == nil)
        #expect(got[5] == nil)
    }

    @Test func resolveOriginalPrefersKnownOverLive() {
        let live = Rect(x: 0, y: 0, w: 700, h: 500)
        let known = Rect(x: 100, y: 100, w: 640, h: 480)
        #expect(resolveOriginal(cgWindowId: 7, liveFrame: live, knownOriginals: [7 as UInt32: known]) == known)
        #expect(resolveOriginal(cgWindowId: 8, liveFrame: live, knownOriginals: [7 as UInt32: known]) == live)
        #expect(resolveOriginal(cgWindowId: 7, liveFrame: live, knownOriginals: [:]) == live)
    }

    @Test func cascadeRestoreStaysInsideUsableAndOffsets() {
        let usable = Rect(x: 8, y: 8, w: 1440, h: 860)
        let first = cascadeRestoreRect(usable: usable, index: 0)
        let second = cascadeRestoreRect(usable: usable, index: 1)
        #expect(usable.contains(point: first.center))
        #expect(usable.contains(point: second.center))
        #expect(first.w <= usable.w && first.h <= usable.h)
        #expect(second.x > first.x && second.y > first.y)
        #expect(cascadeRestoreRect(usable: usable, index: 8) == first)
    }

    @Test func sessionJSONRoundTripOmitsTree() throws {
        let file = SessionFile(
            instanceId: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!,
            bootSessionUUID: "boot",
            focusedSpace: 3,
            displayUUID: "disp",
            stash: [
                StashEntry(
                    cgWindowId: 10,
                    pid: 20,
                    bundleId: "com.apple.Terminal",
                    lastOnscreenFrame: Rect(x: 1, y: 2, w: 3, h: 4)
                ),
            ]
        )
        let data = try SessionFile.encode(file)
        let text = String(data: data, encoding: .utf8)!
        #expect(!text.contains("paused"))
        #expect(!text.contains("ratio"))
        #expect(!text.contains("bookmark"))
        let decoded = try SessionFile.decode(data)
        #expect(decoded == file)
        #expect(decoded.focusedSpace == 3)
    }
}

struct SpaceSwitchTests {
    @Test func wrapMath() {
        #expect(wrapWorkspace(current: 1, count: 5, delta: -1) == 5)
        #expect(wrapWorkspace(current: 5, count: 5, delta: 1) == 1)
        #expect(wrapWorkspace(current: 3, count: 5, delta: 1) == 4)
    }

    @Test func noOpIdGreaterThanCount() {
        let session = Session.empty(spaceCount: 5)
        #expect(resolveWorkspace(id: 99, count: 5) == nil)
        let after = session.switchTo(SpaceId.require(1))
        #expect(after.focusedSpace.raw == 1)
    }

    @Test func focusRestorationPrefersRecordedFocus() {
        var session = Session.empty(spaceCount: 2)
        session = session.insertSpiral(
            space: SpaceId.require(2),
            newLeaf: WindowRef(cgWindowId: 11, pid: 1),
            usableIsWide: true
        )
        session = session.insertSpiral(
            space: SpaceId.require(2),
            newLeaf: WindowRef(cgWindowId: 22, pid: 2),
            usableIsWide: true
        )
        var space = session[SpaceId.require(2)]!
        space.focusedWindow = 11
        session.spaces[SpaceId.require(2)] = space
        #expect(session[SpaceId.require(2)]!.focusRestorationCandidate() == 11)
        #expect(session[SpaceId.require(1)]!.focusRestorationCandidate() == nil)
    }

    @Test func focusRestorationFallsBackWhenRecordedFocusIsGone() {
        var session = Session.empty(spaceCount: 2)
        session = session.insertSpiral(
            space: SpaceId.require(2),
            newLeaf: WindowRef(cgWindowId: 11, pid: 1),
            usableIsWide: true
        )
        session = session.insertSpiral(
            space: SpaceId.require(2),
            newLeaf: WindowRef(cgWindowId: 22, pid: 2),
            usableIsWide: true
        )
        var space = session[SpaceId.require(2)]!
        // Recorded focus points at a window that no longer lives here.
        space.focusedWindow = 99
        session.spaces[SpaceId.require(2)] = space
        // insertSpiral leaves lastTiledLeaf on the newest leaf.
        #expect(session[SpaceId.require(2)]!.focusRestorationCandidate() == 22)
        session = session.removeWindow(space: SpaceId.require(2), cgWindowId: 22)
        #expect(session[SpaceId.require(2)]!.focusRestorationCandidate() == 11)
    }

    @Test func focusRestorationPrefersFullscreenLeafAndFloater() {
        var session = Session.empty(spaceCount: 2)
        session = session.insertSpiral(
            space: SpaceId.require(2),
            newLeaf: WindowRef(cgWindowId: 11, pid: 1),
            usableIsWide: true
        )
        session = session.insertSpiral(
            space: SpaceId.require(2),
            newLeaf: WindowRef(cgWindowId: 22, pid: 2),
            usableIsWide: true
        )
        let leaf1 = session[SpaceId.require(2)]!.leaf(containing: 11)!.id
        session = session.enterLuminaFS(space: SpaceId.require(2), leaf: leaf1)
        var space = session[SpaceId.require(2)]!
        space.focusedWindow = nil
        space.lastTiledLeaf = nil
        session.spaces[SpaceId.require(2)] = space
        #expect(session[SpaceId.require(2)]!.focusRestorationCandidate() == 11)
        var floating = session[SpaceId.require(1)]!
        floating.floating.append(WindowRef(cgWindowId: 33, pid: 3, role: .floating))
        session.spaces[SpaceId.require(1)] = floating
        #expect(session[SpaceId.require(1)]!.focusRestorationCandidate() == 33)
    }

    @Test func moveAndFollowUpdatesFocusedSpace() {
        var session = Session.empty(spaceCount: 5)
        session = session.insertSpiral(
            space: SpaceId.require(1),
            newLeaf: WindowRef(cgWindowId: 1, pid: 1),
            usableIsWide: true
        )
        session = session.moveNodeToWorkspace(SpaceId.require(3), usableIsWide: true)
        #expect(session.focusedSpace.raw == 3)
        #expect(session[SpaceId.require(3)]?.leaf(containing: 1) != nil)
        #expect(session[SpaceId.require(1)]?.root == nil)
    }

    @Test func luminaFSDropOnMove() {
        var session = Session.empty(spaceCount: 5)
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
        let leaf1 = session[SpaceId.require(1)]!.leaf(containing: 1)!.id
        var space = session[SpaceId.require(1)]!
        space.focusedWindow = 1
        session.spaces[SpaceId.require(1)] = space
        session = session.enterLuminaFS(space: SpaceId.require(1), leaf: leaf1)
        #expect(session[SpaceId.require(1)]!.luminaFullscreen != nil)
        session = session.moveNodeToWorkspace(SpaceId.require(2), usableIsWide: true)
        #expect(session.focusedSpace.raw == 2)
        #expect(session[SpaceId.require(1)]!.luminaFullscreen == nil)
        #expect(session[SpaceId.require(2)]?.leaf(containing: 1) != nil)
    }

    @Test func switchStashesAndUnstashesTiledAndFloating() {
        var session = Session.empty(spaceCount: 2)
        session = session.insertSpiral(
            space: SpaceId.require(1),
            newLeaf: WindowRef(cgWindowId: 1, pid: 1),
            usableIsWide: true
        )
        var space = session[SpaceId.require(1)]!
        space.floating.append(WindowRef(cgWindowId: 2, pid: 2, role: .floating))
        session.spaces[SpaceId.require(1)] = space
        session = session.switchTo(SpaceId.require(2))
        #expect(session[SpaceId.require(1)]!.leaf(containing: 1)?.leaf?.role == .stashed)
        #expect(session[SpaceId.require(1)]!.floating.first?.role == .stashed)
        session = session.switchTo(SpaceId.require(1))
        #expect(session[SpaceId.require(1)]!.leaf(containing: 1)?.leaf?.role == .tiled)
        #expect(session[SpaceId.require(1)]!.floating.first?.role == .floating)
    }

    @Test func markVisibleRevertsOnlyFailedStashIds() {
        var session = Session.empty(spaceCount: 2)
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
        space.floating.append(WindowRef(cgWindowId: 3, pid: 3, role: .floating))
        session.spaces[SpaceId.require(1)] = space
        session = session.switchTo(SpaceId.require(2))
        session = session.markVisible(space: SpaceId.require(1), ids: [1, 3])
        #expect(session[SpaceId.require(1)]!.leaf(containing: 1)?.leaf?.role == .tiled)
        #expect(session[SpaceId.require(1)]!.leaf(containing: 2)?.leaf?.role == .stashed)
        #expect(session[SpaceId.require(1)]!.floating.first?.role == .floating)
    }

    @Test func markVisibleDoesNotDemoteLuminaFS() {
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
        let leaf1 = session[SpaceId.require(1)]!.leaf(containing: 1)!.id
        session = session.enterLuminaFS(space: SpaceId.require(1), leaf: leaf1)
        session = session.markVisible(space: SpaceId.require(1), ids: [1])
        #expect(session[SpaceId.require(1)]!.leaf(containing: 1)?.leaf?.role == .luminaFS)
        session = session.markVisible(space: SpaceId.require(1), ids: [2])
        #expect(session[SpaceId.require(1)]!.leaf(containing: 2)?.leaf?.role == .tiled)
    }
}

struct FullscreenTests {
    @Test func isFillExactAndSlopAndNotHalf() {
        let usable = Rect(x: 8, y: 8, w: 800, h: 600)
        #expect(isFill(frame: usable, usable: usable))
        #expect(isFill(frame: Rect(x: 10, y: 10, w: 796, h: 596), usable: usable))
        let half = Rect(x: 8, y: 8, w: 400, h: 600)
        #expect(!isFill(frame: half, usable: usable))
        #expect(classifyInPlaceResize(frame: usable, usable: usable) == .fill)
        #expect(classifyInPlaceResize(frame: half, usable: usable) == .halfQuarter)
        let odd = Rect(x: 8, y: 8, w: 350, h: 500)
        #expect(classifyInPlaceResize(frame: odd, usable: usable) == .fight)
    }

    @Test func fillWinsOverHalf() {
        let usable = Rect(x: 0, y: 0, w: 800, h: 400)
        #expect(classifyInPlaceResize(frame: usable, usable: usable) == .fill)
    }

    @Test func enterExitLuminaFSStashesSiblingsInTree() {
        var session = Session.empty(spaceCount: 1)
        session = session.insertSpiral(space: SpaceId.require(1), newLeaf: WindowRef(cgWindowId: 1, pid: 1), usableIsWide: true)
        session = session.insertSpiral(space: SpaceId.require(1), newLeaf: WindowRef(cgWindowId: 2, pid: 2), usableIsWide: true)
        let leaf1 = session[SpaceId.require(1)]!.leaf(containing: 1)!.id
        session = session.enterLuminaFS(space: SpaceId.require(1), leaf: leaf1)
        let space = session[SpaceId.require(1)]!
        #expect(space.luminaFullscreen == leaf1)
        #expect(space.nodes[leaf1]?.leaf?.role == .luminaFS)
        let sibling = space.leaf(containing: 2)!
        #expect(sibling.leaf?.role == .stashed)
        #expect(space.root != nil)
        session = session.exitLuminaFS(space: SpaceId.require(1))
        #expect(session[SpaceId.require(1)]!.luminaFullscreen == nil)
        #expect(session[SpaceId.require(1)]!.leaf(containing: 2)?.leaf?.role == .tiled)
    }

    @Test func newTiledDuringLuminaFSIsSliveredInTree() {
        var session = Session.empty(spaceCount: 1)
        session = session.insertSpiral(space: SpaceId.require(1), newLeaf: WindowRef(cgWindowId: 1, pid: 1), usableIsWide: true)
        let leaf1 = session[SpaceId.require(1)]!.root!
        session = session.enterLuminaFS(space: SpaceId.require(1), leaf: leaf1)
        session = session.insertWhileLuminaFS(
            space: SpaceId.require(1),
            window: WindowRef(cgWindowId: 2, pid: 2),
            result: .tiled,
            usableIsWide: true
        )
        let space = session[SpaceId.require(1)]!
        #expect(space.leaf(containing: 2) != nil)
        #expect(space.leaf(containing: 2)?.leaf?.role == .stashed)
        #expect(space.focusedWindow == 1)
        #expect(space.lastTiledLeaf == leaf1)
        session = session.insertWhileLuminaFS(
            space: SpaceId.require(1),
            window: WindowRef(cgWindowId: 3, pid: 3),
            result: .floating,
            usableIsWide: true
        )
        #expect(session[SpaceId.require(1)]!.floating.contains(where: { $0.cgWindowId == 3 }))
        #expect(session[SpaceId.require(1)]!.floating.first(where: { $0.cgWindowId == 3 })?.role == .floating)
    }

    @Test func closeLuminaFSLeafClearsFlag() {
        var session = Session.empty(spaceCount: 1)
        session = session.insertSpiral(space: SpaceId.require(1), newLeaf: WindowRef(cgWindowId: 1, pid: 1), usableIsWide: true)
        session = session.insertSpiral(space: SpaceId.require(1), newLeaf: WindowRef(cgWindowId: 2, pid: 2), usableIsWide: true)
        var space = session[SpaceId.require(1)]!
        space.focusedWindow = 1
        session.spaces[SpaceId.require(1)] = space
        let leaf1 = session[SpaceId.require(1)]!.leaf(containing: 1)!.id
        session = session.enterLuminaFS(space: SpaceId.require(1), leaf: leaf1)
        session = session.closeFocused(space: SpaceId.require(1))
        #expect(session[SpaceId.require(1)]!.luminaFullscreen == nil)
        #expect(session[SpaceId.require(1)]!.leaf(containing: 1) == nil)
        #expect(session[SpaceId.require(1)]!.leaf(containing: 2) != nil)
    }
}

struct NativeFSTests {
    @Test func detectorPredicates() {
        #expect(!isNativeFullscreen(NativeFSSignals(missingFromOnScreen: true, pidAlive: false, spaceChangeRecently: true)))
        #expect(!isNativeFullscreen(NativeFSSignals(missingFromOnScreen: true, pidAlive: true)))
        #expect(isNativeFullscreen(NativeFSSignals(missingFromOnScreen: true, pidAlive: true, spaceChangeRecently: true)))
        #expect(!isNativeFullscreen(NativeFSSignals(missingFromOnScreen: false, pidAlive: true, axFullscreen: true)))
        #expect(isNativeFullscreen(NativeFSSignals(missingFromOnScreen: true, pidAlive: true, axFullscreen: true)))
    }

    @Test func reinsertWrapsSurvivingSibling() {
        var session = Session.empty(spaceCount: 1)
        session = session.insertSpiral(space: SpaceId.require(1), newLeaf: WindowRef(cgWindowId: 1, pid: 1), usableIsWide: true)
        session = session.insertSpiral(space: SpaceId.require(1), newLeaf: WindowRef(cgWindowId: 2, pid: 2), usableIsWide: true)
        let space = session[SpaceId.require(1)]!
        let leaf1 = space.leaf(containing: 1)!
        let ratio = space.nodes[leaf1.parent!]!.ratio
        session = session.detachNativeFS(space: SpaceId.require(1), nodeId: leaf1.id)
        #expect(session[SpaceId.require(1)]!.leaf(containing: 1) == nil)
        #expect(session[SpaceId.require(1)]!.nodes[session[SpaceId.require(1)]!.root!]?.leaf?.cgWindowId == 2)
        let parked = session.nativeFSWindows[0]
        #expect(parked.nativeFSBookmark?.siblingId != nil)
        session = session.reinsertNativeFS(parked, usableIsWide: true)
        let restored = session[SpaceId.require(1)]!
        #expect(restored.leaf(containing: 1) != nil)
        #expect(restored.leaf(containing: 2) != nil)
        #expect(restored.nodes[restored.root!]!.ratio == ratio)
        #expect(session.nativeFSWindows.isEmpty)
        let index = restored.nodes[restored.root!]!.children.firstIndex(of: restored.leaf(containing: 1)!.id)
        #expect(index == 0)
    }
}

struct CurrentSpaceTests {
    @Test func spaceChangeNoLargeWindowNotCurrent() {
        #expect(
            !recomputeCurrent(
                reason: .spaceChange,
                skyLightCurrent: nil,
                skyLightSelf: nil,
                skyLightOthers: [],
                hasLargeOnScreen: false,
                isLastCurrent: true,
                otherClaims: false
            )
        )
    }

    @Test func startMarksCurrent() {
        #expect(
            recomputeCurrent(
                reason: .start,
                skyLightCurrent: nil,
                skyLightSelf: nil,
                skyLightOthers: [],
                hasLargeOnScreen: false,
                isLastCurrent: false,
                otherClaims: false
            )
        )
    }

    @Test func stashLastCurrentStaysCurrent() {
        #expect(
            recomputeCurrent(
                reason: .stash,
                skyLightCurrent: nil,
                skyLightSelf: nil,
                skyLightOthers: [],
                hasLargeOnScreen: false,
                isLastCurrent: true,
                otherClaims: false
            )
        )
    }

    @Test func sliverAttachNotSpawn() {
        #expect(shouldAttach(hasAnyOnScreenIncludingSlivers: true))
        #expect(!shouldAttach(hasAnyOnScreenIncludingSlivers: false))
        #expect(!isLargeOnScreen(width: 1, height: 600))
        #expect(isLargeOnScreen(width: 8, height: 8))
        let a = UUID(uuidString: "00000000-0000-0000-0000-00000000000a")!
        let b = UUID(uuidString: "00000000-0000-0000-0000-00000000000b")!
        #expect(startAttachDecision(agents: [], lastCurrent: nil) == .spawn)
        #expect(
            startAttachDecision(
                agents: [AgentPresence(instanceId: a, isCurrent: true, hasOnScreenIncludingSlivers: false)],
                lastCurrent: a
            ) == .alreadyCurrent(a)
        )
        #expect(
            startAttachDecision(
                agents: [AgentPresence(instanceId: a, isCurrent: false, hasOnScreenIncludingSlivers: true)],
                lastCurrent: nil
            ) == .attach(a)
        )
        #expect(
            startAttachDecision(
                agents: [
                    AgentPresence(instanceId: a, isCurrent: false, hasOnScreenIncludingSlivers: true),
                    AgentPresence(instanceId: b, isCurrent: false, hasOnScreenIncludingSlivers: true),
                ],
                lastCurrent: b
            ) == .attach(b)
        )
        #expect(
            startAttachDecision(
                agents: [
                    AgentPresence(instanceId: a, isCurrent: false, hasOnScreenIncludingSlivers: false),
                    AgentPresence(instanceId: b, isCurrent: false, hasOnScreenIncludingSlivers: false),
                ],
                lastCurrent: a
            ) == .spawn
        )
        #expect(pickCurrentAgent(claimants: [a, b], lastCurrent: b) == b)
        #expect(pickCurrentAgent(claimants: [a], lastCurrent: b) == a)
    }

    @Test func lastCurrentWinsTwoClaimants() {
        #expect(
            !recomputeCurrent(
                reason: .other,
                skyLightCurrent: nil,
                skyLightSelf: nil,
                skyLightOthers: [],
                hasLargeOnScreen: true,
                isLastCurrent: false,
                otherClaims: true
            )
        )
        #expect(
            recomputeCurrent(
                reason: .other,
                skyLightCurrent: nil,
                skyLightSelf: nil,
                skyLightOthers: [],
                hasLargeOnScreen: true,
                isLastCurrent: true,
                otherClaims: true
            )
        )
    }

    @Test func skyLightSelfWins() {
        #expect(
            recomputeCurrent(
                reason: .spaceChange,
                skyLightCurrent: 12,
                skyLightSelf: 12,
                skyLightOthers: [],
                hasLargeOnScreen: false,
                isLastCurrent: false,
                otherClaims: false
            )
        )
        #expect(
            !recomputeCurrent(
                reason: .spaceChange,
                skyLightCurrent: 12,
                skyLightSelf: 99,
                skyLightOthers: [12],
                hasLargeOnScreen: true,
                isLastCurrent: true,
                otherClaims: false
            )
        )
    }

    @Test func hotkeyRegisterPredicate() {
        #expect(shouldRegisterHotkeys(isCurrent: true, paused: false))
        #expect(!shouldRegisterHotkeys(isCurrent: false, paused: false))
        #expect(!shouldRegisterHotkeys(isCurrent: true, paused: true))
    }

    @Test func coordinateConversion() {
        let ns = Rect(x: 10, y: 20, w: 100, h: 50)
        let ax = axRect(fromAppKit: ns, menuBarScreenMaxY: 900)
        #expect(ax == Rect(x: 10, y: 830, w: 100, h: 50))
        #expect(appKitRect(fromAX: ax, menuBarScreenMaxY: 900) == ns)
    }
}

struct InputPolicyTests {
    @Test func titleBarSwapPredicates() {
        let ok = TitleBarSwapProbe(pasteboardChanged: false, displacement: 25, pointerOverTile: true)
        #expect(shouldTitleBarSwap(ok))
        #expect(!shouldTitleBarSwap(TitleBarSwapProbe(pasteboardChanged: true, displacement: 25, pointerOverTile: true)))
        #expect(!shouldTitleBarSwap(TitleBarSwapProbe(pasteboardChanged: false, displacement: 10, pointerOverTile: true)))
        #expect(!shouldTitleBarSwap(TitleBarSwapProbe(pasteboardChanged: false, displacement: 25, pointerOverTile: false)))
        #expect(shouldIgnoreFFM(mouseButtonsDown: true, generationInFlight: false))
        #expect(!shouldIgnoreFFM(mouseButtonsDown: false, generationInFlight: false))
        #expect(shouldIgnoreAXGeometry(windowGeneration: 3, inFlight: 3))
        #expect(!shouldIgnoreAXGeometry(windowGeneration: 3, inFlight: 2))
        #expect(onMiniaturize(MiniaturizeEvent(tagged: true)) == .ignore)
        #expect(onMiniaturize(MiniaturizeEvent(tagged: false)) == .deminiaturize)
    }

    @Test func activationFollowsOnlyOnANonEmptyWorkspace() {
        #expect(shouldFollowAppActivation(spaceHasWindows: true, elapsedSinceSpaceChange: 2))
        #expect(!shouldFollowAppActivation(spaceHasWindows: false, elapsedSinceSpaceChange: 2))
        #expect(!shouldFollowAppActivation(spaceHasWindows: true, elapsedSinceSpaceChange: 0.2))
    }

    @Test func coalesceThreeSchedulesDrainOnce() {
        var c = LayoutCoalesce()
        c.schedule()
        c.schedule()
        c.schedule()
        let first = c.drain()
        #expect(first)
        let second = c.drain()
        #expect(!second)
        #expect(shouldSkipRemainingWindows(elapsed: 0.21))
        #expect(!shouldSkipRemainingWindows(elapsed: 0.05))
    }

    @Test func displayUUIDResumeVsStayPaused() {
        #expect(shouldAutoResume(userPaused: false, boundUUID: "a", availableUUIDs: ["a"]))
        #expect(!shouldAutoResume(userPaused: true, boundUUID: "a", availableUUIDs: ["a"]))
        #expect(shouldStayPausedForDisplay(boundUUID: "a", availableUUIDs: ["b"]))
        #expect(!shouldStayPausedForDisplay(boundUUID: "a", availableUUIDs: ["a"]))
    }
}

struct RegistryTests {
    @Test func jsonRoundTripAndBootMismatch() throws {
        let id = UUID(uuidString: "00000000-0000-0000-0000-000000000002")!
        let registry = InstanceRegistry(
            bootSessionUUID: "old",
            lastCurrentInstanceId: id,
            agents: [
                InstanceRecord(instanceId: id, pid: 99, displayUUID: "disp", socket: "/tmp/a.sock"),
            ]
        )
        let data = try InstanceRegistry.encode(registry)
        let decoded = try InstanceRegistry.decode(data)
        #expect(decoded.agents.count == 1)
        #expect(decoded.agents[0].pid == 99)
        #expect(extraLaunchDecision(registryBootUUID: "old", kernBootUUID: "new", livePids: [99]) == .freshStart)
        #expect(extraLaunchDecision(registryBootUUID: "same", kernBootUUID: "same", livePids: []) == .freshStart)
        #expect(extraLaunchDecision(registryBootUUID: "same", kernBootUUID: "same", livePids: [99]) == .reattach)
        #expect(pidDeathAction(followedQuit: true) == .removeNoRestart)
        #expect(pidDeathAction(followedQuit: false) == .restartCrashRecover)
        #expect(decoded.lastCurrentInstanceId == id)
        let other = UUID(uuidString: "00000000-0000-0000-0000-000000000003")!
        let two = InstanceRegistry(
            bootSessionUUID: "same",
            lastCurrentInstanceId: id,
            agents: [
                InstanceRecord(instanceId: other, pid: 1, displayUUID: "a", socket: "/tmp/dead.sock"),
                InstanceRecord(instanceId: id, pid: 2, displayUUID: "b", socket: "/tmp/live.sock"),
            ]
        )
        #expect(preferredAgentSocket(registry: two, pidAlive: { $0 == 2 }) == "/tmp/live.sock")
        #expect(preferredAgentSocket(registry: two, pidAlive: { $0 == 1 }) == "/tmp/dead.sock")
        #expect(preferredAgentSocket(registry: two, pidAlive: { _ in false }) == nil)
    }

    @Test func skipAlreadyRunningAndWarnings() {
        #expect(skipAlreadyRunning(bundleId: "com.apple.Terminal", running: ["com.apple.Terminal"]))
        #expect(!skipAlreadyRunning(bundleId: "com.apple.Terminal", running: []))
        #expect(extraWarning(status: AgentStatus(secureInput: true, axTrusted: true)).tooltip == "hotkeys blocked: Secure Input")
        #expect(extraWarning(status: AgentStatus(axTrusted: false)) == .axDenied)
        #expect(extraWarning(status: AgentStatus(axTrusted: true, displayGone: true)) == .displayGone)
        #expect(extraWarning(status: AgentStatus(axTrusted: true, configError: "bad")) == .configInvalid)
        #expect(extraWarning(status: AgentStatus(axTrusted: true, hotkeyError: "alt-h")) == .hotkeyFailed)
    }
}
