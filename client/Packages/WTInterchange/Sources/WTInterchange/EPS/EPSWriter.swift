// The EPS writer (export-vector.adoc, "Client", *EPS writer*; IO-018): one page of the flattened
// opaque scene as DSC 3.0 Encapsulated PostScript.
//
// The page content uses short names bound in the prolog to the PostScript operators (`m`, `l`,
// `c`, `h`, `f`, `W`, `cm`, `rg`, `k`…), the same spellings as PDF's operators, so the content is
// written by the PDF writer's `PDFContent`.  Paths are filled and stroked in DeviceRGB, or in
// DeviceCMYK under *Convert to CMYK*; linear and radial gradients are Level 3 smooth shadings
// (`shfill`, types 2 and 3, over a sampled function of WTRender's ramp) or, at Level 2, stepped
// bands; images are ASCII85 with FlateDecode (Level 3) or RunLengthDecode (Level 2), a placed JPEG
// keeps its bytes under DCTDecode; overprint is `setoverprint`; text is Type 42 or referenced
// fonts (`PSFontRegistry`).  A TIFF preview goes in the DOS EPS binary header.

import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers
import WTGeometry
import WTRender
import enum WTRender.LineCap
import enum WTRender.LineJoin
import struct WTRender.StrokeStyle

/// Writes one flattened page as EPS.
public struct EPSWriter: Sendable {
    public var options: EPSOptions
    public var cmyk: any CMYKConverter

    public init(options: EPSOptions = .defaults, cmyk: any CMYKConverter = ProfileCMYKConverter()) {
        self.options = options
        self.cmyk = cmyk
    }

    /// `page` as an EPS file (with the preview `tiff` in a binary header when given), and notes.
    public func write(_ page: FlatPage, scene: ExportScene, title: String, preview tiff: Data? = nil, date: Date = Date()) -> (data: Data, notes: [String]) {
        let build = EPSBuild(options: options, cmyk: cmyk, scene: scene)
        let postscript = build.document(page, title: title, date: date)
        guard let tiff else {
            return (postscript, build.notes)
        }
        return (EPSWriter.binaryHeader(postscript: postscript, tiff: tiff), build.notes)
    }

    /// The DOS EPS binary header: magic, PostScript offset and length, no WMF, TIFF offset and
    /// length, no checksum; then the PostScript and the TIFF.
    static func binaryHeader(postscript: Data, tiff: Data) -> Data {
        var file = Data([0xC5, 0xD0, 0xD3, 0xC6])
        file.appendLittleEndian(UInt32(30))
        file.appendLittleEndian(UInt32(postscript.count))
        file.appendLittleEndian(UInt32(0))
        file.appendLittleEndian(UInt32(0))
        file.appendLittleEndian(UInt32(30 + postscript.count))
        file.appendLittleEndian(UInt32(tiff.count))
        file.appendLittleEndian(UInt16(0xFFFF))
        file.append(postscript)
        file.append(tiff)
        return file
    }
}

final class EPSBuild {
    let options: EPSOptions
    let cmyk: any CMYKConverter
    let scene: ExportScene
    let fonts: PSFontRegistry
    var content = PDFContent()
    var notes: [String] = []
    var wideClipped = Set<Color>()
    var bandedGradients = 0

    init(options: EPSOptions, cmyk: any CMYKConverter, scene: ExportScene) {
        self.options = options
        self.cmyk = cmyk
        self.scene = scene
        fonts = PSFontRegistry(mode: options.fonts)
    }

    var level: Int { options.level.rawValue }

    // MARK: File

    func document(_ page: FlatPage, title: String, date: Date) -> Data {
        let bounds = page.bounds
        content.transform(AffineTransform(a: 1, b: 0, c: 0, d: -1, tx: -bounds.minX, ty: bounds.maxY))
        if let background = page.background {
            content.op("q")
            setColor(OpaqueCompositor.over(background, .white))
            content.rectangle(bounds)
            content.op("f")
            content.op("Q")
        }
        for node in page.nodes {
            write(node)
        }
        var header = "%!PS-Adobe-3.0 EPSF-3.0\n"
        header += "%%BoundingBox: 0 0 \(Int(bounds.width.rounded(.up))) \(Int(bounds.height.rounded(.up)))\n"
        header += "%%HiResBoundingBox: 0 0 \(Numbers.format(bounds.width, places: 4)) \(Numbers.format(bounds.height, places: 4))\n"
        header += "%%Creator: \(EPSBuild.dscText(scene.info.creator))\n"
        let info = scene.info
        header += "%%Title: \(EPSBuild.dscText(options.includeDocumentInfo ? info.title ?? title : title))\n"
        if options.includeDocumentInfo {
            if let author = info.author {
                header += "%%For: \(EPSBuild.dscText(author))\n"
            }
            let formatter = ISO8601DateFormatter()
            header += "%%CreationDate: \(formatter.string(from: date))\n"
            let extra: [(String, String?)] = [("Subject", info.subject), ("Description", info.description), ("Keywords", info.keywords.isEmpty ? nil : info.keywords.joined(separator: ", ")), ("Language", info.language)]
            for (key, value) in extra {
                if let value {
                    header += "%WT\(key): \(EPSBuild.dscText(value))\n"
                }
            }
        }
        header += "%%LanguageLevel: \(level)\n"
        header += "%%DocumentData: Clean7Bit\n"
        header += "%%Pages: 1\n"
        let supplied = fonts.suppliedResources
        if !supplied.isEmpty {
            header += "%%DocumentSuppliedResources: " + supplied.map { "font \($0)" }.joined(separator: "\n%%+ ") + "\n"
        }
        let needed = fonts.neededResources
        if !needed.isEmpty {
            header += "%%DocumentNeededResources: " + needed.map { "font \($0)" }.joined(separator: "\n%%+ ") + "\n"
        }
        header += "%%EndComments\n"
        header += "%%BeginProlog\n\(EPSBuild.prolog)%%EndProlog\n"
        header += "%%BeginSetup\nWTDict begin\n\(fonts.setup())end\n%%EndSetup\n"
        header += "%%Page: 1 1\n%%BeginPageSetup\nsave WTDict begin\n%%EndPageSetup\n"
        var file = Data(header.utf8)
        file.append(content.data)
        file.append(Data("%%PageTrailer\nend restore\nshowpage\n%%Trailer\n%%EOF\n".utf8))
        report()
        return file
    }

    /// Short names for the operators the content uses, in a private dictionary.
    static let prolog = """
    /WTDict 40 dict def WTDict begin
    /q /gsave load def /Q /grestore load def /cm {6 array astore concat} bind def
    /m /moveto load def /l /lineto load def /c /curveto load def /h /closepath load def /re {4 2 roll moveto 1 index 0 rlineto 0 exch rlineto neg 0 rlineto closepath} bind def
    /f /fill load def /f* /eofill load def /S /stroke load def /n /newpath load def /W /clip load def /W* /eoclip load def
    /w /setlinewidth load def /J /setlinecap load def /j /setlinejoin load def /M /setmiterlimit load def /d /setdash load def
    /rg /setrgbcolor load def /k /setcmykcolor load def /sf {findfont exch makefont setfont} bind def
    end

    """

    func report() {
        for (name, reason) in fonts.outlined.sorted(by: { $0.key < $1.key }) {
            notes.append("font \(name) \(reason)")
        }
        if !wideClipped.isEmpty {
            notes.append("\(wideClipped.count) wide-gamut color\(wideClipped.count == 1 ? "" : "s") gamut-mapped into sRGB (EPS has no Display P3)")
        }
        if options.colors == .convertToCMYK {
            notes.append("colors converted to CMYK with the \(cmyk.name) profile")
        }
        if bandedGradients > 0 {
            notes.append("\(bandedGradients) gradient\(bandedGradients == 1 ? "" : "s") written as \(options.gradientSteps) stepped bands (PostScript Level 2)")
        }
        if options.embedPackage {
            notes.append("the embedded document package is not written yet (IO-028)")
        }
    }

    /// A DSC text value: printable ASCII as is, anything else in a PostScript string with octal
    /// escapes (DSC comments are 7-bit).
    static func dscText(_ text: String) -> String {
        let bytes = Array(text.utf8)
        if bytes.allSatisfy({ $0 >= 0x20 && $0 < 0x7F && $0 != UInt8(ascii: "(") && $0 != UInt8(ascii: ")") && $0 != UInt8(ascii: "\\") }) {
            return text
        }
        var result = "("
        for byte in bytes {
            switch byte {
            case UInt8(ascii: "("), UInt8(ascii: ")"), UInt8(ascii: "\\"):
                result += "\\" + String(UnicodeScalar(byte))
            case 0x20..<0x7F:
                result.unicodeScalars.append(UnicodeScalar(byte))
            default:
                result += String(format: "\\%03o", byte)
            }
        }
        return result + ")"
    }

    // MARK: Colour

    /// Selects `color` (alpha ignored: the scene is opaque): CMYK through the converter under
    /// *Convert to CMYK*, a CMYK colour's own inks when colours are kept, everything else as
    /// sRGB, gamut-mapped when it lies outside (EPS carries no Display P3).
    func setColor(_ color: Color) {
        if options.colors == .convertToCMYK || (options.colors == .keep && color.space == .cmyk) {
            content.op(cmyk.cmyk(color).map(PDFContent.n).joined(separator: " ") + " k")
            return
        }
        if ColorMath.isWide(color) {
            wideClipped.insert(color)
        }
        let value = ColorMath.sRGBFallback(color)
        content.op([value.red, value.green, value.blue].map(PDFContent.n).joined(separator: " ") + " rg")
    }

    func overprint(_ on: Bool) {
        if on && options.preserveOverprint {
            content.op("true setoverprint")
        }
    }

    // MARK: Nodes

    func write(_ node: FlatNode) {
        switch node {
        case .path(let path): writePath(path)
        case .text(let text): writeText(text)
        case .image(let image): writeImage(image)
        case .group(let group): writeGroup(group)
        }
    }

    func writeGroup(_ group: FlatGroup) {
        content.op("q")
        if let clip = group.clip {
            content.path(clip.path.applying(clip.transform))
            content.op(clip.rule == .evenOdd ? "W* n" : "W n")
        }
        for child in group.children {
            write(child)
        }
        content.op("Q")
    }

    func writePath(_ item: FlatPath) {
        content.op("q")
        content.transform(item.transform)
        overprint(item.overprint)
        if case .stroke(let style) = item.style {
            content.strokeStyle(style, hairlineWidth: 1 / max(item.transform.scaleFactor, 1e-9))
        }
        switch item.paint {
        case .color(let color):
            setColor(color)
            content.path(item.path)
            switch item.style {
            case .fill(let rule): content.op(rule == .evenOdd ? "f*" : "f")
            case .stroke: content.op("S")
            }
        case .gradient(let gradient):
            content.path(item.path)
            switch item.style {
            case .fill(let rule): content.op(rule == .evenOdd ? "W* n" : "W n")
            case .stroke: content.op("strokepath W n")
            }
            if let bounds = item.path.controlBounds {
                writeGradient(gradient, over: bounds.expanded(by: strokeReach(item.style)))
            }
        }
        content.op("Q")
    }

    func strokeReach(_ style: FlatPath.Style) -> Double {
        if case .stroke(let stroke) = style {
            return max(stroke.width, 1) * max(stroke.miterLimit, 2)
        }
        return 0
    }

    // MARK: Gradients

    /// Paints `gradient` over the current clip, which lies within `bounds` (local space).
    func writeGradient(_ gradient: FlatGradient, over bounds: Rect) {
        if options.level == .level3 {
            writeShading(gradient)
        } else {
            bandedGradients += 1
            writeBands(gradient, over: bounds)
        }
    }

    /// A Level 3 smooth shading over a 256-sample function of the ramp.
    func writeShading(_ gradient: FlatGradient) {
        let samples = 256
        var bytes = Data()
        let components = options.colors == .convertToCMYK ? 4 : 3
        for index in 0..<samples {
            let color = gradient.color(at: Double(index) / Double(samples - 1))
            let values = components == 4 ? cmyk.cmyk(color) : [color.red, color.green, color.blue]
            bytes.append(contentsOf: values.map { UInt8((min(max($0, 0), 1) * 255).rounded()) })
        }
        let range = (0..<components).map { _ in "0 1" }.joined(separator: " ")
        let space = components == 4 ? "/DeviceCMYK" : "/DeviceRGB"
        var coords: String
        switch gradient.shape {
        case .axial(let start, let end):
            coords = "/ShadingType 2 /Coords [\([start.x, start.y, end.x, end.y].map(PDFContent.n).joined(separator: " "))]"
        case .radial(let frame):
            content.transform(frame)
            coords = "/ShadingType 3 /Coords [0 0 0 0 0 1]"
        }
        content.op("<< \(coords) /ColorSpace \(space) /Extend [true true]")
        content.op("/Function << /FunctionType 0 /Domain [0 1] /Range [\(range)] /Size [\(samples)] /BitsPerSample 8 /DataSource <")
        content.op(HexLines.encode(bytes) + "> >> >> shfill")
    }

    /// Level 2: the gradient as `gradientSteps` bands of flat colour, each the colour at its
    /// middle, with the ends extended over the rest of `bounds`.
    func writeBands(_ gradient: FlatGradient, over bounds: Rect) {
        let steps = options.gradientSteps
        let corners = [Point(x: bounds.minX, y: bounds.minY), Point(x: bounds.maxX, y: bounds.minY), Point(x: bounds.maxX, y: bounds.maxY), Point(x: bounds.minX, y: bounds.maxY)]
        switch gradient.shape {
        case .axial(let start, let end):
            let axis = end - start
            let lengthSquared = max(axis.dx * axis.dx + axis.dy * axis.dy, 1e-12)
            let normal = Vector(-axis.dy, axis.dx) * (1 / lengthSquared.squareRoot())
            let ts = corners.map { ($0 - start).dot(axis) / lengthSquared }
            let ss = corners.map { ($0 - start).dot(normal) }
            let (sMin, sMax) = (ss.min()! - 1, ss.max()! + 1)
            func band(_ t0: Double, _ t1: Double, _ color: Color) {
                setColor(color)
                let points = [(t0, sMin), (t1, sMin), (t1, sMax), (t0, sMax)].map { start + axis * $0.0 + normal * $0.1 }
                content.path(DisplayPath(polygon: points))
                content.op("f")
            }
            band(min(ts.min()!, 0) - 1, 0, gradient.color(at: 0))
            band(1, max(ts.max()!, 1) + 1, gradient.color(at: 1))
            for step in 0..<steps {
                let t0 = Double(step) / Double(steps), t1 = Double(step + 1) / Double(steps)
                // Each band overlaps the next by a hair so no seam shows between them.
                band(t0, min(t1 + 0.25 / Double(steps), 1), gradient.color(at: (t0 + t1) / 2))
            }
        case .radial(let frame):
            content.transform(frame)
            let inverse = frame.inverted() ?? .identity
            let reach = corners.map { corner -> Double in
                let point = inverse.apply(corner)
                return hypot(point.x, point.y)
            }.max()! + 1
            func disc(_ radius: Double, _ color: Color) {
                setColor(color)
                content.op("0 0 \(PDFContent.n(radius)) 0 360 arc f")
            }
            disc(max(reach, 1), gradient.color(at: 1))
            for step in stride(from: steps, through: 1, by: -1) {
                disc(Double(step) / Double(steps), gradient.color(at: (Double(step) - 0.5) / Double(steps)))
            }
        }
    }

    // MARK: Text

    func writeText(_ text: FlatText) {
        let run = text.run
        guard let font = fonts.font(for: run, text: text.text) else {
            writePath(FlatPath(path: run.outline, transform: text.transform, paint: .color(text.color)))
            return
        }
        let latin1 = PSFontRegistry.latin1Codes(glyphs: run.glyphs.count, text: text.text)
        let size = run.font.size
        let scale = run.font.horizontalScale
        // The font matrix flips glyph space (y up) into the run's y-down space.
        let matrix = "[\([size * scale, 0, run.font.obliqueness * size, -size, 0, 0].map(PDFContent.n).joined(separator: " "))]"
        content.op("q")
        content.transform(text.transform)
        setColor(text.color)
        var current = ""
        var segment: (origin: Point, codes: [UInt8], positions: [Double], glyphs: [CGGlyph])?
        func flush() {
            guard let open = segment else { return }
            var advances: [Double] = []
            for index in open.codes.indices {
                if index + 1 < open.positions.count {
                    advances.append(open.positions[index + 1] - open.positions[index])
                } else {
                    advances.append(PSFontRegistry.advance(of: open.glyphs[index], in: font.unit) / 1000 * size * scale)
                }
            }
            content.op("\(PDFContent.n(open.origin.x)) \(PDFContent.n(open.origin.y)) m <\(HexLines.encode(Data(open.codes), bytesPerLine: 1024))> [\(advances.map(PDFContent.n).joined(separator: " "))] xshow")
            segment = nil
        }
        for (index, glyph) in run.glyphs.enumerated() {
            let use = fonts.use(glyph.glyph, of: font, latin1: latin1?[index])
            if use.name != current {
                flush()
                content.op("\(matrix) /\(use.name) sf")
                current = use.name
            }
            if let transform = glyph.transform {
                flush()
                content.op("q")
                content.transform(transform)
                content.op("0 0 m <\(String(format: "%02X", use.code))> show")
                content.op("Q")
                continue
            }
            if let open = segment, open.origin.y == glyph.position.y, open.codes.count < 16 {
                segment?.codes.append(use.code)
                segment?.positions.append(glyph.position.x)
                segment?.glyphs.append(glyph.glyph)
            } else {
                flush()
                segment = (glyph.position, [use.code], [glyph.position.x], [glyph.glyph])
            }
        }
        flush()
        content.op("Q")
    }

    // MARK: Images

    func writeImage(_ image: FlatImage) {
        let cmykOutput = options.colors == .convertToCMYK
        let components = cmykOutput ? 4 : 3
        var data: Data
        var filters: String
        let width = image.image.width, height = image.image.height
        if !cmykOutput, !image.rasterized, let jpeg = image.jpegData, PDFDocumentBuild.jpegComponents(jpeg) == 3 {
            data = jpeg
            filters = "/ASCII85Decode filter /DCTDecode filter"
        } else {
            if cmykOutput {
                data = cmyk.cmykPixels(image.image)
            } else {
                data = RGBAPixels(image.image).rgbOverWhite
            }
            if level >= 3 {
                data = Zlib.compress(data)
                filters = "/ASCII85Decode filter /FlateDecode filter"
            } else {
                data = Data(PackBits.encode(data) + [128])
                filters = "/ASCII85Decode filter /RunLengthDecode filter"
            }
        }
        let r = image.rect
        content.op("q")
        content.transform(image.transform)
        content.transform(AffineTransform(a: r.width, b: 0, c: 0, d: r.height, tx: r.minX, ty: r.minY))
        let decode = (0..<components).map { _ in "0 1" }.joined(separator: " ")
        content.op("/Device\(components == 4 ? "CMYK" : "RGB") setcolorspace")
        content.op("<< /ImageType 1 /Width \(width) /Height \(height) /BitsPerComponent 8 /Decode [\(decode)] /ImageMatrix [\(width) 0 0 \(height) 0 0] /DataSource currentfile \(filters) >> image")
        content.op(ASCII85.encode(data))
        content.op("Q")
    }
}

extension RGBAPixels {
    /// The colour channels composited over white, 3 bytes per pixel.
    var rgbOverWhite: Data {
        var result = Data(capacity: width * height * 3)
        for index in stride(from: 0, to: bytes.count, by: 4) {
            let alpha = Int(bytes[index + 3])
            for channel in 0..<3 {
                let value = Int(bytes[index + channel])
                result.append(UInt8((value * alpha + 255 * (255 - alpha) + 127) / 255))
            }
        }
        return result
    }
}
