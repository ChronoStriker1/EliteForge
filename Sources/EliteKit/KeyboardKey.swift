import Foundation

/// A keyboard key identified by its USB HID usage (keyboard page 0x07).
/// The Accessories app stores keyboard mappings as these usages: "F" is 0x09.
public struct KeyboardKey: Hashable, Codable, Sendable, Identifiable {
    public var usage: UInt8
    public var id: UInt8 { usage }

    public init(usage: UInt8) { self.usage = usage }

    public var label: String { Self.names[usage] ?? String(format: "Key 0x%02X", usage) }

    public static let all: [KeyboardKey] = names.keys.sorted().map(KeyboardKey.init(usage:))

    static let names: [UInt8: String] = {
        var table: [UInt8: String] = [:]
        for (index, letter) in "ABCDEFGHIJKLMNOPQRSTUVWXYZ".enumerated() {
            table[UInt8(0x04 + index)] = String(letter)
        }
        for (index, digit) in "1234567890".enumerated() {
            table[UInt8(0x1E + index)] = String(digit)
        }
        let named: [UInt8: String] = [
            0x28: "Return", 0x29: "Escape", 0x2A: "Backspace", 0x2B: "Tab", 0x2C: "Space",
            0x2D: "-", 0x2E: "=", 0x2F: "[", 0x30: "]", 0x31: "\\", 0x33: ";", 0x34: "'",
            0x35: "`", 0x36: ",", 0x37: ".", 0x38: "/", 0x39: "Caps Lock",
            0x46: "Print Screen", 0x47: "Scroll Lock", 0x48: "Pause", 0x49: "Insert",
            0x4A: "Home", 0x4B: "Page Up", 0x4C: "Delete", 0x4D: "End", 0x4E: "Page Down",
            0x4F: "Right Arrow", 0x50: "Left Arrow", 0x51: "Down Arrow", 0x52: "Up Arrow",
            0x53: "Num Lock", 0x54: "Keypad /", 0x55: "Keypad *", 0x56: "Keypad -", 0x57: "Keypad +",
            0x58: "Keypad Enter", 0x59: "Keypad 1", 0x5A: "Keypad 2", 0x5B: "Keypad 3", 0x5C: "Keypad 4",
            0x5D: "Keypad 5", 0x5E: "Keypad 6", 0x5F: "Keypad 7", 0x60: "Keypad 8", 0x61: "Keypad 9",
            0x62: "Keypad 0", 0x63: "Keypad .", 0x65: "Menu",
            0xE0: "Left Control", 0xE1: "Left Shift", 0xE2: "Left Alt", 0xE3: "Left Windows",
            0xE4: "Right Control", 0xE5: "Right Shift", 0xE6: "Right Alt", 0xE7: "Right Windows",
        ]
        table.merge(named) { _, new in new }
        for index in 0..<12 {
            table[UInt8(0x3A + index)] = "F\(index + 1)"
        }
        return table
    }()
}

/// Keyboard modifiers held with a key. The controller ORs them into the HID
/// report's modifier byte (firmware 0x1004ed10), so the bits follow it. The
/// values are inferred from the order of the Accessories app's modifier
/// names and the HID convention, not verified on hardware.
public struct KeyModifiers: OptionSet, Hashable, Codable, Sendable {
    public let rawValue: UInt8
    public init(rawValue: UInt8) { self.rawValue = rawValue }

    public static let control = KeyModifiers(rawValue: 0x01)
    public static let shift = KeyModifiers(rawValue: 0x02)
    public static let alt = KeyModifiers(rawValue: 0x04)
    public static let windows = KeyModifiers(rawValue: 0x08)

    /// Each modifier with its name, in the order labels list them.
    public static let named: [(KeyModifiers, String)] = [(.control, "Ctrl"), (.shift, "Shift"), (.alt, "Alt"), (.windows, "Win")]
}

/// A key and the modifiers sent with it.
public struct KeyCombination: Hashable, Codable, Sendable {
    public var key: KeyboardKey
    public var modifiers: KeyModifiers

    public init(_ key: KeyboardKey, modifiers: KeyModifiers = []) {
        self.key = key
        self.modifiers = modifiers
    }

    /// "Ctrl+Shift+F".
    public var label: String {
        (KeyModifiers.named.filter { modifiers.contains($0.0) }.map(\.1) + [key.label]).joined(separator: "+")
    }

    // Stored flat, as {"usage": 9, "modifiers": 3}, so setups saved before
    // modifiers, which hold just the key, still load.
    private enum CodingKeys: String, CodingKey { case usage, modifiers }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        key = KeyboardKey(usage: try container.decode(UInt8.self, forKey: .usage))
        modifiers = try container.decodeIfPresent(KeyModifiers.self, forKey: .modifiers) ?? []
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(key.usage, forKey: .usage)
        try container.encode(modifiers, forKey: .modifiers)
    }
}
