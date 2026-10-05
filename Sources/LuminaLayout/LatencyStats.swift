import Foundation

/// Fixed-capacity ring of latency samples in milliseconds. Pure value type so
/// the agent can record hot-path timings on the mutation queue and the CLI,
/// harness, and tests can read percentiles without shared state.
public struct LatencyStats: Equatable, Sendable {
    public let capacity: Int
    private var samples: [Double] = []
    private var nextIndex = 0
    /// Total samples ever recorded, including ones overwritten in the ring.
    public private(set) var totalRecorded = 0
    /// Most recently recorded sample, kept even after the ring wraps.
    public private(set) var last: Double?

    public init(capacity: Int = 128) {
        self.capacity = Swift.max(1, capacity)
    }

    public var count: Int { samples.count }

    public mutating func record(milliseconds: Double) {
        guard milliseconds.isFinite else { return }
        totalRecorded += 1
        last = milliseconds
        if samples.count < capacity {
            samples.append(milliseconds)
        } else {
            samples[nextIndex] = milliseconds
        }
        nextIndex = (nextIndex + 1) % capacity
    }

    public var min: Double? { samples.min() }

    public var max: Double? { samples.max() }

    public var mean: Double? {
        guard !samples.isEmpty else { return nil }
        return samples.reduce(0, +) / Double(samples.count)
    }

    /// Nearest-rank percentile. `p` is clamped to 0...1.
    public func percentile(_ p: Double) -> Double? {
        guard !samples.isEmpty else { return nil }
        let sorted = samples.sorted()
        let clamped = Swift.min(Swift.max(p, 0), 1)
        let rank = Int((clamped * Double(sorted.count)).rounded(.up))
        let index = Swift.min(Swift.max(rank - 1, 0), sorted.count - 1)
        return sorted[index]
    }

    public var p50: Double? { percentile(0.5) }

    public var p95: Double? { percentile(0.95) }
}
