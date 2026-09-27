// CMS-012: embedded profiles at image import.  Each format's profile is read from the file's own
// structure (JPEG APP2 segments in order, PNG iCCP and sRGB, TIFF tag 34675, PSD resource 0x040F), a
// bundled profile is recognized by hash and adds no blob, and the image importer records what it
// found on the imported image.

import CoreGraphics
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers
@testable import WTInterchange
import WTRender

@Suite struct EmbeddedProfileTests {
    static let adobe = CGColorSpace(name: CGColorSpace.adobeRGB1998)!
    static let sRGB = CGColorSpace(name: CGColorSpace.sRGB)!

    /// A 4 × 4 image in `space` written as `type`.
    static func file(_ type: UTType, space: CGColorSpace) -> Data {
        let context = CGContext(data: nil, width: 4, height: 4, bitsPerComponent: 8, bytesPerRow: 0, space: space, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
        context.setFillColor(CGColor(colorSpace: space, components: [0.8, 0.2, 0.1, 1])!)
        context.fill(CGRect(x: 0, y: 0, width: 4, height: 4))
        return ImageEncoding.encode(context.makeImage()!, type: type)!
    }

    /// A minimal PSD whose image resources hold `icc` as resource 0x040F after another resource.
    static func psd(icc: Data?) -> Data {
        var data = Data("8BPS".utf8) + Data([0, 1]) + Data(count: 6) + Data([0, 3]) + Data([0, 0, 0, 4, 0, 0, 0, 4]) + Data([0, 8, 0, 3])
        data += Data([0, 0, 0, 0])  // colour mode data
        func resource(_ id: UInt16, _ body: Data) -> Data {
            var r = Data("8BIM".utf8) + Data([UInt8(id >> 8), UInt8(id & 0xFF)]) + Data([1, 0x41])  // name "A", padded to even
            let size = UInt32(body.count)
            r += Data([UInt8(size >> 24), UInt8(size >> 16 & 0xFF), UInt8(size >> 8 & 0xFF), UInt8(size & 0xFF)]) + body
            if body.count % 2 == 1 { r.append(0) }
            return r
        }
        var resources = resource(0x03ED, Data([1, 2, 3]))
        if let icc { resources += resource(0x040F, icc) }
        let length = UInt32(resources.count)
        data += Data([UInt8(length >> 24), UInt8(length >> 16 & 0xFF), UInt8(length >> 8 & 0xFF), UInt8(length & 0xFF)]) + resources
        return data
    }

    @Test(arguments: [UTType.jpeg, .png, .tiff])
    func adobeRGBIsFoundInEachFormat(_ type: UTType) throws {
        let data = Self.file(type, space: Self.adobe)
        let found = try #require(EmbeddedProfiles.extract(data))
        #expect(found.profile.name.contains("Adobe RGB"))
        #expect(!found.profile.isBundled && found.profile.space == .rgb)
        let blob = try #require(found.blob)
        #expect(blob.sha256 == found.profile.sha256 && blob.uti == "com.apple.colorsync-profile")
    }

    @Test func psdResourceAndBundledRecognition() throws {
        let icc = Self.adobe.copyICCData()! as Data
        let found = try #require(EmbeddedProfiles.extract(Self.psd(icc: icc)))
        #expect(found.profile.name.contains("Adobe RGB") && found.blob?.data == icc)
        #expect(EmbeddedProfiles.extract(Self.psd(icc: nil)) == nil)
        // sRGB is bundled: recognized by hash, no blob to store (ImageIO writes no profile at all
        // into an sRGB JPEG).
        for type in [UTType.jpeg, .png, .tiff] {
            let srgb = EmbeddedProfiles.extract(Self.file(type, space: Self.sRGB))
            #expect(srgb == nil || (srgb?.profile.bundledID == "srgb" && srgb?.blob == nil), "\(type)")
        }
        let registry = WTColor.ProfileRegistry.shared
        let embedded = try #require(EmbeddedProfiles.extract(Self.psd(icc: registry.iccData(for: registry.sRGB)!)))
        #expect(embedded.profile.bundledID == "srgb" && embedded.blob == nil)
        #expect(EmbeddedProfiles.extract(Self.psd(icc: Self.sRGB.copyICCData()! as Data))?.blob == nil)
    }

    @Test func filesWithoutAProfile() throws {
        let tiff = Self.file(.tiff, space: CGColorSpaceCreateDeviceRGB())
        #expect(EmbeddedProfiles.iccData(in: tiff) == nil)
        #expect(EmbeddedProfiles.iccData(in: Self.file(.gif, space: Self.sRGB)) == nil)
        #expect(EmbeddedProfiles.iccData(in: Data([0xFF, 0xD8, 0xFF, 0xDA, 0, 2])) == nil)
        #expect(EmbeddedProfiles.iccData(in: Data([0xFF, 0xD8, 0xFF, 0xD0, 0xFF, 0xE0, 0, 4, 0, 0, 0xFF, 0xD9])) == nil)
        // Damaged structures read as no profile rather than trapping.
        #expect(EmbeddedProfiles.iccData(in: Data([0x49, 0x49, 0x2A, 0x00, 0xFF, 0xFF, 0, 0])) == nil)
        #expect(EmbeddedProfiles.iccData(in: Data("8BPS".utf8) + Data(count: 30)) == nil)
        #expect(EmbeddedProfiles.extract(Self.psd(icc: Data("not a profile".utf8))) == nil)
        var png = Self.file(.png, space: Self.adobe)
        if let range = png.range(of: Data("iCCP".utf8)) { png.replaceSubrange(range, with: Data("iCCX".utf8)) }
        #expect(EmbeddedProfiles.iccData(in: png) == nil)
    }

    @Test func handMadeStructures() throws {
        let icc = Self.adobe.copyICCData()! as Data
        // A little-endian TIFF with the profile at an offset, and one whose short value is inline.
        func tiff(count: Int, offset: Int, payload: Data) -> Data {
            var d = Data([0x49, 0x49, 0x2A, 0x00, 8, 0, 0, 0, 1, 0])
            d += Data([0x73, 0x87, 7, 0]) + Data([UInt8(count & 0xFF), UInt8(count >> 8 & 0xFF), UInt8(count >> 16 & 0xFF), UInt8(count >> 24)])
            d += Data([UInt8(offset & 0xFF), UInt8(offset >> 8 & 0xFF), UInt8(offset >> 16 & 0xFF), UInt8(offset >> 24)]) + Data([0, 0, 0, 0])
            return d + payload
        }
        #expect(EmbeddedProfiles.iccData(in: tiff(count: icc.count, offset: 26, payload: icc)) == icc)
        #expect(EmbeddedProfiles.iccData(in: tiff(count: 3, offset: 0x00414243, payload: Data())) == Data([0x43, 0x42, 0x41]))
        #expect(EmbeddedProfiles.iccData(in: tiff(count: icc.count, offset: 4000, payload: Data())) == nil)
        // JPEG fill bytes and restart markers are skipped; a segment running past the end stops the scan.
        let segment = Data("ICC_PROFILE".utf8) + Data([0, 1, 1]) + icc.prefix(10)
        let jpeg = Data([0xFF, 0xD8, 0xFF, 0xFF, 0xD0, 0xFF, 0xE2, 0, UInt8(segment.count + 2)]) + segment
        #expect(EmbeddedProfiles.iccData(in: jpeg) == icc.prefix(10))
        #expect(EmbeddedProfiles.iccData(in: Data([0xFF, 0xD8, 0xFF, 0xE2, 0xFF, 0xFF, 0])) == nil)
        // PNG: an iCCP with another compression method, or a damaged stream, is no profile.
        func png(_ chunk: String, _ body: Data) -> Data {
            let length = UInt32(body.count)
            return Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]) + Data([UInt8(length >> 24), UInt8(length >> 16 & 0xFF), UInt8(length >> 8 & 0xFF), UInt8(length & 0xFF)])
                + Data(chunk.utf8) + body + Data(count: 4)
        }
        #expect(EmbeddedProfiles.iccData(in: png("iCCP", Data("P".utf8) + Data([0, 1]) + Data(count: 8))) == nil)
        #expect(EmbeddedProfiles.iccData(in: png("iCCP", Data("P".utf8) + Data([0, 0, 0x78, 0x9C, 0xFF, 0xFF, 0xFF]))) == nil)
        #expect(EmbeddedProfiles.iccData(in: png("tEXt", Data("a".utf8))) == nil)
        #expect(EmbeddedProfiles.iccData(in: png("sRGB", Data([0]))) != nil)
        // PSD: a resource running past the section is no profile.
        var psd = Self.psd(icc: icc)
        psd.removeLast(10)
        #expect(EmbeddedProfiles.iccData(in: psd) == nil)
    }

    @Test func jpegSegmentsJoinInSequenceOrder() throws {
        let icc = Self.adobe.copyICCData()! as Data
        let half = icc.count / 2
        func segment(_ number: UInt8, _ body: Data) -> Data {
            let payload = Data("ICC_PROFILE".utf8) + Data([0, number, 2]) + body
            let length = payload.count + 2
            return Data([0xFF, 0xE2, UInt8(length >> 8), UInt8(length & 0xFF)]) + payload
        }
        // Second part first: the sequence numbers decide.
        let jpeg = Data([0xFF, 0xD8]) + segment(2, icc.suffix(from: half)) + segment(1, icc.prefix(half)) + Data([0xFF, 0xDA, 0, 2])
        #expect(EmbeddedProfiles.iccData(in: jpeg) == icc)
    }

    @Test func theImporterRecordsTheProfileAndItsBlob() throws {
        let data = Self.file(.jpeg, space: Self.adobe)
        let scene = try ImageImporter().convert(data, name: "adobe.jpg", format: .jpeg, options: ImportOptionValues(), context: ImportContext())
        guard case .image(let image)? = scene.nodes.first else { Issue.record("no image"); return }
        let profile = try #require(image.embeddedProfile)
        #expect(scene.blobs.count == 2 && scene.blobs.contains(profile.blob!))
        let srgb = try ImageImporter().convert(Self.file(.jpeg, space: Self.sRGB), name: "s.jpg", format: .jpeg, options: ImportOptionValues(), context: ImportContext())
        #expect(srgb.blobs.count == 1, "a bundled profile adds no blob")
    }
}
