import Foundation

/// Modifier keys of a shortcut.  Independent of AppKit so shortcut sets can be parsed, compared
/// and checked for conflicts in tests without a window; `KeyEquivalentResolver` maps them onto
/// `NSEvent.ModifierFlags`.
struct KeyModifiers: OptionSet, Hashable, Sendable {
    let rawValue: UInt8

    static let command = KeyModifiers(rawValue: 1 << 0)
    static let shift = KeyModifiers(rawValue: 1 << 1)
    static let option = KeyModifiers(rawValue: 1 << 2)
    static let control = KeyModifiers(rawValue: 1 << 3)

    /// Canonical order and spelling of each modifier in the `"cmd+shift+k"` form.
    static let canonicalOrder: [(KeyModifiers, String)] = [
        (.command, "cmd"), (.control, "ctrl"), (.option, "opt"), (.shift, "shift"),
    ]

    /// Every spelling `KeyEquivalent(parsing:)` accepts.
    static let spellings: [String: KeyModifiers] = [
        "cmd": .command, "command": .command, "⌘": .command,
        "shift": .shift, "⇧": .shift,
        "opt": .option, "option": .option, "alt": .option, "⌥": .option,
        "ctrl": .control, "control": .control, "ctl": .control, "⌃": .control,
    ]

    /// The macOS glyphs, in the order the menu bar draws them.
    var glyphs: String {
        var result = ""
        if contains(.control) { result += "⌃" }
        if contains(.option) { result += "⌥" }
        if contains(.shift) { result += "⇧" }
        if contains(.command) { result += "⌘" }
        return result
    }
}

/// A key plus modifiers, in the canonical text form shortcut sets store: `"cmd+shift+k"`,
/// `"p"`, `"cmd+="`, `"delete"`.  The key is one character (letters lowercased) or one of
/// `KeyEquivalent.namedKeys`.
struct KeyEquivalent: Hashable, Sendable, CustomStringConvertible {
    let key: String
    let modifiers: KeyModifiers

    /// Keys that have no printable character.  Values are the Unicode scalars AppKit uses in
    /// `NSMenuItem.keyEquivalent` (`NSEvent.SpecialKey` and the ASCII control characters).
    static let namedKeys: [String: Unicode.Scalar] = [
        "return": "\r", "tab": "\t", "space": " ", "escape": "\u{1B}", "delete": "\u{7F}",
        "forwarddelete": "\u{F728}", "clear": "\u{F739}",
        "left": "\u{F702}", "right": "\u{F703}", "up": "\u{F700}", "down": "\u{F701}",
        "home": "\u{F729}", "end": "\u{F72B}", "pageup": "\u{F72C}", "pagedown": "\u{F72D}",
        "f1": "\u{F704}", "f2": "\u{F705}", "f3": "\u{F706}", "f4": "\u{F707}",
        "f5": "\u{F708}", "f6": "\u{F709}", "f7": "\u{F70A}", "f8": "\u{F70B}",
        "f9": "\u{F70C}", "f10": "\u{F70D}", "f11": "\u{F70E}", "f12": "\u{F70F}",
        "f13": "\u{F710}", "f14": "\u{F711}", "f15": "\u{F712}", "f16": "\u{F713}",
        "f17": "\u{F714}", "f18": "\u{F715}", "f19": "\u{F716}",
    ]

    /// How a named key is drawn beside a menu item or in the palette.
    static let namedKeyGlyphs: [String: String] = [
        "return": "↩", "tab": "⇥", "space": "␣", "escape": "⎋", "delete": "⌫",
        "forwarddelete": "⌦", "clear": "⌧", "left": "←", "right": "→", "up": "↑", "down": "↓",
        "home": "↖", "end": "↘", "pageup": "⇞", "pagedown": "⇟",
    ]

    /// - Parameter key: a single character or a named key; letters are stored lowercased so
    ///   `"K"` and `"k"` are the same key and shift is always explicit in `modifiers`.
    init(_ key: String, _ modifiers: KeyModifiers = []) {
        self.key = Self.normalize(key)
        self.modifiers = modifiers
    }

    /// `true` when `key` is one character or a known named key.
    var isValid: Bool {
        key.count == 1 || Self.namedKeys[key] != nil
    }

    /// `"cmd+shift+k"`: modifiers in canonical order, then the key.  `"cmd++"` is Command
    /// and the plus key.
    var canonical: String {
        var parts = KeyModifiers.canonicalOrder.filter { modifiers.contains($0.0) }.map(\.1)
        parts.append(key)
        return parts.joined(separator: "+")
    }

    /// `"⇧⌘K"`, `"⌫"`: the form the menu bar and the palette show.
    var displayString: String {
        modifiers.glyphs + (Self.namedKeyGlyphs[key] ?? key.uppercased())
    }

    /// The characters AppKit expects in `NSMenuItem.keyEquivalent` (also what the menu
    /// key-equivalent matcher receives from `NSEvent.charactersIgnoringModifiers`).
    var keyEquivalentCharacters: String {
        if let scalar = Self.namedKeys[key] { return String(Character(scalar)) }
        return key
    }

    var description: String { canonical }

    /// Parses the canonical form.  Modifier spellings are those in `KeyModifiers.spellings`,
    /// case-insensitively; the key is the last component.
    init(parsing string: String) throws {
        let trimmed = string.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { throw KeyEquivalentParseError.empty }
        var components = trimmed.split(separator: "+", omittingEmptySubsequences: false).map(String.init)
        var key: String
        if components.count >= 2, components[components.count - 1].isEmpty,
            components[components.count - 2].isEmpty
        {
            // "cmd++" or "+": the plus key itself.
            key = "+"
            components.removeLast(2)
        } else {
            key = components.removeLast()
        }
        var modifiers: KeyModifiers = []
        for component in components {
            guard let modifier = KeyModifiers.spellings[component.lowercased()] else {
                throw KeyEquivalentParseError.unknownModifier(component, in: string)
            }
            modifiers.insert(modifier)
        }
        let equivalent = KeyEquivalent(key, modifiers)
        guard equivalent.isValid else { throw KeyEquivalentParseError.invalidKey(key, in: string) }
        self = equivalent
    }

    private static func normalize(_ key: String) -> String {
        let trimmed = key.trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty { return key == " " ? "space" : "" }
        return trimmed.lowercased()
    }
}

enum KeyEquivalentParseError: Error, Equatable, CustomStringConvertible {
    case empty
    case unknownModifier(String, in: String)
    case invalidKey(String, in: String)

    var description: String {
        switch self {
        case .empty: "empty shortcut"
        case let .unknownModifier(modifier, string): "unknown modifier \"\(modifier)\" in \"\(string)\""
        case let .invalidKey(key, string): "invalid key \"\(key)\" in \"\(string)\""
        }
    }
}

extension KeyEquivalent: Codable {
    init(from decoder: Decoder) throws {
        let string = try decoder.singleValueContainer().decode(String.self)
        do {
            try self.init(parsing: string)
        } catch {
            throw DecodingError.dataCorrupted(DecodingError.Context(
                codingPath: decoder.codingPath, debugDescription: "\(error)"
            ))
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(canonical)
    }
}
