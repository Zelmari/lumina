import Foundation
import Testing
@testable import LuminaLayout

struct ReconcileTests {
    private func live(_ id: UInt32, pid: Int32 = 100, onScreen: Bool = true) -> LiveWindow {
        LiveWindow(
            cgWindowId: id,
            pid: pid,
            bundleId: "com.example.app",
            frame: Rect(x: 0, y: 0, w: 800, h: 600),
            onScreen: onScreen
        )
    }

    @Test func emptyModelAddsEverything() {
        let delta = reconcile(model: [], modelPids: [:], live: [live(1), live(2, pid: 200)])
        #expect(delta.added == [1, 2])
        #expect(delta.removed.isEmpty)
        #expect(delta.rebinds.isEmpty)
    }

    @Test func missingIdsAreRemoved() {
        let delta = reconcile(model: [1, 2, 3], modelPids: [1: 10, 2: 10, 3: 20], live: [live(2)])
        #expect(delta.removed == [1, 3])
        #expect(delta.added.isEmpty)
        #expect(delta.rebinds.isEmpty)
    }

    @Test func offScreenButLiveIsNotRemoved() {
        let delta = reconcile(
            model: [7],
            modelPids: [7: 10],
            live: [live(7, pid: 10, onScreen: false)]
        )
        #expect(delta.isEmpty)
    }

    @Test func oneOutOneInForSamePidIsARebind() {
        let delta = reconcile(
            model: [7],
            modelPids: [7: 10],
            live: [live(8, pid: 10)]
        )
        #expect(delta.rebinds == [RebindPair(from: 7, to: 8)])
        #expect(delta.added.isEmpty)
        #expect(delta.removed.isEmpty)
    }

    @Test func matureRemovedIdIsNotReboundToAnUnrelatedOpen() {
        // The removed window lived for a while; a close plus an unrelated open
        // must be a remove + add, not a slot inheritance.
        let delta = reconcile(
            model: [7],
            modelPids: [7: 10],
            live: [live(8, pid: 10)],
            rebindableIds: []
        )
        #expect(delta.rebinds.isEmpty)
        #expect(delta.removed == [7])
        #expect(delta.added == [8])
    }

    @Test func youngRemovedIdStillRebinds() {
        let delta = reconcile(
            model: [7],
            modelPids: [7: 10],
            live: [live(8, pid: 10)],
            rebindableIds: [7]
        )
        #expect(delta.rebinds == [RebindPair(from: 7, to: 8)])
    }

    @Test func twoRemovedOneAddedIsNotARebind() {
        let delta = reconcile(
            model: [7, 9],
            modelPids: [7: 10, 9: 10],
            live: [live(8, pid: 10)]
        )
        #expect(delta.rebinds.isEmpty)
        #expect(delta.removed == [7, 9])
        #expect(delta.added == [8])
    }

    @Test func differentPidsDoNotRebind() {
        let delta = reconcile(
            model: [7],
            modelPids: [7: 10],
            live: [live(8, pid: 20)]
        )
        #expect(delta.rebinds.isEmpty)
        #expect(delta.removed == [7])
        #expect(delta.added == [8])
    }

    @Test func sameIdNewPidIsRecycledNotAddedOrRemoved() {
        let delta = reconcile(
            model: [7],
            modelPids: [7: 10],
            live: [live(7, pid: 20)]
        )
        #expect(delta.recycled == [7])
        #expect(delta.added.isEmpty)
        #expect(delta.removed.isEmpty)
        #expect(delta.rebinds.isEmpty)
        #expect(!delta.isEmpty)
    }

    @Test func sameIdSamePidIsNotRecycled() {
        let delta = reconcile(
            model: [7],
            modelPids: [7: 10],
            live: [live(7, pid: 10)]
        )
        #expect(delta.recycled.isEmpty)
        #expect(delta.isEmpty)
    }

    @Test func recycledIdDoesNotPairAsRebind() {
        let delta = reconcile(
            model: [7],
            modelPids: [7: 10],
            live: [live(7, pid: 20), live(8, pid: 10)]
        )
        #expect(delta.recycled == [7])
        #expect(delta.added == [8])
        #expect(delta.removed.isEmpty)
        #expect(delta.rebinds.isEmpty)
    }

    @Test func rebindsPerPidAreIndependentAndSorted() {
        let delta = reconcile(
            model: [7, 30],
            modelPids: [7: 10, 30: 20],
            live: [live(8, pid: 10), live(31, pid: 20)]
        )
        #expect(delta.rebinds == [RebindPair(from: 7, to: 8), RebindPair(from: 30, to: 31)])
        #expect(delta.added.isEmpty)
        #expect(delta.removed.isEmpty)
    }

    @Test func deltaIsDeterministic() {
        let delta = reconcile(
            model: [5, 3, 9],
            modelPids: [5: 10, 3: 10, 9: 10],
            live: [live(1), live(2)]
        )
        #expect(delta.removed == [3, 5, 9])
        #expect(delta.added == [1, 2])
    }

    @Test func massRemovalIsOnlySuspendedWhenLocked() {
        #expect(shouldSuspendMassRemoval(modelCount: 6, removedCount: 4, screenLocked: true))
        #expect(!shouldSuspendMassRemoval(modelCount: 6, removedCount: 2, screenLocked: true))
        #expect(!shouldSuspendMassRemoval(modelCount: 6, removedCount: 4, screenLocked: false))
        #expect(!shouldSuspendMassRemoval(modelCount: 2, removedCount: 2, screenLocked: true))
        #expect(!shouldSuspendMassRemoval(modelCount: 6, removedCount: 0, screenLocked: true))
    }

    @Test func removalGoneFromCGIsImmediate() {
        var gate = RemovalGate()
        let result = gate.classify(
            removed: [7], cgLive: [], pidOf: [7: 10], axFailedPids: [], floatingIds: [7]
        )
        #expect(result.real == [7])
        #expect(result.deferred.isEmpty)
    }

    @Test func tiledRemovalDeferredUnboundedWhileCGLive() {
        var gate = RemovalGate()
        for _ in 0..<10 {
            let result = gate.classify(
                removed: [7], cgLive: [7], pidOf: [7: 10], axFailedPids: [], floatingIds: []
            )
            #expect(result.real.isEmpty)
            #expect(result.deferred == [7])
        }
    }

    @Test func removalDeferredWhileAxReadFails() {
        var gate = RemovalGate()
        for _ in 0..<10 {
            let result = gate.classify(
                removed: [7], cgLive: [7], pidOf: [7: 10], axFailedPids: [10], floatingIds: [7]
            )
            #expect(result.real.isEmpty)
            #expect(result.deferred == [7])
        }
    }

    @Test func floatingRemovalAfterGraceMisses() {
        var gate = RemovalGate()
        var result = gate.classify(
            removed: [7], cgLive: [7], pidOf: [7: 10], axFailedPids: [], floatingIds: [7]
        )
        #expect(result.real.isEmpty)
        #expect(result.deferred == [7])
        result = gate.classify(
            removed: [7], cgLive: [7], pidOf: [7: 10], axFailedPids: [], floatingIds: [7]
        )
        #expect(result.real.isEmpty)
        #expect(result.deferred == [7])
        result = gate.classify(
            removed: [7], cgLive: [7], pidOf: [7: 10], axFailedPids: [], floatingIds: [7]
        )
        #expect(result.real == [7])
        #expect(result.deferred.isEmpty)
    }

    @Test func seenWindowResetsMisses() {
        var gate = RemovalGate()
        _ = gate.classify(removed: [7], cgLive: [7], pidOf: [7: 10], axFailedPids: [], floatingIds: [7])
        _ = gate.classify(removed: [], cgLive: [7], pidOf: [7: 10], axFailedPids: [], floatingIds: [7])
        var result = gate.classify(
            removed: [7], cgLive: [7], pidOf: [7: 10], axFailedPids: [], floatingIds: [7]
        )
        #expect(result.deferred == [7])
        _ = gate.classify(removed: [7], cgLive: [7], pidOf: [7: 10], axFailedPids: [], floatingIds: [7])
        result = gate.classify(
            removed: [7], cgLive: [7], pidOf: [7: 10], axFailedPids: [], floatingIds: [7]
        )
        #expect(result.real == [7])
    }

    @Test func successfulMissesAfterFailedReadsStartFresh() {
        var gate = RemovalGate()
        for _ in 0..<5 {
            _ = gate.classify(
                removed: [7], cgLive: [7], pidOf: [7: 10], axFailedPids: [10], floatingIds: [7]
            )
        }
        var result = gate.classify(
            removed: [7], cgLive: [7], pidOf: [7: 10], axFailedPids: [], floatingIds: [7]
        )
        #expect(result.deferred == [7])
        _ = gate.classify(removed: [7], cgLive: [7], pidOf: [7: 10], axFailedPids: [], floatingIds: [7])
        result = gate.classify(
            removed: [7], cgLive: [7], pidOf: [7: 10], axFailedPids: [], floatingIds: [7]
        )
        #expect(result.real == [7])
    }
}
