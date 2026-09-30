import AppKit
import Carbon.HIToolbox

final class HotKeyManager {
    private(set) var isRegistered = false
    private var hotKeyRef: EventHotKeyRef?
    private var eventHandlerRef: EventHandlerRef?
    private let action: () -> Void

    init(action: @escaping () -> Void) {
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
            { _, _, userData in
                guard let userData else { return noErr }
                let manager = Unmanaged<HotKeyManager>.fromOpaque(userData).takeUnretainedValue()
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
        let identifier = EventHotKeyID(signature: fourCharCode("KSHT"), id: 1)
        let status = RegisterEventHotKey(
            UInt32(kVK_ANSI_A),
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
