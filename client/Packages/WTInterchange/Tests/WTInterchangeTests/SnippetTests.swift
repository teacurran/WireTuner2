// COLLAB-036: the snippet library.  A corpus of rectangles, rounded rectangles, ellipses, paths,
// gradients, shadows and text runs is written in every notation and unit and checked for content
// and byte-identical reruns; each SVG snippet re-imports and renders within tolerance of the
// object; the Swift snippets compile with swiftc and, for the shapes, render within tolerance at
// 2× through `ImageRenderer`; colour values agree with ColorSync to half a step of 255 and OKLCH
// round-trips to sRGB within 0.001.

import CoreGraphics
import Foundation
import ImageIO
import Testing
import WTGeometry
@testable import WTInterchange
import WTRender
import struct WTRender.StrokeStyle

@Suite struct SnippetTests {
    static let brand = Color(red: 0.902, green: 0.224, blue: 0.275)

    static func roundedRect(_ r: Rect, radius: Double) -> DisplayPath {
        let k = 0.5522847498 * radius
        var path = DisplayPath()
        path.move(to: Point(x: r.minX + radius, y: r.minY))
        path.addLine(to: Point(x: r.maxX - radius, y: r.minY))
        path.addCubicCurve(control1: Point(x: r.maxX - radius + k, y: r.minY), control2: Point(x: r.maxX, y: r.minY + radius - k), to: Point(x: r.maxX, y: r.minY + radius))
        path.addLine(to: Point(x: r.maxX, y: r.maxY - radius))
        path.addCubicCurve(control1: Point(x: r.maxX, y: r.maxY - radius + k), control2: Point(x: r.maxX - radius + k, y: r.maxY), to: Point(x: r.maxX - radius, y: r.maxY))
        path.addLine(to: Point(x: r.minX + radius, y: r.maxY))
        path.addCubicCurve(control1: Point(x: r.minX + radius - k, y: r.maxY), control2: Point(x: r.minX, y: r.maxY - radius + k), to: Point(x: r.minX, y: r.maxY - radius))
        path.addLine(to: Point(x: r.minX, y: r.minY + radius))
        path.addCubicCurve(control1: Point(x: r.minX, y: r.minY + radius - k), control2: Point(x: r.minX + radius - k, y: r.minY), to: Point(x: r.minX + radius, y: r.minY))
        path.close()
        return path
    }

    static var triangle: DisplayPath {
        var path = DisplayPath()
        path.move(to: Point(x: 10, y: 60))
        path.addQuadCurve(control: Point(x: 40, y: 0), to: Point(x: 70, y: 60))
        path.addCubicCurve(control1: Point(x: 60, y: 70), control2: Point(x: 20, y: 70), to: Point(x: 10, y: 60))
        path.close()
        return path
    }

    static let shadow = EffectElement(.shadow(LiveEffect.Shadow(style: .dropShadow, color: .black, offset: 4, opacity: 50, softness: 6, angle: -45)))
    static let glow = EffectElement(.shadow(LiveEffect.Shadow(style: .innerGlow, color: Corpus.yellow, offset: 2, opacity: 80, softness: 3)))

    /// The corpus, by name.  Shapes without strokes or shadows also render through SwiftUI.
    static var corpus: [(name: String, object: SnippetObject, renders: Bool)] {
        let linear = Paint.gradient(Gradient(.linear, from: brand, to: Corpus.blue, axis: Gradient.Axis(start: Point(x: 0, y: 0), end: Point(x: 60, y: 0))))
        let radial = Paint.gradient(Gradient(.radial, from: .white, to: Corpus.green, axis: Gradient.Axis(start: Point(x: 50, y: 30), end: Point(x: 80, y: 30))))
        let bold = TextRunItem(text: "Bold \"quoted\"\n", glyphRun: Corpus.run("Bold", font: "Helvetica-Bold", size: 24), origin: Point(x: 10, y: 40), color: brand)
        let plain = TextRunItem(text: "plain", glyphRun: Corpus.run("plain", font: "Helvetica-Oblique", size: 14, origin: Point(x: 80, y: 40)), origin: Point(x: 80, y: 40), color: Corpus.blue)
        return [
            ("rectangle", SnippetObject(name: "Brand box", node: Corpus.node(1), shape: .rectangle,
                                        item: Corpus.path(Corpus.rect(10, 20, 60, 40), [Corpus.fill(.solid(brand))]), swatchNames: [brand: "Brand red"]), true),
            ("stroked", SnippetObject(name: "Card", shape: .roundedRectangle(radius: 8),
                                      item: Corpus.path(roundedRect(Rect(x: 0, y: 0, width: 120, height: 48), radius: 8),
                                                        [Corpus.fill(.solid(.white)), Corpus.stroke(.solid(Corpus.blue), width: 2, cap: .round, join: .bevel, dash: [4, 2])],
                                                        effects: [shadow, glow]), opacity: 0.8, swatchNames: [Corpus.blue: "1st blue"]), false),
            ("rounded", SnippetObject(name: "Pill", shape: .roundedRectangle(radius: 12),
                                      item: Corpus.path(roundedRect(Rect(x: 5, y: 5, width: 80, height: 24), radius: 12), [Corpus.fill(linear)])), true),
            ("ellipse", SnippetObject(name: "Oval", shape: .ellipse, item: Corpus.path(Corpus.ellipse(0, 0, 100, 60), [Corpus.fill(radial)])), true),
            ("circle", SnippetObject(shape: .ellipse, item: Corpus.path(Corpus.ellipse(0, 0, 40, 40), [Corpus.fill(.solid(Corpus.green.withAlpha(multipliedBy: 0.5)))])), true),
            ("path", SnippetObject(name: "Leaf", shape: .path,
                                   item: Corpus.path(triangle, [Corpus.fill(.solid(Corpus.yellow), rule: .evenOdd), Corpus.stroke(.solid(.black), width: 1)],
                                                     transform: .translation(x: 5, y: 5))), false),
            ("text", SnippetObject(name: "Headline", shape: .text, item: .group(GroupItem(children: [.text(bold), .text(plain)])), leading: 30, tracking: 20,
                                   swatchNames: [brand: "Headline red"]), false),
            ("pattern", SnippetObject(name: "Hatch", shape: .rectangle,
                                      item: Corpus.path(Corpus.rect(0, 0, 30, 30), [Corpus.fill(.solid(.white)), Corpus.fill(.pattern(PatternPaint(bitmap: PatternBitmap(rows: [0xAA, 0x55]), color: .black)))],
                                                        effects: [EffectElement(.blur(LiveEffect.Blur()))]), cannotExpress: ["a blend"]), false),
        ]
    }

    // MARK: Snapshots

    @Test func snapshotsInEveryNotationAndUnitAreStable() throws {
        for (name, object, _) in Self.corpus {
            for notation in SnippetNotation.allCases {
                for unit in SnippetUnit.allCases {
                    let options = SnippetOptions(notation: notation, unit: unit, scale: 2)
                    let css = CSSSnippet.make(object, options: options)
                    let swift = SwiftSnippet.make(object, options: options)
                    #expect(css == CSSSnippet.make(object, options: options), "\(name) \(notation) \(unit)")
                    #expect(swift == SwiftSnippet.make(object, options: options), "\(name) \(notation) \(unit)")
                    if object.shape != .text { #expect(css.contains(": \(unit.format(object.bounds.width, scale: 2));"), "\(name) \(unit)") }
                }
            }
            #expect(SVGSnippet.make(object) == SVGSnippet.make(object))
            #expect(PNGSnippet.make(object, scale: 2) == PNGSnippet.make(object, scale: 2))
        }
    }

    @Test func rectangleSnapshots() throws {
        let object = Self.corpus[0].object
        #expect(CSSSnippet.make(object, options: SnippetOptions()) == """
        :root {
          --brand-red: #E63946;
        }

        .brand-box {
          width: 60px;
          height: 40px;
          background: var(--brand-red);
        }

        """)
        #expect(SwiftSnippet.make(object, options: SnippetOptions()).text == """
        extension Color {
            static let brandRed = Color(red: 0.902, green: 0.224, blue: 0.275)
        }

        Rectangle()
            .fill(Color.brandRed)
            .frame(width: 60, height: 40)

        """)
        let p3 = SwiftSnippet.make(object, options: SnippetOptions(notation: .displayP3)).declarations
        #expect(p3.contains("static let brandRed = Color(.displayP3, red: "))
        let svg = SVGSnippet.make(object)
        #expect(svg.contains("viewBox=\"0 0 60 40\"") && svg.contains("id=\"Brand-box\"") || svg.contains("id=\"Brand_box\"") || svg.contains("Brand"))
    }

    @Test func declarationsFollowTheGuide() throws {
        let objects = Dictionary(uniqueKeysWithValues: Self.corpus.map { ($0.name, $0.object) })
        let options = SnippetOptions(unit: .points)
        let card = CSSSnippet.make(objects["stroked"]!, options: options)
        #expect(card.contains("--c-1st-blue: #1A4DE6;") && card.contains("--color-1: #FFFFFF;"))
        #expect(card.contains("border: 2pt dashed var(--c-1st-blue);") && card.contains("border-radius: 8pt;"))
        #expect(card.contains("box-shadow: 2.83pt 2.83pt 6pt var(--color-3), inset 0pt 0pt 3pt 2pt var(--color-4);"))
        #expect(card.contains("opacity: 0.8;") && card.contains(".card {"))
        let cardSwift = SwiftSnippet.make(objects["stroked"]!, options: options)
        #expect(cardSwift.declarations.contains("static let swatch1stBlue = Color(red: 0.1, green: 0.3, blue: 0.9)"))
        #expect(cardSwift.view.contains("StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .bevel, dash: [4, 2])"))
        #expect(cardSwift.view.contains(".shadow(color: Color(red: 0, green: 0, blue: 0, opacity: 0.5), radius: 6, x: 2.828, y: 2.828)"))
        #expect(cardSwift.view.contains(".opacity(0.8)"))
        #expect(CSSSnippet.make(objects["rounded"]!, options: options).contains("background: linear-gradient(90deg, var(--color-1) 0%, var(--color-2) 100%);"))
        #expect(SwiftSnippet.make(objects["rounded"]!, options: options).view.contains("RoundedRectangle(cornerRadius: 12)\n    .fill(LinearGradient(stops: ["))
        let oval = CSSSnippet.make(objects["ellipse"]!, options: options)
        #expect(oval.contains("radial-gradient(circle at 50% 50%, var(--color-1) 0%, var(--color-2) 100%)") && oval.contains("border-radius: 50%;"))
        #expect(SwiftSnippet.make(objects["ellipse"]!, options: options).view.hasPrefix("Ellipse()\n    .fill(RadialGradient(stops: "))
        #expect(SwiftSnippet.make(objects["circle"]!, options: options).view.hasPrefix("Circle()\n    .fill(Color(red: 0.1, green: 0.7, blue: 0.3, opacity: 0.5))"))
        #expect(CSSSnippet.make(objects["circle"]!, options: options).contains("--color-1: #1AB34D80;") && CSSSnippet.make(objects["circle"]!, options: options).contains(".object {"))
        // A free path: Swift draws it; CSS falls back to its SVG.
        let leaf = SwiftSnippet.make(objects["path"]!, options: options)
        #expect(leaf.view.hasPrefix("Path { path in\n    path.move(to: CGPoint(x: 0, y: 60))"))
        #expect(leaf.view.contains("path.addQuadCurve(to: CGPoint(x: 60, y: 60), control: CGPoint(x: 30, y: 0))") && leaf.view.contains("style: FillStyle(eoFill: true)"))
        #expect(CSSSnippet.make(objects["path"]!, options: options).contains("/* CSS cannot express this shape; the flattened SVG is the background. */"))
        // Text.
        let headline = CSSSnippet.make(objects["text"]!, options: options)
        #expect(headline.contains("font-family: \"Helvetica\";") && headline.contains("font-weight: 700;") && headline.contains("font-size: 24pt;"))
        #expect(headline.contains("line-height: 30pt;") && headline.contains("letter-spacing: 0.48pt;") && headline.contains("color: var(--headline-red);"))
        #expect(headline.contains(".headline span:nth-of-type(2) {") && headline.contains("font-style: italic;"))
        let headlineSwift = SwiftSnippet.make(objects["text"]!, options: options).view
        #expect(headlineSwift.hasPrefix("(Text(\"Bold \\\"quoted\\\"\\n\")\n        .font(.custom(\"Helvetica-Bold\", size: 24))\n        .kerning(0.48)\n        .foregroundStyle(Color.headlineRed)\n    + Text(\"plain\")"))
        #expect(headlineSwift.hasSuffix("    .lineSpacing(1.2)"))
        // What neither can express.
        let hatch = CSSSnippet.make(objects["pattern"]!, options: options)
        #expect(hatch.contains("/* CSS cannot express a blend, a pattern fill, several fills and the blur effect; the flattened SVG is the background. */"))
        #expect(hatch.contains("background: url(\"data:image/svg+xml;base64,"))
        #expect(SwiftSnippet.make(objects["pattern"]!, options: options).declarations.hasPrefix("// SwiftUI cannot express a blend, a pattern fill, several fills and the blur effect; the flattened SVG:\n/*\n<?xml"))
    }

    @Test func smallPiecesAndEdges() throws {
        #expect(CSSSnippet.slug(" Brand -- Red! ") == "brand-red" && CSSSnippet.slug("!!") == "" && CSSSnippet.slug("2nd") == "c-2nd")
        #expect(SwiftSnippet.identifier("brand red") == "brandRed" && SwiftSnippet.identifier("3 blues") == "swatch3Blues" && SwiftSnippet.identifier("***") == "swatch")
        #expect(SwiftSnippet.stringLiteral("a\tb\r\\") == "\"a\\tb\\r\\\\\"")
        #expect(CSSSnippet.list(["a"]) == "a" && CSSSnippet.list(["a", "b"]) == "a and b")
        #expect(SnippetUnit.millimeters.format(72, scale: 3) == "25.4mm" && SnippetUnit.centimeters.format(72, scale: 1) == "2.54cm")
        #expect(SnippetUnit.inches.format(36, scale: 1) == "0.5in" && SnippetUnit.pixels.format(100, scale: 2) == "200px")
        #expect(SnippetOptions(scale: -1).scale == 1 && SnippetOptions(scale: .infinity).scale == 1)
        #expect(SnippetColors.parseOKLCH("rgb(1 2 3)") == nil && SnippetColors.parseOKLCH("oklch(1 2 3)") == nil)
        // PNG sizes and file names.
        let box = Self.corpus[0].object
        for scale in [1.0, 2, 3] {
            let data = PNGSnippet.make(box, scale: scale)
            let image = try #require(CGImageSourceCreateWithData(data as CFData, nil).flatMap { CGImageSourceCreateImageAtIndex($0, 0, nil) })
            #expect(image.width == Int(60 * scale) && image.height == Int(40 * scale))
        }
        #expect(PNGSnippet.fileName(box, scale: 2) == "Brand box@2x.png" && PNGSnippet.fileName(box, scale: 1) == "Brand box.png")
        #expect(PNGSnippet.fileName(SnippetObject(name: "a/b:c", shape: .other, item: box.item), scale: 1.5) == "a-b-c@1.5x.png")
        #expect(PNGSnippet.fileName(SnippetObject(shape: .other, item: box.item), scale: 1) == "Object.png")
        // Other objects: a frame in Swift, the SVG in CSS; an empty item still makes a page.
        let group = SnippetObject(shape: .other, item: .group(GroupItem(children: [box.item])))
        #expect(SwiftSnippet.make(group, options: SnippetOptions()).view == "Rectangle()\n    .fill(Color.clear)\n    .frame(width: 60, height: 40)")
        #expect(CSSSnippet.make(group, options: SnippetOptions()).contains("cannot express this shape"))
        let empty = SnippetObject(shape: .text, item: .group(GroupItem(children: [])))
        #expect(SwiftSnippet.make(empty, options: SnippetOptions()).view == "Text(\"\")")
        #expect(empty.page.bounds.width == 1 && empty.bounds == .zero)
        // A placeholder text run (no glyphs) is skipped; a stroke without fill fills clear.
        let placeholder = SnippetObject(shape: .text, item: .text(TextRunItem(text: "x", origin: .zero, bounds: Rect(x: 0, y: 0, width: 5, height: 5))))
        #expect(!CSSSnippet.make(placeholder, options: SnippetOptions()).contains("font-family"))
        let outline = SnippetObject(shape: .rectangle, item: Corpus.path(Corpus.rect(0, 0, 10, 10), [Corpus.stroke(.solid(.black), width: 1)]))
        #expect(SwiftSnippet.make(outline, options: SnippetOptions()).view.contains(".fill(Color.clear)"))
        #expect(SwiftSnippet.path(placeholder) == "Path()")
        // Gradients without an axis, glows, other gradient kinds, stroke paints SwiftUI cannot draw.
        let auto = SnippetObject(shape: .rectangle, item: Corpus.path(Corpus.rect(0, 0, 10, 10), [
            Corpus.fill(.gradient(Gradient(.linear, from: .white, to: .black))), Corpus.stroke(.gradient(Gradient(.cone, from: .white, to: .black)), width: 1),
        ], effects: [EffectElement(.shadow(LiveEffect.Shadow(style: .glow, color: .black, offset: 1, opacity: 100))), EffectElement(.blur(LiveEffect.Blur()), hidden: true)]))
        #expect(CSSSnippet.make(auto, options: SnippetOptions()).contains("linear-gradient(90deg,") && CSSSnippet.make(auto, options: SnippetOptions()).contains("0px 0px 0px 1px"))
        #expect(SwiftSnippet.make(auto, options: SnippetOptions()).view.contains("startPoint: .leading, endPoint: .trailing"))
        #expect(auto.unexpressible == ["a cone gradient"])
        let radial = SnippetObject(shape: .ellipse, item: Corpus.path(Corpus.ellipse(0, 0, 10, 20), [Corpus.fill(.gradient(Gradient(.radial, from: .white, to: .black)))]))
        #expect(SwiftSnippet.make(radial, options: SnippetOptions()).view.contains("center: UnitPoint(x: 0.5, y: 0.5), startRadius: 0, endRadius: 10"))
        let flat = SnippetObject(shape: .rectangle, item: Corpus.path(Corpus.rect(0, 0, 0, 0), [Corpus.fill(.gradient(Gradient(.radial, from: .white, to: .black, axis: Gradient.Axis(start: .zero, end: Point(x: 1, y: 0)))))]))
        #expect(CSSSnippet.make(flat, options: SnippetOptions()).contains("circle at 50% 50%"))
        #expect(SwiftSnippet.make(flat, options: SnippetOptions()).view.contains("UnitPoint(x: 0.5, y: 0.5)"))
        let kinds: [Paint] = [.custom(CustomFill(pattern: .bricks)), .textured(TexturedFill(texture: .oak, color: .black)), .tiled(TiledFill(tile: [Corpus.path(Corpus.rect(0, 0, 2, 2), [Corpus.fill(.solid(.black))])])), .lens(LensFill(type: .invert))]
        let others = SnippetObject(shape: .rectangle, item: Corpus.path(Corpus.rect(0, 0, 1, 1), kinds.map { Corpus.fill($0) }))
        #expect(Set(others.unexpressible).isSuperset(of: ["a custom fill", "a textured fill", "a tiled fill", "a lens fill"]))
        // A colour whose swatch name repeats another's gets a numbered property.
        let twins = SnippetObject(shape: .rectangle, item: Corpus.path(Corpus.rect(0, 0, 1, 1), [Corpus.fill(.solid(.white)), Corpus.stroke(.solid(.black), width: 1)]),
                                  swatchNames: [.white: "Ink", .black: "Ink"])
        let twinsCSS = CSSSnippet.make(twins, options: SnippetOptions())
        #expect(twinsCSS.contains("--ink: ") && twinsCSS.contains("--color-2: "))
        #expect(SwiftSnippet.make(twins, options: SnippetOptions()).declarations.components(separatedBy: "static let ink").count == 2)
    }

    // MARK: Round trips

    @Test func svgSnippetsReimportAndRenderLikeTheObject() throws {
        // Both sides go through the PDF writer, which draws the SVG's embedded bitmaps (the
        // effects the SVG writer rasterized) from the imported scene's assets.
        func render(_ scene: ExportScene) throws -> CGImage {
            PDFTests.rasterize(try PDFExporter().data(scene: scene, options: PDFOptions()).data, scale: 2)
        }
        for (name, object, _) in Self.corpus where name != "pattern" {
            let svg = SVGSnippet.make(object)
            let imported = try SVGImporter().convert(Data(svg.utf8), name: "\(name).svg", format: .svg, options: SVGImportOptions().values, context: ImportContext())
            let a = try render(object.scene), b = try render(imported.exportScene())
            // Glyph edges anti-alias differently once text is outlines: a looser bound for text.
            let limit = object.shape == .text ? 0.1 : 0.02
            let difference = Corpus.difference(a, b, tolerance: 40)
            if difference >= limit { Corpus.dump(a, "snippet-\(name)-original"); Corpus.dump(b, "snippet-\(name)-svg") }
            #expect(difference < limit, "\(name): \(difference)")
        }
    }

    @Test func swiftSnippetsCompileAndRender() throws {
        let swiftc = "/usr/bin/swiftc"
        guard FileManager.default.isExecutableFile(atPath: swiftc) else { return }
        let folder = Corpus.directory()
        var source = "import AppKit\nimport SwiftUI\n\n"
        var calls: [String] = []
        for (index, entry) in Self.corpus.enumerated() {
            let code = SwiftSnippet.make(entry.object, options: SnippetOptions(notation: index % 2 == 0 ? .hex : .displayP3))
            // Each object's Color extension stands alone, so one file holds them all.
            source += code.declarations + "\n\n"
            source += "@MainActor @ViewBuilder func view\(index)() -> some View {\n\(code.view)\n}\n\n"
            if entry.renders { calls.append("save(view\(index)(), \"\(folder.path)/\(index).png\")") }
        }
        source += """
        @MainActor func save<V: View>(_ view: V, _ path: String) {
            let renderer = ImageRenderer(content: view)
            renderer.scale = 2
            let image = renderer.cgImage!
            let rep = NSBitmapImageRep(cgImage: image)
            try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: path))
        }

        MainActor.assumeIsolated {
        \(calls.map { "    " + $0 }.joined(separator: "\n"))
        }

        """
        let file = folder.appendingPathComponent("main.swift")
        try source.write(to: file, atomically: true, encoding: .utf8)
        let executable = folder.appendingPathComponent("snippets")
        let compile = try Self.run(swiftc, ["-swift-version", "5", file.path, "-o", executable.path])
        #expect(compile.status == 0, "\(compile.output)")
        guard compile.status == 0 else { return }
        let run = try Self.run(executable.path, [])
        #expect(run.status == 0, "\(run.output)")
        for (index, entry) in Self.corpus.enumerated() where entry.renders {
            let data = try Data(contentsOf: folder.appendingPathComponent("\(index).png"))
            let swiftUI = try #require(CGImageSourceCreateWithData(data as CFData, nil).flatMap { CGImageSourceCreateImageAtIndex($0, 0, nil) })
            let png = PNGSnippet.make(entry.object, scale: 2)
            let ours = try #require(CGImageSourceCreateWithData(png as CFData, nil).flatMap { CGImageSourceCreateImageAtIndex($0, 0, nil) })
            let difference = Corpus.difference(swiftUI, ours, tolerance: 24)
            if difference >= 0.03 { Corpus.dump(swiftUI, "snippet-swiftui-\(entry.name)"); Corpus.dump(ours, "snippet-png-\(entry.name)") }
            #expect(difference < 0.03, "\(entry.name): \(difference)")
        }
    }

    static func run(_ path: String, _ arguments: [String]) throws -> (status: Int32, output: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        try process.run()
        let output = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (process.terminationStatus, String(decoding: output, as: UTF8.self))
    }

    // MARK: Colours

    /// ColorSync's own conversion of one colour between two profiles (WTColor's `Converter`,
    /// which runs a `ColorSyncTransform` directly rather than through Core Graphics).
    static func colorSync(_ values: [Double], from source: WTColor.ProfileRef, to destination: WTColor.ProfileRef) throws -> [Double] {
        let transform = try #require(WTColor.Converter.shared.transform(from: source, to: destination))
        return transform.convert(values).map { min(max($0, 0), 1) }
    }

    @Test func colorsAgreeWithColorSync() throws {
        let colors = SnippetColors()
        let registry = WTColor.ProfileRegistry.shared
        let samples: [(Color, [Double], WTColor.ProfileRef)] = [
            (Color(displayP3Red: 0.9, green: 0.3, blue: 0.2), [0.9, 0.3, 0.2], registry.displayP3),
            (Color(displayP3Red: 0.2, green: 0.6, blue: 0.4), [0.2, 0.6, 0.4], registry.displayP3),
            (Color(red: 0.1, green: 0.5, blue: 0.9), [0.1, 0.5, 0.9], registry.sRGB),
        ]
        for (color, values, profile) in samples {
            let expected = try Self.colorSync(values, from: profile, to: registry.sRGB)
            let ours = colors.srgb(color)
            for (a, b) in zip([ours.x, ours.y, ours.z], expected) { #expect(abs(a - b) * 255 <= 0.5, "\(color): \(a) vs \(b)") }
            let expectedP3 = try Self.colorSync(values, from: profile, to: registry.displayP3)
            let p3 = colors.displayP3(color)
            for (a, b) in zip([p3.x, p3.y, p3.z], expectedP3) { #expect(abs(a - b) * 255 <= 0.5, "\(color): \(a) vs \(b)") }
        }
        #expect(colors.format(Color(red: 0.902, green: 0.224, blue: 0.275), .hex) == "#E63946")
        #expect(colors.format(Color(red: 0.902, green: 0.224, blue: 0.275), .rgb) == "rgb(230 57 70)")
        #expect(colors.format(Color(red: 1, green: 0, blue: 0, alpha: 0.5), .rgb) == "rgb(255 0 0 / 50%)")
        #expect(colors.format(Color(red: 1, green: 1, blue: 1), .displayP3) == "color(display-p3 1 1 1)")
        #expect(colors.format(Color(red: 1, green: 1, blue: 1), .oklch) == "oklch(100% 0 0)")
        // A CMYK colour reports its own inks; others convert through the profile.
        #expect(colors.format(Color(cyan: 0, magenta: 0.75, yellow: 0.7, black: 0.1), .cmyk) == "device-cmyk(0% 75% 70% 10%)")
        #expect(colors.format(.white, .cmyk).hasPrefix("device-cmyk(0% 0% 0% 0%"))
    }

    @Test func oklchRoundTripsToSRGB() throws {
        let colors = SnippetColors()
        var checked = 0
        for r in stride(from: 0.0, through: 1, by: 0.125) {
            for g in stride(from: 0.0, through: 1, by: 0.25) {
                for b in stride(from: 0.0, through: 1, by: 0.25) {
                    let color = Color(red: r, green: g, blue: b)
                    let text = colors.format(color, .oklch)
                    let lch = try #require(SnippetColors.parseOKLCH(text))
                    let back = Color(oklchL: lch.x, chroma: lch.y, hue: lch.z).srgb
                    #expect(abs(back.x - r) < 0.001 && abs(back.y - g) < 0.001 && abs(back.z - b) < 0.001, "\(text)")
                    checked += 1
                }
            }
        }
        #expect(checked == 225)
        #expect(SnippetColors.parseOKLCH("oklch(50% 0.1 30 / 50%)") == SIMD3(0.5, 0.1, 30))
    }

    // MARK: The Inspect panel's sections (COLLAB-037's rest)

    @Test func theReadoutListsColorsStrokeFillsEffectsTypographyAndText() throws {
        let corpus = Dictionary(uniqueKeysWithValues: Self.corpus.map { ($0.name, $0.object) })
        let options = SnippetOptions(notation: .hex, unit: .points, scale: 1)
        let card = SnippetReadout(try #require(corpus["stroked"]), options: options)
        #expect(card.colors.count >= 3 && card.colors.contains { $0.name == "1st blue" })
        #expect(card.stroke.map(\.label) == ["Width", "Cap", "Join", "Dash", "Color"])
        #expect(card.stroke[1].value == "Round" && card.stroke[2].value == "Bevel" && card.stroke[3].value != "Solid")
        #expect(card.fills.map(\.label) == ["Fill 1"] && card.effects.map(\.label) == ["Drop shadow", "Inner glow"])
        #expect(card.effects[0].value.contains("offset") && card.typography.isEmpty && card.text == nil)
        let pill = SnippetReadout(try #require(corpus["rounded"]), options: options)
        #expect(pill.fills.first?.value.hasPrefix("Linear gradient:") == true && pill.stroke.isEmpty)
        let hatch = SnippetReadout(try #require(corpus["pattern"]), options: options)
        #expect(hatch.fills.map(\.value).last == "Pattern" && hatch.effects.first?.label == "Blur")
        let leaf = SnippetReadout(try #require(corpus["path"]), options: options)
        #expect(leaf.stroke.contains { $0.label == "Miter limit" })
        let headline = SnippetReadout(try #require(corpus["text"]), options: options)
        #expect(headline.text == "Bold \"quoted\"\nplain" && headline.typography.count == 2)
        #expect(headline.typography[0].contains(SnippetReadout.Row("Font", "Helvetica")) && headline.typography[0].contains { $0.label == "Leading" })
        #expect(headline.typography[1].first { $0.label == "Style" }?.value.hasSuffix("Italic") == true)
        // Names and paints the panel spells out.
        #expect(SnippetReadout.cap(StrokeStyle(width: 1, cap: .butt)) == "Butt" && SnippetReadout.cap(StrokeStyle(width: 1, cap: .square)) == "Square")
        #expect(SnippetReadout.join(StrokeStyle(width: 1, join: .miter)) == "Miter" && SnippetReadout.join(StrokeStyle(width: 1, join: .round)) == "Round")
        let kinds: [Paint] = [.none, .custom(CustomFill(pattern: .bricks)), .textured(TexturedFill(texture: .oak, color: .black)),
                              .tiled(TiledFill(tile: [Corpus.path(Corpus.rect(0, 0, 2, 2), [Corpus.fill(.solid(.black))])])), .lens(LensFill(type: .invert))]
        for paint in kinds {
            #expect(!SnippetReadout.describe(paint) { _ in "" }.isEmpty)
        }
        #expect(SnippetReadout.title(.bevelEmboss(LiveEffect.BevelEmboss())) == "Bevel emboss")
        #expect(SnippetReadout.style(weight: 400, italic: true, postScriptName: "X") == "Italic" && SnippetReadout.style(weight: 950, italic: false, postScriptName: "X-Heavy") == "Black")
        #expect(SnippetReadout.style(weight: 1200, italic: false, postScriptName: "X-Odd") == "X-Odd")
        // Arrowheads read out on a stroke that has them.
        let arrow = Corpus.stroke(.solid(.black), width: 1, end: Arrowhead(name: "Triangle", shape: DisplayPath()))
        let line = SnippetReadout(SnippetObject(shape: .path, item: Corpus.path(Corpus.rect(0, 0, 10, 10), [arrow])), options: options)
        #expect(line.stroke.contains(SnippetReadout.Row("Arrowheads", "None – Triangle")))
        // Any other effect reads by its name; a run without glyphs or leading reads what it has.
        let embossed = SnippetReadout(SnippetObject(shape: .rectangle, item: Corpus.path(Corpus.rect(0, 0, 10, 10), [Corpus.fill(.solid(.white))],
                                                                                         effects: [EffectElement(.bevelEmboss(LiveEffect.BevelEmboss()))])), options: options)
        #expect(embossed.effects == [SnippetReadout.Row("Bevel emboss", "")])
        let bare = SnippetReadout(SnippetObject(shape: .text, item: .text(TextRunItem(text: "x", origin: .zero, bounds: Rect(x: 0, y: 0, width: 5, height: 5)))),
                                  options: options)
        #expect(bare.typography.first?.map(\.label) == ["Tracking", "Color"] && bare.text == "x")
    }
}
