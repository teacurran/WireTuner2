// IO-041: FreeHand fixtures.  No FreeHand files are vendored (none with a licence allowing it
// exist; libfreehand ships no test documents), so tests write their own: `FreeHandRecordsFixture`
// builds the bridge's JSON record by record for the converter, and `FreeHandFileFixture` writes
// minimal FreeHand 8 and 10 files byte by byte in the layout libfreehand's readers expect, so the
// whole path through the vendored C++ runs.

import Compression
import Foundation
@testable import WTInterchange

/// The bridge's JSON, record by record.  Ids are allocated in order from 1; the special names
/// "fill", "stroke" and "contents" are records 900, 901 and 902.
struct FreeHandRecordsFixture {
    var top: [String: Any] = ["version": 10, "complete": true, "recordCount": 10, "recordsRead": 10,
                              "pages": [[0.0, 0.0, 8.0, 10.0]], "fillName": 900, "strokeName": 901, "contentsName": 902]
    var tables: [String: [String: Any]] = [:]
    private var next = 1
    private var layerIDs: [Int] = []

    static let fill = 900
    static let stroke = 901
    static let contents = 902

    mutating func id() -> Int {
        defer { next += 1 }
        return next
    }

    mutating func set(_ table: String, _ id: Int, _ value: Any) {
        tables[table, default: [:]][String(id)] = value
    }

    func records() throws -> FreeHandRecords {
        var json = top
        var layerList = tables["lists"] ?? [:]
        let listID = 5000
        layerList[String(listID)] = ["type": 0, "elements": layerIDs]
        var all = tables
        all["lists"] = layerList
        for (key, value) in all { json[key] = value }
        if json["layerList"] == nil { json["layerList"] = listID }
        let data = try JSONSerialization.data(withJSONObject: json)
        return try JSONDecoder().decode(FreeHandRecords.self, from: data)
    }

    func convert(name: String = "Test.fh10") throws -> FreeHandConversion {
        var converter = FreeHandConverter(records: try records(), name: name)
        return converter.convert()
    }

    // MARK: Structure

    @discardableResult
    mutating func list(_ elements: [Int]) -> Int {
        let id = id()
        set("lists", id, ["type": 0, "elements": elements])
        return id
    }

    @discardableResult
    mutating func string(_ text: String) -> Int {
        let id = id()
        set("strings", id, text)
        return id
    }

    /// A layer holding `elements`; visibility 3 is visible and printing.
    mutating func layer(_ elements: [Int], name: String? = "Foreground", visibility: Int = 3) {
        let list = list(elements)
        let nameID = name.map { string($0) } ?? 0
        let id = id()
        set("layers", id, ["style": 0, "elements": list, "visibility": visibility, "name": nameID])
        layerIDs.append(id)
    }

    @discardableResult
    mutating func transform(_ m: [Double]) -> Int {
        let id = id()
        set("transforms", id, m)
        return id
    }

    @discardableResult
    mutating func group(_ elements: [Int], style: Int = 0, xform: Int = 0, clip: Bool = false) -> Int {
        let list = list(elements)
        let id = id()
        set(clip ? "clipGroups" : "groups", id, ["style": style, "elements": list, "xform": xform])
        return id
    }

    /// A path of segments `[action, numbers…]` in inches, y up.
    @discardableResult
    mutating func path(_ d: [[Any]], style: Int = 0, xform: Int = 0, evenOdd: Bool = false, table: String = "paths") -> Int {
        let id = id()
        set(table, id, ["style": style, "xform": xform, "evenOdd": evenOdd, "closed": true, "d": d])
        return id
    }

    /// A closed rectangle path from (x, y) of `w` × `h` inches.
    @discardableResult
    mutating func rect(_ x: Double, _ y: Double, _ w: Double, _ h: Double, style: Int = 0, xform: Int = 0) -> Int {
        path([["M", x, y], ["L", x + w, y], ["L", x + w, y + h], ["L", x, y + h], ["Z"]], style: style, xform: xform)
    }

    @discardableResult
    mutating func composite(_ paths: [Int], style: Int = 0) -> Int {
        let list = list(paths)
        let id = id()
        set("compositePaths", id, ["style": style, "elements": list])
        return id
    }

    // MARK: Colours and styles

    @discardableResult
    mutating func rgb(_ r: Double, _ g: Double, _ b: Double) -> Int {
        let id = id()
        set("rgbColors", id, [Int(r * 65535), Int(g * 65535), Int(b * 65535)])
        return id
    }

    /// 16.16 fixed point, big endian, as hex.
    static func fixed(_ values: [Double]) -> String {
        values.map { String(format: "%08x", UInt32(min(max($0, 0), 1) * 65535)) }.joined()
    }

    /// A Color6 or SpotColor6 record: `model` 1 RGB or 2 CMYK, the components at the end.
    @discardableResult
    mutating func colorRecord(kind: Int, name: String? = nil, model: Int, components: [Double], preview: [Double] = [0.5, 0.5, 0.5], header: String = "0000") -> Int {
        let nameID = name.map { string($0) } ?? 0
        let id = id()
        set("rgbColors", id, preview.map { Int($0 * 65535) })
        set("colorRecords", id, ["kind": kind, "variant": components.count, "name": nameID, "other": 0,
                                 "raw": String(format: "%04x", model) + header + FreeHandRecordsFixture.fixed(components)])
        return id
    }

    @discardableResult
    mutating func basicFill(_ color: Int) -> Int {
        let id = id()
        set("basicFills", id, color)
        return id
    }

    @discardableResult
    mutating func basicLine(_ color: Int, width: Double = 1.0 / 72, pattern: Int = 0, miter: Double = 30.0 / 72, start: Int = 0, end: Int = 0) -> Int {
        let id = id()
        set("basicLines", id, ["color": color, "pattern": pattern, "startArrow": start, "endArrow": end, "miter": miter, "width": width])
        return id
    }

    /// A FreeHand 8 style: a property list with `fill`, `stroke` and `contents` entries.
    @discardableResult
    mutating func propList(fill: Int? = nil, stroke: Int? = nil, contents: Int? = nil, parent: Int = 0) -> Int {
        var elements: [String: Int] = [:]
        if let fill { elements[String(FreeHandRecordsFixture.fill)] = fill }
        if let stroke { elements[String(FreeHandRecordsFixture.stroke)] = stroke }
        if let contents { elements[String(FreeHandRecordsFixture.contents)] = contents }
        let id = id()
        set("propertyLists", id, ["parent": parent, "elements": elements])
        return id
    }

    /// An attribute holder whose value is `value` (0: its parent's).
    @discardableResult
    mutating func holder(_ value: Int, parent: Int = 0) -> Int {
        let id = id()
        set("attributeHolders", id, ["parent": parent, "attr": value])
        return id
    }

    /// A FreeHand 9 and later style: a graphic style whose attribute list holds `attributes`.
    @discardableResult
    mutating func graphicStyle(_ attributes: [Int], parent: Int = 0, elements: [String: Int] = [:]) -> Int {
        let list = list(attributes)
        let id = id()
        set("graphicStyles", id, ["parent": parent, "attr": list, "elements": elements])
        return id
    }

    @discardableResult
    mutating func filterHolder(filter: Int, style: Int = 0) -> Int {
        let id = id()
        set("filterAttributeHolders", id, ["parent": 0, "filter": filter, "style": style])
        return id
    }

    // MARK: Text

    /// A paragraph of `text` in character properties `properties` (one run), aligned by `alignment`.
    @discardableResult
    mutating func paragraph(_ text: String, properties: Int, alignment: Int = 0) -> Int {
        let blok = id()
        set("textBloks", blok, Array(text.utf16).map(Int.init))
        let style = id()
        set("paragraphProperties", style, ["ints": [String(0x15e3): alignment], "values": [:], "zones": [:]])
        let id = id()
        set("paragraphs", id, ["paraStyle": style, "textBlok": blok, "charStyles": [[0, properties]]])
        return id
    }

    @discardableResult
    mutating func charProperties(color: Int = 0, size: Double = 12, fontName: String? = nil, font: Int = 0) -> Int {
        let nameID = fontName.map { string($0) } ?? 0
        let fill = color == 0 ? 0 : basicFill(color)
        let id = id()
        set("charProperties", id, ["textColor": fill, "fontSize": size, "fontName": nameID, "font": font, "tEffect": 0, "values": [:]])
        return id
    }

    @discardableResult
    mutating func agdFont(_ name: String, style: Int = 0, size: Double = 24) -> Int {
        let nameID = string(name)
        let id = id()
        set("fonts", id, ["name": nameID, "style": style, "size": size])
        return id
    }

    @discardableResult
    mutating func textObject(_ paragraphs: [Int], x: Double = 1, y: Double = 9, width: Double = 3, height: Double = 2, xform: Int = 0, path: Int = 0,
                             begin: Int = 0, end: Int = 0xffff, columns: Int = 1) -> Int {
        let tString = id()
        set("tStrings", tString, paragraphs)
        let id = id()
        set("textObjects", id, ["style": 0, "xform": xform, "tString": tString, "vmpObj": 0, "path": path, "startX": x, "startY": y,
                                "width": width, "height": height, "beginPos": begin, "endPos": end, "colNum": columns, "rowNum": 1,
                                "colSep": 0.25, "rowSep": 0.25, "rowBreakFirst": 0])
        return id
    }
}

/// A FreeHand file written byte by byte: records in libfreehand's layouts, the dictionary and
/// the record list, compressed for FreeHand 9 and later.
struct FreeHandFileFixture {
    /// The FreeHand version: 8 (`AGD3`, uncompressed) or 10 (`AGD5`, zlib, inside 0x1C records).
    var version: Int
    private var body = Data()
    private var names: [String] = []
    private var order: [UInt16] = []
    private(set) var count = 0

    init(version: Int) {
        self.version = version
    }

    mutating func u8(_ value: Int) { body.append(UInt8(truncatingIfNeeded: value)) }
    mutating func u16(_ value: Int) { body.append(contentsOf: [UInt8(truncatingIfNeeded: value >> 8), UInt8(truncatingIfNeeded: value)]) }
    mutating func u32(_ value: Int) { u16(value >> 16); u16(value) }
    mutating func skip(_ n: Int) { body.append(Data(count: n)) }
    /// A coordinate: 16.16 fixed point.
    mutating func coordinate(_ value: Double) { u32(Int((value * 65536).rounded())) }
    /// A record id.
    mutating func ref(_ id: Int) { u16(id) }

    /// Starts record `name`; returns its id (records are numbered from 1).
    @discardableResult
    mutating func record(_ name: String) -> Int {
        if !names.contains(name) { names.append(name) }
        order.append(UInt16(names.firstIndex(of: name)! + 1))
        count += 1
        return count
    }

    /// The id the next record will get.
    var nextID: Int { count + 1 }

    @discardableResult
    mutating func list(_ elements: [Int]) -> Int {
        let id = record("List")
        u16(elements.count)
        u16(elements.count)
        skip(6)
        u16(0)
        elements.forEach { ref($0) }
        return id
    }

    @discardableResult
    mutating func mString(_ text: String) -> Int {
        let id = record("MString")
        let bytes = Array(text.utf8)
        let size = (bytes.count + 4 + 3) / 4
        u16(size)
        u16(bytes.count)
        body.append(contentsOf: bytes)
        skip((size + 1) * 4 - 4 - bytes.count)
        return id
    }

    @discardableResult
    mutating func mName(_ text: String) -> Int {
        let id = record("MName")
        let bytes = Array(text.utf8)
        let size = (bytes.count + 4 + 3) / 4
        u16(size)
        u16(bytes.count)
        body.append(contentsOf: bytes)
        skip((size + 1) * 4 - 4 - bytes.count)
        return id
    }

    @discardableResult
    mutating func layer(elements: Int, name: Int, visibility: Int = 3) -> Int {
        let id = record("Layer")
        ref(0)
        skip(4 + 6)
        ref(elements)
        ref(name)
        u16(visibility)
        skip(2)
        return id
    }

    /// A closed path through `points` (inches) with straight segments.
    @discardableResult
    mutating func path(_ points: [(Double, Double)], style: Int) -> Int {
        let id = record("Path")
        u16(points.count)
        ref(style)
        ref(0)
        skip(4 + 9)
        u8(1)                     // closed
        u16(points.count)
        for (x, y) in points {
            skip(1); u8(0); skip(1)
            for _ in 0..<3 {
                coordinate(x * 72)
                coordinate(y * 72)
            }
        }
        return id
    }

    /// FreeHand 8's ProcessColor with CMYK values (the RGB preview black, so they are read).
    @discardableResult
    mutating func processColor(name: Int, cmyk: [Double]) -> Int {
        let id = record("ProcessColor")
        ref(name)
        skip(2)
        u16(0); u16(0); u16(0)
        skip(4)
        u16(Int(cmyk[3] * 65535)); u16(Int(cmyk[0] * 65535)); u16(Int(cmyk[1] * 65535)); u16(Int(cmyk[2] * 65535))
        return id
    }

    /// FreeHand 9 and later's SpotColor6: RGB components at the end.
    @discardableResult
    mutating func spotColor6(name: Int, rgb: [Double]) -> Int {
        let id = record("SpotColor6")
        u16(3)
        ref(name)
        u16(Int(rgb[0] * 65535)); u16(Int(rgb[1] * 65535)); u16(Int(rgb[2] * 65535))
        u16(1)                     // model: RGB
        skip(version < 10 ? 14 : 16)
        rgb.forEach { u32(Int($0 * 65535)) }
        return id
    }

    @discardableResult
    mutating func basicFill(color: Int) -> Int {
        let id = record("BasicFill")
        ref(color)
        skip(4)
        return id
    }

    @discardableResult
    mutating func propList(_ pairs: [(Int, Int)]) -> Int {
        let id = record("PropLst")
        u16(pairs.count)
        u16(pairs.count)
        skip(4)
        for (name, value) in pairs {
            ref(name)
            ref(value)
        }
        return id
    }

    @discardableResult
    mutating func block(layerList: Int) -> Int {
        let id = record("Block")
        if version == 10 {
            u16(0)
            for i in 1..<22 { ref(i == 5 ? layerList : 0) }
            skip(1)
            ref(0); ref(0)
        } else {
            for i in 0..<12 { ref(i == 5 ? layerList : 0) }
            skip(14)
        }
        return id
    }

    /// The file: header, records, tail, dictionary and record list; FreeHand 10's data is
    /// zlib-compressed and wrapped in the 0x1C records its files begin with.
    func data(width: Double = 8.5, height: Double = 11) -> Data {
        var tail = Data()
        func tailU16(_ v: Int) { tail.append(contentsOf: [UInt8(truncatingIfNeeded: v >> 8), UInt8(truncatingIfNeeded: v)]) }
        func tailU32(_ v: Int) { tailU16(v >> 16); tailU16(v) }
        tailU16(count)               // the block: the last record
        tailU16(0); tailU16(0)
        tail.append(Data(count: 0x1a - 6))
        tailU32(Int(width * 72 * 65536))
        tailU32(Int(height * 72 * 65536))
        tail.append(Data(count: 0x40 - tail.count))
        var payload = body + tail
        if version >= 9 { payload = FreeHandFileFixture.zlib(payload) }
        var file = Data("AGD".utf8) + [UInt8(0x30 + version - 5)]
        file.append(Data(count: 4))
        let dataLength = 12 + payload.count
        file.append(contentsOf: [UInt8(dataLength >> 24 & 0xff), UInt8(dataLength >> 16 & 0xff), UInt8(dataLength >> 8 & 0xff), UInt8(dataLength & 0xff)])
        file.append(payload)
        // Dictionary.
        file.append(contentsOf: [UInt8(names.count >> 8), UInt8(names.count & 0xff), 0, 0])
        for (index, name) in names.enumerated() {
            let id = index + 1
            file.append(contentsOf: [UInt8(id >> 8), UInt8(id & 0xff)])
            if version <= 8 { file.append(contentsOf: [0, 0]) }
            file.append(Data(name.utf8) + [0])
            if version <= 8 { file.append(contentsOf: [0, 0]) }
        }
        // Record list.
        let n = order.count
        file.append(contentsOf: [UInt8(n >> 24 & 0xff), UInt8(n >> 16 & 0xff), UInt8(n >> 8 & 0xff), UInt8(n & 0xff)])
        for id in order { file.append(contentsOf: [UInt8(id >> 8), UInt8(id & 0xff)]) }
        guard version >= 10 else { return file }
        // FreeHand 10: a 0x1C record, then the AGD block as record 0x080a with a long length.
        var wrapped = Data([0x1C, 0x01, 0x00, 0x00, 0x02, 0x00, 0x04])
        wrapped.append(contentsOf: [0x1C, 0x08, 0x0A, 0x80, 0x04])
        let length = file.count
        wrapped.append(contentsOf: [UInt8(length >> 24 & 0xff), UInt8(length >> 16 & 0xff), UInt8(length >> 8 & 0xff), UInt8(length & 0xff)])
        return wrapped + file
    }

    /// `data` in zlib format (header, raw deflate, Adler-32) as libfreehand inflates it.
    static func zlib(_ data: Data) -> Data {
        let raw = try! (data as NSData).compressed(using: .zlib) as Data
        var a: UInt32 = 1
        var b: UInt32 = 0
        for byte in data {
            a = (a + UInt32(byte)) % 65521
            b = (b + a) % 65521
        }
        let adler = b << 16 | a
        return Data([0x78, 0x9C]) + raw + Data([UInt8(adler >> 24), UInt8(adler >> 16 & 0xff), UInt8(adler >> 8 & 0xff), UInt8(adler & 0xff)])
    }

    /// A one-page drawing: a layer named `layerName` holding a square filled with a named colour.
    static func square(version: Int, layerName: String = "Artwork", colorName: String = "Leaf") -> Data {
        var file = FreeHandFileFixture(version: version)
        let fill = file.mName("fill")
        let name = file.mString(colorName)
        let color = version >= 9 ? file.spotColor6(name: name, rgb: [0.2, 0.6, 0.2]) : file.processColor(name: name, cmyk: [0.8, 0, 1, 0.1])
        let basic = file.basicFill(color: color)
        let style = file.propList([(fill, basic)])
        let square = file.path([(1, 1), (3, 1), (3, 3), (1, 3)], style: style)
        let elements = file.list([square])
        let layerName = file.mString(layerName)
        let layer = file.layer(elements: elements, name: layerName)
        let layers = file.list([layer])
        file.block(layerList: layers)
        return file.data()
    }
}
