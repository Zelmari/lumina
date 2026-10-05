import Foundation

/// True when a frame looks like a rect the engine itself produces for this
/// usable area: a full or 1/2, 1/3, 1/4 span on each axis, gap-aware.
///
/// Used to avoid recording a tile (or a full-screen lumina tile) as a
/// window's pre-tiling original. A user window that happens to be exactly
/// half the screen is rare; the cost of a false positive is only that quit
/// recenters that window instead of restoring the frame.
public func looksLikeEngineFrame(
    _ rect: Rect,
    usable: Rect,
    gaps: Gaps,
    slop: Double = 3
) -> Bool {
    guard usable.w > 0, usable.h > 0, rect.w > 0, rect.h > 0 else { return false }
    // Engine tiles live inside the usable rect (parked/sliver frames are
    // handled by the stashed checks).
    if rect.minX < usable.minX - slop || rect.maxX > usable.maxX + slop { return false }
    if rect.minY < usable.minY - slop || rect.maxY > usable.maxY + slop { return false }
    let inner = Double(gaps.inner)
    func span(_ total: Double, _ count: Int) -> Double {
        max(0, (total - inner * Double(count - 1)) / Double(count))
    }
    let widthMatch = (1...4).contains { abs(rect.w - span(usable.w, $0)) <= slop }
    let heightMatch = (1...4).contains { abs(rect.h - span(usable.h, $0)) <= slop }
    return widthMatch && heightMatch
}
