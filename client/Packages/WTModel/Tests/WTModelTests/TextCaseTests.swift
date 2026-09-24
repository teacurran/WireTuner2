import Foundation
import Testing
import WTCRDT
import WTGeometry
@testable import WTModel
import WTProto
import WTText

/// TYPE-015 Convert Case (editing-text.adoc, "Converting case").
@Suite struct TextCaseTests {
    static func convert(_ text: String, _ conversion: CaseConversion, from: Int? = nil, to: Int? = nil,
                        exceptions: [CaseExceptionInfo] = []) throws -> (Replica, OpID) {
        var a = Replica(1)
        if !exceptions.isEmpty { try a.perform(SetTextCaseSettings(TextCaseSettings(exceptions: exceptions))) }
        let node = try TextFixture.block(&a, text)
        let start = from.map { TextFixture.at(a, node, $0) } ?? .start
        let end = to.map { TextFixture.at(a, node, $0) } ?? .end
        try a.perform(ConvertCase(node: node, from: start, to: end, conversion: conversion))
        return (a, node)
    }

    static func string(_ text: String, _ conversion: CaseConversion, exceptions: [CaseExceptionInfo] = []) throws -> String {
        let (a, node) = try convert(text, conversion, exceptions: exceptions)
        return TextFixture.text(a, node).string
    }

    @Test func eachRewritingConversion() throws {
        #expect(try Self.string("Hello wORLD", .uppercase) == "HELLO WORLD")
        #expect(try Self.string("Hello wORLD", .lowercase) == "hello world")
        #expect(try Self.string("the qUICK brown-fox's tail", .title) == "The Quick Brown-Fox's Tail")
        #expect(try Self.string("hello THERE. how are you? fine!  ok\nnext line 3 apples. \"quoted\" start", .sentence)
                == "Hello there. How are you? Fine!  Ok\nNext line 3 apples. \"Quoted\" start")
        // Mapping that changes length: ß uppercases to SS.
        #expect(try Self.string("straße", .uppercase) == "STRASSE")
        #expect(CaseConversion.allCases.map(\.title) == ["Uppercase", "Lowercase", "Small Caps", "Title", "Sentence"])
    }

    @Test func titleCaseKeepsAnExceptedWordsSpelling() throws {
        let iPhone = CaseExceptionInfo(word: "iPhone", conversions: [.title, .uppercase])
        #expect(try Self.string("the iPhone", .title, exceptions: [iPhone]) == "The iPhone")
        #expect(try Self.string("the IPHONE", .title, exceptions: [iPhone]) == "The iPhone")
        #expect(try Self.string("an iphone", .uppercase, exceptions: [iPhone]) == "AN iPhone")
        // Not excepted under Lowercase.
        #expect(try Self.string("the iPhone", .lowercase, exceptions: [iPhone]) == "the iphone")
        // An exception of another length leaves the word to the conversion.
        #expect(try Self.string("the iPhones", .title, exceptions: [iPhone]) == "The Iphones")
        #expect(try Self.string("the iPhone", .title) == "The Iphone")
    }

    @Test func onlyTheLettersThatChangeAreRewritten() throws {
        var a = Replica(1)
        let node = try TextFixture.block(&a, "aBc dEF")
        let before = TextFixture.text(a, node)
        let change = try #require(try a.perform(ConvertCase(node: node, from: .start, to: .end, conversion: .uppercase)))
        #expect(change.label == "Convert case")
        // Two runs change (a, c ... d) -- "a", "c", then "d": a, c are not adjacent.
        let deletes = change.ops.filter { if case .textDelete? = $0.op { true } else { false } }
        let inserts = change.ops.compactMap { op -> Wiretuner_Doc_V1_TextInsert? in if case .textInsert(let i)? = op.op { i } else { nil } }
        #expect(inserts.map(\.chars) == ["A", "C", "D"])
        #expect(deletes.count == 3)
        // The replacement's origins: the live character before the run, and the run's first character.
        #expect(OpID(element: inserts[1].rightOrigin) == before.chars[2])
        #expect(OpID(element: inserts[1].leftOrigin) == before.chars[1])
        let after = TextFixture.text(a, node)
        #expect(after.string == "ABC DEF")
        #expect(after.chars[1] == before.chars[1] && after.chars[5] == before.chars[5])
        // Nothing to change writes nothing; an empty range writes nothing.
        #expect(try a.perform(ConvertCase(node: node, from: .start, to: .end, conversion: .uppercase)) == nil)
        #expect(try a.perform(ConvertCase(node: node, from: .start, to: .start, conversion: .lowercase)) == nil)
        #expect(throws: TextEditError.notText(OpID(counter: 99, replica: 9))) {
            try a.perform(ConvertCase(node: OpID(counter: 99, replica: 9), from: .start, to: .end, conversion: .title))
        }
        // Undo restores the old spelling.
        a.undo()
        #expect(TextFixture.text(a, node).string == "aBc dEF")
    }

    @Test func aBoldMarkCoveringExactlyTheWordStillCoversIt() throws {
        var a = Replica(1)
        let node = try TextFixture.block(&a, "say hello now")
        let bold = TextFixture.mark { $0.fontStyle = "Bold" }
        try a.perform(ApplyMark(node: node, from: TextFixture.at(a, node, 4), to: TextFixture.at(a, node, 9), value: bold))
        // A kerning pair inside the word (non-expanding, anchored inside the run).
        let kern = TextFixture.mark { $0.kerning = 20 }
        try a.perform(ApplyMark(node: node, from: TextFixture.at(a, node, 6), to: TextFixture.at(a, node, 7), value: kern))
        try a.perform(ConvertCase(node: node, from: TextFixture.at(a, node, 4), to: TextFixture.at(a, node, 9), conversion: .uppercase))
        let text = TextFixture.text(a, node)
        #expect(text.string == "say HELLO now")
        for offset in 0..<text.length {
            #expect(text.values(at: offset).contains(bold) == (4..<9).contains(offset), "offset \(offset)")
            #expect(text.values(at: offset).contains(kern) == (offset == 6), "offset \(offset)")
        }
        // Typing at the end of the converted word continues the bold (expanding end).
        try a.perform(InsertText(node: node, text: "!", at: TextFixture.at(a, node, 9)))
        #expect(TextFixture.text(a, node).values(at: 9).contains(bold))
    }

    @Test func aMarkEndingJustBeforeTheRunDoesNotSpreadOverIt() throws {
        var a = Replica(1)
        let node = try TextFixture.block(&a, "ab cd")
        // Size 20 over "ab " ends before "c".
        try a.perform(ApplyMark(node: node, from: .start, to: TextFixture.at(a, node, 3), value: TextFixture.size(20)))
        try a.perform(ConvertCase(node: node, from: TextFixture.at(a, node, 3), to: .end, conversion: .uppercase))
        let text = TextFixture.text(a, node)
        #expect(text.string == "ab CD")
        #expect(TextFixture.sizes(text) == [20, 20, 20, nil, nil])
    }

    @Test func smallCapsIsAMarkThatTogglesAndSkipsExceptions() throws {
        var a = Replica(1)
        try a.perform(SetTextCaseSettings(TextCaseSettings(exceptions: [CaseExceptionInfo(word: "NASA", conversions: [.smallCaps])])))
        let node = try TextFixture.block(&a, "go nasa go")
        let change = try #require(try a.perform(ConvertCase(node: node, from: .start, to: .end, conversion: .smallCaps)))
        #expect(!change.ops.contains { if case .textInsert? = $0.op { true } else { false } })
        let smallCaps = TextFixture.mark { $0.case = .smallCaps }
        var text = TextFixture.text(a, node)
        #expect(text.string == "go nasa go")
        #expect((0..<text.length).map { text.values(at: $0).contains(smallCaps) }
                == [true, true, true, false, false, false, false, true, true, true])
        // Choosing it again removes it.
        try a.perform(ConvertCase(node: node, from: .start, to: .end, conversion: .smallCaps))
        text = TextFixture.text(a, node)
        #expect((0..<text.length).allSatisfy { !text.values(at: $0).contains(smallCaps) })
        // A range with no letters applies it.
        let digits = try TextFixture.block(&a, "123")
        try a.perform(ConvertCase(node: digits, from: .start, to: .end, conversion: .smallCaps))
        #expect(TextFixture.text(a, digits).values(at: 0).contains(smallCaps))
    }

    @Test func settingsAreReadWrittenAndDiffed() throws {
        var a = Replica(1)
        #expect(TextCaseSettings(a.state) == TextCaseSettings())
        #expect(TextCaseSettings(a.state).smallCapsPercent == 75)
        let change = try #require(try a.perform(SetTextCaseSettings(TextCaseSettings(smallCapsPercent: 80, exceptions: [
            CaseExceptionInfo(word: "iPhone", conversions: [.title]),
            CaseExceptionInfo(word: "NASA", conversions: [.lowercase, .sentence, .smallCaps]),
        ]))))
        #expect(change.label == "Convert Case Settings")
        var settings = TextCaseSettings(a.state)
        #expect(settings.smallCapsPercent == 80)
        #expect(settings.exceptions.map(\.word) == ["iPhone", "NASA"])
        #expect(settings.exceptions[1].conversions == [.lowercase, .sentence, .smallCaps])
        // Edit one, remove the other, add a third; the size unchanged writes no size.
        settings.exceptions[0].word = "iPad"
        settings.exceptions[0].conversions = [.uppercase, .title]
        settings.exceptions.remove(at: 1)
        settings.exceptions.append(CaseExceptionInfo(word: "macOS", conversions: [.title]))
        let edit = try #require(try a.perform(SetTextCaseSettings(settings)))
        #expect(!edit.ops.contains { op in
            if case .set(let set)? = op.op { set.paths.contains { $0 == TextSettingsFields.smallCapsPercent.proto } } else { false }
        })
        let read = TextCaseSettings(a.state)
        #expect(read.exceptions.map(\.word) == ["iPad", "macOS"])
        #expect(read.exceptions[0].conversions == [.uppercase, .title])
        // Unchanged: nothing written.
        #expect(try a.perform(SetTextCaseSettings(read)) == nil)
        // Invalid values throw.
        #expect(throws: TextEditError.invalidValue("smallCapsPercent")) { try a.perform(SetTextCaseSettings(TextCaseSettings(smallCapsPercent: 0))) }
        #expect(throws: TextEditError.invalidValue("word")) {
            try a.perform(SetTextCaseSettings(TextCaseSettings(exceptions: [CaseExceptionInfo(word: "", conversions: [])])))
        }
        #expect(throws: TextEditError.invalidValue("exception")) {
            try a.perform(SetTextCaseSettings(TextCaseSettings(exceptions: [CaseExceptionInfo(id: OpID(counter: 50, replica: 5), word: "x", conversions: [])])))
        }
    }

    @Test func smallCapsSizeReachesTheLayout() throws {
        var a = Replica(1)
        let node = try TextFixture.block(&a, "ab")
        try a.perform(ConvertCase(node: node, from: .start, to: .end, conversion: .smallCaps))
        try a.perform(SetTextCaseSettings(TextCaseSettings(smallCapsPercent: 60)))
        let text = TextFixture.text(a, node)
        let content = TextLayoutReading.content(text, context: TextReadingContext(node, in: a.state))
        #expect(content.runs.allSatisfy { $0.attributes.smallCaps && $0.attributes.smallCapsSize == 0.6 })
        // Without a context the WTText default holds.
        #expect(TextLayoutReading.content(text).runs[0].attributes.smallCapsSize == TextAttributes.smallCapsScale)
    }

    @Test func edgesOfTheRewrite() throws {
        // Title from inside a word: its first letter is not the word's.
        let (a, node) = try Self.convert("the iPhone", .title, from: 5)
        #expect(TextFixture.text(a, node).string == "the iphone")
        // A mark whose characters were all deleted, ending just before the run, does not spread over it.
        var b = Replica(1)
        let text = try TextFixture.block(&b, "abXcd")
        let bold = TextFixture.mark { $0.fontStyle = "Bold" }
        try b.perform(ApplyMark(node: text, from: TextFixture.at(b, text, 2), to: TextFixture.at(b, text, 3), value: bold))
        try b.perform(DeleteText(node: text, from: TextFixture.at(b, text, 2), to: TextFixture.at(b, text, 3)))
        try b.perform(ConvertCase(node: text, from: TextFixture.at(b, text, 2), to: .end, conversion: .uppercase))
        let converted = TextFixture.text(b, text)
        #expect(converted.string == "abCD")
        #expect((0..<converted.length).allSatisfy { !converted.values(at: $0).contains(bold) })
        // Small caps over a range where only some letters have it applies it to all.
        var c = Replica(1)
        let mixed = try TextFixture.block(&c, "abcd")
        try c.perform(ConvertCase(node: mixed, from: .start, to: TextFixture.at(c, mixed, 2), conversion: .smallCaps))
        try c.perform(ConvertCase(node: mixed, from: .start, to: .end, conversion: .smallCaps))
        let caps = TextFixture.text(c, mixed)
        #expect((0..<4).allSatisfy { caps.values(at: $0).contains(.with { $0.case = .smallCaps }) })
        // Every conversion flag of an exception is its own register.
        try c.perform(SetTextCaseSettings(TextCaseSettings(exceptions: [CaseExceptionInfo(word: "x", conversions: [.uppercase])])))
        var settings = TextCaseSettings(c.state)
        settings.exceptions[0].conversions = [.lowercase, .smallCaps, .title, .sentence]
        let change = try #require(try c.perform(SetTextCaseSettings(settings)))
        guard case .set(let set)? = change.ops.first?.op else { Issue.record("set"); return }
        #expect(set.paths.map { $0.segments.last!.field } == [3, 4, 5, 6, 7])
    }

    // MARK: Merge

    @Test func uppercaseVersusAnInsertInsideTheWordKeepsTheInsertedCharacters() throws {
        var pair = Pair()
        let node = try TextFixture.block(&pair.a, "hello world")
        pair.sync()
        try pair.a.perform(ConvertCase(node: node, from: .start, to: TextFixture.at(pair.a, node, 5), conversion: .uppercase))
        try pair.b.perform(InsertText(node: node, text: "XY", at: TextFixture.at(pair.b, node, 2)))
        pair.sync()
        #expect(pair.a.state.stateHash == pair.b.state.stateHash)
        let merged = TextFixture.text(pair.a, node).string
        #expect(merged == TextFixture.text(pair.b, node).string)
        // B's characters survive, after the replacement (they are anchored inside the tombstones).
        #expect(merged == "HELLOXY world")
    }

    @Test func concurrentExceptionEditsMergeAsASequence() throws {
        var pair = Pair()
        try pair.a.perform(SetTextCaseSettings(TextCaseSettings(exceptions: [CaseExceptionInfo(word: "iPhone", conversions: [.title])])))
        pair.sync()
        var fromA = TextCaseSettings(pair.a.state)
        fromA.exceptions.append(CaseExceptionInfo(word: "macOS", conversions: [.title]))
        fromA.exceptions[0].conversions = [.title, .uppercase]
        var fromB = TextCaseSettings(pair.b.state)
        fromB.exceptions.append(CaseExceptionInfo(word: "NASA", conversions: [.lowercase]))
        fromB.exceptions[0].word = "iPad"
        try pair.a.perform(SetTextCaseSettings(fromA))
        try pair.b.perform(SetTextCaseSettings(fromB))
        pair.sync()
        #expect(pair.a.state.stateHash == pair.b.state.stateHash)
        let merged = TextCaseSettings(pair.a.state)
        #expect(Set(merged.exceptions.map(\.word)) == ["iPad", "macOS", "NASA"])
        #expect(merged.exceptions.first { $0.word == "iPad" }?.conversions == [.title, .uppercase])
    }
}
