// The legacy Illustrator reader (import-formats.adoc, "Adobe Illustrator" and "Client"; IMG-010):
// Illustrator 1.1 through 8 and Illustrator EPS files are PostScript, but their page description
// is a fixed operator set (the Adobe Illustrator file format's AI5 operators), so the reader runs
// those operators directly -- paths, painting, compound paths, groups, clip groups, layers (a
// sublayer as a group named after it), colours, stroke attributes, point text and rasters --
// without a PostScript interpreter; object names come from the file's native art (D-095).  The
// prolog, setup and resources are skipped; an operator outside the set makes the file fall back
// to placement as EPS.

import CoreText
import Foundation
import UniformTypeIdentifiers
import WTGeometry
import WTRender
import enum WTRender.LineCap
import enum WTRender.LineJoin
import struct WTRender.StrokeStyle

struct AILegacyReader {
    /// Why a file cannot be read by the operator subset.
    struct Unsupported: Error {
        var op: String
    }

    let data: Data
    let name: String
    let text: ImportTextHandling

    /// The operators read as no-ops: locking, overprint, flatness, gradient instances (their
    /// paths keep the fallback fill) and text attributes the point text model does not carry.
    static let ignored: Set<String> = [
        "A", "Ap", "Ar", "D", "O", "R", "i", "Np", "XT", "XW", "Xy", "Xm", "XP",
        "Bb", "BB", "Bg", "Bh", "Bm", "Bc", "BD", "Bn",
        "Tr", "Tc", "Tw", "Ts", "Tz", "Ti", "Ta", "Tq", "Tt", "Tv", "Th", "Tk", "TA", "TC", "TW", "Tu", "Tn", "TV",
        "XI",
    ]

    /// The file's bounding box in PostScript points (`%%HiResBoundingBox` preferred).
    static func boundingBox(_ data: Data) -> Rect? {
        let head = String(decoding: data.prefix(32_768), as: UTF8.self)
        var box: Rect?
        for line in head.split(whereSeparator: \.isNewline) {
            for key in ["%%BoundingBox:", "%%HiResBoundingBox:"] where line.hasPrefix(key) {
                let values = line.dropFirst(key.count).split(separator: " ").compactMap { Double($0) }
                if values.count == 4, key.hasPrefix("%%Hi") || box == nil {
                    box = Rect(minX: min(values[0], values[2]), minY: min(values[1], values[3]), maxX: max(values[0], values[2]), maxY: max(values[1], values[3]))
                }
            }
        }
        return box
    }

    /// The file converted, or placed as EPS when it leaves the operator subset.
    func read() -> ImportedScene {
        let box = AILegacyReader.boundingBox(data) ?? Rect(x: 0, y: 0, width: 612, height: 792)
        let bounds = Rect(x: 0, y: 0, width: box.width, height: box.height)
        do {
            var interpreter = AILegacyInterpreter(box: box, text: text)
            var nodes = try interpreter.run(data)
            // Object names (D-095): from the native art an Illustrator EPS carries after its
            // PostScript, else from a native-format file's own art dictionaries.
            if nodes.contains(where: \.isLayer), case let native = IllustratorPrivateData.eps(data) ?? data, IllustratorNativeArt.namesObjects(native) {
                IllustratorObjectNames.apply(IllustratorNativeArt(scanning: native), to: &nodes)
            }
            return ImportedScene(kind: .vector, name: name, bounds: bounds, nodes: nodes, notes: interpreter.notes)
        } catch {
            // Placed as the EPS importer places a file: bounding box, preview, notes.
            let note = "“\(name)” was placed as EPS because it uses the PostScript operator “\(error.op)”, which the Illustrator reader does not interpret."
            return EPSImporter.place(data, file: EPSFile(postscript: data), name: name, notes: [note])
        }
    }
}

/// Runs the AI5 operator subset.
struct AILegacyInterpreter {
    /// An open group: an ordinary group (`u`), a clip group (`q`) or a layer (`Lb`).
    struct Open {
        var children: [ImportedNode] = []
        var clip: ImportedPath?
        var name: String?
        var role: ImportedGroup.Role = .group
        /// Which operator closes it.
        var closer: String
    }

    let box: Rect
    let text: ImportTextHandling
    var notes: [String] = []

    var groups: [Open] = [Open(closer: "")]
    /// Groups opened past `ImportNesting.limit`: their contents go into the deepest open group.
    var flattened = 0
    var path = ImportPathBuilder()
    var compound: ImportedPath?
    var clipNext = false
    var fill: ImportedPaint = .solid(.black)
    var stroke: ImportedPaint = .solid(.black)
    var style = StrokeStyle(width: 1)
    var evenOdd = false
    // Text.
    var textObject: [ImportedTextRun]?
    var textTransform = AffineTransform.identity
    var textOrigin = Point.zero
    var fontName = "Helvetica"
    var fontSize = 12.0
    var leading = 14.4
    var line = 0

    init(box: Rect, text: ImportTextHandling) {
        self.box = box
        self.text = text
    }

    /// PostScript points (y up) → the imported page (y down, the box's top-left at the origin).
    func point(_ x: Double, _ y: Double) -> Point {
        Point(x: x - box.minX, y: box.maxY - y)
    }

    mutating func note(_ text: String) {
        if !notes.contains(text) {
            notes.append(text)
        }
    }

    /// Runs the body of `data` and returns the page's nodes.
    mutating func run(_ data: Data) throws(AILegacyReader.Unsupported) -> [ImportedNode] {
        var parser = PDFImportParser(data, keepComments: true)
        var operands: [PDFImportOperand] = []
        var skipping: String?
        var inBody = !String(decoding: data.prefix(32_768), as: UTF8.self).contains("%%EndSetup")
        var raster: (spec: [Double], hex: [UInt8])?
        while let item = parser.next() {
            switch item {
            case .comment(let comment):
                if var pending = raster {
                    if comment.hasPrefix("AI5_EndRaster") {
                        emitRaster(pending.spec, pending.hex)
                        raster = nil
                    } else {
                        pending.hex += comment.utf8.compactMap(PDFImportLexer.hexValue)
                        raster = pending
                    }
                    continue
                }
                if let end = skipping {
                    if comment.hasPrefix(end) {
                        skipping = nil
                        inBody = inBody || end == "%EndSetup"
                    }
                    continue
                }
                for (begin, end) in [("%BeginProlog", "%EndProlog"), ("%BeginSetup", "%EndSetup"), ("%BeginResource", "%EndResource"), ("%BeginProcSet", "%EndProcSet"), ("AI5_BeginPalette", "AI5_EndPalette"), ("AI5_Begin_NonPrinting", "AI5_End_NonPrinting")] where comment.hasPrefix(begin) {
                    skipping = end
                }
                if comment.hasPrefix("%EndSetup") {
                    inBody = true
                }
                if comment.hasPrefix("%PageTrailer") || comment.hasPrefix("%Trailer") || comment.hasPrefix("%EOF") {
                    return finish()
                }
            case .operand(let operand):
                if skipping == nil && inBody {
                    operands.append(operand)
                    if parser.nestingTruncated {
                        note(ImportNesting.note)
                    }
                }
                parser.nestingTruncated = false
            case .op(let op):
                guard skipping == nil, inBody else {
                    continue
                }
                if op == "XI" {
                    raster = (operands.compactMap(\.number) + (operands.first?.array?.compactMap(\.number) ?? []), [])
                }
                try execute(op, operands)
                operands.removeAll()
            }
        }
        return finish()
    }

    mutating func finish() -> [ImportedNode] {
        flushText()
        while groups.count > 1 {
            close()
        }
        return groups[0].children
    }

    mutating func append(_ node: ImportedNode) {
        groups[groups.count - 1].children.append(node)
    }

    /// Opens `group`, or past `ImportNesting.limit` keeps drawing into the deepest open group.
    mutating func open(_ group: Open) {
        guard groups.count < ImportNesting.limit else {
            flattened += 1
            note(ImportNesting.note)
            return
        }
        groups.append(group)
    }

    mutating func close() {
        let open = groups.removeLast()
        append(.group(ImportedGroup(children: open.children, clip: open.clip, name: open.name, role: open.role)))
    }

    mutating func execute(_ op: String, _ operands: [PDFImportOperand]) throws(AILegacyReader.Unsupported) {
        let numbers = operands.compactMap(\.number)
        func number(_ index: Int) -> Double { index < numbers.count ? numbers[index] : 0 }
        func at(_ index: Int) -> Point { point(number(index), number(index + 1)) }
        switch op {
        case "m": path.move(to: at(0))
        case "l", "L": path.line(to: at(0))
        case "c", "C": path.cubic(at(0), at(2), at(4))
        case "v", "V": path.cubic(path.currentPoint ?? at(0), at(0), at(2))
        case "y", "Y": path.cubic(at(0), at(2), at(2))
        case "N", "H": paint(close: false, fill: false, stroke: false)
        case "n", "h": paint(close: true, fill: false, stroke: false)
        case "F": paint(close: false, fill: true, stroke: false)
        case "f": paint(close: true, fill: true, stroke: false)
        case "S": paint(close: false, fill: false, stroke: true)
        case "s": paint(close: true, fill: false, stroke: true)
        case "B": paint(close: false, fill: true, stroke: true)
        case "b": paint(close: true, fill: true, stroke: true)
        case "W": clipNext = true
        case "*u": compound = ImportedPath(contours: [])
        case "*U":
            if let item = compound, !item.contours.isEmpty {
                append(.path(item))
            }
            compound = nil
        case "u": open(Open(closer: "U"))
        case "q": open(Open(closer: "Q"))
        case "U", "Q", "LB":
            if flattened > 0 {
                flattened -= 1
            } else if groups.count > 1 {
                close()
            }
        case "g": fill = .solid(Color(white: number(0)).gray)
        case "G": stroke = .solid(Color(white: number(0)).gray)
        case "k": fill = .solid(Color(cyan: number(0), magenta: number(1), yellow: number(2), black: number(3)))
        case "K": stroke = .solid(Color(cyan: number(0), magenta: number(1), yellow: number(2), black: number(3)))
        case "x", "X":
            let tint = 1 - number(4)
            let color = Color(cyan: number(0) * tint, magenta: number(1) * tint, yellow: number(2) * tint, black: number(3) * tint)
            if op == "x" { fill = .solid(color) } else { stroke = .solid(color) }
        case "Xa", "XA":
            let color = Color(red: number(0), green: number(1), blue: number(2))
            if op == "Xa" { fill = .solid(color) } else { stroke = .solid(color) }
        case "Xx", "XX":
            // c m y k r g b (name) tint type: type 0 is CMYK, 1 RGB.
            let tint = 1 - number(7)
            let color = number(8) == 1
                ? Color(red: 1 - (1 - number(4)) * tint, green: 1 - (1 - number(5)) * tint, blue: 1 - (1 - number(6)) * tint)
                : Color(cyan: number(0) * tint, magenta: number(1) * tint, yellow: number(2) * tint, black: number(3) * tint)
            if op == "Xx" { fill = .solid(color) } else { stroke = .solid(color) }
        case "w": style.width = number(0)
        case "j": style.join = PDFImportInterpreter.join(Int(number(0)))
        case "J": style.cap = PDFImportInterpreter.cap(Int(number(0)))
        case "M": style.miterLimit = number(0)
        case "d":
            style.dash = operands.first?.array?.compactMap(\.number) ?? []
            style.dashPhase = number(0)
        case "XR": evenOdd = number(0) == 1
        case "Lb":
            // A layer inside a layer (a sublayer) is a group named after it.
            let sublayer = groups.contains { $0.role == .layer }
            open(Open(role: sublayer ? .group : .layer, closer: "LB"))
        case "Ln":
            if flattened == 0, let text = operands.first?.string {
                groups[groups.count - 1].name = PDFImportOperand.text(text)
            }
        case "To":
            flushText()
            textObject = []
            line = 0
        case "TO":
            flushText()
        case "Tp":
            if numbers.count >= 6 {
                let m = AffineTransform(a: numbers[0], b: -numbers[1], c: -numbers[2], d: numbers[3], tx: 0, ty: 0)
                textOrigin = point(numbers[4], numbers[5])
                textTransform = m
            }
        case "TP":
            break
        case "Tf":
            if let font = operands.first?.name {
                fontName = font.hasPrefix("_") ? String(font.dropFirst()) : font
            }
            fontSize = numbers.first ?? fontSize
        case "Tl":
            leading = numbers.first ?? leading
        case "Tx", "Tj", "TX":
            if let bytes = operands.first?.string {
                showText(PDFImportOperand.text(bytes))
            }
        case "T*":
            line += 1
        default:
            if AILegacyReader.ignored.contains(op) || op.hasPrefix("%") {
                if op.hasPrefix("B") {
                    note("Gradients in legacy Illustrator files were imported as their fallback fills.")
                }
                return
            }
            throw AILegacyReader.Unsupported(op: op)
        }
    }

    mutating func paint(close: Bool, fill doFill: Bool, stroke doStroke: Bool) {
        if close {
            path.close()
        }
        let contours = path.build()
        path = ImportPathBuilder()
        guard !contours.isEmpty else {
            return
        }
        if clipNext {
            clipNext = false
            let clip = ImportedPath(contours: contours, fillRule: evenOdd ? .evenOdd : .nonZero)
            if flattened == 0, groups.count > 1, groups[groups.count - 1].clip == nil, groups[groups.count - 1].closer == "Q" {
                groups[groups.count - 1].clip = clip
                if !doFill && !doStroke {
                    return
                }
            }
        }
        if compound != nil {
            compound?.contours += contours
            compound?.fill = doFill ? fill : .none
            compound?.fillRule = evenOdd ? .evenOdd : .nonZero
            compound?.stroke = doStroke ? ImportedStroke(paint: stroke, style: style) : nil
            return
        }
        guard doFill || doStroke else {
            return
        }
        append(.path(ImportedPath(contours: contours, fill: doFill ? fill : .none, fillRule: evenOdd ? .evenOdd : .nonZero, stroke: doStroke ? ImportedStroke(paint: stroke, style: style) : nil)))
    }

    // MARK: Text

    mutating func showText(_ string: String) {
        let lines = string.split(omittingEmptySubsequences: false, whereSeparator: { $0 == "\r" || $0 == "\n" })
        for (index, part) in lines.enumerated() {
            if index > 0 {
                line += 1
            }
            if part.isEmpty {
                continue
            }
            let offset = Point(x: 0, y: Double(line) * leading)
            if textObject == nil {
                textObject = []
            }
            if var runs = textObject, let last = runs.last, abs(last.origin.y - offset.y) < 1e-9 {
                runs[runs.count - 1].text += part
                textObject = runs
            } else {
                textObject?.append(ImportedTextRun(text: String(part), fontName: fontName, fontSize: fontSize, fill: fill, origin: offset))
            }
        }
    }

    mutating func flushText() {
        guard let runs = textObject, !runs.isEmpty else {
            textObject = nil
            return
        }
        textObject = nil
        let transform = textTransform.concatenating(.translation(x: textOrigin.x, y: textOrigin.y))
        if text == .outlines {
            var contours: [ImportedContour] = []
            for run in runs {
                guard let glyphs = ImportedScene.glyphRun(run) else { continue }
                for glyph in glyphs.glyphs {
                    if let outline = CTFontCreatePathForGlyph(glyphs.font.ctFont, glyph.glyph, nil) {
                        let placement = AffineTransform(a: 1, b: 0, c: 0, d: -1, tx: glyph.position.x, ty: glyph.position.y)
                        contours += PDFImportPaths.contours(of: outline, transform: placement.concatenating(transform))
                    }
                }
            }
            if !contours.isEmpty {
                append(.path(ImportedPath(contours: contours, fill: runs[0].fill)))
            }
            return
        }
        if textTransform.isIdentity {
            let moved = runs.map { run -> ImportedTextRun in
                var copy = run
                copy.origin = Point(x: run.origin.x + textOrigin.x, y: run.origin.y + textOrigin.y)
                return copy
            }
            append(.text(ImportedText(runs: moved)))
        } else {
            append(.text(ImportedText(runs: runs, transform: transform)))
        }
    }

    // MARK: Rasters

    /// `XI`: `[a b c d tx ty] llx lly urx ury h w bits type alpha reserved binary mask XI`,
    /// the pixels following as hex comment lines up to `%AI5_EndRaster`.
    mutating func emitRaster(_ spec: [Double], _ hex: [UInt8]) {
        // spec: llx lly urx ury h w bits type alpha reserved binary mask, then the matrix.
        guard spec.count >= 18 else {
            return
        }
        let width = Int(spec[5])
        let height = Int(spec[4])
        let bits = Int(spec[6])
        let type = Int(spec[7])
        let matrix = Array(spec[12..<18])
        let bytes = stride(from: 0, to: hex.count - 1, by: 2).map { hex[$0] << 4 | hex[$0 + 1] }
        let space: PDFImportColorSpace = type == 4 ? .cmyk : (type == 3 ? .rgb : .gray)
        let imageSpec = PDFImportImageSpec(width: width, height: height, bitsPerComponent: bits, space: space, decode: nil, imageMask: false, data: Data(bytes), encoded: false)
        let session = PDFImportSession(name: "", text: text, meshBlack: 0.5)
        guard let decoded = PDFImportImage.pixels(imageSpec, fill: .black, session: session) else {
            note("A raster image in the file could not be read and was left out.")
            return
        }
        var image = decoded.image(name: nil)
        // The matrix maps pixel space (y down, one unit a pixel) into PostScript space.
        let m = AffineTransform(a: matrix[0], b: matrix[1], c: matrix[2], d: matrix[3], tx: matrix[4], ty: matrix[5])
        let natural = image.naturalRect
        let toPixels = AffineTransform.scale(x: Double(width) / natural.width, y: Double(height) / natural.height)
        let flip = AffineTransform(a: 1, b: 0, c: 0, d: -1, tx: -box.minX, ty: box.maxY)
        let pixelFlip = AffineTransform(a: 1, b: 0, c: 0, d: -1, tx: 0, ty: 0)
        image.transform = toPixels.concatenating(pixelFlip).concatenating(m).concatenating(flip)
        append(.image(image))
    }
}

extension Color {
    /// The grey as a process black tint, as Illustrator's `g` means it.
    fileprivate var gray: Color {
        Color(cyan: 0, magenta: 0, yellow: 0, black: 1 - srgb.x)
    }
}
