#if os(macOS)
import AppKit
import LuminaLayout

final class StatusStripView: NSView, NSViewToolTipOwner {
    private static let font = NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .medium)
    private static let segmentSpacing: CGFloat = 2
    private static let horizontalPadding: CGFloat = 5
    private static let iconGap: CGFloat = 3

    var model = StatusStripModel(segments: [], compact: false) {
        didSet {
            guard model != oldValue else { return }
            hoveredIndex = nil
            cachedSegmentWidths = nil
            invalidateIntrinsicContentSize()
            needsLayout = true
            needsDisplay = true
            recomputeGeometry()
        }
    }
    var onSegment: ((StatusSegment) -> Void)?
    var onRightClick: (() -> Void)?
    var warningTooltip: String?
    var inactiveTooltip: String?

    private var hoveredIndex: Int?
    private var segmentRects: [NSRect] = []
    private var segmentTrackingAreas: [NSTrackingArea] = []
    private var tooltipTagIndices: [NSView.ToolTipTag: Int] = [:]
    private var accessibilitySegments: [StatusSegmentAccessibilityElement] = []
    /// Geometry the accessibility elements were built for; rebuilding for an
    /// identical state only posts a spurious .layoutChanged.
    private var accessibilityState: (model: StatusStripModel, rects: [NSRect])?
    /// Per-segment widths, recomputed only when the model changes.
    private var cachedSegmentWidths: [CGFloat]?
    /// Resolved symbol images keyed by name and color.
    private var symbolCache: [String: NSImage] = [:]

    override var intrinsicContentSize: NSSize {
        NSSize(width: stripWidth, height: NSView.noIntrinsicMetric)
    }

    override func layout() {
        super.layout()
        recomputeGeometry()
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        syncTrackingAreas()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
        true
    }

    override func accessibilityChildren() -> [Any]? {
        accessibilitySegments
    }

    override func resetCursorRects() {
        super.resetCursorRects()
        for (index, rect) in segmentRects.enumerated()
        where index < model.segments.count && model.segments[index].enabled {
            addCursorRect(rect, cursor: .pointingHand)
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        for (index, segment) in model.segments.enumerated() {
            guard index < segmentRects.count else { continue }
            let rect = segmentRects[index]
            let hovered = hoveredIndex == index
            if segment.state == .active {
                NSColor.controlAccentColor.setFill()
                NSBezierPath(roundedRect: rect, xRadius: 4, yRadius: 4).fill()
            } else if hovered && segment.enabled {
                NSColor.quaternaryLabelColor.setFill()
                NSBezierPath(roundedRect: rect, xRadius: 4, yRadius: 4).fill()
            }
            let color = textColor(for: segment, hovered: hovered)
            var x = rect.minX + Self.horizontalPadding
            if let symbol = segment.symbol {
                if let image = symbolImage(named: symbol, color: color) {
                    let size = image.size
                    image.draw(in: NSRect(x: x, y: rect.midY - size.height / 2, width: size.width, height: size.height))
                    x += size.width + (segment.label.isEmpty ? 0 : Self.iconGap)
                } else {
                    let glyph = fallbackGlyph(for: segment)
                    if !glyph.isEmpty {
                        let size = (glyph as NSString).size(withAttributes: [.font: Self.font])
                        (glyph as NSString).draw(
                            at: NSPoint(x: x, y: rect.midY - size.height / 2),
                            withAttributes: [.font: Self.font, .foregroundColor: color]
                        )
                        x += size.width + (segment.label.isEmpty ? 0 : Self.iconGap)
                    }
                }
            }
            if !segment.label.isEmpty {
                let size = (segment.label as NSString).size(withAttributes: [.font: Self.font])
                (segment.label as NSString).draw(
                    at: NSPoint(x: x, y: rect.midY - size.height / 2),
                    withAttributes: [.font: Self.font, .foregroundColor: color]
                )
            }
        }
    }

    override func mouseEntered(with event: NSEvent) {
        guard let index = trackedIndex(for: event) else { return }
        hoveredIndex = index
        needsDisplay = true
    }

    override func mouseExited(with event: NSEvent) {
        guard let index = trackedIndex(for: event) else { return }
        if hoveredIndex == index {
            hoveredIndex = nil
            needsDisplay = true
        }
    }

    override func mouseUp(with event: NSEvent) {
        if event.modifierFlags.contains(.control) {
            onRightClick?()
            return
        }
        activate(at: convert(event.locationInWindow, from: nil))
    }

    override func rightMouseUp(with event: NSEvent) {
        onRightClick?()
    }

    func view(
        _ view: NSView,
        stringForToolTip tag: NSView.ToolTipTag,
        point: NSPoint,
        userData data: UnsafeMutableRawPointer?
    ) -> String {
        guard let index = tooltipTagIndices[tag], index < model.segments.count else { return "" }
        return tooltip(for: model.segments[index])
    }

    private var stripWidth: CGFloat {
        let widths = cachedSegmentWidths ?? model.segments.map(segmentWidth)
        if cachedSegmentWidths == nil { cachedSegmentWidths = widths }
        guard !widths.isEmpty else { return 0 }
        return ceil(widths.reduce(0, +) + CGFloat(widths.count - 1) * Self.segmentSpacing)
    }

    private func segmentWidth(_ segment: StatusSegment) -> CGFloat {
        var width: CGFloat = 0
        var textWidth: CGFloat = 0
        if !segment.label.isEmpty {
            textWidth = (segment.label as NSString).size(withAttributes: [.font: Self.font]).width
            width += textWidth
        }
        if let symbol = segment.symbol {
            if let image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil) {
                width += image.size.width
            } else {
                let glyph = fallbackGlyph(for: segment)
                if !glyph.isEmpty {
                    width += (glyph as NSString).size(withAttributes: [.font: Self.font]).width
                }
            }
            if textWidth > 0 { width += Self.iconGap }
        }
        return ceil(width + 2 * Self.horizontalPadding)
    }

    private func recomputeGeometry() {
        let rects = computeSegmentRects()
        if rects != segmentRects {
            segmentRects = rects
            syncTrackingAreas()
            syncToolTips()
            window?.invalidateCursorRects(for: self)
        }
        rebuildAccessibility()
    }

    private func computeSegmentRects() -> [NSRect] {
        guard !model.segments.isEmpty else { return [] }
        let widths = cachedSegmentWidths ?? model.segments.map(segmentWidth)
        if cachedSegmentWidths == nil { cachedSegmentWidths = widths }
        let total = widths.reduce(0, +) + CGFloat(widths.count - 1) * Self.segmentSpacing
        let height = min(max(bounds.height - 4, 14), 20)
        let y = bounds.midY - height / 2
        var x = floor((bounds.width - total) / 2)
        var rects: [NSRect] = []
        rects.reserveCapacity(widths.count)
        for width in widths {
            rects.append(NSRect(x: x, y: y, width: width, height: height))
            x += width + Self.segmentSpacing
        }
        return rects
    }

    private func syncTrackingAreas() {
        for area in segmentTrackingAreas { removeTrackingArea(area) }
        segmentTrackingAreas = segmentRects.map { rect in
            let area = NSTrackingArea(
                rect: rect,
                options: [.mouseEnteredAndExited, .activeAlways],
                owner: self,
                userInfo: nil
            )
            addTrackingArea(area)
            return area
        }
    }

    private func syncToolTips() {
        for tag in tooltipTagIndices.keys { removeToolTip(tag) }
        tooltipTagIndices.removeAll()
        for (index, rect) in segmentRects.enumerated() {
            let tag = addToolTip(rect, owner: self, userData: nil)
            tooltipTagIndices[tag] = index
        }
    }

    private func trackedIndex(for event: NSEvent) -> Int? {
        guard let area = event.trackingArea else { return nil }
        return segmentTrackingAreas.firstIndex(where: { $0 === area })
    }

    private func activate(at point: NSPoint) {
        if let index = segmentRects.firstIndex(where: { $0.contains(point) }), index < model.segments.count {
            let segment = model.segments[index]
            guard segment.enabled else { return }
            onSegment?(segment)
            return
        }
        guard model.segments.count == 1, model.segments[0].state == .inactive, model.segments[0].enabled else {
            return
        }
        onSegment?(model.segments[0])
    }

    private func textColor(for segment: StatusSegment, hovered: Bool) -> NSColor {
        switch segment.state {
        case .active:
            return .selectedMenuItemTextColor
        case .paused:
            return .secondaryLabelColor
        case .warning:
            return .systemOrange
        case .inactive:
            return .labelColor
        case .idle:
            return model.compact && !hovered ? .secondaryLabelColor : .labelColor
        }
    }

    private func fallbackGlyph(for segment: StatusSegment) -> String {
        switch segment.state {
        case .paused:
            return "⏸"
        case .warning:
            return "⚠"
        case .inactive:
            return "▶"
        default:
            return ""
        }
    }

    private func symbolImage(named name: String, color: NSColor) -> NSImage? {
        let key = "\(name)|\(color.hashValue)"
        if let cached = symbolCache[key] { return cached }
        guard let base = NSImage(systemSymbolName: name, accessibilityDescription: nil) else {
            return nil
        }
        let configuration = NSImage.SymbolConfiguration(pointSize: 12, weight: .medium)
            .applying(NSImage.SymbolConfiguration(paletteColors: [color]))
        let image = base.withSymbolConfiguration(configuration) ?? base
        image.isTemplate = false
        symbolCache[key] = image
        return image
    }

    private func accessibilityLabel(for segment: StatusSegment) -> String {
        if let space = segment.space {
            return segment.state == .active ? "Workspace \(space), active" : "Workspace \(space)"
        }
        switch segment.state {
        case .inactive:
            return segment.label.isEmpty ? "Start on this Space" : segment.label
        case .warning:
            return "Warning"
        case .paused:
            return segment.label.isEmpty ? "Paused" : segment.label
        default:
            return segment.label
        }
    }

    private func tooltip(for segment: StatusSegment) -> String {
        if let space = segment.space {
            if segment.state == .active { return "Workspace \(space), current" }
            if segment.state == .paused { return "Workspace \(space), paused" }
            return "Workspace \(space)"
        }
        if segment.symbol == "exclamationmark.triangle.fill" {
            return warningTooltip ?? "Lumina warning"
        }
        if segment.symbol == "pause.fill" {
            return "Lumina is paused"
        }
        if segment.label == "…" {
            return "More workspaces in the menu"
        }
        if segment.state == .inactive {
            if let note = inactiveTooltip, !note.isEmpty { return note }
            return "Start tiling on this Space"
        }
        return segment.label
    }

    private func rebuildAccessibility() {
        // Rebuilding identical elements posts .layoutChanged on every poll,
        // waking the accessibility stack for nothing.
        if let accessibilityState, accessibilityState.model == model, accessibilityState.rects == segmentRects {
            return
        }
        accessibilityState = (model, segmentRects)
        accessibilitySegments = model.segments.enumerated().compactMap { index, segment -> StatusSegmentAccessibilityElement? in
            guard index < segmentRects.count else { return nil }
            let element = StatusSegmentAccessibilityElement()
            element.onPress = { [weak self] in
                guard segment.enabled else { return }
                self?.onSegment?(segment)
            }
            element.setAccessibilityParent(self)
            element.setAccessibilityRole(segment.enabled ? NSAccessibility.Role.button : NSAccessibility.Role.staticText)
            element.setAccessibilityLabel(accessibilityLabel(for: segment))
            element.setAccessibilityHelp(tooltip(for: segment))
            element.setAccessibilityFrameInParentSpace(segmentRects[index])
            return element
        }
        NSAccessibility.post(element: self, notification: .layoutChanged)
    }
}

private final class StatusSegmentAccessibilityElement: NSAccessibilityElement {
    var onPress: (() -> Void)?

    override func accessibilityPerformPress() -> Bool {
        onPress?()
        return true
    }
}

#endif
