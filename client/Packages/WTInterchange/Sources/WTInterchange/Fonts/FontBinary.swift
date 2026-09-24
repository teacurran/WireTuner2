// Big-endian reading and writing for the sfnt tables (FONT-018, FONT-025, FONT-027).

import Foundation

/// Appends big-endian font data.
struct FontWriter {
    private(set) var bytes: [UInt8] = []

    init() {}

    var count: Int { bytes.count }

    mutating func u8(_ value: Int) {
        bytes.append(UInt8(truncatingIfNeeded: value))
    }

    mutating func u16(_ value: Int) {
        bytes += [UInt8(truncatingIfNeeded: value >> 8), UInt8(truncatingIfNeeded: value)]
    }

    /// A signed 16-bit value, clamped to its range.
    mutating func i16(_ value: Int) {
        u16(Int(Int16(clamping: value)))
    }

    mutating func u32(_ value: Int) {
        u16(value >> 16)
        u16(value)
    }

    /// A 16.16 fixed-point value.
    mutating func fixed(_ value: Double) {
        u32(Int(Int32(clamping: Int((value * 65_536).rounded()))))
    }

    /// A four-character tag, space-padded.
    mutating func tag(_ tag: String) {
        var scalars = Array(tag.utf8.prefix(4))
        while scalars.count < 4 { scalars.append(0x20) }
        bytes += scalars
    }

    mutating func append(_ other: [UInt8]) {
        bytes += other
    }

    mutating func append(_ other: FontWriter) {
        bytes += other.bytes
    }

    /// Zero bytes up to a multiple of `alignment`.
    mutating func pad(to alignment: Int) {
        while bytes.count % alignment != 0 { bytes.append(0) }
    }

    /// Overwrites the 16-bit value at `offset`.
    mutating func set16(_ value: Int, at offset: Int) {
        bytes[offset] = UInt8(truncatingIfNeeded: value >> 8)
        bytes[offset + 1] = UInt8(truncatingIfNeeded: value)
    }

    /// Overwrites the 32-bit value at `offset`.
    mutating func set32(_ value: Int, at offset: Int) {
        set16(value >> 16, at: offset)
        set16(value, at: offset + 2)
    }
}

/// Why font data could not be read.
public enum FontReadError: Error, Hashable, Sendable {
    /// The data ends before a structure does.
    case truncated(String)
    /// A structure holds a value the reader does not accept.
    case malformed(String)
    /// A required table is missing.
    case missingTable(String)
    /// The font uses something the reader does not support.
    case unsupported(String)
}

/// Reads big-endian font data from a byte array, every read bounds-checked.
struct FontReader {
    let bytes: [UInt8]
    /// The structure being read, for error messages.
    let context: String

    init(_ bytes: [UInt8], context: String) {
        self.bytes = bytes
        self.context = context
    }

    init(_ data: Data, context: String) {
        self.init([UInt8](data), context: context)
    }

    var count: Int { bytes.count }

    func check(_ offset: Int, _ length: Int) throws {
        guard offset >= 0, length >= 0, offset + length <= bytes.count else { throw FontReadError.truncated(context) }
    }

    func u8(_ offset: Int) throws -> Int {
        try check(offset, 1)
        return Int(bytes[offset])
    }

    func u16(_ offset: Int) throws -> Int {
        try check(offset, 2)
        return Int(bytes[offset]) << 8 | Int(bytes[offset + 1])
    }

    func i16(_ offset: Int) throws -> Int {
        Int(Int16(bitPattern: UInt16(try u16(offset))))
    }

    func u24(_ offset: Int) throws -> Int {
        try check(offset, 3)
        return Int(bytes[offset]) << 16 | Int(bytes[offset + 1]) << 8 | Int(bytes[offset + 2])
    }

    func u32(_ offset: Int) throws -> Int {
        try u16(offset) << 16 | u16(offset + 2)
    }

    func i32(_ offset: Int) throws -> Int {
        Int(Int32(bitPattern: UInt32(try u32(offset))))
    }

    func fixed(_ offset: Int) throws -> Double {
        Double(try i32(offset)) / 65_536
    }

    func tag(_ offset: Int) throws -> String {
        try check(offset, 4)
        return String(decoding: bytes[offset..<(offset + 4)], as: UTF8.self)
    }

    func slice(_ offset: Int, _ length: Int) throws -> [UInt8] {
        try check(offset, length)
        return Array(bytes[offset..<(offset + length)])
    }

    /// A reader over `length` bytes from `offset`.
    func sub(_ offset: Int, _ length: Int, context: String? = nil) throws -> FontReader {
        FontReader(try slice(offset, length), context: context ?? self.context)
    }
}
