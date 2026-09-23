// FX-012: raster effects in print and export.  A drop shadow becomes the shadow's pixels under the
// vector object, at the object's raster effects resolution, and the PDF prints like the on-screen
// *Document resolution* render; an effect on one element renders that element alone; effects
// inside the shape are clipped by its outline; a spot-colour object with a blurred fill puts the
// blur on the process plates and its stroke on the spot plate; vector-only formats name the
// objects whose raster effects they cannot carry.

import CoreGraphics
import Foundation
import PDFKit
import Testing
import WTGeometry
@testable import WTInterchange
import WTRender

@Suite struct RasterEffectExportTests {
    static let shadowed = Corpus.node(7)

    static func shadow(resolution: Double = 150) -> DisplayItem {
        .path(PathItem(
            path: Corpus.rect(40, 30, 80, 50),
            appearance: Appearance([Corpus.fill(.solid(Corpus.red))], effects: [EffectElement(.shadow(LiveEffect.Shadow(style: .dropShadow, color: .black, offset: 6, opacity: 70, softness: 9, angle: -45)))], raster: RasterSettings(resolution: resolution)),
            transform: .identity
        ))
    }

    static func scene(_ items: [DisplayItem], nodes: [NodeID?] = [], names: [NodeID: ExportNodeInfo] = [:]) -> ExportScene {
        Corpus.scene([Corpus.page(items, nodes: nodes)], nodes: names)
    }

    static func images(_ nodes: [FlatNode]) -> [FlatImage] {
        FlattenerTests.all(nodes).compactMap { if case .image(let image) = $0 { return image } else { return nil } }
    }

    @Test func dropShadowIsItsPixelsUnderTheVectorObject() throws {
        let scene = Self.scene([Self.shadow()], nodes: [Self.shadowed], names: [Self.shadowed: ExportNodeInfo(name: "Card")])
        let flat = Flattener(target: .pdf, rasterResolution: 72).flatten(scene.pages[0], scene: scene)
        let group = try #require(flat.page.nodes.first.flatMap { if case .group(let group) = $0 { return group } else { return nil } })
        #expect(group.children.count == 2)
        guard case .image(let under) = group.children[0], case .path(let object) = group.children[1] else {
            Issue.record("expected the shadow's pixels, then the vector rectangle")
            return
        }
        #expect(object.paint == .color(Corpus.red))
        // The pixels are at the object's 150 ppi, not the export's 72.
        #expect(abs(Double(under.image.width) / under.rect.width - 150.0 / 72) < 0.01)
        #expect(flat.report.rasterized == ["raster effects of \u{201C}Card\u{201D} rendered at 150 ppi"])
        #expect(flat.report.rasterEffectObjects == ["Card"])
        // Under the object the shadow's pixels are empty (the object covers them).
        let pixels = RGBAPixels(under.image)
        let inside = ((Int((60 - under.rect.minY) * 150 / 72)) * pixels.width + Int((80 - under.rect.minX) * 150 / 72)) * 4
        #expect(pixels.bytes[inside + 3] == 0)
    }

    @Test func pdfPrintsLikeTheDocumentResolutionRender() throws {
        let page = Corpus.page([Self.shadow(resolution: 144)])
        let result = try PDFExporter().data(scene: Corpus.scene([page]), options: PDFOptions())
        let text = PDFTests.text(of: result.data)
        #expect(text.contains("/SMask") && text.contains("/Subtype /Image"))
        let rendered = PDFTests.rasterize(result.data, scale: 2)
        let reference = Corpus.reference(page, scale: 2)
        let failing = Corpus.difference(reference, rendered, tolerance: 24)
        if failing > 0.002 {
            Corpus.dump(rendered, "fx012-pdf")
            Corpus.dump(reference, "fx012-reference")
        }
        #expect(failing <= 0.002, "\(failing)")
        // Preview draws PDFs with PDFKit: the same pixels.
        let document = try #require(PDFDocument(data: result.data))
        #expect(document.pageCount == 1)
        if Ghostscript.isAvailable {
            let url = Corpus.directory().appendingPathComponent("shadow.pdf")
            try result.data.write(to: url)
            #expect(try Ghostscript.check(url, pdf: true).status == 0)
        }
    }

    @Test func bitmapExportsIncludeTheEffectResampled() throws {
        let page = Corpus.page([Self.shadow(resolution: 72)])
        let summary = try BitmapExporter(format: .png).export(scene: Corpus.scene([page]), options: PNGOptions(common: BitmapCommonOptions(ppi: 144, antiAliasing: 1, background: .white)), to: ExportDestination(url: Corpus.directory().appendingPathComponent("shadow.png")))
        let source = try #require(CGImageSourceCreateWithURL(summary.files[0] as CFURL, nil))
        let image = try #require(CGImageSourceCreateImageAtIndex(source, 0, nil))
        #expect(Corpus.difference(Corpus.reference(page, scale: 2), image, tolerance: 24) < 0.01)
    }

    @Test func elementEffectsRenderAloneAndSpotsSeparate() throws {
        let ink = SpotInk(swatch: Corpus.node(90), name: "Brand Blue")
        let blue = Color(cyan: 1, magenta: 0.6, yellow: 0, black: 0).asSpot(ink)
        let item = Corpus.path(Corpus.rect(30, 30, 100, 60), [Corpus.fill(.solid(blue)), Corpus.stroke(.solid(blue), width: 3)], effects: [EffectElement(.blur(LiveEffect.Blur(radius: 4)), target: .element(0))])
        let scene = Corpus.scene([Corpus.page([item])])
        let flat = Flattener(target: .pdf).flatten(scene.pages[0], scene: scene)
        #expect(flat.page.nodes.count == 2)
        #expect(Self.images(flat.page.nodes).count == 1)
        guard case .path(let stroke) = flat.page.nodes[1], case .stroke = stroke.style else {
            Issue.record("expected the vector stroke over the blurred fill's pixels")
            return
        }
        #expect(stroke.paint == .color(blue))
        let result = try PDFExporter().data(scene: scene, options: PDFOptions())
        let text = PDFTests.text(of: result.data)
        // The stroke is on the spot plate; the blurred fill's pixels are process colour.
        #expect(text.contains("/Separation /Brand#20Blue /DeviceCMYK") && text.contains("1 SCN"))
        #expect(text.contains("/Subtype /Image") && !text.contains("/Separation /Brand#20Blue /DeviceCMYK <</FunctionType 2 /Domain [0 1] /C0 [0 0 0 0] /C1 [1 0.6 0 0] /N 1>>] /Subtype /Image"))
        let imageDictionary = try #require(text.components(separatedBy: "obj\n").first { $0.contains("/Subtype /Image") && !$0.contains("/DeviceGray") })
        #expect(imageDictionary.contains("/ICCBased") && !imageDictionary.contains("Separation"))
        if Ghostscript.isAvailable {
            // Ghostscript's separation device lists the spot plate beside the process plates.
            let directory = Corpus.directory()
            let url = directory.appendingPathComponent("spot.pdf")
            try result.data.write(to: url)
            let run = try Ghostscript.run(["-sDEVICE=tiffsep", "-r36", "-sOutputFile=\(directory.appendingPathComponent("sep.tif").path)", url.path])
            #expect(run.status == 0)
            let plates = try FileManager.default.contentsOfDirectory(atPath: directory.path)
            #expect(plates.contains { $0.contains("Brand Blue") }, "\(plates)")
        }
    }

    @Test func insideEffectsAreClippedAndMixedEffectsRenderWhole() throws {
        let inner = Corpus.path(Corpus.ellipse(20, 20, 80, 60), [Corpus.fill(.solid(Corpus.green))], effects: [EffectElement(.shadow(LiveEffect.Shadow(style: .innerShadow, color: .black, offset: 3, opacity: 70, softness: 3)))])
        let clipped = Flattener(target: .pdf).flatten(Corpus.page([inner]), scene: Corpus.scene([Corpus.page([inner])]))
        guard case .group(let group) = clipped.page.nodes[0] else {
            Issue.record("expected a clipped group")
            return
        }
        #expect(group.clip?.path == Corpus.ellipse(20, 20, 80, 60) && Self.images(group.children).count == 1)
        #expect(PDFTests.text(of: try PDFExporter().data(scene: Corpus.scene([Corpus.page([inner])]), options: PDFOptions()).data).contains("W n"))
        // With a stroke the outline would cut it: the object renders unclipped.
        let stroked = Corpus.path(Corpus.ellipse(20, 20, 80, 60), [Corpus.fill(.solid(Corpus.green)), Corpus.stroke(.solid(.black), width: 4)], effects: [EffectElement(.bevelEmboss(LiveEffect.BevelEmboss(style: .raisedEmboss, width: 4)))])
        let whole = Flattener(target: .pdf).flatten(Corpus.page([stroked]), scene: Corpus.scene([Corpus.page([stroked])]))
        #expect(FlattenerTests.isImage(whole.page.nodes[0]))
        // A drop shadow with an inner glow: neither under nor inside only.
        let mixed = Corpus.path(Corpus.rect(20, 20, 60, 40), [Corpus.fill(.solid(Corpus.red))], effects: [
            EffectElement(.shadow(LiveEffect.Shadow(style: .dropShadow, opacity: 50))), EffectElement(.shadow(LiveEffect.Shadow(style: .innerGlow, opacity: 50))),
        ])
        let rendered = Flattener(target: .pdf).flatten(Corpus.page([mixed]), scene: Corpus.scene([Corpus.page([mixed])]))
        #expect(rendered.page.nodes.count == 1 && FlattenerTests.isImage(rendered.page.nodes[0]))
        #expect(rendered.report.rasterized == ["raster effects of an unnamed object rendered at 72 ppi"])
        // An element's pixels under a live transparency stay element pixels.
        let translucent = Corpus.path(Corpus.rect(20, 20, 60, 40), [Corpus.fill(.solid(Corpus.red)), Corpus.stroke(.solid(.black), width: 2)], effects: [
            EffectElement(.blur(LiveEffect.Blur(radius: 3)), target: .element(1)), EffectElement(.transparency(LiveEffect.Transparency(style: .basic, amount: 50))),
        ])
        let faded = Flattener(target: .pdf).flatten(Corpus.page([translucent]), scene: Corpus.scene([Corpus.page([translucent])]))
        guard case .group(let fade) = faded.page.nodes[0] else {
            Issue.record("expected an opacity group")
            return
        }
        #expect(fade.opacity == 0.5 && fade.children.count == 2 && FlattenerTests.isImage(fade.children[1]))
        // A shadow under a translucent object renders whole (transparency is not an under effect).
        let underFade = Corpus.path(Corpus.rect(20, 20, 60, 40), [Corpus.fill(.solid(Corpus.red))], effects: [
            EffectElement(.shadow(LiveEffect.Shadow(style: .dropShadow, opacity: 50))), EffectElement(.transparency(LiveEffect.Transparency(style: .feather, radius: 3))),
        ])
        let whole2 = Flattener(target: .pdf).flatten(Corpus.page([underFade]), scene: Corpus.scene([Corpus.page([underFade])]))
        #expect(whole2.page.nodes.count == 1 && FlattenerTests.isImage(whole2.page.nodes[0]))
        #expect(FlattenRun.isNoOp(.transparency(LiveEffect.Transparency(style: .basic, amount: 0))) && !FlattenRun.isNoOp(.transparency(LiveEffect.Transparency(style: .gradientMask))))
        #expect(!FlattenRun.isNoOp(.ragged(LiveEffect.Ragged(size: 1, frequency: 1))))
        // An object outside the page renders nothing.
        let offPage = Corpus.path(Corpus.rect(500, 500, 10, 10), [Corpus.fill(.solid(Corpus.red))], effects: [EffectElement(.shadow(LiveEffect.Shadow(style: .innerGlow, opacity: 50)))])
        let run = FlattenRun(flattener: Flattener(target: .pdf), page: Corpus.page([]), scene: Corpus.scene([]))
        if case .path(let item) = offPage {
            #expect(run.rasterEffect(item).isEmpty && run.effectPixels(item) == nil)
            #expect(run.flattenEffected(item).isEmpty)
        }
    }

    @Test func vectorOnlyFormatsNameWhatTheyLeaveOut() throws {
        let named = Corpus.node(3)
        let group = DisplayItem.group(GroupItem(children: [Self.shadow()], appearance: Appearance(effects: [EffectElement(.blur(LiveEffect.Blur(radius: 2)))])))
        let items = [Self.shadow(), group, Corpus.path(Corpus.rect(0, 0, 5, 5), [Corpus.fill(.solid(.black))], effects: [EffectElement(.ragged(LiveEffect.Ragged(size: 1, frequency: 2)))])]
        let scene = Self.scene(items, nodes: [named, nil, nil], names: [named: ExportNodeInfo(name: "Logo")])
        let dxf = try DXFExporter().data(scene: scene, page: 0, options: DXFOptions())
        #expect(dxf.notes.contains("raster effects left out (DXF holds no images) on \u{201C}Logo\u{201D}, 2 unnamed objects"))
        let plain = try DXFExporter().data(scene: Self.scene([Corpus.path(Corpus.rect(0, 0, 5, 5), [Corpus.fill(.solid(.black))])]), page: 0, options: DXFOptions())
        #expect(!plain.notes.contains { $0.contains("raster effects") })
        // SVG embeds the pixels and names the object in the report.
        let bevel = Corpus.path(Corpus.rect(10, 10, 50, 30), [Corpus.fill(.solid(Corpus.blue))], effects: [EffectElement(.bevelEmboss(LiveEffect.BevelEmboss(style: .outerBevel, width: 4)))])
        let svg = SVGExporter().documents(scene: Self.scene([bevel], nodes: [named], names: [named: ExportNodeInfo(name: "Logo")]), options: SVGOptions())[0]
        #expect(svg.notes.contains { $0.contains("\u{201C}Logo\u{201D}") })
    }
}
