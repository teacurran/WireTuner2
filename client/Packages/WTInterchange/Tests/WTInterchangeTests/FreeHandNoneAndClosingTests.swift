// IO-041 (D-083): an object's explicit None over its style's stroke or fill, and closed paths,
// read as FreeHand draws them.  A logo file of the owner's had a frame rectangle set to no fill
// and no stroke over a style with a 1 pt black stroke: libfreehand dropped the property list's
// zero value, so the rectangle came in stroked (patch 0003 keeps it).  Its letters' paths are
// closed in their flags, which libfreehand records apart from the segments.  The files here are
// written byte by byte; no corpus content.

import Foundation
import Testing
import WTGeometry
@testable import WTInterchange
import WTRender

@Suite("FreeHand explicit None and closed paths")
struct FreeHandNoneAndClosingTests {
    typealias Fixture = FreeHandRecordsFixture

    static func layerChildren(_ scene: ImportedScene) -> [ImportedNode] {
        guard case .group(let layer)? = scene.nodes.first else { return [] }
        return layer.children
    }

    static func path(_ node: ImportedNode?) -> ImportedPath? {
        if case .path(let path)? = node { return path }
        return nil
    }

    /// A FreeHand 10 file: a style stroking 1 pt in a named colour, and three squares on it --
    /// one set to no stroke (its own list's stroke is record 0), one with no settings of its own,
    /// one that adds a fill.
    static func styledFile() -> (data: Data, noneList: Int, strokeName: Int) {
        var file = FreeHandFileFixture(version: 10)
        let fillName = file.mName("fill")
        let strokeName = file.mName("stroke")
        let ink = file.spotColor6(name: file.mString("Ink"), rgb: [0.1, 0.1, 0.1])
        let line = file.basicLine(color: ink, width: 1)
        let fill = file.basicFill(color: ink)
        let style = file.styleList([(strokeName, line)], element: false)
        let none = file.styleList([(strokeName, 0)], parent: style, element: true)
        let inherits = file.styleList([], parent: style, element: true)
        let filled = file.styleList([(fillName, fill)], parent: style, element: true)
        let square = [(1.0, 1.0), (3.0, 1.0), (3.0, 3.0), (1.0, 3.0)]
        let paths = [none, inherits, filled].map { file.path(square, style: $0) }
        let elements = file.list(paths)
        let layer = file.layer(elements: elements, name: file.mString("Foreground"))
        file.block(layerList: file.list([layer]))
        return (file.data(), none, strokeName)
    }

    @Test("An object's stroke set to None over its style's stroke imports with no stroke")
    func explicitNoneStroke() throws {
        let (data, noneList, strokeName) = Self.styledFile()
        // The bridge sees the zero value libfreehand used to drop.
        let records = try FreeHandImporter.records(data, name: "Frame.fh10")
        #expect(records.propertyLists[noneList]?.elements[String(strokeName)] == 0)
        let scene = try FreeHandImporter().convert(data, name: "Frame.fh10", format: .freehand, options: ImportOptionValues(), context: ImportContext())
        let paths = Self.layerChildren(scene).compactMap(Self.path)
        #expect(paths.count == 3)
        #expect(paths[0].stroke == nil && paths[0].fill == .none, "None over the style's stroke: nothing drawn")
        #expect(paths[1].stroke?.style.width == 1, "no setting of its own: the style's stroke")
        #expect(paths[2].stroke?.style.width == 1 && paths[2].fill != .none)
        // Opened as a document, the named colour is listed once for the swatches it becomes.
        let document = try FreeHandImporter().document(data, name: "Frame.fh10", format: .freehand, options: ImportOptionValues(), context: ImportContext())
        #expect(document.swatches.map(\.name) == ["Ink"])
    }

    @Test("A property list's zero fill or stroke is None over its parent's; an absent key inherits")
    func explicitNoneInPropertyLists() throws {
        var fixture = Fixture()
        let color = fixture.rgb(1, 0, 0)
        let fill = fixture.basicFill(color)
        let line = fixture.basicLine(color)
        let base = fixture.propList(fill: fill, stroke: line)
        let noStroke = fixture.propList(stroke: 0, parent: base)
        let noFill = fixture.propList(fill: 0, parent: base)
        let inherits = fixture.propList(parent: base)
        let ids = [noStroke, noFill, inherits].map { fixture.rect(1, 1, 1, 1, style: $0) }
        fixture.layer(ids)
        let paths = FreeHandImportTests.children(try fixture.convert()).compactMap(Self.path)
        #expect(paths[0].fill != .none && paths[0].stroke == nil)
        #expect(paths[1].fill == .none && paths[1].stroke != nil)
        #expect(paths[2].fill != .none && paths[2].stroke != nil)
        // A zero "contents" is no Paste Inside: the path stays a path.
        let contents = fixture.propList(fill: fill, contents: 0)
        let pasted = fixture.rect(4, 4, 1, 1, style: contents)
        fixture.layer([pasted])
        let conversion = try fixture.convert()
        guard case .group(let second) = conversion.layers[1] else {
            Issue.record("expected the second layer")
            return
        }
        #expect(Self.path(second.children.first) != nil)
    }

    @Test("A path closed in its flag, or ending where it began, imports closed; an open one stays open")
    func closedContours() throws {
        var file = FreeHandFileFixture(version: 10)
        let strokeName = file.mName("stroke")
        let ink = file.spotColor6(name: file.mString("Ink"), rgb: [0, 0, 0])
        let style = file.styleList([(strokeName, file.basicLine(color: ink, width: 2))], element: false)
        let closed = file.path([(1, 1), (3, 1), (3, 3)], style: style)
        let meets = file.path([(1, 1), (3, 1), (3, 3), (1, 1)], style: style, closed: false)
        let open = file.path([(1, 1), (3, 1), (3, 3)], style: style, closed: false)
        let elements = file.list([closed, meets, open])
        let layer = file.layer(elements: elements, name: file.mString("Foreground"))
        file.block(layerList: file.list([layer]))
        let scene = try FreeHandImporter().convert(file.data(), name: "Paths.fh10", format: .freehand, options: ImportOptionValues(), context: ImportContext())
        let paths = Self.layerChildren(scene).compactMap(Self.path)
        #expect(paths.map { $0.contours.map(\.closed) } == [[true], [true], [false]])
        #expect(paths[0].displayPath.elements.last == .close)
    }
}
