import Testing
@testable import LuminaLayout

struct StatusStripTests {
    @Test func inactiveIsSingleStartSegment() {
        let model = statusStrip(spaceCount: 5, focused: 2, paused: true, warning: true, current: false)
        #expect(!model.compact)
        #expect(model.segments.count == 1)
        #expect(model.segments[0].label == "Start on this Space")
        #expect(model.segments[0].state == .inactive)
        #expect(model.segments[0].enabled)
        #expect(model.segments[0].symbol == "play.fill")
        #expect(model.segments[0].space == nil)
    }

    @Test func activeAndIdleDigits() {
        let model = statusStrip(spaceCount: 5, focused: 3, paused: false, warning: false, current: true)
        #expect(!model.compact)
        #expect(model.segments.map(\.label) == ["1", "2", "3", "4", "5"])
        #expect(model.segments.map(\.state) == [.idle, .idle, .active, .idle, .idle])
        #expect(model.segments.allSatisfy { $0.enabled })
        #expect(model.segments.map(\.space) == [1, 2, 3, 4, 5])
        #expect(model.segments.allSatisfy { $0.symbol == nil })
    }

    @Test func pausedPrefixesAndDimsEveryDigit() {
        let model = statusStrip(spaceCount: 4, focused: 2, paused: true, warning: false, current: true)
        #expect(model.segments.count == 5)
        #expect(model.segments[0].symbol == "pause.fill")
        #expect(model.segments[0].state == .paused)
        #expect(!model.segments[0].enabled)
        #expect(model.segments[0].space == nil)
        #expect(model.segments.dropFirst().allSatisfy { $0.state == .paused })
        #expect(model.segments.dropFirst().map(\.label) == ["1", "2", "3", "4"])
        #expect(model.segments.dropFirst().allSatisfy { $0.enabled })
    }

    @Test func warningPrefixesTriangle() {
        let model = statusStrip(spaceCount: 3, focused: 1, paused: false, warning: true, current: true)
        #expect(model.segments.first?.symbol == "exclamationmark.triangle.fill")
        #expect(model.segments.first?.state == .warning)
        #expect(model.segments.first?.enabled == false)
        #expect(model.segments.first?.space == nil)
        #expect(model.segments.dropFirst().map(\.label) == ["1", "2", "3"])
        #expect(model.segments.dropFirst().map(\.state) == [.active, .idle, .idle])
    }

    @Test func warningAndPausedBothPrefixInOrder() {
        let model = statusStrip(spaceCount: 3, focused: 2, paused: true, warning: true, current: true)
        #expect(model.segments.map(\.state) == [.warning, .paused, .paused, .paused, .paused])
        #expect(model.segments[0].symbol == "exclamationmark.triangle.fill")
        #expect(model.segments[1].symbol == "pause.fill")
        #expect(model.segments[1].label == "")
    }

    @Test func everyRequestedWorkspaceIsADigit() {
        let model = statusStrip(spaceCount: 10, focused: 5, paused: false, warning: false, current: true)
        #expect(!model.compact)
        #expect(model.segments.map(\.label) == ["1", "2", "3", "4", "5", "6", "7", "8", "9", "10"])
        #expect(model.segments[4].state == .active)
        #expect(model.segments[4].space == 5)
        #expect(model.segments.allSatisfy { $0.enabled })
    }

    @Test func fiveSpacesShowsFiveDigits() {
        let model = statusStrip(spaceCount: 5, focused: 1, paused: false, warning: false, current: true)
        #expect(!model.compact)
        #expect(model.segments.count == 5)
    }

    @Test func focusedClampsAtBothEnds() {
        let low = statusStrip(spaceCount: 5, focused: 0, paused: false, warning: false, current: true)
        #expect(low.segments.first(where: { $0.state == .active })?.space == 1)
        let high = statusStrip(spaceCount: 5, focused: 99, paused: false, warning: false, current: true)
        #expect(high.segments.first(where: { $0.state == .active })?.space == 5)
    }

    @Test func visibleCountDefaultsToFive() {
        #expect(visibleWorkspaceCount(configured: 10, focused: 1, used: []) == 5)
        #expect(visibleWorkspaceCount(configured: 10, focused: 3, used: [3]) == 5)
    }

    @Test func visibleCountGrowsWithUse() {
        #expect(visibleWorkspaceCount(configured: 10, focused: 1, used: [7]) == 7)
        #expect(visibleWorkspaceCount(configured: 10, focused: 9, used: []) == 9)
        #expect(visibleWorkspaceCount(configured: 10, focused: 2, used: [6, 4]) == 6)
    }

    @Test func visibleCountNeverExceedsConfigured() {
        #expect(visibleWorkspaceCount(configured: 3, focused: 2, used: [3]) == 3)
        #expect(visibleWorkspaceCount(configured: 3, focused: 3, used: []) == 3)
        #expect(visibleWorkspaceCount(configured: 1, focused: 1, used: []) == 1)
    }

    @Test func zeroSpaceCountStillYieldsOneActiveSegment() {
        let model = statusStrip(spaceCount: 0, focused: 1, paused: false, warning: false, current: true)
        #expect(model.segments.count == 1)
        #expect(model.segments[0].state == .active)
        #expect(model.segments[0].space == 1)
    }
}
