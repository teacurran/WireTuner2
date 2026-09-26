import AppKit
import Testing
import WTCRDT
import WTGeometry
import WTModel
import WTProto
import WTRender
@testable import WireTuner

/// LIB-025: the Text tool inside a symbol instance (library.adoc, "Text tool inside an instance"):
/// a click finds the instance's text block through its transform, typing writes the instance's
/// `TEXT` override (the first keystroke copying the master's text), the caret and selection are
/// drawn at the instance's placement, and an override emptied by editing is reset when editing
/// ends.
@Suite(.serialized) @MainActor struct SymbolInstanceTextTests {
    typealias Fixture = TextToolTests.Fixture

    /// A text block "Label" at (50, 50) turned into a symbol, its instance made in place.
    static func instance(_ fixture: Fixture) async throws -> (instance: OpID, master: OpID) {
        let block = try #require(await fixture.document.addText("Label", at: Point(x: 50, y: 50)))
        let change = try #require(await fixture.document.perform(ConvertToSymbol([block])).value)
        await fixture.settle()
        let instance = try #require(change.createdObjects.first { fixture.document.state.nodeKind($0) == .instance })
        let master = try #require(Symbols.resolvedArtwork(of: instance, in: fixture.document.state)?.textBlocks.first)
        return (instance, master)
    }

    static func shown(_ fixture: Fixture, _ instance: OpID, _ master: OpID) -> String? {
        Symbols.textNode(master, in: instance, state: fixture.document.state)?.string
    }

    @Test func typingIntoAnInstanceWritesItsTextOverride() async throws {
        let fixture = Fixture()
        let (instance, master) = try await Self.instance(fixture)
        fixture.click(50.5, 56)
        let session = try #require(fixture.session)
        #expect(session.target == .override(instance: instance, master: master))
        #expect(session.node == nil && session.text?.string == "Label" && session.isLive)
        #expect(fixture.controller.selection.ids == [SelectionID(instance)])
        #expect(session.focusOffset == 0)
        await fixture.type("My ")
        #expect(Self.shown(fixture, instance, master) == "My Label")
        #expect(fixture.document.string(master) == "Label", "the master is untouched")
        #expect(Symbols.liveOverrides(of: instance, in: fixture.document.state).count == 1)
        #expect(session.focusOffset == 3 && session.selectedRange.isEmpty)
        #expect(fixture.document.undoTitle == "Undo Override text")
        // The drawing shows the override.
        let words = SymbolTextOverrideRuns.words(fixture.document.scene.object(instance)?.item)
        #expect(words.contains("My Label"))
        // Deleting and selecting work on the override too.
        fixture.tool.doCommand("deleteBackward:")
        await fixture.settle()
        #expect(Self.shown(fixture, instance, master) == "MyLabel")
        fixture.tool.doCommand("selectAll:")
        fixture.tool.insertText("Hi", replacementRange: nil)
        await fixture.settle()
        #expect(Self.shown(fixture, instance, master) == "Hi" && session.focusOffset == 2)
        // Another block of the document is not touched; ending leaves the instance selected.
        fixture.tool.cancel()
        await fixture.settle()
        #expect(fixture.controller.selection.ids == [SelectionID(instance)])
        #expect(Self.shown(fixture, instance, master) == "Hi")
    }

    @Test func theCaretAndSelectionFollowTheInstancesTransform() async throws {
        let fixture = Fixture()
        let (instance, _) = try await Self.instance(fixture)
        fixture.click(50.5, 56)
        let session = try #require(fixture.session)
        let caret = try #require(session.caret)
        #expect(abs(caret.top.x - 50) < 2 && caret.top.y >= 49 && caret.bottom.y > caret.top.y)
        let corners = session.frameCorners
        let moved = Objects.transform(of: instance, in: fixture.document.state).concatenating(.translation(x: 100, y: 20))
        _ = await fixture.document.perform(SetTransforms([(instance, moved)])).value
        await fixture.settle()
        let after = try #require(session.caret)
        #expect(abs(after.top.x - caret.top.x - 100) < 1e-6 && abs(after.top.y - caret.top.y - 20) < 1e-6)
        #expect(zip(corners, session.frameCorners).allSatisfy { abs($1.x - $0.x - 100) < 1e-6 && abs($1.y - $0.y - 20) < 1e-6 })
        #expect(session.contains(Point(x: 152, y: 76)) && !session.contains(Point(x: 52, y: 56)))
        fixture.tool.doCommand("selectAll:")
        await fixture.settle()
        #expect(!session.selectionQuads.isEmpty && session.caret == nil)
        #expect(session.selectionQuads[0].allSatisfy { $0.x >= 149 })
        // A second click in the instance's block keeps editing it.
        fixture.click(152, 76)
        #expect(fixture.session === session && session.selectedRange.isEmpty)
    }

    @Test func anOverrideEmptiedByEditingIsResetWhenEditingEnds() async throws {
        let fixture = Fixture()
        let (instance, master) = try await Self.instance(fixture)
        fixture.click(50.5, 56)
        fixture.tool.doCommand("selectAll:")
        fixture.tool.doCommand("deleteBackward:")
        await fixture.settle()
        #expect(Self.shown(fixture, instance, master) == "")
        #expect(Symbols.liveOverrides(of: instance, in: fixture.document.state).count == 1)
        fixture.tool.cancel()
        await fixture.settle()
        #expect(Symbols.liveOverrides(of: instance, in: fixture.document.state).isEmpty)
        #expect(Self.shown(fixture, instance, master) == "Label", "the master's text again")
        #expect(fixture.document.state.isLive(instance))
    }

    @Test func aLockedInstanceIsNotEditedAndARemovedOneEndsEditing() async throws {
        let fixture = Fixture()
        let (instance, _) = try await Self.instance(fixture)
        _ = await fixture.document.perform(SetLocked([instance], locked: true)).value
        await fixture.settle()
        fixture.click(50.5, 56)
        #expect(fixture.session?.target == .pending(.point(Point(x: 50.5, y: 56))))
        fixture.tool.cancel()
        _ = await fixture.document.perform(SetLocked([instance], locked: false)).value
        await fixture.settle()
        fixture.click(50.5, 56)
        #expect(fixture.session?.override?.instance == instance)
        // Hiding the block ends editing.
        let master = try #require(fixture.session?.override?.master)
        _ = await fixture.document.perform(SetOverride([instance], master: master, value: .hidden(true), in: fixture.document.state)).value
        await fixture.settle()
        #expect(fixture.session == nil)
    }

    @Test func overrideEditsFollowTheKeystrokeRules() {
        let scalars = Array("one two".unicodeScalars)
        #expect(TextEditingSession.overrideEdit(.insert("x"), range: 3..<3, scalars: scalars)! == (.insert("x", at: 3), 4))
        #expect(TextEditingSession.overrideEdit(.insert("xy"), range: 0..<3, scalars: scalars)! == (.replace(0..<3, with: "xy"), 2))
        #expect(TextEditingSession.overrideEdit(.deleteSelection, range: 3..<3, scalars: scalars) == nil)
        #expect(TextEditingSession.overrideEdit(.backspace, range: 0..<0, scalars: scalars) == nil)
        #expect(TextEditingSession.overrideEdit(.backspace, range: 2..<2, scalars: scalars)! == (.delete(1..<2), 1))
        #expect(TextEditingSession.overrideEdit(.backspace, range: 1..<3, scalars: scalars)! == (.delete(1..<3), 1))
        #expect(TextEditingSession.overrideEdit(.forwardDelete, range: 7..<7, scalars: scalars) == nil)
        #expect(TextEditingSession.overrideEdit(.forwardDelete, range: 0..<0, scalars: scalars)! == (.delete(0..<1), 0))
        #expect(TextEditingSession.overrideEdit(.forwardDelete, range: 0..<2, scalars: scalars)! == (.delete(0..<2), 0))
        #expect(TextEditingSession.overrideEdit(.deleteWordBackward, range: 7..<7, scalars: scalars)! == (.delete(4..<7), 4))
        #expect(TextEditingSession.overrideEdit(.deleteWordBackward, range: 1..<2, scalars: scalars)! == (.delete(1..<2), 1))
        #expect(TextEditingSession.overrideEdit(.deleteWordForward, range: 0..<0, scalars: scalars)! == (.delete(0..<3), 0))
        #expect(TextEditingSession.overrideEdit(.deleteWordForward, range: 1..<2, scalars: scalars)! == (.delete(1..<2), 1))
    }
}

/// Reading the words an item draws.
enum SymbolTextOverrideRuns {
    static func words(_ item: DisplayItem?) -> String {
        switch item {
        case .text(let run)?: run.text
        case .group(let group)?: group.children.map { words($0) }.joined()
        default: ""
        }
    }
}
