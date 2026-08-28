import Carbon.HIToolbox
import AppKit

/// System-wide ⌘⌃Esc to stop a recording — the same shortcut QuickTime uses.
final class StopHotkey {
    static let shared = StopHotkey()
    private var ref: EventHotKeyRef?
    private var handler: EventHandlerRef?
    var onPress: (() -> Void)?

    private init() {}

    func install() {
        guard ref == nil else { return }
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, _, userData in
            guard let userData else { return noErr }
            let me = Unmanaged<StopHotkey>.fromOpaque(userData).takeUnretainedValue()
            DispatchQueue.main.async { me.onPress?() }
            return noErr
        }, 1, &spec, Unmanaged.passUnretained(self).toOpaque(), &handler)

        let id = EventHotKeyID(signature: OSType(0x4F574C43), id: 1)  // 'OWLC'
        RegisterEventHotKey(UInt32(kVK_Escape),
                            UInt32(cmdKey | controlKey),
                            id, GetApplicationEventTarget(), 0, &ref)
    }

    func remove() {
        if let ref { UnregisterEventHotKey(ref) }
        ref = nil
        if let handler { RemoveEventHandler(handler) }
        handler = nil
    }
}
