// IO-013: the exporter registry, formats, capabilities, validation, file naming and the stub.

import Foundation
import Testing
import WTGeometry
@testable import WTInterchange
import WTRender

@Suite struct ExportRegistryTests {
    @Test func everyFormatHasAnExtensionTypeAndCapabilities() {
        #expect(ExportFormat.allCases.count == 17)
        for format in ExportFormat.allCases {
            #expect(!format.fileExtension.isEmpty)
            #expect(!format.typeIdentifier.isEmpty)
            #expect(format.utType.identifier == format.typeIdentifier)
            #expect(format.description == format.displayName)
            #expect(ExportFormat(fileExtension: format.fileExtension) == format)
            #expect(ExportFormat(rawValue: format.rawValue) == format)
            switch format.family {
            case .vector: #expect(format.capabilities.contains(.vector))
            case .bitmap: #expect(format.capabilities.contains(.scales))
            case .text: #expect(!format.capabilities.contains(.vector))
            }
        }
        #expect(ExportFormat.pdf.capabilities.contains(.multiPage))
        #expect(!ExportFormat.jpeg.capabilities.contains(.alpha))
        #expect(ExportFormat.png.capabilities.contains(.alpha))
        #expect(ExportFormat.svg.capabilities.contains(.filters))
        #expect(ExportFormat(fileExtension: "JPEG") == .jpeg)
        #expect(ExportFormat(fileExtension: "tiff") == .tiff)
        #expect(ExportFormat(fileExtension: "text") == .text)
        #expect(ExportFormat(fileExtension: "doc") == nil)
        #expect(ExportFormat.png.rawValue == 10 && ExportFormat.text.rawValue == 31)
    }

    @Test func registryHandsOutExporters() throws {
        var registry = ExportRegistry.standard
        #expect(registry.formats == ExportFormat.allCases)
        let encodable = [ExportFormat.webp, .heic, .avif].filter(BitmapExporter.canEncode)
        #expect(registry.availableFormats == ExportFormat.allCases.filter { ![.webp, .heic, .avif].contains($0) || encodable.contains($0) })
        #expect(try registry.exporter(for: .svg).format == .svg)
        #expect(try registry.exporter(for: .pdf).optionsType == PDFOptions.self)
        for format in registry.availableFormats {
            let exporter = try registry.exporter(for: format)
            #expect(exporter.format == format)
            #expect(exporter.capabilities == format.capabilities)
            #expect(type(of: exporter.optionsType.defaults) == exporter.optionsType)
        }
        if !encodable.contains(.webp) {
            #expect(throws: ExportError.encoderUnavailable(.webp)) { try registry.exporter(for: .webp) }
        }
        let empty = ExportRegistry(exporters: [])
        #expect(throws: ExportError.notImplemented(.eps)) { try empty.exporter(for: .eps) }
        #expect(throws: ExportError.notImplemented(.heic)) { try empty.exporter(for: .heic) }
        registry.register(StubExporter(format: .eps))
        #expect(try registry.exporter(for: .eps).optionsType == StubExportOptions.self)
        #expect(registry.format(forExtension: "SVG") == .svg)
        #expect(registry.format(forExtension: "xyz") == nil)
        for format in [ExportFormat.png, .jpeg, .tiff, .bmp, .targa] {
            let exporter = try registry.exporter(for: format)
            #expect(exporter.capabilities == format.capabilities)
            #expect(exporter.optionsType.defaults is any BitmapFormatOptions)
        }
        #expect(SVGExporter().capabilities == ExportFormat.svg.capabilities)
        #expect(PDFExporter().capabilities == ExportFormat.pdf.capabilities)
    }

    @Test func unsupportedCombinationsAreRejected() throws {
        let registry = ExportRegistry.standard
        #expect(throws: ExportError.unsupported(.alpha, format: .jpeg)) {
            try registry.validate(ExportRequest(format: .jpeg, transparentBackground: true))
        }
        #expect(throws: ExportError.namePatternRequired(format: .png, files: 3)) {
            try registry.validate(ExportRequest(format: .png, pageCount: 3))
        }
        #expect(throws: ExportError.namePatternRequired(format: .png, files: 2)) {
            try registry.validate(ExportRequest(format: .png, pageCount: 2, namePattern: "{name}"))
        }
        #expect(throws: ExportError.unsupported(.scales, format: .svg)) {
            try registry.validate(ExportRequest(format: .svg, scales: [1, 2]))
        }
        #expect(throws: ExportError.nothingToExport) {
            try registry.validate(ExportRequest(format: .svg, pageCount: 0))
        }
        try registry.validate(ExportRequest(format: .pdf, pageCount: 5))
        try registry.validate(ExportRequest(format: .png, pageCount: 2, scales: [1, 2], transparentBackground: true, namePattern: .standard))
        try registry.validate(ExportRequest(format: .png, scales: [1, 2, 3], namePattern: "{name}"))
        try registry.validate(ExportRequest(format: .svg, pageCount: 2, namePattern: "{pagename}"))
        #expect(ExportRequest(format: .png, pageCount: 2, scales: [1, 2]).fileCount == 4)
        #expect(ExportRequest(format: .pdf, pageCount: 3).fileCount == 1)
        #expect(ExportRequest(format: .svg, pageCount: 3, scales: [1, 2]).fileCount == 3)
    }

    @Test func errorsDescribeThemselves() {
        let errors: [ExportError] = [
            .unsupported([.alpha, .multiPage, .vector, .text, .transparency, .layers, .metadata, .colorProfiles, .spotColors, .cmyk, .links, .filters, .scales], format: .jpeg),
            .namePatternRequired(format: .png, files: 2), .wrongOptions(format: .svg), .invalidOption("bad"),
            .notImplemented(.eps), .encoderUnavailable(.webp), .nothingToExport, .writeFailed("disk"),
        ]
        for error in errors {
            #expect(!error.description.isEmpty)
        }
        #expect(ExportError.unsupported(.alpha, format: .jpeg).description == "JPEG cannot hold transparency.")
        #expect(ExportError.invalidOption("bad").description == "bad")
    }

    @Test func fileNamePatternsExpandEveryToken() {
        let date = Date(timeIntervalSince1970: 1_790_000_000)
        let values = FileNamePattern.Values(name: "Catalog", page: 7, pageName: "Cover", scale: 2, date: date)
        #expect(FileNamePattern.standard.expand(values) == "Catalog-7")
        #expect(FileNamePattern("{name}-{page:3}{scale}").expand(values) == "Catalog-007@2x")
        #expect(FileNamePattern("{pagename}_{date}").expand(values).hasPrefix("Cover_2026-"))
        #expect(FileNamePattern("{pagename}").expand(FileNamePattern.Values(name: "A", page: 4)) == "4")
        #expect(FileNamePattern("{unknown}-{page:0}-{page:x}").expand(values) == "{unknown}-{page:0}-{page:x}")
        #expect(FileNamePattern("open {name").expand(values) == "open {name")
        #expect(FileNamePattern("{scale}").expand(FileNamePattern.Values(name: "a", scale: 1)) == "")
        #expect(FileNamePattern.scaleSuffix(1.5) == "@1.5x")
        #expect(FileNamePattern("{page:2}").distinguishesPages)
        #expect(FileNamePattern("{pagename}").distinguishesPages)
        #expect(!FileNamePattern("{name}").distinguishesPages)
        let literal: FileNamePattern = "{name}"
        #expect(literal.rawValue == "{name}")
        let urls = FileNamePattern.uniqueURLs(for: ["a", "a", "b", "a"], extension: "png", in: URL(fileURLWithPath: "/tmp"))
        #expect(urls.map(\.lastPathComponent) == ["a.png", "a-2.png", "b.png", "a-3.png"])
    }

    @Test func stubExporterWritesOneFilePerPage() throws {
        let directory = Corpus.directory()
        let pages = [Corpus.page(Corpus.basics, name: "One"), Corpus.page([], name: nil)]
        let scene = Corpus.scene(pages)
        let stub = StubExporter()
        #expect(stub.format == .text)
        #expect(stub.capabilities == ExportFormat.text.capabilities)
        let summary = try stub.export(scene: scene, options: StubExportOptions(delayPerPage: 0.01), to: ExportDestination(url: directory.appendingPathComponent("out.txt"), namePattern: .standard))
        #expect(summary.files.map(\.lastPathComponent) == ["out-1.txt", "out-2.txt"])
        let text = try String(contentsOf: summary.files[0], encoding: .utf8)
        #expect(text.hasPrefix("One 0.0 0.0 200.0 150.0 7"))
        #expect(throws: ExportError.namePatternRequired(format: .text, files: 2)) {
            try stub.export(scene: scene, options: StubExportOptions.defaults, to: ExportDestination(url: directory.appendingPathComponent("x.txt")))
        }
        #expect(throws: ExportError.wrongOptions(format: .text)) {
            try stub.export(scene: scene, options: SVGOptions(), to: ExportDestination(url: directory.appendingPathComponent("x.txt")))
        }
        #expect(throws: ExportError.nothingToExport) {
            try stub.export(scene: Corpus.scene([]), options: StubExportOptions(), to: ExportDestination(url: directory.appendingPathComponent("x.txt")))
        }
        let single = try stub.export(scene: Corpus.scene([pages[0]]), options: StubExportOptions(), to: ExportDestination(url: directory.appendingPathComponent("single.rtf")))
        #expect(single.files.map(\.lastPathComponent) == ["single.txt"])
    }

    @Test func sceneFactsAreLookedUpByNode() {
        let id = Corpus.node(1), nested = Corpus.node(2)
        var page = Corpus.page([Corpus.path(Corpus.rect(0, 0, 1, 1), [Corpus.fill(.solid(.black))])], nodes: [id])
        page.nestedNodeIDs = [[0, 1]: nested]
        #expect(page.nodeID(at: [0]) == id)
        #expect(page.nodeID(at: [0, 1]) == nested)
        #expect(page.nodeID(at: [3]) == nil)
        let scene = ExportScene(pages: [page], nodes: [id: ExportNodeInfo(name: "Logo")])
        #expect(scene.name == "Untitled")
        #expect(scene.rasterResolution == 300)
        #expect(scene.info(for: id)?.name == "Logo")
        #expect(scene.info(for: nil) == nil)
        #expect(ExportDocumentInfo().isEmpty)
        #expect(!ExportDocumentInfo(keywords: ["a"]).isEmpty)
        #expect(ExportSummary().files.isEmpty)
    }
}
