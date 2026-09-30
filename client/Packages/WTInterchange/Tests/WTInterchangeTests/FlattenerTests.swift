// IO-017: the flattener, vector capture, the opaque compositor and the flat renderer.

import CoreGraphics
import Foundation
import Testing
import WTGeometry
@testable import WTInterchange
import WTRender
import struct WTRender.StrokeStyle

@Suite struct FlattenerTests {
    static func flatten(_ items: [DisplayItem], target: FlattenTarget = .svg, nodes: [NodeID?] = [], scene: ExportScene? = nil, outline: Bool = false) -> (page: FlatPage, report: FlattenReport) {
        let page = Corpus.page(items, nodes: nodes)
        return Flattener(target: target, rasterResolution: 144, outlineText: outline).flatten(page, scene: scene ?? Corpus.scene([page]))
    }

    /// Every node, depth first.
    static func all(_ nodes: [FlatNode]) -> [FlatNode] {
        nodes.flatMap { node -> [FlatNode] in
            if case .group(let group) = node {
                return [node] + all(group.children)
            }
            return [node]
        }
    }

    static func count(_ nodes: [FlatNode], _ predicate: (FlatNode) -> Bool) -> Int {
        all(nodes).filter(predicate).count
    }

    static func isImage(_ node: FlatNode) -> Bool {
        if case .image = node { return true }
        return false
    }

    @Test func basicsStayVector() {
        let flat = Self.flatten(Corpus.basics).page
        #expect(Self.count(flat.nodes, Self.isImage) == 0)
        var strokes = 0, fills = 0
        for node in Self.all(flat.nodes) {
            if case .path(let path) = node {
                if case .stroke = path.style { strokes += 1 } else { fills += 1 }
            }
        }
        #expect(strokes == 5)
        #expect(fills == 6)
    }

    @Test func transparencyBecomesGroups() {
        let flat = Self.flatten(Corpus.transparency).page
        let groups = Self.all(flat.nodes).compactMap { node -> FlatGroup? in
            if case .group(let group) = node { return group }
            return nil
        }
        #expect(groups.contains { $0.opacity == 0.6 })
        #expect(groups.contains { $0.clip != nil })
        #expect(groups.contains { abs($0.opacity - 0.6) < 1e-9 && $0.children.count == 2 })
        #expect(groups.contains { abs($0.opacity - 0.5) < 1e-9 && $0.children.count == 1 })
    }

    @Test func gradientsStayGradientsAndSampledPaintsRender() {
        let flat = Self.flatten(Corpus.gradients).page
        #expect(Self.count(flat.nodes, Self.isImage) == 0)
        let sampled = Self.flatten(Corpus.sampled)
        #expect(Self.count(sampled.page.nodes, Self.isImage) == 7)
        #expect(sampled.report.rasterized.count == 7)
        #expect(sampled.report.notes.count == 7)
        // Without gradient support even linear gradients render.
        let opaque = Self.flatten([Corpus.path(Corpus.rect(0, 0, 50, 50), [Corpus.fill(Corpus.gradient(.linear))])], target: [.transparency])
        #expect(Self.count(opaque.page.nodes, Self.isImage) == 1)
    }

    @Test func effectsAreKeptLiveExpandedOrRendered() {
        let result = Self.flatten(Corpus.effects)
        let groups = Self.all(result.page.nodes).compactMap { node -> FlatGroup? in
            if case .group(let group) = node { return group }
            return nil
        }
        #expect(groups.contains { $0.softMask != nil })
        #expect(groups.contains { if case .blur = $0.filter { return true } else { return false } })
        #expect(groups.contains { if case .dropShadow = $0.filter { return true } else { return false } })
        #expect(groups.contains { if case .glow = $0.filter { return true } else { return false } })
        #expect(Self.count(result.page.nodes, Self.isImage) == 3)
        #expect(result.report.expanded == 1)
        // PDF has no filters: blur, shadow and glow render too.
        let pdf = Self.flatten(Corpus.effects, target: .pdf)
        #expect(Self.count(pdf.page.nodes, Self.isImage) == 6)
        #expect(pdf.report.notes.contains("1 object with live effects expanded to paths"))
    }

    @Test func effectEdgeCases() {
        let square = Corpus.rect(10, 10, 40, 40)
        func effected(_ effects: [EffectElement], _ items: [AppearanceItem] = [Corpus.fill(.solid(Corpus.red))]) -> [FlatNode] {
            Self.flatten([Corpus.path(square, items, effects: effects)]).page.nodes
        }
        // No-op settings add nothing.
        let noOps: [LiveEffect] = [
            .blur(LiveEffect.Blur(radius: 0)), .shadow(LiveEffect.Shadow(opacity: 0)), .bevelEmboss(LiveEffect.BevelEmboss(width: 0)),
            .sharpen(LiveEffect.Sharpen(amount: 0)), .transparency(LiveEffect.Transparency(style: .feather, radius: 0)),
            .transparency(LiveEffect.Transparency(style: .basic, amount: 0)),
        ]
        for effect in noOps {
            let nodes = effected([EffectElement(effect)])
            #expect(nodes.count == 1)
            if case .path = nodes[0] {} else { Issue.record("expected a plain path for \(effect)") }
        }
        // Hidden, unsupported and dangling effects are skipped.
        let skipped = effected([EffectElement(.blur(LiveEffect.Blur(radius: 3)), hidden: true), EffectElement(.unsupported), EffectElement(.blur(LiveEffect.Blur(radius: 3)), target: .element(5))])
        #expect(skipped.count == 1)
        // Box blur and sharpening render.
        #expect(Self.isImage(effected([EffectElement(.blur(LiveEffect.Blur(style: .basic, radius: 3)))])[0]))
        // Sharpening lies inside the shape: rendered, clipped to the outline (FX-012).
        if case .group(let sharpened) = effected([EffectElement(.sharpen(LiveEffect.Sharpen(amount: 50)))])[0] {
            #expect(sharpened.clip != nil && Self.isImage(sharpened.children[0]))
        } else {
            Issue.record("expected a clipped group")
        }
        // A vector effect with a raster one renders.
        #expect(Self.isImage(effected([EffectElement(.ragged(LiveEffect.Ragged(size: 3, frequency: 5))), EffectElement(.blur(LiveEffect.Blur(radius: 2)))])[0]))
        // A single-stop gradient mask is Basic at the stop's luminance; no stops is opaque.
        let oneStop = effected([EffectElement(.transparency(LiveEffect.Transparency(style: .gradientMask, mask: Gradient(stops: [Gradient.Stop(offset: 0, color: .white)]))))])
        if case .group(let group) = oneStop[0] { #expect(group.opacity == 0) } else { Issue.record("expected a group") }
        let noStops = effected([EffectElement(.transparency(LiveEffect.Transparency(style: .gradientMask)))])
        if case .path = noStops[0] {} else { Issue.record("expected a plain path") }
        // Without soft masks a gradient mask renders.
        let masked = Self.flatten([Corpus.path(square, [Corpus.fill(.solid(Corpus.red))], effects: [EffectElement(.transparency(LiveEffect.Transparency(style: .gradientMask, mask: Gradient(.linear, from: .black, to: .white))))])], target: [.transparency, .strokes])
        #expect(Self.isImage(masked.page.nodes[0]))
        // An element-level raster effect the target cannot keep renders that element alone; the
        // fill stays vector (FX-012).
        let elementBlur = Self.flatten([Corpus.path(square, [Corpus.fill(.solid(Corpus.red)), Corpus.stroke(.solid(.black), width: 2)], effects: [EffectElement(.blur(LiveEffect.Blur(radius: 2)), target: .element(1))])], target: .pdf)
        #expect(elementBlur.page.nodes.count == 2 && !Self.isImage(elementBlur.page.nodes[0]) && Self.isImage(elementBlur.page.nodes[1]))
        // An inner glow has no filter.
        #expect(FlattenRun.filter(for: LiveEffect.Shadow(style: .innerGlow, opacity: 50)) == nil)
        // An effected item that paints nothing yields nothing.
        #expect(effected([EffectElement(.blur(LiveEffect.Blur(radius: 2)))], [Corpus.fill(.none)]).isEmpty)
    }

    @Test func strokesThatDeriveAreExpanded() {
        let result = Self.flatten(Corpus.derivedStrokes)
        #expect(Self.count(result.page.nodes, Self.isImage) == 0)
        #expect(result.report.expanded == 4)
        // A brush painted with a gradient cannot be captured and renders.
        let symbol = BrushSymbol(items: [.path(PathItem(path: Corpus.rect(0, -2, 6, 4), appearance: Appearance([Corpus.fill(Corpus.gradient(.linear))])))])
        let brush = Brush(mode: .paint, symbols: [symbol])
        let rendered = Self.flatten([Corpus.path(Corpus.wave(10, 10, 100, 30), [Corpus.stroke(.solid(.black), width: 1, kind: .brush(BrushStroke(brush: brush)))])])
        #expect(Self.isImage(rendered.page.nodes[0]))
        // None paints add nothing; a pattern stroke is expanded or rendered.
        #expect(Self.flatten([Corpus.path(Corpus.wave(0, 0, 10, 10), [Corpus.stroke(.none, width: 2)])]).page.nodes.isEmpty)
        let pattern = Self.flatten([Corpus.path(Corpus.wave(0, 0, 50, 20), [Corpus.stroke(.pattern(PatternPaint(bitmap: .checker, color: .black)), width: 4)])])
        #expect(Self.isImage(pattern.page.nodes[0]))
    }

    @Test func liveGroupsAndGroupEffects() {
        let result = Self.flatten(Corpus.liveGroup)
        #expect(result.report.expanded == 1)
        #expect(Self.count(result.page.nodes, Self.isImage) == 0)
        if case .group(let group) = result.page.nodes.last! {
            #expect(abs(group.opacity - 0.7) < 1e-9)
        } else {
            Issue.record("expected the group's transparency as a group")
        }
        // A group effect the target cannot keep expands the group (and renders it when needed).
        let blurred = Self.flatten([.group(GroupItem(children: [Corpus.path(Corpus.rect(10, 10, 30, 30), [Corpus.fill(.solid(Corpus.red))])], appearance: Appearance([], effects: [EffectElement(.blur(LiveEffect.Blur(radius: 2)))])))], target: .pdf)
        #expect(Self.isImage(blurred.page.nodes[0]))
    }

    @Test func textStaysTextUnlessOutlined() {
        let items = [Corpus.text("Hi"), .text(TextRunItem(text: "placeholder", origin: Point(x: 10, y: 90), bounds: Rect(x: 10, y: 78, width: 60, height: 14)))]
        let kept = Self.flatten(items)
        if case .text(let text) = kept.page.nodes[0] { #expect(text.text == "Hi") } else { Issue.record("expected text") }
        #expect(kept.page.nodes.count == 3)
        let outlined = Self.flatten(items, outline: true)
        if case .path = outlined.page.nodes[0] {} else { Issue.record("expected outlines") }
        #expect(outlined.report.outlinedRuns == 1)
        #expect(outlined.report.notes == ["1 text run converted to outlines"])
        let noText = Self.flatten([Corpus.text("A"), Corpus.text("B")], target: [.transparency])
        #expect(noText.report.notes == ["2 text runs converted to outlines"])
    }

    @Test func imagesUseAssetsOrPlaceholders() {
        let asset = ExportAsset(image: Corpus.image(), jpegData: Data([1, 2]))
        let items: [DisplayItem] = [.image(ImageItem(assetID: "a", rect: Rect(x: 0, y: 0, width: 40, height: 30))), .image(ImageItem(assetID: "missing", rect: Rect(x: 50, y: 0, width: 40, height: 30)))]
        let page = Corpus.page(items)
        let flat = Flattener(target: .svg).flatten(page, scene: Corpus.scene([page], assets: ["a": asset])).page
        #expect(flat.nodes.count == 3)
        if case .image(let image) = flat.nodes[0] { #expect(image.jpegData == Data([1, 2]) && !image.rasterized) } else { Issue.record("expected the asset") }
    }

    /// A 16 × 16 black grayscale image.
    static func blackGray() -> CGImage {
        let context = CGContext(data: nil, width: 16, height: 16, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.linearGray)!, bitmapInfo: CGImageAlphaInfo.none.rawValue)!
        context.setFillColor(gray: 0, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: 16, height: 16))
        return context.makeImage()!
    }

    @Test func imagesKeepTheirCropAndTreatment() throws {
        // IMG-004: what the canvas draws -- the crop clips, a gray image takes its tint -- and a
        // placed JPEG keeps its bytes only while untreated.
        let asset = ExportAsset(image: Self.blackGray(), jpegData: Data([1, 2]))
        let crop = Rect(x: 0.25, y: 0.25, width: 0.5, height: 0.5)
        let items: [DisplayItem] = [
            .image(ImageItem(assetID: "a", rect: Rect(x: 0, y: 0, width: 40, height: 40), crop: crop, mode: .grayscale)),
            .image(ImageItem(assetID: "a", rect: Rect(x: 50, y: 0, width: 40, height: 40), mode: .grayscale, tint: Corpus.red)),
            .image(ImageItem(assetID: "missing", rect: Rect(x: 100, y: 0, width: 40, height: 40), crop: crop)),
        ]
        let page = Corpus.page(items)
        let flat = Flattener(target: .svg).flatten(page, scene: Corpus.scene([page], assets: ["a": asset])).page
        guard case .group(let cropped) = flat.nodes[0], let clip = cropped.clip, case .image(let whole) = try #require(cropped.children.first) else {
            Issue.record("expected a clipped image: \(flat.nodes[0])")
            return
        }
        #expect(clip.path.controlBounds == Rect(x: 10, y: 10, width: 20, height: 20))
        #expect(whole.rect == Rect(x: 0, y: 0, width: 40, height: 40) && whole.jpegData == Data([1, 2]), "untreated: the JPEG's own bytes")
        guard case .image(let tinted) = flat.nodes[1] else {
            Issue.record("expected the tinted image")
            return
        }
        #expect(tinted.jpegData == nil)
        let pixel = Corpus.pixels(tinted.image).bytes
        #expect(pixel[0] > 200 && pixel[1] < 40 && pixel[2] < 40, "black takes the tint: \(pixel.prefix(4))")
        // The missing image's placeholder covers only what the crop shows.
        let placeholder = flat.nodes.dropFirst(2).compactMap { node -> Rect? in if case .path(let path) = node { return path.path.controlBounds } else { return nil } }
        #expect(placeholder.first == Rect(x: 110, y: 10, width: 20, height: 20))
    }

    @Test func nodesTagWhatTheyBecome() {
        let a = Corpus.node(1), b = Corpus.node(2), c = Corpus.node(3)
        let items: [DisplayItem] = [
            Corpus.path(Corpus.rect(0, 0, 10, 10), [Corpus.fill(.solid(.black))]),
            Corpus.path(Corpus.rect(20, 0, 10, 10), [Corpus.fill(.solid(.black)), Corpus.stroke(.solid(Corpus.red), width: 1)]),
            Corpus.path(Corpus.rect(40, 0, 10, 10), [Corpus.fill(.none)]),
        ]
        let flat = Self.flatten(items, nodes: [a, b, c]).page
        #expect(flat.nodes.count == 2)
        #expect(flat.nodes[0].node == a)
        if case .group(let group) = flat.nodes[1] {
            #expect(group.node == b && group.children.count == 2 && !group.isEffective)
        } else {
            Issue.record("expected a node group")
        }
        // Items outside the page are skipped.
        let outside = Self.flatten([Corpus.path(Corpus.rect(500, 500, 10, 10), [Corpus.fill(.solid(.black))])])
        #expect(outside.page.nodes.isEmpty)
    }

    @Test func lensesRenderWithTheirBackdrop() {
        let result = Self.flatten(Corpus.sampled)
        #expect(result.report.rasterized.last == "lens rendered at 144 ppi")
    }

    @Test func flatGradientsResolveLikeWTRender() throws {
        let bounds = Rect(x: 0, y: 0, width: 100, height: 50)
        #expect(FlatGradient(Gradient(stops: []), bounds: bounds) == nil)
        #expect(FlatGradient(Gradient(.cone, from: .black, to: .white), bounds: bounds) == nil)
        let auto = try #require(FlatGradient(Gradient(.linear, from: .black, to: .white, behavior: .autoSize, axis: Gradient.Axis(start: .zero, end: Point(x: 5, y: 5))), bounds: bounds))
        #expect(auto.shape == .axial(start: Point(x: 0, y: 25), end: Point(x: 100, y: 25)))
        let thin = try #require(FlatGradient(Gradient(.linear, from: .black, to: .white), bounds: Rect(x: 3, y: 0, width: 0, height: 10)))
        #expect(thin.shape == .axial(start: Point(x: 3, y: 5), end: Point(x: 4, y: 5)))
        let coincident = try #require(FlatGradient(Gradient(.radial, from: .black, to: .white, axis: Gradient.Axis(start: .zero, end: .zero)), bounds: bounds))
        #expect(coincident.shape == .radial(frame: AffineTransform(a: 1, b: 0, c: 0, d: 1, tx: 0, ty: 0)))
        let parallel = try #require(FlatGradient(Gradient(.radial, from: .black, to: .white, axis: Gradient.Axis(start: .zero, end: Point(x: 2, y: 0), end2: Point(x: 4, y: 0))), bounds: bounds))
        #expect(parallel.shape == .radial(frame: AffineTransform(a: 2, b: 0, c: 0, d: 2, tx: 0, ty: 0)))
        let autoRadial = try #require(FlatGradient(Gradient(.radial, from: .black, to: .white), bounds: bounds))
        #expect(autoRadial.parameter(at: Point(x: 100, y: 25)) == 1)
        #expect(auto.parameter(at: Point(x: 50, y: 0)) == 0.5)
        #expect(auto.color(at: 0) == .black)
        #expect(auto.color(at: 1) == .white)
        #expect(!auto.hasAlpha)
        #expect(auto == auto)
        #expect(Set([auto, autoRadial]).count == 2)
        let reflect = try #require(FlatGradient(Gradient(.logarithmic, from: .black, to: .white, behavior: .reflect, repeatCount: 2), bounds: bounds))
        #expect(reflect.rampPosition(1) == 0)
        #expect(reflect.rampPosition(.nan) == 0)
        let stops = reflect.linearStops(samplesPerSegment: 2)
        #expect(stops.first!.offset == 0 && stops.last!.offset == 1)
        #expect(zip(stops, stops.dropFirst()).allSatisfy { $0.offset <= $1.offset })
        let repeated = try #require(FlatGradient(Gradient(.linear, from: .black, to: .white, behavior: .repeat, repeatCount: 3), bounds: bounds))
        #expect(repeated.rampPosition(1) == 1)
        #expect(repeated.linearStops(samplesPerSegment: 1).count == 6)
        let single = try #require(FlatGradient(Gradient(stops: [Gradient.Stop(offset: 0.5, color: Corpus.red)]), bounds: bounds))
        #expect(single.linearStops().count == 3)
        let mask = FlatSoftMask(gradient: auto, frame: .identity, bounds: bounds)
        #expect(mask.value(at: 0) == 1)
        #expect(mask.value(at: 1) == 0)
    }

    @Test func flatNodesReportBounds() {
        let hairline = FlatNode.path(FlatPath(path: Corpus.rect(0, 0, 10, 10), paint: .color(.black), style: .stroke(StrokeStyle(width: 0))))
        #expect(hairline.bounds!.minX < 0)
        #expect(FlatNode.path(FlatPath(path: DisplayPath(), paint: .color(.black))).bounds == nil)
        let empty = FlatNode.group(FlatGroup(children: []))
        #expect(empty.bounds == nil)
        let clipped = FlatNode.group(FlatGroup(children: [.path(FlatPath(path: Corpus.rect(0, 0, 10, 10), paint: .color(.black)))], clip: FlatClip(path: DisplayPath())))
        #expect(clipped.bounds == nil)
        let filtered = FlatNode.group(FlatGroup(children: [.path(FlatPath(path: Corpus.rect(0, 0, 10, 10), paint: .color(.black)))], filter: .glow(radius: 1, sigma: 1, color: .black)))
        #expect(filtered.bounds == Rect(x: -4, y: -4, width: 18, height: 18))
        #expect(FlatFilter.blur(sigma: 1).spread == 3)
        #expect(FlatFilter.dropShadow(dx: -2, dy: 1, sigma: 1, color: .black).spread == 5)
        let text = FlatNode.text(FlatText(text: " ", run: Corpus.run(" "), color: .black))
        #expect(text.bounds == nil)
        #expect(text.tagged(Corpus.node(4)).node == Corpus.node(4))
        let image = FlatNode.image(FlatImage(image: Corpus.image(), rect: Rect(x: 0, y: 0, width: 4, height: 3)))
        #expect(image.tagged(Corpus.node(5)).node == Corpus.node(5))
        #expect(FlatNode.union([]) == nil)
        #expect(Rect.null.nonEmpty == nil)
    }

    // MARK: Rendering the flattened scene

    @Test(arguments: Corpus.fixtures)
    func flattenedPagesRenderLikeTheLivePage(_ name: String) throws {
        let page = Corpus.fixture(name)
        let scene = Corpus.scene([page], ppi: 144)
        let reference = Corpus.reference(page, scale: 2)
        for target in [FlattenTarget.pdf, .opaque] {
            let flat = Flattener(target: target, rasterResolution: 144).flatten(page, scene: scene).page
            let image = try #require(FlatRenderer().render(flat, scale: 2, background: .white))
            let failing = Corpus.difference(reference, image, tolerance: 40)
            if failing > 0.02 {
                Corpus.dump(image, "flat-\(name)-\(target.rawValue)")
                Corpus.dump(reference, "flat-\(name)-reference")
            }
            #expect(failing <= 0.02, "\(name) \(target.rawValue): \(failing)")
        }
    }

    @Test func opaqueTargetsCarryNoTransparency() {
        let page = Corpus.fixture("transparency")
        let result = Flattener(target: .opaque, rasterResolution: 72).flatten(page, scene: Corpus.scene([page]))
        #expect(result.report.planarized >= 1)
        for node in Self.all(result.page.nodes) {
            switch node {
            case .path(let path):
                if case .color(let color) = path.paint { #expect(color.alpha >= 1) }
            case .group(let group):
                #expect(group.opacity >= 1 && group.softMask == nil)
            case .image(let image):
                #expect(RGBAPixels(image.image).isOpaque)
            case .text:
                break
            }
        }
    }

    @Test func opaqueCompositorCases() throws {
        func composite(_ nodes: [FlatNode], background: Color? = nil) -> (nodes: [FlatNode], compositor: OpaqueCompositor) {
            var page = Corpus.page([])
            page.background = background
            var compositor = OpaqueCompositor(page: page, rasterResolution: 72)
            return (compositor.composite(nodes), compositor)
        }
        let square = FlatPath(path: Corpus.rect(10, 10, 40, 40), paint: .color(Corpus.blue))
        let translucent = FlatPath(path: Corpus.rect(30, 30, 40, 40), paint: .color(Corpus.red.withAlpha(multipliedBy: 0.5)))
        // Over nothing: composited over the page colour.
        let alone = composite([.path(translucent)], background: Color(white: 0.5))
        if case .path(let path) = alone.nodes[0], case .color(let color) = path.paint {
            #expect(abs(color.red - 0.7) < 1e-9 && color.alpha == 1)
        } else {
            Issue.record("expected an opaque piece")
        }
        // Over a fill: pieces.
        let over = composite([.path(square), .group(FlatGroup(children: [.path(translucent)], opacity: 0.8))])
        #expect(over.compositor.planarized == 1)
        #expect(over.nodes.count >= 3)
        // Over text: rendered.
        let text = FlatNode.text(FlatText(text: "A", run: Corpus.run("A", origin: Point(x: 30, y: 50)), color: .black))
        let overText = composite([text, .path(translucent)])
        #expect(overText.compositor.rasterized.count == 1)
        if case .group(let group) = overText.nodes[1] { #expect(group.clip != nil) } else { Issue.record("expected a clipped image") }
        // Translucent strokes, gradients with alpha, images with alpha and soft masks render.
        let bounds = Rect(x: 0, y: 0, width: 50, height: 50)
        let alphaGradient = try #require(FlatGradient(Gradient(.linear, from: .black, to: Color.white.withAlpha(multipliedBy: 0)), bounds: bounds))
        let others: [FlatNode] = [
            .path(FlatPath(path: Corpus.rect(0, 0, 10, 10), paint: .color(Color.black.withAlpha(multipliedBy: 0.5)), style: .stroke(StrokeStyle(width: 2)))),
            .path(FlatPath(path: Corpus.rect(0, 0, 10, 10), paint: .gradient(alphaGradient))),
            .image(FlatImage(image: Corpus.image(alpha: true), rect: bounds)),
            .group(FlatGroup(children: [.path(square)], softMask: FlatSoftMask(gradient: alphaGradient, frame: .identity, bounds: bounds))),
            .text(FlatText(text: "B", run: Corpus.run("B"), color: Color.black.withAlpha(multipliedBy: 0.3))),
        ]
        let rendered = composite(others)
        #expect(rendered.compositor.rasterized.count == 5)
        // Opaque gradients and images, clipped groups and nested plain groups pass through.
        let opaqueGradient = try #require(FlatGradient(Gradient(.linear, from: .black, to: .white), bounds: bounds))
        let clipped = FlatNode.group(FlatGroup(children: [.path(square), .path(translucent)], clip: FlatClip(path: Corpus.rect(0, 0, 60, 60))))
        let passing = composite([.path(FlatPath(path: Corpus.rect(0, 0, 5, 5), paint: .gradient(opaqueGradient))), .image(FlatImage(image: Corpus.image(), rect: bounds)), clipped])
        #expect(passing.compositor.planarized == 0)
        #expect(passing.compositor.rasterized.count == 1)
        // Off-page translucency and empty groups vanish; many fills beneath render.
        let offPage = composite([.group(FlatGroup(children: [.path(FlatPath(path: Corpus.rect(900, 900, 5, 5), paint: .color(Color.black.withAlpha(multipliedBy: 0.5)), style: .stroke(StrokeStyle(width: 1))))])), .group(FlatGroup(children: []))])
        if case .group(let group) = offPage.nodes[0], case .group(let inner) = group.children[0] { #expect(inner.children.isEmpty) } else { Issue.record("expected an empty group") }
        let many = (0..<(OpaqueCompositor.planarLimit + 1)).map { index in FlatNode.path(FlatPath(path: Corpus.rect(Double(index), 0, 50, 50), paint: .color(.black))) }
        #expect(composite(many + [.path(translucent)]).compositor.rasterized.count == 1)
        #expect(OpaqueCompositor.translucentFill(.path(FlatPath(path: Corpus.rect(0, 0, 1, 1), paint: .color(.black), overprint: true))) == nil)
    }

    @Test func flatRendererDrawsEveryNode() throws {
        let bounds = Rect(x: 0, y: 0, width: 50, height: 50)
        let gradient = try #require(FlatGradient(Gradient(.radial, from: .black, to: .white), bounds: bounds))
        let nodes: [FlatNode] = [
            .path(FlatPath(path: Corpus.rect(0, 0, 20, 20), paint: .gradient(gradient), style: .stroke(StrokeStyle(width: 2, cap: .round, join: .bevel, dash: [2, 1])))),
            .path(FlatPath(path: Corpus.rect(0, 0, 20, 20), paint: .color(.black), style: .stroke(StrokeStyle(width: 2, cap: .square, join: .round)))),
            .group(FlatGroup(children: [.path(FlatPath(path: Corpus.rect(0, 0, 40, 40), paint: .color(.black)))], softMask: FlatSoftMask(gradient: gradient, frame: .identity, bounds: bounds))),
            .group(FlatGroup(children: [], softMask: FlatSoftMask(gradient: gradient, frame: AffineTransform(a: 0, b: 0, c: 0, d: 0, tx: 0, ty: 0), bounds: bounds))),
        ]
        #expect(FlatRenderer().render(nodes, region: bounds, scale: 1, background: nil) != nil)
        #expect(FlatRenderer().render(nodes, region: Rect(x: 0, y: 0, width: 0, height: 5), scale: 1, background: nil) == nil)
        #expect(FlatRenderer().render(FlatPage(bounds: bounds, nodes: nodes), scale: 1) != nil)
    }

    // MARK: Vector capture

    /// A one-page PDF whose content is `content`, with `resources`.
    static func pdf(_ content: String, resources: [(String, PDFValue)] = [], extra: (PDFObjects) -> [(String, PDFValue)] = { _ in [] }) -> Data {
        let objects = PDFObjects(compress: false)
        let pages = objects.reserve()
        let stream = objects.addStream([], data: Data(content.utf8))
        let more = extra(objects)
        let page = objects.add(.dictionary([("Type", .name("Page")), ("Parent", .reference(pages)), ("MediaBox", .rect(0, 0, 100, 100)), ("Resources", .dictionary(resources + more)), ("Contents", .reference(stream))]))
        objects.set(pages, .dictionary([("Type", .name("Pages")), ("Kids", .array([.reference(page)])), ("Count", .int(1))]))
        let root = objects.add(.dictionary([("Type", .name("Catalog")), ("Pages", .reference(pages))]))
        return objects.file(version: "1.7", root: root, info: nil)
    }

    static let region = Rect(x: 0, y: 0, width: 100, height: 100)

    @Test func captureReadsPlainVectorContent() throws {
        let content = """
        q 1 0 0 1 5 5 cm 0.5 g 0 0 m 10 0 l 10 10 5 10 0 10 c 0 8 0 5 v 0 2 0 0 y h f
        1 0 0 rg 20 20 10 10 re f*
        0 0 100 100 re W n
        10 10 30 30 re W* n
        /DeviceRGB cs 0 1 0 sc 40 40 5 5 re F
        /DeviceGray cs 0.2 sc 50 50 5 5 re f Q
        n 60 60 m 70 70 l f
        """
        let nodes = try #require(VectorCapture.parse(pdf: Self.pdf(content), region: Self.region))
        #expect(Self.count(nodes) { if case .path = $0 { return true } else { return false } } == 5)
        #expect(Self.count(nodes) { if case .group(let group) = $0 { return group.clip != nil } else { return false } } == 2)
        let first = nodes[0]
        if case .path(let path) = first, case .color(let color) = path.paint {
            #expect(color == Color(white: 0.5))
            #expect(path.path.controlBounds == Rect(x: 5, y: 85, width: 10, height: 10))
        } else {
            Issue.record("expected the grey path first")
        }
    }

    @Test func captureRefusesWhatItCannotExpress() {
        let failing = [
            "0 0 10 10 re S", "/Sh1 sh", "BT ET", "0 0 0 1 k", "1 0 0 RG",
            "10 m", "/Missing gs", "/Missing Do", "/Missing cs 1 sc", "/P1 cs 1 sc",
        ]
        for content in failing {
            #expect(VectorCapture.parse(pdf: Self.pdf(content), region: Self.region) == nil, "\(content)")
        }
        #expect(VectorCapture.parse(pdf: Data("not a pdf".utf8), region: Self.region) == nil)
        // Colour spaces: an ICC space with 4 components, a pattern space, a non-ICC array.
        let spaces = Self.pdf("/C4 cs 0 0 0 1 sc 0 0 5 5 re f", extra: { objects in
            let icc4 = objects.addStream([("N", .int(4))], data: Data())
            return [("ColorSpace", .dictionary([("C4", .array([.name("ICCBased"), .reference(icc4)])), ("P1", .array([.name("Pattern")]))]))]
        })
        #expect(VectorCapture.parse(pdf: spaces, region: Self.region) == nil)
        let icc3 = Self.pdf("/C3 cs 1 0 0 sc 0 0 5 5 re f", extra: { objects in
            let icc = objects.addStream([("N", .int(3))], data: Data())
            return [("ColorSpace", .dictionary([("C3", .array([.name("ICCBased"), .reference(icc)]))]))]
        })
        #expect(VectorCapture.parse(pdf: icc3, region: Self.region)?.count == 1)
        // Graphics states: soft masks and blend modes refuse; SMask None and Normal pass.
        let states = Self.pdf("/A gs /B gs 0 0 5 5 re f", resources: [("ExtGState", .dictionary([
            ("A", .dictionary([("ca", .real(0.5)), ("SMask", .name("None")), ("BM", .name("Normal"))])),
            ("B", .dictionary([("BM", .name("Compatible"))])),
        ]))])
        let passed = VectorCapture.parse(pdf: states, region: Self.region)
        if case .path(let path) = passed?.first, case .color(let color) = path.paint { #expect(color.alpha == 0.5) } else { Issue.record("expected a translucent path") }
        for state in [PDFValue.dictionary([("SMask", .dictionary([]))]), .dictionary([("BM", .name("Multiply"))])] {
            #expect(VectorCapture.parse(pdf: Self.pdf("/S gs", resources: [("ExtGState", .dictionary([("S", state)]))]), region: Self.region) == nil)
        }
        // XObjects: images refuse, forms without resources refuse, transparency forms group.
        let image = Self.pdf("/Im Do", extra: { objects in
            [("XObject", .dictionary([("Im", .reference(objects.addStream([("Subtype", .name("Image"))], data: Data())))]))]
        })
        #expect(VectorCapture.parse(pdf: image, region: Self.region) == nil)
        let bare = Self.pdf("/Fm Do", extra: { objects in
            [("XObject", .dictionary([("Fm", .reference(objects.addStream([("Subtype", .name("Form"))], data: Data("0 0 5 5 re f".utf8))))]))]
        })
        #expect(VectorCapture.parse(pdf: bare, region: Self.region) == nil)
        let group = Self.pdf("/G gs /Fm Do", resources: [("ExtGState", .dictionary([("G", .dictionary([("ca", .real(0.4))]))]))], extra: { objects in
            let form = objects.addStream([
                ("Subtype", .name("Form")), ("BBox", .rect(0, 0, 50, 50)), ("Matrix", .numbers([1, 0, 0, 1, 10, 0])),
                ("Group", .dictionary([("S", .name("Transparency"))])), ("Resources", .dictionary([])),
            ], data: Data("1 0 0 rg 0 0 20 20 re f".utf8))
            return [("XObject", .dictionary([("Fm", .reference(form))]))]
        })
        let grouped = try? #require(VectorCapture.parse(pdf: group, region: Self.region))
        if case .group(let outer) = grouped?.first {
            #expect(abs(outer.opacity - 0.4) < 1e-6)
        } else {
            Issue.record("expected a transparency group")
        }
        let badMatrix = Self.pdf("/Fm Do", extra: { objects in
            [("XObject", .dictionary([("Fm", .reference(objects.addStream([("Subtype", .name("Form")), ("Matrix", .array([.name("x")])), ("BBox", .array([.name("y")])), ("Resources", .dictionary([]))], data: Data("0 0 5 5 re f".utf8))))]))]
        })
        #expect(VectorCapture.parse(pdf: badMatrix, region: Self.region)?.count == 1)
        #expect(VectorCapture.capture([], region: .null)?.isEmpty == true)
        #expect(!CaptureState.isRectangle(Corpus.ellipse(0, 0, 5, 5)))
        #expect(!CaptureState.isRectangle(DisplayPath(polygon: [Point(x: 0, y: 0), Point(x: 5, y: 1), Point(x: 5, y: 5), Point(x: 0, y: 5)])))
    }

    @Test func flattenReportPluralizes() {
        var report = FlattenReport()
        report.expanded = 2
        report.planarized = 1
        report.outlinedRuns = 1
        #expect(report.notes == ["2 objects with live effects expanded to paths", "1 text run converted to outlines", "1 transparent area flattened into opaque pieces"])
        report.planarized = 3
        #expect(report.notes.last == "3 transparent areas flattened into opaque pieces")
    }
}
