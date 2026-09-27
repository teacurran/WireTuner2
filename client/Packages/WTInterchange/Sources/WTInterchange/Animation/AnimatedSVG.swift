// Animated SVG export (web/animation.adoc, "Exporting an animation" and "Client"; WEB-018): every
// frame of the document's animation in one SVG, each frame a `<g class="f" id="fN">`, the layers
// every frame shares (the background) in one `<g>` outside the frames, and a CSS `@keyframes`
// block per frame with `step-end` timing toggling `visibility` (hold counts stretch the frame's
// share of the cycle).  `animation-iteration-count` follows *Loop*; without *Autoplay* the frames
// are paused on frame 1 until the pointer hovers or clicks.  No SMIL, no scripts.  The frames go
// through the SVG writer, so paths, gradients, text and links are written as in a still SVG.
//
// Layers source: one file per exported page (each frame shows the page's area).  Pages and
// Pages-and-layers sources: one file whose frames show their own pages, each translated onto
// the first frame's page.

import Foundation
import WTGeometry
import WTRender

/// Animated SVG options: the SVG writer's, and overrides of the document's timing.
public struct AnimatedSVGOptions: ExportOptions, Hashable {
    public var svg: SVGOptions
    /// Frames per second; nil uses the document's.
    public var fps: Double?
    /// Nil uses the document's *Loop*.
    public var loop: Bool?
    /// Nil uses the document's *Autoplay*.
    public var autoplay: Bool?
    /// Nil uses the document's *Background*.
    public var background: ExportAnimation.Background?
    /// Page indices to export frames of (Pages sources); nil exports every frame.
    public var pages: Set<Int>?
    /// Placed SVG animations keep playing inside every frame (WEB-028); the HTML publisher, which
    /// places them over the page itself, turns it off.
    public var nestsSVGAnimations = true
    /// `SVGWriter.sameTabTarget`: `_top` from the HTML publisher, whose pages sit in `<object>`.
    public var sameTabTarget: String?

    public init(svg: SVGOptions = .defaults, fps: Double? = nil, loop: Bool? = nil, autoplay: Bool? = nil, background: ExportAnimation.Background? = nil,
                pages: Set<Int>? = nil) {
        self.svg = svg
        self.fps = fps
        self.loop = loop
        self.autoplay = autoplay
        self.background = background
        self.pages = pages
    }

    public static var defaults: AnimatedSVGOptions { AnimatedSVGOptions() }

    func validate() throws {
        try svg.validate()
        if let fps, !(fps.isFinite && fps >= 0.01 && fps <= 120) {
            throw ExportError.invalidOption("The frame rate must be 0.01 to 120 frames per second.")
        }
    }
}

/// The frame timing of an animated SVG: each frame's start and end as fractions of the cycle.
public struct AnimatedSVGTiming: Hashable, Sendable {
    /// Seconds per cycle.
    public var duration: Double
    /// Per frame, the cycle fraction it starts and ends at.
    public var spans: [(start: Double, end: Double)]

    public init(holds: [Int], fps: Double) {
        let periods = holds.map { max($0, 1) }
        let total = max(periods.reduce(0, +), 1)
        duration = Double(total) / fps
        var start = 0
        spans = periods.map { hold in
            defer { start += hold }
            return (Double(start) / Double(total), Double(start + hold) / Double(total))
        }
    }

    public static func == (lhs: AnimatedSVGTiming, rhs: AnimatedSVGTiming) -> Bool {
        lhs.duration == rhs.duration && lhs.spans.map(\.start) == rhs.spans.map(\.start) && lhs.spans.map(\.end) == rhs.spans.map(\.end)
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(duration)
        hasher.combine(spans.map(\.start))
        hasher.combine(spans.map(\.end))
    }
}

/// Writes the document's animation as animated SVG.
public struct AnimatedSVGExporter: Sendable {
    public init() {}

    /// The animated SVG documents of `scene`'s animation: one per exported page for the Layers
    /// source, one in all for the Pages sources.  `pageHrefs` is as for `SVGWriter` (page links
    /// inside frames).  Throws `nothingToExport` without frames.
    public func documents(scene: ExportScene, options: AnimatedSVGOptions = .defaults, pageHrefs: [Int: String] = [:]) throws -> [SVGDocument] {
        try options.validate()
        guard let animation = scene.animation else { throw ExportError.nothingToExport }
        let frames = animation.frames.filter { frame in frame.page.map { options.pages?.contains($0) ?? true } ?? true }
        guard let first = frames.first else { throw ExportError.nothingToExport }
        if first.page == nil {
            let areas = scene.pages.isEmpty ? [animation.area] : scene.pages.map(\.bounds)
            return areas.map { area in document(frames: frames, areas: frames.map { _ in area }, scene: scene, animation: animation, options: options, pageHrefs: pageHrefs) }
        }
        let areas = frames.map { $0.pageRect ?? animation.area }
        return [document(frames: frames, areas: areas, scene: scene, animation: animation, options: options, pageHrefs: pageHrefs)]
    }

    /// Writes `documents` next to `destination` (one file, or one per page named by the
    /// destination's pattern).
    public func export(scene: ExportScene, options: AnimatedSVGOptions = .defaults, to destination: ExportDestination) throws -> ExportSummary {
        let pages = scene.animation?.frames.first?.page == nil ? max(scene.pages.count, 1) : 1
        let urls = try destination.urls(count: pages, format: .svg) { index in
            FileNamePattern.Values(name: scene.name, page: index + 1, pageName: index < scene.pages.count ? scene.pages[index].name : nil)
        }
        let documents = try documents(scene: scene, options: options)
        var summary = ExportSummary()
        do {
            for (document, url) in zip(documents, urls) {
                try Data(document.text.utf8).write(to: url)
                summary.files.append(url)
                summary.notes += document.notes
            }
        } catch {
            throw ExportError.writeFailed(error.localizedDescription)
        }
        return summary
    }

    /// One animated SVG of `frames`, frame i drawn over `areas[i]` and mapped onto `areas[0]`.
    func document(frames: [AnimationFrame], areas: [Rect], scene: ExportScene, animation: ExportAnimation, options: AnimatedSVGOptions,
                  pageHrefs: [Int: String]) -> SVGDocument {
        let area = areas[0]
        // Layers every frame shows over one area are the shared background, written once.
        let sameArea = areas.allSatisfy { $0 == area }
        var shared = sameArea ? Set(frames[0].layers) : []
        for frame in frames.dropFirst() { shared.formIntersection(frame.layers) }
        if frames.count == 1 { shared = [] }
        let flattener = SVGExporter.flattener(options: options.svg, scene: scene)
        func flat(_ layers: Set<NodeID>, over rect: Rect) -> [FlatNode] {
            let list = animation.displayList.restricted(toLayers: layers)
            return flattener.flatten(ExportPage(bounds: rect, displayList: list), scene: scene).page.nodes
        }
        let background: Color? = switch options.background ?? animation.background {
        case .pageColor: animation.pageColor ?? .white
        case .white: .white
        case .transparent: nil
        }
        let build = SVGBuild(options: options.svg, page: FlatPage(bounds: area, background: background, nodes: []), scene: scene, resourceFolder: "images")
        build.pageHrefs = pageHrefs
        build.nestsSVGAnimations = options.nestsSVGAnimations
        build.sameTabTarget = options.sameTabTarget
        let backgroundNodes = shared.isEmpty ? [] : flat(shared, over: area)
        let frameNodes = zip(frames, areas).map { frame, rect in flat(Set(frame.layers).subtracting(shared), over: rect) }
        let timing = AnimatedSVGTiming(holds: frames.map(\.hold), fps: options.fps ?? animation.fps)
        return build.animatedDocument(background: backgroundNodes, frames: frameNodes, offsets: areas.map { Vector(dx: area.minX - $0.minX, dy: area.minY - $0.minY) },
                                      timing: timing, loop: options.loop ?? animation.loop, autoplay: options.autoplay ?? animation.autoplay)
    }
}

extension SVGBuild {
    /// The animated document: the background nodes, then each frame's nodes in its group
    /// (translated by its offset), and the frame CSS.
    func animatedDocument(background: [FlatNode], frames: [[FlatNode]], offsets: [Vector], timing: AnimatedSVGTiming, loop: Bool, autoplay: Bool) -> SVGDocument {
        assignNodeIDs(background + frames.flatMap { $0 })
        body = XMLStream(minify: options.minify)
        if !background.isEmpty {
            body.start("g", [("class", "bg")])
            for node in background { write(node) }
            body.end()
        }
        for (index, nodes) in frames.enumerated() {
            let offset = offsets[index]
            let transform = offset.dx == 0 && offset.dy == 0 ? nil : "translate(\(number(offset.dx)) \(number(offset.dy)))"
            body.start("g", [("class", "f"), ("id", "f\(index)"), ("transform", transform)])
            for node in nodes { write(node) }
            body.end()
        }
        let css = Self.frameCSS(timing, loop: loop, autoplay: autoplay, separator: options.minify ? "" : "\n")
        var out = XMLStream(minify: options.minify)
        var text = "<?xml version=\"1.0\" encoding=\"UTF-8\"?>"
        if !options.minify {
            text += "\n<!-- Generator: \(XMLStream.escape(scene.info.creator, attribute: false)) -->"
        }
        let width = page.bounds.width, height = page.bounds.height
        let unit = SVGOptions.unitScale[options.sizeUnit, default: 1]
        out.start("svg", [
            ("xmlns", "http://www.w3.org/2000/svg"),
            ("xmlns:xlink", "http://www.w3.org/1999/xlink"),
            ("version", "1.1"),
            ("width", options.responsive ? nil : number(width * unit) + options.sizeUnit),
            ("height", options.responsive ? nil : number(height * unit) + options.sizeUnit),
            ("viewBox", "0 0 \(number(width)) \(number(height))"),
        ])
        out.start("defs")
        let rules = fontFaces + classOrder.map { ".\(classes[$0]!){\($0)}" } + [css]
        out.element("style", [("type", "text/css")], text: rules.joined(separator: options.minify ? "" : "\n"))
        if !defs.text.isEmpty {
            out.raw(indented(defs.text, levels: 2))
        }
        out.end()
        if let color = page.background {
            var attributes: [(String, String?)] = [("width", number(width)), ("height", number(height))]
            attributes += styleAttributes(paint(color, "fill"))
            out.element("rect", attributes)
        }
        if !body.text.isEmpty {
            out.raw(indented(body.text, levels: 1))
        }
        out.end()
        let count = frames.count
        notes.append("\(count) frame\(count == 1 ? "" : "s") written as an animated SVG")
        return SVGDocument(text: text + (options.minify ? "" : "\n") + out.text + (options.minify ? "" : "\n"), resources: resources, notes: notes)
    }

    /// The frame CSS: every frame hidden but while its keyframes show it.
    static func frameCSS(_ timing: AnimatedSVGTiming, loop: Bool, autoplay: Bool, separator: String) -> String {
        func percent(_ fraction: Double) -> String { Numbers.format(fraction * 100, places: 4) + "%" }
        let duration = Numbers.format(timing.duration, places: 4)
        var rules = [".f{visibility:hidden;animation-duration:\(duration)s;animation-timing-function:step-end;animation-iteration-count:\(loop ? "infinite" : "1");animation-fill-mode:forwards\(autoplay ? "" : ";animation-play-state:paused")}"]
        if !autoplay {
            rules.append("svg:hover .f,svg:active .f{animation-play-state:running}")
        }
        for (index, span) in timing.spans.enumerated() {
            var steps: [String] = []
            if span.start > 0 { steps.append("0%{visibility:hidden}") }
            steps.append("\(percent(span.start)){visibility:visible}")
            if span.end < 1 { steps.append("\(percent(span.end)){visibility:hidden}") }
            steps.append("100%{visibility:\(span.end < 1 ? "hidden" : "visible")}")
            rules.append("@keyframes wt-f\(index){\(steps.joined())}")
            rules.append("#f\(index){animation-name:wt-f\(index)}")
        }
        return rules.joined(separator: separator)
    }
}
