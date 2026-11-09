#if os(macOS)
import AppKit
import LuminaLayout

final class StatusItemController {
    private var item: NSStatusItem?
    private var stripView: StatusStripView?
    var onDigit: ((Int) -> Void)?
    var onOpenConfig: (() -> Void)?
    var onGrantAccessibility: (() -> Void)?
    var onReload: (() -> Void)?
    var onPauseResume: (() -> Void)?
    var onStart: (() -> Void)?
    var onLaunchAtLogin: (() -> Void)?
    var onQuitThisSpace: (() -> Void)?
    var onQuitAll: (() -> Void)?
    private var current = false
    private var paused = false
    private var spaces: [Int] = [1, 2, 3, 4, 5]
    private var pendingSpace: Int?
    private var focused = 1
    private var warning: ExtraWarning = .none
    private var loginEnabled = false
    var loginNote: String?
    private var menu: NSMenu?
    private var rendered: RenderState?
    private var renderedWidth: CGFloat = 0
    var pausedNow: Bool { paused }

    private var displayedSpaces: [Int] {
        guard let pending = pendingSpace, !spaces.contains(pending) else {
            return spaces
        }
        var result = spaces
        result.append(pending)
        return result.sorted()
    }

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
            button.target = self
            button.action = #selector(stripClicked(_:))
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
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
        pendingSpace = nil
        renderStrip()
    }

    func updateCurrent(spaces: [Int], focused: Int, paused: Bool, loginEnabled: Bool = false, warning: ExtraWarning) {
        current = true
        self.spaces = spaces.isEmpty ? [1] : spaces
        self.focused = focused
        self.paused = paused
        self.loginEnabled = loginEnabled
        self.warning = warning
        self.pendingSpace = nil
        renderStrip()
    }

    func updateCurrent(spaceCount: Int, focused: Int, paused: Bool, loginEnabled: Bool = false, warning: ExtraWarning) {
        updateCurrent(
            spaces: Array(1...max(spaceCount, 1)),
            focused: focused,
            paused: paused,
            loginEnabled: loginEnabled,
            warning: warning
        )
    }

    /// Optimistically highlight a workspace the user just selected, before the
    /// authoritative status arrives. The next poll either confirms it (no
    /// visible change) or corrects the highlight.
    func showPendingSpace(_ n: Int) {
        guard current, n != focused else { return }
        focused = n
        if !spaces.contains(n) {
            pendingSpace = n
        } else {
            pendingSpace = nil
        }
        renderStrip()
    }

    func digitClickFrames() -> [(space: Int, rect: CGRect)] {
        stripView?.digitClickFrames() ?? []
    }

    private func renderStrip() {
        let tip = [warning.tooltip, loginNote].compactMap { $0 }.joined(separator: "\n")
        apply(
            statusStrip(
                spaces: displayedSpaces,
                focused: focused,
                paused: paused,
                warning: warning != .none,
                current: current
            ),
            tooltip: tip.isEmpty ? nil : tip
        )
    }

    private func apply(_ model: StatusStripModel, tooltip: String?) {
        stripView?.warningTooltip = warning.tooltip
        stripView?.inactiveTooltip = loginNote
        item?.button?.toolTip = tooltip
        let state = RenderState(model: model, tooltip: tooltip, loginEnabled: loginEnabled)
        guard state != rendered else { return }
        rendered = state
        stripView?.model = model
        resizeToFit()
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
        if current {
            for i in displayedSpaces {
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
        menu.addItem(menuItem(title: "Config…", symbol: "gearshape", action: #selector(openConfig)))
        menu.addItem(
            menuItem(
                title: "Grant Accessibility…",
                symbol: "hand.raised",
                action: #selector(grantAccessibility)
            )
        )
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

    @objc func stripClicked(_ sender: Any?) {
        guard item?.button != nil, let view = stripView, let event = NSApp.currentEvent else { return }
        let right = event.type == .rightMouseUp || event.type == .rightMouseDown || event.modifierFlags.contains(.control)
        if right {
            showMenu()
            return
        }
        view.click(at: view.convert(event.locationInWindow, from: nil))
    }

    @objc func pickSpace(_ sender: NSMenuItem) { onDigit?(sender.tag) }
    @objc func openConfig() { onOpenConfig?() }
    @objc func grantAccessibility() { onGrantAccessibility?() }
    @objc func reload() { onReload?() }
    @objc func pauseResume() { onPauseResume?() }
    @objc func start() { onStart?() }
    @objc func login() { onLaunchAtLogin?() }
    @objc func quitThis() { onQuitThisSpace?() }
    @objc func quitAll() { onQuitAll?() }
}

#endif
