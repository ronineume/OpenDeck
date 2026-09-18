import AppKit
import Carbon.HIToolbox

/// A recorded key combination, stored as Carbon key code + modifier flags.
struct HotKeySpec: Equatable, Codable {
    var keyCode: UInt32
    var modifiers: UInt32

    static let optionSpace = HotKeySpec(keyCode: UInt32(kVK_Space), modifiers: UInt32(optionKey))
    static let controlSpace = HotKeySpec(keyCode: UInt32(kVK_Space), modifiers: UInt32(controlKey))
    static let commandShiftSpace = HotKeySpec(keyCode: UInt32(kVK_Space), modifiers: UInt32(cmdKey | shiftKey))
    static let f4 = HotKeySpec(keyCode: UInt32(kVK_F4), modifiers: 0)

    /// Named presets offered as one-click buttons in settings.
    static let presets: [(String, HotKeySpec)] = [
        ("⌥ Space", .optionSpace),
        ("⌃ Space", .controlSpace),
        ("⌘ ⇧ Space", .commandShiftSpace),
        ("F4", .f4),
    ]

    /// Modifier symbols in Apple's canonical order.
    var modifierSymbols: String {
        var out = ""
        if modifiers & UInt32(controlKey) != 0 { out += "⌃" }
        if modifiers & UInt32(optionKey) != 0 { out += "⌥" }
        if modifiers & UInt32(shiftKey) != 0 { out += "⇧" }
        if modifiers & UInt32(cmdKey) != 0 { out += "⌘" }
        return out
    }

    var keyName: String { Self.name(for: keyCode) }

    var displayString: String {
        let symbols = modifierSymbols
        return symbols.isEmpty ? keyName : "\(symbols) \(keyName)"
    }

    /// Build a spec from a recorded NSEvent.
    static func from(event: NSEvent) -> HotKeySpec? {
        let flags = event.modifierFlags
        var carbon: UInt32 = 0
        if flags.contains(.control) { carbon |= UInt32(controlKey) }
        if flags.contains(.option) { carbon |= UInt32(optionKey) }
        if flags.contains(.shift) { carbon |= UInt32(shiftKey) }
        if flags.contains(.command) { carbon |= UInt32(cmdKey) }

        let code = UInt32(event.keyCode)
        // Refuse bare modifiers and Escape (used to cancel recording).
        if code == UInt32(kVK_Escape) { return nil }
        if [kVK_Command, kVK_Shift, kVK_Option, kVK_Control,
            kVK_RightCommand, kVK_RightShift, kVK_RightOption, kVK_RightControl].map(UInt32.init).contains(code) {
            return nil
        }
        // A function key is usable on its own; a letter key is not.
        let isFunctionKey = (UInt32(kVK_F1)...UInt32(kVK_F20)).contains(code)
        if carbon == 0 && !isFunctionKey { return nil }

        return HotKeySpec(keyCode: code, modifiers: carbon)
    }

    /// Virtual key code → readable name.
    static func name(for code: UInt32) -> String {
        let table: [Int: String] = [
            kVK_Space: "Space", kVK_Return: "↩", kVK_Tab: "⇥", kVK_Delete: "⌫",
            kVK_ForwardDelete: "⌦", kVK_Escape: "⎋", kVK_Home: "↖", kVK_End: "↘",
            kVK_PageUp: "⇞", kVK_PageDown: "⇟", kVK_UpArrow: "↑", kVK_DownArrow: "↓",
            kVK_LeftArrow: "←", kVK_RightArrow: "→",
            kVK_ANSI_A: "A", kVK_ANSI_B: "B", kVK_ANSI_C: "C", kVK_ANSI_D: "D",
            kVK_ANSI_E: "E", kVK_ANSI_F: "F", kVK_ANSI_G: "G", kVK_ANSI_H: "H",
            kVK_ANSI_I: "I", kVK_ANSI_J: "J", kVK_ANSI_K: "K", kVK_ANSI_L: "L",
            kVK_ANSI_M: "M", kVK_ANSI_N: "N", kVK_ANSI_O: "O", kVK_ANSI_P: "P",
            kVK_ANSI_Q: "Q", kVK_ANSI_R: "R", kVK_ANSI_S: "S", kVK_ANSI_T: "T",
            kVK_ANSI_U: "U", kVK_ANSI_V: "V", kVK_ANSI_W: "W", kVK_ANSI_X: "X",
            kVK_ANSI_Y: "Y", kVK_ANSI_Z: "Z",
            kVK_ANSI_0: "0", kVK_ANSI_1: "1", kVK_ANSI_2: "2", kVK_ANSI_3: "3",
            kVK_ANSI_4: "4", kVK_ANSI_5: "5", kVK_ANSI_6: "6", kVK_ANSI_7: "7",
            kVK_ANSI_8: "8", kVK_ANSI_9: "9",
            kVK_ANSI_Minus: "-", kVK_ANSI_Equal: "=", kVK_ANSI_LeftBracket: "[",
            kVK_ANSI_RightBracket: "]", kVK_ANSI_Backslash: "\\", kVK_ANSI_Semicolon: ";",
            kVK_ANSI_Quote: "'", kVK_ANSI_Comma: ",", kVK_ANSI_Period: ".",
            kVK_ANSI_Slash: "/", kVK_ANSI_Grave: "`",
            kVK_F1: "F1", kVK_F2: "F2", kVK_F3: "F3", kVK_F4: "F4", kVK_F5: "F5",
            kVK_F6: "F6", kVK_F7: "F7", kVK_F8: "F8", kVK_F9: "F9", kVK_F10: "F10",
            kVK_F11: "F11", kVK_F12: "F12", kVK_F13: "F13", kVK_F14: "F14",
            kVK_F15: "F15", kVK_F16: "F16", kVK_F17: "F17", kVK_F18: "F18",
            kVK_F19: "F19", kVK_F20: "F20",
        ]
        return table[Int(code)] ?? "Key \(code)"
    }
}

/// Registers a system-wide hot key via Carbon.
///
/// Carbon hot keys are used rather than an event tap because they work without
/// Accessibility permission and the system hands the key to us first.
final class HotKeyManager {
    static let shared = HotKeyManager()

    private var hotKeyRef: EventHotKeyRef?
    private var eventHandler: EventHandlerRef?
    fileprivate var onFire: (() -> Void)?
    /// Set when registration fails, surfaced in the settings window.
    private(set) var lastError: String?

    private init() {}

    /// Returns false when the combination is already taken by another app.
    @discardableResult
    func register(_ spec: HotKeySpec?, onFire: @escaping () -> Void) -> Bool {
        unregister()
        lastError = nil
        guard let spec else { return true }
        self.onFire = onFire

        var eventType = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )
        let installStatus = InstallEventHandler(
            GetApplicationEventTarget(),
            { _, _, _ -> OSStatus in
                DispatchQueue.main.async { HotKeyManager.shared.onFire?() }
                return noErr
            },
            1,
            &eventType,
            nil,
            &eventHandler
        )
        guard installStatus == noErr else {
            lastError = "Could not install the hot key handler."
            NSLog("LaunchDeck: InstallEventHandler failed (\(installStatus))")
            return false
        }

        let hotKeyID = EventHotKeyID(signature: OSType(0x4C44_434B), id: 1) // 'LDCK'
        let status = RegisterEventHotKey(
            spec.keyCode,
            spec.modifiers,
            hotKeyID,
            GetApplicationEventTarget(),
            0,
            &hotKeyRef
        )
        if status != noErr {
            NSLog("LaunchDeck: RegisterEventHotKey failed (\(status)) for \(spec.displayString)")
            lastError = "\(spec.displayString) is already taken by another app."
            return false
        }
        return true
    }

    func unregister() {
        if let hotKeyRef {
            UnregisterEventHotKey(hotKeyRef)
            self.hotKeyRef = nil
        }
        if let eventHandler {
            RemoveEventHandler(eventHandler)
            self.eventHandler = nil
        }
        onFire = nil
    }
}
