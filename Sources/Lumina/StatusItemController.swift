#if os(macOS)
import AppKit
import LuminaLayout

final class StatusItemController {
    private var item: NSStatusItem?
    private var stripView: StatusStripView?
    var onDigit: ((Int) -> Void)?
    var onOpenConfig: (() -> Void)?
    var onReload: (() -> Void)?
    var onPauseResume: (() -> Void)?
    var onStart: (() -> Void)?
    var onLaunchAtLogin: (() -> Void)?
    var onQuitThisSpace: (() -> Void)?
    var onQuitAll: (() -> Void)?
    private var current = false
    private var paused = false
    private var spaceCount = 10
    private var focused = 1
    private var warning: ExtraWarning = .none
    private var loginEnabled = false
    var loginNote: String?
    private var menu: NSMenu?
    private var rendered: RenderState?
    private var renderedWidth: CGFloat = 0
    var pausedNow: Bool { paused }

    private struct RenderState: Equatable {
        var model: StatusStripModel
        var tooltip: String?
        var loginEnabled: Bool
    }

    func install() {
        guard item == nil else { return }
        let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        let view = StatusStripView()
        view.onSegment = { [weak self] segment in self?.perform(segment) }
        view.onRightClick = { [weak self] in self?.showMenu() }
        if let button = statusItem.button {
            button.title = ""
            button.target = nil
            button.action = nil
            button.imagePosition = .imageOnly
            button.imageScaling = .scaleNone
            button.setAccessibilityLabel("Lumina workspaces")
            view.frame = button.bounds
            view.autoresizingMask = [.width, .height]
            button.addSubview(view)
        }
        item = statusItem
        stripView = view
        rebuildMenu()
    }

    func updateEmpty(loginEnabled: Bool = false) {
        current = false
        self.loginEnabled = loginEnabled
        warning = .none
        apply(
            statusStrip(spaceCount: spaceCount, focused: focused, paused: false, warning: false, current: false),
            tooltip: loginNote
        )
    }

    func updateCurrent(spaceCount: Int, focused: Int, paused: Bool, loginEnabled: Bool = false, warning: ExtraWarning) {
        current = true
        self.spaceCount = spaceCount
        self.focused = focused
        self.paused = paused
        self.loginEnabled = loginEnabled
        self.warning = warning
        let tip = [warning.tooltip, loginNote].compactMap { $0 }.joined(separator: "\n")
        apply(
            statusStrip(
                spaceCount: spaceCount,
                focused: focused,
                paused: paused,
                warning: warning != .none,
                current: true
            ),
            tooltip: tip.isEmpty ? nil : tip
        )
    }

    private func apply(_ model: StatusStripModel, tooltip: String?) {
        stripView?.model = model
        stripView?.warningTooltip = warning.tooltip
        stripView?.inactiveTooltip = loginNote
        item?.button?.toolTip = tooltip
        resizeToFit()
        let state = RenderState(model: model, tooltip: tooltip, loginEnabled: loginEnabled)
        guard state != rendered else { return }
        rendered = state
        rebuildMenu()
    }

    private func resizeToFit() {
        guard let button = item?.button, let view = stripView else { return }
        let width = view.intrinsicContentSize.width
        guard width > 0 else { return }
        if abs(width - renderedWidth) > 0.5 {
            renderedWidth = width
            let spacer = NSImage(size: NSSize(width: width, height: 1))
            spacer.isTemplate = true
            button.image = spacer
        }
        view.frame = button.bounds
    }

    private func perform(_ segment: StatusSegment) {
        if let space = segment.space {
            onDigit?(space)
        } else if segment.state == .inactive {
            onStart?()
        }
    }

    private func showMenu() {
        rebuildMenu()
        guard let button = item?.button, let menu else { return }
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: button.bounds.height), in: button)
    }

    private func rebuildMenu() {
        let menu = NSMenu()
        let count = max(spaceCount, 1)
        if current {
            for i in 1...count {
                let entry = menuItem(
                    title: "Space \(i)",
                    symbol: "\(i).circle.fill",
                    hint: "⌥\(i)",
                    state: i == focused ? .on : .off,
                    action: #selector(pickSpace(_:))
                )
                entry.tag = i
                menu.addItem(entry)
            }
            menu.addItem(.separator())
        }
        menu.addItem(menuItem(title: "Open Config", symbol: "gearshape", action: #selector(openConfig)))
        if current {
            menu.addItem(menuItem(title: "Reload", symbol: "arrow.clockwise", action: #selector(reload)))
            menu.addItem(
                menuItem(
                    title: paused ? "Resume" : "Pause",
                    symbol: paused ? "play.fill" : "pause.fill",
                    action: #selector(pauseResume)
                )
            )
        }
        let start = menuItem(title: "Start on this Space", symbol: "play.fill", action: #selector(start))
        start.isHidden = current
        menu.addItem(start)
        menu.addItem(
            menuItem(
                title: "Launch at Login",
                symbol: "checkmark.circle",
                state: loginEnabled ? .on : .off,
                action: #selector(login)
            )
        )
        if current {
            menu.addItem(menuItem(title: "Quit this Space", symbol: "xmark.circle", action: #selector(quitThis)))
        }
        menu.addItem(menuItem(title: "Quit all", symbol: "power", action: #selector(quitAll)))
        item?.menu = nil
        item?.button?.menu = nil
        self.menu = menu
    }

    private func menuItem(
        title: String,
        symbol: String?,
        hint: String? = nil,
        state: NSControl.StateValue = .off,
        action: Selector
    ) -> NSMenuItem {
        let entry = NSMenuItem(title: title, action: action, keyEquivalent: "")
        entry.target = self
        entry.state = state
        if let symbol {
            entry.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
        }
        if let hint {
            let text = NSMutableAttributedString(string: title)
            text.append(
                NSAttributedString(
                    string: "\t\(hint)",
                    attributes: [.foregroundColor: NSColor.secondaryLabelColor]
                )
            )
            entry.attributedTitle = text
        }
        return entry
    }

    @objc func pickSpace(_ sender: NSMenuItem) { onDigit?(sender.tag) }
    @objc func openConfig() { onOpenConfig?() }
    @objc func reload() { onReload?() }
    @objc func pauseResume() { onPauseResume?() }
    @objc func start() { onStart?() }
    @objc func login() { onLaunchAtLogin?() }
    @objc func quitThis() { onQuitThisSpace?() }
    @objc func quitAll() { onQuitAll?() }
}

final class StatusStripView: NSView, NSViewToolTipOwner {
    private static let font = NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .medium)
    private static let segmentSpacing: CGFloat = 2
    private static let horizontalPadding: CGFloat = 5
    private static let iconGap: CGFloat = 3

    var model = StatusStripModel(segments: [], compact: false) {
        didSet {
            guard model != oldValue else { return }
            hoveredIndex = nil
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
        let widths = model.segments.map(segmentWidth)
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
        let widths = model.segments.map(segmentWidth)
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
        guard let base = NSImage(systemSymbolName: name, accessibilityDescription: nil) else {
            return nil
        }
        let configuration = NSImage.SymbolConfiguration(pointSize: 12, weight: .medium)
            .applying(NSImage.SymbolConfiguration(paletteColors: [color]))
        let image = base.withSymbolConfiguration(configuration) ?? base
        image.isTemplate = false
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
