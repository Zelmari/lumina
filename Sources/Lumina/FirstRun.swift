#if os(macOS)
import AppKit
import ApplicationServices

final class FirstRunController {
    let flagPath: String
    weak var extra: ExtraController?
    private var timer: Timer?
    private var alert: NSAlert?

    init(flagPath: String, extra: ExtraController) {
        self.flagPath = flagPath
        self.extra = extra
    }

    func sheetIfNeeded() {
        if FileManager.default.fileExists(atPath: flagPath), extra?.currentRecord() != nil {
            return
        }
        DispatchQueue.main.async { self.show() }
    }

    private func show() {
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
        self.alert = alert
        let response = alert.runModal()
        if response == .alertFirstButtonReturn {
            openAccessibility()
        }
        pollAX()
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

    private func pollAX() {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] t in
            guard let self else { return }
            if self.extra?.currentRecord() != nil {
                self.extra?.pollStatus()
            }
            // Agent reports axTrusted via status; extra must not prompt as itself.
            if let rec = self.extra?.currentRecord(),
               let resp = Client.request(socketPath: rec.socket, cmd: "status", args: [:], role: .agent),
               resp.data?.object?["axTrusted"]?.bool == true
            {
                t.invalidate()
                try? FileManager.default.createDirectory(
                    atPath: (self.flagPath as NSString).deletingLastPathComponent,
                    withIntermediateDirectories: true
                )
                FileManager.default.createFile(atPath: self.flagPath, contents: nil)
            }
        }
    }
}
#endif
