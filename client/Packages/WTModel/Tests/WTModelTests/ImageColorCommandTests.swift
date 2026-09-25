import Foundation
import Testing
import WTCRDT
import WTGeometry
@testable import WTModel
import WTProto
import WTRender

/// CMS-013: assigning an image's source profile and intent, and the merge cases of *Done when*.
@Suite struct ImageColorCommandTests {
    static let registry = WTColor.ProfileRegistry.shared

    /// Writes an embedded profile on `node`, as the importer does.
    static func embed(_ profile: WTColor.ProfileRef, on node: OpID, _ replica: inout Replica) throws {
        let values = ImageColorFields.values { $0.embeddedProfile = ColorSettings.stored(profile) }
        try replica.perform(OpsCommand("Embed", ops: [Ops.set(node, [RegisterPath([ImageFields.kind, 11, 4])], values: values)]))
    }

    @Test func choicesAndIntentsReadBackAsOneChangeEach() throws {
        var a = Replica(0xA)
        let images = [try ImageCommandsTests.place(&a), try ImageCommandsTests.place(&a)]
        var info = try #require(ImageColorInfo(images[0], in: a.state))
        #expect(info.source == .documentDefault && info.embedded == nil && info.intent == nil && info.mode == .rgb && info.space == .rgb)
        let p3 = Self.registry.displayP3
        let assign = try #require(try a.perform(SetImageSourceProfile(images, .profile(p3))))
        #expect(assign.label == "Assign Image Profile (2 images)" && SetImageSourceProfile([images[0]], .embedded).label == "Assign Image Profile")
        info = try #require(ImageColorInfo(images[1], in: a.state))
        #expect(info.source == .profile(p3))
        // Embedded without an embedded profile reads as the assignment still.
        try a.perform(SetImageSourceProfile([images[0]], .embedded))
        #expect(ImageColorInfo(images[0], in: a.state)?.source == .profile(p3))
        try Self.embed(Self.registry.sRGB, on: images[0], &a)
        #expect(ImageColorInfo(images[0], in: a.state)?.source == .embedded && ImageColorInfo(images[0], in: a.state)?.embedded == Self.registry.sRGB)
        try a.perform(SetImageSourceProfile([images[0]], .documentDefault))
        #expect(ImageColorInfo(images[0], in: a.state)?.source == .documentDefault)
        // Intent, and back to the document's.
        let intent = try #require(try a.perform(SetImageIntent(images, intent: .perceptual)))
        #expect(intent.label == "Change Image Intent (2 images)" && ImageColorInfo(images[1], in: a.state)?.intent == .perceptual)
        try a.perform(SetImageIntent([images[1]], intent: nil))
        #expect(ImageColorInfo(images[1], in: a.state)?.intent == nil)
        // The scene reads the assignment.
        #expect(ImageNodes.item(a.state.props(images[1]).image, transform: .identity).sourceProfile == p3)
        // Not an image.
        let rect = try LayerFixture.object(LayerFixture.rect(on: nil), on: &a)
        #expect(ImageColorInfo(rect, in: a.state) == nil)
        #expect(throws: ImageEditError.notAnImage(rect)) { try a.perform(SetImageIntent([rect], intent: .saturation)) }
        // The models' spaces.
        let gray = try ImageCommandsTests.place(&a, ImageCommandsTests.pixels(mode: .grayscale))
        let cmyk = try ImageCommandsTests.place(&a, ImageCommandsTests.pixels(mode: .cmyk))
        #expect(ImageColorInfo(gray, in: a.state)?.space == .gray && ImageColorInfo(cmyk, in: a.state)?.space == .cmyk)
    }

    @Test func concurrentAssignmentsAndIntentsMerge() throws {
        var pair = Pair()
        let image = try ImageCommandsTests.place(&pair.a)
        try Self.embed(Self.registry.sRGB, on: image, &pair.a)
        pair.sync()
        let x = Self.registry.displayP3
        // A assigns X while B sets Perceptual: both kept.
        try pair.a.perform(SetImageSourceProfile([image], .profile(x)))
        try pair.b.perform(SetImageIntent([image], intent: .perceptual))
        pair.sync()
        for replica in [pair.a, pair.b] {
            let info = try #require(ImageColorInfo(image, in: replica.state))
            #expect(info.source == .profile(x) && info.intent == .perceptual)
        }
        // A switches to the embedded profile while B assigns Y: embedded wins, Y is retained.
        let y = Self.registry.genericGray
        try pair.a.perform(SetImageSourceProfile([image], .embedded))
        try pair.b.perform(SetImageSourceProfile([image], .profile(y)))
        pair.sync()
        #expect(pair.a.state.stateHash == pair.b.state.stateHash)
        #expect(ImageColorInfo(image, in: pair.b.state)?.source == .embedded)
        #expect(ColorSettings.profile(pair.b.state.props(image).image.color.sourceProfile, registry: Self.registry) == y, "Y is retained")
        // Turning the embedded profile off again brings Y back... by choosing it.
        try pair.b.perform(SetImageSourceProfile([image], .documentDefault))
        #expect(ImageColorInfo(image, in: pair.b.state)?.source == .documentDefault)
    }
}
