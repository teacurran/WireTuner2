import AppKit
import Foundation
import Testing
import UniformTypeIdentifiers
import WTCRDT
import WTGeometry
import WTInterchange
import WTModel
import WTRender
@testable import WireTuner

/// IO-040 (D-082): Illustrator, PDF, SVG, EPS and DXF files opened as new documents -- through the
/// app's real open path (the Finder's `application(_:open:)`, menu:File[Open File…], the Library's
/// button and drop) and `ForeignFileOpener` itself.
@Suite(.serialized) @MainActor struct ForeignFileOpeningTests {
    /// The fixtures, one per format: a two-page PDF (also as a PDF-compatible `.ai`), an SVG, a
    /// PostScript-only EPS and a DXF line.
    static func fixtures(in files: ImportFiles) -> [String: URL] {
        [
            "pdf": files.write("Brochure.pdf", twoPagePDF()),
            "ai": files.write("Poster.ai", twoPagePDF()),
            "svg": files.text("Icon.svg", ImportFiles.staticSVG),
            "eps": files.text("Logo.eps", "%!PS-Adobe-3.0 EPSF-3.0\n%%BoundingBox: 0 0 120 60\n%%EndComments\n0 0 moveto 10 10 lineto stroke\nshowpage\n%%EOF\n"),
            "dxf": files.text("Plan.dxf", "0\nSECTION\n2\nENTITIES\n0\nLINE\n8\nWalls\n10\n0\n20\n0\n11\n100\n21\n50\n0\nENDSEC\n0\nEOF\n"),
        ]
    }

    /// Two pages: Letter with a blue square, then a 300 × 200 page with a red one.
    static func twoPagePDF() -> Data {
        let data = NSMutableData()
        let context = CGContext(consumer: CGDataConsumer(data: data as CFMutableData)!, mediaBox: nil, nil)!
        for (size, color) in [(CGSize(width: 612, height: 792), CGColor(red: 0, green: 0, blue: 1, alpha: 1)), (CGSize(width: 300, height: 200), CGColor(red: 1, green: 0, blue: 0, alpha: 1))] {
            var box = CGRect(origin: .zero, size: size)
            context.beginPage(mediaBox: &box)
            context.setFillColor(color)
            context.fill(CGRect(x: 10, y: 10, width: 40, height: 40))
            context.endPage()
        }
        context.closePDF()
        return data as Data
    }

    /// An app delegate launched over a fake library, and its cleanup.
    @MainActor
    final class App {
        let suite = TestDefaults()
        let library = LibraryModel(services: FakeLibraryServer().services(), store: nil, thumbnails: ThumbnailCache(directory: nil))
        let delegate: AppDelegate
        var alerts: [(String, String)] = []

        init() {
            delegate = AppDelegate(layoutStore: nil, defaults: suite.defaults, library: library)
            delegate.applicationDidFinishLaunching(Notification(name: NSApplication.didFinishLaunchingNotification))
            delegate.foreignFiles.showAlert = { [unowned self] message, detail, _ in alerts.append((message, detail)) }
            delegate.packages.showAlert = { [unowned self] message, detail, _ in alerts.append((message, detail)) }
        }

        func close() {
            for id in delegate.documents.documents.map(\.id) { delegate.documents.close(id) }
            suite.remove()
        }

        /// The document titled `title` once it is open with its model.
        func opened(_ title: String) async -> DocumentHandle? {
            let documents = delegate.documents!
            guard await eventually(.seconds(10), { documents.documents.contains { $0.title == title && $0.model != nil } }) else { return nil }
            return delegate.documents.documents.first { $0.title == title }
        }
    }

    @Test func eachFormatOpensFromTheFinderAsANewLibraryDocumentAndTheFileIsUntouched() async throws {
        let app = App()
        let files = ImportFiles()
        defer {
            app.close()
            files.remove()
        }
        let fixtures = Self.fixtures(in: files)
        let before = try Dictionary(uniqueKeysWithValues: fixtures.map { key, url in
            (key, (try Data(contentsOf: url), try url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate))
        })
        let expected: [String: (title: String, pages: Int)] = ["pdf": ("Brochure", 2), "ai": ("Poster", 2), "svg": ("Icon", 1), "eps": ("Logo", 1), "dxf": ("Plan", 1)]
        for (key, url) in fixtures.sorted(by: { $0.key < $1.key }) {
            #expect(app.delegate.open(url), "\(key) is routed to the opener")
            let document = try #require(await app.opened(expected[key]!.title), "\(key) opens")
            let pages = PageList(document.state).pages
            #expect(pages.count == expected[key]!.pages, "\(key)'s pages")
            #expect(!LayerOrder(document.state).layers.isEmpty, "\(key) has its artwork on a layer")
            #expect(document.model?.canUndo == false, "opening is not an undo step")
            // In the Library, in Open Recent, and titled after the file.
            let entry = try #require(app.library.cache.documents[document.id])
            #expect(entry.name == expected[key]!.title)
            #expect(app.library.cache.recentDocuments.first?.id == document.id)
            #expect(app.delegate.documents.windowControllers[document.id]?.window?.title == expected[key]!.title)
        }
        // The two-page PDF keeps its page sizes; the Illustrator file's artboards are pages too.
        let brochure = try #require(app.delegate.documents.documents.first { $0.title == "Brochure" })
        #expect(PageList(brochure.state).pages.map(\.geometry.preset) == ["Letter", ""])
        #expect(PageList(brochure.state).pages.last?.geometry.size == Size(width: 300, height: 200))
        let plan = try #require(app.delegate.documents.documents.first { $0.title == "Plan" })
        #expect(LayerOrder(plan.state).layers.map(\.name).contains("Walls"), "the DXF's layer is a layer")
        // The originals are exactly as they were.
        for (key, url) in fixtures {
            #expect(try Data(contentsOf: url) == before[key]!.0)
            #expect(try url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate == before[key]!.1)
        }
        // The EPS holds only PostScript: it opened placed, and the report said so.
        #expect(app.alerts.contains { $0.0 == "“Logo.eps” was opened with changes." && $0.1.contains("placed EPS") })
    }

    @Test func bitmapsAndUnknownFilesDoNotOpenAndBrokenFilesAreNamed() async throws {
        let app = App()
        let files = ImportFiles()
        defer {
            app.close()
            files.remove()
        }
        let count = app.delegate.documents.documents.count
        #expect(!app.delegate.open(files.png()), "a PNG is imported, not opened")
        #expect(!PackageController.opens(files.png()) && !app.delegate.foreignFiles.opens(URL(string: "https://example.com/a.ai")!))
        let broken = files.text("Broken.svg", "not svg at all")
        #expect(await app.delegate.foreignFiles.open(broken) == nil)
        #expect(app.alerts.last?.0 == "“Broken.svg” could not be opened.")
        let disguised = files.write("Photo.pdf", try Data(contentsOf: files.png()))
        #expect(await app.delegate.foreignFiles.open(disguised) == nil)
        #expect(app.alerts.last?.1.contains("File > Import…") == true, "a PNG named .pdf is sent to Import")
        #expect(ForeignFileOpener.reason(ImportError.unsupportedFormat(name: "x"), name: "x").contains("Adobe Illustrator, SVG, AutoCAD DXF, Encapsulated PostScript and FreeHand"))
        #expect(app.delegate.documents.documents.count == count, "nothing was created")
    }

    @Test func openFileOffersPackagesAndForeignFilesAndOpensSeveral() async throws {
        let app = App()
        let files = ImportFiles()
        defer {
            app.close()
            files.remove()
        }
        let fixtures = Self.fixtures(in: files)
        let command = try #require(app.delegate.commands.command(ImportCommands.ID.openPackage))
        #expect(command.title == "Open File…" && command.defaultKey == KeyEquivalent("o", [.command, .shift]))
        var panels: [NSOpenPanel] = []
        app.delegate.packages.runOpenPanel = { panel, _ in
            panels.append(panel)
            return [fixtures["svg"]!, fixtures["ai"]!]
        }
        let first = await app.delegate.packages.openPackage()
        #expect(first?.title == "Icon")
        #expect(await app.opened("Poster") != nil)
        let panel = try #require(panels.first)
        #expect(panel.allowsMultipleSelection && panel.title == "Open File")
        for type in [UTType(filenameExtension: "ai")!, .pdf, .svg, UTType(filenameExtension: "eps")!, PackageController.contentType] {
            #expect(panel.allowedContentTypes.contains(type), "\(type.identifier)")
        }
        #expect(!panel.allowedContentTypes.contains(.png))
        // The Library window's button and a drop on it open files the same way.
        app.delegate.packages.runOpenPanel = { _, _ in [fixtures["eps"]!] }
        app.library.openFile()
        #expect(await app.opened("Logo") != nil)
        #expect(app.library.openFiles([fixtures["dxf"]!, files.png()]))
        #expect(await app.opened("Plan") != nil)
        #expect(!app.library.openFiles([files.png()]))
    }

    @Test func theOpenerUsesTheRememberedOptionsWithEveryPage() async throws {
        let world = ImportWorld()
        defer { world.close() }
        let opener = ForeignFileOpener(imports: world.imports)
        // An import remembered page 2 only; opening reads both pages.
        var remembered = PDFImportOptions().values
        remembered["pages"] = .string("2")
        remembered["importNotes"] = .bool(false)
        world.imports.options.save(remembered, for: .pdf)
        let values = try #require(opener.options(for: "a.pdf"))
        #expect(values.string("pages", default: "") == "All" && values.bool("importNotes", default: true) == false)
        #expect(opener.options(for: "a.svg")?["pages"] == nil && opener.options(for: "noext") == nil)
        // Without a way to create documents the file is refused after it is read.
        var alerts: [String] = []
        opener.showAlert = { message, detail, _ in alerts.append(message + " " + detail) }
        let pdf = world.files.write("Two.pdf", Self.twoPagePDF())
        #expect(await opener.open(pdf) == nil)
        #expect(alerts.last == "“Two.pdf” could not be opened. A new document could not be created for it.")
        // Created through the document environment, as the Library creates it.
        var templates: [DocumentCreation.Template] = []
        opener.createDocument = { title, template in
            templates.append(template)
            return world.documents.open(world.documents.environment.makeDocument(title: title, isNew: true, template: template), show: false).documentHandle
        }
        let document = try #require(await opener.open(pdf))
        #expect(document.title == "Two" && PageList(document.state).pages.count == 2 && templates.count == 1)
        guard case .imported(let source)? = templates.first else {
            Issue.record("the document is created from the file")
            return
        }
        #expect(source.link?.path == pdf.path)
        world.documents.close(document.id)
        #expect(ForeignFileOpener.openableTypes().contains(.svg) && PackageController.opens(world.files.text("x.dxf", "0\nEOF\n")))
    }

    @Test func theReportListsEachNoteOnceAndCutsALongList() {
        let world = ImportWorld()
        defer { world.close() }
        let opener = ForeignFileOpener(imports: world.imports)
        var shown: [(String, String)] = []
        opener.showAlert = { message, detail, _ in shown.append((message, detail)) }
        let page = ImportedPage(size: Size(width: 1, height: 1), nodes: [])
        opener.report(ImportedDocument(format: .pdf, name: "Quiet.pdf", pages: [page]), in: world.document)
        #expect(shown.isEmpty)
        let notes = ["same", "same"] + (1...20).map { "note \($0)" }
        opener.report(ImportedDocument(format: .pdf, name: "Busy.pdf", pages: [page], notes: notes), in: world.document)
        let detail = try? #require(shown.first?.1)
        let lines = detail?.split(separator: "\n") ?? []
        #expect(shown.first?.0 == "“Busy.pdf” was opened with changes.")
        #expect(lines.count == ForeignFileOpener.reportLimit + 1 && lines.last == "…and 9 more." && lines.filter { $0 == "same" }.count == 1)
    }

    @Test func theAppDeclaresTheFormatsAsAViewerAtAlternateRank() throws {
        let plist = try InfoPlistSourceTests.committedPlist()
        let types = plist["CFBundleDocumentTypes"] as? [[String: Any]] ?? []
        for identifier in ["com.adobe.illustrator.ai-image", "com.adobe.pdf", "com.adobe.encapsulated-postscript", "public.svg-image", "com.autodesk.dxf"] {
            let entry = types.first { ($0["LSItemContentTypes"] as? [String] ?? []).contains(identifier) }
            #expect(entry?["CFBundleTypeRole"] as? String == "Viewer" && entry?["LSHandlerRank"] as? String == "Alternate", "\(identifier)")
        }
        let imported = (plist["UTImportedTypeDeclarations"] as? [[String: Any]] ?? []).compactMap { $0["UTTypeIdentifier"] as? String }
        #expect(imported.contains("com.autodesk.dxf"))
        let bundled = (Bundle.main.infoDictionary?["CFBundleDocumentTypes"] as? [[String: Any]] ?? []).flatMap { $0["LSItemContentTypes"] as? [String] ?? [] }
        #expect(bundled.contains("com.adobe.illustrator.ai-image") && bundled.contains("com.autodesk.dxf"), "the built app declares them")
    }
}
