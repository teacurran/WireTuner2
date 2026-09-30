import Foundation
import Testing
import WTCRDT
import WTGeometry
@testable import WTModel
import WTProto
import WTRender

/// OBJ-023's *Resample at* (find-replace.adoc; D-090): steps from the printer resolution, the
/// screen and the largest ink change.
@Suite struct BlendResamplingTests {
    /// A blend of a red-to-blue pair of squares (`red` of the second).
    static func blend(_ a: inout Replica, red: Double = 0) throws -> OpID {
        let start = try BlendCommandTests.square(&a, x: 0)
        let end = try BlendCommandTests.square(&a, x: 100, red: red)
        try a.perform(Blend([start, end]))
        return try #require(BlendCommandTests.blend(of: start, a.state))
    }

    @Test func levelsFollowTheResolutionAndTheScreen() {
        #expect(BlendResampling.levels(resolution: 300, frequency: 60) == 25)
        #expect(BlendResampling.levels(resolution: 1200, frequency: 150) == 64)
        #expect(BlendResampling.levels(resolution: 2540, frequency: 150) == 256, "PostScript's 256 grey levels")
        #expect(BlendResampling.levels(resolution: 300, frequency: 0) == 25, "an unset screen reads 60 lpi")
        #expect(BlendResampling.levels(resolution: .nan, frequency: 60) == 25, "an unreadable resolution reads 300 dpi")
        #expect(BlendResampling.steps(levels: 25, change: 1) == 25)
        #expect(BlendResampling.steps(levels: 25, change: 0.5) == 13)
        #expect(BlendResampling.steps(levels: 256, change: 0.001) == 1)
        #expect(BlendResampling.steps(levels: 25, change: 0) == nil)
        #expect(BlendResampling.steps(levels: 5000, change: 1) == 1000)
    }

    @Test func inkChangeIsTheLargestInkOrTheSpotTint() {
        let cyan = Color(cyan: 1, magenta: 0.2, yellow: 0, black: 0)
        let paler = Color(cyan: 0.4, magenta: 0.1, yellow: 0, black: 0.1)
        #expect(abs(BlendResampling.inkChange(cyan, paler) - 0.6) < 1e-12)
        let ink = SpotInk(.swatch(NodeID(OpID(counter: 9, replica: 1))), name: "Orange", tint: 0.8)
        var orange = Color(cyan: 0, magenta: 0.5, yellow: 1, black: 0)
        orange.spot = ink
        var tint = orange
        tint.spot = SpotInk(ink.identity, name: ink.name, tint: 0.3)
        #expect(abs(BlendResampling.inkChange(orange, tint) - 0.5) < 1e-12)
        #expect(BlendResampling.inkChange(Color(white: 0), Color(white: 1)) == 1)
    }

    @Test func resampleSetsTheStepsTheDocumentCallsFor() throws {
        var a = Replica(0xA)
        let blend = try Self.blend(&a)
        // Red to blue: the cyan and yellow inks change fully.
        #expect(BlendResampling.steps(for: blend, in: a.state) == 25)
        let edit = GraphicEdit.resampleBlends(ValueRange())
        #expect(ReplaceGraphics.matches(edit, in: [blend], state: a.state) == [], "25 already (unset reads 25)")
        try a.perform(SetPrinterResolution(1200))
        try a.perform(SetPrintSettings(.defaultHalftone(.with { $0.frequency = 100 })))
        let change = try a.perform(ReplaceGraphics(edit, candidates: [blend]))!
        #expect(change.label == "Replace blend steps in 1 objects")
        #expect(a.state.props(blend).blend.steps == 144)
        // Outside the range, or not a blend: nothing.
        #expect(ReplaceGraphics.matches(.resampleBlends(ValueRange(min: 1, max: 20)), in: [blend], state: a.state).isEmpty)
        let square = BlendReading.keyObjects(blend, in: a.state)[0]
        #expect(BlendResampling.steps(for: square, in: a.state) == nil)
        #expect(ReplaceGraphics.matches(edit, in: [square], state: a.state).isEmpty)
    }

    @Test func aBlendWithoutAColourChangeKeepsItsSteps() throws {
        var a = Replica(0xA)
        let blend = try Self.blend(&a, red: 1)
        #expect(BlendResampling.steps(for: blend, in: a.state) == nil)
        #expect(ReplaceGraphics.matches(.resampleBlends(ValueRange()), in: [blend], state: a.state).isEmpty)
    }

    @Test func gradientStopsAndStrokesCount() throws {
        var a = Replica(0xA)
        let blend = try Self.blend(&a, red: 1)
        let keys = BlendReading.keyObjects(blend, in: a.state)
        // A grey stroke on one key and black on the other: black ink changes by half.
        try a.perform(AddAppearance.stroke([keys[0]], Appearances.basicStroke(red: 0.5, green: 0.5, blue: 0.5, width: 1)))
        try a.perform(AddAppearance.stroke([keys[1]], Appearances.basicStroke(red: 0, green: 0, blue: 0, width: 1)))
        #expect(BlendResampling.steps(for: blend, in: a.state) == 13)
        // Gradient fills compare stop by stop.
        let rows = keys.map { key in AppearanceEditing.stack(key, in: a.state).last { $0.list == .fills }! }
        try a.perform(ChooseGradient([(keys[0], rows[0]), (keys[1], rows[1])]))
        let colors = BlendResampling.colors(of: keys[0], resolver: ColorResolver(a.state), in: a.state)
        #expect(colors[0].count == 2 && colors[1].count == 1)
    }
}
