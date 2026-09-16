#if os(macOS)
import AppKit
import LuminaLayout

final class StatusItemController {
    private var item: NSStatusItem?
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
    private var spaceCount = 5
    private var focused = 1

    func install() {
        guard item == nil else { return }
        item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item?.button?.title = "Start on this Space"
        item?.button?.target = self
        item?.button?.action = #selector(clicked)
        rebuildMenu()
    }

    func updateEmpty() {
        current = false
        item?.button?.title = "Start on this Space"
        rebuildMenu()
    }

    func updateCurrent(spaceCount: Int, focused: Int, paused: Bool, warning: ExtraWarning) {
        current = true
        self.spaceCount = spaceCount
        self.focused = focused
        self.paused = paused
        var parts: [String] = []
        for i in 1...spaceCount {
            parts.append(i == focused ? "(\(i))" : "\(i)")
        }
        var title = parts.joined(separator: " ")
        if warning != .none { title = "! " + title }
        item?.button?.title = title
        item?.button?.toolTip = warning.tooltip
        rebuildMenu()
    }

    @objc func clicked(_ sender: Any?) {
        if !current {
            onStart?()
            return
        }
        // Digit click: approximate by not having per-digit tracking; menu handles switch.
    }

    private func rebuildMenu() {
        let menu = NSMenu()
        if current {
            for i in 1...spaceCount {
                let item = NSMenuItem(title: "Space \(i)", action: #selector(pickSpace(_:)), keyEquivalent: "")
                item.tag = i
                item.target = self
                if i == focused { item.state = .on }
                menu.addItem(item)
            }
            menu.addItem(.separator())
        }
        menu.addItem(action("Open Config", #selector(openConfig)))
        if current {
            menu.addItem(action("Reload", #selector(reload)))
            menu.addItem(action(paused ? "Resume" : "Pause", #selector(pauseResume)))
        }
        let start = action("Start on this Space", #selector(start))
        start.isHidden = current
        menu.addItem(start)
        menu.addItem(action("Launch at Login", #selector(login)))
        if current {
            menu.addItem(action("Quit this Space", #selector(quitThis)))
        }
        menu.addItem(action("Quit all", #selector(quitAll)))
        item?.menu = menu
    }

    private func action(_ title: String, _ sel: Selector) -> NSMenuItem {
        let i = NSMenuItem(title: title, action: sel, keyEquivalent: "")
        i.target = self
        return i
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
#endif
