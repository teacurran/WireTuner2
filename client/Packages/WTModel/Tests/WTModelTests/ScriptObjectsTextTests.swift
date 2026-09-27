import Foundation
import Testing
import WTCRDT
import WTGeometry
@testable import WTModel
import WTProto
import WTRender

/// DOC-026's rest, model half: the Text suite (paragraph, word, character with font, size,
/// leading and colour), units, grid and guides, and making layers (`ScriptObjects`).
@Suite struct ScriptObjectsTextTests {
    typealias Base = ScriptObjectsTests

    static func textBlock(_ text: String, core: inout DocumentCore) throws -> OpID {
        let change = try Base.perform(CreateTextBlock(.point(Point(x: 100, y: 100)), text: text), on: &core)
        return try #require(change?.createdObjects.first)
    }

    @Test func paragraphsWordsAndCharactersReadTheirContents() throws {
        var core = try Base.core()
        let text = try Self.textBlock("Spring sale\nIt's here, now", core: &core)
        let state = core.state
        #expect(ScriptObjects.textCount(.paragraph, of: text, in: state) == 2)
        #expect(ScriptObjects.textCount(.word, of: text, in: state) == 5)
        #expect(ScriptObjects.textCount(.character, of: text, in: state) == 26)
        #expect(ScriptObjects.textCount(.text, of: text, in: state) == 1)
        #expect(ScriptObjects.textGet(text, .paragraph, 0, "contents", in: state) as? String == "Spring sale")
        #expect(ScriptObjects.textGet(text, .paragraph, 1, "contents", in: state) as? String == "It's here, now")
        #expect(ScriptObjects.textGet(text, .word, 2, "contents", in: state) as? String == "It's")
        #expect(ScriptObjects.textGet(text, .word, 4, "contents", in: state) as? String == "now")
        #expect(ScriptObjects.textGet(text, .character, 1, "contents", in: state) as? String == "p")
        #expect(ScriptObjects.textGet(text, .text, 0, "contents", in: state) as? String == "Spring sale\nIt's here, now")
        #expect(ScriptObjects.textGet(text, .word, 9, "contents", in: state) == nil)
        #expect(ScriptObjects.textGet(text, .word, 0, "kerning", in: state) == nil)
        #expect(ScriptObjects.words(Array("tail' end'".unicodeScalars)).count == 2)
        let page = try #require(ScriptObjects.list("pages", in: state)?.first)
        #expect(ScriptObjects.textCount(.word, of: page, in: state) == 0 && ScriptObjects.textGet(page, .word, 0, "size", in: state) == nil)
        #expect(throws: TextEditError.self) { try ScriptObjects.textSetting(page, .word, 0, "size", to: 12, in: state) }
        #expect(ScriptObjects.NoSuchObject(element: "word", index: 2).description == "There is no word 3")
    }

    @Test func fontSizeLeadingAndColorReadDefaultsAndSetOneRange() throws {
        var core = try Base.core()
        let text = try Self.textBlock("Spring sale now", core: &core)
        #expect(ScriptObjects.textGet(text, .word, 1, "font", in: core.state) as? String == ScriptObjects.defaultFontFamily)
        #expect(ScriptObjects.textGet(text, .word, 1, "size", in: core.state) as? Double == 12)
        #expect(ScriptObjects.textGet(text, .word, 1, "leading", in: core.state) as? Double == 12 * 1.2)
        #expect(ScriptObjects.textGet(text, .word, 1, "color", in: core.state) as? [Double] == [0, 0, 0])

        _ = try Base.perform(ScriptObjects.textSetting(text, .word, 1, "font", to: "Futura", in: core.state).command, on: &core)
        _ = try Base.perform(ScriptObjects.textSetting(text, .word, 1, "size", to: 24, in: core.state).command, on: &core)
        _ = try Base.perform(ScriptObjects.textSetting(text, .word, 1, "leading", to: 30, in: core.state).command, on: &core)
        _ = try Base.perform(ScriptObjects.textSetting(text, .word, 1, "color", to: [1, 0, 0], in: core.state).command, on: &core)
        #expect(ScriptObjects.textGet(text, .word, 1, "font", in: core.state) as? String == "Futura")
        #expect(ScriptObjects.textGet(text, .word, 1, "size", in: core.state) as? Double == 24)
        #expect(ScriptObjects.textGet(text, .word, 1, "leading", in: core.state) as? Double == 30)
        let red = try #require(ScriptObjects.textGet(text, .word, 1, "color", in: core.state) as? [Double])
        #expect(abs(red[0] - 1) < 1e-6 && abs(red[1]) < 1e-6 && abs(red[2]) < 1e-6)
        // The neighbours keep theirs: one range, one change each.
        #expect(ScriptObjects.textGet(text, .word, 0, "size", in: core.state) as? Double == 12)
        #expect(ScriptObjects.textGet(text, .character, 5, "font", in: core.state) as? String == ScriptObjects.defaultFontFamily)
        #expect(ScriptObjects.textGet(text, .character, 7, "font", in: core.state) as? String == "Futura")

        // Leading modes as stored by the Text panel read in points.
        let node = try #require(TextNode(text, in: core.state))
        for (mode, value, points) in [(Wiretuner_Doc_V1_LeadingMode.extra, 2.0, 14.0), (.percent, 150, 18)] {
            var mark = Wiretuner_Doc_V1_TextMarkValue()
            mark.leading = .with { $0.mode = mode; $0.value = value }
            _ = try Base.perform(ApplyMark(node: text, from: node.anchor(at: 0), to: node.anchor(at: 6), value: mark), on: &core)
            #expect(ScriptObjects.textGet(text, .word, 0, "leading", in: core.state) as? Double == points)
        }

        #expect(throws: ScriptObjects.InvalidValue(property: "size")) { try ScriptObjects.textSetting(text, .word, 0, "size", to: 0, in: core.state) }
        #expect(throws: ScriptObjects.InvalidValue(property: "size")) { try ScriptObjects.textSetting(text, .word, 0, "size", to: "big", in: core.state) }
        #expect(throws: ScriptObjects.InvalidValue(property: "font")) { try ScriptObjects.textSetting(text, .word, 0, "font", to: "", in: core.state) }
        #expect(throws: ScriptObjects.InvalidValue(property: "color")) { try ScriptObjects.textSetting(text, .word, 0, "color", to: [1, 0], in: core.state) }
        #expect(throws: ScriptObjects.InvalidValue(property: "color")) { try ScriptObjects.textSetting(text, .word, 0, "color", to: [2, 0, 0], in: core.state) }
        #expect(throws: ScriptObjects.ReadOnly(property: "kerning", kind: "word")) { try ScriptObjects.textSetting(text, .word, 0, "kerning", to: 1, in: core.state) }
        #expect(throws: ScriptObjects.NoSuchObject(element: "paragraph", index: 4)) {
            try ScriptObjects.textSetting(text, .paragraph, 4, "size", to: 10, in: core.state)
        }
    }

    @Test func contentsReplaceAnElementKeepingItsFormat() throws {
        var core = try Base.core()
        let text = try Self.textBlock("One two\n\nthree", core: &core)
        _ = try Base.perform(ScriptObjects.textSetting(text, .word, 1, "size", to: 20, in: core.state).command, on: &core)
        let edit = try ScriptObjects.textSetting(text, .word, 1, "contents", to: "2", in: core.state)
        #expect(edit.immediate)
        _ = try Base.perform(edit.command, on: &core)
        #expect(ScriptObjects.textGet(text, .text, 0, "contents", in: core.state) as? String == "One 2\n\nthree")
        #expect(ScriptObjects.textGet(text, .word, 1, "size", in: core.state) as? Double == 20)
        // An empty paragraph takes text; an empty element reads the character before it.
        #expect(ScriptObjects.textGet(text, .paragraph, 1, "size", in: core.state) as? Double == 12)
        _ = try Base.perform(ScriptObjects.textSetting(text, .paragraph, 1, "contents", to: "middle", in: core.state).command, on: &core)
        #expect(ScriptObjects.textGet(text, .paragraph, 1, "contents", in: core.state) as? String == "middle")
        _ = try Base.perform(ScriptObjects.textSetting(text, .text, 0, "contents", to: "", in: core.state).command, on: &core)
        #expect(ScriptObjects.textGet(text, .text, 0, "contents", in: core.state) as? String == "")
        #expect(ScriptObjects.textGet(text, .text, 0, "size", in: core.state) as? Double == 12)
        _ = try Base.perform(ScriptObjects.textSetting(text, .text, 0, "contents", to: "again", in: core.state).command, on: &core)
        #expect(ScriptObjects.textGet(text, .text, 0, "contents", in: core.state) as? String == "again")
    }

    @Test func unitsAndGridReadAndSet() throws {
        var core = try Base.core()
        #expect(ScriptObjects.documentGet("units", in: core.state) as? String == "points")
        #expect(ScriptObjects.documentGet("gridSize", in: core.state) as? Double == GridSettings.defaultSize)
        #expect(ScriptObjects.documentGet("gridRelative", in: core.state) as? Bool == false)
        #expect(ScriptObjects.documentGet("bleed", in: core.state) == nil)
        for (name, unit) in [("Millimeters", LengthUnit.millimeters), ("in", .inches), ("decimal inches", .decimalInches), ("pc", .picas), ("q", .kyus)] {
            #expect(ScriptObjects.unit(named: name, in: core.state) == unit, "\(name)")
        }
        #expect(ScriptObjects.unit(named: "furlongs", in: core.state) == nil)
        _ = try Base.perform(ScriptObjects.documentSetting("units", to: "mm", in: core.state).command, on: &core)
        #expect(ScriptObjects.documentGet("units", in: core.state) as? String == "millimeters")
        _ = try Base.perform(AddCustomUnit(name: "Agate", amount: 1, base: .points), on: &core)
        _ = try Base.perform(ScriptObjects.documentSetting("units", to: "agate", in: core.state).command, on: &core)
        #expect(ScriptObjects.documentGet("units", in: core.state) as? String == "agate")
        _ = try Base.perform(ScriptObjects.documentSetting("gridSize", to: 18, in: core.state).command, on: &core)
        _ = try Base.perform(ScriptObjects.documentSetting("gridRelative", to: true, in: core.state).command, on: &core)
        #expect(ScriptObjects.documentGet("gridSize", in: core.state) as? Double == 18)
        #expect(ScriptObjects.documentGet("gridRelative", in: core.state) as? Bool == true)
        #expect(throws: ScriptObjects.InvalidValue(property: "units")) { try ScriptObjects.documentSetting("units", to: "furlongs", in: core.state) }
        #expect(throws: ScriptObjects.InvalidValue(property: "gridSize")) { try ScriptObjects.documentSetting("gridSize", to: -1, in: core.state) }
        #expect(throws: ScriptObjects.ReadOnly(property: "name", kind: "document")) { try ScriptObjects.documentSetting("name", to: "x", in: core.state) }
    }

    @Test func guidesAreAddedMovedAndRemovedOnPagesAndMasters() throws {
        var core = try Base.core()
        let page = try #require(ScriptObjects.list("pages", in: core.state)?.first)
        #expect(ScriptObjects.guides(of: page, in: core.state).isEmpty)
        _ = try Base.perform(ScriptObjects.addingGuide(on: page, orientation: "Vertical", at: 72).command, on: &core)
        _ = try Base.perform(ScriptObjects.addingGuide(on: page, orientation: "horizontal", at: 36).command, on: &core)
        let guides = ScriptObjects.guides(of: page, in: core.state)
        #expect(guides.count == 2)
        #expect(ScriptObjects.guideGet(guides[0].id, on: page, "orientation", in: core.state) as? String == "vertical")
        #expect(ScriptObjects.guideGet(guides[1].id, on: page, "orientation", in: core.state) as? String == "horizontal")
        #expect(ScriptObjects.guideGet(guides[0].id, on: page, "position", in: core.state) as? Double == 72)
        #expect(ScriptObjects.guideGet(guides[0].id, on: page, "color", in: core.state) == nil)
        #expect(ScriptObjects.guideGet(.zero, on: page, "position", in: core.state) == nil)
        _ = try Base.perform(ScriptObjects.guideSetting(guides[0].id, on: page, "position", to: 90, in: core.state).command, on: &core)
        #expect(ScriptObjects.guideGet(guides[0].id, on: page, "position", in: core.state) as? Double == 90)
        #expect(throws: ScriptObjects.ReadOnly(property: "orientation", kind: "guide")) {
            try ScriptObjects.guideSetting(guides[0].id, on: page, "orientation", to: "horizontal", in: core.state)
        }
        #expect(throws: ScriptObjects.NoSuchObject.self) { try ScriptObjects.guideSetting(.zero, on: page, "position", to: 1, in: core.state) }
        _ = try Base.perform(ScriptObjects.removingGuide(guides[1].id, on: page, in: core.state).command, on: &core)
        #expect(ScriptObjects.guides(of: page, in: core.state).count == 1)
        #expect(throws: ScriptObjects.NoSuchObject.self) { try ScriptObjects.removingGuide(.zero, on: page, in: core.state) }
        #expect(throws: ScriptObjects.InvalidValue(property: "orientation")) { try ScriptObjects.addingGuide(on: page, orientation: "diagonal", at: 1) }
        #expect(throws: ScriptObjects.InvalidValue(property: "position")) { try ScriptObjects.addingGuide(on: page, orientation: "vertical", at: "x") }

        _ = try Base.perform(NewMasterPage(from: page, name: "A"), on: &core)
        let master = try #require(ScriptObjects.list("masterPages", in: core.state)?.first)
        _ = try Base.perform(ScriptObjects.addingGuide(on: master, orientation: "vertical", at: 10).command, on: &core)
        #expect(ScriptObjects.guides(of: master, in: core.state).map(\.position) == [10])
        #expect(ScriptObjects.guides(of: .zero, in: core.state).isEmpty)
    }

    @Test func layersAreMadeOnTop() throws {
        var core = try Base.core()
        let before = ScriptObjects.list("layers", in: core.state)?.count ?? 0
        _ = try Base.perform(ScriptObjects.creating("layer", ["name": "Notes"]), on: &core)
        _ = try Base.perform(ScriptObjects.creating("layer", ["name": ""]), on: &core)
        let layers = try #require(ScriptObjects.list("layers", in: core.state))
        #expect(layers.count == before + 2)
        let names = layers.compactMap { ScriptObjects.get($0, "name", in: core.state) as? String }
        #expect(names.contains("Notes") && names.contains("Layer"))
    }

    /// The corners of `ScriptObjects` the surfaces reach rarely: summaries, symbologies, hidden
    /// layers in the report, numbers as names, unknown calls and creations.
    @Test func theRarerReadsSetsAndCreationsBehave() throws {
        var core = try Base.core()
        #expect(ScriptObjects.get(OpID(counter: 999_999, replica: 5), "name", in: core.state) == nil)
        var appearance = Wiretuner_Doc_V1_AppearanceProps()
        appearance.fills = [Appearances.basicFill(red: 1, green: 0, blue: 0), Appearances.basicFill(red: 0, green: 1, blue: 0)]
        appearance.strokes = [Appearances.basicStroke(red: 0, green: 0, blue: 0, width: 1)]
        let shape = try #require(try Base.perform(CreateShape(.rectangle(CornerRadii()), size: Size(width: 10, height: 10), appearance: appearance), on: &core)?
            .createdObjects.first)
        #expect(ScriptObjects.get(shape, "fill", in: core.state) as? String == "2 fills")
        #expect(ScriptObjects.get(shape, "stroke", in: core.state) as? String == "1 stroke")
        appearance.fills = [Appearances.basicFill(red: 1, green: 0, blue: 0)]
        appearance.strokes = []
        let plain = try #require(try Base.perform(CreateShape(.ellipse, size: Size(width: 10, height: 10), appearance: appearance), on: &core)?.createdObjects.first)
        #expect(ScriptObjects.get(plain, "fill", in: core.state) as? String == "1 fill")
        #expect(ScriptObjects.get(plain, "stroke", in: core.state) as? String == "0 strokes")
        _ = try Base.perform(ScriptObjects.setting(shape, "name", to: NSNumber(value: 7), in: core.state).command, on: &core)
        #expect(ScriptObjects.get(shape, "name", in: core.state) as? String == "7")
        _ = try Base.perform(ScriptObjects.setting(shape, "notes", to: nil, in: core.state).command, on: &core)
        #expect(throws: DataEditError.self) { try ScriptObjects.setting(shape, "name", to: [1], in: core.state) }
        #expect(throws: DataEditError.self) { try ScriptObjects.setting(shape, "locked", to: "yes", in: core.state) }
        #expect(throws: ScriptUnavailable.self) { try ScriptObjects.calling(shape, "explode", nil, in: core.state) }
        #expect(throws: ScriptUnavailable.self) { try ScriptObjects.creating("star", [:]) }
        #expect(throws: ScriptObjects.ReadOnly.self) { try ScriptObjects.setting(shape, "fill", to: "red", in: core.state) }
        for method in ["bringToFront", "sendToBack", "duplicate"] {
            _ = try Base.perform(ScriptObjects.calling(shape, method, nil, in: core.state).command, on: &core)
        }

        // Barcodes: Code 128 read, set and made.
        let code = try #require(try Base.perform(ScriptObjects.creating("barcode", ["kind": "Code128"]), on: &core)?.createdObjects.first)
        #expect(ScriptObjects.get(code, "symbology", in: core.state) as? String == "code128")
        _ = try Base.perform(ScriptObjects.setting(code, "symbology", to: "qr", in: core.state).command, on: &core)
        #expect(ScriptObjects.get(code, "symbology", in: core.state) as? String == "qr")
        _ = try Base.perform(ScriptObjects.setting(code, "symbology", to: "CODE128", in: core.state).command, on: &core)
        _ = try Base.perform(ScriptObjects.setting(code, "value", to: "123", in: core.state).command, on: &core)
        #expect(ScriptObjects.get(code, "value", in: core.state) as? String == "123")

        // Text: an empty block made, then set over existing text keeping its format.
        let text = try #require(try Base.perform(ScriptObjects.creating("text", [:]), on: &core)?.createdObjects.first)
        _ = try Base.perform(ScriptObjects.setting(text, "text", to: "Hello", in: core.state).command, on: &core)
        _ = try Base.perform(ScriptObjects.textSetting(text, .text, 0, "size", to: 30, in: core.state).command, on: &core)
        _ = try Base.perform(ScriptObjects.setting(text, "text", to: "World", in: core.state).command, on: &core)
        #expect(ScriptObjects.textGet(text, .text, 0, "size", in: core.state) as? Double == 30)
        #expect(ScriptObjects.get(text, "text", in: core.state) as? String == "World")
        // A size outside the readable range reads as the default; a cleared font as the default family.
        let node = try #require(TextNode(text, in: core.state))
        var huge = Wiretuner_Doc_V1_TextMarkValue()
        huge.size = 20_000
        _ = try Base.perform(ApplyMark(node: text, from: node.anchor(at: 0), to: node.anchor(at: 5), value: huge), on: &core)
        #expect(ScriptObjects.textGet(text, .text, 0, "size", in: core.state) as? Double == 12)
        _ = try Base.perform(ScriptObjects.textSetting(text, .text, 0, "font", to: "Futura", in: core.state).command, on: &core)
        let again = try #require(TextNode(text, in: core.state))
        var family = Wiretuner_Doc_V1_TextMarkValue()
        family.fontFamily = "Futura"
        _ = try Base.perform(ApplyMark.remove(node: text, from: again.anchor(at: 0), to: again.anchor(at: 5), attribute: family), on: &core)
        #expect(ScriptObjects.textGet(text, .text, 0, "font", in: core.state) as? String == ScriptObjects.defaultFontFamily)

        // Layers: flags read; masters, hidden and locked layers in the report; pages on a master.
        let layer = try #require(ScriptObjects.list("layers", in: core.state)?.first)
        _ = try Base.perform(ScriptObjects.setting(layer, "visible", to: false, in: core.state).command, on: &core)
        _ = try Base.perform(ScriptObjects.setting(layer, "locked", to: true, in: core.state).command, on: &core)
        #expect(ScriptObjects.get(layer, "visible", in: core.state) as? Bool == false)
        #expect(ScriptObjects.get(layer, "locked", in: core.state) as? Bool == true)
        let page = try #require(ScriptObjects.list("pages", in: core.state)?.first)
        _ = try Base.perform(NewMasterPage(from: page, name: "A"), on: &core)
        let master = try #require(ScriptObjects.list("masterPages", in: core.state)?.first)
        #expect(ScriptObjects.get(master, "name", in: core.state) as? String == "A")
        _ = try Base.perform(ScriptObjects.addPages(count: 1, master: master), on: &core)
        #expect(PageList(core.state).pages.last?.master == master)
        let report = ScriptObjects.report(name: "R", state: core.state)
        #expect(report.contains("Master pages: 1\n  A\n") && report.contains(" (hidden) (locked)"))
    }
}
