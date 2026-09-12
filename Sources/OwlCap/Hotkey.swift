import Carbon.HIToolbox
import AppKit

/// System-wide shortcuts. These are registered with Carbon's RegisterEventHotKey, which
/// fires no matter which app is in front — and, importantly, without activating OwlCap,
/// so summoning the bar never pulls you out of a fullscreen Space.
final class Hotkeys {
    static let shared = Hotkeys()

    /// ⌘⌃⎋ — the shortcut QuickTime uses to stop a recording.
    var onStop: (() -> Void)?
    /// ⌘⇧6 — sits next to macOS's own ⌘⇧5 capture shortcut.
    var onSummon: (() -> Void)?

    private var refs: [EventHotKeyRef?] = []
    private var handler: EventHandlerRef?
    private let signature: OSType = 0x4F574C43   // 'OWLC'

    private init() {}

    func install() {
        guard refs.isEmpty else { return }
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard),
                                 eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, event, userData in
            guard let userData, let event else { return noErr }
            var id = EventHotKeyID()
            GetEventParameter(event, EventParamName(kEventParamDirectObject),
                              EventParamType(typeEventHotKeyID), nil,
                              MemoryLayout<EventHotKeyID>.size, nil, &id)
            let me = Unmanaged<Hotkeys>.fromOpaque(userData).takeUnretainedValue()
            DispatchQueue.main.async {
                switch id.id {
                case 1: me.onStop?()
                case 2: me.onSummon?()
                default: break
                }
            }
            return noErr
        }, 1, &spec, Unmanaged.passUnretained(self).toOpaque(), &handler)

        register(keyCode: UInt32(kVK_Escape), modifiers: UInt32(cmdKey | controlKey), id: 1)
        register(keyCode: UInt32(kVK_ANSI_6), modifiers: UInt32(cmdKey | shiftKey), id: 2)
    }

    private func register(keyCode: UInt32, modifiers: UInt32, id: UInt32) {
        var ref: EventHotKeyRef?
        RegisterEventHotKey(keyCode, modifiers,
                            EventHotKeyID(signature: signature, id: id),
                            GetApplicationEventTarget(), 0, &ref)
        refs.append(ref)
    }

    func remove() {
        for ref in refs { if let ref { UnregisterEventHotKey(ref) } }
        refs.removeAll()
        if let handler { RemoveEventHandler(handler) }
        handler = nil
    }
}
