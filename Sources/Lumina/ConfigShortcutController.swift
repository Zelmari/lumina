#if os(macOS)
import AppKit
import Carbon
import LuminaLayout

/// The supervisor owns this hotkey so opening Config never depends on a
/// running, current, or unpaused window-management agent.
final class ConfigShortcutController: @unchecked Sendable {
    private let path: String
    private let onOpen: () -> Void
    private var hotkey: EventHotKeyRef?
    private var handler: EventHandlerRef?
    private var timer: Timer?
    private var registeredChord: Chord?
    private var lastText: String?
    private var hasLoaded = false
    private(set) var error: String?
    var onError: ((String?) -> Void)?

    init(path: String, onOpen: @escaping () -> Void) {
        self.path = path
        self.onOpen = onOpen
    }

    func start() {
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let result = InstallEventHandler(GetApplicationEventTarget(), { _, event, context in
            guard let event, let context else { return noErr }
            var id = EventHotKeyID()
            GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID), nil,
                              MemoryLayout<EventHotKeyID>.size, nil, &id)
            guard id.signature == OSType(0x4C554D43), id.id == 1 else { return eventNotHandledErr }
            Unmanaged<ConfigShortcutController>.fromOpaque(context).takeUnretainedValue().onOpen()
            return noErr
        }, 1, &spec, Unmanaged.passUnretained(self).toOpaque(), &handler)
        guard result == noErr else {
            report("Could not install the Config shortcut handler (\(result)). Use the menu to open Config.")
            return
        }
        refresh()
        timer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in self?.refresh() }
    }

    private func refresh() {
        do {
            let text = try String(contentsOfFile: path, encoding: .utf8)
            guard !hasLoaded || text != lastText else { return }
            hasLoaded = true
            lastText = text
            let config = try parseConfig(text: text, defaults: .bundledDefault).get()
            guard let chord = parseChord(config.configShortcut) else { return }
            guard chord != registeredChord else { report(nil); return }
            var modifiers: UInt32 = 0
            if chord.option { modifiers |= UInt32(optionKey) }
            if chord.cmd { modifiers |= UInt32(cmdKey) }
            if chord.ctrl { modifiers |= UInt32(controlKey) }
            if chord.shift { modifiers |= UInt32(shiftKey) }
            var replacement: EventHotKeyRef?
            let id = EventHotKeyID(signature: OSType(0x4C554D43), id: 1) // 'LUMC'
            let result = RegisterEventHotKey(chord.keyCode, modifiers, id, GetApplicationEventTarget(), 0, &replacement)
            guard result == noErr, let replacement else {
                report("Config shortcut \(chord.description) is unavailable (\(result)). Choose another shortcut; the previous shortcut remains active.")
                return
            }
            if let hotkey { UnregisterEventHotKey(hotkey) }
            hotkey = replacement
            registeredChord = chord
            report(nil)
        } catch {
            report("Config shortcut unchanged: \(error.localizedDescription)")
        }
    }

    private func report(_ message: String?) {
        error = message
        onError?(message)
    }

    deinit {
        timer?.invalidate()
        if let hotkey { UnregisterEventHotKey(hotkey) }
        if let handler { RemoveEventHandler(handler) }
    }
}
#endif
