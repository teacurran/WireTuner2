// IMG-013: DXF import.  Fixtures are written here as group-code pairs in the styles of the
// applications that produce DXF -- AutoCAD (2018, handles and subclass markers, tables, blocks,
// objects), LibreCAD (R12 POLYLINE/VERTEX) and Blender (no tables, LWPOLYLINE and LINE only) -- and
// re-encoded as binary DXF with both group-code widths; no third-party files are vendored.  Round
// trips go through the DXF exporter (IO-020) and back.

import CoreGraphics
import Foundation
import Testing
import WTGeometry
@testable import WTInterchange
import WTRender

/// A DXF fixture as group-code pairs.
fileprivate struct DXFImportFixture {
    var pairs: [(Int, String)] = []

    init(_ pairs: [(Int, String)] = []) {
        self.pairs = pairs
    }

    static func section(_ name: String, _ body: [(Int, String)]) -> [(Int, String)] {
        [(0, "SECTION"), (2, name)] + body + [(0, "ENDSEC")]
    }

    static func entity(_ type: String, _ fields: [(Int, Any)]) -> [(Int, String)] {
        [(0, type)] + fields.map { ($0.0, "\($0.1)") }
    }

    static func layer(_ name: String, color: Int = 7, flags: Int = 0, extra: [(Int, Any)] = []) -> [(Int, String)] {
        entity("LAYER", [(2, name), (70, flags), (62, color)] + extra)
    }

    /// A drawing: header variables, layer records, blocks (name, base, entities) and entities.
    static func drawing(units: Int? = nil, layers: [[(Int, String)]] = [], blocks: [(String, Point, [[(Int, String)]])] = [], entities: [[(Int, String)]]) -> DXFImportFixture {
        var pairs: [(Int, String)] = []
        if let units {
            pairs += section("HEADER", [(9, "$ACADVER"), (1, "AC1032"), (9, "$INSUNITS"), (70, "\(units)")])
        }
        if !layers.isEmpty {
            pairs += section("TABLES", [(0, "TABLE"), (2, "LAYER"), (70, "\(layers.count)")] + layers.flatMap { $0 } + [(0, "ENDTAB")])
        }
        if !blocks.isEmpty {
            pairs += section("BLOCKS", blocks.flatMap { block in
                entity("BLOCK", [(8, "0"), (2, block.0), (70, 0), (10, block.1.x), (20, block.1.y), (30, 0)]) + block.2.flatMap { $0 } + entity("ENDBLK", [(8, "0")])
            })
        }
        pairs += section("ENTITIES", entities.flatMap { $0 })
        pairs.append((0, "EOF"))
        return DXFImportFixture(pairs)
    }

    var text: String { pairs.map { "\(String(repeating: " ", count: $0.0 < 10 ? 2 : ($0.0 < 100 ? 1 : 0)))\($0.0)\n\($0.1)\n" }.joined() }
    var ascii: Data { Data(text.utf8) }

    /// Binary DXF: R12's one-byte codes (255 escapes to two) or R13's two-byte codes.
    func binary(wide: Bool) -> Data {
        var data = Data("AutoCAD Binary DXF\r\n".utf8) + Data([0x1A, 0x00])
        for (code, value) in pairs {
            if wide {
                data.appendLittleEndian(UInt16(code))
            } else if code >= 255 {
                data.append(255)
                data.appendLittleEndian(UInt16(code))
            } else {
                data.append(UInt8(code))
            }
            switch DXFImportDrawing.binaryValue(code)! {
            case .string: data += Data(value.utf8) + Data([0])
            case .double: withUnsafeBytes(of: Double(value)!.bitPattern.littleEndian) { data.append(contentsOf: $0) }
            case .int16: data.appendLittleEndian(UInt16(bitPattern: Int16(value)!))
            case .int32: data.appendLittleEndian(UInt32(bitPattern: Int32(value)!))
            case .int64: withUnsafeBytes(of: Int64(value)!.littleEndian) { data.append(contentsOf: $0) }
            case .bool: data.append(UInt8(value)!)
            case .chunk:
                let bytes = stride(from: 0, to: value.count, by: 2).map { UInt8(value.dropFirst($0).prefix(2), radix: 16)! }
                data.append(UInt8(bytes.count))
                data += Data(bytes)
            }
        }
        return data
    }
}

private func dxfImport(_ fixture: DXFImportFixture, _ options: DXFImportOptions = DXFImportOptions()) throws -> ImportedScene {
    try DXFImporter().convert(fixture.ascii, name: "drawing.dxf", options: options)
}

/// Every point of `contour`'s segments sampled at `steps` parameters.
private func dxfImportSamples(_ contour: ImportedContour, steps: Int = 16) -> [Point] {
    var points: [Point] = []
    var current = contour.start
    for segment in contour.segments {
        switch segment {
        case .line(let end):
            points.append(end)
        case .cubic(let c1, let c2, let end):
            let curve = CubicBezier(current, c1, c2, end)
            points += (0...steps).map { curve.evaluate(Double($0) / Double(steps)) }
        }
        current = segment.end
    }
    return points
}

private func dxfImportClose(_ a: Point, _ b: Point, _ tolerance: Double = 1e-6) -> Bool {
    abs(a.x - b.x) <= tolerance && abs(a.y - b.y) <= tolerance
}

private func dxfImportColor(_ scene: ImportedScene, _ index: Int = 0) -> Color? {
    let path = scene.scenePaths[index]
    return path.stroke?.paint.representativeColor ?? path.fill.representativeColor
}

@Suite struct DXFImportTests {
    fileprivate typealias F = DXFImportFixture

    // MARK: Reading

    @Test func asciiLinesUnitsLayersAndBounds() throws {
        let fixture = F.drawing(units: 4, layers: [F.layer("Walls", color: 1), F.layer("Unused")], entities: [
            F.entity("LINE", [(8, "Walls"), (10, 0), (20, 0), (30, 0), (11, 25.4), (21, 12.7), (31, 0)]),
            F.entity("LINE", [(8, "Doors"), (10, 25.4), (20, 0), (11, 50.8), (21, 0)]),
        ])
        let crlf = Data(fixture.text.replacingOccurrences(of: "\n", with: "\r\n").utf8)
        for (index, data) in [fixture.ascii, crlf, fixture.binary(wide: false), fixture.binary(wide: true)].enumerated() {
            let scene: ImportedScene
            do { scene = try DXFImporter().convert(data, name: "walls.dxf", options: DXFImportOptions()) } catch { Issue.record("variant \(index): \(error)"); continue }
            #expect(scene.kind == .vector)
            #expect(scene.bounds == Rect(x: 0, y: 0, width: 144, height: 36))
            #expect(scene.nodes.map(\.name) == ["Walls", "Doors"])
            let paths = scene.scenePaths
            #expect(paths.count == 2)
            #expect(dxfImportClose(paths[0].contours[0].start, Point(x: 0, y: 36)))
            #expect(dxfImportClose(paths[0].contours[0].end, Point(x: 72, y: 0)))
            #expect(paths[0].stroke?.paint == .solid(Color(red: 1, green: 0, blue: 0)))
            #expect(abs(paths[0].stroke!.style.width - 0.25 * 72 / 25.4) < 1e-9)
            #expect(paths[1].groupNames == ["Doors"])
            if case .group(let group) = scene.nodes[0] {
                #expect(group.role == .layer)
            }
        }
    }

    @Test func autoCADLibreCADAndBlenderStyles() throws {
        // AutoCAD 2018: handles, owners and subclass markers around every record.
        let autocad = F.drawing(units: 1, layers: [F.entity("LAYER", [(5, "10"), (330, "2"), (100, "AcDbSymbolTableRecord"), (100, "AcDbLayerTableRecord"), (2, "0"), (70, 0), (62, 7), (6, "Continuous"), (370, -3)])], entities: [
            F.entity("LWPOLYLINE", [(5, "2A"), (330, "1F"), (100, "AcDbEntity"), (8, "0"), (100, "AcDbPolyline"), (90, 4), (70, 1), (43, 0), (10, 0), (20, 0), (10, 2), (20, 0), (10, 2), (20, 1), (10, 0), (20, 1)]),
        ]).pairs + F.section("OBJECTS", [(0, "DICTIONARY"), (5, "C"), (330, "0"), (100, "AcDbDictionary")])
        var autocadFixture = F(autocad)
        autocadFixture.pairs.removeAll { $0 == (0, "EOF") }
        autocadFixture.pairs.append((0, "EOF"))
        let rectangle = try dxfImport(autocadFixture)
        #expect(rectangle.bounds.size == Rect(x: 0, y: 0, width: 144, height: 72).size)
        #expect(rectangle.scenePaths[0].contours[0].closed)
        #expect(rectangle.scenePaths[0].contours[0].segments.count == 4)
        // LibreCAD: R12 POLYLINE with VERTEX and SEQEND, no $INSUNITS.
        let librecad = F.drawing(entities: [
            F.entity("POLYLINE", [(8, "0"), (66, 1), (10, 0), (20, 0), (70, 0)]),
            F.entity("VERTEX", [(8, "0"), (10, 0), (20, 0)]),
            F.entity("VERTEX", [(8, "0"), (10, 1), (20, 1)]),
            F.entity("SEQEND", [(8, "0")]),
        ])
        let inches = try dxfImport(librecad)
        #expect(inches.bounds.width == 72 && inches.bounds.height == 72)
        let millimetres = try dxfImport(librecad, DXFImportOptions(units: .millimeters))
        #expect(abs(millimetres.bounds.width - 72 / 25.4) < 1e-9)
        // Blender: no header, no tables, an ENTITIES section only.
        let blender = DXFImportFixture(F.section("ENTITIES", F.entity("LINE", [(8, "Cube"), (10, 0), (20, 0), (30, 0), (11, 1), (21, 0), (31, 1)])) + [(0, "EOF")])
        let lines = try DXFImporter().convert(blender.ascii, name: "cube.dxf", options: DXFImportOptions(units: .points))
        #expect(lines.nodes.map(\.name) == ["Cube"])
        #expect(lines.bounds == Rect(x: 0, y: 0, width: 1, height: 0))
    }

    @Test func unitsTable() {
        let expected: [Int: Double] = [1: 72, 2: 864, 4: 72 / 25.4, 5: 720 / 25.4, 6: 72_000 / 25.4, 9: 0.072, 10: 2592]
        for (code, points) in expected {
            #expect(abs(DXFImportConverter.pointsPerUnit(code)! - points) < 1e-9)
        }
        for code in [3, 7, 8, 11, 12, 13, 14, 15, 16, 21] {
            #expect(DXFImportConverter.pointsPerUnit(code)! > 0)
        }
        #expect(DXFImportConverter.pointsPerUnit(0) == nil)
        #expect(DXFImportConverter.pointsPerUnit(19) == nil)
        #expect(DXFImportOptions.Units.points.points == 1)
    }

    @Test func unknownUnitsFallBackToTheOption() throws {
        let scene = try dxfImport(F.drawing(units: 19, entities: [F.entity("LINE", [(10, 0), (20, 0), (11, 1), (21, 0)])]), DXFImportOptions(units: .points))
        #expect(scene.bounds.width == 1)
        #expect(scene.notes.contains { $0.contains("$INSUNITS 19") })
    }

    @Test func refusals() throws {
        let importer = DXFImporter()
        let line = F.entity("LINE", [(10, 0), (20, 0), (11, 1), (21, 0)])
        let bad: [Data] = [
            Data("hello".utf8),
            Data("0\nSECTION\n2\n".utf8),                                       // odd line count
            Data("zero\nSECTION\n".utf8),                                        // not a group code
            Data("0\nSECTION\n2\nENTITIES\n".utf8),                              // no ENDSEC
            Data("999\ncomment\n0\nEOF\n".utf8),                                 // no section
            Data("AutoCAD Binary DXF\r\n".utf8) + Data([0x1A, 0x00]),            // sentinel only
            F.drawing(entities: [line]).binary(wide: true).dropLast(3),          // cut short
            F.drawing(entities: [line]).binary(wide: false).dropLast(1),
            Data("AutoCAD Binary DXF\r\n".utf8) + Data([0x1A, 0x00, 0x00, 0x00, 0x53]), // unterminated string
            Data("AutoCAD Binary DXF\r\n".utf8) + Data([0x1A, 0x00, 0xFE, 0x01, 0x00]),  // undefined code
            Data("AutoCAD Binary DXF\r\n".utf8) + Data([0x1A, 0x00, 0xFF, 0x01]),        // cut-short wide escape
            Data("AutoCAD Binary DXF\r\n".utf8) + Data([0x1A, 0x00, 0x00, 0x53, 0x00, 0xFF, 0x36, 0x01]), // chunk without length
            Data("AutoCAD Binary DXF\r\n".utf8) + Data([0x1A, 0x00, 0x00, 0x53, 0x00, 0xFF, 0x36, 0x01, 0x05, 0x01]), // chunk cut short
            Data("AutoCAD Binary DXF\r\n".utf8) + Data([0x1A, 0x00, 0x00, 0x53, 0x00, 0x0A, 0x01]), // double cut short
            Data("AutoCAD Binary DXF\r\n".utf8) + Data([0x1A, 0x00, 0x00, 0x00, 0x53, 0x00, 0x00]), // wide code cut short
        ]
        for data in bad {
            #expect(throws: ImportError.unreadable(name: "bad.dxf", reason: "it is not a DXF file or it is cut short.")) {
                try importer.convert(data, name: "bad.dxf", options: DXFImportOptions())
            }
        }
        #expect(throws: ImportError.empty(name: "empty.dxf")) {
            try importer.convert(F.drawing(entities: [F.entity("POINT", [(10, 1), (20, 1)])]).ascii, name: "empty.dxf", options: DXFImportOptions())
        }
        #expect(throws: ImportError.tooLarge(name: "big.dxf", bytes: F.drawing(entities: [line]).ascii.count, limit: 10)) {
            try importer.convert(F.drawing(entities: [line]).ascii, name: "big.dxf", format: .dxf, options: DXFImportOptions.schema.defaults, context: ImportContext(maximumFileSize: 10))
        }
    }

    @Test func binaryValueKinds() throws {
        // Every value encoding round-trips: ints, int64, bools, chunks and extended data.
        let fixture = F.drawing(entities: [F.entity("LINE", [
            (5, "1F"), (160, 12), (290, 1), (310, "DEADBEEF"), (1071, 7), (90, 3), (1000, "extra"), (10, 0), (20, 0), (11, 3), (21, 4),
        ])])
        for wide in [false, true] {
            let drawing = try #require(DXFImportDrawing(fixture.binary(wide: wide)))
            let entity = drawing.entities[0]
            #expect(entity.string(310) == "DEADBEEF")
            #expect(entity.int(160) == 12 && entity.int(290) == 1 && entity.int(1071) == 7)
            #expect(entity.string(1000) == "extra")
            #expect(entity.point(11) == Point(x: 3, y: 4))
        }
        #expect(DXFImportDrawing.binaryValue(-5) == nil)
    }

    @Test func encodings() throws {
        var bytes = [UInt8](F.drawing(entities: [F.entity("TEXT", [(1, "X"), (10, 0), (20, 0), (40, 1)])]).ascii)
        let index = bytes.lastIndex(of: UInt8(ascii: "X"))!
        bytes.replaceSubrange(index...index, with: [0x80, 0xE9])                // € é in Windows-1252
        let scene = try DXFImporter().convert(Data(bytes), name: "a.dxf", options: DXFImportOptions())
        #expect(scene.texts == ["€é"])
        #expect(DXFImportDrawing.unescape("D\\U+00E9coupe") == "Découpe")
        #expect(DXFImportDrawing.unescape("a\\U+zzzzb") == "a\\U+zzzzb")
        #expect(DXFImportDrawing.windows1252(0x41) == 0x41)
        #expect(DXFImportDrawing.windows1252(0x9F) == 0x178)
        let pair = DXFImportPair(code: 70, value: " 2.0 ")
        #expect(pair.int == 2)
        #expect(DXFImportPair(code: 1, value: "x").double == 0)
    }

    @Test func sequencesAndSectionsTolerateOddOrder() throws {
        // A POLYLINE cut short by another entity, a stray pair before the first record, an
        // unknown section, an entity list without EOF.
        let pairs: [(Int, String)] = [(999, "comment"), (0, "SECTION"), (2, "THUMBNAILIMAGE"), (90, "0"), (0, "ENDSEC"), (0, "LINE")] + F.section("ENTITIES", [(8, "stray")]
            + F.entity("POLYLINE", [(66, 1), (70, 0)]) + F.entity("VERTEX", [(10, 0), (20, 0)]) + F.entity("VERTEX", [(10, 1), (20, 0)])
            + F.entity("LINE", [(10, 0), (20, 1), (11, 1), (21, 1)])
            + F.entity("POLYLINE", [(66, 1), (70, 0)]) + F.entity("VERTEX", [(10, 0), (20, 2)]) + F.entity("VERTEX", [(10, 1), (20, 2)]))
        let scene = try dxfImport(F(pairs), DXFImportOptions(units: .points))
        #expect(scene.scenePaths.count == 3)
        #expect(scene.bounds.height == 2)
    }

    @Test func oddRecordsAndCutShortStructures() throws {
        // Header values before any variable, layer and block records without names, duplicate
        // layers, a hatch whose boundary stops early, text with no text code.
        var pairs = F.section("HEADER", [(70, "1"), (9, "$INSUNITS"), (70, "1")])
        pairs += F.section("TABLES", F.layer("A", color: 1) + F.entity("LAYER", [(62, 3)]) + F.layer("A", color: 5))
        pairs += F.section("BLOCKS", F.entity("BLOCK", [(10, 0), (20, 0)]) + F.entity("LINE", [(10, 0), (20, 0), (11, 1), (21, 0)]) + F.entity("ENDBLK", []))
        pairs += F.section("ENTITIES",
            F.entity("LINE", [(8, "A"), (10, 0), (20, 0), (11, 1), (21, 0)])
            + F.entity("INSERT", [(2, ""), (10, 2), (20, 0)])
            + F.entity("HATCH", [(70, 1), (91, 3), (92, 2), (72, 1), (73, 1), (93, 3), (10, 0), (20, 0), (42, 0), (10, 1), (20, 0), (10, 1)])
            + F.entity("HATCH", [(70, 1), (91, 1), (92, 1), (93, 2), (72, 3), (10, 5), (20, 5), (11, 1), (21, 0), (40, 0.5), (50, 0), (51, 180), (73, 0), (72, 4)])
            + F.entity("TEXT", [(10, 0), (20, 0)])
            + F.entity("MTEXT", [(10, 0), (20, 0), (3, "only\\P\\Pchunks")]))
        pairs.append((0, "EOF"))
        let scene = try dxfImport(F(pairs))
        #expect(scene.nodes.map(\.name) == ["A", "0"])
        #expect(dxfImportColor(scene, 0) == Color(red: 1, green: 0, blue: 0))
        #expect(scene.scenePaths.count == 4)
        #expect(scene.texts == ["onlychunks"])
        #expect(DXFImportText.plain("x\\H2") == "x")
        let text = try dxfImport(F.drawing(entities: [F.entity("TEXT", [(1, "Low"), (10, 0), (20, 0), (11, 0), (21, 0), (40, 2), (73, 1)])]))
        #expect(text.texts == ["Low"])
    }

    // MARK: Polylines and arcs

    @Test func bulgedPolylinesMatchTheirArcs() throws {
        // A semicircle of radius 1 inch (bulge 1) and a quarter arc clockwise (bulge −tan 22.5°).
        let fixture = F.drawing(units: 1, entities: [
            F.entity("LWPOLYLINE", [(90, 2), (70, 0), (10, -1), (20, 0), (42, 1), (10, 1), (20, 0)]),
            F.entity("LWPOLYLINE", [(90, 2), (70, 0), (43, 0.1), (10, 5), (20, 0), (42, -tan(Double.pi / 8)), (10, 6), (20, -1)]),
        ])
        let scene = try dxfImport(fixture)
        let paths = scene.scenePaths
        // Counter-clockwise in y-up from (−1, 0) to (1, 0) passes (0, −1), which is below: after
        // the flip the arc is on the larger-y side of its chord.
        let semicircle = paths[0].contours[0]
        let center = Point(x: semicircle.start.x + 72, y: semicircle.start.y)
        for point in dxfImportSamples(semicircle) {
            #expect(abs(point.distance(to: center) - 72) < 0.01)
            #expect(point.y >= center.y - 1e-9)
        }
        let quarter = paths[1].contours[0]
        let quarterCenter = Point(x: quarter.start.x, y: quarter.start.y + 72)
        for point in dxfImportSamples(quarter) {
            #expect(abs(point.distance(to: quarterCenter) - 72) < 0.01)
        }
        #expect(abs(paths[1].stroke!.style.width - 7.2) < 1e-9)
    }

    @Test func heavyPolylinesClosedMeshesAndSplineFrames() throws {
        let fixture = F.drawing(units: 4, entities: [
            F.entity("POLYLINE", [(66, 1), (70, 1), (40, 2)]),
            F.entity("VERTEX", [(10, 0), (20, 0), (42, 0.5)]),
            F.entity("VERTEX", [(10, 10), (20, 0), (70, 16)]),               // frame point: skipped
            F.entity("VERTEX", [(10, 10), (20, 10)]),
            F.entity("SEQEND", []),
            F.entity("POLYLINE", [(66, 1), (70, 64)]),
            F.entity("VERTEX", [(10, 0), (20, 0), (70, 128)]),
            F.entity("SEQEND", []),
            F.entity("POLYLINE", [(66, 1), (70, 0)]),
            F.entity("SEQEND", []),
        ])
        let scene = try dxfImport(fixture)
        let paths = scene.scenePaths
        #expect(paths.count == 1)
        let contour = paths[0].contours[0]
        #expect(contour.closed)
        #expect(contour.segments.count >= 3)
        #expect(abs(paths[0].stroke!.style.width - 2 * 72 / 25.4) < 1e-9)
        #expect(scene.notes.contains { $0.contains("polyface and polygon meshes") })
    }

    @Test func circlesArcsEllipsesAndExtrusion() throws {
        let fixture = F.drawing(units: 1, entities: [
            F.entity("CIRCLE", [(10, 0), (20, 0), (40, 1)]),
            F.entity("ARC", [(10, 5), (20, 0), (40, 1), (50, 270), (51, 90)]),          // through 0°
            F.entity("ARC", [(10, 5), (20, 0), (40, 1), (50, 0), (51, 90), (230, -1)]), // mirrored
            F.entity("ELLIPSE", [(10, 10), (20, 0), (11, 2), (21, 0), (40, 0.5)]),
            F.entity("ELLIPSE", [(10, 10), (20, 5), (11, 0), (21, 2), (40, 0.5), (41, 0), (42, Double.pi / 2)]),
            F.entity("CIRCLE", [(10, 0), (20, 5), (40, 1), (210, 0.6), (220, 0), (230, 0.8)]),
        ])
        let scene = try dxfImport(fixture)
        let paths = scene.scenePaths
        #expect(paths.count == 6)
        #expect(paths[0].contours[0].closed)
        #expect(paths[0].contours[0].segments.count == 6)
        // The arc from 270° to 90° counter-clockwise has its right half: every x ≥ the centre's.
        let arc = dxfImportSamples(paths[1].contours[0])
        let arcCenterX = paths[1].contours[0].start.x
        #expect(arc.allSatisfy { $0.x >= arcCenterX - 1e-9 })
        #expect(abs(arc.map(\.x).max()! - arcCenterX - 72) < 0.01)
        // Mirrored: the OCS x axis points left, so the quarter arc lies left of x = −5 inches.
        let mirrored = dxfImportSamples(paths[2].contours[0])
        #expect(mirrored.allSatisfy { $0.x <= arcCenterX - 5 * 72 * 2 + 72 + 1e-6 })
        #expect(paths[3].contours[0].closed)
        let ellipse = dxfImportSamples(paths[3].contours[0])
        #expect(abs(ellipse.map(\.x).max()! - ellipse.map(\.x).min()! - 4 * 72) < 0.01)
        #expect(abs(ellipse.map(\.y).max()! - ellipse.map(\.y).min()! - 2 * 72) < 0.01)
        #expect(!paths[4].contours[0].closed)
        #expect(scene.notes.contains { $0.contains("tilted extrusion") })
    }

    // MARK: Splines

    @Test func splinesConvertExactlyToBeziers() throws {
        let controls = [Point(x: 0, y: 0), Point(x: 1, y: 3), Point(x: 3, y: 4), Point(x: 5, y: 1), Point(x: 6, y: 2), Point(x: 8, y: 0)]
        for (degree, knots) in [(3, [0.0, 0, 0, 0, 1, 2, 4, 4, 4, 4]), (2, [0.0, 0, 0, 1, 1, 2, 3, 3, 3]), (1, [0.0, 0, 1, 2, 3, 4, 5, 5])] {
            var fields: [(Int, Any)] = [(70, 8), (71, degree), (72, knots.count), (73, controls.count)]
            fields += knots.map { (40, $0) as (Int, Any) }
            fields += controls.flatMap { [(10, $0.x), (20, $0.y), (30, 0)] as [(Int, Any)] }
            let scene = try dxfImport(F.drawing(entities: [F.entity("SPLINE", fields)]), DXFImportOptions(units: .points))
            let contour = scene.scenePaths[0].contours[0]
            // Undo the flip and the shift: a clamped spline starts on its first control point.
            let flipped = contour.applying(AffineTransform(a: 1, b: 0, c: 0, d: -1, tx: 0, ty: 0))
            let imported = flipped.applying(.translation(x: controls[0].x - flipped.start.x, y: controls[0].y - flipped.start.y))
            let spans = (degree..<controls.count).filter { knots[$0 + 1] > knots[$0] }
            #expect(imported.segments.count == spans.count)
            var current = imported.start
            for (segment, span) in zip(imported.segments, spans) {
                for step in 0...10 {
                    let t = Double(step) / 10
                    let u = knots[span] + t * (knots[span + 1] - knots[span])
                    let expected = DXFImportSpline.evaluate(degree: degree, knots: knots, controls: controls, weights: [], at: u, span: span)
                    let got: Point
                    switch segment {
                    case .line(let end): got = Point.lerp(current, end, t)
                    case .cubic(let c1, let c2, let end): got = CubicBezier(current, c1, c2, end).evaluate(t)
                    }
                    #expect(dxfImportClose(got, expected, 1e-9), "degree \(degree) span \(span) t \(t)")
                }
                current = segment.end
            }
            #expect(dxfImportClose(imported.end, controls.last!, 1e-9))
        }
    }

    @Test func rationalHighDegreeFitPointAndClosedSplines() throws {
        let w = 2.0.squareRoot() / 2
        let rational = F.entity("SPLINE", [(71, 2), (40, 0), (40, 0), (40, 0), (40, 1), (40, 1), (40, 1), (10, 1), (20, 0), (41, 1), (10, 1), (20, 1), (41, w), (10, 0), (20, 1), (41, 1)])
        let high = F.entity("SPLINE", [(71, 4)] + [0, 0, 0, 0, 0, 1, 1, 1, 1, 1].map { (40, $0) as (Int, Any) } + [(10, 0), (20, 0), (10, 1), (20, 2), (10, 2), (20, -2), (10, 3), (20, 2), (10, 4), (20, 0)])
        let fits = F.entity("SPLINE", [(70, 1), (71, 3), (11, 0), (21, 0), (11, 2), (21, 0), (11, 2), (21, 2)])
        let openFits = F.entity("SPLINE", [(71, 3), (11, 5), (21, 0), (11, 6), (21, 1), (11, 7), (21, 0)])
        let nothing = F.entity("SPLINE", [(71, 3), (10, 0), (20, 0)])
        let scene = try dxfImport(F.drawing(entities: [rational, high, fits, openFits, nothing]), DXFImportOptions(units: .points))
        let paths = scene.scenePaths
        #expect(paths.count == 4)
        // The rational quarter circle is flattened onto the unit circle.
        let quarter = paths[0].contours[0]
        #expect(quarter.segments.allSatisfy { if case .line = $0 { return true } else { return false } })
        let center = Point(x: quarter.start.x - 1, y: quarter.start.y)
        for point in [quarter.start] + quarter.segments.map(\.end) {
            #expect(abs(point.distance(to: center) - 1) < 0.01)
        }
        #expect(paths[1].contours[0].segments.count >= 4)
        // Fit points are passed through, and the closed flag closes the curve.
        let closed = paths[2].contours[0]
        #expect(closed.closed)
        #expect(closed.segments.count == 3)
        #expect(!paths[3].contours[0].closed)
        #expect(paths[3].contours[0].segments.count == 2)
        #expect(scene.notes.contains { $0.contains("SPLINE without control or fit points") })
    }

    // MARK: Fills

    @Test func hatchesAndSolids() throws {
        let polylineHatch = F.entity("HATCH", [(10, 0), (20, 0), (30, 0), (2, "SOLID"), (70, 1), (71, 0), (91, 2),
            (92, 2), (72, 1), (73, 1), (93, 3), (10, 0), (20, 0), (42, 0), (10, 4), (20, 0), (42, 0.4), (10, 4), (20, 4), (42, 0), (97, 0),
            (92, 2), (72, 0), (73, 1), (93, 3), (10, 1), (20, 1), (10, 2), (20, 1), (10, 2), (20, 2), (97, 0),
            (75, 0), (76, 1), (98, 1), (10, 1), (20, 1)])
        let edgeHatch = F.entity("HATCH", [(62, 3), (2, "ANSI31"), (70, 0), (91, 1),
            (92, 1), (93, 5),
            (72, 1), (10, 10), (20, 0), (11, 14), (21, 0),
            (72, 2), (10, 14), (20, 2), (40, 2), (50, 270), (51, 90), (73, 1),
            (72, 3), (10, 12), (20, 4), (11, 2), (21, 0), (40, 0.5), (50, 0), (51, 180), (73, 1),
            (72, 2), (10, 10), (20, 2), (40, 2), (50, 90), (51, 180), (73, 0),
            (72, 4), (94, 2), (73, 1), (74, 0), (95, 6), (96, 3), (40, 0), (40, 0), (40, 0), (40, 1), (40, 1), (40, 1), (10, 8), (20, 2), (42, 1), (10, 8), (20, 0), (42, 0.5), (10, 10), (20, 0), (42, 1),
            (97, 0)])
        let emptyHatch = F.entity("HATCH", [(70, 1)])
        let solid = F.entity("SOLID", [(62, 255), (10, 20), (20, 0), (11, 22), (21, 0), (12, 20), (22, 2), (13, 22), (23, 2)])
        let triangle = F.entity("TRACE", [(62, 5), (10, 30), (20, 0), (11, 32), (21, 0), (12, 31), (22, 2)])
        let scene = try dxfImport(F.drawing(entities: [polylineHatch, edgeHatch, emptyHatch, solid, triangle]), DXFImportOptions(units: .points))
        let paths = scene.scenePaths
        #expect(paths.count == 4)
        #expect(paths[0].fillRule == .evenOdd && paths[0].stroke == nil)
        #expect(paths[0].contours.count == 2)
        #expect(paths[0].contours.allSatisfy { $0.closed })
        #expect(paths[1].fill == .solid(Color(red: 0, green: 1, blue: 0)))
        #expect(paths[1].contours.count == 1)
        #expect(scene.notes.contains { $0.contains("hatch pattern") })
        // SOLID's corners are 1-2-4-3: the square is not a bow tie.
        let square = paths[2].contours[0]
        #expect(square.segments.map(\.end).map(\.x) == [square.start.x + 2, square.start.x + 2, square.start.x])
        #expect(paths[2].fill == .solid(.black))                 // white converted
        #expect(paths[3].contours[0].segments.count == 3)
        let white = try dxfImport(F.drawing(entities: [solid]), DXFImportOptions(whiteFillsToBlack: false, units: .points))
        #expect(white.scenePaths[0].fill == .solid(.white))
    }

    // MARK: Text

    @Test func textJustificationRotationAndSpecials() throws {
        let entities = [
            F.entity("TEXT", [(1, "Left %%d %%c %%p %%% %%uU %%065 %%x"), (10, 0), (20, 0), (40, 10)]),
            F.entity("TEXT", [(1, "Center"), (10, 0), (20, 0), (11, 100), (21, 0), (40, 10), (72, 1), (73, 2)]),
            F.entity("TEXT", [(1, "Right"), (10, 0), (20, 0), (11, 100), (21, 50), (40, 10), (72, 2), (73, 3), (50, 90)]),
            F.entity("TEXT", [(1, "Middle"), (10, 0), (20, 0), (11, 0), (21, 100), (40, 10), (72, 4), (73, 1)]),
            F.entity("TEXT", [(1, "Fit"), (10, 0), (20, 0), (40, 10), (72, 5), (62, 255)]),
            F.entity("TEXT", [(1, ""), (10, 0), (20, 0), (40, 10)]),
        ]
        let scene = try dxfImport(F.drawing(entities: entities), DXFImportOptions(units: .points))
        #expect(scene.texts == ["Left ° ⌀ ± % U A %%x", "Center", "Right", "Middle", "Fit"])
        let texts = scene.nodes.flatMap(\.descendants).compactMap { node -> ImportedText? in
            if case .text(let text) = node { return text } else { return nil }
        }
        // Cap height 10 pt: the font size is the height over Helvetica's cap-height ratio.
        #expect(abs(texts[0].runs[0].fontSize * DXFImportConverter.capHeight - 10) < 1e-9)
        #expect(texts[0].runs[0].fontName == "Helvetica")
        let centered = texts[1].runs[0]
        #expect(abs(centered.origin.x + DXFImportConverter.width(of: "Center", size: centered.fontSize) / 2) < 1e-9)
        // Rotated 90°: the baseline runs up the page (−y).
        #expect(abs(texts[2].transform.a) < 1e-9 && abs(texts[2].transform.b + 1) < 1e-9)
        #expect(texts[4].runs[0].fill == .solid(.black))
        let bounds = DXFImportConverter.bounds(of: .text(texts[0]), .identity)
        #expect(bounds.count == 1 && bounds[0].width > 0)
    }

    @Test func multilineTextStripsFormatting() throws {
        let mtext = F.entity("MTEXT", [(10, 0), (20, 0), (40, 5), (71, 5), (3, "{\\fArial|b1;Bold}\\Pline\\~two \\\\ \\{x\\} "), (1, "\\S1^2; \\S3#4;\\Lu\\l\\H2x;"), (11, 0), (21, 1)])
        let empty = F.entity("MTEXT", [(10, 0), (20, 0), (1, "{\\C1;}")])
        let tail = F.entity("MTEXT", [(10, 0), (20, 0), (1, "end\\")])
        let scene = try dxfImport(F.drawing(entities: [mtext, empty, tail]), DXFImportOptions(units: .points))
        #expect(scene.texts == ["Boldline\u{00A0}two \\ {x} 1/2 3/4u", "end\\"])
        #expect(DXFImportText.plain("a\\nb\\S1^2") == "a\nb1/2")
        let text = try #require(scene.nodes.flatMap(\.descendants).compactMap { node -> ImportedText? in
            if case .text(let text) = node { return text } else { return nil }
        }.first)
        #expect(text.runs.count == 2)
        // Direction (0, 1): rotated a quarter turn.
        #expect(abs(text.transform.b + 1) < 1e-9)
        #expect(DXFImportText.specials("100%%") == "100%%")
    }

    // MARK: Blocks

    @Test func blocksNestedArraysAttributesAndDimensions() throws {
        let square = F.entity("LWPOLYLINE", [(8, "0"), (62, 0), (90, 4), (70, 1), (10, 0), (20, 0), (10, 1), (20, 0), (10, 1), (20, 1), (10, 0), (20, 1)])
        let blocks: [(String, Point, [[(Int, String)]])] = [
            ("Square", Point(x: 0, y: 0), [square, F.entity("ATTDEF", [(2, "TAG"), (1, "x")])]),
            ("Pair", Point(x: 1, y: 0), [F.entity("INSERT", [(8, "0"), (2, "Square"), (10, 1), (20, 0)]), F.entity("INSERT", [(8, "Red"), (2, "Square"), (10, 3), (20, 0)])]),
            ("Loop", Point(x: 0, y: 0), [F.entity("INSERT", [(2, "Loop"), (10, 0), (20, 0)])]),
            ("Hidden", Point(x: 0, y: 0), [F.entity("LINE", [(8, "Off"), (10, 0), (20, 0), (11, 1), (21, 0)])]),
            ("*D1", Point(x: 0, y: 0), [F.entity("LINE", [(10, 0), (20, 0), (11, 2), (21, 0)])]),
        ]
        let entities = [
            F.entity("INSERT", [(8, "Blue"), (2, "Pair"), (10, 10), (20, 10), (41, 2), (42, 2), (62, 5)]),
            F.entity("INSERT", [(8, "Blue"), (66, 1), (2, "Square"), (10, 20), (20, 0), (50, 90), (70, 3), (71, 2), (44, 2), (45, 3), (62, 1)]),
            F.entity("ATTRIB", [(1, "shown"), (2, "TAG"), (10, 20), (20, 5), (40, 1), (70, 0)]),
            F.entity("ATTRIB", [(1, "secret"), (2, "TAG2"), (10, 20), (20, 7), (40, 1), (70, 1), (72, 1), (74, 3), (11, 20), (21, 7)]),
            F.entity("SEQEND", []),
            F.entity("INSERT", [(2, "Missing"), (10, 0), (20, 0)]),
            F.entity("INSERT", [(2, "Loop"), (10, 0), (20, 0)]),
            F.entity("INSERT", [(2, "Hidden"), (10, 0), (20, 0)]),
            F.entity("INSERT", [(10, 0), (20, 0)]),
            F.entity("DIMENSION", [(2, "*D1"), (10, 0), (20, 0)]),
            F.entity("DIMENSION", [(10, 0), (20, 0)]),
        ]
        let layers = [F.layer("Blue", color: 4), F.layer("Red", color: 1), F.layer("Off", color: -3)]
        let fixture = F.drawing(layers: layers, blocks: blocks, entities: entities)
        let scene = try dxfImport(fixture, DXFImportOptions(units: .points))
        #expect(scene.nodes.map(\.name) == ["Blue", "0"])
        let blue = scene.scenePaths.filter { $0.groupNames.first == "Blue" }
        // Pair: two squares; the array: 3 × 2 squares.
        #expect(blue.count == 8)
        // BYBLOCK takes the INSERT's colour (blue, index 5); nested, the inner INSERT on layer 0
        // is BYLAYER, which in a block is the outer INSERT's layer; on layer Red it is red.
        #expect(blue[0].stroke?.paint == .solid(Color(red: 0, green: 1, blue: 1)))
        #expect(blue[0].groupNames == ["Blue", "Pair", "Square"])
        #expect(blue[1].stroke?.paint == .solid(Color(red: 1, green: 0, blue: 0)))
        // Scaled by 2 about the base point (1, 0): the first square spans 2 points.
        let first = blue[0].contours[0]
        let xs = first.allPoints.map(\.x)
        #expect(abs(xs.max()! - xs.min()! - 2) < 1e-9)
        // Array squares rotated 90° are red (index 1).
        #expect(blue[2].stroke?.paint == .solid(Color(red: 1, green: 0, blue: 0)))
        #expect(scene.texts == ["shown"])
        #expect(scene.notes.contains { $0.contains("missing block “Missing”") })
        #expect(scene.notes.contains { $0.contains("“Loop” refers to itself") })
        let withInvisible = try dxfImport(fixture, DXFImportOptions(importInvisibleAttributes: true, units: .points))
        #expect(withInvisible.texts == ["shown", "secret"])
        // The dimension's block is drawn once, on layer 0.
        #expect(scene.scenePaths.filter { $0.groupNames == ["0", "*D1"] }.count == 1)
    }

    // MARK: Colours and weights

    @Test func colorIndexTable() {
        let table = DXFImportColors.table
        #expect(table.count == 256)
        #expect(table[1] == 0xFF0000 && table[5] == 0x0000FF && table[8] == 0x414141 && table[255] == 0xFFFFFF)
        #expect(table[10] == 0xFF0000)
        #expect(table[11] == 0xFFAAAA)
        #expect(table[12] == 0xBD0000)
        #expect(table[13] == 0xBD7E7E)
        #expect(table[50] == 0xFFFF00)
        #expect(table[130] == 0x00FFFF)
        #expect(table[250] == 0x333333)
        #expect(DXFImportColors.color(index: 7) == .black)
        #expect(DXFImportColors.color(index: 300) == .black)
        #expect(DXFImportColors.color(index: 3) == Color(red: 0, green: 1, blue: 0))
        #expect(DXFImportColors.isWhite(DXFImportColors.color(index: 255)))
        #expect(!DXFImportColors.isWhite(DXFImportColors.color(index: 254)))
    }

    @Test func colorsLineweightsAndWhiteStrokes() throws {
        let layers = [F.layer("True", color: 3, extra: [(420, 0x123456), (370, 50)]), F.layer("Plain", color: 2)]
        let entities = [
            F.entity("LINE", [(8, "True"), (10, 0), (20, 0), (11, 1), (21, 0)]),                                  // layer true colour, 0.5 mm
            F.entity("LINE", [(8, "Plain"), (420, 0xFF8000), (370, 0), (10, 0), (20, 1), (11, 1), (21, 1)]),        // own true colour, hairline
            F.entity("LINE", [(8, "Plain"), (62, 255), (370, -2), (10, 0), (20, 2), (11, 1), (21, 2)]),            // white, BYBLOCK weight
            F.entity("LINE", [(8, "Plain"), (62, 0), (370, 100), (10, 0), (20, 3), (11, 1), (21, 3)]),             // BYBLOCK colour at top
            F.entity("LINE", [(8, "Nowhere"), (10, 0), (20, 4), (11, 1), (21, 4)]),                               // no layer record
        ]
        let scene = try dxfImport(F.drawing(layers: layers, entities: entities), DXFImportOptions(units: .points))
        let paths = scene.scenePaths
        #expect(dxfImportColor(scene, 0) == DXFImportColors.color(rgb: 0x123456))
        #expect(abs(paths[0].stroke!.style.width - 0.5 * 72 / 25.4) < 1e-9)
        #expect(dxfImportColor(scene, 1) == DXFImportColors.color(rgb: 0xFF8000))
        #expect(paths[1].stroke!.style.width == 0)
        #expect(dxfImportColor(scene, 2) == .black)
        #expect(abs(paths[2].stroke!.style.width - 0.25 * 72 / 25.4) < 1e-9)
        #expect(dxfImportColor(scene, 3) == .black)
        #expect(abs(paths[3].stroke!.style.width - 72 / 25.4) < 1e-9)
        #expect(dxfImportColor(scene, 4) == .black)
        #expect(scene.nodes.map(\.name) == ["True", "Plain", "Nowhere"])
        let kept = try dxfImport(F.drawing(layers: layers, entities: entities), DXFImportOptions(whiteStrokesToBlack: false, units: .points))
        #expect(dxfImportColor(kept, 2) == .white)
    }

    @Test func hiddenAndFrozenLayersAreLeftOut() throws {
        let layers = [F.layer("Off", color: -1), F.layer("Frozen", flags: 1), F.layer("On")]
        let entities = [
            F.entity("LINE", [(8, "Off"), (10, 0), (20, 0), (11, 1), (21, 0)]),
            F.entity("LINE", [(8, "Frozen"), (10, 0), (20, 0), (11, 1), (21, 0)]),
            F.entity("LINE", [(8, "On"), (10, 0), (20, 0), (11, 1), (21, 0)]),
            F.entity("3DFACE", [(8, "On")]),
            F.entity("3DFACE", [(8, "On")]),
            F.entity("VIEWPORT", [(8, "On")]),
        ]
        let scene = try dxfImport(F.drawing(layers: layers, entities: entities))
        #expect(scene.nodes.map(\.name) == ["On"])
        #expect(scene.notes.contains("Layers that are off or frozen were left out: Frozen, Off."))
        #expect(scene.notes.contains("Entities without a two-dimensional appearance were left out: 3DFACE."))
    }

    // MARK: Framework

    @Test func probeSchemaAndRegistry() throws {
        let data = F.drawing(units: 1, entities: [F.entity("LINE", [(10, 0), (20, 0), (11, 2), (21, 1)])]).ascii
        let importer = DXFImporter()
        #expect(importer.formats == [.dxf])
        #expect(importer.optionsSchema(for: .dxf) == DXFImportOptions.schema)
        let descriptor = try importer.probe(data, name: "a.dxf", format: .dxf)
        #expect(descriptor.naturalSize == Rect(x: 0, y: 0, width: 144, height: 72))
        let registry = ImportRegistry(importers: [importer])
        #expect(registry.format(of: data, name: "drawing.txt") == .dxf)
        let scene = try registry.convert(data, name: "a.dxf", options: DXFImportOptions(units: .points).values)
        #expect(scene.bounds.width == 144)
        let binary = F.drawing(entities: [F.entity("LINE", [(10, 0), (20, 0), (11, 2), (21, 1)])]).binary(wide: true)
        #expect(ImportFormat.sniff(binary) == .dxf)
    }

    // MARK: Round trips through the exporter

    /// A page of shapes and its exported DXF read back: `compare` checks each imported path
    /// against the source geometry, shifted so the extents' corners meet.
    private func roundTrip(_ options: DXFOptions, importOptions: DXFImportOptions = DXFImportOptions(), check: (ImportedScene, Vector) throws -> Void) throws {
        let cut = Corpus.node(1)
        let items: [DisplayItem] = [
            .group(GroupItem(children: [Corpus.path(Corpus.rect(20, 30, 60, 40), [Corpus.fill(.solid(.black))])])),
            Corpus.path(Corpus.ellipse(100, 30, 80, 60), [Corpus.stroke(.solid(.black), width: 1)]),
        ]
        let page = Corpus.page(items, nodes: [cut, nil])
        let scene = Corpus.scene([page], nodes: [cut: ExportNodeInfo(name: "Cut", isLayer: true)])
        let data = try DXFExporter().data(scene: scene, page: 0, options: options).data
        let imported = try DXFImporter().convert(data, name: "trip.dxf", options: importOptions)
        // Source extents: x 20...180, y 30...90; imported extents start at the origin.
        try check(imported, Vector(dx: -20, dy: -30))
    }

    @Test func roundTripPolylinesInMillimetres() throws {
        try roundTrip(DXFOptions(version: .v2018, units: .millimeters)) { scene, shift in
            #expect(abs(scene.bounds.width - 160) < 0.01 && abs(scene.bounds.height - 60) < 0.01)
            #expect(scene.nodes.map(\.name) == ["0", "Cut"] || scene.nodes.map(\.name) == ["Cut", "0"])
            let rect = try #require(scene.scenePaths.first { $0.groupNames == ["Cut"] })
            let expected = [Point(x: 20, y: 30), Point(x: 80, y: 30), Point(x: 80, y: 70), Point(x: 20, y: 70)].map { $0 + shift }
            let got = [rect.contours[0].start] + rect.contours[0].segments.dropLast().map(\.end)
            #expect(zip(got, expected).allSatisfy { dxfImportClose($0, $1, 1e-4) })
            #expect(rect.contours[0].closed)
            // The ellipse, flattened within 0.1 mm, stays on the ellipse.
            let ellipse = try #require(scene.scenePaths.first { $0.groupNames == ["0"] })
            for point in dxfImportSamples(ellipse.contours[0]) {
                let r = hypot((point.x - (140 + shift.dx)) / 40, (point.y - (60 + shift.dy)) / 30)
                #expect(abs(r - 1) < 0.01)
            }
        }
    }

    @Test func roundTripSplinesAreExact() throws {
        try roundTrip(DXFOptions(version: .v2000, units: .inches, splines: true)) { scene, shift in
            let ellipse = try #require(scene.scenePaths.first { $0.groupNames == ["0"] })
            let source = DisplayPath(ellipseIn: Rect(x: 100, y: 30, width: 80, height: 60))
            var expected: [Point] = []
            for element in source.elements {
                if case .cubicCurve(let c1, let c2, let end) = element {
                    expected += [c1, c2, end]
                }
            }
            let got = ellipse.contours[0].segments.flatMap { segment -> [Point] in
                if case .cubic(let c1, let c2, let end) = segment { return [c1, c2, end] }
                return []
            }
            #expect(got.count == expected.count)
            #expect(zip(got, expected.map { $0 + shift }).allSatisfy { dxfImportClose($0, $1, 1e-4) })
        }
    }

    @Test func roundTripR12InchesAndPoints() throws {
        try roundTrip(DXFOptions(version: .r12, units: .inches), importOptions: DXFImportOptions(units: .inches)) { scene, _ in
            #expect(abs(scene.bounds.width - 160) < 0.01)
            #expect(scene.nodes.contains { $0.name == "Cut" })
        }
        try roundTrip(DXFOptions(version: .v2018, units: .points, layersFromDocument: false), importOptions: DXFImportOptions(units: .points)) { scene, _ in
            #expect(abs(scene.bounds.height - 60) < 0.01)
            #expect(scene.nodes.map(\.name) == ["0"])
        }
    }
}
