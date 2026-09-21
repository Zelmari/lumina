import Foundation

public enum ResizeDelta: Equatable, Sendable {
    case grow
    case shrink
}

public struct Size: Equatable, Sendable {
    public var w: Double
    public var h: Double

    public init(w: Double, h: Double) {
        self.w = w
        self.h = h
    }

    /// 0 means unknown — only the 80pt floor applies on user resize.
    public static let unknown = Size(w: 0, h: 0)
}

private let userResizeFloor: Double = 80
private let sliverFloor: Double = 1

extension Session {
    /// Recurse all containers on the space; set each `ratio` to equal `1.0` per child.
    public func balance(space spaceId: SpaceId) -> Session {
        var session = self
        guard var space = session.spaces[spaceId] else { return session }
        if let root = space.root {
            balanceNode(id: root, space: &space)
        }
        session.spaces[spaceId] = space
        return session
    }

    /// Move the parent split of `focusedLeaf` by 5% of that container along the parent axis.
    public func resize(
        space spaceId: SpaceId,
        focusedLeaf: NodeId,
        delta: ResizeDelta,
        minSizes: [UInt32: Size],
        usable: Rect,
        gaps: Gaps
    ) -> (session: Session, floated: WindowRef?) {
        var session = self
        guard var space = session.spaces[spaceId],
              let leaf = space.nodes[focusedLeaf],
              leaf.isLeaf,
              leaf.leaf?.role != .floating,
              let parentId = leaf.parent,
              var parent = space.nodes[parentId],
              parent.children.count == 2,
              let index = parent.children.firstIndex(of: focusedLeaf)
        else {
            return (self, nil)
        }

        let weights = normalizedWeights(parent)
        let sum = weights.reduce(0, +)
        let step = 0.05 * sum
        let siblingIndex = index == 0 ? 1 : 0
        let sign: Double = delta == .grow ? 1 : -1

        // Shrink the applied step until both children meet min+80, or step is 0.
        var applied = step
        var best = weights
        var found = false
        for _ in 0..<32 {
            var proposed = weights
            proposed[index] += sign * applied
            proposed[siblingIndex] -= sign * applied
            if proposed[index] < 0 || proposed[siblingIndex] < 0 {
                applied /= 2
                if applied < 1e-9 { break }
                continue
            }
            parent.ratio = proposed
            var trial = space
            trial.setNode(parent)
            if childrenMeetMins(
                parent: parent,
                space: trial,
                minSizes: minSizes,
                usable: usable,
                gaps: gaps,
                floor: userResizeFloor,
                unknownUsesFloor: true
            ) {
                best = proposed
                found = true
                break
            }
            applied /= 2
            if applied < 1e-9 { break }
        }

        if found {
            parent.ratio = best
            space.setNode(parent)
            session.spaces[spaceId] = space
            return (session, nil)
        }

        // Even delta 0: check current weights.
        parent.ratio = weights
        space.setNode(parent)
        if childrenMeetMins(
            parent: parent,
            space: space,
            minSizes: minSizes,
            usable: usable,
            gaps: gaps,
            floor: userResizeFloor,
            unknownUsesFloor: true
        ) {
            session.spaces[spaceId] = space
            return (session, nil)
        }
        session.spaces[spaceId] = space
        return session.floatLeaf(space: spaceId, nodeId: focusedLeaf)
    }

    /// After insert and after display-frame change.
    public func clampOverflow(
        space spaceId: SpaceId,
        minSizes: [UInt32: Size],
        usable: Rect,
        gaps: Gaps,
        preferFloat: NodeId? = nil
    ) -> (session: Session, floated: [WindowRef]) {
        var session = self
        var floated: [WindowRef] = []
        for _ in 0..<32 {
            guard let space = session.spaces[spaceId] else { break }
            var didFloat = false
            let containers = space.nodes.values.filter { !$0.isLeaf && $0.children.count == 2 }
            for container in containers {
                let b = container.children[1]
                guard let current = session.spaces[spaceId] else { break }
                if let adjusted = clampSibling(
                    parent: container,
                    space: current,
                    minSizes: minSizes,
                    usable: usable,
                    gaps: gaps,
                    floor: sliverFloor,
                    unknownUsesFloor: true
                ) {
                    if adjusted.ratio != container.ratio {
                        var s = current
                        s.setNode(adjusted)
                        session.spaces[spaceId] = s
                        break
                    }
                    continue
                }
                // Both cannot fit. Prefer floating the newly inserted / focused leaf,
                // including when it sits under a nested container.
                let offender = leafToFloat(in: container, space: space, prefer: preferFloat) ?? b
                let (after, win) = session.floatLeaf(space: spaceId, nodeId: offender)
                session = after
                if let win { floated.append(win) }
                didFloat = true
                break
            }
            if !didFloat {
                // Recheck leaves for < 1pt slivers after weight clamp.
                let space = session.spaces[spaceId]!
                let leafRects = frames(space: space, usable: usable, gaps: gaps)
                if let sliver = leafRects.first(where: { _, r in
                    r.w < sliverFloor || r.h < sliverFloor
                }) {
                    let (after, win) = session.floatLeaf(space: spaceId, nodeId: sliver.key)
                    session = after
                    if let win { floated.append(win) }
                    didFloat = true
                }
            }
            if !didFloat { break }
        }
        return (session, floated)
    }

    public func floatLeaf(space spaceId: SpaceId, nodeId: NodeId) -> (Session, WindowRef?) {
        var session = self
        guard let space = session.spaces[spaceId],
              let node = space.nodes[nodeId],
              var window = node.leaf
        else {
            return (session, nil)
        }
        window.role = .floating
        session = session.remove(space: spaceId, node: nodeId)
        guard var space2 = session.spaces[spaceId] else { return (session, window) }
        space2.floating.append(window)
        session.spaces[spaceId] = space2
        return (session, window)
    }
}

private func balanceNode(id: NodeId, space: inout Space) {
    guard var node = space.nodes[id] else { return }
    if !node.children.isEmpty {
        node.ratio = Array(repeating: 1.0, count: node.children.count)
        space.setNode(node)
        for child in node.children {
            balanceNode(id: child, space: &space)
        }
    }
}

func normalizedWeights(_ parent: Node) -> [Double] {
    var weights = parent.ratio
    if weights.count != parent.children.count {
        weights = Array(repeating: 1.0, count: parent.children.count)
    }
    if weights.reduce(0, +) == 0 {
        weights = Array(repeating: 1.0, count: parent.children.count)
    }
    return weights
}

private func axisSpan(_ rect: Rect, axis: Axis) -> Double {
    axis == .horizontal ? rect.w : rect.h
}

/// Minimum span of a leaf or subtree along `axis`.
/// A nested split on the same axis sums its children plus inner gaps.
/// A nested split on the other axis needs the widest child.
private func subtreeMin(
    id: NodeId,
    space: Space,
    axis: Axis,
    minSizes: [UInt32: Size],
    gaps: Gaps,
    floor: Double,
    unknownUsesFloor: Bool
) -> Double {
    guard let node = space.nodes[id] else { return floor }
    if node.isLeaf {
        return minNeeded(leaf: node, axis: axis, minSizes: minSizes, floor: floor, unknownUsesFloor: unknownUsesFloor)
    }
    let childMins = node.children.map {
        subtreeMin(
            id: $0,
            space: space,
            axis: axis,
            minSizes: minSizes,
            gaps: gaps,
            floor: floor,
            unknownUsesFloor: unknownUsesFloor
        )
    }
    if node.axis == axis {
        let gap = Double(gaps.inner) * Double(max(0, node.children.count - 1))
        return childMins.reduce(0, +) + gap
    }
    return childMins.max() ?? floor
}

private func containsNode(_ root: Node, _ target: NodeId, space: Space) -> Bool {
    if root.id == target { return true }
    for child in root.children {
        if let node = space.nodes[child], containsNode(node, target, space: space) { return true }
    }
    return false
}

private func leafToFloat(in container: Node, space: Space, prefer: NodeId?) -> NodeId? {
    if let prefer, containsNode(container, prefer, space: space), space.nodes[prefer]?.isLeaf == true {
        return prefer
    }
    func firstLeaf(_ id: NodeId) -> NodeId? {
        guard let node = space.nodes[id] else { return nil }
        if node.isLeaf { return id }
        for child in node.children {
            if let leaf = firstLeaf(child) { return leaf }
        }
        return nil
    }
    if let last = container.children.last, let leaf = firstLeaf(last) { return leaf }
    return container.children.first.flatMap(firstLeaf)
}

private func minNeeded(leaf: Node, axis: Axis, minSizes: [UInt32: Size], floor: Double, unknownUsesFloor: Bool) -> Double {
    guard let window = leaf.leaf else { return floor }
    let size = minSizes[window.cgWindowId] ?? .unknown
    let axisMin = axis == .horizontal ? size.w : size.h
    if axisMin == 0 {
        return unknownUsesFloor ? floor : 0
    }
    return max(axisMin, floor)
}

private func childrenMeetMins(
    parent: Node,
    space: Space,
    minSizes: [UInt32: Size],
    usable: Rect,
    gaps: Gaps,
    floor: Double,
    unknownUsesFloor: Bool
) -> Bool {
    let rects = nodeFrames(root: space.root, nodes: space.nodes, usable: usable, gaps: gaps)
    for childId in parent.children {
        guard let rect = rects[childId] else { return false }
        let span = axisSpan(rect, axis: parent.axis)
        let needed: Double
        needed = subtreeMin(
            id: childId,
            space: space,
            axis: parent.axis,
            minSizes: minSizes,
            gaps: gaps,
            floor: floor,
            unknownUsesFloor: unknownUsesFloor
        )
        if span + 1e-9 < needed { return false }
    }
    return true
}

/// Clamp sibling first so both meet min. Returns nil if both cannot fit.
private func clampSibling(
    parent: Node,
    space: Space,
    minSizes: [UInt32: Size],
    usable: Rect,
    gaps: Gaps,
    floor: Double,
    unknownUsesFloor: Bool
) -> Node? {
    guard parent.children.count == 2 else { return parent }
    let rects = nodeFrames(root: space.root, nodes: space.nodes, usable: usable, gaps: gaps)
    guard let container = rects[parent.id] else { return parent }
    let available = axisSpan(container, axis: parent.axis) - Double(gaps.inner)
    let a = parent.children[0]
    let b = parent.children[1]
    func needed(_ id: NodeId) -> Double {
        subtreeMin(
            id: id,
            space: space,
            axis: parent.axis,
            minSizes: minSizes,
            gaps: gaps,
            floor: floor,
            unknownUsesFloor: unknownUsesFloor
        )
    }
    let minA = needed(a)
    let minB = needed(b)
    if minA + minB > available + 1e-9 {
        return nil
    }
    let weights = normalizedWeights(parent)
    let sum = weights.reduce(0, +)
    func weight(forSpan s: Double) -> Double {
        guard available > 0 else { return 0 }
        return (s / available) * sum
    }
    var wa = weights[0]
    var wb = weights[1]
    let needA = weight(forSpan: minA)
    let needB = weight(forSpan: minB)
    if wa < needA {
        let deficit = needA - wa
        wa = needA
        wb -= deficit
    }
    if wb < needB {
        let deficit = needB - wb
        wb = needB
        wa -= deficit
    }
    if wa < needA - 1e-9 || wb < needB - 1e-9 {
        return nil
    }
    var parent = parent
    parent.ratio = [wa, wb]
    return parent
}
