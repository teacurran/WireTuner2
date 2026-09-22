import AppKit

/// Maps the active shortcut set onto AppKit: `KeyEquivalent` to `NSMenuItem.keyEquivalent`
/// plus `keyEquivalentModifierMask`, and back from an `NSEvent` for key capture and conflict
/// checks.  The only AppKit types here are `NSEvent.ModifierFlags` and `NSMenuItem`.
enum KeyEquivalentResolver {
    struct MenuKey: Equatable {
        let keyEquivalent: String
        let modifierMask: NSEvent.ModifierFlags
    }

    static let modifierPairs: [(KeyModifiers, NSEvent.ModifierFlags)] = [
        (.command, .command), (.shift, .shift), (.option, .option), (.control, .control),
    ]

    static func modifierFlags(_ modifiers: KeyModifiers) -> NSEvent.ModifierFlags {
        modifierPairs.reduce(into: []) { flags, pair in
            if modifiers.contains(pair.0) { flags.insert(pair.1) }
        }
    }

    static func modifiers(_ flags: NSEvent.ModifierFlags) -> KeyModifiers {
        modifierPairs.reduce(into: []) { modifiers, pair in
            if flags.contains(pair.1) { modifiers.insert(pair.0) }
        }
    }

    static func menuKey(for key: KeyEquivalent) -> MenuKey {
        MenuKey(keyEquivalent: key.keyEquivalentCharacters, modifierMask: modifierFlags(key.modifiers))
    }

    /// The key the active set binds to `commandID`, as an `NSMenuItem` wants it.
    static func menuKey(for commandID: CommandID, in set: ShortcutSet) -> MenuKey {
        set.keyEquivalent(for: commandID).map(menuKey(for:)) ?? MenuKey(keyEquivalent: "", modifierMask: [])
    }

    static func apply(_ key: KeyEquivalent?, to item: NSMenuItem) {
        let menuKey = key.map(menuKey(for:)) ?? MenuKey(keyEquivalent: "", modifierMask: [])
        item.keyEquivalent = menuKey.keyEquivalent
        item.keyEquivalentModifierMask = menuKey.modifierMask
    }

    /// The shortcut a key press means, from the characters typed without modifiers and the
    /// modifier flags (what a key-capture field reads off `keyDown`).  `nil` when the
    /// characters are empty or more than one key.
    static func keyEquivalent(charactersIgnoringModifiers characters: String, modifierFlags flags: NSEvent.ModifierFlags) -> KeyEquivalent? {
        guard characters.unicodeScalars.count == 1, let scalar = characters.unicodeScalars.first else { return nil }
        let name = KeyEquivalent.namedKeys.first { $0.value == scalar }?.key
        let key = KeyEquivalent(name ?? characters, modifiers(flags))
        return key.isValid ? key : nil
    }
}
