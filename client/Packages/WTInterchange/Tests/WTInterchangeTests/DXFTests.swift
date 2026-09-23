// IO-020: the DXF writer, read back by a minimal DXF reader: group-code pairs, sections, the layer
// table, handles, and LWPOLYLINE, POLYLINE/VERTEX and SPLINE entities (splines evaluated by de Boor),
// with dimensions checked in millimetres to 0.01 mm.

import Foundation
import Testing
import WTGeometry
@testable import WTInterchange
import WTRender

/// A minimal DXF reader for the tests.
struct DXFFile {
    struct Entity {
        var type: String
        var layer = "0"
        var flags = 0
        var points: [Point] = []
        var knots: [Double] = []
        var degree = 0
        var handle: String?
    }

    var pairs: [(code: Int, value: String)] = []
    var sections: [String] = []
    var header: [String: [String]] = [:]
    var layers: [String] = []
    var entities: [Entity] = []
    var handles: [String] = []

    init(_ text: String) throws {
        let lines = text.components(separatedBy: "\n")
        var index = 0
        while index + 1 < lines.count {
            guard let code = Int(lines[index].trimmingCharacters(in: .whitespaces)) else {
                throw ExportError.writeFailed("bad group code at line \(index + 1): \(lines[index])")
            }
            pairs.append((code, lines[index + 1]))
            index += 2
        }
        var section = ""
        var variable = ""
        var expecting = ""
        var current: Entity?
        var vertexOwner: Entity?
        func close() {
            guard let entity = current else { return }
            switch entity.type {
            case "VERTEX":
                vertexOwner?.points += entity.points
            case "SEQEND":
                if let owner = vertexOwner {
                    entities.append(owner)
                }
                vertexOwner = nil
            case "POLYLINE":
                vertexOwner = entity
            case "LAYER":
                break
            default:
                if section == "ENTITIES" {
                    entities.append(entity)
                }
            }
            current = nil
        }
        var pendingX: Double?
        for (code, value) in pairs {
            if code == 0 {
                close()
                switch value {
                case "SECTION", "TABLE":
                    expecting = value
                case "ENDSEC", "EOF", "ENDTAB":
                    expecting = ""
                default:
                    current = Entity(type: value)
                }
                continue
            }
            if code == 2 && expecting == "SECTION" {
                section = value
                sections.append(value)
                expecting = ""
                continue
            }
            if (code == 5 || code == 105) && current != nil {
                handles.append(value)
                current?.handle = value
            }
            guard current != nil else {
                if section == "HEADER" {
                    if code == 9 {
                        variable = value
                    } else {
                        header[variable, default: []].append(value.trimmingCharacters(in: .whitespaces))
                    }
                }
                continue
            }
            switch code {
            case 2 where current?.type == "LAYER": layers.append(value)
            case 8: current?.layer = value
            case 70: current?.flags = Int(value.trimmingCharacters(in: .whitespaces)) ?? 0
            case 71: current?.degree = Int(value.trimmingCharacters(in: .whitespaces)) ?? 0
            case 40 where current?.type == "SPLINE": current?.knots.append(Double(value)!)
            case 10: pendingX = Double(value)
            case 20:
                if let x = pendingX, current?.type != "POLYLINE" {
                    current?.points.append(Point(x: x, y: Double(value)!))
                }
                pendingX = nil
            default: break
            }
        }
        close()
    }

    /// The point of a clamped B-spline at `u` (de Boor).
    static func evaluate(_ entity: Entity, at u: Double) -> Point {
        let p = entity.degree, knots = entity.knots, controls = entity.points
        var span = p
        while span < controls.count - 1 && knots[span + 1] <= u {
            span += 1
        }
        var d = (0...p).map { controls[span - p + $0] }
        for r in 1...p {
            for j in stride(from: p, through: r, by: -1) {
                let i = span - p + j
                let denominator = knots[i + p - r + 1] - knots[i]
                let alpha = denominator == 0 ? 0 : (u - knots[i]) / denominator
                d[j] = Point(x: (1 - alpha) * d[j - 1].x + alpha * d[j].x, y: (1 - alpha) * d[j - 1].y + alpha * d[j].y)
            }
        }
        return d[p]
    }
}

@Suite struct DXFTests {
    static let mm = 25.4 / 72

    static func export(_ page: ExportPage, options: DXFOptions = DXFOptions(), nodes: [NodeID: ExportNodeInfo] = [:], assets: [String: ExportAsset] = [:]) throws -> (file: DXFFile, text: String, notes: [String]) {
        let result = try DXFExporter().data(scene: Corpus.scene([page], nodes: nodes, assets: assets), page: 0, options: options)
        let text = String(decoding: result.data, as: UTF8.self)
        return (try DXFFile(text), text, result.notes)
    }

    @Test func dimensionsMatchInMillimetres() throws {
        let page = Corpus.page([Corpus.path(Corpus.rect(36, 36, 72, 36), [Corpus.fill(.solid(Corpus.red)), Corpus.stroke(.solid(.black), width: 2)])])
        let result = try Self.export(page)
        #expect(result.file.header["$ACADVER"] == ["AC1032"])
        #expect(result.file.header["$INSUNITS"] == ["4"])
        #expect(result.file.sections == ["HEADER", "CLASSES", "TABLES", "BLOCKS", "ENTITIES", "OBJECTS"])
        let polylines = result.file.entities.filter { $0.type == "LWPOLYLINE" }
        // The fill's contour and the stroke's centerline.
        #expect(polylines.count == 2)
        let fill = polylines[0]
        #expect(fill.flags & 1 == 1)
        #expect(fill.points.count == 4)
        let xs = fill.points.map(\.x), ys = fill.points.map(\.y)
        #expect(abs(xs.min()! - 12.7) < 0.01 && abs(xs.max()! - 38.1) < 0.01)
        #expect(abs(ys.min()! - 78 * Self.mm) < 0.01 && abs(ys.max()! - 114 * Self.mm) < 0.01)
        #expect(Set(result.file.handles).count == result.file.handles.count)
        let seed = try #require(result.file.header["$HANDSEED"]?.first)
        #expect(result.file.handles.allSatisfy { Int($0, radix: 16)! < Int(seed, radix: 16)! })
    }

    @Test func holesAreSeparateClosedPolylinesAndTextIsOutlined() throws {
        var ring = Corpus.ellipse(10, 10, 80, 80)
        ring.elements += Corpus.ellipse(30, 30, 40, 40).elements
        let page = Corpus.page([Corpus.path(ring, [Corpus.fill(.solid(.black), rule: .evenOdd)]), Corpus.text("Cut", origin: Point(x: 100, y: 60))])
        let result = try Self.export(page)
        let polylines = result.file.entities.filter { $0.type == "LWPOLYLINE" }
        #expect(polylines.count > 4)
        #expect(polylines.allSatisfy { $0.flags & 1 == 1 })
        // The outer circle: radius 40 pt, flattened within 0.1 mm.
        let center = Point(x: 50 * Self.mm, y: 100 * Self.mm)
        let radii = polylines[0].points.map { hypot($0.x - center.x, $0.y - center.y) }
        #expect(radii.allSatisfy { abs($0 - 40 * Self.mm) < 0.11 })
        #expect(!result.text.contains("\nTEXT\n"))
        #expect(!result.notes.contains { $0.contains("outlines") })
    }

    @Test func splinesFollowTheBeziers() throws {
        let page = Corpus.page([Corpus.path(Corpus.ellipse(20, 20, 100, 60), [Corpus.stroke(.solid(.black), width: 1)]), Corpus.path(Corpus.rect(130, 20, 40, 40), [Corpus.fill(.solid(.black))])])
        let result = try Self.export(page, options: DXFOptions(version: .v2000, splines: true))
        #expect(result.file.header["$ACADVER"] == ["AC1015"])
        let spline = try #require(result.file.entities.first { $0.type == "SPLINE" })
        #expect(spline.degree == 3)
        #expect(spline.knots.count == spline.points.count + 4)
        // Every point of the spline lies on the ellipse to within the Bézier approximation.
        let center = Point(x: 70 * Self.mm, y: 100 * Self.mm)
        for step in 0...40 {
            let u = spline.knots.last! * Double(step) / 40
            let p = DXFFile.evaluate(spline, at: u)
            let r = hypot((p.x - center.x) / (50 * Self.mm), (p.y - center.y) / (30 * Self.mm))
            #expect(abs(r - 1) < 0.001, "u \(u): \(r)")
        }
        // Straight-edged contours stay polylines.
        #expect(result.file.entities.contains { $0.type == "LWPOLYLINE" && $0.points.count == 4 })
        let open = DXFContour(start: .zero, segments: [.line(Point(x: 3, y: 0)), .cubic(Point(x: 4, y: 0), Point(x: 5, y: 1), Point(x: 5, y: 2))], closed: true)
        #expect(open.spline.controls.count == 10)
        #expect(open.spline.knots == [0, 0, 0, 0, 1, 1, 1, 2, 2, 2, 3, 3, 3, 3])
    }

    @Test func layersFromDocumentGroups() throws {
        let cut = Corpus.node(1), engrave = Corpus.node(2), again = Corpus.node(3), unnamed = Corpus.node(4)
        let items: [DisplayItem] = [
            .group(GroupItem(children: [Corpus.path(Corpus.rect(10, 10, 20, 20), [Corpus.fill(.solid(.black))])])),
            .group(GroupItem(children: [Corpus.path(Corpus.rect(40, 10, 20, 20), [Corpus.fill(.solid(.black))]), .group(GroupItem(children: [Corpus.path(Corpus.rect(70, 10, 20, 20), [Corpus.fill(.solid(.black))])]))])),
            .group(GroupItem(children: [Corpus.path(Corpus.rect(100, 10, 20, 20), [Corpus.fill(.solid(.black))])])),
            .group(GroupItem(children: [Corpus.path(Corpus.rect(130, 10, 20, 20), [Corpus.fill(.solid(.black))])])),
            Corpus.path(Corpus.rect(160, 10, 20, 20), [Corpus.fill(.solid(.black))]),
        ]
        let page = Corpus.page(items, nodes: [cut, engrave, again, unnamed, nil])
        let nodes = [cut: ExportNodeInfo(name: "Cut", isLayer: true), engrave: ExportNodeInfo(name: "En/grave", isLayer: true), again: ExportNodeInfo(name: "cut", isLayer: true), unnamed: ExportNodeInfo(isLayer: true)]
        let result = try Self.export(page, nodes: nodes)
        #expect(result.file.layers == ["0", "Cut", "En_grave", "cut-2", "Layer"])
        #expect(result.file.entities.map(\.layer) == ["Cut", "En_grave", "En_grave", "cut-2", "Layer", "0"])
        let single = try Self.export(page, options: DXFOptions(layersFromDocument: false), nodes: nodes)
        #expect(single.file.layers == ["0"])
        #expect(single.file.entities.allSatisfy { $0.layer == "0" })
        let escaped = try Self.export(Corpus.page([.group(GroupItem(children: [Corpus.path(Corpus.rect(0, 0, 5, 5), [Corpus.fill(.solid(.black))])]))], nodes: [cut]), options: DXFOptions(version: .v2000), nodes: [cut: ExportNodeInfo(name: "Découpe", isLayer: true)])
        #expect(escaped.file.layers.contains("D\\U+00E9coupe"))
        let utf8 = try Self.export(Corpus.page([.group(GroupItem(children: [Corpus.path(Corpus.rect(0, 0, 5, 5), [Corpus.fill(.solid(.black))])]))], nodes: [cut]), nodes: [cut: ExportNodeInfo(name: "Découpe", isLayer: true)])
        #expect(utf8.file.layers.contains("Découpe"))
    }

    @Test func r12WritesPolylineVertices() throws {
        let cut = Corpus.node(1)
        let page = Corpus.page([.group(GroupItem(children: [Corpus.path(Corpus.ellipse(10, 10, 50, 50), [Corpus.fill(.solid(.black))])])), Corpus.path(Corpus.wave(70, 10, 60, 40), [Corpus.stroke(.solid(.black), width: 2)])], nodes: [cut])
        let result = try Self.export(page, options: DXFOptions(version: .r12, units: .inches), nodes: [cut: ExportNodeInfo(name: "Outline", isLayer: true)])
        #expect(result.file.header["$ACADVER"] == ["AC1009"])
        #expect(result.file.header["$INSUNITS"] == nil)
        #expect(result.file.header["$MEASUREMENT"] == ["0"])
        #expect(result.file.handles.isEmpty)
        #expect(result.file.entities.map(\.type) == ["POLYLINE", "POLYLINE"])
        #expect(result.file.entities[0].layer == "Outline")
        #expect(result.file.entities[0].flags == 1)
        #expect(result.file.entities[1].flags == 0)
        #expect(result.file.entities[0].points.allSatisfy { $0.x >= 10.0 / 72 - 1e-6 && $0.x <= 60.0 / 72 + 1e-6 })
        #expect(throws: ExportError.self) { try DXFExporter().data(scene: Corpus.scene([page]), page: 0, options: DXFOptions(version: .r12, splines: true)) }
    }

    @Test func tolerancesUnitsAndStrokeOutlines() throws {
        let page = Corpus.page([Corpus.path(Corpus.ellipse(10, 10, 100, 100), [Corpus.stroke(.solid(.black), width: 6)])])
        let coarse = try Self.export(page, options: DXFOptions(tolerance: 1))
        let fine = try Self.export(page, options: DXFOptions(tolerance: 0.01))
        #expect(fine.file.entities[0].points.count > coarse.file.entities[0].points.count)
        let outlined = try Self.export(page, options: DXFOptions(outlineStrokes: true))
        // A stroked circle's outline is two closed contours.
        #expect(outlined.file.entities.count == 2)
        #expect(outlined.file.entities.allSatisfy { $0.flags & 1 == 1 })
        let points = try Self.export(page, options: DXFOptions(units: .points))
        #expect(points.file.header["$INSUNITS"] == ["0"])
        #expect(points.notes.contains { $0.contains("DXF has no point unit") })
        let document = try Self.export(page, options: DXFOptions(units: .document))
        #expect(document.notes.contains { $0.contains("document's units") })
        #expect(abs(DXFOptions(units: .inches, tolerance: 0.01).tolerancePoints - 0.72) < 1e-12)
        #expect(throws: ExportError.self) { try DXFExporter().data(scene: Corpus.scene([page]), page: 0, options: DXFOptions(tolerance: -1)) }
    }

    @Test func imagesClipsEffectsAndPaintsReduceToOutlines() throws {
        let assets = ["a": ExportAsset(image: Corpus.image())]
        let clipped = DisplayItem.group(GroupItem(children: [Corpus.path(Corpus.rect(0, 0, 50, 50), [Corpus.fill(.solid(.black))])], clip: Corpus.ellipse(0, 0, 40, 40)))
        let items = Corpus.effects + Corpus.sampled + [.image(ImageItem(assetID: "a", rect: Rect(x: 0, y: 0, width: 10, height: 10))), clipped] + Corpus.derivedStrokes + Corpus.liveGroup
        let result = try Self.export(Corpus.page(items), assets: assets)
        #expect(result.notes.contains("1 image left out (DXF carries outlines only)"))
        #expect(result.notes.contains("1 clipping path ignored: clipped artwork is written whole"))
        #expect(!result.notes.contains { $0.contains("rendered") })
        // Every fill of the sampled and effects pages arrives as geometry.
        #expect(result.file.entities.count > Corpus.effects.count + Corpus.sampled.count)
        #expect(DXFExporter.solid(.none) == .none)
        let empty = try Self.export(Corpus.page([]))
        #expect(empty.file.entities.isEmpty)
        #expect(DXFContour.contours(of: DisplayPath(elements: [.close, .line(to: Point(x: 1, y: 1)), .quadCurve(control: Point(x: 2, y: 0), end: Point(x: 3, y: 1)), .close]), transform: .identity, filled: false).count == 1)
        let degenerate = DXFContour(start: .zero, segments: [.cubic(.zero, .zero, .zero)], closed: false)
        #expect(degenerate.polyline(tolerance: 0.1).count == 2)
    }

    /// A Python with ezdxf (`python3 -m venv v && v/bin/pip install ezdxf`), for an independent
    /// reader's audit of every version.
    static let ezdxf = ProcessInfo.processInfo.environment["WTINTERCHANGE_EZDXF_PYTHON"]

    @Test(.enabled(if: DXFTests.ezdxf != nil), arguments: [DXFOptions.Version.v2018, .v2000, .r12])
    func ezdxfAuditsTheCorpus(_ version: DXFOptions.Version) throws {
        let directory = Corpus.directory()
        var files: [String] = []
        for name in Corpus.fixtures {
            let url = directory.appendingPathComponent("\(name).dxf")
            try DXFExporter().data(scene: Corpus.scene([Corpus.fixture(name)]), page: 0, options: DXFOptions(version: version, splines: version != .r12)).data.write(to: url)
            files.append(url.path)
        }
        let script = """
        import sys, ezdxf
        from ezdxf import recover
        bad = 0
        for path in sys.argv[1:]:
            doc, auditor = recover.readfile(path)
            fatal = [e for e in auditor.errors]
            n = len(doc.modelspace())
            print(path.split('/')[-1], doc.dxfversion, n, 'entities', len(auditor.errors), 'errors', len(auditor.fixes), 'fixes')
            if auditor.has_errors or n == 0 and 'text' not in path:
                bad += 1
        sys.exit(1 if bad else 0)
        """
        let process = Process()
        process.executableURL = URL(fileURLWithPath: DXFTests.ezdxf!)
        process.arguments = ["-c", script] + files
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        try process.run()
        let output = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        process.waitUntilExit()
        print(output)
        #expect(process.terminationStatus == 0, "\(output)")
    }

    @Test func filesAndErrors() throws {
        let page = Corpus.fixture("basics")
        let directory = Corpus.directory()
        let summary = try DXFExporter().export(scene: Corpus.scene([page, page]), options: DXFOptions(), to: ExportDestination(url: directory.appendingPathComponent("cut.dxf"), namePattern: .standard))
        #expect(summary.files.map(\.lastPathComponent) == ["cut-1.dxf", "cut-2.dxf"])
        #expect(throws: ExportError.nothingToExport) { try DXFExporter().export(scene: Corpus.scene([]), options: DXFOptions(), to: ExportDestination(url: directory.appendingPathComponent("x.dxf"))) }
        #expect(throws: ExportError.nothingToExport) { try DXFExporter().data(scene: Corpus.scene([page]), page: 1, options: DXFOptions()) }
        #expect(throws: ExportError.wrongOptions(format: .dxf)) { try DXFExporter().export(scene: Corpus.scene([page]), options: EPSOptions(), to: ExportDestination(url: directory.appendingPathComponent("x.dxf"))) }
        #expect(throws: ExportError.self) { try DXFExporter().export(scene: Corpus.scene([page]), options: DXFOptions(), to: ExportDestination(url: URL(fileURLWithPath: "/nonexistent-folder/x.dxf"))) }
        #expect(DXFExporter().optionsType is DXFOptions.Type)
        #expect(DXFExporter().capabilities == ExportFormat.dxf.capabilities)
        #expect(DXFOptions.defaults == DXFOptions())
        #expect(throws: ExportError.self) { try DXFFile("x\ny\n") }
    }
}
