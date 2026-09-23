// IO-005 and IO-006: the `.wiretuner` package -- the zip container, the manifest's protobuf JSON,
// the writer's blob collection, thumbnail and preview, and the reader's validation.

import CoreGraphics
import Foundation
import ImageIO
import Testing
import WTGeometry
@testable import WTInterchange
import WTRender

private enum PackageFixtures {
    static let snapshot = Data((0..<4096).map { UInt8(truncatingIfNeeded: $0 &* 31) })

    static var page: ExportScene {
        Corpus.scene([Corpus.page([
            Corpus.path(Corpus.rect(10, 10, 100, 60), [Corpus.fill(.solid(Corpus.red))]),
            Corpus.text("Package"),
        ], width: 400, height: 300)])
    }

    static var manifest: PackageManifest {
        PackageManifest(originDocumentID: "01926a3c-0000-7000-8000-000000000001", title: "Poster “draft”", exportedBy: "user-1", exportedByName: "Terry", exportedAtMs: 1_790_000_000_000, appVersion: "1.0 (42)", featureLevel: 3, mergeTableVersion: 7, headServerSeq: 9_007_199_254_740_993, unsyncedChanges: 4, stateHash: Data(repeating: 0xAB, count: 32))
    }

    static func contents(blobs: [PackageBlobSource] = []) -> PackageContents {
        PackageContents(manifest: manifest, snapshot: snapshot, blobs: blobs, firstPage: page)
    }

    static let reader = PackageReader(featureLevel: 3, mergeTableVersion: 7)

    /// A zip of `entries`, stored.
    static func zip(_ entries: [(String, Data)], method: ZipMethod = .stored) throws -> Data {
        var data = Data()
        let writer = ZipWriter { data.append($0) }
        for (name, bytes) in entries {
            try writer.add(name, data: bytes, method: method)
        }
        try writer.finish()
        return data
    }

    static func run(_ tool: String, _ arguments: [String], in directory: URL) throws -> (status: Int32, output: String, data: Data) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: tool)
        process.arguments = arguments
        process.currentDirectoryURL = directory
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        try process.run()
        let output = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (process.terminationStatus, String(decoding: output, as: UTF8.self), output)
    }

    static func directory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("wt-package-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}

@Suite("Packages")
struct PackageTests {
    // MARK: Zip

    @Test func zipEntriesRoundTripStoredAndDeflated() throws {
        let text = Data(String(repeating: "wiretuner ", count: 500).utf8)
        let random = Data((0..<257).map { UInt8(truncatingIfNeeded: $0 &* 197 &+ 13) })
        let data = try PackageFixtures.zip([("a.txt", text), ("b.bin", random), ("empty", Data()), ("dir/ü.txt", Data("ü".utf8))], method: .deflate)
        let reader = try ZipReader(data: data)
        #expect(reader.names == ["a.txt", "b.bin", "empty", "dir/ü.txt"])
        #expect(reader.entry("a.txt")?.method == ZipMethod.deflate.rawValue)
        #expect(reader.entry("a.txt")!.compressedSize < text.count)
        // Incompressible data is stored even when deflate is asked for.
        #expect(reader.entry("empty")?.method == ZipMethod.stored.rawValue)
        #expect(try reader.contents(of: "a.txt") == text)
        #expect(try reader.contents(of: "b.bin") == random)
        #expect(try reader.contents(of: "empty") == Data())
        #expect(try reader.contents(of: "dir/ü.txt") == Data("ü".utf8))
        #expect(throws: ZipError.missing("c")) { try reader.contents(of: "c") }
        // A reader over a slice of a larger buffer (a mapped file's subrange) reads the same.
        let slice = (Data([1, 2, 3]) + data).dropFirst(3)
        #expect(try ZipReader(data: slice).contents(of: "a.txt") == text)
    }

    @Test func zipsInteroperateWithTheSystemTools() throws {
        let directory = try PackageFixtures.directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let ours = directory.appendingPathComponent("ours.zip")
        try PackageFixtures.zip([("hello.txt", Data(String(repeating: "hello ", count: 100).utf8)), ("raw.bin", Data([0, 1, 2]))], method: .deflate).write(to: ours)
        let test = try PackageFixtures.run("/usr/bin/unzip", ["-t", ours.path], in: directory)
        #expect(test.status == 0, "\(test.output)")
        // A zip written by Info-ZIP from a pipe carries data descriptors and extra fields.
        try Data(String(repeating: "theirs ", count: 200).utf8).write(to: directory.appendingPathComponent("theirs.txt"))
        let made = try PackageFixtures.run("/usr/bin/zip", ["-q", "-", "theirs.txt"], in: directory)
        #expect(made.status == 0)
        let theirs = try ZipReader(data: made.data)
        #expect(theirs.entries[0].flags & 0x0008 != 0)
        #expect(try theirs.contents(of: "theirs.txt") == Data(String(repeating: "theirs ", count: 200).utf8))
    }

    @Test func damagedZipsAreRefused() throws {
        #expect(throws: ZipError.malformed("it is too short to be a zip archive")) { try ZipReader(data: Data("PK".utf8)) }
        #expect(throws: ZipError.malformed("it has no end of central directory record")) { try ZipReader(data: Data(repeating: 0, count: 100)) }
        let good = try PackageFixtures.zip([("a", Data("abcdef".utf8))])
        var bytes = [UInt8](good)
        let end = bytes.count - 22
        // A directory said to start past the end record.
        var outside = bytes
        outside[end + 16] = 0xFF
        #expect(throws: ZipError.malformed("its central directory lies outside the file")) { try ZipReader(data: Data(outside)) }
        // zip64 markers.
        var zip64 = bytes
        zip64[end + 10] = 0xFF
        zip64[end + 11] = 0xFF
        #expect(throws: ZipError.unsupported("zip64")) { try ZipReader(data: Data(zip64)) }
        // A damaged directory entry signature.
        let directoryStart = Int(bytes[end + 16]) | Int(bytes[end + 17]) << 8
        var badEntry = bytes
        badEntry[directoryStart] = 0
        #expect(throws: ZipError.malformed("its central directory is damaged")) { try ZipReader(data: Data(badEntry)) }
        // A name running past the directory.
        var longName = bytes
        longName[directoryStart + 28] = 0xFF
        #expect(throws: ZipError.malformed("its central directory is damaged")) { try ZipReader(data: Data(longName)) }
        // A flipped data byte fails the CRC.
        bytes[30 + 1 + 2] ^= 0xFF
        let flipped = try ZipReader(data: Data(bytes))
        #expect(throws: ZipError.corrupt("a")) { try flipped.contents(of: "a") }
        // A missing local header, encryption, an unknown method, data past the end.
        var header = [UInt8](good)
        header[0] = 0
        #expect(throws: ZipError.self) { try ZipReader(data: Data(header)).contents(of: "a") }
        var encrypted = [UInt8](good)
        encrypted[directoryStart + 8] |= 1
        #expect(throws: ZipError.unsupported("encryption")) { try ZipReader(data: Data(encrypted)).contents(of: "a") }
        var method = [UInt8](good)
        method[directoryStart + 10] = 12
        #expect(throws: ZipError.unsupported("compression method 12")) { try ZipReader(data: Data(method)).contents(of: "a") }
        var size = [UInt8](good)
        size[directoryStart + 20] = 0xFF
        #expect(throws: ZipError.corrupt("a")) { try ZipReader(data: Data(size)).contents(of: "a") }
        // An empty entry marked deflated reads as empty.
        let empty = try PackageFixtures.zip([("e", Data())])
        var emptyBytes = [UInt8](empty)
        let emptyEnd = emptyBytes.count - 22
        let emptyDirectory = Int(emptyBytes[emptyEnd + 16]) | Int(emptyBytes[emptyEnd + 17]) << 8
        emptyBytes[emptyDirectory + 10] = 8
        #expect(try ZipReader(data: Data(emptyBytes)).contents(of: "e") == Data())
        // Deflated bytes that do not inflate.
        let deflated = try PackageFixtures.zip([("t", Data(String(repeating: "x", count: 300).utf8))], method: .deflate)
        var garbled = [UInt8](deflated)
        for index in 31..<36 { garbled[index] = 0xFF }
        #expect(throws: ZipError.self) { try ZipReader(data: Data(garbled)).contents(of: "t") }
        for error in [ZipError.malformed("x"), .unsupported("x"), .corrupt("x"), .tooLarge, .missing("x"), .writeFailed("x")] {
            #expect(!error.description.isEmpty)
        }
    }

    @Test func dosTimestampsEncodeTheDate() {
        var parts = DateComponents()
        parts.year = 2026
        parts.month = 9
        parts.day = 23
        parts.hour = 10
        parts.minute = 30
        parts.second = 42
        let date = Calendar(identifier: .gregorian).date(from: parts)!
        let stamp = ZipWriter.dosTimestamp(date)
        #expect(stamp.date == UInt16(46 << 9 | 9 << 5 | 23))
        #expect(stamp.time == UInt16(10 << 11 | 30 << 5 | 21))
        #expect(ZipWriter.dosTimestamp(Date(timeIntervalSince1970: 0)).date >> 9 == 0)
    }

    // MARK: Manifest

    @Test func manifestIsProtobufJSON() throws {
        var manifest = PackageFixtures.manifest
        manifest.blobs = [PackageBlob(sha256: Data(repeating: 1, count: 32), size: 10, mediaType: "image/png", name: "a.png")]
        manifest.missingBlobs = [PackageBlob(sha256: Data(repeating: 2, count: 32), size: 0, mediaType: "font/otf")]
        let json = manifest.jsonData()
        let text = String(decoding: json, as: UTF8.self)
        #expect(text.hasPrefix("{\"format\":\"wiretuner-package\",\"formatVersion\":1,\"originDocumentId\":"))
        #expect(text.contains("\"exportedAtMs\":\"1790000000000\""))
        #expect(text.contains("\"headServerSeq\":\"9007199254740993\""))
        #expect(text.contains("\"featureLevel\":3"))
        #expect(text.contains("\"size\":\"10\""))
        #expect(!text.contains("\"size\":\"0\""))
        #expect(text.contains("Poster “draft”"))
        #expect(try PackageManifest(jsonData: json) == manifest)
        // Defaults are omitted.
        #expect(String(decoding: PackageManifest(format: "").jsonData(), as: UTF8.self) == "{\"formatVersion\":1}")
    }

    @Test func manifestParsingAcceptsEitherSpelling() throws {
        let hash = Data(repeating: 0xFB, count: 32)
        let urlSafe = hash.base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
        let json = """
        {"format":"wiretuner-package","format_version":1,"feature_level":2,"head_server_seq":12,
         "exported_at_ms":"-5","state_hash":"\(urlSafe)","title":null,
         "missing_blobs":[{"sha256":"\(hash.base64EncodedString())","media_type":"image/jpeg","size":3}]}
        """
        let manifest = try PackageManifest(jsonData: Data(json.utf8))
        #expect(manifest.formatVersion == 1)
        #expect(manifest.featureLevel == 2)
        #expect(manifest.headServerSeq == 12)
        #expect(manifest.exportedAtMs == -5)
        #expect(manifest.stateHash == hash)
        #expect(manifest.title == "")
        #expect(manifest.missingBlobs[0].mediaType == "image/jpeg")
        #expect(manifest.missingBlobs[0].size == 3)
        let bad: [String] = [
            "[]", "not json", "{\"format\":3}", "{\"featureLevel\":\"x\"}", "{\"featureLevel\":1.5}",
            "{\"featureLevel\":true}", "{\"featureLevel\":-1}", "{\"stateHash\":\"***\"}", "{\"stateHash\":4}", "{\"blobs\":{}}",
        ]
        for text in bad {
            #expect(throws: PackageError.self, "\(text)") { try PackageManifest(jsonData: Data(text.utf8)) }
        }
        #expect(PackageManifest.standardBase64("YQ") == "YQ==")
    }

    // MARK: Writing

    @Test func packagesHoldEverythingInOrder() throws {
        let image = ImageFixtures.png(width: 6, height: 4)
        let font = Data("OTTO font bytes".utf8)
        let missing = Data(repeating: 7, count: 32)
        let blobs = [
            PackageBlobSource(data: image, mediaType: "image/png", name: "photo.png"),
            PackageBlobSource(data: font, mediaType: "font/otf"),
            PackageBlobSource(data: image, mediaType: "image/png", name: "photo again"),
            PackageBlobSource(sha256: missing, mediaType: "image/jpeg", name: "gone.jpg", data: nil),
            PackageBlobSource(sha256: Data(repeating: 8, count: 32), mediaType: "image/jpeg", data: Data("wrong bytes".utf8)),
        ]
        let (data, summary) = try PackageWriter().data(PackageFixtures.contents(blobs: blobs))
        #expect(summary.wrotePreview)
        #expect(summary.manifest.blobs.count == 2)
        #expect(summary.manifest.missingBlobs.map(\.name) == ["gone.jpg", ""])
        #expect(summary.notes.count == 2)
        #expect(summary.notes[0].contains("gone.jpg"))
        let zip = try ZipReader(data: data)
        let imageHex = ImportedBlob.hex(ImportedBlob.hash(image))
        let fontHex = ImportedBlob.hex(ImportedBlob.hash(font))
        #expect(zip.names == ["manifest.json", "snapshot.pb.zst", "blobs/\(imageHex)", "blobs/\(fontHex)", "thumbnail.png", "preview.pdf"])
        #expect(zip.entry("snapshot.pb.zst")?.method == ZipMethod.stored.rawValue)

        let opened = try PackageFixtures.reader.open(data)
        #expect(opened.snapshot == PackageFixtures.snapshot)
        #expect(opened.manifest.title == "Poster “draft”")
        #expect(opened.manifest.unsyncedChanges == 4)
        #expect(opened.manifest.stateHash == Data(repeating: 0xAB, count: 32))
        #expect(opened.manifest.format == PackageManifest.formatName)
        #expect(opened.blobs.count == 2)
        #expect(opened.data(for: opened.manifest.blobs[0]) == image)
        #expect(opened.data(for: opened.manifest.missingBlobs[0]) == nil)

        // The thumbnail: 1024 px on the long edge, with alpha.
        let thumbnail = try #require(opened.thumbnail)
        let source = try #require(CGImageSourceCreateWithData(thumbnail as CFData, nil))
        let properties = try #require(CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any])
        #expect(properties[kCGImagePropertyPixelWidth] as? Int == 1024)
        #expect(properties[kCGImagePropertyPixelHeight] as? Int == 768)
        #expect(properties[kCGImagePropertyHasAlpha] as? Bool == true)
        // The preview: a valid one-page PDF of page 1.
        let preview = try #require(opened.preview)
        let document = try #require(CGPDFDocument(CGDataProvider(data: preview as CFData)!))
        #expect(document.numberOfPages == 1)
        #expect(document.page(at: 1)?.getBoxRect(.mediaBox).width == 400)
        // The Quick Look paths read one entry each.
        #expect(try PackageReader.manifest(of: data).title == "Poster “draft”")
        #expect(try PackageReader.thumbnail(of: data) == thumbnail)
    }

    @Test func thePreviewIsPageOneOnly() throws {
        var scene = PackageFixtures.page
        scene.pages.append(Corpus.page([Corpus.path(Corpus.rect(0, 0, 5, 5), [Corpus.fill(.solid(Corpus.blue))])]))
        let pdf = try PackageWriter.preview(scene)
        #expect(CGPDFDocument(CGDataProvider(data: pdf as CFData)!)?.numberOfPages == 1)
        #expect(PackageWriter.previewOptions.fonts == .embedSubset)
        #expect(!PackageWriter.previewOptions.embedPackage)
    }

    @Test func aFailedPreviewIsSkippedAndTolerated() throws {
        struct Failure: Error {}
        let writer = PackageWriter { _ in throw Failure() }
        let provided = ImageFixtures.png(width: 4, height: 3)
        var contents = PackageFixtures.contents()
        contents.thumbnail = provided
        let (data, summary) = try writer.data(contents)
        #expect(!summary.wrotePreview)
        #expect(summary.notes.contains { $0.contains("preview") })
        let opened = try PackageFixtures.reader.open(data)
        #expect(opened.preview == nil)
        #expect(opened.thumbnail == provided)
    }

    @Test func packagesStreamToDisk() throws {
        let directory = try PackageFixtures.directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("Poster.wiretuner")
        let summary = try PackageWriter().write(PackageFixtures.contents(blobs: [PackageBlobSource(data: Data("blob".utf8), mediaType: "application/octet-stream")]), to: url)
        #expect(summary.manifest.blobs.count == 1)
        let opened = try PackageFixtures.reader.open(contentsOf: url)
        #expect(opened.blobs.count == 1)
        #expect(try PackageFixtures.run("/usr/bin/unzip", ["-t", url.path], in: directory).status == 0)
        #expect(throws: PackageError.self) {
            try PackageWriter().write(PackageFixtures.contents(), to: directory.appendingPathComponent("missing/dir/x.wiretuner"))
        }
        #expect(throws: PackageError.self) {
            try PackageFixtures.reader.open(contentsOf: directory.appendingPathComponent("absent.wiretuner"))
        }
        var empty = PackageFixtures.contents()
        empty.firstPage.pages = []
        #expect(throws: PackageError.nothingToExport) { try PackageWriter().data(empty) }
        // A sink that fails surfaces as a write failure.
        struct Full: Error {}
        #expect(throws: PackageError.self) { try PackageWriter().write(PackageFixtures.contents()) { _ in throw Full() } }
    }

    // MARK: Reading

    @Test func readersRefuseWhatTheyCannotOpen() throws {
        let valid = try PackageWriter().data(PackageFixtures.contents()).data
        #expect(try PackageFixtures.reader.open(valid).manifest.featureLevel == 3)
        #expect(throws: PackageError.needsUpdate(featureLevel: 3, supported: 2)) {
            try PackageReader(featureLevel: 2, mergeTableVersion: 7).open(valid)
        }
        #expect(throws: PackageError.unsupportedMergeTable(version: 7, supported: 6)) {
            try PackageReader(featureLevel: 3, mergeTableVersion: 6).open(valid)
        }
        // A corrupt zip is refused before anything is created.
        #expect(throws: PackageError.self) { try PackageFixtures.reader.open(valid.prefix(valid.count / 2)) }
        func package(_ manifest: PackageManifest?, snapshot: Data? = Data([1]), extra: [(String, Data)] = []) throws -> Data {
            var entries: [(String, Data)] = []
            if let manifest { entries.append(("manifest.json", manifest.jsonData())) }
            if let snapshot { entries.append(("snapshot.pb.zst", snapshot)) }
            return try PackageFixtures.zip(entries + extra)
        }
        #expect(throws: PackageError.malformedManifest("the package has no manifest.json")) { try PackageFixtures.reader.open(package(nil)) }
        #expect(throws: PackageError.notAPackage("other")) { try PackageFixtures.reader.open(package(PackageManifest(format: "other"))) }
        #expect(throws: PackageError.unsupportedFormatVersion(2)) { try PackageFixtures.reader.open(package(PackageManifest(formatVersion: 2))) }
        #expect(throws: PackageError.missingSnapshot) { try PackageFixtures.reader.open(package(PackageManifest(), snapshot: nil)) }
        #expect(throws: PackageError.missingSnapshot) { try PackageFixtures.reader.open(package(PackageManifest(), snapshot: Data())) }
        // A blob whose bytes do not hash to its name.
        let bytes = Data("pixels".utf8)
        let listed = PackageBlob(sha256: ImportedBlob.hash(bytes), size: 6, mediaType: "image/png", name: "a.png")
        let swapped = try package(PackageManifest(blobs: [listed]), extra: [("blobs/\(listed.hex)", Data("other!".utf8))])
        #expect(throws: PackageError.corruptBlob("a.png")) { try PackageFixtures.reader.open(swapped) }
        let unnamed = PackageBlob(sha256: listed.sha256, size: 6, mediaType: "image/png")
        #expect(throws: PackageError.corruptBlob(listed.hex)) {
            try PackageFixtures.reader.open(package(PackageManifest(blobs: [unnamed]), extra: [("blobs/\(listed.hex)", Data("other!".utf8))]))
        }
        // A listed blob absent from the zip is simply not restored; no thumbnail, no preview.
        let sparse = try PackageFixtures.reader.open(package(PackageManifest(blobs: [listed])))
        #expect(sparse.blobs.isEmpty)
        #expect(sparse.thumbnail == nil && sparse.preview == nil)
        #expect(throws: PackageError.self) { try PackageReader.thumbnail(of: package(PackageManifest())) }
        #expect(throws: PackageError.self) { try PackageReader.manifest(of: Data("not a zip at all, clearly".utf8)) }
        let errors: [PackageError] = [
            .archive(.tooLarge), .malformedManifest("x"), .notAPackage("x"), .unsupportedFormatVersion(2),
            .needsUpdate(featureLevel: 2, supported: 1), .unsupportedMergeTable(version: 2, supported: 1),
            .missingSnapshot, .corruptBlob("x"), .nothingToExport, .writeFailed("x"),
        ]
        for error in errors {
            #expect(!error.description.isEmpty)
        }
    }
}
