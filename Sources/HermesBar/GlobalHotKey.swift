import AppKit
import Carbon.HIToolbox

// A tiny wrapper around Carbon's RegisterEventHotKey — the reliable, dependency
// -free way to get a system-wide hotkey on macOS. Requires the app to have
// Accessibility permission.
final class GlobalHotKey {
    private var hotKeyRef: EventHotKeyRef?
    private let signature: OSType = 0x484D4253   // 'HMBS'
    private let id: UInt32

    // ONE shared Carbon handler dispatches to every registered hotkey by id.
    // Per-instance handlers used to chain, and the last-installed one swallowed
    // the others' events (which broke the second hotkey). A single dispatcher
    // keyed by id fixes that completely.
    private static var handlers: [UInt32: () -> Void] = [:]
    private static var sharedInstalled = false

    init(id: UInt32 = 1) { self.id = id }

    func register(keyCode: UInt32, modifiers: UInt32, handler: @escaping () -> Void) {
        unregister()
        GlobalHotKey.installSharedHandler()
        GlobalHotKey.handlers[id] = handler
        let hotKeyID = EventHotKeyID(signature: signature, id: id)
        let status = RegisterEventHotKey(keyCode, modifiers, hotKeyID,
                                         GetApplicationEventTarget(), 0, &hotKeyRef)
        NSLog("[HermesBar] hotkey register id=\(id) keyCode=\(keyCode) mods=\(modifiers) register=\(status) ref=\(hotKeyRef != nil)")
    }

    func unregister() {
        if let ref = hotKeyRef {
            UnregisterEventHotKey(ref)
            hotKeyRef = nil
        }
        GlobalHotKey.handlers[id] = nil
    }

    private static func installSharedHandler() {
        guard !sharedInstalled else { return }
        sharedInstalled = true
        var eventType = EventTypeSpec(eventClass: OSType(kEventClassKeyboard),
                                      eventKind: OSType(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { (_, event, _) -> OSStatus in
            guard let event = event else { return noErr }
            var hkID = EventHotKeyID()
            GetEventParameter(event, EventParamName(kEventParamDirectObject),
                              EventParamType(typeEventHotKeyID), nil,
                              MemoryLayout<EventHotKeyID>.size, nil, &hkID)
            if let h = GlobalHotKey.handlers[hkID.id] {
                NSLog("[HermesBar] hotkey FIRED id=\(hkID.id)")
                DispatchQueue.main.async { h() }
            }
            return noErr
        }, 1, &eventType, nil, nil)
    }

    deinit { unregister() }
}

// Maps a handful of common virtual key codes to display names for the hotkey
// label. Falls back to "Key <code>" for anything not listed.
enum KeyNames {
    static func name(for keyCode: UInt32) -> String {
        switch Int(keyCode) {
        case kVK_ANSI_A: return "A"
        case kVK_ANSI_B: return "B"
        case kVK_ANSI_C: return "C"
        case kVK_ANSI_D: return "D"
        case kVK_ANSI_E: return "E"
        case kVK_ANSI_F: return "F"
        case kVK_ANSI_G: return "G"
        case kVK_ANSI_H: return "H"
        case kVK_ANSI_I: return "I"
        case kVK_ANSI_J: return "J"
        case kVK_ANSI_K: return "K"
        case kVK_ANSI_L: return "L"
        case kVK_ANSI_M: return "M"
        case kVK_ANSI_N: return "N"
        case kVK_ANSI_O: return "O"
        case kVK_ANSI_P: return "P"
        case kVK_ANSI_Q: return "Q"
        case kVK_ANSI_R: return "R"
        case kVK_ANSI_S: return "S"
        case kVK_ANSI_T: return "T"
        case kVK_ANSI_U: return "U"
        case kVK_ANSI_V: return "V"
        case kVK_ANSI_W: return "W"
        case kVK_ANSI_X: return "X"
        case kVK_ANSI_Y: return "Y"
        case kVK_ANSI_Z: return "Z"
        case kVK_ANSI_0: return "0"
        case kVK_ANSI_1: return "1"
        case kVK_ANSI_2: return "2"
        case kVK_ANSI_3: return "3"
        case kVK_ANSI_4: return "4"
        case kVK_ANSI_5: return "5"
        case kVK_ANSI_6: return "6"
        case kVK_ANSI_7: return "7"
        case kVK_ANSI_8: return "8"
        case kVK_ANSI_9: return "9"
        case kVK_Space: return "Space"
        case kVK_Return: return "↩"
        case kVK_Escape: return "⎋"
        case kVK_Tab: return "⇥"
        case kVK_Delete: return "⌫"
        case kVK_ANSI_LeftBracket: return "["
        case kVK_ANSI_RightBracket: return "]"
        case kVK_ANSI_Semicolon: return ";"
        case kVK_ANSI_Quote: return "'"
        case kVK_ANSI_Comma: return ","
        case kVK_ANSI_Period: return "."
        case kVK_ANSI_Slash: return "/"
        case kVK_ANSI_Backslash: return "\\"
        case kVK_ANSI_Minus: return "-"
        case kVK_ANSI_Equal: return "="
        case kVK_ANSI_Grave: return "`"
        case kVK_LeftArrow: return "←"
        case kVK_RightArrow: return "→"
        case kVK_UpArrow: return "↑"
        case kVK_DownArrow: return "↓"
        default: return "Key \(keyCode)"
        }
    }
}
