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
    spaces: [Int],
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
    let spaces = spaces.isEmpty ? [1] : spaces
    let focus: Int
    if spaces.contains(focused) {
        focus = focused
    } else if let first = spaces.first, focused < first {
        focus = first
    } else if let last = spaces.last, focused > last {
        focus = last
    } else {
        focus = spaces.min(by: { abs($0 - focused) < abs($1 - focused) }) ?? focused
    }
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
    // Every workspace the caller asked for is a digit. The caller passes the
    // visible spaces (five minimum, growing with use/focus), so collapsing the
    // digits into ellipses would hide exactly the workspaces that are used.
    for space in spaces {
        let state: StatusSegmentState = paused ? .paused : (space == focus ? .active : .idle)
        segments.append(StatusSegment(label: "\(space)", state: state, enabled: true, space: space))
    }
    return StatusStripModel(segments: segments, compact: false)
}

public func statusStrip(
    spaceCount: Int,
    focused: Int,
    paused: Bool,
    warning: Bool,
    current: Bool
) -> StatusStripModel {
    let count = max(spaceCount, 1)
    return statusStrip(
        spaces: Array(1...count),
        focused: focused,
        paused: paused,
        warning: warning,
        current: current
    )
}

/// Workspaces the menu extra should show: at least persistent `1...minimum`
/// (up to configured), plus any used workspaces and the focused workspace,
/// never exceeding configured.
public func visibleWorkspaces(
    configured: Int,
    focused: Int,
    used: [Int],
    minimum: Int = 5
) -> [Int] {
    let configured = max(configured, 1)
    let persistentMax = min(max(minimum, 1), configured)
    var visible = Set(1...persistentMax)
    visible.insert(min(max(focused, 1), configured))
    for u in used where u >= 1 && u <= configured {
        visible.insert(u)
    }
    return visible.sorted()
}

/// Workspaces the menu extra should show: at least `minimum`, one past the
/// highest used index (the focused workspace counts as used), never more
/// than configured. A workspace counts as used when it holds a window.
public func visibleWorkspaceCount(
    configured: Int,
    focused: Int,
    used: [Int],
    minimum: Int = 5
) -> Int {
    let configured = max(configured, 1)
    let highestUsed = max(used.max() ?? 1, max(focused, 1))
    return min(configured, max(max(minimum, 1), highestUsed))
}
