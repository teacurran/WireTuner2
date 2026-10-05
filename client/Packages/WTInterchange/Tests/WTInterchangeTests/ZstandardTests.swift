// D-098: the Zstandard decoder over the vendored reference library.  Two kinds of fixture, none
// from a third party: frames the reference command-line tool wrote (zstd 1.5.7, the commands
// beside each), checked in as their bytes, and frames the tests compress at run time with the
// same reference library (`CZstd`'s compressor) -- with and without checksums and declared
// sizes, in many blocks and frames, with dictionaries -- then damaged, cut short and capped.

import CZstd
import Foundation
import Testing
@testable import WTInterchange

@Suite struct ZstandardTests {
    // MARK: Fixtures the reference tool wrote

    /// `printf 'Hello, Zstandard.\n' | zstd -c`: from a pipe, so no declared size (as
    /// Illustrator writes its frames), with the tool's default XXH64 checksum; one raw block.
    static let hello = Data(base64Encoded: "KLUv/QRYkQAASGVsbG8sIFpzdGFuZGFyZC4KVoxFBQ==")!

    /// `yes 'WireTuner zstd fixture: one line of a multi-block frame.' | head -c 400000 | zstd -19 -c`:
    /// 400,000 bytes in four blocks (a block holds at most 128 KiB), with a checksum.
    static let blocks = Data(base64Encoded: "KLUv/QRo7AEAkoMMEaDtMKT5rFlAajlD3SuZfk+MQCgzvVfIrRMYrshuvu7aeF2b+9COUPI+wTff2iLR5hIBAEn8z3MFBUQAAAABAP3/PFdARAAAAAEA/f85AAI9AAAAAQB92gMgdwo/iA==")!

    static var blocksContent: Data {
        let line = "WireTuner zstd fixture: one line of a multi-block frame.\n"
        return Data(String(repeating: line, count: 400_000 / line.utf8.count + 1).utf8.prefix(400_000))
    }

    /// A 1 KiB dictionary in zstd's format (ID 1701958943) trained by the tool on 400 layer
    /// records: `for i in $(seq 1 400); do printf '%%AI5_BeginLayer\r%d 1 1 1 0 0 %d 79 128 255 0 50 Lb\r(Layer %d) Ln\r%%AI5_EndLayer--\r' $((i%2)) $((i%7)) $i > samples/s$i; done;
    /// zstd --train samples/* -o dict --maxdict=1024`.
    static let dictionary = Data(base64Encoded: """
    N6Qw7B/VcWUnEDC7kQ7wF2nDX6QNf5E2/EXaDAAAAAAAAAAAAHYIIXtvuQcAAJAO4wgAAAAQh5oRAAAEAAAAAAADAwBBAAAOAJYA\
    AAAAqEogBADgqmkAAAAAsACAAQAAAAC0KhwIBwAAAAAAAAAAAAAAAAAAAQAAAAQAAAAIAAAAZ2luTGF5ZXINMCAxIDEgMSAwIDAg\
    NiA3OSAxMjggMjU1IDAgNTAgTGINKExheWVyIDI4NikgTG4NJUFJNV9FbmRMYXllci0tDSVBSTVfQmVnaW5MYXllcg0wIDEgMSAx\
    IDAgMCAzIDc5IDEyOCAyNTUgMCA1MCBMYg0oTGF5ZXIgODApIExuDSVBSTVfRW5kTGF5ZXItLQ0lQUk1X0JlZ2luTGF5ZXINMSAx\
    IDEgMSAwIDAgMiA3OSAxMjggMjU1IDAgNTAgTGINKExheWVyIDE0OSkgTG4NJUFJNV9FbmRMYXllci0tDSVBSTVfQmVnaW5MYXll\
    cg0wIDEgMSAxIDAgMCA1IDc5IDEyOCAyNTUgMCA1MCBMYg0oTGF5ZXIgMjIyKSBMbg0lQUk1X0VuZExheWVyLS0NJUFJNV9CZWdp\
    bkxheWVyDTAgMSAxIDEgMCAwIDMgNzkgMTI4IDI1NSAwIDUwIExiDShMYXllciAxNzgpIExuDSVBSTVfRW5kTGF5ZXItLQ0lQUk1\
    X0JlZ2luTGF5ZXINMSAxIDEgMSAwIDAgNSA3OSAxMjggMjU1IDAgNTAgTGINKExheWVyIDI0MykgTG4NJUFJNV9FbmRMYXllci0t\
    DSVBSTVfQmVnaW5MYXllcmluTGF5ZXINMSAxIDEgMSAwIDAgNSA3OSAxMjggMjU1IDAgNTAgTGINKExheWVyIDEzMSkgTG4NJUFJ\
    NV9FbmRMYXllci0tDSVBSTVfQmVnaW5MYXllcg0wIDEgMSAxIDAgMCA2IDc5IDEyOCAyNTUgMCA1MCBMYg0oTGF5ZXIgMjMwKSBM\
    bg0lQUk1X0VuZExheWVyLS0NJUFJNV9CZWdpbkxheWVyDTAgMSAxIDEgMCAwIDEgNzkgMTI4IDI1NSAwIDUwIExiDShMYXllciAy\
    NzQpIExuDSVBSTVfRW5kTGF5ZXItLQ0lQUk1X0JlZ2luTGF5ZXINMSAxIDEgMSAwIDAgMiA3OSAxMjggMjU1IDAgNTAgTGINKExh\
    eWVyIDM4NykgTG4NJUFJNV9FbmRMYXllci0tDSVBSTVfQmVnaW5MYXllcg0xIDEgMSAxIDAgMCAzIDc5IDEyOCAyNTUgMCA1MCBM\
    Yg0oTGF5ZXIgNTkpIExuDSVBSTVfRW5kTGF5ZXItLQ0lQUk1X0JlZ2luTGF5ZXINMA==
    """)!

    /// One more record compressed with that dictionary:
    /// `printf '%%AI5_BeginLayer\r1 1 1 1 0 0 3 79 128 255 0 50 Lb\r(Dictionary layer) Ln\r%%AI5_EndLayer--\r' | zstd -19 -D dict -c`.
    static let withDictionary = Data(base64Encoded: "KLUv/QdoH9VxZdUAAHAlRGljdGlvbmFyeSBsKQPAa6AAVtkdo/Ajh7jN/w==")!
    static let withDictionaryContent = Data("%AI5_BeginLayer\r1 1 1 1 0 0 3 79 128 255 0 50 Lb\r(Dictionary layer) Ln\r%AI5_EndLayer--\r".utf8)

    // MARK: Frames compressed here with the reference library

    /// `data` as one frame: at `level`, with an XXH64 checksum when `checksum`, its size declared
    /// unless `streamed` (written by the streaming compressor without a pledged size, as
    /// Illustrator's are), with `dictionary` (zstd's format or raw content) and `windowLog`.
    static func compress(_ data: Data, level: Int32 = 3, checksum: Bool = true, streamed: Bool = false, dictionary: Data? = nil, windowLog: Int32 = 0) -> Data {
        let context = ZSTD_createCCtx()!
        defer { ZSTD_freeCCtx(context) }
        ZSTD_CCtx_setParameter(context, ZSTD_c_compressionLevel, level)
        ZSTD_CCtx_setParameter(context, ZSTD_c_checksumFlag, checksum ? 1 : 0)
        ZSTD_CCtx_setParameter(context, ZSTD_c_windowLog, windowLog)
        if let dictionary {
            _ = dictionary.withUnsafeBytes { ZSTD_CCtx_loadDictionary(context, $0.baseAddress, $0.count) }
        }
        let source = [UInt8](data)
        var output = [UInt8](repeating: 0, count: ZSTD_compressBound(source.count) + 1024)
        let written = output.withUnsafeMutableBytes { target in
            source.withUnsafeBytes { raw -> Int in
                if !streamed {
                    return ZSTD_compress2(context, target.baseAddress, target.count, raw.baseAddress, raw.count)
                }
                var input = ZSTD_inBuffer(src: raw.baseAddress, size: raw.count, pos: 0)
                var out = ZSTD_outBuffer(dst: target.baseAddress, size: target.count, pos: 0)
                // Fed in pieces with no pledged size: the frame declares none.
                while input.pos < input.size {
                    let piece = min(input.size - input.pos, 1 << 16)
                    var part = ZSTD_inBuffer(src: raw.baseAddress! + input.pos, size: piece, pos: 0)
                    _ = ZSTD_compressStream2(context, &out, &part, ZSTD_e_continue)
                    input.pos += part.pos
                }
                while ZSTD_compressStream2(context, &out, &input, ZSTD_e_end) != 0 {}
                return out.pos
            }
        }
        precondition(ZSTD_isError(written) == 0, "compress")
        return Data(output[..<written])
    }

    /// `count` bytes that compress partly: runs of text with pseudo-random bytes between them.
    static func mixed(_ count: Int, seed: UInt64 = 7) -> Data {
        var random = SeededRandom(seed: seed)
        var bytes: [UInt8] = []
        bytes.reserveCapacity(count)
        let words = Array("%AI5_BeginLayer Lb Ln /ArtDictionary /XMLUID (Artboard 1) ".utf8)
        while bytes.count < count {
            if random.next() % 3 == 0 {
                for _ in 0..<(random.next() % 64) { bytes.append(UInt8(truncatingIfNeeded: random.next())) }
            } else {
                let start = Int(random.next() % UInt64(words.count))
                bytes += words[start...]
            }
        }
        return Data(bytes.prefix(count))
    }

    /// A skippable frame (RFC 8878, 3.1.2) holding `payload`.
    static func skippable(_ payload: Data, variant: UInt8 = 0) -> Data {
        let size = UInt32(payload.count)
        return Data([0x50 | variant, 0x2A, 0x4D, 0x18, UInt8(size & 0xFF), UInt8(size >> 8 & 0xFF), UInt8(size >> 16 & 0xFF), UInt8(size >> 24)]) + payload
    }

    static func decode(_ data: Data, dictionary: Data? = nil, limit: Int = 1 << 30) -> Result<Data, Zstandard.Failure> {
        Result { () throws(Zstandard.Failure) -> Data in try Zstandard.decompress(data, dictionary: dictionary, limit: limit) }
    }

    // MARK: Decoding

    @Test func framesTheReferenceToolWroteDecode() throws {
        #expect(try Zstandard.decompress(Self.hello, limit: 100) == Data("Hello, Zstandard.\n".utf8))
        let content = try Zstandard.decompress(Self.blocks, limit: 1 << 20)
        #expect(content.count == 400_000 && content == Self.blocksContent)
        // The frame names its dictionary; without it (or with another) the library refuses it.
        #expect(try Zstandard.decompress(Self.withDictionary, dictionary: Self.dictionary, limit: 1000) == Self.withDictionaryContent)
        #expect(Self.decode(Self.withDictionary) == .failure(.damaged("Dictionary mismatch")))
        #expect(Self.decode(Self.withDictionary, dictionary: Data("raw content".utf8)) == .failure(.damaged("Dictionary mismatch")))
        // A damaged dictionary in zstd's format is refused when loaded.
        var damaged = Self.dictionary
        damaged.replaceSubrange(8..<40, with: Data(repeating: 0xFF, count: 32))
        if case .failure(.damaged) = Self.decode(Self.withDictionary, dictionary: damaged) {} else { Issue.record("damaged dictionary") }
    }

    @Test func framesTheLibraryWritesDecode() throws {
        let data = Self.mixed(700_000)
        for level: Int32 in [1, 3, 19] {
            for checksum in [true, false] {
                for streamed in [true, false] {
                    let frame = Self.compress(data, level: level, checksum: checksum, streamed: streamed)
                    #expect(try Zstandard.decompress(frame, limit: 1 << 20) == data, "level \(level) checksum \(checksum) streamed \(streamed)")
                }
            }
        }
        // Empty content, declared or not.
        #expect(try Zstandard.decompress(Self.compress(Data()), limit: 0).isEmpty)
        #expect(try Zstandard.decompress(Self.compress(Data(), streamed: true), limit: 0).isEmpty)
        // A raw-content dictionary.
        let dictionary = Self.mixed(4_000, seed: 3)
        let sample = Self.mixed(3_000, seed: 3).suffix(1_000) + Data("tail".utf8)
        #expect(try Zstandard.decompress(Self.compress(sample, dictionary: dictionary), dictionary: dictionary, limit: 10_000) == sample)
    }

    @Test func framesFollowOneAnotherAndWhatFollowsThemIsIgnored() throws {
        let one = Self.mixed(200_000, seed: 1)
        let two = Self.mixed(5_000, seed: 2)
        let joined = Self.compress(one, streamed: true) + Self.skippable(Data("skip me".utf8), variant: 0xF) + Self.hello + Self.compress(two)
        #expect(try Zstandard.decompress(joined, limit: 1 << 20) == one + Data("Hello, Zstandard.\n".utf8) + two)
        // A skippable frame first, an empty one, then trailing bytes that are not a frame.
        let framed = Self.skippable(Data()) + Self.hello + Data("%%EOF\r".utf8)
        #expect(try Zstandard.decompress(framed, limit: 100) == Data("Hello, Zstandard.\n".utf8))
        // Only skippable frames: nothing.
        #expect(try Zstandard.decompress(Self.skippable(Data([1, 2, 3])), limit: 100).isEmpty)
        // A slice of a larger buffer reads from its own start.
        let sliced = (Data("prefix".utf8) + Self.hello).dropFirst(6)
        #expect(try Zstandard.decompress(sliced, limit: 100) == Data("Hello, Zstandard.\n".utf8))
    }

    @Test func whatIsNotZstandardIsRefused() {
        for data in [Data(), Data([0x28, 0xB5, 0x2F]), Data("%AI12_CompressedData".utf8), Data([0x51, 0x2A, 0x4D, 0x19])] {
            #expect(Self.decode(data) == .failure(.notZstandard))
        }
        #expect(Zstandard.startsWithFrame([0x5F, 0x2A, 0x4D, 0x18]) && !Zstandard.startsWithFrame([0x60, 0x2A, 0x4D, 0x18]))
        #expect(Zstandard.startsWithFrame(Self.hello) && !Zstandard.startsWithFrame(Data([0x28])))
    }

    // MARK: Damage

    @Test func aBadChecksumIsAnError() {
        var frame = Self.hello
        frame[frame.count - 1] ^= 0x01
        #expect(Self.decode(frame) == .failure(.damaged("Restored data doesn't match checksum")))
        var big = Self.compress(Self.mixed(300_000), streamed: true)
        big[big.count - 2] ^= 0x80
        #expect(Self.decode(big) == .failure(.damaged("Restored data doesn't match checksum")))
    }

    @Test func aCutOffFrameIsAnError() {
        // Every proper prefix of a frame (and of two) fails; none decodes as if it were whole.
        // (Two frames cut after the first, or inside the second's magic number, are the first.)
        let two = Self.hello + Self.blocks
        for frame in [Self.hello, Self.blocks, two] {
            for length in 4..<frame.count where !(frame == two && (Self.hello.count..<Self.hello.count + 4).contains(length)) {
                switch Self.decode(frame.prefix(length)) {
                case .success: Issue.record("prefix \(length) of \(frame.count) decoded")
                case .failure(.notZstandard): Issue.record("prefix \(length) not recognised")
                case .failure: break
                }
            }
        }
        #expect(Self.decode(Self.hello.prefix(10)) == .failure(.truncated))
        let streamed = Self.compress(Self.mixed(400_000), streamed: true)
        #expect(Self.decode(streamed.prefix(streamed.count / 2)) == .failure(.truncated))
    }

    /// Damaged frames -- bytes changed, bytes dropped, garbage after the magic number -- must
    /// fail or decode, never crash, hang or run past the cap.
    @Test func damagedFramesFailCleanly() {
        var random = SeededRandom(seed: 98)
        let frames = [Self.hello, Self.blocks, Self.compress(Self.mixed(150_000), level: 19, streamed: true), Self.compress(Self.mixed(60_000), checksum: false)]
        let clock = ContinuousClock()
        let started = clock.now
        var failures = 0
        for round in 0..<3_000 {
            var frame = frames[round % frames.count]
            switch round % 3 {
            case 0:
                for _ in 0...(random.next() % 8) {
                    let at = 4 + Int(random.next() % UInt64(frame.count - 4))
                    frame[at] = UInt8(truncatingIfNeeded: random.next())
                }
            case 1:
                let at = 4 + Int(random.next() % UInt64(frame.count - 4))
                frame.removeSubrange(at..<min(frame.count, at + 1 + Int(random.next() % 16)))
            default:
                frame = frame.prefix(4) + Data((0..<(random.next() % 256)).map { _ in UInt8(truncatingIfNeeded: random.next()) })
            }
            switch Self.decode(frame, limit: 1 << 20) {
            case .success(let content): #expect(content.count <= 1 << 20)
            case .failure(let failure): #expect(failure != .notZstandard); failures += 1
            }
        }
        #expect(failures > 2_000)
        #expect(clock.now - started < .seconds(60))
    }

    // MARK: Limits

    @Test func contentPastTheLimitIsRefused() {
        let zeros = Data(count: 3_000_000)
        // Declared: refused from the header, before decoding.
        #expect(Self.decode(Self.compress(zeros), limit: 1_000_000) == .failure(.tooLarge))
        // Not declared (as Illustrator's): refused as the output grows past the limit.
        let streamed = Self.compress(zeros, streamed: true)
        #expect(Self.decode(streamed, limit: 1_000_000) == .failure(.tooLarge))
        #expect(Self.decode(streamed, limit: 3_000_000) == .success(zeros))
        // Over several frames.
        #expect(Self.decode(Self.hello + Self.hello, limit: 30) == .failure(.tooLarge))
        #expect(Self.decode(Self.hello + Self.hello, limit: 36).map(\.count) == .success(36))
    }

    @Test func aFrameAskingForMoreThanA128MiBWindowIsRefused() {
        // Written with a 256 MiB window and no declared size, the frame header asks for all of it.
        let frame = Self.compress(Self.mixed(10_000), streamed: true, windowLog: 28)
        #expect(Self.decode(frame) == .failure(.damaged("Frame requires too much memory for decoding")))
        #expect(Self.decode(Self.compress(Self.mixed(10_000), streamed: true, windowLog: 27)) == .success(Self.mixed(10_000)))
    }
}
