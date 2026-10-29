import Carbon
import Foundation

// Сочетания клавиш на весь Mac через Carbon: работают из любой программы и не требуют разрешения «Универсальный доступ».
final class HotKeys {
    static let shared = HotKeys()
    private var actions: [UInt32: () -> Void] = [:]
    private var refs: [EventHotKeyRef] = []
    private var handlerInstalled = false

    /// keyCode — код клавиши (kVK_ANSI_1…), modifiers — controlKey | shiftKey и т.п.
    /// Возвращает false, если сочетание уже занято другой программой.
    @discardableResult
    func register(id: UInt32, keyCode: Int, modifiers: Int, action: @escaping () -> Void) -> Bool {
        installHandler()
        actions[id] = action
        var ref: EventHotKeyRef?
        let hotKeyID = EventHotKeyID(signature: OSType(0x534E4D4B), id: id)  // 'SNMK'
        if RegisterEventHotKey(UInt32(keyCode), UInt32(modifiers), hotKeyID, GetApplicationEventTarget(), 0, &ref) == noErr,
           let ref {
            refs.append(ref)
            return true
        }
        return false
    }

    private func installHandler() {
        guard !handlerInstalled else { return }
        handlerInstalled = true
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, event, _ in
            var id = EventHotKeyID()
            GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                              nil, MemoryLayout<EventHotKeyID>.size, nil, &id)
            let key = id.id
            DispatchQueue.main.async { HotKeys.shared.actions[key]?() }
            return noErr
        }, 1, &spec, nil, nil)
    }
}
