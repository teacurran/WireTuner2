import AppKit
import Foundation
import Testing
@testable import WireTuner

@Suite struct KeyEquivalentTests {
    @Test func parsesCanonicalAndAliasSpellings() throws {
        let key = try KeyEquivalent(parsing: "cmd+shift+k")
        #expect(key == KeyEquivalent("k", [.command, .shift]))
        #expect(key.canonical == "cmd+shift+k")
        #expect(try KeyEquivalent(parsing: "Command+Shift+K") == key)
        #expect(try KeyEquivalent(parsing: "⌘+⇧+k") == key)
        #expect(try KeyEquivalent(parsing: "ctrl+opt+a") == KeyEquivalent("a", [.control, .option]))
        #expect(try KeyEquivalent(parsing: "control+alt+a").canonical == "ctrl+opt+a")
        #expect(try KeyEquivalent(parsing: "p") == KeyEquivalent("p"))
        #expect(try KeyEquivalent(parsing: "6").key == "6")
        #expect(try KeyEquivalent(parsing: " delete ") == KeyEquivalent("delete"))
        #expect(try KeyEquivalent(parsing: "cmd+=").key == "=")
    }

    @Test func parsesThePlusKey() throws {
        #expect(try KeyEquivalent(parsing: "cmd++") == KeyEquivalent("+", .command))
        #expect(try KeyEquivalent(parsing: "+") == KeyEquivalent("+"))
        #expect(KeyEquivalent("+", .command).canonical == "cmd++")
    }

    @Test func rejectsBadStrings() {
        #expect(throws: KeyEquivalentParseError.empty) { try KeyEquivalent(parsing: "  ") }
        #expect(throws: KeyEquivalentParseError.unknownModifier("bogus", in: "cmd+bogus+k")) {
            try KeyEquivalent(parsing: "cmd+bogus+k")
        }
        #expect(throws: KeyEquivalentParseError.invalidKey("kk", in: "cmd+kk")) { try KeyEquivalent(parsing: "cmd+kk") }
        #expect(throws: KeyEquivalentParseError.invalidKey("", in: "cmd+")) { try KeyEquivalent(parsing: "cmd+") }
        #expect(!KeyEquivalent("").isValid)
        #expect(KeyEquivalent(" ") == KeyEquivalent("space"))
        #expect(KeyEquivalentParseError.empty.description == "empty shortcut")
        #expect(KeyEquivalentParseError.unknownModifier("x", in: "x+a").description.contains("x+a"))
        #expect(KeyEquivalentParseError.invalidKey("ab", in: "ab").description.contains("ab"))
    }

    @Test func normalizesCase() {
        #expect(KeyEquivalent("K", .command) == KeyEquivalent("k", .command))
        #expect(KeyEquivalent("Delete").key == "delete")
        #expect(KeyEquivalent("?", .command).description == "cmd+?")
    }

    @Test func rendersGlyphsAndMenuCharacters() {
        #expect(KeyEquivalent("k", [.command, .shift, .option, .control]).displayString == "⌃⌥⇧⌘K")
        #expect(KeyEquivalent("delete").displayString == "⌫")
        #expect(KeyEquivalent("f5", .command).displayString == "⌘F5")
        #expect(KeyEquivalent("f5").keyEquivalentCharacters == "\u{F708}")
        #expect(KeyEquivalent("return").keyEquivalentCharacters == "\r")
        #expect(KeyEquivalent("a").keyEquivalentCharacters == "a")
    }

    @Test func roundTripsThroughJSON() throws {
        let keys = [KeyEquivalent("k", [.command, .shift]), KeyEquivalent("delete"), KeyEquivalent("+", .command)]
        let data = try JSONEncoder().encode(keys)
        #expect(String(decoding: data, as: UTF8.self) == "[\"cmd+shift+k\",\"delete\",\"cmd++\"]")
        #expect(try JSONDecoder().decode([KeyEquivalent].self, from: data) == keys)
        let bad = Data("[\"cmd+bogus+k\"]".utf8)
        #expect(throws: DecodingError.self) { try JSONDecoder().decode([KeyEquivalent].self, from: bad) }
    }

    @Test func resolvesToMenuKeys() {
        let redo = KeyEquivalentResolver.menuKey(for: KeyEquivalent("z", [.command, .shift]))
        #expect(redo == KeyEquivalentResolver.MenuKey(keyEquivalent: "z", modifierMask: [.command, .shift]))
        let delete = KeyEquivalentResolver.menuKey(for: KeyEquivalent("delete"))
        #expect(delete == KeyEquivalentResolver.MenuKey(keyEquivalent: "\u{7F}", modifierMask: []))
        #expect(KeyEquivalentResolver.modifierFlags([.option, .control]) == [.option, .control])
        #expect(KeyEquivalentResolver.modifiers([.command, .shift, .function]) == [.command, .shift])

        let set = ShortcutSet(id: "s", name: "S", bindings: [ShortcutBinding(commandID: "a", keys: [KeyEquivalent("a", .command)])])
        #expect(KeyEquivalentResolver.menuKey(for: "a", in: set).keyEquivalent == "a")
        #expect(KeyEquivalentResolver.menuKey(for: "b", in: set) == KeyEquivalentResolver.MenuKey(keyEquivalent: "", modifierMask: []))
    }

    @Test @MainActor func appliesToMenuItems() {
        let item = NSMenuItem(title: "X", action: nil, keyEquivalent: "q")
        KeyEquivalentResolver.apply(KeyEquivalent("k", [.command, .option]), to: item)
        #expect(item.keyEquivalent == "k")
        #expect(item.keyEquivalentModifierMask == [.command, .option])
        KeyEquivalentResolver.apply(nil, to: item)
        #expect(item.keyEquivalent == "")
        #expect(item.keyEquivalentModifierMask == [])
    }

    @Test func readsKeyPresses() {
        #expect(KeyEquivalentResolver.keyEquivalent(charactersIgnoringModifiers: "k", modifierFlags: [.command, .shift]) == KeyEquivalent("k", [.command, .shift]))
        #expect(KeyEquivalentResolver.keyEquivalent(charactersIgnoringModifiers: "\u{7F}", modifierFlags: []) == KeyEquivalent("delete"))
        #expect(KeyEquivalentResolver.keyEquivalent(charactersIgnoringModifiers: "\u{F704}", modifierFlags: [.function]) == KeyEquivalent("f1"))
        #expect(KeyEquivalentResolver.keyEquivalent(charactersIgnoringModifiers: "", modifierFlags: []) == nil)
        #expect(KeyEquivalentResolver.keyEquivalent(charactersIgnoringModifiers: "ab", modifierFlags: []) == nil)
    }
}
