// Typed access to a PDF's object graph through Core Graphics (`CGPDFDocument` parses the file,
// resolves references and decodes stream filters; the importer reads the structures it needs
// through these wrappers).  IMG-009.

import CoreGraphics
import Foundation

/// A PDF object of any type.
enum PDFImportValue {
    case null
    case bool(Bool)
    case number(Double)
    case name(String)
    case string(Data)
    case array(PDFImportArray)
    case dict(PDFImportDict)
    case stream(PDFImportStream)

    init(_ object: CGPDFObjectRef) {
        switch CGPDFObjectGetType(object) {
        case .boolean:
            var value: CGPDFBoolean = 0
            CGPDFObjectGetValue(object, .boolean, &value)
            self = .bool(value != 0)
        case .integer:
            var value: CGPDFInteger = 0
            CGPDFObjectGetValue(object, .integer, &value)
            self = .number(Double(value))
        case .real:
            var value: CGPDFReal = 0
            CGPDFObjectGetValue(object, .real, &value)
            self = .number(Double(value))
        case .name:
            var value: UnsafePointer<CChar>?
            CGPDFObjectGetValue(object, .name, &value)
            self = .name(String(cString: value!))
        case .string:
            var value: CGPDFStringRef?
            CGPDFObjectGetValue(object, .string, &value)
            self = .string(PDFImportValue.bytes(value!))
        case .array:
            var value: CGPDFArrayRef?
            CGPDFObjectGetValue(object, .array, &value)
            self = .array(PDFImportArray(ref: value!))
        case .dictionary:
            var value: CGPDFDictionaryRef?
            CGPDFObjectGetValue(object, .dictionary, &value)
            self = .dict(PDFImportDict(ref: value!))
        case .stream:
            var value: CGPDFStreamRef?
            CGPDFObjectGetValue(object, .stream, &value)
            self = .stream(PDFImportStream(ref: value!))
        default:
            self = .null
        }
    }

    static func bytes(_ string: CGPDFStringRef) -> Data {
        Data(UnsafeBufferPointer(start: CGPDFStringGetBytePtr(string), count: CGPDFStringGetLength(string)))
    }

    var number: Double? {
        if case .number(let value) = self { return value }
        return nil
    }

    var name: String? {
        if case .name(let value) = self { return value }
        return nil
    }

    var array: PDFImportArray? {
        if case .array(let value) = self { return value }
        return nil
    }

    /// A dictionary, or a stream's dictionary.
    var dict: PDFImportDict? {
        switch self {
        case .dict(let value): return value
        case .stream(let stream): return stream.dict
        default: return nil
        }
    }

    var stream: PDFImportStream? {
        if case .stream(let value) = self { return value }
        return nil
    }

    var string: Data? {
        if case .string(let value) = self { return value }
        return nil
    }

    /// Converted to a content-stream operand (streams become null).
    var operand: PDFImportOperand {
        switch self {
        case .null, .stream: return .null
        case .bool(let value): return .bool(value)
        case .number(let value): return .number(value)
        case .name(let value): return .name(value)
        case .string(let value): return .string(value)
        case .array(let array): return .array(array.values.map(\.operand))
        case .dict(let dict): return .dict(Dictionary(uniqueKeysWithValues: dict.keys.compactMap { key in dict[key].map { (key, $0.operand) } }))
        }
    }
}

struct PDFImportDict {
    let ref: CGPDFDictionaryRef

    subscript(key: String) -> PDFImportValue? {
        var object: CGPDFObjectRef?
        guard CGPDFDictionaryGetObject(ref, key, &object), let object else {
            return nil
        }
        return PDFImportValue(object)
    }

    func number(_ key: String) -> Double? { self[key]?.number }
    func name(_ key: String) -> String? { self[key]?.name }
    func dict(_ key: String) -> PDFImportDict? { self[key]?.dict }
    func array(_ key: String) -> PDFImportArray? { self[key]?.array }
    func stream(_ key: String) -> PDFImportStream? { self[key]?.stream }
    func string(_ key: String) -> Data? { self[key]?.string }

    func bool(_ key: String) -> Bool? {
        if case .bool(let value)? = self[key] { return value }
        return nil
    }

    /// A text string entry (`/Contents`, `/Name`, `/URI`).
    func text(_ key: String) -> String? {
        var string: CGPDFStringRef?
        if CGPDFDictionaryGetString(ref, key, &string), let string {
            return CGPDFStringCopyTextString(string) as String?
        }
        return nil
    }

    /// The numbers of an array entry.
    func numbers(_ key: String) -> [Double]? { array(key)?.numbers }

    /// Every key.
    var keys: [String] {
        final class Collector {
            var keys: [String] = []
        }
        let collector = Collector()
        CGPDFDictionaryApplyBlock(ref, { key, _, info in
            Unmanaged<Collector>.fromOpaque(info!).takeUnretainedValue().keys.append(String(cString: key))
            return true
        }, Unmanaged.passUnretained(collector).toOpaque())
        return collector.keys.sorted()
    }

    /// An identity for caches.
    var id: UnsafeRawPointer { unsafeBitCast(ref, to: UnsafeRawPointer.self) }
}

struct PDFImportArray {
    let ref: CGPDFArrayRef

    var count: Int { CGPDFArrayGetCount(ref) }

    subscript(index: Int) -> PDFImportValue? {
        var object: CGPDFObjectRef?
        guard index >= 0, index < count, CGPDFArrayGetObject(ref, index, &object), let object else {
            return nil
        }
        return PDFImportValue(object)
    }

    var values: [PDFImportValue] { (0..<count).compactMap { self[$0] } }

    /// The numeric elements (non-numbers are skipped).
    var numbers: [Double] { values.compactMap(\.number) }
}

struct PDFImportStream {
    let ref: CGPDFStreamRef

    var dict: PDFImportDict { PDFImportDict(ref: CGPDFStreamGetDictionary(ref)!) }

    /// The decoded bytes and whether they are still JPEG or JPEG 2000 encoded (Core Graphics
    /// leaves those filters for the image decoder).
    var decoded: (data: Data, format: CGPDFDataFormat) {
        var format = CGPDFDataFormat.raw
        let data = CGPDFStreamCopyData(ref, &format).map { $0 as Data } ?? Data()
        return (data, format)
    }

    var data: Data { decoded.data }
}
