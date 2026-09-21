import Foundation

/// Pure function from tree + usable rect + gaps → leaf rects.
/// `usable` is already outer-gapped by the caller (AX coords).
/// Floaters, stashed, ignored, nativeFS are not in the tree and not returned.
/// A luminaFS leaf is still in the tree; its computed tile rect is returned.
public func frames(root: NodeId?, nodes: [NodeId: Node], usable: Rect, gaps: Gaps) -> [NodeId: Rect] {
    nodeFrames(root: root, nodes: nodes, usable: usable, gaps: gaps).filter { id, _ in
        nodes[id]?.isLeaf == true
    }
}

public func frames(space: Space, usable: Rect, gaps: Gaps) -> [NodeId: Rect] {
    frames(root: space.root, nodes: space.nodes, usable: usable, gaps: gaps)
}

/// Rects for every node (containers and leaves). Used by resize/clamp.
func nodeFrames(root: NodeId?, nodes: [NodeId: Node], usable: Rect, gaps: Gaps) -> [NodeId: Rect] {
    guard let root, nodes[root] != nil else { return [:] }
    var out: [NodeId: Rect] = [:]
    framesRecurse(id: root, nodes: nodes, rect: usable, gaps: gaps, into: &out)
    return out
}

private func framesRecurse(
    id: NodeId,
    nodes: [NodeId: Node],
    rect: Rect,
    gaps: Gaps,
    into out: inout [NodeId: Rect]
) {
    guard let node = nodes[id] else { return }
    out[id] = rect
    if node.isLeaf { return }
    let n = node.children.count
    guard n > 0 else { return }
    var weights = node.ratio
    if weights.count != n {
        weights = Array(repeating: 1.0, count: n)
    }
    var sum = weights.reduce(0, +)
    if sum == 0 {
        weights = Array(repeating: 1.0, count: n)
        sum = Double(n)
    }
    let innerTotal = Double(gaps.inner) * Double(max(0, n - 1))
    let horizontal = node.axis == .horizontal
    let available = max(0, (horizontal ? rect.width : rect.height) - innerTotal)
    let spans = wholePointSpans(count: n, available: available, weights: weights, sum: sum)
    if horizontal {
        var run = rect.minX
        for i in 0..<n {
            let childRect = Rect(x: run, y: rect.minY, w: spans[i], h: rect.height)
            framesRecurse(id: node.children[i], nodes: nodes, rect: childRect, gaps: gaps, into: &out)
            run += spans[i] + Double(gaps.inner)
        }
    } else {
        var run = rect.minY
        for i in 0..<n {
            let childRect = Rect(x: rect.minX, y: run, w: rect.width, h: spans[i])
            framesRecurse(id: node.children[i], nodes: nodes, rect: childRect, gaps: gaps, into: &out)
            run += spans[i] + Double(gaps.inner)
        }
    }
}

/// Round every span but the last to the nearest point. The last span absorbs the
/// remainder so the children still fill `available` exactly.
func wholePointSpans(count n: Int, available: Double, weights: [Double], sum: Double) -> [Double] {
    guard n > 0 else { return [] }
    if n == 1 { return [available] }
    var spans = Array(repeating: 0.0, count: n)
    var used = 0.0
    for i in 0..<(n - 1) {
        let raw = available * (weights[i] / sum)
        let span = raw.rounded(.toNearestOrAwayFromZero)
        spans[i] = span
        used += span
    }
    spans[n - 1] = available - used
    return spans
}
