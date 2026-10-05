// Zstandard (RFC 8878) decompression for the importers, over the reference library vendored as
// client/Vendor/zstd (`CZstd`, BSD; docs/spec/decisions.adoc D-098).  Illustrator 2020 and later
// compress their private data with it (`%AI24_ZStandard_Data`, import-formats.adoc, "Adobe
// Illustrator"); Compression.framework has no zstd.  The library checks every frame -- block
// sizes, entropy tables, offsets, the window and the optional checksum -- so damaged input is an
// error, never a crash; this wrapper adds the size cap and makes sure every call makes progress.

import CZstd
import Foundation

enum Zstandard {
    /// Why bytes could not be decompressed.
    enum Failure: Error, Equatable {
        /// The input does not start with a Zstandard or skippable frame.
        case notZstandard
        /// The library rejected the data (damaged, a checksum mismatch, a dictionary that is
        /// missing or wrong); the library's own description.
        case damaged(String)
        /// The input ends inside a frame.
        case truncated
        /// The content is larger than the limit.
        case tooLarge
    }

    /// The largest window a frame may ask for: 2^27 bytes (128 MiB), the library's default and
    /// what Illustrator writes.  A frame asking for more is refused before anything is allocated.
    static let windowLogMax: Int32 = 27

    /// Whether `data` starts with a frame: a Zstandard frame's magic number 0xFD2FB528 or a
    /// skippable frame's 0x184D2A50 … 0x184D2A5F (little-endian).
    static func startsWithFrame<Bytes: Collection>(_ data: Bytes) -> Bool where Bytes.Element == UInt8 {
        let head = Array(data.prefix(4))
        guard head.count == 4 else { return false }
        return head == [0x28, 0xB5, 0x2F, 0xFD] || (head[0] & 0xF0 == 0x50 && head[1...] == [0x2A, 0x4D, 0x18])
    }

    /// The content of the frames `data` starts with, decoded one after another; skippable frames
    /// are passed over, and whatever follows the last frame that is not another frame is ignored
    /// (as `IllustratorPrivateData.inflate` ignores what follows a zlib stream).  `dictionary` is
    /// a dictionary (zstd's format, or raw content) for frames compressed with one.  Throws when
    /// `data` is not Zstandard, the library rejects it, it ends inside a frame, or the content
    /// passes `limit` bytes -- checked against a frame's declared size before decoding, and
    /// against the output as it grows.
    static func decompress(_ data: Data, dictionary: Data? = nil, limit: Int) throws(Failure) -> Data {
        guard startsWithFrame(data) else { throw .notZstandard }
        // The declared size of the first frame, when it has one, settles the cap without decoding.
        let declared = data.withUnsafeBytes { ZSTD_getFrameContentSize($0.baseAddress, $0.count) }
        if declared != ZSTD_CONTENTSIZE_UNKNOWN, declared != ZSTD_CONTENTSIZE_ERROR, declared > UInt64(limit) {
            throw .tooLarge
        }
        // Creating a context fails only when malloc does.
        let context = ZSTD_createDCtx()!
        defer { ZSTD_freeDCtx(context) }
        try check(ZSTD_DCtx_setParameter(context, ZSTD_d_windowLogMax, windowLogMax))
        if let dictionary {
            try check(dictionary.withUnsafeBytes { ZSTD_DCtx_loadDictionary(context, $0.baseAddress, $0.count) })
        }
        let source = [UInt8](data)
        // withUnsafeBytes rethrows untyped errors, so the result comes out as a Result.
        return try source.withUnsafeBytes { raw in
            Result { () throws(Failure) -> Data in try decode(raw, context: context, limit: limit) }
        }.get()
    }

    /// Runs the streaming decoder over `source` until its frames end.
    private static func decode(_ source: UnsafeRawBufferPointer, context: OpaquePointer, limit: Int) throws(Failure) -> Data {
        let chunk = ZSTD_DStreamOutSize()
        var buffer = [UInt8](repeating: 0, count: chunk)
        var output = Data()
        var input = ZSTD_inBuffer(src: source.baseAddress, size: source.count, pos: 0)
        // The hint the last call returned: 0 when a frame has just ended.
        var hint = 1
        while true {
            if hint == 0 {
                // A frame ended: carry on only into another frame.
                let rest = UnsafeRawBufferPointer(rebasing: source[input.pos...])
                guard startsWithFrame(rest) else { return output }
            }
            let before = input.pos
            let produced = buffer.withUnsafeMutableBytes { target -> (Int, Int) in
                var out = ZSTD_outBuffer(dst: target.baseAddress, size: target.count, pos: 0)
                let result = ZSTD_decompressStream(context, &out, &input)
                return (result, out.pos)
            }
            try check(produced.0)
            hint = produced.0
            output.append(contentsOf: buffer[..<produced.1])
            if output.count > limit { throw .tooLarge }
            // The library consumes input or fills output on every call that has either to give;
            // a call that does neither has nothing more to read: the input ended inside a frame.
            if input.pos == before && produced.1 == 0 {
                throw .truncated
            }
        }
    }

    /// Throws the library's error for a result that is one.
    private static func check(_ result: Int) throws(Failure) {
        if ZSTD_isError(result) != 0 {
            throw .damaged(String(cString: ZSTD_getErrorName(result)))
        }
    }
}
