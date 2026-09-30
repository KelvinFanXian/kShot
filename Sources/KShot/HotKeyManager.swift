import AppKit
import Carbon.HIToolbox

final class HotKeyManager {
    private(set) var isRegistered = false
    private var hotKeyRef: EventHotKeyRef?
    private var eventHandlerRef: EventHandlerRef?
    private let action: () -> Void
    private let keyCode: UInt32
    private let identifierID: UInt32

    init(keyCode: UInt32, identifierID: UInt32, action: @escaping () -> Void) {
        self.keyCode = keyCode
        self.identifierID = identifierID
        self.action = action
        installHandler()
        registerHotKey()
    }

    deinit {
        if let hotKeyRef { UnregisterEventHotKey(hotKeyRef) }
        if let eventHandlerRef { RemoveEventHandler(eventHandlerRef) }
    }

    private func installHandler() {
        var eventType = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )
        let pointer = Unmanaged.passUnretained(self).toOpaque()
        InstallEventHandler(
            GetApplicationEventTarget(),
            { _, event, userData in
                guard let event, let userData else { return OSStatus(eventNotHandledErr) }
                let manager = Unmanaged<HotKeyManager>.fromOpaque(userData).takeUnretainedValue()
                var identifier = EventHotKeyID()
                let status = GetEventParameter(
                    event,
                    EventParamName(kEventParamDirectObject),
                    EventParamType(typeEventHotKeyID),
                    nil,
                    MemoryLayout<EventHotKeyID>.size,
                    nil,
                    &identifier
                )
                guard status == noErr, identifier.id == manager.identifierID else {
                    return OSStatus(eventNotHandledErr)
                }
                DispatchQueue.main.async { manager.action() }
                return noErr
            },
            1,
            &eventType,
            pointer,
            &eventHandlerRef
        )
    }

    private func registerHotKey() {
        let identifier = EventHotKeyID(signature: fourCharCode("KSHT"), id: identifierID)
        let status = RegisterEventHotKey(
            keyCode,
            UInt32(controlKey | cmdKey),
            identifier,
            GetApplicationEventTarget(),
            0,
            &hotKeyRef
        )
        isRegistered = status == noErr
        if status != noErr {
            NSLog("KShot 注册快捷键失败，OSStatus=%d", status)
        }
    }

    private func fourCharCode(_ value: String) -> FourCharCode {
        value.utf8.reduce(0) { ($0 << 8) + FourCharCode($1) }
    }
}
