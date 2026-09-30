// The package's zip container (saving.adoc, "Client": "the writer uses a minimal streaming zip
// encoder in WTInterchange (stored and deflate via Compression.framework); the reader tolerates any
// conforming zip").  The writer emits entries one after another -- local header, data -- and the
// central directory at the end, so a package streams to disk without holding it in memory; UTF-8
// names, DOS timestamps, no encryption, no zip64 (a package over 4 GiB is refused).  The reader
// finds the end-of-central-directory record, lists the entries from the central directory (so
// data descriptors and extra fields written by other tools are tolerated) and inflates one entry
// at a time, checking its CRC.  The Quick Look extensions read `thumbnail.png` through it without
// inflating anything else.

import Foundation

/// Why a zip could not be read or written.
public enum ZipError: Error, Hashable, Sendable, CustomStringConvertible {
    /// Not a zip, or its directory is damaged.
    case malformed(String)
    /// An entry uses a feature the reader does not implement (encryption, zip64, a method
    /// other than stored and deflate).
    case unsupported(String)
    /// An entry's data does not match its CRC or size.
    case corrupt(String)
    /// The archive or an entry is too large for a zip without zip64.
    case tooLarge
    /// No entry of that name.
    case missing(String)
    /// The destination could not be written.
    case writeFailed(String)

    public var description: String {
        switch self {
        case .malformed(let reason): return "The archive is damaged: \(reason)."
        case .unsupported(let reason): return "The archive uses \(reason), which is not supported."
        case .corrupt(let name): return "“\(name)” in the archive is damaged."
        case .tooLarge: return "The archive would be larger than 4 GiB."
        case .missing(let name): return "The archive has no “\(name)”."
        case .writeFailed(let reason): return "The archive could not be written: \(reason)"
        }
    }
}

/// How an entry's bytes are stored.
public enum ZipMethod: UInt16, Hashable, Sendable {
    case stored = 0
    case deflate = 8
}

/// Writes a zip archive entry by entry.
public final class ZipWriter {
    private struct Record {
        var name: Data
        var method: ZipMethod
        var crc: UInt32
        var compressedSize: UInt32
        var size: UInt32
        var offset: UInt32
    }

    private let sink: (Data) throws -> Void
    private var records: [Record] = []
    private var offset: UInt64 = 0
    private let time: UInt16
    private let date: UInt16
    private var finished = false

    /// A writer that hands each written chunk to `sink` (a file handle's `write`, or an append
    /// to a buffer).  `date` stamps every entry.
    public convenience init(date: Date = Date(), sink: @escaping (Data) throws -> Void) {
        self.init(stamp: ZipWriter.dosTimestamp(date), sink: sink)
    }

    /// A writer that stamps every entry with an MS-DOS `stamp` as read from another archive, so a
    /// rewritten archive keeps the original's bytes where its entries do.
    init(stamp: (time: UInt16, date: UInt16), sink: @escaping (Data) throws -> Void) {
        self.sink = sink
        time = stamp.time
        date = stamp.date
    }

    /// Adds an entry.  Deflate is used only when it makes the entry smaller.
    public func add(_ name: String, data: Data, method: ZipMethod = .deflate) throws {
        precondition(!finished, "entries added after finish()")
        let crc = CRC32.checksum(data)
        var stored = data
        var used = ZipMethod.stored
        if method == .deflate, !data.isEmpty, let deflated = try? (data as NSData).compressed(using: .zlib) as Data, deflated.count < data.count {
            stored = deflated
            used = .deflate
        }
        guard data.count <= UInt32.max, stored.count <= UInt32.max, offset <= UInt32.max else {
            throw ZipError.tooLarge
        }
        let nameBytes = Data(name.utf8)
        let record = Record(name: nameBytes, method: used, crc: crc, compressedSize: UInt32(stored.count), size: UInt32(data.count), offset: UInt32(offset))
        var header = Data()
        header.appendLittleEndian(UInt32(0x0403_4B50))
        header.appendLittleEndian(UInt16(20))                 // version needed
        header.appendLittleEndian(UInt16(0x0800))             // UTF-8 names
        header.appendLittleEndian(used.rawValue)
        header.appendLittleEndian(time)
        header.appendLittleEndian(self.date)
        header.appendLittleEndian(crc)
        header.appendLittleEndian(record.compressedSize)
        header.appendLittleEndian(record.size)
        header.appendLittleEndian(UInt16(nameBytes.count))
        header.appendLittleEndian(UInt16(0))
        header.append(nameBytes)
        try emit(header)
        try emit(stored)
        records.append(record)
    }

    /// Writes the central directory and the end record.
    public func finish() throws {
        precondition(!finished, "finish() called twice")
        finished = true
        let start = offset
        for record in records {
            var entry = Data()
            entry.appendLittleEndian(UInt32(0x0201_4B50))
            entry.appendLittleEndian(UInt16(0x031E))           // made by: Unix, zip 3.0
            entry.appendLittleEndian(UInt16(20))
            entry.appendLittleEndian(UInt16(0x0800))
            entry.appendLittleEndian(record.method.rawValue)
            entry.appendLittleEndian(time)
            entry.appendLittleEndian(date)
            entry.appendLittleEndian(record.crc)
            entry.appendLittleEndian(record.compressedSize)
            entry.appendLittleEndian(record.size)
            entry.appendLittleEndian(UInt16(record.name.count))
            entry.appendLittleEndian(UInt16(0))                // extra
            entry.appendLittleEndian(UInt16(0))                // comment
            entry.appendLittleEndian(UInt16(0))                // disk
            entry.appendLittleEndian(UInt16(0))                // internal attributes
            entry.appendLittleEndian(UInt32(0o100644) << 16)   // external: regular file, rw-r--r--
            entry.appendLittleEndian(record.offset)
            entry.append(record.name)
            try emit(entry)
        }
        let size = offset - start
        guard records.count <= UInt16.max, start <= UInt32.max, size <= UInt32.max else {
            throw ZipError.tooLarge
        }
        var end = Data()
        end.appendLittleEndian(UInt32(0x0605_4B50))
        end.appendLittleEndian(UInt16(0))
        end.appendLittleEndian(UInt16(0))
        end.appendLittleEndian(UInt16(records.count))
        end.appendLittleEndian(UInt16(records.count))
        end.appendLittleEndian(UInt32(size))
        end.appendLittleEndian(UInt32(start))
        end.appendLittleEndian(UInt16(0))
        try emit(end)
    }

    private func emit(_ data: Data) throws {
        try sink(data)
        offset += UInt64(data.count)
    }

    /// MS-DOS time and date fields for `date` in the current time zone (1980 at the earliest).
    static func dosTimestamp(_ date: Date) -> (time: UInt16, date: UInt16) {
        // `dateComponents(in:from:)` fills every component.
        let parts = Calendar(identifier: .gregorian).dateComponents(in: .current, from: date)
        let year = max(parts.year! - 1980, 0)
        let time = UInt16(parts.hour! << 11 | parts.minute! << 5 | parts.second! / 2)
        let day = UInt16(min(year, 127) << 9 | parts.month! << 5 | parts.day!)
        return (time, day)
    }
}

/// Reads a zip archive held in memory (or mapped from disk).
public struct ZipReader: Sendable {
    /// One entry of the central directory.
    public struct Entry: Hashable, Sendable {
        public var name: String
        public var method: UInt16
        public var crc: UInt32
        public var compressedSize: Int
        public var size: Int
        public var flags: UInt16
        /// Offset of the local header.
        var headerOffset: Int
    }

    public let data: Data
    /// The entries in directory order.
    public let entries: [Entry]

    public init(data: Data) throws {
        self.data = data
        entries = try ZipReader.directory(of: data)
    }

    /// The entry named `name`.
    public func entry(_ name: String) -> Entry? {
        entries.first { $0.name == name }
    }

    /// The names of every entry.
    public var names: [String] { entries.map(\.name) }

    /// The MS-DOS modification time and date in `entry`'s local header.
    func stamp(of entry: Entry) -> (time: UInt16, date: UInt16)? {
        let header = entry.headerOffset
        guard header + 30 <= data.count, read32(data, header) == 0x0403_4B50 else { return nil }
        return (read16(data, header + 10), read16(data, header + 12))
    }

    /// The uncompressed bytes of `name`, CRC-checked.
    public func contents(of name: String) throws -> Data {
        guard let entry = entry(name) else {
            throw ZipError.missing(name)
        }
        return try contents(of: entry)
    }

    /// The uncompressed bytes of `entry`, CRC-checked.
    public func contents(of entry: Entry) throws -> Data {
        if entry.flags & 0x0001 != 0 {
            throw ZipError.unsupported("encryption")
        }
        let base = data.startIndex
        let header = entry.headerOffset
        guard header + 30 <= data.count, read32(data, header) == 0x0403_4B50 else {
            throw ZipError.malformed("the local header of “\(entry.name)” is missing")
        }
        let start = header + 30 + Int(read16(data, header + 26)) + Int(read16(data, header + 28))
        guard start + entry.compressedSize <= data.count else {
            throw ZipError.corrupt(entry.name)
        }
        let raw = data.subdata(in: (base + start)..<(base + start + entry.compressedSize))
        let bytes: Data
        switch entry.method {
        case ZipMethod.stored.rawValue:
            bytes = raw
        case ZipMethod.deflate.rawValue:
            guard entry.size > 0 else {
                bytes = Data()
                break
            }
            guard let inflated = try? (raw as NSData).decompressed(using: .zlib) as Data else {
                throw ZipError.corrupt(entry.name)
            }
            bytes = inflated
        default:
            throw ZipError.unsupported("compression method \(entry.method)")
        }
        guard bytes.count == entry.size, CRC32.checksum(bytes) == entry.crc else {
            throw ZipError.corrupt(entry.name)
        }
        return bytes
    }

    static func directory(of data: Data) throws -> [Entry] {
        // The end record is the last 22 bytes plus a comment of at most 65,535 bytes.
        guard data.count >= 22 else {
            throw ZipError.malformed("it is too short to be a zip archive")
        }
        var end = data.count - 22
        let lowest = max(0, data.count - 22 - 65_535)
        while end >= lowest && read32(data, end) != 0x0605_4B50 {
            end -= 1
        }
        guard end >= lowest else {
            throw ZipError.malformed("it has no end of central directory record")
        }
        let count = Int(read16(data, end + 10))
        let size = Int(read32(data, end + 12))
        let start = Int(read32(data, end + 16))
        if count == 0xFFFF || size == 0xFFFF_FFFF || start == 0xFFFF_FFFF {
            throw ZipError.unsupported("zip64")
        }
        guard start + size <= end else {
            throw ZipError.malformed("its central directory lies outside the file")
        }
        var entries: [Entry] = []
        var cursor = start
        for _ in 0..<count {
            guard cursor + 46 <= end, read32(data, cursor) == 0x0201_4B50 else {
                throw ZipError.malformed("its central directory is damaged")
            }
            let nameLength = Int(read16(data, cursor + 28))
            let extraLength = Int(read16(data, cursor + 30))
            let commentLength = Int(read16(data, cursor + 32))
            guard cursor + 46 + nameLength <= end else {
                throw ZipError.malformed("its central directory is damaged")
            }
            let base = data.startIndex
            let name = String(decoding: data[(base + cursor + 46)..<(base + cursor + 46 + nameLength)], as: UTF8.self)
            entries.append(Entry(
                name: name, method: read16(data, cursor + 10), crc: read32(data, cursor + 16),
                compressedSize: Int(read32(data, cursor + 20)), size: Int(read32(data, cursor + 24)),
                flags: read16(data, cursor + 8), headerOffset: Int(read32(data, cursor + 42))))
            cursor += 46 + nameLength + extraLength + commentLength
        }
        return entries
    }
}

private func read16(_ data: Data, _ offset: Int) -> UInt16 {
    let base = data.startIndex + offset
    return UInt16(data[base]) | UInt16(data[base + 1]) << 8
}

private func read32(_ data: Data, _ offset: Int) -> UInt32 {
    UInt32(read16(data, offset)) | UInt32(read16(data, offset + 2)) << 16
}
