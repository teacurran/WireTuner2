import AppKit
import Foundation
import SwiftUI
import Testing
import WTCRDT
import WTGeometry
import WTInterchange
import WTModel
import WTProto
import WTRender
import WTText
@testable import WireTuner

/// PRINT-014: the Print dialog's missing-font warning -- only fonts on printed pages, the
/// substitution sheet behind it, and the preference that turns it off.
@Suite(.serialized) @MainActor struct PrintFontWarningTests {
    /// A text block set in `family`, its top-left at `point`.
    static func text(_ document: DocumentHandle, _ family: String, at point: Point) async {
        var mark = Wiretuner_Doc_V1_TextMarkValue()
        mark.fontFamily = family
        _ = await document.perform(CreateTextBlock(.point(point), text: "Ab", marks: [mark])).value
        await document.settle()
    }

    @Test func theMessageNamesEachMissingFamilyOnce() {
        #expect(PrintFontWarning().message == nil)
        let one = PrintFontWarning(faces: [FaceName(family: "Univers"), FaceName(family: "Univers", style: "Bold")])
        #expect(one.message == "1 missing font: Univers")
        let two = PrintFontWarning(faces: [FaceName(family: "Univers"), FaceName(family: "Garamond")], pending: ["Garamond"])
        #expect(two.families == ["Garamond", "Univers"])
        #expect(two.message == "2 missing fonts: Garamond, Univers (waiting for the team library)")
    }

    @Test func onlyPrintedTextWarnsAndThePreferenceSilencesIt() async throws {
        let world = PrintWorld()
        defer { world.close() }
        let printed = FontDocuments.missing("Printed"), offstage = FontDocuments.missing("Offstage")
        await Self.text(world.document, printed, at: world.point(-40, -10))
        let second = FontDocuments.missing("Also")
        await Self.text(world.document, second, at: world.point(-40, 30))
        await Self.text(world.document, offstage, at: world.point(5000, 0))
        // Text in the document's default font names no face.
        _ = await world.document.perform(CreateTextBlock(.point(world.point(-40, 60)), text: "Plain")).value
        await world.document.settle()
        let preferences = world.setup.environment.preferences
        let fonts = DocumentFonts(preferences: preferences)
        fonts.present = { _, _ in }
        _ = await fonts.documentDidOpen(world.window)
        let checker = try #require(PrintFontChecker.make(fonts: fonts, preferences: preferences, document: world.document))
        let document = world.document
        let session = PrintSession(document: document, info: NSPrintInfo(), selection: nil, imageStore: nil, blobs: BlobPlacement(), fonts: checker) { document.perform($0) }
        #expect(session.pane.fonts.families == [second, printed].sorted(), "the pasteboard's font is not in the job")
        #expect(session.pane.fonts.message == "2 missing fonts: \([second, printed].sorted().joined(separator: ", "))")
        _ = NSHostingView(rootView: PrintFontWarningView(model: session.pane)).fittingSize
        _ = NSHostingView(rootView: PrintPaneView(model: session.pane)).fittingSize
        // The preference off: no warning.
        _ = preferences.set(false, for: PreferenceCatalog.Printing.warnMissingFonts)
        session.pane.show(session.plan)
        #expect(session.pane.fonts.message == nil)
        _ = NSHostingView(rootView: PrintFontWarningView(model: session.pane)).fittingSize
        _ = preferences.set(true, for: PreferenceCatalog.Printing.warnMissingFonts)
        session.pane.show(session.plan)
        // No checker, no warning; no font index yet, no checker.
        let plain = PrintSession(document: document, info: NSPrintInfo(), selection: nil, imageStore: nil, blobs: BlobPlacement()) { document.perform($0) }
        #expect(plain.pane.fonts == PrintFontWarning())
        plain.pane.showSubstitutions()
        #expect(PrintFontChecker.make(fonts: DocumentFonts(preferences: preferences), preferences: preferences, document: document) == nil)
        // A click on the warning opens the substitution sheet over the missing faces; when it
        // closes the job is checked again.
        var asked: [[FaceName]] = []
        var stub = checker
        stub.substitute = { faces, done in
            asked.append(faces)
            done()
        }
        session.pane.fontChecker = stub
        let revision = session.pane.revision
        session.pane.showSubstitutions()
        #expect(asked == [[second, printed].sorted().map { FaceName(family: $0) }] && session.pane.revision == revision + 1)
        // The app's substitute opens the sheet (on the key window, or on its own without one).
        var finished = 0
        checker.substitute([FaceName(family: printed)]) { finished += 1 }
        let sheet = try #require(NSApp.windows.first { $0.identifier?.rawValue == "print-missing-fonts" && ($0.isVisible || $0.sheetParent != nil) })
        let hosting = try #require(sheet.contentViewController as? NSHostingController<MissingFontsSheet>)
        hosting.rootView.model.didActivate()
        hosting.rootView.finish(false)
        #expect(await eventually { finished == 1 })
        fonts.documentDidClose(world.document)
    }

    @Test func theSheetFromThePrintDialogSubstitutesAndReplaces() async throws {
        let world = PrintWorld()
        defer { world.close() }
        let missing = FontDocuments.missing(), other = FontDocuments.missing()
        await Self.text(world.document, missing, at: world.point(-40, -10))
        await Self.text(world.document, other, at: world.point(-40, 20))
        let preferences = world.setup.environment.preferences
        let fonts = DocumentFonts(preferences: preferences)
        fonts.present = { _, _ in }
        _ = await fonts.documentDidOpen(world.window)
        let index = try #require(fonts.index(for: world.document.id))
        // A document-only substitution, then btn:[Cancel]: kept for this document, nothing written.
        let undo = world.document.undoTitle
        var closed = 0
        let model = fonts.presentSubstitutions([FaceName(family: other)], for: world.document, index: index, on: nil) { closed += 1 }
        let sheet = try #require(NSApp.windows.first { $0.identifier?.rawValue == "print-missing-fonts" && $0.isVisible })
        model.selectAll()
        model.remember = false
        model.substitute(with: FaceName(family: "Courier"))
        try #require(sheet.contentViewController as? NSHostingController<MissingFontsSheet>).rootView.finish(false)
        #expect(await eventually { closed == 1 })
        #expect(!sheet.isVisible && world.document.undoTitle == undo)
        #expect(index.documentSubstitutions.map(\.missing) == [FaceName(family: other)])
        // A replacement, then btn:[Open]: one change, on a sheet over a window.
        let parent = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 300, height: 200), styleMask: [.titled], backing: .buffered, defer: false)
        parent.isReleasedWhenClosed = false
        let replacing = fonts.presentSubstitutions([FaceName(family: missing)], for: world.document, index: index, on: parent) { closed += 1 }
        #expect(await eventually { parent.attachedSheet != nil })
        replacing.selectAll()
        replacing.replace(with: FaceName(family: "Georgia"))
        let attached = try #require(parent.attachedSheet)
        try #require(attached.contentViewController as? NSHostingController<MissingFontsSheet>).rootView.finish(true)
        #expect(await eventually { closed == 2 && world.document.undoTitle == "Undo Replace font \(missing) with Georgia" })
        parent.close()
        fonts.documentDidClose(world.document)
    }

    @Test func printingPassesTheChecker() async throws {
        let world = PrintWorld()
        defer { world.close() }
        var checked = 0
        world.features.fontChecker = { _ in
            checked += 1
            return PrintFontChecker(warns: { true }, faces: { [:] }, report: { _ in FontReport() }, substitute: { _, done in done() })
        }
        world.features.runPrint = { _ in false }
        #expect(!world.features.print())
        #expect(checked == 1 && world.features.pane?.fontChecker != nil && world.features.pane?.fonts == PrintFontWarning())
    }
}
