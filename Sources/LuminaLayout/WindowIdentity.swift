import Foundation

/// Chebyshev distance between an AX frame and a CG window bounds rect.
public func cgWindowMatchScore(ax: Rect, cg: Rect) -> Double {
    max(
        abs(ax.x - cg.x),
        abs(ax.y - cg.y),
        abs(ax.w - cg.w),
        abs(ax.h - cg.h)
    )
}

/// Pick a unique CGWindowID by frame. Returns nil when no candidate is close enough
/// or the top two scores are too close to tell apart.
public func pickCGWindowId(
    axFrame: Rect,
    candidates: [(id: UInt32, frame: Rect)],
    excluding: Set<UInt32> = [],
    maxScore: Double = 80,
    ambiguity: Double = 16
) -> UInt32? {
    let scored = candidates
        .filter { !excluding.contains($0.id) && $0.frame.w >= 8 && $0.frame.h >= 8 }
        .map { (id: $0.id, score: cgWindowMatchScore(ax: axFrame, cg: $0.frame)) }
        .sorted { lhs, rhs in
            if lhs.score != rhs.score { return lhs.score < rhs.score }
            return lhs.id < rhs.id
        }
    guard let best = scored.first, best.score < maxScore else { return nil }
    if let second = scored.dropFirst().first, second.score - best.score < ambiguity {
        return nil
    }
    return best.id
}

/// True when `frame` matches an on-screen CG window of the same process.
public func axFrameLooksOnScreen(frame: Rect, onScreenFrames: [Rect]) -> Bool {
    guard frame.w >= 8, frame.h >= 8 else { return false }
    return onScreenFrames.contains { cgWindowMatchScore(ax: frame, cg: $0) < 80 }
}
