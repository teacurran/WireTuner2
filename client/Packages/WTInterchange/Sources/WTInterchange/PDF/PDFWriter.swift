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
// links from attached URLs; page boxes; document info and XMP metadata; layers as optional content
// groups (IO-029); PDF/X-1a and PDF/X-4 identification, output intents and CMYK conversion through a
// `CMYKConverter` (IO-026); note comments, bookmarks from page names and AES encryption with open
// and permissions passwords (IO-027); the embedded document package (IO-028); spot colours as
// `/Separation` spaces (FX-012); the cross-reference table.  Linearization and object streams are
// reported, not written.

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
    /// Converts colours and images under *Convert to CMYK* and names the PDF/X output intent.
    public var cmyk: any CMYKConverter

    public init(options: PDFOptions = .defaults, cmyk: any CMYKConverter = ProfileCMYKConverter()) {
        self.options = options
        self.cmyk = cmyk
    }

    /// `pages` (flattened from `scene`'s pages, in order) as a PDF file, and notes for the
    /// export summary.
    public func write(_ pages: [FlatPage], scene: ExportScene) -> (data: Data, notes: [String]) {
        PDFDocumentBuild(options: options, scene: scene, cmyk: cmyk).write(pages)
    }
}

/// One file being written.
final class PDFDocumentBuild {
    let options: PDFOptions
    let scene: ExportScene
    let cmyk: any CMYKConverter
    let objects: PDFObjects
    let fonts: PDFFontRegistry
    var notes: [String] = []
    private var iccObjects: [String: Int] = [:]
    private var images: [ObjectIdentifier: (object: Int, image: CGImage)] = [:]
    var wideClipped = 0
    var wideKept = 0
    var outlinedFonts = Set<String>()
    /// Colours and images converted to CMYK.
    var convertedColors = Set<Color>()
    var convertedImages = 0
    /// Optional content groups by layer node, in first-use order.
    private(set) var layerGroups: [(node: NodeID, object: Int)] = []
    /// The document page numbers of the exported pages, in order (page links, WEB-023).
    lazy var pageNumbers: [Int] = WebLinks.pageNumbers(scene)
    lazy var pageNumberSet = Set(pageNumbers)
    /// Whether a page link was written: the catalog then names each page's destination.
    var writesPageDestinations = false

    init(options: PDFOptions, scene: ExportScene, cmyk: any CMYKConverter = ProfileCMYKConverter()) {
        self.options = options
        self.scene = scene
        self.cmyk = cmyk.resolved(for: scene)
        objects = PDFObjects(compress: options.compressContent)
        fonts = PDFFontRegistry(objects: objects, embedAll: options.fonts == .embedFull)
        if options.encrypts {
            objects.encryption = PDFEncryption(
                revision: options.version == .v2_0 ? .r6 : .r4, userPassword: options.openPassword, ownerPassword: options.permissionsPassword,
                permissions: PDFEncryption.permissions(printing: options.allowPrinting, copying: options.allowCopying, editing: options.allowEditing)
            )
        }
    }

    /// Whether every colour is written as DeviceCMYK.
    var cmykOutput: Bool { options.colors == .convertToCMYK }

    func write(_ pages: [FlatPage]) -> (data: Data, notes: [String]) {
        let pagesObject = objects.reserve()
        var pageObjects: [Int] = []
        var pageHeights: [Double] = []
        for (index, page) in pages.enumerated() {
            let documentBleed = index < scene.pages.count ? scene.pages[index].bleed : 0
            let bleed = options.pageSize == .pagePlusBleed ? (options.useDocumentBleed ? documentBleed : options.bleedPoints) : 0
            pageObjects.append(writePage(page, bleed: bleed, parent: pagesObject))
            pageHeights.append(page.bounds.height + 2 * bleed)
        }
        fonts.finish()
        objects.set(pagesObject, .dictionary([
            ("Type", .name("Pages")),
            ("Kids", .array(pageObjects.map { .reference($0) })),
            ("Count", .int(pageObjects.count)),
        ]))
        var catalog: [(String, PDFValue)] = [("Type", .name("Catalog")), ("Pages", .reference(pagesObject))]
        if writesPageDestinations {
            // `/D /pageN` in a GoTo action names the page's fit-page destination.
            catalog.append(("Dests", .dictionary(zip(pageNumbers, pageObjects).map { ("page\($0)", .array([.reference($1), .name("Fit")])) })))
        }
        var info: Int?
        if options.includeDocumentInfo {
            info = objects.add(infoDictionary())
            catalog.append(("Metadata", .reference(objects.addStream([("Type", .name("Metadata")), ("Subtype", .name("XML"))], data: xmp(), raw: true))))
        }
        if let language = scene.info.effectiveLanguage {
            catalog.append(("Lang", .string(language)))
        }
        if options.bookmarksFromPageNames, let outlines = outlines(pages: pageObjects, heights: pageHeights) {
            catalog += [("Outlines", .reference(outlines)), ("PageMode", .name("UseOutlines"))]
        }
        if options.embedPackage {
            if let package = scene.package {
                let file = embeddedPackage(EmbeddedPackage.slimmed(package))
                catalog += [("Names", .dictionary([("EmbeddedFiles", .dictionary([("Names", .array([.string(EmbeddedPackage.fileName(scene.name)), .reference(file)]))]))])), ("AF", .array([.reference(file)]))]
            } else {
                notes.append("no document package was supplied; the PDF does not embed the document")
            }
        }
        if !layerGroups.isEmpty {
            let groups = PDFValue.array(layerGroups.map { .reference($0.object) })
            catalog.append(("OCProperties", .dictionary([
                ("OCGs", groups),
                ("D", .dictionary([("Name", .string("Layers")), ("Order", groups), ("ON", groups), ("OFF", .array([])), ("BaseState", .name("ON"))])),
            ])))
        }
        if options.standard != .none {
            let intent = PDFOutputIntent(subtype: "GTS_PDFX", identifier: cmyk.outputConditionIdentifier, condition: cmyk.name, profile: cmyk.iccProfile, components: 4)
            catalog.append(("OutputIntents", .array([intent.value(objects: objects)])))
        } else if wideKept > 0 {
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
            notes.append("\(wideClipped) wide-gamut color\(wideClipped == 1 ? "" : "s") gamut-mapped into sRGB (Display P3 needs PDF 1.7 with colors kept and profiles embedded)")
        }
        for name in outlinedFonts.sorted() {
            if fonts.uninstanceableNames.contains(name) {
                notes.append("font \(name) converted to outlines: variable font (only TrueType variable fonts are instanced)")
            } else {
                notes.append("font \(name) does not allow embedding; its text is outlined")
            }
        }
        if options.linearize {
            notes.append("fast web view (linearization) is not written yet; the file is not linearized")
        }
        if options.layers && !options.writesLayers {
            notes.append("PDF layers need PDF 1.5 or later; layers are flattened into the page")
        }
        if !convertedColors.isEmpty || convertedImages > 0 {
            notes.append("\(convertedColors.count) color\(convertedColors.count == 1 ? "" : "s") and \(convertedImages) image\(convertedImages == 1 ? "" : "s") converted to CMYK with the \(cmyk.name) profile")
        }
        for problem in PDFXCheck.violations(objects.dictionaries, standard: options.standard) {
            notes.append("PDF/X check: \(problem)")
        }
        var encrypt: Int?
        if let encryption = objects.encryption {
            let object = objects.reserve()
            encryption.exempt = object
            objects.set(object, encryption.dictionary)
            encrypt = object
            notes.append(encryption.revision == .r6 ? "encrypted with AES-256" : "encrypted with AES-128")
            if !(options.openPassword + options.permissionsPassword).unicodeScalars.allSatisfy(\.isASCII) {
                notes.append("a password holds characters outside ASCII: Preview may not accept it\(encryption.revision == .r4 ? ", and PDF readers disagree on how PDF 1.7 and earlier encode it" : "")")
            }
            if options.headerVersion != options.version.rawValue {
                notes.append("passwords need AES, so the file is PDF 1.6 rather than \(options.version.rawValue)")
            }
        }
        return (objects.file(version: options.headerVersion, root: root, info: info, encrypt: encrypt), notes)
    }

    /// The outline: one bookmark per named page, opening the page whole; nil when no page has
    /// a name.
    func outlines(pages: [Int], heights: [Double]) -> Int? {
        let named = scene.pages.prefix(pages.count).enumerated().compactMap { index, page in
            page.name.flatMap { $0.isEmpty ? nil : (index, $0) }
        }
        guard !named.isEmpty else {
            return nil
        }
        let root = objects.reserve()
        let items = named.map { _ in objects.reserve() }
        for (position, (index, name)) in named.enumerated() {
            var entries: [(String, PDFValue)] = [
                ("Title", .string(name)), ("Parent", .reference(root)),
                ("Dest", .array([.reference(pages[index]), .name("XYZ"), .int(0), .real(heights[index]), .null])),
            ]
            if position > 0 {
                entries.append(("Prev", .reference(items[position - 1])))
            }
            if position + 1 < items.count {
                entries.append(("Next", .reference(items[position + 1])))
            }
            objects.set(items[position], .dictionary(entries))
        }
        objects.set(root, .dictionary([("Type", .name("Outlines")), ("First", .reference(items[0])), ("Last", .reference(items[items.count - 1])), ("Count", .int(items.count))]))
        return root
    }

    /// The package as an embedded file with its file specification (`AFRelationship /Source`:
    /// the document the PDF was made from), returning the specification.
    func embeddedPackage(_ package: Data) -> Int {
        let stream = objects.addStream([
            ("Type", .name("EmbeddedFile")), ("Subtype", .name(EmbeddedPackage.mediaType)),
            ("Params", .dictionary([("Size", .int(package.count)), ("ModDate", .string(pdfDate(Date())))])),
        ], data: package, raw: true)
        let name = EmbeddedPackage.fileName(scene.name)
        return objects.add(.dictionary([
            ("Type", .name("Filespec")), ("F", .string(name)), ("UF", .string(name)),
            ("Desc", .string(EmbeddedPackage.description)),
            ("EF", .dictionary([("F", .reference(stream)), ("UF", .reference(stream))])),
            ("AFRelationship", .name("Source")),
        ]))
    }

    /// The optional content group of a layer node.
    func layerGroup(_ node: NodeID) -> Int {
        if let existing = layerGroups.first(where: { $0.node == node }) {
            return existing.object
        }
        let name = scene.nodes[node]?.name.flatMap { $0.isEmpty ? nil : $0 } ?? "Layer \(layerGroups.count + 1)"
        let object = objects.add(.dictionary([
            ("Type", .name("OCG")),
            ("Name", .string(name)),
            ("Usage", .dictionary([("CreatorInfo", .dictionary([("Creator", .string(scene.info.creator)), ("Subtype", .name("Artwork"))]))])),
        ]))
        layerGroups.append((node, object))
        return object
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
            if options.writesLayers, let id = node.node, scene.nodes[id]?.isLayer == true {
                let group = layerGroup(id)
                let name = stream.resources.name("Properties", prefix: "MC", key: String(group)) { .reference(group) }
                stream.content.op("/OC /\(name) BDC")
                stream.write(node)
                stream.content.op("EMC")
            } else {
                stream.write(node)
            }
        }
        let contents = objects.addStream([], data: stream.content.data)
        var dictionary: [(String, PDFValue)] = [
            ("Type", .name("Page")),
            ("Parent", .reference(parent)),
            ("MediaBox", .rect(0, 0, width, height)),
            ("TrimBox", .rect(bleed, bleed, bleed + page.bounds.width, bleed + page.bounds.height)),
        ]
        if bleed > 0 || options.standard != .none {
            dictionary.append(("BleedBox", .rect(0, 0, width, height)))
        }
        // PDF/X pages carry a TrimBox or an ArtBox, never both.
        if options.standard == .none, let art = FlatNode.union(page.nodes.compactMap(\.bounds))?.intersection(page.bounds).nonEmpty {
            let box = art.applying(base)
            dictionary.append(("ArtBox", .rect(box.minX, box.minY, box.maxX, box.maxY)))
        }
        dictionary += [("Resources", stream.resources.value), ("Contents", .reference(contents))]
        if options.linksFromURLs {
            // Text-range links: one annotation per line of the range (WEB-005).
            for node in scene.textLinks.keys.sorted() {
                for link in scene.textLinks[node]! {
                    guard let href = WebLinks.href(link.url) else { continue }
                    for rect in link.rects {
                        if let box = rect.intersection(page.bounds).nonEmpty { stream.links.append((.uri(href), link.alt, box)) }
                    }
                }
            }
        }
        var annotations = stream.links.map { link -> PDFValue in
            let box = link.bounds.applying(base)
            let action: PDFValue
            switch link.action {
            case .uri(let url):
                action = .dictionary([("S", .name("URI")), ("URI", .string(url))])
            case .page(let number):
                writesPageDestinations = true
                action = .dictionary([("S", .name("GoTo")), ("D", .name("page\(number)"))])
            }
            var entries: [(String, PDFValue)] = [
                ("Type", .name("Annot")),
                ("Subtype", .name("Link")),
                ("Rect", .rect(box.minX, box.minY, box.maxX, box.maxY)),
                ("Border", .array([.int(0), .int(0), .int(0)])),
                ("A", action),
            ]
            if let alt = link.alt { entries.append(("Contents", .string(alt))) }
            return .reference(objects.add(.dictionary(entries)))
        }
        // A note is a closed comment icon whose top-left corner is the object's.
        annotations += stream.notes.map { note -> PDFValue in
            let corner = base.apply(Point(x: note.bounds.minX, y: note.bounds.minY))
            var entries: [(String, PDFValue)] = [
                ("Type", .name("Annot")), ("Subtype", .name("Text")),
                ("Rect", .rect(corner.x, corner.y - 20, corner.x + 20, corner.y)),
                ("Contents", .string(note.text)), ("Name", .name("Comment")), ("Open", .bool(false)), ("F", .int(4)),
            ]
            if let title = note.title {
                entries.append(("T", .string(title)))
            }
            return .reference(objects.add(.dictionary(entries)))
        }
        if options.commentsAsAnnotations {
            annotations += commentAnnotations(on: page.bounds, base: base)
        }
        if !annotations.isEmpty {
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
        if cmykOutput {
            let object = cmykImageObject(picture)
            images[key] = (object, image.image)
            return object
        }
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

    /// An image converted to DeviceCMYK (lossless, with its alpha as a soft mask where it has one).
    func cmykImageObject(_ picture: CGImage) -> Int {
        convertedImages += 1
        let pixels = RGBAPixels(picture)
        var dictionary: [(String, PDFValue)] = [
            ("Type", .name("XObject")), ("Subtype", .name("Image")), ("Width", .int(picture.width)), ("Height", .int(picture.height)),
            ("BitsPerComponent", .int(8)), ("ColorSpace", .name("DeviceCMYK")),
        ]
        if !pixels.isOpaque {
            let mask: [(String, PDFValue)] = [
                ("Type", .name("XObject")), ("Subtype", .name("Image")), ("Width", .int(pixels.width)), ("Height", .int(pixels.height)),
                ("ColorSpace", .name("DeviceGray")), ("BitsPerComponent", .int(8)),
            ]
            dictionary.append(("SMask", .reference(objects.addStream(mask, data: pixels.alpha, raw: options.colorImages == .none))))
        }
        // Unpremultiplied colours: the soft mask carries the coverage.
        return objects.addStream(dictionary, data: cmyk.cmykPixels(PDFDocumentBuild.opaqueRGB(pixels)), raw: options.colorImages == .none)
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
        let now = pdfDate(Date())
        if let writer = info.metadataWriter(documentName: scene.name) {
            entries = writer.pdfInfo.map { ($0.key, .string($0.value)) }
            entries += [("Producer", .string("WireTuner PDF writer")), ("CreationDate", .string(now)), ("ModDate", .string(now))]
        } else {
            let fields: [(String, String?)] = [("Title", info.title), ("Author", info.author), ("Subject", info.subject ?? info.description)]
            for (key, value) in fields {
                if let value {
                    entries.append((key, .string(value)))
                }
            }
            if !info.keywords.isEmpty {
                entries.append(("Keywords", .string(info.keywords.joined(separator: ", "))))
            }
            entries += [("Creator", .string(info.creator)), ("Producer", .string("WireTuner PDF writer")), ("CreationDate", .string(now)), ("ModDate", .string(now))]
        }
        switch options.standard {
        case .none:
            break
        case .pdfX1a2001:
            entries += [("GTS_PDFXVersion", .string("PDF/X-1:2001")), ("GTS_PDFXConformance", .string("PDF/X-1a:2001")), ("Trapped", .name("False"))]
        case .pdfX4_2010:
            entries += [("GTS_PDFXVersion", .string("PDF/X-4")), ("Trapped", .name("False"))]
        }
        if options.standard != .none && info.title == nil && info.metadata == nil {
            entries.insert(("Title", .string(scene.name)), at: 0)
        }
        return .dictionary(entries)
    }

    /// The XMP packet: Dublin Core, XMP basic and PDF properties.
    func xmp() -> Data {
        let info = scene.info
        func escape(_ text: String) -> String { XMLStream.escape(text, attribute: false) }
        var dc = ""
        if let title = info.title ?? (options.standard != .none ? scene.name : nil) {
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
        var tool = "<xmp:CreatorTool>\(escape(info.creator))</xmp:CreatorTool>"
        if let writer = info.metadataWriter(documentName: scene.name) {
            dc = writer.xmpProperties(includeTool: false)
            tool = "<xmp:CreatorTool>\(escape(writer.creatorTool))</xmp:CreatorTool>"
        }
        let formatter = ISO8601DateFormatter()
        let now = formatter.string(from: Date())
        var standard = ""
        switch options.standard {
        case .none:
            break
        case .pdfX1a2001:
            standard = "<pdfxid:GTS_PDFXVersion>PDF/X-1:2001</pdfxid:GTS_PDFXVersion><pdfx:GTS_PDFXConformance>PDF/X-1a:2001</pdfx:GTS_PDFXConformance>"
        case .pdfX4_2010:
            standard = "<pdfxid:GTS_PDFXVersion>PDF/X-4</pdfxid:GTS_PDFXVersion>"
        }
        if options.standard != .none {
            let id = "uuid:" + UUID().uuidString.lowercased()
            standard += "<pdf:Trapped>False</pdf:Trapped><xmpMM:DocumentID>\(id)</xmpMM:DocumentID><xmpMM:InstanceID>\(id)</xmpMM:InstanceID>"
            standard += "<xmpMM:VersionID>1</xmpMM:VersionID><xmpMM:RenditionClass>default</xmpMM:RenditionClass>"
        }
        let packet = """
        <?xpacket begin="\u{FEFF}" id="W5M0MpCehiHzreSzNTczkc9d"?>
        <x:xmpmeta xmlns:x="adobe:ns:meta/"><rdf:RDF xmlns:rdf="http://www.w3.org/1999/02/22-rdf-syntax-ns#">\
        <rdf:Description rdf:about="" xmlns:dc="http://purl.org/dc/elements/1.1/" xmlns:xmp="http://ns.adobe.com/xap/1.0/" xmlns:pdf="http://ns.adobe.com/pdf/1.3/" \
        xmlns:xmpMM="http://ns.adobe.com/xap/1.0/mm/" xmlns:pdfxid="http://www.npes.org/pdfx/ns/id/" xmlns:pdfx="http://ns.adobe.com/pdfx/1.3/" \
        xmlns:xmpRights="http://ns.adobe.com/xap/1.0/rights/" xmlns:photoshop="http://ns.adobe.com/photoshop/1.0/" xmlns:Iptc4xmpCore="http://iptc.org/std/Iptc4xmpCore/1.0/xmlns/">\
        <dc:format>application/pdf</dc:format>\(dc)\
        \(tool)<xmp:CreateDate>\(now)</xmp:CreateDate><xmp:ModifyDate>\(now)</xmp:ModifyDate>\
        <pdf:Producer>WireTuner PDF writer</pdf:Producer>\(standard)</rdf:Description></rdf:RDF></x:xmpmeta>
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
    /// Links (URLs completed by `WebLinks.href`, or page links), their alt text and pasteboard
    /// bounds.
    var links: [(action: ExportLinkAction, alt: String?, bounds: Rect)] = []
    /// Object notes, with the object's name and pasteboard bounds.
    var notes: [(text: String, title: String?, bounds: Rect)] = []

    init(build: PDFDocumentBuild, patternBase: AffineTransform) {
        self.build = build
        self.patternBase = patternBase
    }

    var options: PDFOptions { build.options }
    var objects: PDFObjects { build.objects }

    func write(_ node: FlatNode) {
        let info = build.scene.info(for: node.node)
        if options.linksFromURLs, let action = WebLinks.action(info, pages: build.pageNumberSet), let bounds = node.bounds {
            links.append((action, info?.linkAlt, bounds))
        }
        if options.notesAsComments, let note = info?.note, !note.isEmpty, let bounds = node.bounds {
            notes.append((note, info?.name, bounds))
        }
        switch node {
        case .path(let path): writePath(path)
        case .text(let text): writeText(text)
        case .image(let image): writeImage(image)
        case .group(let group): writeGroup(group)
        }
    }

    // MARK: Colour

    /// Selects `color` for filling (or stroking) in the space the options keep it in, and
    /// returns its alpha.  *Keep*: sRGB as sRGB, CMYK as DeviceCMYK, CIELAB as `/Lab` (D50), and
    /// Display P3, OKLab and extended sRGB through the Display P3 profile at PDF 1.7 and later --
    /// otherwise gamut-mapped into sRGB and counted.  *Convert to RGB* gamut-maps everything into
    /// sRGB; *Convert to CMYK* converts through the CMYK converter.
    func setColor(_ color: Color, stroke: Bool) -> Double {
        let alpha = min(max(color.alpha, 0), 1)
        if let spot = color.spot, options.preserveSpot, options.colors != .convertToRGB {
            let name = separation(spot, alternate: color)
            content.op("/\(name) \(stroke ? "CS" : "cs") \(PDFContent.n(spot.tint)) \(stroke ? "SCN" : "scn")")
            return alpha
        }
        if build.cmykOutput {
            build.convertedColors.insert(color)
            content.op(build.cmyk.cmyk(color).map(PDFContent.n).joined(separator: " ") + (stroke ? " K" : " k"))
            return alpha
        }
        let keep = options.colors == .keep
        if keep && color.space == .cmyk {
            let c = color.clampedToSpace.components
            content.op([c.x, c.y, c.z, c.w].map(PDFContent.n).joined(separator: " ") + (stroke ? " K" : " k"))
            return alpha
        }
        if keep && color.space == .lab {
            let name = resources.name("ColorSpace", prefix: "CS", key: "lab") {
                .array([.name("Lab"), .dictionary([("WhitePoint", .numbers([0.9642, 1, 0.8249])), ("Range", .numbers([-128, 127, -128, 127]))])])
            }
            let c = color.clampedToSpace.components
            content.op("/\(name) \(stroke ? "CS" : "cs") \([c.x, min(c.y, 127), min(c.z, 127)].map(PDFContent.n).joined(separator: " ")) \(stroke ? "SC" : "sc")")
            return alpha
        }
        let rgb = ColorMath.sRGBFallback(color)
        var components = [rgb.red, rgb.green, rgb.blue]
        var space = CGColorSpace.sRGB
        let wide = ColorMath.isWide(color)
        if keep && options.keepsDisplayP3 && (wide || color.space == .displayP3 || color.space == .oklab) {
            let p3 = ColorMath.displayP3(color)
            components = [p3.x, p3.y, p3.z]
            space = CGColorSpace.displayP3
            build.wideKept += 1
        } else if wide {
            build.wideClipped += 1
        }
        let name = colorSpace(space)
        let values = components.map(PDFContent.n).joined(separator: " ")
        content.op("/\(name) \(stroke ? "CS" : "cs") \(values) \(stroke ? "SC" : "sc")")
        return alpha
    }

    /// The `/Separation` colour space of a spot ink (FX-012): tint 0 is no ink, tint 1 the
    /// ink's process alternate at full strength (`alternate` is the colour at the ink's tint,
    /// untinted here in its own space); Registration is `/All`.
    func separation(_ ink: SpotInk, alternate color: Color) -> String {
        let registration = ink.identity == .registration
        let name = registration ? "All" : ink.name
        return resources.name("ColorSpace", prefix: "CS", key: "separation|" + name) {
            var full = color
            if ink.tint > 0, ink.tint < 1 {
                let white: SIMD4<Double>
                switch color.space {
                case .cmyk: white = .zero
                case .lab: white = SIMD4(100, 0, 0, 0)
                case .oklab: white = SIMD4(1, 0, 0, 0)
                case .sRGB, .displayP3: white = SIMD4(1, 1, 1, 0)
                }
                full.components = white + (color.components - white) / ink.tint
            }
            full.spot = nil
            let inks = registration ? [1.0, 1, 1, 1] : (full.space == .cmyk ? [full.components.x, full.components.y, full.components.z, full.components.w].map { min(max($0, 0), 1) } : build.cmyk.cmyk(full))
            let function = PDFValue.dictionary([
                ("FunctionType", .int(2)), ("Domain", .numbers([0, 1])), ("C0", .numbers([0, 0, 0, 0])), ("C1", .numbers(inks)), ("N", .int(1)),
            ])
            return .array([.name("Separation"), .name(name), .name("DeviceCMYK"), function])
        }
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
        if build.cmykOutput {
            build.convertedColors.formUnion(gradient.gradient.stops.map(\.color))
        }
        let shading = shadingObject(gradient, components: build.cmykOutput ? 4 : 3) { t in
            let color = gradient.color(at: t)
            if self.build.cmykOutput {
                return self.build.cmyk.cmyk(color)
            }
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
        let space: PDFValue
        switch components {
        case 1: space = .name("DeviceGray")
        case 4: space = .name("DeviceCMYK")
        default: space = options.embedProfiles ? .array([.name("ICCBased"), .reference(build.icc(CGColorSpace.sRGB))]) : .name("DeviceRGB")
        }
        var entries: [(String, PDFValue)] = [("ColorSpace", space)]
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
            notes += form.notes
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
