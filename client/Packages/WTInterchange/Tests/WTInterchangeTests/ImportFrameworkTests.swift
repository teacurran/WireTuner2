// IMG-008: the importer protocol, registry, format recognition, options schema and persistence,
// the imported scene model and its path builder, and the scene's rendering.

import CoreGraphics
import Foundation
import Testing
import UniformTypeIdentifiers
import WTGeometry
@testable import WTInterchange
import WTRender
import struct WTRender.StrokeStyle

/// A test importer registered for a fixture UTI (IMG-008: "A test importer registered for a
/// fixture UTI shows in the sheet with its options and yields a group named after the file").
private struct FrameworkStubImporter: Importer {
    var formats: [ImportFormat] { [.dxf] }

    func optionsSchema(for format: ImportFormat) -> ImportOptionsSchema {
        ImportOptionsSchema(fields: [ImportOptionField(key: "size", label: "Size", control: .choice([.init("small", "Small"), .init("large", "Large")]), defaultValue: .string("small"))])
    }

    func probe(_ data: Data, name: String, format: ImportFormat) throws -> ImportDescriptor {
        ImportDescriptor(format: format, naturalSize: Rect(x: 0, y: 0, width: 10, height: 10))
    }

    func convert(_ data: Data, name: String, format: ImportFormat, options: ImportOptionValues, context: ImportContext) throws -> ImportedScene {
        let side = options.string("size", default: "small") == "large" ? 100.0 : 10
        var builder = ImportPathBuilder()
        builder.rect(Rect(x: 0, y: 0, width: side, height: side))
        let path = ImportedPath(contours: builder.build(), fill: .solid(.black))
        return ImportedScene(kind: .vector, name: name, bounds: Rect(x: 0, y: 0, width: side, height: side), nodes: [.path(path)])
    }
}

/// A plain importer that relies on the protocol's default (empty) options.
private struct FrameworkPlainImporter: Importer {
    var formats: [ImportFormat] { [.eps] }

    func probe(_ data: Data, name: String, format: ImportFormat) throws -> ImportDescriptor {
        ImportDescriptor(format: format, naturalSize: .zero, placed: true)
    }

    func convert(_ data: Data, name: String, format: ImportFormat, options: ImportOptionValues, context: ImportContext) throws -> ImportedScene {
        let blob = ImportedBlob(data: data, uti: "com.adobe.encapsulated-postscript")
        return ImportedScene(kind: .placed, name: name, bounds: Rect(x: 0, y: 0, width: 72, height: 72), nodes: [.placed(ImportedPlacedFile(kind: .eps, blob: blob, bounds: Rect(x: 0, y: 0, width: 72, height: 72)))])
    }
}

/// An in-memory `ImportOptionsStorage`.
private final class FrameworkMemoryStorage: ImportOptionsStorage {
    var values: [String: Any] = [:]

    func data(forKey key: String) -> Data? { values[key] as? Data }

    func set(_ value: Any?, forKey key: String) { values[key] = value }
}

@Suite("Import framework")
struct ImportFrameworkTests {
    // MARK: Formats

    @Test func formatsHaveNamesExtensionsAndTypes() {
        for format in ImportFormat.allCases {
            #expect(!format.displayName.isEmpty)
            #expect(format.description == format.displayName)
            #expect(ImportFormat(fileExtension: format.fileExtensions[0].uppercased()) == format)
            for uti in format.utis {
                #expect(ImportFormat(uti: uti) == format)
            }
        }
        #expect(ImportFormat(fileExtension: "doc") == nil)
        #expect(ImportFormat.allCases.filter(\.isBitmap).count == 10)
        #expect(!ImportFormat.svg.isBitmap)
    }

    @Test func typesConformingToAFormatResolve() {
        // A dynamic type declared for .svgz conforms to nothing; a known subtype resolves to its parent.
        #expect(ImportFormat(uti: "public.jpeg-2000") == nil || ImportFormat(uti: "public.jpeg-2000") != .jpeg)
        #expect(ImportFormat(uti: "not a type") == nil)
        #expect(ImportFormat(uti: "com.apple.private.nothing") == nil)
        #expect(ImportFormat(uti: "public.heif") == .heic)
    }

    @Test func sniffingRecognisesEveryMagicNumber() {
        func bytes(_ values: [UInt8], padding: Int = 16) -> Data { Data(values + Array(repeating: 0, count: padding)) }
        #expect(ImportFormat.sniff(Data("%PDF-1.7".utf8)) == .pdf)
        #expect(ImportFormat.sniff(bytes([0x89, 0x50, 0x4E, 0x47])) == .png)
        #expect(ImportFormat.sniff(bytes([0xFF, 0xD8, 0xFF, 0xE0])) == .jpeg)
        #expect(ImportFormat.sniff(Data("GIF89a".utf8)) == .gif)
        #expect(ImportFormat.sniff(bytes([0x49, 0x49, 0x2A, 0x00])) == .tiff)
        #expect(ImportFormat.sniff(bytes([0x4D, 0x4D, 0x00, 0x2A])) == .tiff)
        #expect(ImportFormat.sniff(Data("8BPS".utf8)) == .psd)
        #expect(ImportFormat.sniff(Data("BM....".utf8)) == .bmp)
        #expect(ImportFormat.sniff(bytes([0xC5, 0xD0, 0xD3, 0xC6])) == .eps)
        #expect(ImportFormat.sniff(Data("RIFF\0\0\0\0WEBPVP8 ".utf8)) == .webp)
        #expect(ImportFormat.sniff(Data("RIFF\0\0\0\0WAVEfmt ".utf8)) == nil)
        #expect(ImportFormat.sniff(Data("\0\0\0\u{1C}ftypavif".utf8)) == .avif)
        #expect(ImportFormat.sniff(Data("\0\0\0\u{1C}ftypheic".utf8)) == .heic)
        #expect(ImportFormat.sniff(Data("\0\0\0\u{1C}ftypmp42".utf8)) == nil)
        #expect(ImportFormat.sniff(bytes([0x1F, 0x8B])) == .svg)
        #expect(ImportFormat.sniff(Data("AutoCAD Binary DXF\r\n\u{1A}\0".utf8)) == .dxf)
        #expect(ImportFormat.sniff(Data("%!PS-Adobe-3.0 EPSF-3.0\n%%Creator: Adobe Illustrator".utf8)) == .eps)
        #expect(ImportFormat.sniff(Data("%!PS-Adobe-3.0\n%%Creator: Adobe Illustrator(R) 8.0".utf8)) == .illustrator)
        #expect(ImportFormat.sniff(Data("%!PS-Adobe-2.0\n".utf8)) == .eps)
        #expect(ImportFormat.sniff(Data("\u{FEFF}<?xml version=\"1.0\"?>\n<svg xmlns=\"\"/>".utf8)) == .svg)
        #expect(ImportFormat.sniff(Data("<html></html>".utf8)) == nil)
        #expect(ImportFormat.sniff(Data("  0\nSECTION\n  2\nHEADER\n".utf8)) == .dxf)
        #expect(ImportFormat.sniff(Data("0\r\nEOF\r\n".utf8)) == .dxf)
        #expect(ImportFormat.sniff(Data("999\nwritten by hand\n0\nSECTION\n".utf8)) == .dxf)
        #expect(ImportFormat.sniff(Data("hello".utf8)) == nil)
        #expect(ImportFormat.sniff(Data()) == nil)
    }

    // MARK: Registry

    @Test func registryResolvesByContentThenName() throws {
        let registry = ImportRegistry(importers: [ImageImporter(), FrameworkStubImporter()])
        #expect(registry.availableFormats.contains(.png))
        #expect(registry.availableFormats.contains(.dxf))
        #expect(!registry.availableFormats.contains(.pdf))
        #expect(registry.acceptedUTIs.contains("public.png"))
        #expect(registry.importer(for: .pdf) == nil)
        let png = ImageFixtures.png(width: 4, height: 3)
        // A PNG named .jpg is a PNG.
        #expect(registry.format(of: png, name: "photo.jpg") == .png)
        // Unrecognisable bytes fall back to the extension.
        #expect(registry.format(of: Data("x".utf8), name: "plan.dxf") == .dxf)
        #expect(registry.format(of: Data("%PDF-1.4".utf8), name: "art.ai") == .illustrator)
        #expect(registry.format(of: Data("%!PS-Adobe-3.0\n%%Creator: Adobe Illustrator 8".utf8), name: "art.ai") == .illustrator)
        #expect(registry.format(of: Data("%!PS-Adobe-3.0\n%%Creator: Adobe Illustrator 8".utf8), name: "art.eps") == .eps)
        #expect(registry.format(of: Data("%PDF-1.4".utf8), name: "doc.pdf") == .pdf)
        #expect(throws: ImportError.unsupportedFormat(name: "notes.txt")) {
            try registry.convert(Data("hello".utf8), name: "notes.txt")
        }
        #expect(throws: ImportError.unsupportedFormat(name: "doc.pdf")) {
            try registry.probe(Data("%PDF-1.4".utf8), name: "doc.pdf")
        }
    }

    @Test func theStandardRegistryReadsEveryShippedFormat() {
        let registry = ImportRegistry.standard
        #expect(registry.availableFormats == ImportFormat.allCases.filter { $0 != .eps })
        #expect(registry.importer(for: .pdf)?.optionsSchema(for: .pdf) == PDFImportOptions.schema)
        #expect(registry.importer(for: .svg)?.optionsSchema(for: .svg) == SVGImportOptions.schema)
        #expect(registry.importer(for: .dxf)?.optionsSchema(for: .dxf) == DXFImportOptions.schema)
        #expect(registry.importer(for: .png)?.optionsSchema(for: .png).isEmpty == true)
    }

    @Test func aRegisteredImporterShowsItsOptionsAndNamesTheGroup() throws {
        var registry = ImportRegistry(importers: [])
        registry.register(FrameworkStubImporter())
        registry.register(FrameworkPlainImporter())
        let importer = try #require(registry.importer(for: .dxf))
        let schema = importer.optionsSchema(for: .dxf)
        #expect(schema.fields.map(\.key) == ["size"])
        #expect(!schema.isEmpty)
        #expect(registry.importer(for: .eps)?.optionsSchema(for: .eps).isEmpty == true)
        let descriptor = try registry.probe(Data("0\nSECTION\n".utf8), name: "plan.dxf")
        #expect(descriptor.format == .dxf)
        var scene = try registry.convert(Data("0\nSECTION\n".utf8), name: "plan.dxf")
        #expect(scene.bounds.width == 10)
        scene = try registry.convert(Data("0\nSECTION\n".utf8), name: "plan.dxf", options: ImportOptionValues(["size": .string("large")]))
        #expect(scene.bounds.width == 100)
        guard case .group(let group) = scene.subtree else {
            Issue.record("a vector import is one group")
            return
        }
        #expect(group.name == "plan.dxf")
        #expect(group.children.count == 1)
        let placed = try registry.convert(Data("%!PS-Adobe-3.0 EPSF-3.0\n".utf8), name: "logo.eps")
        guard case .placed(let file) = placed.subtree else {
            Issue.record("a placed file is one node")
            return
        }
        #expect(file.name == "logo.eps")
        #expect(placed.blobs.count == 1)
    }

    @Test func urlEntryPointsCheckTheSizeBeforeReading() throws {
        let registry = ImportRegistry(importers: [ImageImporter()])
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("wt-import-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        // A 201 MiB file, sparse so the test writes nothing.
        let big = directory.appendingPathComponent("huge.png")
        FileManager.default.createFile(atPath: big.path, contents: nil)
        let handle = try FileHandle(forWritingTo: big)
        try handle.truncate(atOffset: 201 * 1_048_576)
        try handle.close()
        do {
            _ = try registry.convert(contentsOf: big)
            Issue.record("a 201 MiB file must be refused")
        } catch let error as ImportError {
            #expect(error == .tooLarge(name: "huge.png", bytes: 201 * 1_048_576, limit: 200 * 1_048_576))
            #expect(error.description.contains("201 MiB"))
            #expect(error.description.contains("huge.png"))
        }
        let small = directory.appendingPathComponent("small.png")
        try ImageFixtures.png(width: 5, height: 4).write(to: small)
        let scene = try registry.convert(contentsOf: small)
        #expect(scene.kind == .bitmap)
        #expect(try registry.probe(contentsOf: small).pixelWidth == 5)
        #expect(throws: ImportError.self) {
            try registry.convert(contentsOf: directory.appendingPathComponent("missing.png"))
        }
        // Data over the limit is refused before any importer runs.
        let tiny = ImportContext(downsampleLimit: nil, maximumFileSize: 10)
        #expect(throws: ImportError.tooLarge(name: "a.png", bytes: ImageFixtures.png(width: 5, height: 4).count, limit: 10)) {
            try registry.convert(ImageFixtures.png(width: 5, height: 4), name: "a.png", context: tiny)
        }
    }

    @Test func errorsNameTheFile() {
        let errors: [ImportError] = [
            .tooLarge(name: "a", bytes: 3 * 1_048_576 / 2, limit: 1_048_576),
            .unsupportedFormat(name: "a"),
            .unreadable(name: "a", reason: "bad"),
            .unsupportedJPEGPrecision(name: "a", bits: 12),
            .invalidOption(name: "a", reason: "bad"),
            .empty(name: "a"),
        ]
        for error in errors {
            #expect(error.fileName == "a")
            #expect(error.description.contains("“a”"))
        }
        #expect(errors[0].description.contains("1.5 MiB"))
        #expect(ImportError.size(2 * 1_048_576) == "2 MiB")
    }

    @Test func contextChoicesMapToPixelLimits() {
        #expect(ImportContext().downsampleLimit == 50_000_000)
        #expect(ImportContext().keepBothOffset == 10)
        #expect(ImportContext(downsampleMegapixels: 0).downsampleLimit == nil)
        #expect(ImportContext(downsampleMegapixels: 20).downsampleLimit == 20_000_000)
        #expect(ImportContext.downsampleChoices == [0, 20, 50, 100])
    }

    // MARK: Options

    @Test func schemasNormalizeStoredValues() {
        let schema = PDFImportOptions.schema
        let defaults = schema.defaults
        #expect(defaults["pages"] == .string("All"))
        var values = ImportOptionValues(["text": .string("outlines"), "importNotes": .string("yes"), "bogus": .bool(true), "keepPageClip": .bool(true)])
        values = schema.normalized(values)
        #expect(values["bogus"] == nil)
        #expect(values["text"] == .string("outlines"))
        #expect(values["importNotes"] == .bool(true))
        #expect(values["keepPageClip"] == .bool(true))
        #expect(schema.normalized(ImportOptionValues(["text": .string("sideways")]))["text"] == .string("editable"))
        let field = ImportOptionField(key: "k", label: "K", control: .text(placeholder: ""), defaultValue: .string(""))
        #expect(field.accepts(.string("x")))
        #expect(!field.accepts(.number(1)))
        #expect(!ImportOptionField(key: "t", label: "T", control: .toggle, defaultValue: .bool(false)).accepts(.string("true")))
        #expect(values.bool("missing", default: true))
        #expect(values.string("importNotes", default: "x") == "x")
        #expect(values.bool("text", default: false) == false)
    }

    @Test func optionsPersistPerFormat() throws {
        let storage = FrameworkMemoryStorage()
        let store = ImportOptionsStore(storage: storage)
        #expect(store.options(for: .pdf, schema: PDFImportOptions.schema) == PDFImportOptions.schema.defaults)
        var values = PDFImportOptions.schema.defaults
        values["pages"] = .string("2-3")
        store.save(values, for: .pdf)
        // A new store over the same storage is a relaunch.
        let relaunched = ImportOptionsStore(storage: storage)
        #expect(relaunched.options(for: .pdf, schema: PDFImportOptions.schema)["pages"] == .string("2-3"))
        #expect(relaunched.options(for: .svg, schema: SVGImportOptions.schema) == SVGImportOptions.schema.defaults)
        storage.values[ImportOptionsStore.key(.dxf)] = Data("not json".utf8)
        #expect(relaunched.options(for: .dxf, schema: DXFImportOptions.schema) == DXFImportOptions.schema.defaults)
        relaunched.reset(.pdf)
        #expect(relaunched.options(for: .pdf, schema: PDFImportOptions.schema) == PDFImportOptions.schema.defaults)

        let suite = "wt-import-options-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let persisted = ImportOptionsStore(storage: defaults)
        persisted.save(SVGImportOptions(text: .outlines).values, for: .svg)
        #expect(ImportOptionsStore(storage: defaults).options(for: .svg, schema: SVGImportOptions.schema)["text"] == .string("outlines"))
        #expect(ImportOptionsStore().storage === UserDefaults.standard)
    }

    @Test func pageRangesParseAndResolve() throws {
        #expect(ImportPageRange(parsing: "")?.pages == nil)
        #expect(ImportPageRange(parsing: " all ")?.pages == nil)
        #expect(ImportPageRange(parsing: "1")?.pages == [1])
        #expect(ImportPageRange(parsing: "2-4")?.pages == [2, 3, 4])
        #expect(ImportPageRange(parsing: "1, 3,7")?.pages == [1, 3, 7])
        for bad in ["0", "4-2", "a", "1-2-3", "-3", "1,,2"] {
            #expect(ImportPageRange(parsing: bad) == nil, "\(bad)")
        }
        #expect(ImportPageRange.all.description == "All")
        #expect(ImportPageRange(pages: [1, 3]).description == "1,3")
        #expect(try ImportPageRange.all.resolve(pageCount: 3, name: "a") == [1, 2, 3])
        #expect(try ImportPageRange.all.resolve(pageCount: 0, name: "a") == [])
        #expect(try ImportPageRange(pages: [2]).resolve(pageCount: 3, name: "a") == [2])
        #expect(throws: ImportError.invalidOption(name: "a", reason: "page 5 is beyond the last page (3).")) {
            try ImportPageRange(pages: [1, 5]).resolve(pageCount: 3, name: "a")
        }
    }

    @Test func typedOptionsRoundTripThroughValues() throws {
        let pdf = PDFImportOptions(pages: ImportPageRange(pages: [1, 2]), text: .outlines, importNotes: false, importLinks: false, keepPageClip: true)
        #expect(try PDFImportOptions(pdf.values, name: "a") == pdf)
        #expect(try PDFImportOptions(ImportOptionValues(), name: "a") == PDFImportOptions())
        #expect(throws: ImportError.self) {
            try PDFImportOptions(ImportOptionValues(["pages": .string("x")]), name: "a")
        }
        let svg = SVGImportOptions(text: .outlines, flattenGroups: true, animation: .place)
        #expect(SVGImportOptions(svg.values) == svg)
        #expect(SVGImportOptions(ImportOptionValues(["animation": .string("dance")])).animation == .automatic)
        #expect(SVGImportOptions.schema.fields.count == 3)
        let dxf = DXFImportOptions(importInvisibleAttributes: true, whiteStrokesToBlack: false, whiteFillsToBlack: false, units: .millimeters)
        #expect(DXFImportOptions(dxf.values) == dxf)
        #expect(DXFImportOptions(ImportOptionValues(["units": .string("furlongs")])).units == .inches)
        #expect(DXFImportOptions.Units.inches.points == 72)
        #expect(abs(DXFImportOptions.Units.millimeters.points - 2.834_645_669) < 1e-6)
        #expect(DXFImportOptions.Units.points.points == 1)
        #expect(ImportTextHandling(ImportOptionValues(["text": .string("?")])) == .editable)
    }

    // MARK: Scene model

    @Test func blobsAreContentAddressed() {
        let a = ImportedBlob(data: Data("abc".utf8), uti: "public.png")
        let b = ImportedBlob(data: Data("abc".utf8), uti: "public.png")
        #expect(a == b)
        #expect(a.hex == "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
        #expect(a.sha256.count == 32)
        #expect(a.mediaType == "image/png")
        #expect(ImportedBlob(data: Data(), uti: "not.a.type").mediaType == "application/octet-stream")
    }

    @Test func contoursBecomePathPoints() {
        var builder = ImportPathBuilder()
        builder.move(to: Point(x: 0, y: 0))
        builder.cubic(Point(x: 0, y: -10), Point(x: 20, y: -10), Point(x: 20, y: 0))
        builder.cubic(Point(x: 20, y: 10), Point(x: 0, y: 10), Point(x: 0, y: 0))
        builder.close()
        let contour = builder.build()[0]
        let points = contour.pathPoints
        #expect(points.count == 2)
        #expect(points[0].anchor == Point(x: 0, y: 0))
        #expect(points[0].outHandle == Vector(dx: 0, dy: -10))
        #expect(points[0].inHandle == Vector(dx: 0, dy: 10))
        #expect(points[0].smooth)
        #expect(points[1].smooth)
        // Lines make corners with retracted handles.
        var square = ImportPathBuilder()
        square.rect(Rect(x: 0, y: 0, width: 10, height: 10))
        let corners = square.build()[0].pathPoints
        #expect(corners.count == 4)
        #expect(corners.allSatisfy { !$0.smooth && $0.inHandle == .zero && $0.outHandle == .zero })
        // An open contour keeps every point.
        let open = ImportedContour(start: .zero, segments: [.line(to: Point(x: 5, y: 0)), .cubic(control1: Point(x: 6, y: 0), control2: Point(x: 7, y: 1), to: Point(x: 7, y: 2))])
        #expect(open.pathPoints.count == 3)
        #expect(!open.pathPoints[1].smooth)
        #expect(open.end == Point(x: 7, y: 2))
        #expect(open.allPoints.count == 5)
        let moved = open.applying(.translation(x: 1, y: 1))
        #expect(moved.start == Point(x: 1, y: 1))
        #expect(moved.segments[1] == .cubic(control1: Point(x: 7, y: 1), control2: Point(x: 8, y: 2), to: Point(x: 8, y: 3)))
        #expect(ImportedContour(start: .zero).end == .zero)
    }

    @Test func nodesExposeNamesTransformsAndDescendants() {
        let blob = ImportedBlob(data: Data([1]), uti: "public.png")
        let pixels = ImportedPixels(blob: blob, width: 2, height: 2, mode: .rgb, bitsPerChannel: 8, hasAlpha: false)
        let shift = AffineTransform.translation(x: 3, y: 4)
        let image = ImportedImage(pixels: pixels, dpiX: 0, dpiY: -1, transform: shift, name: "img")
        #expect(image.dpiX == 72 && image.dpiY == 72)
        #expect(image.naturalRect == Rect(x: 0, y: 0, width: 2, height: 2))
        let nodes: [ImportedNode] = [
            .path(ImportedPath(contours: [], transform: shift, name: "p")),
            .text(ImportedText(runs: [ImportedTextRun(text: "a", fontName: "Helvetica", fontSize: 12, origin: .zero), ImportedTextRun(text: "b", fontName: "Helvetica", fontSize: 12, origin: .zero)], transform: shift, name: "t")),
            .image(image),
            .placed(ImportedPlacedFile(kind: .eps, blob: blob, bounds: .zero, transform: shift, name: "e")),
        ]
        let group = ImportedNode.group(ImportedGroup(children: nodes, transform: shift, name: "g", role: .layer))
        #expect(group.descendants.count == 5)
        #expect(group.descendants.map(\.name) == ["g", "p", "t", "img", "e"])
        #expect(group.descendants.allSatisfy { $0.transform == shift })
        if case .text(let text) = nodes[1] {
            #expect(text.string == "ab")
        }
        for mode in ImportedColorMode.allCases {
            #expect(ImageMode.allCases.contains(mode.imageMode))
        }
        #expect(ImportedPaint.none.representativeColor == nil)
        #expect(ImportedPaint.solid(.white).representativeColor == .white)
        #expect(ImportedPaint.gradient(Gradient(from: .black, to: .white)).representativeColor == .black)
    }

    @Test func subtreesFollowTheSceneKind() {
        let blob = ImportedBlob(data: Data([1, 2]), uti: "public.png")
        let pixels = ImportedPixels(blob: blob, width: 1, height: 1, mode: .grayscale, bitsPerChannel: 8, hasAlpha: false)
        let bitmap = ImportedScene(kind: .bitmap, name: "a.png", bounds: .zero, nodes: [.image(ImportedImage(pixels: pixels))])
        guard case .image(let image) = bitmap.subtree else {
            Issue.record("bitmap subtree")
            return
        }
        #expect(image.name == "a.png")
        let named = ImportedScene(kind: .bitmap, name: "a.png", bounds: .zero, nodes: [.image(ImportedImage(pixels: pixels, name: "own"))])
        #expect(named.subtree.name == "own")
        let empty = ImportedScene(kind: .placed, name: "x", bounds: .zero, nodes: [])
        #expect(empty.subtree.name == "x")
        let odd = ImportedScene(kind: .placed, name: "x", bounds: .zero, nodes: [.path(ImportedPath(contours: [], name: "p"))])
        #expect(odd.subtree.name == "p")
        // Blobs are listed once, from nodes and layers.
        let twice = ImportedScene(kind: .vector, name: "v", bounds: .zero, nodes: [.image(ImportedImage(pixels: pixels)), .group(ImportedGroup(children: [.image(ImportedImage(pixels: pixels)), .text(ImportedText(runs: []))]))], layers: [ImportedLayer(name: "Notes", nodes: [.placed(ImportedPlacedFile(kind: .svgAnimation(css: true, smil: false, script: false, durationMs: 0), blob: ImportedBlob(data: Data([9]), uti: "public.svg-image"), bounds: .zero))])])
        #expect(twice.blobs.count == 2)
        #expect(twice.images.count == 2)
        #expect(twice.texts == [""])
    }

    // MARK: Path builder

    @Test func builderContinuesAfterClose() {
        var builder = ImportPathBuilder()
        #expect(builder.currentPoint == nil)
        builder.close()
        builder.line(to: Point(x: 1, y: 1))      // no move: starts at the origin
        #expect(builder.hasCurrentContour)
        builder.move(to: Point(x: 5, y: 5))
        builder.line(to: Point(x: 6, y: 5))
        builder.close()
        #expect(!builder.hasCurrentContour)
        #expect(builder.currentPoint == Point(x: 5, y: 5))
        builder.line(to: Point(x: 7, y: 7))       // continues from the closed contour's start
        builder.quad(Point(x: 8, y: 8), Point(x: 9, y: 7))
        let contours = builder.build()
        #expect(contours.count == 3)
        #expect(contours[2].start == Point(x: 5, y: 5))
        guard case .cubic(let c1, let c2, let end) = contours[2].segments[1] else {
            Issue.record("quad raised to cubic")
            return
        }
        #expect(end == Point(x: 9, y: 7))
        #expect(c1.isApproximatelyEqual(to: Point(x: 7 + 2.0 / 3, y: 7 + 2.0 / 3), tolerance: 1e-9))
        #expect(c2.isApproximatelyEqual(to: Point(x: 9 - 2.0 / 3, y: 7 + 2.0 / 3), tolerance: 1e-9))
        var fresh = ImportPathBuilder()
        fresh.quad(Point(x: 1, y: 1), Point(x: 2, y: 0))
        #expect(fresh.build().count == 1)
        // After an open contour is finished, drawing continues from its end.
        var open = ImportPathBuilder()
        open.move(to: .zero)
        open.line(to: Point(x: 3, y: 0))
        open.finishContour()
        #expect(open.currentPoint == Point(x: 3, y: 0))
        // Arcs and bulges with nothing drawn yet start at the origin.
        var arc = ImportPathBuilder()
        arc.svgArc(rx: 5, ry: 5, rotationDegrees: 0, largeArc: false, sweep: true, to: Point(x: 10, y: 0))
        #expect(arc.build()[0].start.isApproximatelyEqual(to: .zero))
        var bulge = ImportPathBuilder()
        bulge.bulge(1, to: Point(x: 10, y: 0), yDown: true)
        #expect(bulge.build()[0].start.isApproximatelyEqual(to: .zero))
    }

    /// The largest distance from the circle of `radius` about `center` over samples of `contour`.
    private func radialError(_ contour: ImportedContour, center: Point, radius: Double) -> Double {
        var worst = 0.0
        var from = contour.start
        for segment in contour.segments {
            guard case .cubic(let c1, let c2, let end) = segment else {
                from = segment.end
                continue
            }
            for step in 0...16 {
                let t = Double(step) / 16
                let mt = 1 - t
                let x = mt * mt * mt * from.x + 3 * mt * mt * t * c1.x + 3 * mt * t * t * c2.x + t * t * t * end.x
                let y = mt * mt * mt * from.y + 3 * mt * mt * t * c1.y + 3 * mt * t * t * c2.y + t * t * t * end.y
                worst = max(worst, abs(Point(x: x, y: y).distance(to: center) - radius))
            }
            from = end
        }
        return worst
    }

    @Test func arcsAreQuarterTurnBeziersOnTheCircle() {
        var builder = ImportPathBuilder()
        builder.ellipse(center: Point(x: 50, y: 50), rx: 40, ry: 40)
        let circle = builder.build()[0]
        #expect(circle.closed)
        #expect(circle.segments.count == 4)
        #expect(circle.end == circle.start)
        #expect(radialError(circle, center: Point(x: 50, y: 50), radius: 40) < 40 * 3e-4)
        var arc = ImportPathBuilder()
        arc.move(to: Point(x: 0, y: 0))
        arc.arc(center: Point(x: 100, y: 0), rx: 10, ry: 10, start: 0, sweep: .pi / 3)
        let contour = arc.build()[0]
        #expect(contour.segments.count == 2)         // a line to the arc's start, then one cubic
        var zero = ImportPathBuilder()
        zero.arc(center: .zero, rx: 1, ry: 1, start: 0, sweep: 0)
        zero.arc(center: .zero, rx: 1, ry: 1, start: 0, sweep: .infinity)
        #expect(zero.build()[0].segments.isEmpty)
    }

    @Test func svgArcsMatchTheImplementationNotes() {
        // A half circle of radius 50 from (0, 50) to (100, 50) through (50, 0) or (50, 100).
        for sweep in [false, true] {
            var builder = ImportPathBuilder()
            builder.move(to: Point(x: 0, y: 50))
            builder.svgArc(rx: 50, ry: 50, rotationDegrees: 0, largeArc: false, sweep: sweep, to: Point(x: 100, y: 50))
            let contour = builder.build()[0]
            #expect(contour.end == Point(x: 100, y: 50))
            #expect(radialError(contour, center: Point(x: 50, y: 50), radius: 50) < 0.02)
            let ys = contour.allPoints.map(\.y)
            // Positive angles turn clockwise on screen with y down: from the left end, the sweep
            // flag passes over the top.
            #expect(sweep ? ys.min()! < 10 : ys.max()! > 90)
        }
        // Radii too small are scaled up; zero radii make a line; a zero-length arc is nothing.
        var small = ImportPathBuilder()
        small.move(to: .zero)
        small.svgArc(rx: 1, ry: 1, rotationDegrees: 30, largeArc: true, sweep: true, to: Point(x: 10, y: 0))
        #expect(small.build()[0].end == Point(x: 10, y: 0))
        var flat = ImportPathBuilder()
        flat.move(to: .zero)
        flat.svgArc(rx: 0, ry: 5, rotationDegrees: 0, largeArc: false, sweep: false, to: Point(x: 3, y: 4))
        flat.svgArc(rx: 5, ry: 5, rotationDegrees: 0, largeArc: false, sweep: false, to: Point(x: 3, y: 4))
        let flatContour = flat.build()[0]
        #expect(flatContour.segments == [.line(to: Point(x: 3, y: 4))])
        // A large arc takes the long way round.
        var large = ImportPathBuilder()
        large.move(to: Point(x: 0, y: 50))
        large.svgArc(rx: 50, ry: 50, rotationDegrees: 0, largeArc: true, sweep: false, to: Point(x: 50, y: 0))
        #expect(large.build()[0].segments.count == 3)
    }

    @Test func bulgesAreArcsInBothOrientations() {
        // A bulge of 1 is a half circle.
        for yDown in [false, true] {
            for bulge in [1.0, -1.0, 0.5, -2.0] {
                var builder = ImportPathBuilder()
                builder.move(to: Point(x: 0, y: 0))
                builder.bulge(bulge, to: Point(x: 10, y: 0), yDown: yDown)
                let contour = builder.build()[0]
                #expect(contour.end == Point(x: 10, y: 0))
                let included = 4 * atan(bulge)
                let radius = abs(10 / (2 * sin(included / 2)))
                // The centre is on the perpendicular bisector; find it from the first sample.
                let ys = contour.allPoints.map(\.y)
                let side = (abs(ys.min()!) > abs(ys.max()!)) ? -1.0 : 1.0
                let offset = sqrt(max(radius * radius - 25, 0))
                let candidates = [Point(x: 5, y: offset), Point(x: 5, y: -offset)]
                let best = candidates.map { radialError(contour, center: $0, radius: radius) }.min()!
                #expect(best < 0.01, "bulge \(bulge) yDown \(yDown) side \(side)")
            }
        }
        // Positive bulges turn counter-clockwise in y-up: the arc of a half circle from
        // (0,0) to (10,0) passes below the chord in y-up, above it once y points down.
        var up = ImportPathBuilder()
        up.move(to: .zero)
        up.bulge(1, to: Point(x: 10, y: 0), yDown: false)
        #expect(up.build()[0].allPoints.map(\.y).min()! < -4)
        var down = ImportPathBuilder()
        down.move(to: .zero)
        down.bulge(1, to: Point(x: 10, y: 0), yDown: true)
        #expect(down.build()[0].allPoints.map(\.y).max()! > 4)
        var straight = ImportPathBuilder()
        straight.move(to: .zero)
        straight.bulge(0, to: Point(x: 10, y: 0), yDown: true)
        #expect(straight.build()[0].segments == [.line(to: Point(x: 10, y: 0))])
    }

    // MARK: Rendering

    @Test func scenesRenderThroughTheDisplayList() throws {
        var builder = ImportPathBuilder()
        builder.rect(Rect(x: 10, y: 10, width: 30, height: 20))
        let square = builder.build()
        let pixels = ImageImporter.pixels(of: Corpus.image(width: 8, height: 6))
        let clip = ImportedPath(contours: square, fillRule: .evenOdd, transform: .translation(x: 1, y: 0))
        let nodes: [ImportedNode] = [
            .path(ImportedPath(contours: square, fill: .solid(Corpus.red), stroke: ImportedStroke(paint: .solid(.black), style: StrokeStyle(width: 2)), name: "square")),
            .path(ImportedPath(contours: square, fill: .gradient(Gradient(from: .black, to: .white)), stroke: ImportedStroke(paint: .none), opacity: 0.5, transform: .translation(x: 50, y: 0))),
            .group(ImportedGroup(children: [.image(ImportedImage(pixels: pixels, transform: .translation(x: 10, y: 50)))], clip: clip, opacity: 0.8, name: "clipped")),
            .group(ImportedGroup(children: [.path(ImportedPath(contours: square, fill: .solid(Corpus.blue)))], transform: .translation(x: 100, y: 0))),
            .text(ImportedText(runs: [ImportedTextRun(text: "Hi", fontName: "Helvetica", fontSize: 18, fill: .solid(Corpus.green), origin: Point(x: 10, y: 100)), ImportedTextRun(text: "", fontName: "Helvetica", fontSize: 18, origin: .zero)])),
            .placed(ImportedPlacedFile(kind: .eps, blob: ImportedBlob(data: Data("%!PS".utf8), uti: "com.adobe.encapsulated-postscript"), bounds: Rect(x: 0, y: 0, width: 20, height: 20), transform: .translation(x: 150, y: 100))),
        ]
        let scene = ImportedScene(kind: .vector, name: "art", bounds: Rect(x: 0, y: 0, width: 200, height: 150), nodes: nodes)
        let export = scene.exportScene()
        #expect(export.pages.count == 1)
        #expect(export.assets[pixels.blob.hex] != nil)
        let items = export.pages[0].displayList.items
        #expect(items.count == 6)
        guard case .group(let clipped) = items[2] else {
            Issue.record("the clip group stays a group")
            return
        }
        #expect(clipped.clip != nil)
        #expect(clipped.clipRule == .evenOdd)
        if case .path(let moved) = items[3] {
            #expect(moved.transform == .translation(x: 100, y: 0))
        } else {
            Issue.record("a plain group is flattened into its children")
        }
        #expect(scene.scenePaths.count == 3)
        #expect(scene.scenePaths[2].contours[0].start == Point(x: 110, y: 10))
        #expect(scene.scenePaths[1].opacity == 0.5)
        #expect(scene.scenePaths[0].name == "square")
        // It renders: the red square shows where it should.
        let bitmap = BitmapRasterizer(common: BitmapCommonOptions(ppi: 72, background: .white)).render(export.pages[0], scale: 1, bitsPerComponent: 8, alpha: false).bitmap
        let pixel = ImageFixtures.pixel(bitmap.image, x: 25, y: 20)
        #expect(pixel.red > 0.8 && pixel.green < 0.3)
    }
}
