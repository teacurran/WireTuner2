// IO-041 with IO-040: a FreeHand file opened as a document.

import Foundation
import Testing
import WTGeometry
import WTRender
@testable import WTInterchange

@Suite("FreeHand opened as a document")
struct FreeHandDocumentTests {
    @Test("Each page takes the objects that lie on it, in its own space, layers kept")
    func pages() throws {
        var f = FreeHandRecordsFixture()
        f.top["pages"] = [[0.0, 0.0, 8.0, 10.0], [10.0, 0.0, 18.0, 10.0]]
        f.layer([f.rect(1, 1, 1, 1), f.rect(11, 1, 1, 1), f.rect(9, 5, 0.5, 0.5), f.rect(30, 5, 1, 1)], name: "Art")
        var converter = FreeHandConverter(records: try f.records(), name: "two.fh10")
        let conversion = converter.convert()
        #expect(FreeHandImporter.page(of: FreeHandImportTests.children(conversion)[0], among: conversion.pages) == 0)
        #expect(FreeHandImporter.page(of: FreeHandImportTests.children(conversion)[1], among: conversion.pages) == 1)
        #expect(FreeHandImporter.page(of: FreeHandImportTests.children(conversion)[3], among: conversion.pages) == 1)
        #expect(FreeHandImporter.page(of: .group(ImportedGroup(children: [])), among: conversion.pages) == 0)
    }

    @Test("A FreeHand file opens as a document of its pages")
    func openedFile() throws {
        let document = try FreeHandImporter().document(FreeHandFileFixture.square(version: 10), name: "Square.fh10", format: .freehand,
                                                       options: ImportOptionValues(), context: ImportContext())
        #expect(document.pages.count == 1)
        #expect(document.pages[0].size == Size(width: 612, height: 792))
        #expect(document.layerNames == ["Artwork"])
        #expect(FreeHandImporter().opensAsDocument(.freehand))
    }

    @Test("Opened as a document, hidden layers come in hidden with their artwork; an import leaves them out")
    func hiddenLayers() throws {
        var f = FreeHandRecordsFixture()
        f.layer([f.rect(1, 1, 1, 1)], name: "Shown")
        f.layer([f.rect(2, 2, 1, 1)], name: "Secret", visibility: 2)
        f.layer([f.rect(2, 2, 1, 1)], name: "Guides", visibility: 10)
        var converter = FreeHandConverter(records: try f.records(), name: "a.fh10")
        converter.keepHidden = true
        let kept = converter.convert()
        let groups = kept.layers.compactMap(FreeHandImportTests.group)
        #expect(groups.map(\.name) == ["Shown", "Secret"] && groups.map(\.layerState.visible) == [true, false])
        #expect(!kept.notes.contains { $0.hasPrefix("Hidden layers") })
        // The whole file: a shown layer and a hidden one.
        var file = FreeHandFileFixture(version: 10)
        let fill = file.mName("fill")
        let leaf = file.mString("Leaf")
        let color = file.spotColor6(name: leaf, rgb: [0.2, 0.6, 0.2])
        let basic = file.basicFill(color: color)
        let style = file.propList([(fill, basic)])
        let square = file.path([(1, 1), (3, 1), (3, 3), (1, 3)], style: style)
        let shown = file.list([square])
        let small = file.path([(4, 4), (5, 4), (5, 5), (4, 5)], style: style)
        let hidden = file.list([small])
        let art = file.mString("Art")
        let sketch = file.mString("Sketch")
        let layers = [file.layer(elements: shown, name: art), file.layer(elements: hidden, name: sketch, visibility: 2)]
        let list = file.list(layers)
        file.block(layerList: list)
        let data = file.data()
        let document = try FreeHandImporter().document(data, name: "Two.fh10", format: .freehand, options: ImportOptionValues(), context: ImportContext())
        let opened = document.pages[0].nodes.compactMap(FreeHandImportTests.group)
        #expect(opened.map(\.name) == ["Art", "Sketch"] && opened.map(\.layerState.visible) == [true, false])
        #expect(opened.allSatisfy { $0.children.count == 1 })
        let scene = try FreeHandImporter().convert(data, name: "Two.fh10", format: .freehand, options: ImportOptionValues(), context: ImportContext())
        #expect(scene.nodes.compactMap(FreeHandImportTests.group).map(\.name) == ["Art"])
        #expect(scene.notes.contains("Hidden layers were left out: Sketch."))
    }
}
