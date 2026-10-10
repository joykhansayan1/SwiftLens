#if os(macOS)
import Carbon.HIToolbox
import Foundation

/// A system-wide keyboard shortcut (default ⌥⌘L) registered through Carbon, which needs no
/// Accessibility permission.
final class GlobalHotKey {
    nonisolated(unsafe) static var action: (@MainActor () -> Void)?
    private var hotKeyRef: EventHotKeyRef?
    private var handlerRef: EventHandlerRef?

    init?(keyCode: UInt32 = UInt32(kVK_ANSI_L), modifiers: UInt32 = UInt32(cmdKey | optionKey)) {
        var eventType = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let status = InstallEventHandler(GetApplicationEventTarget(), { _, _, _ in
            Task { @MainActor in GlobalHotKey.action?() }
            return noErr
        }, 1, &eventType, nil, &handlerRef)
        guard status == noErr else { return nil }
        let identifier = EventHotKeyID(signature: OSType(0x534C_4E53), id: 1) // 'SLNS'
        guard RegisterEventHotKey(keyCode, modifiers, identifier, GetApplicationEventTarget(), 0, &hotKeyRef) == noErr else {
            return nil
        }
    }

    deinit {
        if let hotKeyRef { UnregisterEventHotKey(hotKeyRef) }
        if let handlerRef { RemoveEventHandler(handlerRef) }
    }
}
#endif
