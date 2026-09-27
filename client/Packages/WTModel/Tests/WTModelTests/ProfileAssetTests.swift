import CryptoKit
import Foundation
import Testing
import WTCRDT
@testable import WTModel
import WTProto

/// CMS-010: profile asset nodes, the Profiles… list, the reference scan and export
/// (color-profiles.adoc).
@Suite struct ProfileAssetTests {
    static let bytes = Data("fake ICC profile bytes".utf8)
    static let custom: Wiretuner_Doc_V1_ProfileRef = .with {
        $0.name = "Press Proof"
        $0.sha256 = Data(SHA256.hash(data: bytes))
        $0.space = .cmyk
    }
    static let bundled: Wiretuner_Doc_V1_ProfileRef = .with {
        $0.name = "Generic CMYK"
        $0.sha256 = Data(repeating: 9, count: 32)
        $0.bundledID = "default-cmyk"
        $0.space = .cmyk
    }

    @discardableResult
    static func choose(_ profile: Wiretuner_Doc_V1_ProfileRef, on replica: inout Replica) throws -> Wiretuner_Doc_V1_Change? {
        var draft = replica.state.props(WellKnown.settings).settings.color
        draft.cmykProfile = profile
        return try replica.perform(ChangeColorSettings(draft, profileSizes: [custom.sha256: UInt64(bytes.count)]))
    }

    @Test func choosingACustomProfileCreatesItsAssetOnceInTheSameChange() throws {
        var a = Replica(0xA)
        let change = try #require(try Self.choose(Self.custom, on: &a))
        #expect(change.label == "Change Color Settings" && change.createdNodes.count == 1)
        let entry = try #require(ProfileAssets.list(a.state).first)
        #expect(entry.name == "Press Proof" && entry.size == UInt64(Self.bytes.count) && entry.isReferenced && entry.space == .cmyk)
        #expect(ProfileAssets.asset(for: Self.custom.sha256, in: a.state) == change.createdNodes[0])
        // Choosing it again elsewhere reuses the node; a bundled profile needs none.
        var draft = a.state.props(WellKnown.settings).settings.color
        draft.defaultImageRgbProfile = Self.custom
        let again = try #require(try a.perform(ChangeColorSettings(draft)))
        #expect(again.createdNodes.isEmpty)
        #expect(try Self.choose(Self.bundled, on: &a)?.createdNodes.isEmpty == true)
        #expect(!ProfileAssets.isCustom(Self.bundled) && ProfileAssets.isCustom(Self.custom))
        #expect(ProfileAssets.isCustom(.with { $0.sha256 = Data([1]) }) == false)
    }

    @Test func addProfileAssetsForImagesAndLists() throws {
        var a = Replica(0xA)
        let other: Wiretuner_Doc_V1_ProfileRef = .with { $0.name = "Adobe RGB"; $0.sha256 = Data(repeating: 4, count: 32); $0.space = .rgb }
        let command = AddProfileAssets([(Self.custom, 10), (other, 20), (Self.custom, 10), (Self.bundled, 5)])
        #expect(command.label == "Add 4 profiles" && AddProfileAssets([(Self.custom, 1)]).label == "Add profile")
        let change = try #require(try a.perform(command))
        #expect(change.createdNodes.count == 2)
        #expect(ProfileAssets.list(a.state).map(\.name) == ["Adobe RGB", "Press Proof"])
        #expect(ProfileAssets.list(a.state).allSatisfy { !$0.isReferenced })
        #expect(try a.perform(AddProfileAssets([(other, 20)])) == nil)
        // A malformed asset (no hash) is left out of the list.
        _ = try a.perform(OpsCommand("Bad", ops: [Ops.create(parent: ProfileAssets.assets, position: [0xF0], props: .with { $0.profileAsset.size = 1 })]))
        #expect(ProfileAssets.list(a.state).count == 2)
        // The profile menus' *In this document* group (CMS-010's rest): WTColor's references, by space.
        #expect(ColorSettings.documentProfiles(a.state).map(\.name) == ["Adobe RGB", "Press Proof"])
        #expect(ColorSettings.documentProfiles(a.state, space: .rgb).map(\.name) == ["Adobe RGB"])
        #expect(ColorSettings.documentProfiles(a.state, space: .cmyk).map(\.name) == ["Press Proof"])
    }

    @Test func choosingTheSameProfileOnTwoMacsMakesTwoNodesListedAsOne() throws {
        var pair = Pair()
        try Self.choose(Self.custom, on: &pair.a)
        try Self.choose(Self.custom, on: &pair.b)
        pair.sync()
        #expect(StateHash.of(pair.a.state.store) == StateHash.of(pair.b.state.store))
        let nodes = pair.a.state.liveChildren(ProfileAssets.assets).filter { pair.a.state.store.kind($0) == ProfileAssets.kind }
        #expect(nodes.count == 2)
        let list = ProfileAssets.list(pair.a.state)
        #expect(list.count == 1 && list[0].nodes == nodes.sorted())
    }

    @Test func removingTheLastReferenceWhileAnotherIsAddedKeepsTheProfile() throws {
        var pair = Pair()
        try Self.choose(Self.custom, on: &pair.a)
        pair.sync()
        // A goes back to the bundled profile; B gives an image the custom one as its source.
        try Self.choose(Self.bundled, on: &pair.a)
        var image = Wiretuner_Doc_V1_NodeProps()
        image.image.dpiX = 72
        image.image.dpiY = 72
        image.image.color.sourceProfile = Self.custom
        let layer = try LayerFixture.layers(["Art"], on: &pair.b)[0]
        try pair.b.perform(OpsCommand("Image", ops: [Ops.create(parent: layer, position: [0x80], props: image)]))
        pair.sync()
        #expect(StateHash.of(pair.a.state.store) == StateHash.of(pair.b.state.store))
        #expect(ProfileAssets.referencedHashes(in: pair.a.state) == [Self.custom.sha256])
        #expect(ProfileAssets.unreferenced(in: pair.a.state).isEmpty, "the profile remains available")
        var scan = ProfileReferenceScan(window: 10)
        #expect(scan.observe(pair.a.state, now: 0).isEmpty && scan.observe(pair.a.state, now: 100).isEmpty)
    }

    @Test func theScanMarksAnAssetDeletedAfterTheWindowAndResetsOnAReference() throws {
        var a = Replica(0xA)
        try a.perform(AddProfileAssets([(Self.custom, 10)]))
        let asset = try #require(ProfileAssets.asset(for: Self.custom.sha256, in: a.state))
        var scan = ProfileReferenceScan(window: 1_000)
        #expect(ProfileReferenceScan().window == EngineState.deletedNodeRetentionMs)
        #expect(scan.observe(a.state, now: 5_000).isEmpty)
        #expect(scan.unreferencedSince[asset] == 5_000)
        // Referenced again: the clock starts over.
        try Self.choose(Self.custom, on: &a)
        #expect(scan.observe(a.state, now: 5_500).isEmpty && scan.unreferencedSince.isEmpty)
        try Self.choose(Self.bundled, on: &a)
        #expect(scan.observe(a.state, now: 6_000).isEmpty)
        let due = scan.observe(a.state, now: 7_000)
        #expect(due == [asset])
        let removal = RemoveUnreferencedProfiles(due)
        #expect(removal.label == "Remove unused profiles" && !removal.recordsUndo)
        #expect(try a.perform(removal) != nil && !a.state.isLive(asset))
        // An asset referenced again before the removal runs is kept.
        try a.perform(AddProfileAssets([(Self.custom, 10)]))
        let second = try #require(ProfileAssets.asset(for: Self.custom.sha256, in: a.state))
        try Self.choose(Self.custom, on: &a)
        #expect(try a.perform(RemoveUnreferencedProfiles([second])) == nil)
    }

    @Test func exportedBytesHashToTheAssetsSHA256() throws {
        var a = Replica(0xA)
        try a.perform(AddProfileAssets([(Self.custom, 10)]))
        let asset = try #require(ProfileAssets.asset(for: Self.custom.sha256, in: a.state))
        let exported = try #require(ProfileAssets.exportData(asset, blob: Self.bytes, in: a.state))
        #expect(Data(SHA256.hash(data: exported)) == Self.custom.sha256)
        #expect(ProfileAssets.exportData(asset, blob: Data("tampered".utf8), in: a.state) == nil)
        #expect(ProfileAssets.exportData(WellKnown.layers, blob: Self.bytes, in: a.state) == nil)
    }

    @Test func profilesAreFoundAtAnyDepth() {
        var props = Wiretuner_Doc_V1_NodeProps()
        props.image.color.sourceProfile = Self.custom
        props.image.color.embeddedProfile = Self.bundled
        let found = ProfileAssets.profiles(in: props, schema: EngineState().schema)
        #expect(found == [Self.custom, Self.bundled])
    }
}
