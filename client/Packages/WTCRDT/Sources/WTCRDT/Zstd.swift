import CZstd

/// zstd compression for snapshots (docs/spec/crdt-model.adoc, "Snapshots"), over the vendored
/// single-file library (`CZstd`).  wt-crdt uses zstd-jni; both read and write standard zstd
/// frames, so either side decompresses what the other compressed.
public enum Zstd {
    /// Why bytes could not be decompressed.
    public struct Failure: Error, Equatable, CustomStringConvertible {
        public let description: String
    }

    /// The level snapshots are compressed at (zstd's default).
    public static let level: Int32 = 3

    /// `data` as one zstd frame (with its content size).
    public static func compress(_ data: [UInt8], level: Int32 = level) -> [UInt8] {
        var out = [UInt8](repeating: 0, count: ZSTD_compressBound(data.count))
        let written = out.withUnsafeMutableBytes { target in
            data.withUnsafeBytes { source in
                ZSTD_compress(target.baseAddress, target.count, source.baseAddress, source.count, level)
            }
        }
        // ZSTD_compress cannot fail with a ZSTD_compressBound-sized buffer and a valid level.
        out.removeSubrange(written...)
        return out
    }

    /// Decompresses one zstd frame of exactly `size` bytes of content.
    public static func decompress(_ data: [UInt8], size: Int) throws(Failure) -> [UInt8] {
        var out = [UInt8](repeating: 0, count: size)
        let written = out.withUnsafeMutableBytes { target in
            data.withUnsafeBytes { source in
                ZSTD_decompress(target.baseAddress, target.count, source.baseAddress, source.count)
            }
        }
        if ZSTD_isError(written) != 0 {
            throw Failure(description: "zstd: \(String(cString: ZSTD_getErrorName(written)))")
        }
        guard written == size else {
            throw Failure(description: "zstd: \(written) bytes of content, expected \(size)")
        }
        return out
    }
}
