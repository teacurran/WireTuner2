// The PDF content-stream interpreter (import-formats.adoc, "Client"; IMG-009): runs a page's (or
// form's, or Type 3 glyph's) operators over a graphics state and emits imported nodes into a
// `PDFImportTree`.  Geometry is baked into page space -- points, y down, the crop box's top-left
// at the origin -- so every path's transform is the identity and stroke widths are scaled by the
// CTM's mean scale; images and text keep a transform.

import CoreGraphics
import CoreText
import Foundation
import WTGeometry
import WTRender
import enum WTRender.LineCap
import enum WTRender.LineJoin
import struct WTRender.StrokeStyle

final class PDFImportInterpreter {
    struct State {
        var ctm: AffineTransform
        var fillSpace: PDFImportColorSpace = .gray
        var strokeSpace: PDFImportColorSpace = .gray
        var fillValues: [Double] = [0]
        var strokeValues: [Double] = [0]
        var fillPattern: String?
        var strokePattern: String?
        var fillAlpha = 1.0
        var strokeAlpha = 1.0
        var lineWidth = 1.0
        var cap = LineCap.butt
        var join = LineJoin.miter
        var miterLimit = 10.0
        var dash: [Double] = []
        var dashPhase = 0.0
        var clips: [PDFImportScope] = []
        var charSpacing = 0.0
        var wordSpacing = 0.0
        var horizontalScale = 1.0
        var leading = 0.0
        var font: PDFImportFont?
        var fontSize = 0.0
        var render = 0
        var rise = 0.0
        /// A luminosity soft mask painting one shading: the alpha of a gradient's ramp.
        var alphaRamp: PDFImportAlphaRamp?
    }

    let session: PDFImportSession
    let tree: PDFImportTree
    let resources: PDFImportDict?
    /// Scopes opened outside this stream (the page clip, the enclosing forms).
    let outerScopes: [PDFImportScope]
    /// The default space of this stream's patterns: the CTM when it began.
    let patternBase: AffineTransform
    /// The page area `sh` fills when no clip is set, in page space.
    let pageBox: Rect
    let depth: Int
    /// Type 3 glyph mode: painted contours are collected instead of emitted.
    let collectGlyphs: Bool
    private(set) var glyphContours: [ImportedContour] = []

    var state: State
    private var stack: [State] = []
    private var marked: [PDFImportScope?] = []
    private var path = ImportPathBuilder()
    private var pendingClip: FillRule?
    private var textMatrix = AffineTransform.identity
    private var lineMatrix = AffineTransform.identity

    init(session: PDFImportSession, tree: PDFImportTree, resources: PDFImportDict?, ctm: AffineTransform, pageBox: Rect, outerScopes: [PDFImportScope] = [], depth: Int = 0, collectGlyphs: Bool = false) {
        self.session = session
        self.tree = tree
        self.resources = resources
        self.outerScopes = outerScopes
        patternBase = ctm
        self.pageBox = pageBox
        self.depth = depth
        self.collectGlyphs = collectGlyphs
        state = State(ctm: ctm)
    }

    /// Runs `data`, a content stream.
    func run(_ data: Data) {
        var parser = PDFImportParser(data)
        parser.forEachOperator { op, operands in
            execute(op, operands)
        }
        tree.flushText()
    }

    /// The scopes a node emitted now is inside, outermost first.
    var scopes: [PDFImportScope] {
        outerScopes + (marked.compactMap { $0 } + state.clips).sorted { $0.id < $1.id }
    }

    // MARK: Operators

    func execute(_ op: String, _ operands: [PDFImportOperand]) {
        let numbers = operands.compactMap(\.number)
        func number(_ index: Int) -> Double { index < numbers.count ? numbers[index] : 0 }
        func point(_ index: Int) -> Point { Point(x: number(index), y: number(index + 1)) }
        switch op {
        case "q":
            stack.append(state)
        case "Q":
            if let saved = stack.popLast() {
                state = saved
            }
        case "cm":
            if numbers.count == 6 {
                state.ctm = AffineTransform(a: numbers[0], b: numbers[1], c: numbers[2], d: numbers[3], tx: numbers[4], ty: numbers[5]).concatenating(state.ctm)
            }
        case "w": state.lineWidth = number(0)
        case "J": state.cap = PDFImportInterpreter.cap(Int(number(0)))
        case "j": state.join = PDFImportInterpreter.join(Int(number(0)))
        case "M": state.miterLimit = number(0)
        case "d":
            state.dash = operands.first?.array?.compactMap(\.number) ?? []
            state.dashPhase = operands.count > 1 ? operands[1].number ?? 0 : 0
        case "gs":
            if let name = operands.first?.name, let dict = resources?.dict("ExtGState")?.dict(name) {
                graphicsState(dict)
            }
        case "g", "G", "rg", "RG", "k", "K":
            let space: PDFImportColorSpace = op.lowercased() == "g" ? .gray : (op.lowercased() == "rg" ? .rgb : .cmyk)
            setColor(stroke: op == op.uppercased(), space: space, values: numbers)
        case "cs", "CS":
            let space = operands.first?.name.flatMap { PDFImportColorSpace.named($0, resources: resources) } ?? .gray
            setColor(stroke: op == "CS", space: space, values: space.initial)
        case "sc", "SC", "scn", "SCN":
            let stroke = op.hasPrefix("S")
            if let name = operands.last?.name {
                if stroke { state.strokePattern = name } else { state.fillPattern = name }
            } else if stroke {
                state.strokeValues = numbers
                state.strokePattern = nil
            } else {
                state.fillValues = numbers
                state.fillPattern = nil
            }
        case "m": path.move(to: point(0))
        case "l": path.line(to: point(0))
        case "c": path.cubic(point(0), point(2), point(4))
        case "v": path.cubic(path.currentPoint ?? point(0), point(0), point(2))
        case "y": path.cubic(point(0), point(2), point(2))
        case "h": path.close()
        case "re": path.rect(Rect(x: number(0), y: number(1), width: number(2), height: number(3)))
        case "S": paint(fill: nil, stroke: true)
        case "s": path.close(); paint(fill: nil, stroke: true)
        case "f", "F": paint(fill: .nonZero, stroke: false)
        case "f*": paint(fill: .evenOdd, stroke: false)
        case "B": paint(fill: .nonZero, stroke: true)
        case "B*": paint(fill: .evenOdd, stroke: true)
        case "b": path.close(); paint(fill: .nonZero, stroke: true)
        case "b*": path.close(); paint(fill: .evenOdd, stroke: true)
        case "n": paint(fill: nil, stroke: false)
        case "W": pendingClip = .nonZero
        case "W*": pendingClip = .evenOdd
        case "sh":
            if let name = operands.first?.name, let shading = resources?.dict("Shading")?[name] {
                shade(shading)
            }
        case "Do":
            if let name = operands.first?.name, let object = resources?.dict("XObject")?.stream(name) {
                xObject(object)
            }
        case "ID":
            var entries: [String: PDFImportOperand] = [:]
            var index = 0
            while index + 1 < operands.count - 1 {
                if let key = operands[index].name {
                    entries[key] = operands[index + 1]
                }
                index += 2
            }
            if let data = operands.last?.string, let spec = PDFImportImage.inlineSpec(entries, data: data, resources: resources, session: session) {
                image(spec)
            }
        case "BMC", "BDC":
            marked.append(op == "BDC" ? layerScope(operands) : nil)
        case "EMC":
            _ = marked.popLast()
        case "BT":
            textMatrix = .identity
            lineMatrix = .identity
        case "ET":
            tree.flushText()
        case "Tc": state.charSpacing = number(0)
        case "Tw": state.wordSpacing = number(0)
        case "Tz": state.horizontalScale = number(0) / 100
        case "TL": state.leading = number(0)
        case "Ts": state.rise = number(0)
        case "Tr": state.render = Int(number(0))
        case "Tf":
            state.fontSize = number(0)
            if let name = operands.first?.name, let dict = resources?.dict("Font")?.dict(name) {
                state.font = session.font(dict)
            }
        case "Td":
            nextLine(number(0), number(1))
        case "TD":
            state.leading = -number(1)
            nextLine(number(0), number(1))
        case "Tm":
            if numbers.count == 6 {
                textMatrix = AffineTransform(a: numbers[0], b: numbers[1], c: numbers[2], d: numbers[3], tx: numbers[4], ty: numbers[5])
                lineMatrix = textMatrix
            }
        case "T*":
            nextLine(0, -state.leading)
        case "Tj":
            show(operands.first.map { [$0] } ?? [])
        case "TJ":
            show(operands.first?.array ?? [])
        case "'":
            nextLine(0, -state.leading)
            show(operands.first.map { [$0] } ?? [])
        case "\"":
            state.wordSpacing = number(0)
            state.charSpacing = number(1)
            nextLine(0, -state.leading)
            show(operands.last.map { [$0] } ?? [])
        default:
            // d0, d1, ri, i, MP, DP, BX, EX, EI and anything unknown: nothing to import.
            break
        }
    }

    static func cap(_ value: Int) -> LineCap {
        value == 1 ? .round : (value == 2 ? .square : .butt)
    }

    static func join(_ value: Int) -> LineJoin {
        value == 1 ? .round : (value == 2 ? .bevel : .miter)
    }

    func graphicsState(_ dict: PDFImportDict) {
        if let width = dict.number("LW") { state.lineWidth = width }
        if let cap = dict.number("LC") { state.cap = PDFImportInterpreter.cap(Int(cap)) }
        if let join = dict.number("LJ") { state.join = PDFImportInterpreter.join(Int(join)) }
        if let limit = dict.number("ML") { state.miterLimit = limit }
        if let dash = dict.array("D"), let lengths = dash[0]?.array {
            state.dash = lengths.numbers
            state.dashPhase = dash[1]?.number ?? 0
        }
        if let alpha = dict.number("CA") { state.strokeAlpha = alpha }
        if let alpha = dict.number("ca") { state.fillAlpha = alpha }
        switch dict["SMask"] {
        case .name?:
            state.alphaRamp = nil
        case .dict(let mask)?:
            state.alphaRamp = PDFImportAlphaRamp(mask, ctm: state.ctm, session: session)
            if state.alphaRamp == nil {
                session.note("Soft masks were left out; the objects they mask are imported without them.")
            }
        default:
            break
        }
        if let mode = dict.name("BM"), mode != "Normal", mode != "Compatible" {
            session.note("Blend modes were imported as Normal.")
        }
        if let font = dict.array("Font"), let fontDict = font[0]?.dict {
            state.font = session.font(fontDict)
            state.fontSize = font[1]?.number ?? state.fontSize
        }
    }

    func setColor(stroke: Bool, space: PDFImportColorSpace, values: [Double]) {
        if stroke {
            state.strokeSpace = space
            state.strokeValues = values
            state.strokePattern = nil
        } else {
            state.fillSpace = space
            state.fillValues = values
            state.fillPattern = nil
        }
    }

    /// The current fill colour (black for a pattern), for image masks and text.
    var fillColor: Color {
        state.fillSpace.color(state.fillValues, alpha: state.fillAlpha) ?? .black
    }

    /// The paint of the fill or stroke state, seen through a gradient soft mask.
    func currentPaint(stroke: Bool) -> ImportedPaint {
        let paint = basePaint(stroke: stroke)
        return state.alphaRamp?.apply(to: paint) ?? paint
    }

    func basePaint(stroke: Bool) -> ImportedPaint {
        let space = stroke ? state.strokeSpace : state.fillSpace
        let alpha = stroke ? state.strokeAlpha : state.fillAlpha
        if case .pattern = space {
            guard let name = stroke ? state.strokePattern : state.fillPattern, let pattern = resources?.dict("Pattern")?[name], let dict = pattern.dict else {
                return .solid(.black)
            }
            guard Int(dict.number("PatternType") ?? 1) == 2, let shading = dict["Shading"] else {
                session.note("Tiling patterns were imported as flat fills.")
                return session.meshPaint
            }
            let m = dict.numbers("Matrix").flatMap { $0.count == 6 ? AffineTransform(a: $0[0], b: $0[1], c: $0[2], d: $0[3], tx: $0[4], ty: $0[5]) : nil } ?? .identity
            return PDFImportShading.paint(shading, toPage: m.concatenating(patternBase), resources: resources, session: session)
        }
        let values = stroke ? state.strokeValues : state.fillValues
        return .solid(space.color(values, alpha: alpha)!)
    }

    /// The CTM's mean scale.
    static func scale(_ transform: AffineTransform) -> Double {
        abs(transform.determinant).squareRoot()
    }

    func strokeStyle() -> StrokeStyle {
        let scale = PDFImportInterpreter.scale(state.ctm)
        return StrokeStyle(width: state.lineWidth * scale, cap: state.cap, join: state.join, miterLimit: state.miterLimit, dash: state.dash.map { $0 * scale }, dashPhase: state.dashPhase * scale)
    }

    // MARK: Paths

    func paint(fill: FillRule?, stroke: Bool) {
        let contours = path.build().map { $0.applying(state.ctm) }
        path = ImportPathBuilder()
        let clip = pendingClip
        pendingClip = nil
        if !contours.isEmpty, fill != nil || stroke {
            if collectGlyphs {
                glyphContours += contours
            } else {
                let item = ImportedPath(contours: contours, fill: fill == nil ? .none : currentPaint(stroke: false), fillRule: fill ?? .nonZero, stroke: stroke ? ImportedStroke(paint: currentPaint(stroke: true), style: strokeStyle()) : nil)
                tree.emit(.path(item), scopes: scopes)
            }
        }
        if let clip, !contours.isEmpty, !collectGlyphs {
            state.clips.append(session.scope(.clip(ImportedPath(contours: contours, fillRule: clip))))
        }
    }

    /// `sh`: the shading fills the clip (or the page).
    func shade(_ shading: PDFImportValue) {
        let paint = PDFImportShading.paint(shading, toPage: state.ctm, resources: resources, session: session)
        var region = ImportPathBuilder()
        region.rect(pageBox)
        var contours = region.build()
        if let last = state.clips.last, case .clip(let clip) = last.kind {
            contours = clip.contours
        }
        tree.emit(.path(ImportedPath(contours: contours, fill: paint)), scopes: scopes)
    }

    // MARK: Marked content

    /// The layer scope a `BDC` opens: `/OC` with an optional content group (or membership
    /// dictionary) names a layer; anything else opens nothing.
    func layerScope(_ operands: [PDFImportOperand]) -> PDFImportScope? {
        guard operands.first?.name == "OC", operands.count > 1 else {
            return nil
        }
        var name: String?
        switch operands[1] {
        case .name(let key):
            if let dict = resources?.dict("Properties")?.dict(key) {
                let group = dict.name("Type") == "OCMD" ? (dict.dict("OCGs") ?? dict.array("OCGs")?[0]?.dict) : dict
                name = group?.text("Name")
            }
        case .dict(let dict):
            name = dict["Name"]?.string.map(PDFImportOperand.text)
        default:
            break
        }
        return name.map { session.scope(.layer($0)) }
    }

    // MARK: XObjects

    func xObject(_ stream: PDFImportStream) {
        let dict = stream.dict
        switch dict.name("Subtype") {
        case "Image":
            image(PDFImportImage.spec(stream, resources: resources))
        case "Form":
            form(stream)
        default:
            break
        }
    }

    func form(_ stream: PDFImportStream) {
        guard depth < 16 else {
            session.note("Forms nested more than 16 deep were left out.")
            return
        }
        let dict = stream.dict
        let matrix = dict.numbers("Matrix").flatMap { $0.count == 6 ? AffineTransform(a: $0[0], b: $0[1], c: $0[2], d: $0[3], tx: $0[4], ty: $0[5]) : nil } ?? .identity
        let ctm = matrix.concatenating(state.ctm)
        var outer = scopes
        let transparency = dict.dict("Group")?.name("S") == "Transparency"
        if transparency {
            outer.append(session.scope(.group(opacity: state.fillAlpha)))
        } else if let box = dict.numbers("BBox"), box.count == 4 {
            var builder = ImportPathBuilder()
            builder.rect(Rect(minX: min(box[0], box[2]), minY: min(box[1], box[3]), maxX: max(box[0], box[2]), maxY: max(box[1], box[3])))
            let contours = builder.build().map { $0.applying(ctm) }
            outer.append(session.scope(.clip(ImportedPath(contours: contours))))
        }
        let child = PDFImportInterpreter(session: session, tree: tree, resources: dict.dict("Resources") ?? resources, ctm: ctm, pageBox: pageBox, outerScopes: outer, depth: depth + 1, collectGlyphs: collectGlyphs)
        child.state = state
        child.state.ctm = ctm
        child.state.clips = []
        if transparency {
            child.state.fillAlpha = 1
            child.state.strokeAlpha = 1
        }
        child.run(stream.data)
        glyphContours += child.glyphContours
    }

    func image(_ spec: PDFImportImageSpec) {
        guard !collectGlyphs, let decoded = PDFImportImage.pixels(spec, fill: fillColor, session: session) else {
            return
        }
        var image = decoded.image(name: nil)
        let natural = image.naturalRect
        let unit = AffineTransform(a: 1 / natural.width, b: 0, c: 0, d: -1 / natural.height, tx: 0, ty: 1)
        image.transform = unit.concatenating(state.ctm)
        tree.emit(.image(image), scopes: scopes)
    }

    // MARK: Text

    func nextLine(_ tx: Double, _ ty: Double) {
        lineMatrix = AffineTransform.translation(x: tx, y: ty).concatenating(lineMatrix)
        textMatrix = lineMatrix
    }

    /// One glyph of a show operation.
    struct Glyph {
        var code: UInt32
        var text: String?
        /// Text space → page at this glyph's origin, sized by the font size.
        var matrix: AffineTransform
        /// The adjustment before it, in thousandths of an em (TJ numbers).
        var gapBefore: Double
    }

    /// `Tj`, `TJ`, `'` and `"`: shows strings and advances the text matrix.
    func show(_ items: [PDFImportOperand]) {
        guard let font = state.font else {
            return
        }
        let size = state.fontSize
        let hScale = state.horizontalScale
        var glyphs: [Glyph] = []
        var gap = 0.0
        for item in items {
            if let adjustment = item.number {
                textMatrix = AffineTransform.translation(x: -adjustment / 1000 * size * hScale, y: 0).concatenating(textMatrix)
                gap += adjustment
                continue
            }
            guard let bytes = item.string else {
                continue
            }
            for code in font.codes(bytes) {
                let local = AffineTransform(a: size * hScale, b: 0, c: 0, d: size, tx: 0, ty: state.rise)
                glyphs.append(Glyph(code: code, text: font.unicode(code), matrix: local.concatenating(textMatrix).concatenating(state.ctm), gapBefore: gap))
                gap = 0
                let spacing = !font.twoByte && code == 32 ? state.wordSpacing : 0
                let advance = (font.width(code) * size + state.charSpacing + spacing) * hScale
                textMatrix = AffineTransform.translation(x: advance, y: 0).concatenating(textMatrix)
            }
        }
        guard !glyphs.isEmpty, state.render != 3, state.render != 7 else {
            return
        }
        let stroked = state.render % 4 == 1 || state.render % 4 == 2
        let outline = collectGlyphs || stroked || session.text == .outlines || font.isType3 || glyphs.contains { $0.text == nil }
        if outline {
            outlines(glyphs, font: font)
        } else {
            editable(glyphs, font: font)
        }
    }

    /// The glyphs as one path of their outlines.
    func outlines(_ glyphs: [Glyph], font: PDFImportFont) {
        var contours: [ImportedContour] = []
        for glyph in glyphs {
            if font.isType3 {
                guard let procedure = font.glyphName(glyph.code).flatMap({ font.charProcs?.stream($0) }) else {
                    continue
                }
                let child = PDFImportInterpreter(session: session, tree: tree, resources: font.type3Resources ?? resources, ctm: font.fontMatrix.concatenating(glyph.matrix), pageBox: pageBox, depth: depth + 1, collectGlyphs: true)
                child.run(procedure.data)
                contours += child.glyphContours
            } else if let path = font.outline(glyph.code) {
                contours += PDFImportPaths.contours(of: path, transform: glyph.matrix)
            }
        }
        guard !contours.isEmpty else {
            return
        }
        if collectGlyphs {
            glyphContours += contours
            return
        }
        let mode = state.render % 4
        let fill: ImportedPaint = mode == 1 ? .none : currentPaint(stroke: false)
        let stroke = mode == 1 || mode == 2 ? ImportedStroke(paint: currentPaint(stroke: true), style: strokeStyle()) : nil
        tree.emit(.path(ImportedPath(contours: contours, fill: fill, stroke: stroke)), scopes: scopes)
    }

    /// The glyphs as text runs: a new run wherever a `TJ` gap moves the pen more than a fifth
    /// of an em, a space added where such a gap stood for one.
    func editable(_ glyphs: [Glyph], font: PDFImportFont) {
        if !font.name.isEmpty, !PDFImportFont.isInstalled(font.name), session.missingFonts.insert(font.name).inserted {
            session.note("The font \(font.name) is not installed; its text uses a substitute until it is (Font substitution).")
        }
        var segments: [[Glyph]] = []
        for glyph in glyphs {
            if segments.isEmpty || glyph.gapBefore < -200 || glyph.gapBefore > 200 {
                if glyph.gapBefore < -200, let last = segments.last?.last, let text = last.text, !text.hasSuffix(" ") {
                    segments[segments.count - 1][segments[segments.count - 1].count - 1].text = text + " "
                }
                segments.append([glyph])
            } else {
                segments[segments.count - 1].append(glyph)
            }
        }
        let flip = AffineTransform(a: 1, b: 0, c: 0, d: -1, tx: 0, ty: 0)
        for segment in segments {
            let first = segment[0]
            // Block space (y down, one unit a point at the run's size) → page.
            let full = flip.concatenating(first.matrix)
            let scale = max(PDFImportInterpreter.scale(full), 1e-9)
            var transform = AffineTransform.scale(1 / scale).concatenating(full)
            var origin = Point.zero
            if abs(transform.a - 1) < 1e-6, abs(transform.d - 1) < 1e-6, abs(transform.b) < 1e-6, abs(transform.c) < 1e-6 {
                origin = Point(x: transform.tx, y: transform.ty)
                transform = .identity
            }
            let run = ImportedTextRun(text: segment.compactMap(\.text).joined(), fontName: font.name.isEmpty ? "Helvetica" : font.name, fontSize: scale, fill: currentPaint(stroke: false), origin: origin)
            tree.emitText(run, transform: transform, scopes: scopes)
        }
    }
}

