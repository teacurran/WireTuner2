import Foundation
import Testing
import WTCRDT
import WTGeometry
import WTInterchange
@testable import WTModel
import WTProto
import WTRender
import struct WTGeometry.AffineTransform
import struct WTRender.StrokeStyle
import enum WTRender.LineCap
import enum WTRender.LineJoin

/// Imported scenes and their placement (import-formats.adoc, "Imported scene to document").
enum ImportFixture {
    static let png = ImportedBlob(data: Data([0x89, 0x50, 0x4E, 0x47, 1, 2, 3]), uti: "public.png")
    static let eps = ImportedBlob(data: Data("%!PS-Adobe-3.0 EPSF-3.0\n".utf8), uti: "com.adobe.encapsulated-postscript")
    static let svg = ImportedBlob(data: Data("<svg/>".utf8), uti: "public.svg-image")
    static let poster = ImportedBlob(data: Data([0x89, 0x50, 0x4E, 0x47, 9]), uti: "public.png")

    static func square(_ x: Double, fill: ImportedPaint = .solid(Color(red: 1, green: 0, blue: 0)), stroke: ImportedStroke? = nil,
                       opacity: Double = 1, name: String? = nil, url: String? = nil) -> ImportedPath {
        ImportedPath(contours: [ImportedContour(start: Point(x: x, y: 0), segments: [
            .line(to: Point(x: x + 10, y: 0)), .cubic(control1: Point(x: x + 12, y: 3), control2: Point(x: x + 12, y: 7), to: Point(x: x + 10, y: 10)),
            .line(to: Point(x: x, y: 10)), .line(to: Point(x: x, y: 0)),
        ], closed: true)], fill: fill, fillRule: .evenOdd, stroke: stroke, opacity: opacity, name: name, url: url)
    }

    static func pixels(_ blob: ImportedBlob = png) -> ImportedPixels {
        ImportedPixels(blob: blob, width: 300, height: 150, mode: .rgb, bitsPerChannel: 8, hasAlpha: true)
    }

    static var vector: ImportedScene {
        let gradient = Gradient(kind: .radial, behavior: .reflect, repeatCount: 2, axis: Gradient.Axis(start: Point(x: 0, y: 0), end: Point(x: 5, y: 0), end2: Point(x: 0, y: 5)),
                                stops: [Gradient.Stop(offset: 0, color: .white), Gradient.Stop(offset: 1, color: .black)])
        let clipped = ImportedGroup(children: [.path(square(0))], clip: square(2), opacity: 0.25, name: "Clip")
        let text = ImportedText(runs: [
            ImportedTextRun(text: "Hi", fontName: "Helvetica-Bold", fontSize: 12, fill: .solid(.black), origin: Point(x: 5, y: 20)),
            ImportedTextRun(text: "there", fontName: "NoSuchFont-Regular", fontSize: 0, fill: .none, origin: Point(x: 5, y: 34)),
            ImportedTextRun(text: "", fontName: "Helvetica", fontSize: 9, origin: Point(x: 5, y: 34)),
        ], name: "Words")
        let image = ImportedImage(pixels: pixels(), dpiX: 144, dpiY: 0, transform: .translation(x: 1, y: 2), name: nil)
        return ImportedScene(kind: .vector, name: "art.svg", bounds: Rect(x: -10, y: -10, width: 100, height: 50), nodes: [
            .path(square(0, stroke: ImportedStroke(paint: .solid(.black), style: StrokeStyle(width: 2, cap: .round, join: .bevel, miterLimit: 80, dash: [3, 1])),
                         opacity: 0.5, name: "Square", url: "https://example.com")),
            .path(square(20, fill: .gradient(gradient), stroke: ImportedStroke(paint: .gradient(gradient)))),
            .path(square(40, fill: .none, stroke: ImportedStroke(paint: .none))),
            .group(clipped),
            .text(text),
            .image(image),
        ], notes: ["Filters were left out."])
    }

    static var bitmap: ImportedScene {
        ImportedScene(kind: .bitmap, name: "photo.png", bounds: Rect(x: 0, y: 0, width: 300, height: 150),
                      nodes: [.image(ImportedImage(pixels: pixels(), dpiX: 72, dpiY: 72))])
    }

    static func placed(_ kind: ImportedPlacedFile.Kind, blob: ImportedBlob, name: String) -> ImportedScene {
        ImportedScene(kind: .placed, name: name, bounds: Rect(x: 10, y: 20, width: 200, height: 100),
                      nodes: [.placed(ImportedPlacedFile(kind: kind, blob: blob, bounds: Rect(x: 10, y: 20, width: 200, height: 100)))])
    }

    static let link = ImportLink(displayName: "photo.png", path: "/Users/me/photo.png", device: "Studio", modified: Date(timeIntervalSince1970: 1_700_000_000))
}

@Suite struct ImportMappingTests {
    /// The single node the change placed on a layer.
    static func placed(_ change: Wiretuner_Doc_V1_Change?, _ replica: Replica) throws -> OpID {
        let change = try #require(change)
        return try #require(PlaceImportedScene.placedRoot(of: change, in: replica.state))
    }

    @Test func aVectorImportIsOneGroupNamedAfterTheFileOnTheCurrentLayer() throws {
        var a = Replica(0xA)
        let layers = try LayerFixture.layers(["Back", "Front"], on: &a)
        let command = PlaceImportedScene(ImportFixture.vector, placement: .at(Point(x: 100, y: 200)), layer: layers[0])
        #expect(command.label == "Import art.svg")
        let change = try a.perform(command)
        let group = try Self.placed(change, a)
        #expect(a.state.liveChildren(layers[0]) == [group])
        let props = a.state.props(group).group
        #expect(props.common.name == "art.svg")
        #expect(props.kind == .group)
        #expect(props.common.transform.tx == 110 && props.common.transform.ty == 210)
        let children = a.state.liveChildren(group)
        #expect(children.count == 6)

        let square = a.state.props(children[0]).path
        #expect(square.common.name == "Square" && square.common.url == "https://example.com")
        #expect(square.evenOdd)
        #expect(square.contours.count == 1 && square.contours[0].closed)
        #expect(square.contours[0].points.count == 4, "the closing point is not repeated")
        #expect(square.contours[0].points.map(\.kind).contains(.corner))
        #expect(square.appearance.fills.first?.settings.basic.color.inline.rgb.r == 1)
        let stroke = try #require(square.appearance.strokes.first).settings.basic
        #expect(stroke.width == 2 && stroke.cap == .round && stroke.join == .bevel && stroke.miterLimit == 57)
        #expect(stroke.dash.lengths == [3, 1])
        #expect(square.appearance.effects.first?.settings.transparency.amount == 50)

        let gradient = a.state.props(children[1]).path.appearance
        #expect(gradient.fills.first?.settings.kind == .gradient)
        let fill = try #require(gradient.fills.first).settings.gradient
        #expect(fill.type == .radial && fill.behavior == .reflect && fill.repeatCount == 2 && fill.axis.end2.y == 5)
        #expect(fill.stops.count == 2)
        #expect(gradient.strokes.first?.settings.basic.color.inline.rgb.r == 1, "a gradient stroke paints its first stop")

        let unpainted = a.state.props(children[2]).path.appearance
        #expect(unpainted.fills.isEmpty && unpainted.strokes.isEmpty && unpainted.effects.isEmpty)

        let clip = a.state.props(children[3]).group
        #expect(clip.kind == .clip && clip.common.name == "Clip")
        #expect(clip.appearance.effects.first?.settings.transparency.amount == 75)
        let clipChildren = a.state.liveChildren(children[3])
        #expect(clipChildren.count == 2)
        #expect(OpID(clip.clipPath.id) == clipChildren[0])
        #expect(a.state.props(clipChildren[0]).path.appearance.fills.isEmpty)

        let text = children[4]
        #expect(a.state.props(text).text.common.name == "Words")
        #expect(a.state.props(text).text.block.autoWidth)
        #expect(a.state.props(text).text.common.transform.ty == 20)
        let sequence = try #require(a.state.store.text(text, RegisterPath([130, 2])))
        #expect(sequence.string == "Hi\nthere")
        // Hi: family, style, size, fill; there: family only.
        #expect(sequence.marks.count == 5)

        let image = a.state.props(children[5]).image
        #expect(image.dpiX == 144 && image.dpiY == 72)
        #expect(!image.hasSource, "an image inside a vector file has no link record")
        #expect(image.pixels.format == "public.png" && image.pixels.pixelWidth == 300 && image.pixels.hasAlpha_p)
        #expect(image.common.transform.tx == 1)
    }

    @Test func aBitmapFromAFileIsPlacedWithItsLinkRecord() throws {
        var a = Replica(0xA)
        let layer = try LayerFixture.layers(["One"], on: &a)[0]
        let command = PlaceImportedScene(ImportFixture.bitmap, placement: .fit(Rect(x: 0, y: 0, width: 600, height: 600), fillWidth: false),
                                         link: ImportFixture.link)
        #expect(command.label == "Place photo.png")
        let change = try a.perform(command)
        let image = try Self.placed(change, a)
        #expect(a.state.liveChildren(layer) == [image])
        let props = a.state.props(image).image
        #expect(props.common.name == "photo.png" && props.sourceName == "photo.png")
        #expect(props.pixels.blobSha256 == ImportFixture.png.sha256)
        #expect(props.pixels.mode == .rgb && props.pixels.bitsPerChannel == 8)
        // 300 × 150 fitted into 600 × 600: scale 2, centred vertically.
        #expect(props.common.transform.a == 2 && props.common.transform.ty == 150)
        let asset = OpID(props.source.id)
        #expect(a.state.store.placement(asset)?.parent == WellKnown.assets)
        let record = a.state.props(asset).asset
        #expect(record.sha256 == ImportFixture.png.sha256 && record.byteSize == 7 && record.mediaType == "image/png")
        #expect(record.link.kind == .localFile && record.link.path == "/Users/me/photo.png" && record.link.device == "Studio")
        #expect(record.link.sourceModifiedMs == 1_700_000_000_000)
    }

    @Test func placementsMapTheBoundsOntoThePasteboard() {
        let bounds = Rect(x: 10, y: 10, width: 100, height: 50)
        let natural = ImportPlacement.at(Point(x: 0, y: 0)).transform(for: bounds)
        #expect(natural.apply(Point(x: 10, y: 10)) == Point(x: 0, y: 0))
        let fitted = ImportPlacement.fit(Rect(x: 0, y: 0, width: 50, height: 50), fillWidth: false).transform(for: bounds)
        #expect(fitted.apply(Point(x: 110, y: 60)) == Point(x: 50, y: 37.5))
        let wide = ImportPlacement.fit(Rect(x: 0, y: 0, width: 400, height: 10), fillWidth: true).transform(for: bounds)
        #expect(wide.apply(Point(x: 110, y: 60)) == Point(x: 400, y: 200))
        let empty = ImportPlacement.fit(Rect(x: 5, y: 6, width: 40, height: 40), fillWidth: false).transform(for: Rect(x: 1, y: 1, width: 0, height: 0))
        #expect(empty.apply(Point(x: 1, y: 1)) == Point(x: 5, y: 6))
    }

    @Test func placedFilesAndAnimationsKeepTheirBlobsInAssets() throws {
        var a = Replica(0xA)
        _ = try LayerFixture.layers(["One"], on: &a)
        let eps = try Self.placed(a.perform(PlaceImportedScene(ImportFixture.placed(.eps, blob: ImportFixture.eps, name: "logo.eps"),
                                                                 placement: .at(Point(x: 0, y: 0)), link: ImportLink(fileURL: URL(fileURLWithPath: "/tmp/logo.eps")))), a)
        let file = a.state.props(eps).placedFile
        #expect(file.common.name == "logo.eps" && file.content.format == .eps && file.content.sourceName == "logo.eps")
        #expect(file.content.bounds.width == 200 && file.content.blobSha256 == ImportFixture.eps.sha256)
        #expect(a.state.props(OpID(file.source.id)).asset.link.displayName == "logo.eps")

        let pasted = try Self.placed(a.perform(PlaceImportedScene(ImportFixture.placed(.eps, blob: ImportFixture.eps, name: "clip.eps"),
                                                                    placement: .at(Point(x: 0, y: 0)))), a)
        #expect(!a.state.props(pasted).placedFile.hasSource)

        let animation = ImportedPlacedFile.Kind.svgAnimation(css: true, smil: false, script: true, durationMs: 1_500)
        let command = PlaceImportedScene(ImportFixture.placed(animation, blob: ImportFixture.svg, name: "wave.svg"), placement: .at(Point(x: 50, y: 50)),
                                         poster: ImportedPoster(blob: ImportFixture.poster, timeMs: 0))
        #expect(command.label == "Place wave.svg")
        let svg = try Self.placed(a.perform(command), a)
        let props = a.state.props(svg).svgAnimation
        #expect(props.naturalSize.width == 200 && props.naturalSize.height == 100 && props.durationMs == 1_500)
        #expect(props.kinds.css && !props.kinds.smil && props.kinds.script)
        #expect(props.common.transform.tx == 50 && props.common.transform.ty == 50, "the view box's origin maps to the click")
        let asset = a.state.props(OpID(props.asset.id)).asset
        #expect(asset.sha256 == ImportFixture.svg.sha256 && asset.link.kind == .embedded && asset.common.name == "wave.svg")
        #expect(a.state.props(OpID(props.poster.id)).asset.common.name == "wave.svg poster")

        let bare = try Self.placed(a.perform(PlaceImportedScene(ImportFixture.placed(animation, blob: ImportFixture.svg, name: "b.svg"),
                                                                  placement: .at(Point(x: 0, y: 0)))), a)
        #expect(!a.state.props(bare).svgAnimation.hasPoster)
    }

    @Test func namedLayersReceiveTheirArtworkWithThePlacement() throws {
        var a = Replica(0xA)
        let layers = try LayerFixture.layers(["Art", "Notes"], on: &a)
        try a.perform(PlaceImportedScene(ImportFixture.bitmap, placement: .at(Point(x: 0, y: 0)), layer: layers[1]))
        var scene = ImportFixture.vector
        scene.layers = [
            ImportedLayer(name: "Notes", nodes: [.path(ImportFixture.square(0))]),
            ImportedLayer(name: "URLs", nodes: [.path(ImportFixture.square(1, url: "https://a")), .path(ImportFixture.square(2))]),
            ImportedLayer(name: "Empty", nodes: []),
        ]
        try a.perform(PlaceImportedScene(scene, placement: .at(Point(x: 10, y: 10)), layer: layers[0]))
        let order = LayerOrder(a.state)
        #expect(order.layers.map(\.name) == ["Art", "Notes", "URLs"])
        let notes = a.state.liveChildren(layers[1])
        #expect(notes.count == 2, "above what the layer held")
        #expect(a.state.props(notes[1]).path.common.transform.tx == 20)
        #expect(a.state.liveChildren(order.layers[2].id).count == 2)
    }

    @Test func lockedOrHiddenLayersFallBackToTheNearestEditableLayerAbove() throws {
        var a = Replica(0xA)
        #expect(ImportTarget.resolve(preferred: nil, in: a.state) == ImportTarget(layer: nil, fellBack: false))
        let first = try a.perform(PlaceImportedScene(ImportFixture.bitmap, placement: .at(Point(x: 0, y: 0))))
        #expect(LayerOrder(a.state).layers.map(\.name) == ["Foreground"])
        #expect(try Self.placed(first, a) != .zero)

        var b = Replica(0xB)
        let layers = try LayerFixture.layers(["Bottom", "Locked", "Hidden", "Top"], on: &b)
        try b.perform(SetLayerFlag([layers[1]], .locked, true))
        try b.perform(SetLayerFlag([layers[2]], .visible, false))
        #expect(ImportTarget.resolve(preferred: layers[0], in: b.state) == ImportTarget(layer: layers[0], fellBack: false))
        #expect(ImportTarget.resolve(preferred: layers[1], in: b.state) == ImportTarget(layer: layers[3], fellBack: true))
        #expect(ImportTarget.resolve(preferred: .wellKnown(99), in: b.state) == ImportTarget(layer: layers[3], fellBack: false))
        try b.perform(SetLayerFlag([layers[3]], .locked, true))
        #expect(ImportTarget.resolve(preferred: layers[2], in: b.state) == ImportTarget(layer: nil, fellBack: true))
        let change = try b.perform(PlaceImportedScene(ImportFixture.bitmap, placement: .at(Point(x: 0, y: 0)), layer: layers[2]))
        let image = try Self.placed(change, b)
        let order = LayerOrder(b.state)
        #expect(order.layers.last?.name == "Imported Artwork")
        #expect(order.layer(of: image, in: b.state) == order.layers.last?.id)
    }

    @Test func aLayerTransformIsUndoneForTheTopNode() throws {
        var a = Replica(0xA)
        var props = Wiretuner_Doc_V1_NodeProps()
        props.layer.common.name = "Moved"
        props.layer.visible = true
        props.layer.printing = true
        props.layer.common.transform = PathEditing.proto(.translation(x: 100, y: 0))
        let layer = try a.perform(OpsCommand("Layer", ops: [Ops.create(parent: WellKnown.layers, position: [0x80], props: props)]))!.createdNodes[0]
        let image = try Self.placed(a.perform(PlaceImportedScene(ImportFixture.bitmap, placement: .at(Point(x: 150, y: 0)), layer: layer)), a)
        #expect(a.state.props(image).image.common.transform.tx == 50)
    }

    @Test func coloursKeepTheirSpace() {
        let p3 = ImportMapping.color(Color(displayP3Red: 1, green: 0.5, blue: 2))
        #expect(p3.space == .displayP3 && p3.rgb.b == 1)
        #expect(ImportMapping.color(Color(red: -1, green: 0, blue: 0)).rgb.r == 0)
        let lab = ImportMapping.color(Color(labL: 50, a: 10, b: -10))
        #expect(lab.space == .lab && lab.lab.l == 50 && lab.lab.b == -10)
        #expect(ImportMapping.color(Color(oklabL: 0.5, a: 0.1, b: 0)).space == .oklab)
        let cmyk = ImportMapping.color(Color(cyan: 0.1, magenta: 0.2, yellow: 0.3, black: 0.4))
        #expect(cmyk.cmyk.c == 0.1 && cmyk.cmyk.k == 0.4)
        for kind in Gradient.Kind.allCases {
            for behavior in Gradient.Behavior.allCases {
                let value = ImportMapping.gradient(Gradient(kind: kind, behavior: behavior, repeatCount: 0, stops: []))
                #expect(value.repeatCount == 1 && !value.hasAxis)
            }
        }
        for cap in [LineCap.butt, .round, .square] {
            for join in [LineJoin.miter, .round, .bevel] {
                #expect(ImportMapping.stroke(ImportedStroke(paint: .solid(.black), style: StrokeStyle(width: -1, cap: cap, join: join)))?.settings.basic.width == 0)
            }
        }
        #expect(ImportMapping.transparency(1) == nil)
        #expect(ImportMapping.transparency(-1)?.settings.transparency.amount == 100)
        for mode in ImportedColorMode.allCases {
            #expect(ImportMapping.mode(mode) != .unspecified)
        }
    }

    @Test func fontsResolveToFamiliesOrKeepTheirName() {
        let bold = ImportMapping.font("Helvetica-Bold")
        #expect(bold.family == "Helvetica" && bold.style == "Bold")
        #expect(ImportMapping.font("NoSuchFont-Regular") == ("NoSuchFont-Regular", ""))
    }

    @Test func vectorFilesKeepNoLinkAndShareAnimationAssets() throws {
        var a = Replica(0xA)
        let layer = try LayerFixture.layers(["One"], on: &a)[0]
        let animation = ImportedPlacedFile(kind: .svgAnimation(css: true, smil: false, script: false, durationMs: 0), blob: ImportFixture.svg,
                                           bounds: Rect(x: 0, y: 0, width: 10, height: 10))
        let smooth = ImportedContour(start: Point(x: 0, y: 0), segments: [
            .cubic(control1: Point(x: 0, y: 5), control2: Point(x: 5, y: 10), to: Point(x: 10, y: 10)),
            .cubic(control1: Point(x: 15, y: 10), control2: Point(x: 20, y: 5), to: Point(x: 20, y: 0)),
        ])
        let scene = ImportedScene(kind: .vector, name: "mixed.pdf", bounds: Rect(x: 0, y: 0, width: 50, height: 50), nodes: [
            .placed(animation), .placed(animation), .text(ImportedText(runs: [])),
            .image(ImportedImage(pixels: ImportFixture.pixels())), .path(ImportedPath(contours: [smooth])),
        ])
        let group = try Self.placed(a.perform(PlaceImportedScene(scene, placement: .at(Point(x: 0, y: 0)), layer: layer, link: ImportFixture.link)), a)
        let children = a.state.liveChildren(group)
        #expect(a.state.props(children[0]).svgAnimation.asset == a.state.props(children[1]).svgAnimation.asset)
        #expect(a.state.liveChildren(WellKnown.assets).count == 1)
        #expect(a.state.store.text(children[2], RegisterPath([130, 2])) == nil)
        #expect(!a.state.props(children[3]).image.hasSource, "no link record inside a vector file")
        #expect(a.state.props(children[4]).path.contours[0].points.map(\.kind) == [.corner, .curve, .corner])
    }

    @Test func concurrentImportsOntoOneLayerConverge() throws {
        var pair = Pair()
        let layer = try LayerFixture.layers(["Shared"], on: &pair.a)[0]
        pair.sync()
        try pair.a.perform(PlaceImportedScene(ImportFixture.vector, placement: .at(Point(x: 0, y: 0)), layer: layer))
        var other = ImportFixture.vector
        other.name = "other.pdf"
        try pair.b.perform(PlaceImportedScene(other, placement: .at(Point(x: 5, y: 5)), layer: layer))
        pair.sync()
        #expect(pair.a.state.stateHash == pair.b.state.stateHash)
        let names = pair.a.state.liveChildren(layer).map { pair.a.state.props($0).group.common.name }
        #expect(Set(names) == ["art.svg", "other.pdf"])
        #expect(names == pair.b.state.liveChildren(layer).map { pair.b.state.props($0).group.common.name })
    }
}
