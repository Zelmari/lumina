import Foundation

public enum StatusSegmentState: String, Equatable, Sendable {
    case active
    case idle
    case paused
    case warning
    case inactive
}

public struct StatusSegment: Equatable, Sendable {
    public var label: String
    public var state: StatusSegmentState
    public var enabled: Bool
    public var symbol: String?
    public var space: Int?

    public init(
        label: String,
        state: StatusSegmentState,
        enabled: Bool = true,
        symbol: String? = nil,
        space: Int? = nil
    ) {
        self.label = label
        self.state = state
        self.enabled = enabled
        self.symbol = symbol
        self.space = space
    }
}

public struct StatusStripModel: Equatable, Sendable {
    public var segments: [StatusSegment]
    public var compact: Bool

    public init(segments: [StatusSegment], compact: Bool) {
        self.segments = segments
        self.compact = compact
    }
}

public func statusStrip(
    spaceCount: Int,
    focused: Int,
    paused: Bool,
    warning: Bool,
    current: Bool
) -> StatusStripModel {
    guard current else {
        return StatusStripModel(
            segments: [
                StatusSegment(
                    label: "Start on this Space",
                    state: .inactive,
                    enabled: true,
                    symbol: "play.fill"
                ),
            ],
            compact: false
        )
    }
    let count = max(spaceCount, 1)
    let focus = min(max(focused, 1), count)
    let compact = count > 5
    var segments: [StatusSegment] = []
    if warning {
        segments.append(
            StatusSegment(
                label: "",
                state: .warning,
                enabled: false,
                symbol: "exclamationmark.triangle.fill"
            )
        )
    }
    if paused {
        segments.append(
            StatusSegment(
                label: "",
                state: .paused,
                enabled: false,
                symbol: "pause.fill"
            )
        )
    }
    let lower = compact ? max(1, focus - 2) : 1
    let upper = compact ? min(count, focus + 2) : count
    if compact && lower > 1 {
        segments.append(StatusSegment(label: "…", state: .idle, enabled: false))
    }
    for space in lower...upper {
        let state: StatusSegmentState = paused ? .paused : (space == focus ? .active : .idle)
        segments.append(StatusSegment(label: "\(space)", state: state, enabled: true, space: space))
    }
    if compact && upper < count {
        segments.append(StatusSegment(label: "…", state: .idle, enabled: false))
    }
    return StatusStripModel(segments: segments, compact: compact)
}
