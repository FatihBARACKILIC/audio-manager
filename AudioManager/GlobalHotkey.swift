import AppKit
import Carbon.HIToolbox

/// A keyboard shortcut the user can trigger from any app.
///
/// Stored as a printable string ("cmd+shift+v") so the settings file stays readable and
/// so a shortcut can be typed in by hand without a binary blob.
struct KeyboardShortcut: Equatable, Sendable {
    var keyCode: UInt32
    var modifiers: UInt32
    var displayString: String

    /// Parses "cmd+shift+v" style text. Returns `nil` for anything unusable, which the
    /// settings UI treats as "no shortcut" rather than failing.
    static func parse(_ text: String?) -> KeyboardShortcut? {
        guard let text, !text.isEmpty else { return nil }

        var modifiers: UInt32 = 0
        var key: String?

        for rawPart in text.lowercased().split(separator: "+") {
            let part = rawPart.trimmingCharacters(in: .whitespaces)
            switch part {
            case "cmd", "command", "⌘": modifiers |= UInt32(cmdKey)
            case "shift", "⇧": modifiers |= UInt32(shiftKey)
            case "opt", "option", "alt", "⌥": modifiers |= UInt32(optionKey)
            case "ctrl", "control", "⌃": modifiers |= UInt32(controlKey)
            default: key = part
            }
        }

        guard let key, let keyCode = keyCodes[key], modifiers != 0 else { return nil }
        return KeyboardShortcut(keyCode: keyCode, modifiers: modifiers, displayString: display(for: text))
    }

    private static func display(for text: String) -> String {
        var result = ""
        var key = ""
        for rawPart in text.lowercased().split(separator: "+") {
            switch rawPart.trimmingCharacters(in: .whitespaces) {
            case "ctrl", "control", "⌃": result += "⌃"
            case "opt", "option", "alt", "⌥": result += "⌥"
            case "shift", "⇧": result += "⇧"
            case "cmd", "command", "⌘": result += "⌘"
            case let other: key = other.uppercased()
            }
        }
        return result + key
    }

    /// Only the keys worth binding: letters, digits and function keys.
    private static let keyCodes: [String: UInt32] = {
        var codes: [String: UInt32] = [
            "a": 0, "s": 1, "d": 2, "f": 3, "h": 4, "g": 5, "z": 6, "x": 7, "c": 8, "v": 9,
            "b": 11, "q": 12, "w": 13, "e": 14, "r": 15, "y": 16, "t": 17,
            "1": 18, "2": 19, "3": 20, "4": 21, "6": 22, "5": 23, "9": 25, "7": 26, "8": 28, "0": 29,
            "o": 31, "u": 32, "i": 34, "p": 35, "l": 37, "j": 38, "k": 40, "n": 45, "m": 46,
            "space": 49,
        ]
        let functionKeys: [String: UInt32] = [
            "f1": 122, "f2": 120, "f3": 99, "f4": 118, "f5": 96, "f6": 97,
            "f7": 98, "f8": 100, "f9": 101, "f10": 109, "f11": 103, "f12": 111,
        ]
        codes.merge(functionKeys) { current, _ in current }
        return codes
    }()
}

/// Registers global shortcuts through Carbon's hot key API.
///
/// Carbon is the only public way to get a system-wide shortcut without asking for
/// accessibility access, and it works inside the sandbox. The surface used here is tiny
/// and stable, and it is wrapped so nothing else in the app has to know about it.
@MainActor
final class GlobalHotkeyCenter {
    private struct Registration {
        var ref: EventHotKeyRef?
        var action: () -> Void
    }

    private var registrations: [UInt32: Registration] = [:]
    private var eventHandler: EventHandlerRef?
    private var nextID: UInt32 = 1

    /// Handlers are looked up from the Carbon callback, which cannot capture context.
    private static var shared: GlobalHotkeyCenter?

    init() {
        GlobalHotkeyCenter.shared = self
    }

    deinit {
        // Carbon objects are released in `unregisterAll`, which the delegate calls on
        // quit; `deinit` on the main actor cannot call actor-isolated code.
    }

    /// Replaces any existing registration for `name` with the given shortcut.
    @discardableResult
    func register(_ shortcut: KeyboardShortcut?, action: @escaping () -> Void) -> UInt32? {
        installHandlerIfNeeded()

        guard let shortcut else { return nil }

        let id = nextID
        nextID += 1

        var hotKeyID = EventHotKeyID(signature: OSType(0x414D_4752), id: id) // 'AMGR'
        var reference: EventHotKeyRef?
        let status = RegisterEventHotKey(
            shortcut.keyCode,
            shortcut.modifiers,
            hotKeyID,
            GetEventDispatcherTarget(),
            0,
            &reference
        )

        guard status == noErr, let reference else { return nil }
        registrations[id] = Registration(ref: reference, action: action)
        _ = hotKeyID
        return id
    }

    func unregisterAll() {
        for registration in registrations.values {
            if let ref = registration.ref {
                UnregisterEventHotKey(ref)
            }
        }
        registrations.removeAll()

        if let eventHandler {
            RemoveEventHandler(eventHandler)
            self.eventHandler = nil
        }
    }

    private func installHandlerIfNeeded() {
        guard eventHandler == nil else { return }

        var eventType = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )

        InstallEventHandler(
            GetEventDispatcherTarget(),
            { _, event, _ -> OSStatus in
                var hotKeyID = EventHotKeyID()
                let status = GetEventParameter(
                    event,
                    EventParamName(kEventParamDirectObject),
                    EventParamType(typeEventHotKeyID),
                    nil,
                    MemoryLayout<EventHotKeyID>.size,
                    nil,
                    &hotKeyID
                )
                guard status == noErr else { return status }

                let id = hotKeyID.id
                DispatchQueue.main.async {
                    MainActor.assumeIsolated {
                        GlobalHotkeyCenter.shared?.registrations[id]?.action()
                    }
                }
                return noErr
            },
            1,
            &eventType,
            nil,
            &eventHandler
        )
    }
}
