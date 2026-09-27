import AppKit
import CoreText
import Foundation
import SwiftUI
import Testing
import WTCRDT
import WTGeometry
import WTInterchange
import WTModel
import WTProto
@testable import WireTuner

/// The Metrics window's *Features* pop-up (kerning-metrics.adoc, "Client"; FONT-020): the automatic
/// features and the feature file's, the warning for a file that does not check clean, and the
/// preview reshaping when a feature is turned on or off.
@Suite @MainActor struct MetricsFeaturesTests {
    /// A typeface with f, i, f_i, a and a.sc drawn and `features` as its feature file.
    func typeface(features: String) async throws -> TypefaceWindowFixture {
        let fixture = await TypefaceWindowFixture.typeface()
        _ = await fixture.document.perform(AddGlyphs([NewGlyph(name: "f_i", kind: .ligature), NewGlyph(name: "a.sc")])).value
        for (name, width) in [("f", 400.0), ("i", 200.0), ("f_i", 600.0), ("a", 400.0), ("a.sc", 350.0)] {
            let handle = try #require(GlyphCanvas.handle(for: fixture.glyph(name), of: fixture.document))
            _ = await fixture.box(20, -600, width - 40, 600, on: handle)
        }
        _ = await fixture.document.perform(OpsCommand("Edit features", ops: [
            Ops.textInsert(WellKnown.settings, FontFields.features, features, left: .zero),
        ])).value
        return fixture
    }

    /// The glyph names the preview font sets `text` with.
    func shaped(_ text: String, _ model: MetricsModel) throws -> [String] {
        let font = try #require(model.previewFont)
        let names = FontGeneration.snapshot(model.document.state).source.glyphs.map(\.name)
        let attributed = NSAttributedString(string: text, attributes: [NSAttributedString.Key(kCTFontAttributeName as String): font])
        return (CTLineGetGlyphRuns(CTLineCreateWithAttributedString(attributed)) as! [CTRun]).flatMap { run -> [String] in
            var glyphs = [CGGlyph](repeating: 0, count: CTRunGetGlyphCount(run))
            CTRunGetGlyphs(run, CFRange(location: 0, length: 0), &glyphs)
            return glyphs.map { names.indices.contains(Int($0)) ? names[Int($0)] : "?" }
        }
    }

    func host<V: View>(_ view: V) {
        let hosting = NSHostingView(rootView: view)
        hosting.frame = NSRect(x: 0, y: 0, width: 600, height: 700)
        hosting.layoutSubtreeIfNeeded()
        _ = hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds).map { hosting.cacheDisplay(in: hosting.bounds, to: $0) }
    }

    @Test func thePopUpTurnsFeaturesOnAndOff() async throws {
        let fixture = try await typeface(features: "feature smcp {\n  sub a by a.sc;\n} smcp;\n")
        defer { fixture.close() }
        let model = MetricsModel(document: fixture.document)
        #expect(model.features.items.isEmpty)
        host(MetricsFeaturesMenu(model: model))
        #expect(await model.compilePreview().value)
        #expect(model.features.items.map(\.tag) == ["liga", "smcp"] && model.features.warning == nil)
        // liga is on by default: "fi" previews as f_i; smcp is off until chosen.
        #expect(model.isFeatureOn("liga") && !model.isFeatureOn("smcp"))
        #expect(try shaped("afi", model) == ["a", "f_i"])
        model.setFeature("smcp", on: true)
        #expect(try shaped("afi", model) == ["a.sc", "f_i"])
        model.setFeature("liga", on: false)
        #expect(try shaped("afi", model) == ["a.sc", "f", "i"])
        // A tag the pop-up does not list is ignored; the choices survive a recompile.
        model.setFeature("ss01", on: true)
        #expect(!model.isFeatureOn("ss01"))
        #expect(await model.compilePreview().value)
        #expect(model.isFeatureOn("smcp") && !model.isFeatureOn("liga"))
        let menu = MetricsFeaturesMenu(model: model)
        menu.binding("liga").wrappedValue = true
        #expect(menu.binding("liga").wrappedValue && model.isFeatureOn("liga"))
        host(menu)
        host(MetricsView(model: model))
    }

    @Test func aFileWithErrorsPreviewsOnlyTheAutomaticFeatures() async throws {
        let fixture = try await typeface(features: "feature smcp {\n  sub a by nosuchglyph;\n} smcp;\n")
        defer { fixture.close() }
        let model = MetricsModel(document: fixture.document)
        _ = await model.compilePreview().value
        #expect(model.features.items.map(\.tag) == ["liga"])
        #expect(model.features.warning == PreviewFeatures.uncheckedWarning)
        host(MetricsView(model: model))
        // A compile that fails leaves no preview font to reshape.
        model.compile = { _ in throw FontCompiler.Failure.cancelled }
        #expect(await model.compilePreview().value == false)
        model.setFeature("liga", on: false)
        #expect(model.previewFont == nil)
    }
}
