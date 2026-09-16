/// AX / CoreGraphics space: origin is the top-left of the menu-bar display, Y down.
/// Integers from AX still go through `Double`. Never mix AppKit bottom-left coords here.
public struct Rect: Equatable, Hashable, Sendable, Codable {
    public var x: Double
    public var y: Double
    public var w: Double
    public var h: Double

    public init(x: Double, y: Double, w: Double, h: Double) {
        self.x = x
        self.y = y
        self.w = w
        self.h = h
    }

    public var minX: Double { x }
    public var minY: Double { y }
    public var maxX: Double { x + w }
    public var maxY: Double { y + h }
    public var width: Double { w }
    public var height: Double { h }

    public var center: Point {
        Point(x: x + w / 2, y: y + h / 2)
    }

    public var area: Double {
        max(0, w) * max(0, h)
    }

    public func contains(point: Point) -> Bool {
        point.x >= minX && point.x < maxX && point.y >= minY && point.y < maxY
    }

    public func intersection(_ other: Rect) -> Rect {
        let ix = max(minX, other.minX)
        let iy = max(minY, other.minY)
        let ax = min(maxX, other.maxX)
        let ay = min(maxY, other.maxY)
        let iw = ax - ix
        let ih = ay - iy
        if iw <= 0 || ih <= 0 {
            return Rect(x: ix, y: iy, w: 0, h: 0)
        }
        return Rect(x: ix, y: iy, w: iw, h: ih)
    }

    public func intersects(_ other: Rect) -> Bool {
        intersection(other).area > 0
    }

    public func inset(by amount: Double) -> Rect {
        Rect(x: x + amount, y: y + amount, w: max(0, w - 2 * amount), h: max(0, h - 2 * amount))
    }
}

public struct Point: Equatable, Hashable, Sendable, Codable {
    public var x: Double
    public var y: Double

    public init(x: Double, y: Double) {
        self.x = x
        self.y = y
    }

    public func distance(to other: Point) -> Double {
        let dx = x - other.x
        let dy = y - other.y
        return (dx * dx + dy * dy).squareRoot()
    }
}
