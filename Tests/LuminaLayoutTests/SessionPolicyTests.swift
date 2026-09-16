import Foundation
import Testing
@testable import LuminaLayout

struct StashTests {
    @Test func stashFrameBottomRightVsLeft() {
        let display = DisplayFrame(
            axFrame: Rect(x: 0, y: 0, w: 1440, h: 900),
            axVisibleFrame: Rect(x: 0, y: 0, w: 1440, h: 850)
        )
        let right = stashFrame(for: 600, display: display, dockRight: false, lastWidth: 800)
        #expect(right.w == 800)
        #expect(right.h == 600)
        #expect(right.x == 1440 + stashOffscreenGap)
        #expect(isStashedOffDisplay(right, display: display))
        #expect(!display.axFrame.intersects(right))
        let left = stashFrame(for: 600, display: display, dockRight: true, lastWidth: 500)
        #expect(left.x == 0 - 500 - stashOffscreenGap)
        #expect(left.w == 500)
        #expect(isStashedOffDisplay(left, display: display))
        #expect(!display.axFrame.intersects(left))
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
        #expect(isNativeFullscreen(NativeFSSignals(missingFromOnScreen: false, pidAlive: true, axFullscreen: true)))
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
