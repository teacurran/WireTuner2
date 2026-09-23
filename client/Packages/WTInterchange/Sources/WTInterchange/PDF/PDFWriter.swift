// The PDF writer (export-pdf.adoc, "Client"; IO-025; D-039): {product}'s own writer, fed by the
// flattened scene rather than `CGPDFContext`, so that separations, overprint, output intents,
// page boxes, layers and embedded files -- which Core Graphics cannot write -- have a home.
//
// What it writes: a header for the chosen version; one content stream per page in the page's
// coordinate system (pasteboard y-down mapped onto PDF's y-up by one `cm`); paths filled and
// stroked in `/ICCBased` sRGB (or Display P3 at PDF 1.7 and later); linear and radial gradients as
// shading patterns over a sampled function of WTRender's OKLab ramp, with a luminosity soft mask
// carrying the ramp's alpha; transparency groups for opacity; gradient masks as luminosity soft
// masks whose group paints a DeviceGray shading -- vector, no bitmap; clipping; overprint graphics
// states; images with `FlateDecode` (or the placed JPEG's bytes under `DCTDecode`) and an `SMask`
// for alpha, downsampled on request; fonts as TrueType subsets or Type 3 glyphs with `ToUnicode`;
// links from attached URLs; page boxes; document info and XMP metadata; the cross-reference table.
// Linearization, object streams, layers and the embedded package are reported, not written.

import CoreGraphics
import CoreText
import Foundation
import ImageIO
import UniformTypeIdentifiers
import WTGeometry
import WTRender

/// Writes flattened pages as one PDF.
public struct PDFWriter: Sendable {
    public var options: PDFOptions

    public init(options: PDFOptions = .defaults) {
        self.options = options
    }

    /// `pages` (flattened from `scene`'s pages, in order) as a PDF file, and notes for the
    /// export summary.
    public func write(_ pages: [FlatPage], scene: ExportScene) -> (data: Data, notes: [String]) {
        PDFDocumentBuild(options: options, scene: scene).write(pages)
    }
}

/// One file being written.
final class PDFDocumentBuild {
    let options: PDFOptions
    let scene: ExportScene
    let objects: PDFObjects
    let fonts: PDFFontRegistry
    var notes: [String] = []
    private var iccObjects: [String: Int] = [:]
    private var images: [ObjectIdentifier: (object: Int, image: CGImage)] = [:]
    var wideClipped = 0
    var wideKept = 0
    var outlinedFonts = Set<String>()

    init(options: PDFOptions, scene: ExportScene) {
        self.options = options
        self.scene = scene
        objects = PDFObjects(compress: options.compressContent)
        fonts = PDFFontRegistry(objects: objects, embedAll: options.fonts == .embedFull)
    }

    func write(_ pages: [FlatPage]) -> (data: Data, notes: [String]) {
        let pagesObject = objects.reserve()
        var pageObjects: [Int] = []
        for (index, page) in pages.enumerated() {
            let bleed = options.pageSize == .pagePlusBleed && index < scene.pages.count ? scene.pages[index].bleed : 0
            pageObjects.append(writePage(page, bleed: bleed, parent: pagesObject))
        }
        fonts.finish()
        objects.set(pagesObject, .dictionary([
            ("Type", .name("Pages")),
            ("Kids", .array(pageObjects.map { .reference($0) })),
            ("Count", .int(pageObjects.count)),
        ]))
        var catalog: [(String, PDFValue)] = [("Type", .name("Catalog")), ("Pages", .reference(pagesObject))]
        var info: Int?
        if options.includeDocumentInfo {
            info = objects.add(infoDictionary())
            catalog.append(("Metadata", .reference(objects.addStream([("Type", .name("Metadata")), ("Subtype", .name("XML"))], data: xmp(), raw: true))))
        }
        if let language = scene.info.language {
            catalog.append(("Lang", .string(language)))
        }
        if wideKept > 0 {
            // A PDF without a standard that keeps Display P3 objects names Display P3 as its
            // output intent, so viewers know what the document was made for.
            catalog.append(("OutputIntents", .array([.dictionary([
                ("Type", .name("OutputIntent")),
                ("S", .name("GTS_PDFA1")),
                ("OutputConditionIdentifier", .string("Display P3")),
                ("DestOutputProfile", .reference(icc(CGColorSpace.displayP3))),
            ])])))
            notes.append("\(wideKept) Display P3 color\(wideKept == 1 ? "" : "s") written with the Display P3 profile")
        }
        let root = objects.add(.dictionary(catalog))
        if wideClipped > 0 {
            notes.append("\(wideClipped) wide-gamut color\(wideClipped == 1 ? "" : "s") converted to sRGB (Display P3 needs PDF 1.7 with profiles embedded)")
        }
        for name in outlinedFonts.sorted() {
            notes.append("font \(name) does not allow embedding; its text is outlined")
        }
        if options.linearize {
            notes.append("fast web view (linearization) is not written yet; the file is not linearized")
        }
        if options.layers {
            notes.append("PDF layers are not written yet; layers are flattened into the page")
        }
        if options.embedPackage {
            notes.append("the embedded document package is not written yet (IO-028)")
        }
        return (objects.file(version: options.version.rawValue, root: root, info: info), notes)
    }

    // MARK: Pages

    func writePage(_ page: FlatPage, bleed: Double, parent: Int) -> Int {
        let width = page.bounds.width + 2 * bleed
        let height = page.bounds.height + 2 * bleed
        // Pasteboard (y down) → page space (y up, origin at the media box's corner).
        let base = AffineTransform(a: 1, b: 0, c: 0, d: -1, tx: bleed - page.bounds.minX, ty: page.bounds.maxY + bleed)
        let stream = PDFStreamWriter(build: self, patternBase: base)
        stream.content.transform(base)
        for node in page.nodes {
            stream.write(node)
        }
        let contents = objects.addStream([], data: stream.content.data)
        var dictionary: [(String, PDFValue)] = [
            ("Type", .name("Page")),
            ("Parent", .reference(parent)),
            ("MediaBox", .rect(0, 0, width, height)),
            ("TrimBox", .rect(bleed, bleed, bleed + page.bounds.width, bleed + page.bounds.height)),
        ]
        if bleed > 0 {
            dictionary.append(("BleedBox", .rect(0, 0, width, height)))
        }
        if let art = FlatNode.union(page.nodes.compactMap(\.bounds))?.intersection(page.bounds).nonEmpty {
            let box = art.applying(base)
            dictionary.append(("ArtBox", .rect(box.minX, box.minY, box.maxX, box.maxY)))
        }
        dictionary += [("Resources", stream.resources.value), ("Contents", .reference(contents))]
        if !stream.links.isEmpty {
            let annotations = stream.links.map { link -> PDFValue in
                let box = link.bounds.applying(base)
                return .reference(objects.add(.dictionary([
                    ("Type", .name("Annot")),
                    ("Subtype", .name("Link")),
                    ("Rect", .rect(box.minX, box.minY, box.maxX, box.maxY)),
                    ("Border", .array([.int(0), .int(0), .int(0)])),
                    ("A", .dictionary([("S", .name("URI")), ("URI", .string(link.url))])),
                ])))
            }
            dictionary.append(("Annots", .array(annotations)))
        }
        return objects.add(.dictionary(dictionary))
    }

    // MARK: Shared objects

    /// The `/ICCBased` stream of a named Core Graphics colour space (sRGB, Display P3).
    func icc(_ name: CFString) -> Int {
        let key = name as String
        if let object = iccObjects[key] {
            return object
        }
        // Both spaces are built in and carry ICC data.
        let data = CGColorSpace(name: name)!.copyICCData()! as Data
        let object = objects.addStream([("N", .int(3)), ("Alternate", .name("DeviceRGB"))], data: data)
        iccObjects[key] = object
        return object
    }

    /// The image XObject for `image` (shared by every use of the same image).
    func imageObject(_ image: FlatImage, pixelsPerPoint: Double) -> Int {
        let key = ObjectIdentifier(image.image)
        if let existing = images[key] {
            return existing.object
        }
        var picture = image.image
        if options.downsample, pixelsPerPoint * 72 > options.downsampleAbovePPI {
            let factor = options.downsampleToPPI / (pixelsPerPoint * 72)
            picture = PDFDocumentBuild.resample(picture, width: max(Int((Double(picture.width) * factor).rounded()), 1), height: max(Int((Double(picture.height) * factor).rounded()), 1))
        }
        let colorSpace: PDFValue = options.embedProfiles ? .array([.name("ICCBased"), .reference(icc(CGColorSpace.sRGB))]) : .name("DeviceRGB")
        let original = picture === image.image && !image.rasterized && options.colorImages != .lossless && options.colorImages != .none ? image.jpegData : nil
        var dictionary: [(String, PDFValue)] = [
            ("Type", .name("XObject")),
            ("Subtype", .name("Image")),
            ("Width", .int(picture.width)),
            ("Height", .int(picture.height)),
            ("BitsPerComponent", .int(8)),
        ]
        let object: Int
        if let original, let components = PDFDocumentBuild.jpegComponents(original) {
            dictionary.append(("ColorSpace", components == 1 ? .name("DeviceGray") : (components == 4 ? .name("DeviceCMYK") : colorSpace)))
            dictionary.append(("Filter", .name("DCTDecode")))
            object = objects.addStream(dictionary, data: original, raw: true)
        } else {
            let pixels = RGBAPixels(picture)
            dictionary.append(("ColorSpace", colorSpace))
            if !pixels.isOpaque {
                let mask: [(String, PDFValue)] = [
                    ("Type", .name("XObject")), ("Subtype", .name("Image")), ("Width", .int(pixels.width)), ("Height", .int(pixels.height)),
                    ("ColorSpace", .name("DeviceGray")), ("BitsPerComponent", .int(8)),
                ]
                dictionary.append(("SMask", .reference(objects.addStream(mask, data: pixels.alpha, raw: options.colorImages == .none))))
            }
            if options.colorImages == .jpeg, let jpeg = ImageEncoding.encode(PDFDocumentBuild.opaqueRGB(pixels), type: .jpeg, properties: [kCGImageDestinationLossyCompressionQuality: Double(options.jpegQuality) / 100]) {
                dictionary.append(("Filter", .name("DCTDecode")))
                object = objects.addStream(dictionary, data: jpeg, raw: true)
            } else {
                object = objects.addStream(dictionary, data: pixels.rgb, raw: options.colorImages == .none)
            }
        }
        images[key] = (object, image.image)
        return object
    }

    /// The component count of a JPEG (1 grey, 3 RGB, 4 CMYK), nil when it cannot be read.
    static func jpegComponents(_ data: Data) -> Int? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let model = properties[kCGImagePropertyColorModel] as? String
        else {
            return nil
        }
        switch model as CFString {
        case kCGImagePropertyColorModelGray: return 1
        case kCGImagePropertyColorModelCMYK: return 4
        default: return 3
        }
    }

    /// `image` redrawn at `width` × `height` with high-quality interpolation.
    static func resample(_ image: CGImage, width: Int, height: Int) -> CGImage {
        let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: FlatRenderer.colorSpace, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return context.makeImage()!
    }

    /// The colour channels as an opaque image (for JPEG, which has no alpha).
    static func opaqueRGB(_ pixels: RGBAPixels) -> CGImage {
        let provider = CGDataProvider(data: pixels.rgb as CFData)!
        return CGImage(width: pixels.width, height: pixels.height, bitsPerComponent: 8, bitsPerPixel: 24, bytesPerRow: pixels.width * 3, space: FlatRenderer.colorSpace, bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue), provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent)!
    }

    // MARK: Metadata

    func pdfDate(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "yyyyMMddHHmmss"
        return "D:" + formatter.string(from: date) + "Z"
    }

    func infoDictionary() -> PDFValue {
        let info = scene.info
        var entries: [(String, PDFValue)] = []
        let fields: [(String, String?)] = [("Title", info.title), ("Author", info.author), ("Subject", info.subject ?? info.description)]
        for (key, value) in fields {
            if let value {
                entries.append((key, .string(value)))
            }
        }
        if !info.keywords.isEmpty {
            entries.append(("Keywords", .string(info.keywords.joined(separator: ", "))))
        }
        let now = pdfDate(Date())
        entries += [("Creator", .string(info.creator)), ("Producer", .string("WireTuner PDF writer")), ("CreationDate", .string(now)), ("ModDate", .string(now))]
        return .dictionary(entries)
    }

    /// The XMP packet: Dublin Core, XMP basic and PDF properties.
    func xmp() -> Data {
        let info = scene.info
        func escape(_ text: String) -> String { XMLStream.escape(text, attribute: false) }
        var dc = ""
        if let title = info.title {
            dc += "<dc:title><rdf:Alt><rdf:li xml:lang=\"x-default\">\(escape(title))</rdf:li></rdf:Alt></dc:title>"
        }
        if let author = info.author {
            dc += "<dc:creator><rdf:Seq><rdf:li>\(escape(author))</rdf:li></rdf:Seq></dc:creator>"
        }
        if let description = info.description {
            dc += "<dc:description><rdf:Alt><rdf:li xml:lang=\"x-default\">\(escape(description))</rdf:li></rdf:Alt></dc:description>"
        }
        if !info.keywords.isEmpty {
            dc += "<dc:subject><rdf:Bag>" + info.keywords.map { "<rdf:li>\(escape($0))</rdf:li>" }.joined() + "</rdf:Bag></dc:subject>"
        }
        if let language = info.language {
            dc += "<dc:language><rdf:Bag><rdf:li>\(escape(language))</rdf:li></rdf:Bag></dc:language>"
        }
        let formatter = ISO8601DateFormatter()
        let now = formatter.string(from: Date())
        let packet = """
        <?xpacket begin="\u{FEFF}" id="W5M0MpCehiHzreSzNTczkc9d"?>
        <x:xmpmeta xmlns:x="adobe:ns:meta/"><rdf:RDF xmlns:rdf="http://www.w3.org/1999/02/22-rdf-syntax-ns#">\
        <rdf:Description rdf:about="" xmlns:dc="http://purl.org/dc/elements/1.1/" xmlns:xmp="http://ns.adobe.com/xap/1.0/" xmlns:pdf="http://ns.adobe.com/pdf/1.3/">\
        <dc:format>application/pdf</dc:format>\(dc)\
        <xmp:CreatorTool>\(escape(info.creator))</xmp:CreatorTool><xmp:CreateDate>\(now)</xmp:CreateDate><xmp:ModifyDate>\(now)</xmp:ModifyDate>\
        <pdf:Producer>WireTuner PDF writer</pdf:Producer></rdf:Description></rdf:RDF></x:xmpmeta>
        <?xpacket end="w"?>
        """
        return Data(packet.utf8)
    }
}

/// The resources of one content stream.
final class PDFResources {
    private var entries: [String: [(String, PDFValue)]] = [:]
    private var keys: [String: String] = [:]
    private var counters: [String: Int] = [:]

    /// The name of a resource in `category`, added once per `key`.
    func name(_ category: String, prefix: String, key: String, value: () -> PDFValue) -> String {
        let full = category + "|" + key
        if let name = keys[full] {
            return name
        }
        counters[category, default: 0] += 1
        let name = "\(prefix)\(counters[category]!)"
        keys[full] = name
        entries[category, default: []].append((name, value()))
        return name
    }

    /// Registers a resource under a given name (fonts, named by the registry).
    func add(_ category: String, name: String, value: PDFValue) {
        let full = category + "|" + name
        guard keys[full] == nil else { return }
        keys[full] = name
        entries[category, default: []].append((name, value))
    }

    var value: PDFValue {
        .dictionary(entries.keys.sorted().map { ($0, .dictionary(entries[$0]!)) })
    }
}

/// Writes flat nodes into one content stream.
final class PDFStreamWriter {
    let build: PDFDocumentBuild
    var content = PDFContent()
    let resources = PDFResources()
    /// Pasteboard → this stream's default space (pattern matrices are relative to it).
    let patternBase: AffineTransform
    /// Attached URLs and their pasteboard bounds.
    var links: [(url: String, bounds: Rect)] = []

    init(build: PDFDocumentBuild, patternBase: AffineTransform) {
        self.build = build
        self.patternBase = patternBase
    }

    var options: PDFOptions { build.options }
    var objects: PDFObjects { build.objects }

    func write(_ node: FlatNode) {
        if options.linksFromURLs, let url = build.scene.info(for: node.node)?.url, let bounds = node.bounds {
            links.append((url, bounds))
        }
        switch node {
        case .path(let path): writePath(path)
        case .text(let text): writeText(text)
        case .image(let image): writeImage(image)
        case .group(let group): writeGroup(group)
        }
    }

    // MARK: Colour

    /// Selects `color` for filling (or stroking) and returns its alpha.
    func setColor(_ color: Color, stroke: Bool) -> Double {
        var components = [color.red, color.green, color.blue]
        var space = CGColorSpace.sRGB
        if ColorMath.isWide(color) {
            if options.keepsDisplayP3 {
                let p3 = ColorMath.displayP3(color)
                components = [p3.x, p3.y, p3.z]
                space = CGColorSpace.displayP3
                build.wideKept += 1
            } else {
                let clipped = ColorMath.clipped(color)
                components = [clipped.red, clipped.green, clipped.blue]
                build.wideClipped += 1
            }
        }
        let name = colorSpace(space)
        let values = components.map(PDFContent.n).joined(separator: " ")
        content.op("/\(name) \(stroke ? "CS" : "cs") \(values) \(stroke ? "SC" : "sc")")
        return min(max(color.alpha, 0), 1)
    }

    func colorSpace(_ space: CFString) -> String {
        if !options.embedProfiles {
            return resources.name("ColorSpace", prefix: "CS", key: "device") { .name("DeviceRGB") }
        }
        return resources.name("ColorSpace", prefix: "CS", key: space as String) {
            .array([.name("ICCBased"), .reference(build.icc(space))])
        }
    }

    /// Sets a graphics state for constant alpha and overprint (nothing for the defaults).
    func setState(fillAlpha: Double = 1, strokeAlpha: Double = 1, overprint: Bool = false, softMask: PDFValue? = nil, maskKey: String = "") {
        let op = overprint && options.preserveOverprint
        guard fillAlpha < 1 || strokeAlpha < 1 || op || softMask != nil else {
            return
        }
        var entries: [(String, PDFValue)] = [("Type", .name("ExtGState"))]
        if fillAlpha < 1 { entries.append(("ca", .real(fillAlpha))) }
        if strokeAlpha < 1 { entries.append(("CA", .real(strokeAlpha))) }
        if op { entries += [("OP", .bool(true)), ("op", .bool(true)), ("OPM", .int(1))] }
        if let softMask { entries.append(("SMask", softMask)) }
        let key = "\(fillAlpha)|\(strokeAlpha)|\(op)|\(maskKey)"
        let name = resources.name("ExtGState", prefix: "GS", key: key) { .dictionary(entries) }
        content.op("/\(name) gs")
    }

    // MARK: Paths

    func writePath(_ item: FlatPath) {
        content.op("q")
        content.transform(item.transform)
        let stroke: Bool
        var alpha = 1.0
        switch item.style {
        case .fill:
            stroke = false
        case .stroke(let style):
            stroke = true
            content.strokeStyle(style, hairlineWidth: 1 / max(item.transform.scaleFactor, 1e-9))
        }
        switch item.paint {
        case .color(let color):
            alpha = setColor(color, stroke: stroke)
            setState(fillAlpha: stroke ? 1 : alpha, strokeAlpha: stroke ? alpha : 1, overprint: item.overprint)
        case .gradient(let gradient):
            let pattern = self.pattern(gradient, transform: item.transform)
            content.op(stroke ? "/Pattern CS /\(pattern) SCN" : "/Pattern cs /\(pattern) scn")
            if gradient.hasAlpha, let bounds = item.path.controlBounds {
                setState(overprint: item.overprint, softMask: alphaMask(gradient, bounds: bounds.expanded(by: strokeReach(item.style))), maskKey: "alpha\(objects.count)")
            } else {
                setState(overprint: item.overprint)
            }
        }
        content.path(item.path)
        switch item.style {
        case .fill(let rule): content.op(rule == .evenOdd ? "f*" : "f")
        case .stroke: content.op("S")
        }
        content.op("Q")
    }

    func strokeReach(_ style: FlatPath.Style) -> Double {
        if case .stroke(let stroke) = style {
            return max(stroke.width, 1) * max(stroke.miterLimit, 2)
        }
        return 0
    }

    /// A shading pattern for `gradient` painted by an item with local → pasteboard `transform`.
    func pattern(_ gradient: FlatGradient, transform: AffineTransform) -> String {
        let shading = shadingObject(gradient, components: 3) { t in
            let color = gradient.color(at: t)
            return [color.red, color.green, color.blue].map { min(max($0, 0), 1) }
        }
        let matrix = PDFStreamWriter.shadingFrame(gradient).concatenating(transform).concatenating(patternBase)
        let object = objects.add(.dictionary([
            ("Type", .name("Pattern")),
            ("PatternType", .int(2)),
            ("Shading", .reference(shading)),
            ("Matrix", .numbers([matrix.a, matrix.b, matrix.c, matrix.d, matrix.tx, matrix.ty])),
        ]))
        return resources.name("Pattern", prefix: "P", key: String(object)) { .reference(object) }
    }

    /// The transform from a shading's own space to the gradient's local space: identity for an
    /// axial shading (its coordinates are local), the frame for a radial one (a unit circle).
    static func shadingFrame(_ gradient: FlatGradient) -> AffineTransform {
        if case .radial(let frame) = gradient.shape {
            return frame
        }
        return .identity
    }

    /// An axial or radial shading over a sampled function of `evaluate` (1 or 3 components).
    func shadingObject(_ gradient: FlatGradient, components: Int, evaluate: (Double) -> [Double]) -> Int {
        let samples = 1024
        var bytes = Data(capacity: samples * components * 2)
        for index in 0..<samples {
            for value in evaluate(Double(index) / Double(samples - 1)) {
                let word = UInt16((min(max(value, 0), 1) * 65535).rounded())
                bytes.append(UInt8(word >> 8))
                bytes.append(UInt8(word & 0xFF))
            }
        }
        let range = PDFValue.numbers((0..<components).flatMap { _ in [0.0, 1.0] })
        let function = objects.addStream([
            ("FunctionType", .int(0)), ("Domain", .numbers([0, 1])), ("Range", range),
            ("Size", .array([.int(samples)])), ("BitsPerSample", .int(16)),
        ], data: bytes)
        let space: PDFValue = components == 1 ? .name("DeviceGray") : .array([.name("ICCBased"), .reference(build.icc(CGColorSpace.sRGB))])
        var entries: [(String, PDFValue)] = [("ColorSpace", options.embedProfiles || components == 1 ? space : .name("DeviceRGB"))]
        switch gradient.shape {
        case .axial(let start, let end):
            entries += [("ShadingType", .int(2)), ("Coords", .numbers([start.x, start.y, end.x, end.y]))]
        case .radial:
            // The unit circle; `shadingFrame` maps it onto the gradient.
            entries += [("ShadingType", .int(3)), ("Coords", .numbers([0, 0, 0, 0, 0, 1]))]
        }
        entries += [("Domain", .numbers([0, 1])), ("Function", .reference(function)), ("Extend", .array([.bool(true), .bool(true)]))]
        return objects.add(.dictionary(entries))
    }

    /// A luminosity soft mask whose group paints a grey shading of `evaluate`, in the current
    /// user space, over `bounds`.
    func luminosityMask(_ gradient: FlatGradient, frame: AffineTransform, bounds: Rect, evaluate: (Double) -> Double) -> PDFValue {
        let shading = shadingObject(gradient, components: 1) { [evaluate($0)] }
        var group = PDFContent()
        group.op("q")
        group.transform(PDFStreamWriter.shadingFrame(gradient).concatenating(frame))
        group.op("/Sh1 sh")
        group.op("Q")
        let form = objects.addStream([
            ("Type", .name("XObject")), ("Subtype", .name("Form")),
            ("BBox", .rect(bounds.minX, bounds.minY, bounds.maxX, bounds.maxY)),
            ("Group", .dictionary([("S", .name("Transparency")), ("CS", .name("DeviceGray"))])),
            ("Resources", .dictionary([("Shading", .dictionary([("Sh1", .reference(shading))]))])),
        ], data: group.data)
        return .dictionary([("Type", .name("Mask")), ("S", .name("Luminosity")), ("G", .reference(form)), ("BC", .array([.real(0)]))])
    }

    /// The soft mask carrying a gradient's alpha (a PDF shading has none), in local space.
    func alphaMask(_ gradient: FlatGradient, bounds: Rect) -> PDFValue {
        luminosityMask(gradient, frame: .identity, bounds: bounds) { gradient.color(at: $0).alpha }
    }

    // MARK: Text

    func writeText(_ text: FlatText) {
        let run = text.run
        guard options.fonts != .outlines, let font = build.fonts.font(for: run.font) else {
            if options.fonts != .outlines {
                build.outlinedFonts.insert(run.font.postScriptName)
            }
            writePath(FlatPath(path: run.outline, transform: text.transform, paint: .color(text.color)))
            return
        }
        content.op("q")
        content.transform(text.transform)
        let alpha = setColor(text.color, stroke: false)
        setState(fillAlpha: alpha)
        content.op("BT")
        let size = run.font.size
        let scale = run.font.horizontalScale
        if scale != 1 {
            content.op("\(PDFContent.n(scale * 100)) Tz")
        }
        let mapping = PDFFontRegistry.unicodeMapping(glyphs: run.glyphs.map(\.glyph), text: text.text)
        // Glyphs on one baseline are shown with one TJ, the gaps between Core Text's positions
        // and the font's advances written as adjustments, so text extracts as words.
        let flip = AffineTransform(a: 1, b: 0, c: 0, d: -1, tx: 0, ty: 0)
        var current = ""
        var shown: [String] = []
        var line: Double?
        var pen = 0.0
        func flush() {
            if !shown.isEmpty {
                content.op("[\(shown.joined(separator: " "))] TJ")
                shown = []
            }
        }
        for (glyph, unicode) in zip(run.glyphs, mapping) {
            let use = build.fonts.use(glyph.glyph, of: font, text: unicode)
            resources.add("Font", name: use.name, value: .reference(use.object))
            if use.name != current {
                flush()
                line = nil
                content.op("/\(use.name) \(PDFContent.n(size)) Tf")
                current = use.name
            }
            if glyph.transform == nil, let y = line, glyph.position.y == y {
                let adjustment = -(glyph.position.x - pen) / (size * scale) * 1000
                if abs(adjustment) >= 0.01 {
                    shown.append(PDFContent.n(adjustment))
                }
            } else {
                flush()
                let m = flip.concatenating(glyph.placement)
                content.op("\([m.a, m.b, m.c, m.d, m.tx, m.ty].map(PDFContent.n).joined(separator: " ")) Tm")
                line = glyph.transform == nil ? glyph.position.y : nil
            }
            shown.append("<\(use.code)>")
            pen = glyph.position.x + build.fonts.width(of: glyph.glyph, in: font) / 1000 * size * scale
        }
        flush()
        content.op("ET")
        content.op("Q")
    }

    // MARK: Images

    func writeImage(_ image: FlatImage) {
        let scale = image.transform.scaleFactor
        let pixelsPerPoint = Double(image.image.width) / max(image.rect.width * scale, 1e-9)
        let object = build.imageObject(image, pixelsPerPoint: pixelsPerPoint)
        let name = resources.name("XObject", prefix: "Im", key: String(object)) { .reference(object) }
        content.op("q")
        content.transform(image.transform)
        let r = image.rect
        content.transform(AffineTransform(a: r.width, b: 0, c: 0, d: -r.height, tx: r.minX, ty: r.maxY))
        content.op("/\(name) Do")
        content.op("Q")
    }

    // MARK: Groups

    func writeGroup(_ group: FlatGroup) {
        content.op("q")
        if let clip = group.clip {
            content.path(clip.path.applying(clip.transform))
            content.op(clip.rule == .evenOdd ? "W* n" : "W n")
        }
        if group.opacity < 1 || group.softMask != nil, let bounds = FlatNode.group(FlatGroup(children: group.children)).bounds {
            let mask = group.softMask.map { mask in
                luminosityMask(mask.gradient, frame: mask.frame, bounds: mask.bounds) { mask.value(at: $0) }
            }
            setState(fillAlpha: group.opacity, strokeAlpha: group.opacity, softMask: mask, maskKey: mask == nil ? "" : "mask\(objects.count)")
            let form = PDFStreamWriter(build: build, patternBase: patternBase)
            for child in group.children {
                form.write(child)
            }
            links += form.links
            let object = objects.addStream([
                ("Type", .name("XObject")), ("Subtype", .name("Form")),
                ("BBox", .rect(bounds.minX, bounds.minY, bounds.maxX, bounds.maxY)),
                ("Group", .dictionary([("S", .name("Transparency")), ("I", .bool(true))])),
                ("Resources", form.resources.value),
            ], data: form.content.data)
            let name = resources.name("XObject", prefix: "Fm", key: String(object)) { .reference(object) }
            content.op("/\(name) Do")
        } else {
            for child in group.children {
                write(child)
            }
        }
        content.op("Q")
    }
}
