// OBJ-015: the interchange clipboard formats.  A copy writes every enabled format that has
// something to carry, lazily per type; PDF and SVG copies read back as editable paths, a PNG as a
// bitmap object, RTF and plain text as a text block; a disabled format is absent.

import AppKit
import Foundation
import Testing
import WTGeometry
@testable import WTInterchange
import WTRender

@Suite struct ClipboardFormatTests {
    /// The selection as the model captures it: one page the size of the artwork, a red rectangle
    /// and a blue ellipse, and (optionally) one text block.
    static func scene(text: String? = nil) -> ExportScene {
        let items: [DisplayItem] = [
            Corpus.path(Corpus.rect(10, 10, 60, 40), [Corpus.fill(.solid(Corpus.red))]),
            Corpus.path(Corpus.ellipse(90, 20, 50, 30), [Corpus.fill(.solid(Corpus.blue)), Corpus.stroke(.solid(.black), width: 2)]),
        ]
        var scene = Corpus.scene([Corpus.page(items, width: 150, height: 60)])
        if let text {
            var attributes = ExportTextAttributes()
            attributes.fontFamily = "Helvetica"
            attributes.size = 20
            attributes.color = Corpus.red
            scene.text = [ExportTextBlock(node: Corpus.node(9), page: 0, stackingOrder: 0,
                                          story: ExportStory(paragraphs: text.split(separator: "\n").map { ExportParagraph([ExportTextRun(String($0), attributes: attributes)]) }))]
        }
        return scene
    }

    static func paths(_ nodes: [ImportedNode]) -> [ImportedPath] {
        nodes.flatMap(\.descendants).compactMap { node in
            if case .path(let path) = node { return path }
            return nil
        }
    }

    // MARK: Formats and settings

    @Test func formatsKnowTheirTypesNamesAndOrder() {
        #expect(ClipboardFormat.image.writtenTypes == ["public.tiff", "public.png"])
        #expect(ClipboardFormat.image.readTypes == ["public.png", "public.tiff"])
        #expect(ClipboardFormat.native.readTypes == ["com.villagecompute.wiretuner.objects", "com.wiretuner.objects"])
        #expect(ClipboardFormat.pdf.writtenTypes == ["com.adobe.pdf"])
        #expect(ClipboardFormat.svg.readTypes == ["public.svg-image"])
        #expect(ClipboardFormat.rtf.writtenTypes == ["public.rtf"])
        #expect(ClipboardFormat.plainText.writtenTypes == ["public.utf8-plain-text"])
        #expect(ClipboardFormat.allCases.map(\.displayName) == ["WireTuner", "PDF", "SVG", "Image (TIFF and PNG)", "Rich text (RTF)", "Plain text"])
        #expect(ClipboardFormat.allCases.filter(\.isText) == [.rtf, .plainText])
        #expect(ClipboardFormat(pasteboardType: "com.wiretuner.objects") == .native)
        #expect(ClipboardFormat(pasteboardType: "public.tiff") == .image)
        #expect(ClipboardFormat(pasteboardType: "public.jpeg") == nil)
        #expect(ClipboardColors.allCases.map(\.displayName) == ["CMYK", "RGB", "CMYK and RGB"])
        #expect(ClipboardColors.allCases.map(\.pdfColors) == [.convertToCMYK, .convertToRGB, .keep])
    }

    @Test func settingsDefaultToEverythingAndKeepNative() {
        let defaults = ClipboardSettings()
        #expect(defaults.formats == Set(ClipboardFormat.allCases))
        #expect(defaults.colors == .cmykAndRGB)
        #expect(defaults.imageResolution == 144)
        #expect(ClipboardSettings.optionalFormats == [.pdf, .svg, .image, .rtf, .plainText])
        // Native cannot be switched off, by the initializer or the toggle.
        #expect(ClipboardSettings(formats: [.pdf]).formats == [.native, .pdf])
        #expect(defaults.setting(.native, enabled: false).formats.contains(.native))
        #expect(!defaults.setting(.svg, enabled: false).formats.contains(.svg))
        #expect(defaults.setting(.svg, enabled: false).setting(.svg, enabled: true) == defaults)
        // The resolution is clamped to the preference's range.
        #expect(ClipboardSettings(imageResolution: 1).imageResolution == 72)
        #expect(ClipboardSettings(imageResolution: 99_999).imageResolution == 2400)
        // Copy Special writes one format alone.
        #expect(defaults.only(.svg).formats == [.svg])
    }

    // MARK: Writing

    @Test func aCopyOffersEveryEnabledFormatThatHasSomethingToCarry() throws {
        let native = Data([1, 2, 3])
        let artwork = ClipboardWriter(scene: Self.scene(), native: native)
        // No text selected: no text formats.
        #expect(artwork.types == ["com.villagecompute.wiretuner.objects", "com.adobe.pdf", "public.svg-image", "public.tiff", "public.png"])
        let withText = ClipboardWriter(scene: Self.scene(text: "Hello"), native: native)
        #expect(withText.formats == [.native, .pdf, .svg, .image, .rtf, .plainText])
        #expect(try withText.data(for: ClipboardFormat.nativeType) == native)
        // No payload: no native type; nothing on a page: no vector or image formats.
        #expect(ClipboardWriter(scene: Self.scene()).formats == [.pdf, .svg, .image])
        var empty = Self.scene(text: "Only text")
        empty.pages = []
        #expect(ClipboardWriter(scene: empty).formats == [.rtf, .plainText])
        // A type not offered has no data.
        #expect(try artwork.data(for: "public.rtf") == nil)
        #expect(try artwork.data(for: "public.jpeg") == nil)
    }

    @Test func disablingAFormatRemovesItFromThePasteboard() throws {
        let settings = ClipboardSettings().setting(.pdf, enabled: false).setting(.image, enabled: false)
        let writer = ClipboardWriter(scene: Self.scene(text: "Hi"), settings: settings, native: Data([0]))
        #expect(!writer.types.contains("com.adobe.pdf"))
        #expect(!writer.types.contains("public.tiff") && !writer.types.contains("public.png"))
        #expect(writer.types == ["com.villagecompute.wiretuner.objects", "public.svg-image", "public.rtf", "public.utf8-plain-text"])
        #expect(try writer.allData().map(\.type) == writer.types)
        #expect(try writer.data(for: "com.adobe.pdf") == nil)
        // Copy Special: exactly one format.
        let special = ClipboardWriter(scene: Self.scene(), settings: ClipboardSettings().only(.svg), native: Data([0]))
        #expect(special.types == ["public.svg-image"])
    }

    @Test func pdfAndSVGCopiesReadBackAsEditablePaths() throws {
        let writer = ClipboardWriter(scene: Self.scene())
        let pdf = try #require(try writer.data(for: ClipboardFormat.pdfType))
        #expect(pdf.starts(with: Array("%PDF".utf8)))
        let fromPDF = try ClipboardReader.read(.pdf, types: writer.types) { $0 == ClipboardFormat.pdfType ? pdf : nil }
        #expect(fromPDF.kind == .vector)
        #expect(Self.paths(fromPDF.nodes).count >= 2)
        let svg = try #require(try writer.data(for: ClipboardFormat.svgType))
        #expect(String(decoding: svg, as: UTF8.self).contains("<svg"))
        let fromSVG = try ClipboardReader.read(.svg, types: [ClipboardFormat.svgType]) { _ in svg }
        let paths = Self.paths(fromSVG.nodes)
        #expect(paths.count >= 2)
        #expect(paths.contains { $0.fill.representativeColor.map { abs($0.red - Corpus.red.red) < 0.01 } == true })
    }

    @Test func pdfCopiesConvertColorsAsTheSettingSays() throws {
        let rgb = try #require(try ClipboardWriter(scene: Self.scene(), settings: ClipboardSettings(colors: .rgb)).data(for: ClipboardFormat.pdfType))
        let cmyk = try #require(try ClipboardWriter(scene: Self.scene(), settings: ClipboardSettings(colors: .cmyk)).data(for: ClipboardFormat.pdfType))
        #expect(rgb != cmyk)
    }

    @Test func imageCopiesAreRasterizedAtTheClipboardResolution() throws {
        let writer = ClipboardWriter(scene: Self.scene(), settings: ClipboardSettings(imageResolution: 144))
        let png = try #require(try writer.data(for: ClipboardFormat.pngType))
        let tiff = try #require(try writer.data(for: ClipboardFormat.tiffType))
        for data in [png, tiff] {
            let image = try #require(NSBitmapImageRep(data: data))
            // A 150 x 60 pt page at 144 ppi.
            #expect(image.pixelsWide == 300 && image.pixelsHigh == 120)
            #expect(image.hasAlpha)
        }
        // A PNG pastes as a bitmap object; with both present, PNG is the one read.
        let scene = try ClipboardReader.read(.image, types: ClipboardFormat.image.writtenTypes) { $0 == ClipboardFormat.pngType ? png : tiff }
        #expect(scene.kind == .bitmap)
        guard case .image(let image)? = scene.nodes.first else { Issue.record("no image"); return }
        #expect(image.pixels.width == 300 && image.pixels.blob.uti == "public.png")
        let fromTIFF = try ClipboardReader.read(.image, types: [ClipboardFormat.tiffType]) { _ in tiff }
        #expect(fromTIFF.kind == .bitmap)
    }

    // MARK: Text

    @Test func textCopiesRoundTripThroughRTFAndPlainText() throws {
        let writer = ClipboardWriter(scene: Self.scene(text: "Hello\nWorld"))
        let plain = try #require(try writer.data(for: ClipboardFormat.plainTextType))
        #expect(String(decoding: plain, as: UTF8.self) == "Hello\nWorld")
        let rtf = try #require(try writer.data(for: ClipboardFormat.rtfType))
        let fromRTF = try ClipboardReader.read(.rtf, types: [ClipboardFormat.rtfType, ClipboardFormat.plainTextType]) { $0 == ClipboardFormat.rtfType ? rtf : nil }
        guard case .text(let text)? = fromRTF.nodes.first else { Issue.record("no text"); return }
        #expect(text.string == "HelloWorld")
        #expect(text.runs.count == 2 && text.runs[1].origin.y > text.runs[0].origin.y)
        #expect(text.runs[0].fontSize == 20 && text.runs[0].fontName.hasPrefix("Helvetica"))
        #expect(text.runs[0].fill.representativeColor.map { abs($0.red - Corpus.red.red) < 0.02 } == true)
        let fromPlain = try ClipboardReader.read(.plainText, types: [ClipboardFormat.plainTextType]) { _ in plain }
        guard case .text(let plainText)? = fromPlain.nodes.first else { Issue.record("no text"); return }
        #expect(plainText.runs.map(\.text) == ["Hello", "World"])
        #expect(plainText.runs[0].fontName == "Helvetica" && plainText.runs[0].fontSize == 12)
        #expect(fromPlain.bounds.height == 2 * 12 * 1.2)
    }

    @Test func textReadingKeepsBlankLinesAndRefusesNothing() throws {
        let scene = try ClipboardReader.text("A\r\n\r\nB\n\n")
        guard case .text(let text)? = scene.nodes.first else { Issue.record("no text"); return }
        #expect(text.runs.map(\.text) == ["A", "", "B"])
        #expect(throws: ImportError.empty(name: "Pasted")) { try ClipboardReader.text("\n\n") }
        // An RTF blank line keeps its baseline with an empty run.
        let attributed = NSAttributedString(string: "One\n\nTwo", attributes: [.font: NSFont(name: "Helvetica", size: 10)!])
        let rtf = try attributed.data(from: NSRange(location: 0, length: attributed.length), documentAttributes: [.documentType: NSAttributedString.DocumentType.rtf])
        guard case .text(let rich)? = try ClipboardReader.text(rtf: rtf).nodes.first else { Issue.record("no text"); return }
        #expect(rich.runs.map(\.text) == ["One", "", "Two"])
        #expect(Set(rich.runs.map(\.origin.y)).count == 3)
        // A run without a font or colour takes plain text's.
        let bare = ClipboardReader.style([:])
        #expect(bare.font == "Helvetica" && bare.size == 12 && bare.color == .black)
        // Plain text in the RTF slot is not RTF.
        #expect(throws: ImportError.self) { try ClipboardReader.text(rtf: Data("not rtf".utf8)) }
    }

    // MARK: Reading

    @Test func pasteTakesTheRichestFormatAndPasteSpecialListsOnlyPresentOnes() throws {
        let types = ["public.utf8-plain-text", "public.tiff", "com.adobe.pdf", "public.rtf", "public.jpeg"]
        #expect(ClipboardReader.formats(in: types) == [.pdf, .image, .rtf, .plainText])
        #expect(ClipboardReader.richest(in: types) == .pdf)
        #expect(ClipboardReader.richest(in: ["public.jpeg"]) == nil)
        #expect(ClipboardReader.formats(in: ["com.wiretuner.objects", "public.png"]) == [.native, .image])
        // Native present: the app pastes it, not the reader.
        #expect(try ClipboardReader.readRichest(types: ["com.villagecompute.wiretuner.objects", "public.utf8-plain-text"]) { _ in Data("x".utf8) } == nil)
        #expect(try ClipboardReader.readRichest(types: []) { _ in nil } == nil)
        let text = try #require(try ClipboardReader.readRichest(types: ["public.utf8-plain-text"]) { _ in Data("Hi".utf8) })
        #expect(text.name == "Pasted" && text.kind == .vector)
        // Reading native, or a format whose bytes are missing, is refused.
        #expect(throws: ImportError.unsupportedFormat(name: "Pasted")) {
            try ClipboardReader.read(.native, types: ["com.villagecompute.wiretuner.objects"]) { _ in Data() }
        }
        #expect(throws: ImportError.unsupportedFormat(name: "Clip")) {
            try ClipboardReader.read(.svg, types: ["public.svg-image"], name: "Clip") { _ in nil }
        }
        #expect(throws: ImportError.unsupportedFormat(name: "Pasted")) {
            try ClipboardReader.read(.pdf, types: ["public.svg-image"]) { _ in Data() }
        }
    }
}
