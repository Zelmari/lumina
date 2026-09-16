#if os(macOS)
import Carbon
import Foundation
import LuminaLayout
import LuminaIPC

public final class Hotkeys {
    private var refs: [EventHotKeyRef] = []
    private var handler: EventHandlerRef?
    public var hotkeyError: String?
    public var onCommand: ((BoundCommand) -> Void)?
    public var isPaused: () -> Bool = { false }

    public func register(bindings: [Binding]) {
        unregister()
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let status = InstallEventHandler(
            GetApplicationEventTarget(),
            { (_, event, userData) -> OSStatus in
                guard let userData else { return noErr }
                let hotkeys = Unmanaged<Hotkeys>.fromOpaque(userData).takeUnretainedValue()
                return hotkeys.handle(event)
            },
            1,
            &spec,
            Unmanaged.passUnretained(self).toOpaque(),
            &handler
        )
        if status != noErr {
            hotkeyError = "InstallEventHandler failed"
            return
        }
        for (index, binding) in bindings.enumerated() {
            var modifiers: UInt32 = UInt32(optionKey)
            if binding.chord.shift { modifiers |= UInt32(shiftKey) }
            var ref: EventHotKeyRef?
            let id = EventHotKeyID(signature: OSType(0x4C554D41), id: UInt32(index + 1)) // 'LUMA'
            let err = RegisterEventHotKey(binding.chord.keyCode, modifiers, id, GetApplicationEventTarget(), 0, &ref)
            if err != noErr {
                let msg = "failed to register \(binding.chord.description)"
                hotkeyError = (hotkeyError.map { $0 + "; " } ?? "") + msg
                continue
            }
            if let ref { refs.append(ref) }
        }
        registered = bindings
    }

    public func unregister() {
        for ref in refs { UnregisterEventHotKey(ref) }
        refs.removeAll()
        registered = []
        if let handler {
            RemoveEventHandler(handler)
            self.handler = nil
        }
    }

    private var registered: [Binding] = []

    private func handle(_ event: EventRef?) -> OSStatus {
        guard let event else { return noErr }
        if isPaused() { return noErr }
        var id = EventHotKeyID()
        GetEventParameter(
            event,
            EventParamName(kEventParamDirectObject),
            EventParamType(typeEventHotKeyID),
            nil,
            MemoryLayout<EventHotKeyID>.size,
            nil,
            &id
        )
        let index = Int(id.id) - 1
        guard registered.indices.contains(index) else { return noErr }
        let command = registered[index].command
        MutationQueue.shared.hop { [weak self] in
            self?.onCommand?(command)
        }
        return noErr
    }
}
#endif
