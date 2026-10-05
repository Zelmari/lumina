import Testing
@testable import LuminaLayout

struct LatencyStatsTests {
    @Test func emptyHasNoStats() {
        let stats = LatencyStats(capacity: 8)
        #expect(stats.count == 0)
        #expect(stats.totalRecorded == 0)
        #expect(stats.last == nil)
        #expect(stats.min == nil)
        #expect(stats.max == nil)
        #expect(stats.mean == nil)
        #expect(stats.percentile(0.5) == nil)
    }

    @Test func singleSample() {
        var stats = LatencyStats(capacity: 8)
        stats.record(milliseconds: 4.5)
        #expect(stats.count == 1)
        #expect(stats.totalRecorded == 1)
        #expect(stats.last == 4.5)
        #expect(stats.min == 4.5)
        #expect(stats.max == 4.5)
        #expect(stats.mean == 4.5)
        #expect(stats.p50 == 4.5)
        #expect(stats.p95 == 4.5)
    }

    @Test func nearestRankPercentiles() {
        var stats = LatencyStats(capacity: 100)
        for value in 1...100 {
            stats.record(milliseconds: Double(value))
        }
        #expect(stats.count == 100)
        #expect(stats.last == 100)
        #expect(stats.min == 1)
        #expect(stats.max == 100)
        #expect(stats.mean == 50.5)
        #expect(stats.p50 == 50)
        #expect(stats.p95 == 95)
        #expect(stats.percentile(0.99) == 99)
    }

    @Test func ringKeepsMostRecentSamples() {
        var stats = LatencyStats(capacity: 4)
        for value in 1...10 {
            stats.record(milliseconds: Double(value))
        }
        #expect(stats.count == 4)
        #expect(stats.totalRecorded == 10)
        #expect(stats.last == 10)
        #expect(stats.min == 7)
        #expect(stats.max == 10)
        #expect(stats.p50 == 8)
    }

    @Test func ignoresNonFiniteSamples() {
        var stats = LatencyStats(capacity: 4)
        stats.record(milliseconds: .nan)
        stats.record(milliseconds: .infinity)
        stats.record(milliseconds: 2)
        #expect(stats.count == 1)
        #expect(stats.totalRecorded == 1)
        #expect(stats.last == 2)
    }

    @Test func percentileClampsOutOfRange() {
        var stats = LatencyStats(capacity: 4)
        stats.record(milliseconds: 1)
        stats.record(milliseconds: 2)
        #expect(stats.percentile(-1) == 1)
        #expect(stats.percentile(2) == 2)
    }
}
