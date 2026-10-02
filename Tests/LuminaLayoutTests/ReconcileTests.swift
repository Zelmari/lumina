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
}
