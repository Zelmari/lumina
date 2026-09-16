#if os(macOS)
import AppKit
import ApplicationServices

final class FirstRunController: @unchecked Sendable {
    let flagPath: String
    weak var extra: ExtraController?
    private var showing = false

    init(flagPath: String, extra: ExtraController) {
        self.flagPath = flagPath
        self.extra = extra
    }

    func sheetIfNeeded() {
        if showing { return }
        if FileManager.default.fileExists(atPath: flagPath) { return }
        showing = true
        show()
    }

    private func show() {
        defer { showing = false }
        if FileManager.default.fileExists(atPath: flagPath) { return }
        extra?.writeDefaultConfigIfNeeded()
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "Welcome to Lumina"
        alert.informativeText = """
        Lumina is a guest tiling window manager. It never quits your apps.

        Accessibility is required for Lumina Agent (not this menu extra).

        Turn Stage Manager off. Do not run another tiling WM.

        System Settings → Desktop & Dock → Windows: turn off “Drag windows to screen edges to tile”, “Drag windows to menu bar to fill screen”, and “Hold Option key while dragging windows to tile”. Lumina does not write those settings.

        Launch at login is off unless you choose it in the menu.
        """
        alert.addButton(withTitle: "Open Accessibility Settings")
        alert.addButton(withTitle: "Later")
        alert.window.level = .floating
        let response = alert.runModal()
        markDone()
        if response == .alertFirstButtonReturn {
            openAccessibility()
        }
    }

    private func markDone() {
        try? FileManager.default.createDirectory(
            atPath: (flagPath as NSString).deletingLastPathComponent,
            withIntermediateDirectories: true
        )
        FileManager.default.createFile(atPath: flagPath, contents: nil)
    }

    private func openAccessibility() {
        let urls = [
            "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?Privacy_Accessibility",
            "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility",
        ]
        for s in urls {
            if let url = URL(string: s), NSWorkspace.shared.open(url) { return }
        }
    }
}
#endif
