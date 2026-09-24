import Carbon
import Foundation

/// System-wide hotkeys through Carbon's RegisterEventHotKey, which needs no
/// Accessibility permission. Registered keys are captured from every app
/// while Telemprompit is running.
final class GlobalHotkeys {
    struct Binding {
        var keyCode: Int
        var modifiers: Int
        var action: () -> Void
    }

    private var hotKeys: [EventHotKeyRef] = []
    private var actions: [UInt32: () -> Void] = [:]
    private var handler: EventHandlerRef?
    private static let signature: OSType = 0x5450_4D54 // "TPMT"

    init() {
        var eventType = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(
            GetApplicationEventTarget(),
            { _, event, userData in
                guard let event, let userData else { return OSStatus(eventNotHandledErr) }
                var hotKeyID = EventHotKeyID()
                GetEventParameter(
                    event,
                    EventParamName(kEventParamDirectObject),
                    EventParamType(typeEventHotKeyID),
                    nil,
                    MemoryLayout<EventHotKeyID>.size,
                    nil,
                    &hotKeyID
                )
                let hotkeys = Unmanaged<GlobalHotkeys>.fromOpaque(userData).takeUnretainedValue()
                hotkeys.actions[hotKeyID.id]?()
                return noErr
            },
            1,
            &eventType,
            Unmanaged.passUnretained(self).toOpaque(),
            &handler
        )
    }

    func replace(with bindings: [Binding]) {
        hotKeys.forEach { UnregisterEventHotKey($0) }
        hotKeys.removeAll()
        actions.removeAll()

        for (offset, binding) in bindings.enumerated() {
            let id = UInt32(offset + 1)
            var ref: EventHotKeyRef?
            let status = RegisterEventHotKey(
                UInt32(binding.keyCode),
                UInt32(binding.modifiers),
                EventHotKeyID(signature: Self.signature, id: id),
                GetApplicationEventTarget(),
                0,
                &ref
            )
            if status == noErr, let ref {
                hotKeys.append(ref)
                actions[id] = binding.action
            } else {
                NSLog("Telemprompit could not register hotkey %d (status %d)", binding.keyCode, status)
            }
        }
    }

    deinit {
        hotKeys.forEach { UnregisterEventHotKey($0) }
        if let handler { RemoveEventHandler(handler) }
    }
}
