// CMS-012's model half -- an imported image records its embedded profile, creates the profile's asset
// unless it is bundled, and reads through it as the preference says -- and IO-032's: the export
// snapshot carries each page's reading order for tagged PDF.

import CoreGraphics
import Foundation
import Testing
import WTCRDT
import WTGeometry
import WTInterchange
@testable import WTModel
import WTProto
import WTRender

@Suite struct ImportProfileAndReadingOrderTests {
    static let registry = WTColor.ProfileRegistry.shared
    static let adobeICC = CGColorSpace(name: CGColorSpace.adobeRGB1998)!.copyICCData()! as Data

    static func adobe() throws -> ImportedProfile {
        let ref = try #require(registry.register(iccData: adobeICC))
        return ImportedProfile(profile: ref, blob: ImportedBlob(data: adobeICC, uti: "com.apple.colorsync-profile"))
    }

    /// Performs `command` on `replica` and returns the object it placed.
    static func place(_ command: PlaceImportedScene, on replica: inout Replica) throws -> OpID {
        let change = try #require(try replica.perform(command))
        return try #require(PlaceImportedScene.placedRoot(of: change, in: replica.state))
    }

    static func scene(_ profile: ImportedProfile?, pixels: ImportedBlob = ImportFixture.png) -> ImportedScene {
        ImportedScene(kind: .bitmap, name: "photo.jpg", bounds: Rect(x: 0, y: 0, width: 300, height: 150),
                      nodes: [.image(ImportedImage(pixels: ImportFixture.pixels(pixels), name: "photo.jpg", embeddedProfile: profile))])
    }

    @Test func eachPreferenceWritesTheDocumentedFields() throws {
        let profile = try Self.adobe()
        for (policy, used) in [(EmbeddedProfilePolicy.useEmbedded, true), (.ignore, false)] {
            var a = Replica(0xA)
            _ = try LayerFixture.layers(["Art"], on: &a)
            let node = try Self.place(PlaceImportedScene(Self.scene(profile), placement: .at(Point(x: 0, y: 0)), embeddedProfiles: policy), on: &a)
            let color = a.state.props(node).image.color
            #expect(color.embeddedProfile.sha256 == profile.profile.sha256 && color.embeddedProfile.name.contains("Adobe RGB"))
            #expect(color.useEmbedded == used)
            #expect(ProfileAssets.list(a.state).map(\.sha256) == [profile.profile.sha256], "the profile is stored either way")
        }
        // The default is Use embedded; an image without a profile writes nothing.
        var b = Replica(0xB)
        _ = try LayerFixture.layers(["Art"], on: &b)
        let plain = try Self.place(PlaceImportedScene(Self.scene(nil), placement: .at(Point(x: 0, y: 0))), on: &b)
        #expect(!b.state.props(plain).image.hasColor)
        #expect(ProfileAssets.list(b.state).isEmpty)
    }

    @Test func bundledProfilesAddNoAsset() throws {
        var a = Replica(0xA)
        _ = try LayerFixture.layers(["Art"], on: &a)
        let srgb = ImportedProfile(profile: Self.registry.sRGB, blob: nil)
        for index in 0..<100 {
            let pixels = ImportedBlob(data: Data([0x89, 0x50, 0x4E, 0x47, UInt8(index)]), uti: "public.png")
            try a.perform(PlaceImportedScene(Self.scene(srgb, pixels: pixels), placement: .at(Point(x: Double(index), y: 0)), link: ImportFixture.link))
        }
        #expect(ProfileAssets.list(a.state).isEmpty)
        // An image asset and a profile asset made in one change get distinct keys above the others.
        let change = try #require(try a.perform(PlaceImportedScene(Self.scene(try Self.adobe()), placement: .at(Point(x: 0, y: 0)), link: ImportFixture.link)))
        let assets = a.state.liveChildren(WellKnown.assets)
        let positions = assets.compactMap { a.state.store.placement($0)?.position }
        #expect(Set(positions).count == positions.count && change.ops.count >= 3)
    }

    @Test func concurrentImportsKeepBothNodesAndBothAssets() throws {
        var pair = Pair()
        _ = try LayerFixture.layers(["Art"], on: &pair.a)
        pair.sync()
        let other = CGColorSpace(name: CGColorSpace.rommrgb)!.copyICCData()! as Data
        let romm = ImportedProfile(profile: try #require(Self.registry.register(iccData: other)), blob: ImportedBlob(data: other, uti: "com.apple.colorsync-profile"))
        let first = try Self.place(PlaceImportedScene(Self.scene(try Self.adobe()), placement: .at(Point(x: 0, y: 0))), on: &pair.a)
        let secondPixels = ImportedBlob(data: Data([0x89, 0x50, 0x4E, 0x47, 0xEE]), uti: "public.png")
        let second = try Self.place(PlaceImportedScene(Self.scene(romm, pixels: secondPixels), placement: .at(Point(x: 50, y: 0))), on: &pair.b)
        pair.sync()
        for replica in [pair.a, pair.b] {
            #expect(replica.state.isLive(first) && replica.state.isLive(second))
            #expect(Set(ProfileAssets.list(replica.state).map(\.sha256)) == [romm.profile.sha256, try Self.adobe().profile.sha256])
        }
    }

    @Test func theSnapshotCarriesEachPagesReadingOrder() throws {
        var a = Replica(0xA)
        let page = try PageFixture.onePage(&a)
        _ = try LayerFixture.layers(["Art"], on: &a)
        var objects: [OpID] = []
        for index in 0..<3 { objects.append(try PageFixture.rect(&a, at: Point(x: 20 + Double(index) * 30, y: 20))) }
        try a.perform(ArrangeReadingOrder(page: page, order: [objects[2], objects[0]]))
        let pages = PageList(a.state).exportPages
        let snapshot = ExportSnapshot.capture(a.state, request: ExportSnapshot.Request(name: "R", pages: pages, scope: .pages([0])),
                                              builder: DocumentDisplayListBuilder(canvas: "export"), blob: { _ in nil })
        #expect(snapshot.scene.pages[0].readingOrder == [objects[2], objects[0], objects[1]].map(NodeID.init))
        // Pages the document does not have by rectangle go by index; past its pages, nothing.
        let odd = [ExportSnapshot.Page(bounds: Rect(x: 0, y: 0, width: 11, height: 11)), ExportSnapshot.Page(bounds: Rect(x: 0, y: 0, width: 12, height: 12))]
        let loose = ExportSnapshot.capture(a.state, request: ExportSnapshot.Request(name: "L", pages: odd, scope: .pages([0, 1])),
                                           builder: DocumentDisplayListBuilder(canvas: "export"), blob: { _ in nil })
        #expect(loose.scene.pages.map(\.readingOrder) == [[objects[2], objects[0], objects[1]].map(NodeID.init), []])
    }
}
