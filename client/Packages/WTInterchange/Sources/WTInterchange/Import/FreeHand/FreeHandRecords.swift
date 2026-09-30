// FreeHand's records as libfreehand parses them (import-formats.adoc, "FreeHand"; IO-041, D-083).
// The vendored libfreehand (client/Vendor/libfreehand) reads the file into its record collector
// and the bridge writes every record out as JSON; this file is that JSON's Swift shape.  Ids are
// record numbers; coordinates are libfreehand's -- inches, y up, on FreeHand's pasteboard --
// except where a field says otherwise.  Nothing here interprets the records: FreeHandConverter
// does.

import CFreeHand
import Foundation

/// Reading a FreeHand file through libfreehand.
enum FreeHandFile {
    /// Whether `data` is a FreeHand document libfreehand reads: `AGD` or `FH3` at the start, or
    /// inside the `0x1C` records a FreeHand 10 or MX file begins with.
    static func isFreeHand(_ data: Data) -> Bool {
        guard let first = data.first, [0x41, 0x46, 0x1C].contains(first) else { return false }
        return data.withUnsafeBytes { raw in
            wt_freehand_is_supported(raw.bindMemory(to: UInt8.self).baseAddress, raw.count) != 0
        }
    }

    /// The file's records; nil when `data` is not a FreeHand document.
    static func records(_ data: Data) throws -> FreeHandRecords? {
        var length = 0
        let json: UnsafeMutablePointer<CChar>? = data.withUnsafeBytes { raw in
            wt_freehand_export_records(raw.bindMemory(to: UInt8.self).baseAddress, raw.count, &length)
        }
        guard let json else { return nil }
        defer { wt_freehand_free(json) }
        let bytes = Data(bytesNoCopy: json, count: length, deallocator: .none)
        return try JSONDecoder().decode(FreeHandRecords.self, from: bytes)
    }
}

/// A record table: record id to value, decoded from a JSON object keyed by the id's digits.
struct FreeHandTable<Value: Decodable & Sendable>: Decodable, Sendable {
    var values: [Int: Value]

    init(_ values: [Int: Value] = [:]) {
        self.values = values
    }

    init(from decoder: any Decoder) throws {
        let raw = try [String: Value](from: decoder)
        values = Dictionary(uniqueKeysWithValues: raw.compactMap { key, value in Int(key).map { ($0, value) } })
    }

    subscript(_ id: Int) -> Value? { id == 0 ? nil : values[id] }
}

/// Bytes the bridge writes as lower-case hex.
struct FreeHandBytes: Decodable, Hashable, Sendable {
    var data: Data

    init(from decoder: any Decoder) throws {
        let hex = try String(from: decoder)
        var bytes = [UInt8]()
        bytes.reserveCapacity(hex.utf8.count / 2)
        var high: UInt8?
        for character in hex.utf8 {
            let value: UInt8
            switch character {
            case 0x30...0x39: value = character - 0x30
            case 0x61...0x66: value = character - 0x61 + 10
            case 0x41...0x46: value = character - 0x41 + 10
            default: continue
            }
            if let first = high {
                bytes.append(first << 4 | value)
                high = nil
            } else {
                high = value
            }
        }
        data = Data(bytes)
    }
}

/// Every record libfreehand collected, and what the file holds.  A class, so the converter's
/// many lookups share one copy (a struct of this size is copied into every debug frame that
/// reads it, which deep FreeHand nesting multiplies past a thread's stack).
final class FreeHandRecords: Decodable, Sendable {
    /// FreeHand's version: 3, 5, 7, 8, 9, 10 or 11 (MX).
    let version: Int
    /// False when reading stopped before the last record (damage, or a record libfreehand
    /// does not know).
    let complete: Bool
    let recordCount: Int
    let recordsRead: Int
    /// How many records of each type the file holds, by FreeHand's name for the type.
    let recordTypes: [String: Int]
    /// The type of the record reading stopped at.
    let stoppedAt: String?

    /// The union of the pages, [minX, minY, maxX, maxY].
    let pageInfo: [Double]
    /// Each page's rectangle, [minX, minY, maxX, maxY], in record order.
    let pages: [[Double]]
    /// The document's size from the file's tail, [0, 0, width, height].
    let tailPageInfo: [Double]
    let layerList: Int
    /// The `MName` records naming the style keys "stroke", "fill" and "contents".
    let strokeName: Int
    let fillName: Int
    let contentsName: Int

    /// Six coefficients in libfreehand's order (m11, m21, m12, m22, m13, m23): x' = m11 x +
    /// m12 y + m13, y' = m21 x + m22 y + m23.
    let transforms: FreeHandTable<[Double]>
    let paths: FreeHandTable<Path>
    let arrowPaths: FreeHandTable<Path>
    let strings: FreeHandTable<String>
    let names: [String: Int]
    let lists: FreeHandTable<List>
    let layers: FreeHandTable<Layer>
    let groups: FreeHandTable<Group>
    let clipGroups: FreeHandTable<Group>
    let compositePaths: FreeHandTable<CompositePath>
    let pathTexts: FreeHandTable<PathText>
    let tStrings: FreeHandTable<[Int]>
    let fonts: FreeHandTable<AGDFont>
    let tEffects: FreeHandTable<TextEffect>
    let paragraphs: FreeHandTable<Paragraph>
    let tabs: FreeHandTable<[[Double]]>
    /// UTF-16 code units.
    let textBloks: FreeHandTable<[UInt16]>
    let textObjects: FreeHandTable<TextObject>
    let charProperties: FreeHandTable<CharProperties>
    let paragraphProperties: FreeHandTable<ParagraphProperties>
    /// 16-bit red, green, blue: every colour record's RGB preview.
    let rgbColors: FreeHandTable<[Int]>
    let colorRecords: FreeHandTable<ColorRecord>
    let tints: FreeHandTable<Tint>
    /// Colour id.
    let basicFills: FreeHandTable<Int>
    let propertyLists: FreeHandTable<PropertyList>
    let basicLines: FreeHandTable<BasicLine>
    let customProcs: FreeHandTable<CustomProc>
    let patternLines: FreeHandTable<PatternLine>
    let displayTexts: FreeHandTable<DisplayText>
    let graphicStyles: FreeHandTable<GraphicStyle>
    let attributeHolders: FreeHandTable<AttributeHolder>
    let filterAttributeHolders: FreeHandTable<FilterAttributeHolder>
    let data: FreeHandTable<FreeHandBytes>
    let dataLists: FreeHandTable<DataList>
    let images: FreeHandTable<Image>
    /// [colour id, position 0...1] per stop.
    let multiColorLists: FreeHandTable<[[Double]]>
    let linearFills: FreeHandTable<LinearFill>
    let radialFills: FreeHandTable<RadialFill>
    let lensFills: FreeHandTable<LensFill>
    let tileFills: FreeHandTable<TileFill>
    let patternFills: FreeHandTable<PatternFill>
    /// Dash, gap, dash, gap… in points.
    let linePatterns: FreeHandTable<[Double]>
    let newBlends: FreeHandTable<NewBlend>
    /// 0...1.
    let opacityFilters: FreeHandTable<Double>
    let shadowFilters: FreeHandTable<ShadowFilter>
    let glowFilters: FreeHandTable<GlowFilter>
    let symbolClasses: FreeHandTable<SymbolClass>
    let symbolInstances: FreeHandTable<SymbolInstance>


    enum CodingKeys: String, CodingKey {
        case version, complete, recordCount, recordsRead, recordTypes, stoppedAt, pageInfo, pages, tailPageInfo, layerList, strokeName, fillName, contentsName, transforms, paths, arrowPaths, strings, names, lists, layers, groups, clipGroups, compositePaths, pathTexts, tStrings, fonts, tEffects, paragraphs, tabs, textBloks, textObjects, charProperties, paragraphProperties, rgbColors, colorRecords, tints, basicFills, propertyLists, basicLines, customProcs, patternLines, displayTexts, graphicStyles, attributeHolders, filterAttributeHolders, data, dataLists, images, multiColorLists, linearFills, radialFills, lensFills, tileFills, patternFills, linePatterns, newBlends, opacityFilters, shadowFilters, glowFilters, symbolClasses, symbolInstances
    }

    /// Every field is optional in the JSON: a missing table is empty, a missing number zero, so
    /// tests can write only the records they need.
    required init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        version = try c.decodeIfPresent(Int.self, forKey: .version) ?? 0
        complete = try c.decodeIfPresent(Bool.self, forKey: .complete) ?? true
        recordCount = try c.decodeIfPresent(Int.self, forKey: .recordCount) ?? 0
        recordsRead = try c.decodeIfPresent(Int.self, forKey: .recordsRead) ?? 0
        recordTypes = try c.decodeIfPresent([String: Int].self, forKey: .recordTypes) ?? [:]
        stoppedAt = try c.decodeIfPresent(String.self, forKey: .stoppedAt)
        pageInfo = try c.decodeIfPresent([Double].self, forKey: .pageInfo) ?? []
        pages = try c.decodeIfPresent([[Double]].self, forKey: .pages) ?? []
        tailPageInfo = try c.decodeIfPresent([Double].self, forKey: .tailPageInfo) ?? []
        layerList = try c.decodeIfPresent(Int.self, forKey: .layerList) ?? 0
        strokeName = try c.decodeIfPresent(Int.self, forKey: .strokeName) ?? 0
        fillName = try c.decodeIfPresent(Int.self, forKey: .fillName) ?? 0
        contentsName = try c.decodeIfPresent(Int.self, forKey: .contentsName) ?? 0
        transforms = try c.decodeIfPresent(FreeHandTable<[Double]>.self, forKey: .transforms) ?? FreeHandTable<[Double]>()
        paths = try c.decodeIfPresent(FreeHandTable<Path>.self, forKey: .paths) ?? FreeHandTable<Path>()
        arrowPaths = try c.decodeIfPresent(FreeHandTable<Path>.self, forKey: .arrowPaths) ?? FreeHandTable<Path>()
        strings = try c.decodeIfPresent(FreeHandTable<String>.self, forKey: .strings) ?? FreeHandTable<String>()
        names = try c.decodeIfPresent([String: Int].self, forKey: .names) ?? [:]
        lists = try c.decodeIfPresent(FreeHandTable<List>.self, forKey: .lists) ?? FreeHandTable<List>()
        layers = try c.decodeIfPresent(FreeHandTable<Layer>.self, forKey: .layers) ?? FreeHandTable<Layer>()
        groups = try c.decodeIfPresent(FreeHandTable<Group>.self, forKey: .groups) ?? FreeHandTable<Group>()
        clipGroups = try c.decodeIfPresent(FreeHandTable<Group>.self, forKey: .clipGroups) ?? FreeHandTable<Group>()
        compositePaths = try c.decodeIfPresent(FreeHandTable<CompositePath>.self, forKey: .compositePaths) ?? FreeHandTable<CompositePath>()
        pathTexts = try c.decodeIfPresent(FreeHandTable<PathText>.self, forKey: .pathTexts) ?? FreeHandTable<PathText>()
        tStrings = try c.decodeIfPresent(FreeHandTable<[Int]>.self, forKey: .tStrings) ?? FreeHandTable<[Int]>()
        fonts = try c.decodeIfPresent(FreeHandTable<AGDFont>.self, forKey: .fonts) ?? FreeHandTable<AGDFont>()
        tEffects = try c.decodeIfPresent(FreeHandTable<TextEffect>.self, forKey: .tEffects) ?? FreeHandTable<TextEffect>()
        paragraphs = try c.decodeIfPresent(FreeHandTable<Paragraph>.self, forKey: .paragraphs) ?? FreeHandTable<Paragraph>()
        tabs = try c.decodeIfPresent(FreeHandTable<[[Double]]>.self, forKey: .tabs) ?? FreeHandTable<[[Double]]>()
        textBloks = try c.decodeIfPresent(FreeHandTable<[UInt16]>.self, forKey: .textBloks) ?? FreeHandTable<[UInt16]>()
        textObjects = try c.decodeIfPresent(FreeHandTable<TextObject>.self, forKey: .textObjects) ?? FreeHandTable<TextObject>()
        charProperties = try c.decodeIfPresent(FreeHandTable<CharProperties>.self, forKey: .charProperties) ?? FreeHandTable<CharProperties>()
        paragraphProperties = try c.decodeIfPresent(FreeHandTable<ParagraphProperties>.self, forKey: .paragraphProperties) ?? FreeHandTable<ParagraphProperties>()
        rgbColors = try c.decodeIfPresent(FreeHandTable<[Int]>.self, forKey: .rgbColors) ?? FreeHandTable<[Int]>()
        colorRecords = try c.decodeIfPresent(FreeHandTable<ColorRecord>.self, forKey: .colorRecords) ?? FreeHandTable<ColorRecord>()
        tints = try c.decodeIfPresent(FreeHandTable<Tint>.self, forKey: .tints) ?? FreeHandTable<Tint>()
        basicFills = try c.decodeIfPresent(FreeHandTable<Int>.self, forKey: .basicFills) ?? FreeHandTable<Int>()
        propertyLists = try c.decodeIfPresent(FreeHandTable<PropertyList>.self, forKey: .propertyLists) ?? FreeHandTable<PropertyList>()
        basicLines = try c.decodeIfPresent(FreeHandTable<BasicLine>.self, forKey: .basicLines) ?? FreeHandTable<BasicLine>()
        customProcs = try c.decodeIfPresent(FreeHandTable<CustomProc>.self, forKey: .customProcs) ?? FreeHandTable<CustomProc>()
        patternLines = try c.decodeIfPresent(FreeHandTable<PatternLine>.self, forKey: .patternLines) ?? FreeHandTable<PatternLine>()
        displayTexts = try c.decodeIfPresent(FreeHandTable<DisplayText>.self, forKey: .displayTexts) ?? FreeHandTable<DisplayText>()
        graphicStyles = try c.decodeIfPresent(FreeHandTable<GraphicStyle>.self, forKey: .graphicStyles) ?? FreeHandTable<GraphicStyle>()
        attributeHolders = try c.decodeIfPresent(FreeHandTable<AttributeHolder>.self, forKey: .attributeHolders) ?? FreeHandTable<AttributeHolder>()
        filterAttributeHolders = try c.decodeIfPresent(FreeHandTable<FilterAttributeHolder>.self, forKey: .filterAttributeHolders) ?? FreeHandTable<FilterAttributeHolder>()
        data = try c.decodeIfPresent(FreeHandTable<FreeHandBytes>.self, forKey: .data) ?? FreeHandTable<FreeHandBytes>()
        dataLists = try c.decodeIfPresent(FreeHandTable<DataList>.self, forKey: .dataLists) ?? FreeHandTable<DataList>()
        images = try c.decodeIfPresent(FreeHandTable<Image>.self, forKey: .images) ?? FreeHandTable<Image>()
        multiColorLists = try c.decodeIfPresent(FreeHandTable<[[Double]]>.self, forKey: .multiColorLists) ?? FreeHandTable<[[Double]]>()
        linearFills = try c.decodeIfPresent(FreeHandTable<LinearFill>.self, forKey: .linearFills) ?? FreeHandTable<LinearFill>()
        radialFills = try c.decodeIfPresent(FreeHandTable<RadialFill>.self, forKey: .radialFills) ?? FreeHandTable<RadialFill>()
        lensFills = try c.decodeIfPresent(FreeHandTable<LensFill>.self, forKey: .lensFills) ?? FreeHandTable<LensFill>()
        tileFills = try c.decodeIfPresent(FreeHandTable<TileFill>.self, forKey: .tileFills) ?? FreeHandTable<TileFill>()
        patternFills = try c.decodeIfPresent(FreeHandTable<PatternFill>.self, forKey: .patternFills) ?? FreeHandTable<PatternFill>()
        linePatterns = try c.decodeIfPresent(FreeHandTable<[Double]>.self, forKey: .linePatterns) ?? FreeHandTable<[Double]>()
        newBlends = try c.decodeIfPresent(FreeHandTable<NewBlend>.self, forKey: .newBlends) ?? FreeHandTable<NewBlend>()
        opacityFilters = try c.decodeIfPresent(FreeHandTable<Double>.self, forKey: .opacityFilters) ?? FreeHandTable<Double>()
        shadowFilters = try c.decodeIfPresent(FreeHandTable<ShadowFilter>.self, forKey: .shadowFilters) ?? FreeHandTable<ShadowFilter>()
        glowFilters = try c.decodeIfPresent(FreeHandTable<GlowFilter>.self, forKey: .glowFilters) ?? FreeHandTable<GlowFilter>()
        symbolClasses = try c.decodeIfPresent(FreeHandTable<SymbolClass>.self, forKey: .symbolClasses) ?? FreeHandTable<SymbolClass>()
        symbolInstances = try c.decodeIfPresent(FreeHandTable<SymbolInstance>.self, forKey: .symbolInstances) ?? FreeHandTable<SymbolInstance>()
    }

    /// One segment of a path: its action and numbers (`M x y`, `L x y`, `C x1 y1 x2 y2 x y`,
    /// `Q x1 y1 x y`, `A rx ry rotation large sweep x y`, `Z`).
    struct Segment: Decodable, Sendable {
        var action: String
        var numbers: [Double]

        init(from decoder: any Decoder) throws {
            var container = try decoder.unkeyedContainer()
            action = try container.decode(String.self)
            numbers = []
            while !container.isAtEnd {
                numbers.append(try container.decode(Double.self))
            }
        }
    }

    struct Path: Decodable, Sendable {
        var style: Int
        var xform: Int
        var evenOdd: Bool
        var closed: Bool
        var d: [Segment]
    }

    struct List: Decodable, Sendable {
        var type: Int
        var elements: [Int]
    }

    struct Layer: Decodable, Sendable {
        var style: Int
        var elements: Int
        /// Bit 0 visible, bit 1 printing, bit 3 the guides layer.
        var visibility: Int
        var name: Int
    }

    struct Group: Decodable, Sendable {
        var style: Int
        var elements: Int
        var xform: Int
    }

    struct CompositePath: Decodable, Sendable {
        var style: Int
        var elements: Int
    }

    struct PathText: Decodable, Sendable {
        var elements: Int
        var layer: Int
        var displayText: Int
        var shape: Int
        var textSize: Int
    }

    struct AGDFont: Decodable, Sendable {
        var name: Int
        /// Bit 0 bold, bit 1 italic.
        var style: Int
        var size: Double
    }

    struct TextEffect: Decodable, Sendable {
        var name: Int
        var shortName: Int
        var colors: [Int]
    }

    struct Paragraph: Decodable, Sendable {
        var paraStyle: Int
        var textBlok: Int
        /// [first character, character properties id] per run.
        var charStyles: [[Int]]
    }

    struct TextObject: Decodable, Sendable {
        var style: Int
        var xform: Int
        var tString: Int
        var vmpObj: Int
        /// The path of text on a path (`TFOnPath`).
        var path: Int
        var startX: Double
        var startY: Double
        var width: Double
        var height: Double
        var beginPos: Int
        var endPos: Int
        var colNum: Int
        var rowNum: Int
        var colSep: Double
        var rowSep: Double
        var rowBreakFirst: Int
    }

    struct CharProperties: Decodable, Sendable {
        /// A basic fill id.
        var textColor: Int
        var fontSize: Double
        var fontName: Int
        var font: Int
        var tEffect: Int
        /// By FreeHand's key: baseline shift (0x169c), horizontal scale (0x16d4), range kern
        /// (0x16ec).
        var values: [String: Double]
    }

    struct ParagraphProperties: Decodable, Sendable {
        /// By FreeHand's key: alignment (0x15e3: 0 left, 1 right, 2 centre, 3 justify), leading
        /// type (0x16e3).
        var ints: [String: Int]
        var values: [String: Double]
        var zones: [String: Int]
    }

    /// What a colour record says beyond its RGB preview (patch 0002, `FHColorRecord`).
    struct ColorRecord: Decodable, Sendable {
        /// 1 Color6, 2 SpotColor6 (a named colour of FreeHand 9 and later), 3 TintColor6,
        /// 4 ProcessColor, 5 SpotColor, 6 TintColor.
        var kind: Int
        var variant: Int
        /// The name's string record; 0 for an unnamed colour.
        var name: Int
        var other: Int
        /// ProcessColor's CMYK, 16-bit.
        var cmyk: [Int]?
        /// The record's bytes libfreehand skips.
        var raw: FreeHandBytes
    }

    struct Tint: Decodable, Sendable {
        var base: Int
        /// 0...65535.
        var tint: Int
    }

    struct PropertyList: Decodable, Sendable {
        var parent: Int
        /// Name record id (as digits) to value id.
        var elements: [String: Int]
    }

    struct BasicLine: Decodable, Sendable {
        var color: Int
        var pattern: Int
        var startArrow: Int
        var endArrow: Int
        /// Inches.
        var miter: Double
        /// Inches.
        var width: Double
    }

    struct CustomProc: Decodable, Sendable {
        var ids: [Int]
        var widths: [Double]
        var params: [Double]
        var angles: [Double]
    }

    struct PatternLine: Decodable, Sendable {
        var color: Int
        var percent: Double
        var miter: Double
        var width: Double
    }

    struct DisplayText: Decodable, Sendable {
        var style: Int
        var xform: Int
        var startX: Double
        var startY: Double
        var width: Double
        var height: Double
        var justify: Int
        var charProps: [DisplayCharProps]
        var paraOffsets: [Int]
        /// MacRoman.
        var characters: FreeHandBytes
    }

    struct DisplayCharProps: Decodable, Sendable {
        var offset: Int
        var fontName: Int
        var fontSize: Double
        var fontStyle: Int
        var fontColor: Int
        var textEffs: Int
        var leading: Double
        var letterSpacing: Double
        var wordSpacing: Double
        var horizontalScale: Double
        var baselineShift: Double
    }

    struct GraphicStyle: Decodable, Sendable {
        var parent: Int
        var attr: Int
        var elements: [String: Int]
    }

    struct AttributeHolder: Decodable, Sendable {
        var parent: Int
        var attr: Int
    }

    struct FilterAttributeHolder: Decodable, Sendable {
        var parent: Int
        var filter: Int
        var style: Int
    }

    struct DataList: Decodable, Sendable {
        var size: Int
        var elements: [Int]
    }

    struct Image: Decodable, Sendable {
        var style: Int
        var dataList: Int
        var xform: Int
        var startX: Double
        var startY: Double
        var width: Double
        var height: Double
        var format: String
    }

    struct LinearFill: Decodable, Sendable {
        var color1: Int
        var color2: Int
        /// Degrees.
        var angle: Double
        var multiColorList: Int
    }

    struct RadialFill: Decodable, Sendable {
        var color1: Int
        var color2: Int
        /// The centre as fractions of the bounds.
        var cx: Double
        var cy: Double
        var multiColorList: Int
    }

    struct LensFill: Decodable, Sendable {
        var color: Int
        /// Percent (transparency, lighten, darken) or the magnification.
        var value: Double
        /// 0 transparency, 1 magnify, 2 lighten, 3 darken, 4 invert, 5 monochrome.
        var mode: Int
    }

    struct TileFill: Decodable, Sendable {
        var xform: Int
        var group: Int
        /// Fractions (1 = 100%).
        var scaleX: Double
        var scaleY: Double
        /// Inches.
        var offsetX: Double
        var offsetY: Double
        /// Degrees.
        var angle: Double
    }

    struct PatternFill: Decodable, Sendable {
        var color: Int
        /// Eight rows, most significant bit the left pixel.
        var pattern: FreeHandBytes
    }

    struct NewBlend: Decodable, Sendable {
        var style: Int
        var parent: Int
        var list1: Int
        var list2: Int
        var list3: Int
    }

    struct ShadowFilter: Decodable, Sendable {
        var color: Int
        var knockOut: Bool
        var inner: Bool
        var distribution: Double
        var opacity: Double
        var smoothness: Double
        var angle: Double
    }

    struct GlowFilter: Decodable, Sendable {
        var color: Int
        var inner: Bool
        var width: Double
        var opacity: Double
        var smoothness: Double
        var distribution: Double
    }

    struct SymbolClass: Decodable, Sendable {
        var name: Int
        var group: Int
        var dateTime: Int
        var library: Int
        var list: Int
    }

    struct SymbolInstance: Decodable, Sendable {
        var style: Int
        var parent: Int
        var symbolClass: Int
        var xform: [Double]
    }
}
