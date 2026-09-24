import Foundation
import WTInterchange

/// A choice in an options pop-up: the value and its title.
struct OptionChoice<Value: Hashable & Sendable>: Hashable, Identifiable, Sendable {
    var value: Value
    var title: String
    var id: String { title }

    init(_ value: Value, _ title: String) {
        self.value = value
        self.title = title
    }
}

/// The pop-ups' choices, in menu order (export-pdf.adoc, export-vector.adoc, export-bitmap.adoc,
/// export-text.adoc, animation.adoc).
enum ExportChoices {
    static let pdfVersions = PDFOptions.Version.allCases.map { OptionChoice($0, "PDF \($0.rawValue)") }
    static let pdfStandards = [OptionChoice(PDFOptions.Standard.none, "None"), OptionChoice(.pdfX1a2001, "PDF/X-1a:2001"), OptionChoice(.pdfX4_2010, "PDF/X-4:2010")]
    static let pdfImages = [OptionChoice(PDFOptions.ImageCompression.auto, "Automatic"), OptionChoice(.jpeg, "JPEG"), OptionChoice(.lossless, "Lossless"),
                            OptionChoice(.none, "None")]
    static let pdfFonts = [OptionChoice(PDFOptions.Fonts.embedSubset, "Embed subsets"), OptionChoice(.embedFull, "Embed whole fonts"),
                           OptionChoice(.outlines, "Convert text to outlines")]
    static let colors = [OptionChoice(PDFOptions.Colors.keep, "Keep document colors"), OptionChoice(.convertToCMYK, "Convert to CMYK"),
                         OptionChoice(.convertToRGB, "Convert to RGB")]
    static let pdfPageSizes = [OptionChoice(PDFOptions.PageSize.page, "Page"), OptionChoice(.pagePlusBleed, "Page plus bleed")]
    static let epsLevels = [OptionChoice(EPSOptions.Level.level2, "Level 2"), OptionChoice(.level3, "Level 3")]
    static let epsPreviews = [OptionChoice(EPSOptions.Preview.none, "None"), OptionChoice(.tiff72, "TIFF (72 ppi)"), OptionChoice(.tiff144, "TIFF (144 ppi)")]
    static let epsFonts = [OptionChoice(EPSOptions.Fonts.embedSubset, "Embed subsets"), OptionChoice(.embedFull, "Embed whole fonts"),
                           OptionChoice(.outlines, "Convert text to outlines"), OptionChoice(.reference, "Name only")]
    static let epsColors = [OptionChoice(EPSOptions.Colors.keep, "Keep document colors"), OptionChoice(.convertToCMYK, "Convert to CMYK"),
                            OptionChoice(.convertToRGB, "Convert to RGB")]
    static let svgText = [OptionChoice(SVGOptions.Text.asText, "Text"), OptionChoice(.outlines, "Outlines"), OptionChoice(.asTextEmbedFonts, "Text with embedded fonts")]
    static let svgIDs = [OptionChoice(SVGOptions.Ids.fromNames, "From object names"), OptionChoice(.generated, "Generated"), OptionChoice(.none, "None")]
    static let svgStyling = [OptionChoice(SVGOptions.Styling.presentationAttributes, "Presentation attributes"), OptionChoice(.cssClasses, "CSS classes"),
                             OptionChoice(.inlineStyle, "Inline styles")]
    static let svgImages = [OptionChoice(SVGOptions.Images.embed, "Embed"), OptionChoice(.link, "Link"), OptionChoice(.linkOriginals, "Link originals")]
    static let svgUnits = ["pt", "px", "mm", "in"].map { OptionChoice($0, $0) }
    static let dxfVersions = [OptionChoice(DXFOptions.Version.v2018, "AutoCAD 2018"), OptionChoice(.v2000, "AutoCAD 2000"), OptionChoice(.r12, "R12")]
    static let dxfUnits = [OptionChoice(DXFOptions.Units.millimeters, "Millimeters"), OptionChoice(.inches, "Inches"), OptionChoice(.points, "Points"),
                           OptionChoice(.document, "Document units")]
    static let backgrounds = [OptionChoice(BitmapCommonOptions.Background.transparent, "Transparent"), OptionChoice(.pageColor, "Page color"),
                              OptionChoice(.white, "White")]
    static let colorModes = [OptionChoice(BitmapCommonOptions.ColorMode.rgb, "RGB"), OptionChoice(.gray, "Grayscale"), OptionChoice(.cmyk, "CMYK")]
    static let rgbSpaces = [OptionChoice(BitmapCommonOptions.RGBSpace.auto, "Automatic"), OptionChoice(.sRGB, "sRGB"), OptionChoice(.displayP3, "Display P3"),
                            OptionChoice(.workingRGB, "Working RGB")]
    static let antiAliasing = [OptionChoice(1, "None"), OptionChoice(2, "2×"), OptionChoice(3, "3×"), OptionChoice(4, "4×")]
    static let palettes = [OptionChoice(PaletteChoice.adaptive, "Adaptive"), OptionChoice(.exact, "Exact"), OptionChoice(.web216, "Web 216"),
                           OptionChoice(.grayscale, "Grayscale")]
    static let pngBits = [OptionChoice(8, "8-bit palette"), OptionChoice(24, "24-bit"), OptionChoice(32, "32-bit"), OptionChoice(48, "48-bit"), OptionChoice(64, "64-bit")]
    static let tiffCompression = [OptionChoice(TIFFOptions.Compression.none, "None"), OptionChoice(.lzw, "LZW"), OptionChoice(.zip, "ZIP"), OptionChoice(.jpeg, "JPEG")]
    static let bmpBits = [OptionChoice(24, "24-bit"), OptionChoice(32, "32-bit")]
    static let targaBits = [OptionChoice(8, "8-bit gray"), OptionChoice(16, "16-bit"), OptionChoice(24, "24-bit"), OptionChoice(32, "32-bit")]
    static let psdBits = [OptionChoice(8, "8 bits per channel"), OptionChoice(16, "16 bits per channel")]
    static let encodings = [OptionChoice(PlainTextOptions.Encoding.utf8, "UTF-8"), OptionChoice(.utf8BOM, "UTF-8 with BOM"), OptionChoice(.utf16, "UTF-16")]
    static let loops = [OptionChoice(AnimationLoopChoice.document, "As the document says"), OptionChoice(.forever, "Forever"), OptionChoice(.count, "Times")]
    static let animationBackgrounds = [OptionChoice(AnimationBackgroundChoice.document, "As the document says"), OptionChoice(.pageColor, "Page color"),
                                       OptionChoice(.white, "White"), OptionChoice(.transparent, "Transparent")]
}

/// *Loop* without its count.
enum AnimationLoopChoice: Hashable, Sendable {
    case document
    case forever
    case count
}

/// *Background*, with the document's own choice.
enum AnimationBackgroundChoice: Hashable, Sendable {
    case document
    case pageColor
    case white
    case transparent
}

/// The options sheets' controls that do not map one-to-one onto a stored field: each reads and
/// writes the chosen format's options.
extension ExportSheetModel {
    /// The chosen bitmap format's shared options.
    var bitmapCommon: BitmapCommonOptions {
        get { settings.options.common(settings.format) }
        set { settings.options.setCommon(newValue, for: settings.format) }
    }

    /// Whether files are written at `scale`.
    func hasScale(_ scale: Double) -> Bool {
        bitmapCommon.scales.contains(scale)
    }

    /// Adds or removes `scale`; the last one stays.
    func setScale(_ scale: Double, _ on: Bool) {
        var scales = bitmapCommon.scales.filter { $0 != scale }
        if on { scales.append(scale) }
        bitmapCommon.scales = scales.isEmpty ? [scale] : scales.sorted()
    }

    var scale1x: Bool {
        get { hasScale(1) }
        set { setScale(1, newValue) }
    }

    var scale2x: Bool {
        get { hasScale(2) }
        set { setScale(2, newValue) }
    }

    var scale3x: Bool {
        get { hasScale(3) }
        set { setScale(3, newValue) }
    }

    /// The palette used by the chosen format's 8-bit depth (GIF, PNG 8, TIFF 8).
    var palette: PaletteSettings {
        get {
            switch settings.format {
            case .gif: settings.options.gif.palette
            case .tiff: settings.options.tiff.palette
            default: settings.options.png.palette
            }
        }
        set {
            switch settings.format {
            case .gif: settings.options.gif.palette = newValue
            case .tiff: settings.options.tiff.palette = newValue
            default: settings.options.png.palette = newValue
            }
        }
    }

    // MARK: Animation

    /// The chosen animation format's shared options.
    var animationCommon: AnimationCommonOptions {
        get { settings.options.animation(settings.format) }
        set { settings.options.setAnimation(newValue, for: settings.format) }
    }

    /// *Size*: an explicit pixel size rather than points × scale.
    var animationUsesPixels: Bool {
        get {
            if case .pixels = animationCommon.size { return true }
            return false
        }
        set { animationCommon.size = newValue ? .pixels(width: animationWidth, height: animationHeight) : .scale(animationScale) }
    }

    var animationScale: Double {
        get {
            if case .scale(let factor) = animationCommon.size { return factor }
            return 1
        }
        set { animationCommon.size = .scale(newValue) }
    }

    var animationWidth: Int {
        get {
            if case .pixels(let width, _) = animationCommon.size { return width }
            return 640
        }
        set { animationCommon.size = .pixels(width: newValue, height: animationHeight) }
    }

    var animationHeight: Int {
        get {
            if case .pixels(_, let height) = animationCommon.size { return height }
            return 480
        }
        set { animationCommon.size = .pixels(width: animationWidth, height: newValue) }
    }

    /// *Frame rate*: the document's, or the value typed.
    var animationUsesDocumentFPS: Bool {
        get { animationCommon.fps == nil }
        set { animationCommon.fps = newValue ? nil : 12 }
    }

    var animationFPS: Double {
        get { animationCommon.fps ?? 12 }
        set { animationCommon.fps = newValue }
    }

    var animationLoop: AnimationLoopChoice {
        get {
            switch animationCommon.loop {
            case .document: .document
            case .forever: .forever
            case .count: .count
            }
        }
        set {
            switch newValue {
            case .document: animationCommon.loop = .document
            case .forever: animationCommon.loop = .forever
            case .count: animationCommon.loop = .count(animationLoopCount)
            }
        }
    }

    var animationLoopCount: Int {
        get {
            if case .count(let count) = animationCommon.loop { return count }
            return 1
        }
        set { animationCommon.loop = .count(max(newValue, 1)) }
    }

    var animationBackground: AnimationBackgroundChoice {
        get {
            switch animationCommon.background {
            case nil: .document
            case .pageColor?: .pageColor
            case .white?: .white
            case .transparent?: .transparent
            }
        }
        set {
            let values: [AnimationBackgroundChoice: ExportAnimation.Background] = [.pageColor: .pageColor, .white: .white, .transparent: .transparent]
            animationCommon.background = values[newValue]
        }
    }

    /// *Pages*: the page numbers to take frames from, empty for every frame.
    var animationPages: String {
        get { (animationCommon.pages ?? []).sorted().map { String($0 + 1) }.joined(separator: ", ") }
        set { animationCommon.pages = (try? PageRange.parse(newValue, pageCount: context.pages.count)).map(Set.init) }
    }

    // MARK: PDF

    /// Interactive features are off with a PDF/X standard (export-pdf.adoc, "Interactive").
    var pdfInteractiveAllowed: Bool { settings.options.pdf.standard == .none }

    /// What a PDF/X standard will change, listed under the pop-up.
    var pdfStandardNote: String? {
        switch settings.options.pdf.standard {
        case .none: nil
        case .pdfX1a2001: "Transparency is flattened, colors become CMYK and interactive features are left out."
        case .pdfX4_2010: "Colors are tagged, the bleed box is written and interactive features are left out."
        }
    }

    /// A preset asks for the PDF's passwords at export time.
    var pdfPasswordsAsked: Bool { settings.asksOpenPassword || settings.asksPermissionsPassword }
}
