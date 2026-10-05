#if os(macOS)
import AppKit
import ApplicationServices

final class FirstRunController: @unchecked Sendable {
    let flagPath: String
    weak var extra: ExtraController?
    var axTrusted: () -> Bool = { false }
    private var showing = false
    private var snoozeUntil: Date?
    private var lastTrustCheck = Date.distantPast
    private var trustCheckInFlight = false
    private var poll: Timer?

    init(flagPath: String, extra: ExtraController) {
        self.flagPath = flagPath
        self.extra = extra
    }

    func sheetIfNeeded() {
        if showing { return }
        if FileManager.default.fileExists(atPath: flagPath) { return }
        showing = true
        show()
        startPolling()
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
        if axTrusted() {
            markDone()
        }
        if response == .alertFirstButtonReturn {
            openAccessibility()
        } else {
            // "Later" means later, not "ask again in half a second".
            snoozeUntil = Date().addingTimeInterval(3600)
        }
    }

    private func startPolling() {
        poll?.invalidate()
        let timer = Timer(timeInterval: 1.0, repeats: true) { [weak self] _ in
            guard let self else { return }
            if FileManager.default.fileExists(atPath: self.flagPath) {
                self.poll?.invalidate()
                return
            }
            if let until = self.snoozeUntil, Date() < until { return }
            self.refreshTrustOffMain()
            if !self.showing {
                self.showing = true
                self.show()
            }
        }
        poll = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    /// The trust check is agent IPC; never block the main run loop on it.
    private func refreshTrustOffMain() {
        guard !trustCheckInFlight, Date().timeIntervalSince(lastTrustCheck) > 3 else { return }
        lastTrustCheck = Date()
        trustCheckInFlight = true
        DispatchQueue.global().async { [weak self] in
            guard let self else { return }
            let trusted = self.axTrusted()
            DispatchQueue.main.async {
                self.trustCheckInFlight = false
                if trusted {
                    self.markDone()
                    self.poll?.invalidate()
                }
            }
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
