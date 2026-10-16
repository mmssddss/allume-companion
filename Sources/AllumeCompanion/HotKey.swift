import Carbon
import Foundation

/// Global hotkey via Carbon RegisterEventHotKey (works without Input Monitoring).
/// A registered hotkey swallows the key in every app, so callers register it only while
/// Allume is frontmost and unregister it otherwise (see AppDelegate).
final class HotKey {
    private let keyCode: UInt32
    private let modifiers: UInt32
    private var hotKeyRef: EventHotKeyRef?
    private var handlerRef: EventHandlerRef?
    var action: (() -> Void)?
    var isRegistered: Bool { hotKeyRef != nil }

    init(keyCode: UInt32, modifiers: UInt32) {
        self.keyCode = keyCode
        self.modifiers = modifiers
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let selfPtr = Unmanaged.passUnretained(self).toOpaque()
        InstallEventHandler(GetApplicationEventTarget(), { _, _, userData in
            guard let userData else { return noErr }
            let me = Unmanaged<HotKey>.fromOpaque(userData).takeUnretainedValue()
            DispatchQueue.main.async { me.action?() }
            return noErr
        }, 1, &spec, selfPtr, &handlerRef)
    }

    func register() {
        guard hotKeyRef == nil else { return }
        let id = EventHotKeyID(signature: OSType(0x414C_4C55), id: 1) // 'ALLU'
        RegisterEventHotKey(keyCode, modifiers, id, GetApplicationEventTarget(), 0, &hotKeyRef)
    }

    func unregister() {
        if let hotKeyRef { UnregisterEventHotKey(hotKeyRef) }
        hotKeyRef = nil
    }

    deinit {
        unregister()
        if let handlerRef { RemoveEventHandler(handlerRef) }
    }
}
