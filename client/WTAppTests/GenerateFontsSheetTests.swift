import AppKit
import Foundation
import SwiftUI
import Testing
import WTCRDT
import WTInterchange
import WTModel
@testable import WireTuner

/// FONT-026 (rest): the Generate Fonts sheet's Fix All Warnings (one undo step), background
/// generation with progress and Stop, and the sync-state reminder.
@Suite @MainActor struct GenerateFontsSheetTests {
    @Test func fixAllWarningsIsOneUndoStep() async throws {
        let fixture = try await TypefaceFontTests().drawnTypeface()
        defer { fixture.close() }
        let handle = try #require(GlyphCanvas.handle(for: fixture.glyph("B"), of: fixture.document))
        _ = await fixture.box(50.5, -600.25, 400, 600, on: handle)
        let model = GenerateFontsModel(document: fixture.document, installer: fixture.features.installer)
        TypefaceFontTests().host(GenerateFontsSheet(model: model, close: {}))
        #expect(model.fixableGlyphs == [fixture.glyph("B")])
        await model.fixAllWarnings().value
        #expect(model.fixableGlyphs.isEmpty && model.message == "Fixed the warnings of 1 glyph")
        #expect(GlyphOutlines.metrics(of: fixture.glyph("B"), in: fixture.document.state)?.bounds?.minX == 51)
        // One undo step brings the warning back.
        _ = await fixture.document.undo().value
        model.validate()
        #expect(model.fixableGlyphs == [fixture.glyph("B")])
        // Two glyphs, one step; nothing to fix does nothing.
        let other = try #require(GlyphCanvas.handle(for: fixture.glyph("C"), of: fixture.document))
        _ = await fixture.box(10.5, -600, 400, 600, on: other)
        model.validate()
        #expect(model.fixableGlyphs.count == 2)
        await model.fixAllWarnings().value
        #expect(model.fixableGlyphs.isEmpty && model.message == "Fixed the warnings of 2 glyphs")
        model.fixWarningsButton()
        _ = await fixture.document.undo().value
        model.validate()
        #expect(model.fixableGlyphs.count == 2)
    }

    @Test func generatesInTheBackgroundAndStops() async throws {
        let fixture = try await TypefaceFontTests().drawnTypeface()
        defer { fixture.close() }
        let model = GenerateFontsModel(document: fixture.document, installer: fixture.features.installer)
        let folder = FileManager.default.temporaryDirectory.appending(path: "WireTunerStop-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        model.ttf = true
        // Started, the sheet shows progress; stopped before it compiles, nothing is written.
        let task = model.generate(into: folder)
        #expect(model.isWorking && model.progress == 0)
        TypefaceFontTests().host(GenerateFontsSheet(model: model, close: {}))
        model.stopGenerating()
        #expect(await task.value.isEmpty)
        #expect(model.message == "Generating stopped; nothing was written" && model.progress == nil && !model.isWorking)
        #expect(try FileManager.default.contentsOfDirectory(atPath: folder.path).isEmpty)
        // Stopped while compiling: the compile is cancelled with it.
        let compiling = model.generate(into: folder)
        await Task.yield()
        model.stopGenerating()
        let urls = await compiling.value
        #expect(urls.isEmpty == (model.message == "Generating stopped; nothing was written"))
        // Run to the end, the progress goes away.
        #expect(await model.generate(into: folder).value.count == 2 && model.progress == nil && model.progressText == "Writing…")
        model.stopGenerating()
    }

    @Test func showsTheSyncStateAndReminds() async throws {
        let fixture = await TypefaceWindowFixture.typeface()
        defer { fixture.close() }
        let model = GenerateFontsModel(document: fixture.document, installer: fixture.features.installer)
        #expect(model.syncReminder == nil)
        let status = StubSyncStatus(state: .offline(3))
        model.attachSync(status)
        #expect(model.syncState == .offline(3) && model.syncReminder?.hasPrefix("Some changes have not been synced yet") == true)
        #expect(model.syncLine == SyncState.offline(3).label)
        TypefaceFontTests().host(GenerateFontsSheet(model: model, close: {}))
        // Followed while the sheet is open.
        status.state = .saved
        status.details = SyncDetails(collaborators: ["Ada"])
        #expect(model.syncReminder?.hasPrefix("Others are working on this typeface") == true && model.syncLine.hasSuffix("1 other person has it open"))
        status.details = SyncDetails(collaborators: ["Ada", "Grace"])
        #expect(model.syncLine.hasSuffix("2 other people have it open"))
        model.detachSync()
        status.state = .offline(1)
        #expect(model.syncState == .saved)
        // Closing the sheet stops a generation and the following.
        model.attachSync(status)
        var closed = false
        model.closing { closed = true }()
        status.state = .saved
        #expect(closed && model.syncState == .offline(1))
        // The sheet the menu item opens follows its window's sync state.
        fixture.front = fixture.window
        let window = try #require(fixture.features.presentGenerate())
        fixture.window.window?.endSheet(window)
    }
}
