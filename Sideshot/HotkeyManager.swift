import AppKit
import Carbon

/// Global hotkeys via Carbon RegisterEventHotKey — the same mechanism CleanShot X uses
/// (its binary carries `carbonEventHotKey` / `carbonHotKeyID` symbols).
final class HotkeyManager {
    private struct HotkeyBox {
        let id: UInt32
        let action: () -> Void
    }

    private var boxes: [HotkeyBox] = []
    private var refs: [EventHotKeyRef] = []
    private var handlerRef: EventHandlerRef?
    private var escRef: EventHotKeyRef?
    private var escAction: (() -> Void)?
    private let signature: OSType = 0x53494445  // "SIDE"

    func register(keyCode: UInt32, modifiers: UInt32, id: UInt32, action: @escaping () -> Void) {
        var ref: EventHotKeyRef?
        let hotKeyID = EventHotKeyID(signature: signature, id: id)
        let status = RegisterEventHotKey(keyCode, modifiers, hotKeyID, GetApplicationEventTarget(), 0, &ref)
        guard status == noErr, let ref else {
            NSLog("Sideshot hotkey \(id) registration failed: \(status)")
            return
        }
        refs.append(ref)
        boxes.append(HotkeyBox(id: id, action: action))
    }

    /// Dynamically enable/disable a global Esc hotkey (id 99). Used only while a
/// capture/selection/recording operation is in flight so we don't swallow Esc globally.
func enableEsc(_ action: (() -> Void)?) {
        escAction = action
        if action != nil {
            if escRef == nil {
                var ref: EventHotKeyRef?
                RegisterEventHotKey(53, 0, EventHotKeyID(signature: signature, id: 99),
                                    GetApplicationEventTarget(), 0, &ref)
                escRef = ref
            }
        } else if let ref = escRef {
            UnregisterEventHotKey(ref)
            escRef = nil
        }
    }

    func install() {
        var eventType = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, event, userData in
            guard let event else { return noErr }
            var hotKeyID = EventHotKeyID()
            GetEventParameter(event,
                              EventParamName(kEventParamDirectObject),
                              EventParamType(typeEventHotKeyID),
                              nil, MemoryLayout<EventHotKeyID>.size, nil, &hotKeyID)
            guard let userData else { return noErr }
            let manager = Unmanaged<HotkeyManager>.fromOpaque(userData).takeUnretainedValue()
            let id = hotKeyID.id
            DispatchQueue.main.async {
                if id == 99 {
                    manager.escAction?()
                } else if let box = manager.boxes.first(where: { $0.id == id }) {
                    box.action()
                }
            }
            return noErr
        }, 1, &eventType, Unmanaged.passUnretained(self).toOpaque(), &handlerRef)
    }
}