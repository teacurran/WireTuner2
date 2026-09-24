import Foundation
import Testing
import WTCRDT
import WTModel
import WTProto
import WTRender
@testable import WTSync

/// CMS-009: the always-listed colour settings row.
@Suite(.timeLimit(.minutes(2))) struct ColorSettingsReviewTests {
    static let pressA = WTColor.ProfileRef(name: "Coated Press", sha256: Data(repeating: 1, count: 32), space: .cmyk)
    static let pressB = WTColor.ProfileRef(name: "Coated Press", sha256: Data(repeating: 2, count: 32), space: .cmyk)

    static func open(_ scratch: Scratch, _ name: String, replica: UInt64) async throws -> LocalStore {
        try await LocalStore.open(documentID: "D", at: scratch.url(name), options: options(replicas: Replicas(from: replica)))
    }

    @Test func aProfileChangedOfflineIsListedForTheOtherSideOnly() async throws {
        let scratch = Scratch()
        let a = try await Self.open(scratch, "a", replica: 0xA)
        let b = try await Self.open(scratch, "b", replica: 0xB)
        // A changes the CMYK profile offline; B changes nothing.
        _ = try await a.perform(ChangeColorSettings(TestProfiles.draft(cmyk: Self.pressA)), recording: Fixture.recording())
        let sent = try await a.outbox()
        #expect(sent.count == 1)
        // Reconnect: B receives A's change; A's own change is its outbox.
        _ = try await b.receive(sent[0], serverSeq: 1)
        let onB = try await b.divergence(since: 0, gap: .seconds(3600 * 24))
        let entry = try #require(onB.entries.first { $0.setting == .colorSettings })
        #expect(onB.overlapCount == 0 && entry.actions == [.useTheirs])
        #expect(onB.decision(.standard).holdsOutbox)
        let onA = try await a.divergence(since: 0, gap: .seconds(3600 * 24))
        #expect(onA.entries.isEmpty)
        // B's row names the change; its choice is an ordinary change (none needed: B has theirs).
        let review = try #require(ColorSettingsReview(base: EngineState(), local: try await b.outbox(), remote: try await b.remoteChanges(after: 0),
                                                      authors: ["Priya"]))
        #expect(review.title == "Color settings changed by Priya")
        #expect(review.changes == [ColorSettingsReview.FieldChange(field: "Working CMYK", old: "Generic CMYK Profile", new: "Coated Press")])
        #expect(review.changes[0].line == "Working CMYK: Generic CMYK Profile → Coated Press")
        #expect(review.mine == nil && review.useMine == nil && review.actions == [.useTheirs])
        #expect(review.useTheirs.label == "Use Their Color Settings")
        #expect(try await b.perform(review.useTheirs, recording: Fixture.recording()).change == nil)
        // A sees nothing to review: no remote colour change.
        #expect(ColorSettingsReview(base: EngineState(), local: try await a.outbox(), remote: [], authors: []) == nil)
        try await a.close()
        try await b.close()
    }

    @Test func sameNameDifferentDataAndUseMine() async throws {
        let scratch = Scratch()
        let a = try await Self.open(scratch, "a", replica: 0xA)
        let b = try await Self.open(scratch, "b", replica: 0xB)
        // Both start from press A (sequenced 1).
        _ = try await a.perform(ChangeColorSettings(TestProfiles.draft(cmyk: Self.pressA)), recording: Fixture.recording())
        let base = try await a.outbox()[0]
        try await a.acknowledge(seq: base.seq, serverSeq: 1)
        _ = try await b.receive(base, serverSeq: 1)
        // B installs a new press profile of the same name; A, offline, changes the intent.
        _ = try await b.perform(ChangeColorSettings(TestProfiles.draft(cmyk: Self.pressB, in: await b.read { $0 })), recording: Fixture.recording())
        var intent = ColorSettings.draft(await a.read { $0 })
        intent.intent = .perceptual
        _ = try await a.perform(ChangeColorSettings(intent), recording: Fixture.recording())
        _ = try await a.receive(try await b.outbox()[0], serverSeq: 2)
        let head = try #require(try await a.state(atServerSeq: 1))
        let review = try #require(ColorSettingsReview(base: head, local: try await a.outbox(), remote: try await a.remoteChanges(after: 1),
                                                      authors: ["Tom"]))
        #expect(review.changes.count == 1 && review.changes[0].sameNameDifferentData)
        #expect(review.changes[0].line == "Working CMYK: Coated Press → Coated Press (same name, different data)")
        #expect(review.actions == [.useMine, .useTheirs] && review.mine?.intent == .perceptual)
        #expect(ColorSettings(await a.read { $0 }).cmykProfile == Self.pressB)
        // Use mine writes my settings back as one undoable change.
        let choice = try #require(review.useMine)
        #expect(choice.label == "Use My Color Settings")
        #expect(try await a.perform(choice, recording: Fixture.recording()).change != nil)
        #expect(ColorSettings(await a.read { $0 }).cmykProfile == Self.pressA)
        _ = try await a.undo(recording: Fixture.recording())
        #expect(ColorSettings(await a.read { $0 }).cmykProfile == Self.pressB)
        try await a.close()
        try await b.close()
    }

    @Test func everySettingIsNamed() {
        var old = Wiretuner_Doc_V1_ColorSettings()
        old.cmykProfile = ColorSettings.stored(Self.pressA)
        var new = Wiretuner_Doc_V1_ColorSettings()
        let registry = WTColor.ProfileRegistry.shared
        new.rgbProfile = ColorSettings.stored(registry.displayP3)
        new.cmykProfile = ColorSettings.stored(Self.pressB)
        new.defaultImageRgbProfile = ColorSettings.stored(registry.displayP3)
        new.intent = .saturation
        new.noBlackPointCompensation = true
        new.noSpotColorManagement = true
        new.proof.target = .composite
        new.proof.compositeProfile = ColorSettings.stored(registry.defaultCMYK)
        new.proof.compositeSimulatesSeparations = true
        new.proof.simulatePaperWhite = true
        new.proof.simulateBlackInk = true
        let changes = ColorSettingsReview.changes(from: old, to: new)
        #expect(changes.map(\.field) == ["Working RGB", "Working CMYK", "Default image RGB", "Intent", "Black point compensation",
                                         "Color manage spot colors", "Proof", "Composite proof profile", "Composite simulates separations",
                                         "Simulate paper white", "Simulate black ink"])
        #expect(changes[3].old == "Relative Colorimetric" && changes[3].new == "Saturation")
        #expect(changes[4].line == "Black point compensation: On → Off")
        #expect(changes[6].old == "None" && changes[6].new == "Composite")
        #expect([WTColor.RenderingIntent.perceptual, .absoluteColorimetric].map(ColorSettingsReview.name) == ["Perceptual", "Absolute Colorimetric"])
        #expect(ColorSettingsReview.name(ColorSettings.ProofTarget.separations) == "Separations")
    }

    @Test func titlesNameEveryAuthorOnce() throws {
        var theirs = Wiretuner_Doc_V1_NodeProps()
        theirs.settings.color.intent = .perceptual
        let change = Fixture.change(7, seq: 1, start: 1, [Ops.set(WellKnown.settings, ChangeColorSettings.registers, values: theirs)])
        func title(_ authors: [String]) throws -> String {
            try #require(ColorSettingsReview(base: EngineState(), local: [], remote: [change], authors: authors)).title
        }
        #expect(try title([]) == "Color settings changed by someone")
        #expect(try title(["Priya", "", "Tom", "Priya"]) == "Color settings changed by Priya, someone and Tom")
        #expect(try title(["Priya", "Tom"]) == "Color settings changed by Priya and Tom")
    }
}
