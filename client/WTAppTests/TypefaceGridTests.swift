import AppKit
import Foundation
import Testing
import WTCRDT
import WTGeometry
import WTModel
import WTProto
import WTRender
@testable import WireTuner

/// FONT-010's grid and FONT-009's cell images in the app: the model's order, filter and
/// selection, the view's layout, keys and clicks, and the thumbnails following changes.
@Suite @MainActor struct TypefaceGridTests {
    @Test func cellsReadTheGlyphsInEachOrder() async throws {
        let fixture = await TypefaceWindowFixture.typeface()
        defer { fixture.close() }
        _ = await fixture.document.perform(AddGlyphs([NewGlyph(name: "a.alt"), NewGlyph(scalar: 0x0301)])).value
        let a = fixture.glyph("a.alt")
        _ = await fixture.document.perform(SetGlyphAttributes([a], markColor: 3, export: false)).value
        let model = GlyphGridModel()
        model.reload(fixture.document.state)
        #expect(model.cells.first?.name == ".notdef" && model.cells[1].label == "space" && model.cells[34].label == "A")
        let alt = try #require(model.cells.first { $0.id == a })
        #expect(alt.label == "a.alt" && alt.unicodeLabel.isEmpty && alt.badges == [.noExport] && alt.markColor == 3)
        #expect(model.cells[34].unicodeLabel == "U+0041")
        model.sort = .unicode
        #expect(model.cells.first?.name == "space" && model.cells.last?.codepoints.isEmpty == true)
        model.sort = .name
        #expect(model.cells.first?.name == ".notdef")
        model.sort = .name
        model.sort = .custom
        #expect(GlyphSort.allCases.map(\.title) == ["Custom Order", "Unicode", "Name"])
        // Search by name, character or codepoint.
        model.search = "U+41"
        #expect(model.cells.map(\.name) == ["A"])
        model.search = "0042"
        #expect(model.cells.map(\.name) == ["B"])
        model.search = "é"
        #expect(model.cells.isEmpty)
        model.search = "alt"
        #expect(model.cells.map(\.name) == ["a.alt"])
        model.search = "Z"
        #expect(model.cells.map(\.name).contains("Z") && model.cells.map(\.name).contains("z"))
        model.search = "zz!"
        #expect(model.cells.isEmpty)
        model.search = ""
        #expect(model.cells.count == 98)
    }

    @Test func theSelectionFollowsClicksKeysAndChanges() async throws {
        let fixture = await TypefaceWindowFixture.typeface()
        defer { fixture.close() }
        let model = GlyphGridModel()
        var changes = 0
        model.onChange = { changes += 1 }
        model.reload(fixture.document.state)
        model.click(at: 34)
        #expect(model.selection == [fixture.glyph("A")] && model.anchor == fixture.glyph("A"))
        model.click(at: 36, extend: true)
        #expect(model.selection.count == 3)
        model.click(at: 40, toggle: true)
        model.click(at: 40, toggle: true)
        #expect(model.selection.count == 3 && model.isSelected(fixture.glyph("B")))
        model.click(at: nil, extend: true)
        #expect(model.selection.count == 3)
        model.click(at: nil)
        #expect(model.selection.isEmpty)
        model.move(by: 1)
        #expect(model.selection == [model.cells[0].id])
        model.select([])
        model.move(by: -1)
        #expect(model.selection == [model.cells.last!.id])
        model.move(by: 5, extend: true)
        model.selectAll()
        #expect(model.selection.count == 96)
        #expect(model.jump(to: "Q") && model.selection == [fixture.glyph("Q")])
        #expect(model.jump(to: "quest") && model.selection == [fixture.glyph("question")])
        #expect(!model.jump(to: "") && !model.jump(to: "nothing"))
        // A remote removal drops the removed glyph from the selection, keeping the rest.
        model.select([fixture.glyph("A"), fixture.glyph("B")])
        _ = await fixture.document.perform(RemoveGlyphs([fixture.glyph("B")])).value
        model.reload(fixture.document.state)
        #expect(model.selection == [fixture.glyph("A")] && model.anchor == fixture.glyph("A"))
        let empty = GlyphGridModel()
        empty.move(by: 1)
        #expect(empty.selection.isEmpty && changes > 0)
    }

    @Test func theViewLaysOutDrawsAndTakesKeys() async throws {
        let fixture = await TypefaceWindowFixture.typeface()
        defer { fixture.close() }
        _ = await fixture.box(50, -600, 300, 600, on: try #require(GlyphCanvas.handle(for: fixture.glyph("A"), of: fixture.document)))
        _ = await fixture.document.perform(SetGlyphAttributes([fixture.glyph("A")], markColor: 2, export: false)).value
        _ = await fixture.document.perform(AddGlyphs([NewGlyph(name: "Aacute", codepoints: [0xC1], components: [
            NewGlyph.NewComponent(source: .glyph(fixture.glyph("A"))),
        ])])).value
        let grid = try #require(fixture.mode.grid)
        let view = grid.gridView
        let window = TestWindow.make(NSRect(x: 0, y: 0, width: 400, height: 300))
        defer { window.close() }
        let scroll = NSScrollView(frame: window.contentView!.bounds)
        scroll.documentView = view
        window.contentView?.addSubview(scroll)
        view.relayout(width: 400)
        let columns = view.columns
        #expect(columns == 400 / Int(view.cellSize.width) && view.rows == (grid.model.cells.count + columns - 1) / columns)
        #expect(view.position(at: NSPoint(x: 1, y: 1)) == 0 && view.position(at: NSPoint(x: -1, y: 1)) == nil)
        #expect(view.position(at: NSPoint(x: 1, y: 1_000_000)) == nil && view.position(at: NSPoint(x: 399, y: 1)) == nil || columns * Int(view.cellSize.width) > 399)
        #expect(view.rect(of: columns).minY == view.cellSize.height)
        // Drawing renders every visible cell with its image, label, colour and badges.
        grid.model.select([fixture.glyph("A")])
        let bitmap = try #require(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: bitmap)
        #expect(grid.thumbnails.cache.count > 0)
        grid.model.cellSize = .large
        view.relayout(width: 400)
        view.cacheDisplay(in: view.bounds, to: try #require(view.bitmapImageRepForCachingDisplay(in: view.bounds)))
        #expect(GlyphGridView.color(of: .collision) == .systemRed && GlyphGridView.color(of: .components) == .systemBlue)
        // Keys move, extend, open, remove and jump.
        var opened: [OpID] = [], removed = 0
        view.onOpen = { opened.append($0) }
        view.onRemove = { removed += 1 }
        grid.model.select([fixture.glyph("B")])
        let arrows = [NSRightArrowFunctionKey, NSLeftArrowFunctionKey, NSDownArrowFunctionKey, NSUpArrowFunctionKey].map { String(UnicodeScalar($0)!) }
        for key in arrows { #expect(view.handleKey(key, characters: key)) }
        #expect(grid.model.selection == [fixture.glyph("B")])
        view.handleKey(arrows[0], characters: arrows[0], shift: true)
        #expect(grid.model.selection.count == 2)
        view.handleKey("\r", characters: "\r")
        #expect(opened.count == 2)
        view.handleKey("\u{7F}", characters: "\u{7F}")
        #expect(removed == 1)
        let now = Date()
        view.handleKey("q", characters: "q", now: now)
        view.handleKey("u", characters: "u", now: now.addingTimeInterval(0.2))
        #expect(grid.model.selection == [fixture.glyph("quotedbl")] || grid.model.selection == [fixture.glyph("quotesingle")])
        view.handleKey("x", characters: "x", now: now.addingTimeInterval(0.4))
        #expect(grid.model.selection == [fixture.glyph("x")])
        #expect(!view.handleKey(" ", characters: " ") && !view.handleKey("", characters: ""))
        // Clicks select, double-clicks open.
        let point = view.convert(NSPoint(x: 5, y: 5), to: nil)
        view.mouseDown(with: try #require(NSEvent.mouseEvent(with: .leftMouseDown, location: point, modifierFlags: [], timestamp: 0,
                                                              windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)))
        #expect(grid.model.selection == [grid.model.cells[0].id])
        view.mouseDown(with: try #require(NSEvent.mouseEvent(with: .leftMouseDown, location: point, modifierFlags: [], timestamp: 0,
                                                              windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 2, pressure: 1)))
        #expect(opened.last == grid.model.cells[0].id)
        view.keyDown(with: try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber,
                                                         context: nil, characters: "Z", charactersIgnoringModifiers: "Z", isARepeat: false, keyCode: 6)))
        #expect(grid.model.selection == [fixture.glyph("Z")])
        view.keyDown(with: try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber,
                                                         context: nil, characters: "\t", charactersIgnoringModifiers: "\t", isARepeat: false, keyCode: 48)))
        #expect(view.acceptsFirstResponder && view.isFlipped)
    }

    @Test func theControllerBarDrivesTheModel() async throws {
        let fixture = await TypefaceWindowFixture.typeface()
        defer { fixture.close() }
        let grid = try #require(fixture.mode.grid)
        grid.searchField.stringValue = "U+0041"
        grid.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification))
        #expect(grid.model.cells.count == 1 && grid.countLabel.stringValue == "1 of 96 glyphs")
        grid.searchField.stringValue = ""
        grid.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification))
        grid.sortPopUp.selectItem(at: 2)
        grid.sortChanged(grid.sortPopUp)
        #expect(grid.model.sort == .name)
        grid.sizePopUp.selectItem(at: 0)
        grid.sizeChanged(grid.sizePopUp)
        #expect(grid.model.cellSize == .small)
        #expect(GlyphThumbnail.CellSize.allCases.map(GlyphGridController.title(of:)) == ["Small", "Medium", "Large"])
        NotificationCenter.default.post(name: NSView.frameDidChangeNotification, object: grid.scrollView.contentView)
        var added = false
        grid.onAdd = { added = true }
        grid.add(nil)
        #expect(added)
    }

    @Test func thumbnailsFollowTheChangesThatReachThem() async throws {
        let fixture = await TypefaceWindowFixture.typeface()
        defer { fixture.close() }
        let source = GlyphThumbnailSource()
        await source.follow(fixture.document).value
        await source.follow(fixture.document).value
        let state = fixture.document.state
        let metrics = WTModel.FontInfo(state).metrics
        let a = fixture.glyph("A"), b = fixture.glyph("B")
        _ = source.image(for: a, advanceWidth: 500, in: state, font: metrics, pixels: 64)
        _ = source.image(for: b, advanceWidth: 500, in: state, font: metrics, pixels: 64)
        _ = source.image(for: a, advanceWidth: 500, in: state, font: metrics, pixels: 64)
        #expect(source.cache.renders == 2)
        // Drawing on A redraws A only.
        let handle = try #require(GlyphCanvas.handle(for: a, of: fixture.document))
        _ = await fixture.box(0, -500, 100, 500, on: handle)
        let after = fixture.document.state
        _ = source.image(for: a, advanceWidth: 500, in: after, font: metrics, pixels: 64)
        _ = source.image(for: b, advanceWidth: 500, in: after, font: metrics, pixels: 64)
        #expect(source.cache.renders == 3)
        // A font-level change (the em) redraws everything.
        _ = await fixture.document.perform(SetFontMetrics([.ascender: 900])).value
        #expect(source.cache.count == 0)
        #expect(!GlyphThumbnailSource.touchesSettings(Ops.setDeleted(a, true)))
        source.stop()
        source.stop()
    }
}
