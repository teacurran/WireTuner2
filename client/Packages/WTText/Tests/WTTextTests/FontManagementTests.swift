import CoreText
import Foundation
import Testing
import WTGeometry
import WTRender
@testable import WTText

/// TXT-002: font lookup through installed → embedded → team library → substitution table →
/// default substitute, activation of font files for the process, embedding licences, and the
/// report the Missing Fonts sheet reads.  Activation is process-wide, so every test activates a
/// family of its own.
@Suite(.serialized) struct FontManagementTests {
    static let missing = FaceName(family: "No Such Family", style: "Bold")

    static func layout(_ text: String, _ attributes: TextAttributes, engine: TextLayoutEngine) -> TextLayout {
        engine.layout(TextContent(text, attributes: attributes), in: [Fixture.block(width: 400, height: 100)])
    }

    @Test func theChainAnswersFromTheFirstStepThatHasTheFace() {
        let fonts = FontManager()
        #expect(fonts.resolve(FaceName(family: "Helvetica", style: "Bold")) == FontResolution(source: .installed, face: FaceName(family: "Helvetica", style: "Bold")))
        #expect(fonts.isInstalled("Helvetica") && fonts.isAvailable("Helvetica") && !fonts.isAvailable("No Such Family"))
        // No row: the default substitute, Helvetica Neue, in the style asked for.
        #expect(fonts.resolve(Self.missing) == FontResolution(source: .defaultSubstitute, face: FaceName(family: "Helvetica Neue", style: "Bold")))
        // A row for the family; a row for the very style wins over it; the document's rows
        // come before the remembered ones; a row whose substitute is not available is skipped.
        fonts.substitutions = FontSubstitutionTable(rows: [
            FontSubstitution(missing: FaceName(family: "No Such Family"), substitute: FaceName(family: "Times New Roman")),
            FontSubstitution(missing: FaceName(family: "No Such Family", style: "BOLD"), substitute: FaceName(family: "Georgia", style: "Italic")),
            FontSubstitution(missing: FaceName(family: "Other Missing"), substitute: FaceName(family: "Also Missing")),
        ])
        #expect(fonts.resolve(Self.missing) == FontResolution(source: .substitution, face: FaceName(family: "Georgia", style: "Italic")))
        #expect(fonts.resolve(FaceName(family: "No Such Family", style: "Light")) == FontResolution(source: .substitution, face: FaceName(family: "Times New Roman", style: "Light")))
        #expect(fonts.resolve(FaceName(family: "Other Missing")).source == .defaultSubstitute)
        fonts.documentSubstitutions = [FontSubstitution(missing: FaceName(family: "No Such Family"), substitute: FaceName(family: "Courier New"))]
        #expect(fonts.resolve(Self.missing).face == FaceName(family: "Courier New", style: "Bold"))
        #expect(fonts.documentSubstitutions.count == 1)
        // A default substitute that is not available either gives way to Helvetica.
        fonts.substitutions = FontSubstitutionTable(defaultSubstitute: FaceName(family: "Gone Too"))
        fonts.documentSubstitutions = []
        #expect(fonts.resolve(Self.missing) == FontResolution(source: .defaultSubstitute, face: FaceName(family: "Helvetica", style: "Bold")))
        fonts.substitutions = FontSubstitutionTable(defaultSubstitute: FaceName(family: "Courier", style: "Oblique"))
        #expect(fonts.resolve(Self.missing).face == FaceName(family: "Courier", style: "Oblique"))
        #expect(fonts.substitutions.row(for: Self.missing) == nil)
        #expect(FontSource.allCases.filter(\.isSubstitute) == [.substitution, .defaultSubstitute])
    }

    @Test func layoutUsesTheSubstituteAndReportsHowEachFaceResolved() throws {
        let fonts = FontManager()
        let engine = TextLayoutEngine(fonts: fonts)
        let laid = Self.layout("Hello", TextAttributes(fontFamily: "No Such Family", fontStyle: "Bold", size: 12), engine: engine)
        #expect(laid.fontReport.missingFamilies == ["No Such Family"])
        #expect(laid.fontReport.resolutions[Self.missing]?.face == FaceName(family: "Helvetica Neue", style: "Bold"))
        #expect(laid.fontReport.substitutedFaces.keys.sorted { $0.description < $1.description } == [Self.missing])
        #expect(laid.fontReport.facesNeedingSheet == [Self.missing])
        let run = try #require(laid.displayItems(forContainer: 0).compactMap { item -> GlyphRun? in
            if case .text(let text) = item { return text.glyphRun }
            return nil
        }.first)
        #expect(run.font.postScriptName == "HelveticaNeue-Bold", "the substitute renders")
        // A run that names no family is the document default, not reported.
        let plain = Self.layout("Hello", TextAttributes(size: 12), engine: engine)
        #expect(plain.fontReport.resolutions.isEmpty)
        // Remembering a substitution relays out in it with no sheet.
        let typeset = engine.paragraphsTypeset
        fonts.substitutions = FontSubstitutionTable(rows: [FontSubstitution(missing: FaceName(family: "No Such Family"), substitute: FaceName(family: "Courier New"))])
        let substituted = Self.layout("Hello", TextAttributes(fontFamily: "No Such Family", fontStyle: "Bold", size: 12), engine: engine)
        #expect(engine.paragraphsTypeset == typeset + 1, "the changed table retypesets")
        #expect(substituted.fontReport.facesNeedingSheet.isEmpty)
        #expect(substituted.fontReport.resolutions[Self.missing] == FontResolution(source: .substitution, face: FaceName(family: "Courier New", style: "Bold")))
        // Without layout: the sheet's check over a document's faces.
        let report = fonts.report(for: [Self.missing, FaceName(family: "Helvetica")])
        #expect(report.resolutions[FaceName(family: "Helvetica")]?.source == .installed)
        #expect(report.missingFamilies == ["No Such Family"])
        let before = fonts.generation
        fonts.refreshInstalledFonts()
        #expect(fonts.generation > before)
    }

    @Test func embeddedFontsActivateForTheProcessAndLayOutAsThemselves() throws {
        let family = "WT Fixture Embedded"
        let fonts = FontManager()
        let engine = TextLayoutEngine(fonts: fonts)
        let face = FaceName(family: family, style: "Regular")
        let attributes = TextAttributes(fontFamily: family, size: 10)
        #expect(fonts.resolve(face).source == .defaultSubstitute)
        #expect(!GlyphFont(postScriptName: "WTFixtureEmbedded-Regular", size: 10).isAvailable)
        #expect(Self.layout("B", attributes, engine: engine).fontReport.missingFamilies == [family])

        let unrelated = TextLayoutEngine(fonts: fonts)
        _ = Self.layout("Unrelated", TextAttributes(fontFamily: "Helvetica", size: 10), engine: unrelated)

        let directory = FontFixture.directory()
        let data = FontFixture.font(family: family, fsType: 0x0008)
        let faces = try fonts.activate(data, source: .embedded, directory: directory)
        #expect(faces == [face])
        #expect(try fonts.activate(data, source: .embedded, directory: directory) == faces, "activating the same bytes again is a no-op")
        #expect(fonts.resolve(face) == FontResolution(source: .embedded, face: face))
        #expect(fonts.isAvailable(family) && !fonts.isInstalled(family))
        #expect(fonts.families().contains(family) && fonts.styles(of: family) == ["Regular"] && fonts.styles(of: "No Such Family").isEmpty)
        #expect(fonts.activatedFaces(from: .embedded).contains(face))
        #expect(fonts.embedding(of: face) == FontEmbedding(fsType: 0x0008))
        let file = try #require(fonts.fileURL(of: face))
        #expect(file.deletingLastPathComponent().standardizedFileURL.path == directory.standardizedFileURL.path && file.pathExtension == "ttf")
        #expect(fonts.font(for: FaceName(family: family)) != nil && fonts.font(for: FaceName(family: "No Such Family")) == nil)
        #expect(GlyphFont(postScriptName: "WTFixtureEmbedded-Regular", size: 10).isAvailable, "WTRender's glyph runs find it by PostScript name")

        _ = Self.layout("Unrelated", TextAttributes(fontFamily: "Helvetica", size: 10), engine: unrelated)
        #expect(unrelated.paragraphsTypeset == 1, "a paragraph whose faces resolve as before stays cached")
        let laid = Self.layout("B", attributes, engine: engine)
        #expect(laid.fontReport.missingFamilies.isEmpty && laid.fontReport.resolutions[FaceName(family: family)]?.source == .embedded)
        #expect(approx(try #require(laid.glyphs().first).advance, 11), "B is 1,100 units wide")

        #expect(fonts.deactivate(fontsAt: file))
        #expect(!fonts.deactivate(fontsAt: file))
        #expect(fonts.resolve(face).source == .defaultSubstitute)
        #expect(!approx(try #require(Self.layout("B", attributes, engine: engine).glyphs().first).advance, 11), "laid out in the substitute again")
    }

    @Test func teamLibraryFontsWaitForTheirFetchThenActivate() throws {
        let family = "WT Fixture Team"
        let fonts = FontManager()
        fonts.teamLibraryFamilies = [family]
        #expect(fonts.teamLibraryFamilies == [family])
        let face = FaceName(family: family, style: "Bold")
        let waiting = fonts.report(for: [face, Self.missing])
        #expect(waiting.teamLibraryPending == [family])
        #expect(waiting.facesNeedingSheet == [Self.missing], "the sheet lists only fonts the library does not have")

        let bold = try fonts.activate(FontFixture.font(family: family, style: "Bold", weight: 700, fsType: 0x0002), source: .teamLibrary, directory: FontFixture.directory())
        #expect(bold == [face], "a team font is licensed to the team whatever its embedding bits")
        #expect(fonts.resolve(face).source == .teamLibrary)
        // Embedded wins over the team library for the same family.
        _ = try fonts.activate(FontFixture.font(family: family, style: "Italic"), source: .embedded, directory: FontFixture.directory())
        #expect(fonts.resolve(face).source == .embedded)
        fonts.deactivateAll(from: .embedded)
        #expect(fonts.resolve(face).source == .teamLibrary)
        fonts.deactivateAll(from: .teamLibrary)
        #expect(fonts.resolve(face).source == .defaultSubstitute)
        #expect(ActivationSource.allCases.map(\.fontSource) == [.embedded, .teamLibrary])
    }

    @Test func activationRefusesUnlicensedUnreadableAndDuplicateFonts() throws {
        let fonts = FontManager()
        let directory = FontFixture.directory()
        #expect(throws: FontActivationError.notLicensedForEmbedding(FaceName(family: "WT Fixture Restricted", style: "Regular"))) {
            try fonts.activate(FontFixture.font(family: "WT Fixture Restricted", fsType: 0x0002), source: .embedded, directory: directory)
        }
        #expect(throws: FontActivationError.notLicensedForEmbedding(FaceName(family: "WT Fixture Bitmap", style: "Regular"))) {
            try fonts.activate(FontFixture.font(family: "WT Fixture Bitmap", fsType: 0x0200), source: .embedded, directory: directory)
        }
        #expect(throws: FontActivationError.unreadable) {
            try fonts.activate(Data("not a font".utf8), source: .embedded, directory: directory)
        }
        // A face an installed font provides is not activated: installed wins.
        #expect(try fonts.activate(FontFixture.font(family: "Helvetica"), source: .embedded, directory: directory).isEmpty)
        // Core Text refusing the file is an error; a file it already has is not.
        let file = directory.appendingPathComponent("refused.ttf")
        try FontFixture.font(family: "WT Fixture Refused").write(to: file)
        #expect(throws: FontActivationError.registrationFailed(305)) {
            try FontActivations(register: { _ in 305 }).activate(file, source: .embedded) { _ in false }
        }
        let registered = FontActivations(register: { _ in CTFontManagerError.alreadyRegistered.rawValue })
        #expect(try registered.activate(file, source: .teamLibrary) { _ in false } == [FaceName(family: "WT Fixture Refused", style: "Regular")])
        #expect(registered.deactivate(file) && registered.generation == 2)
        #expect(FontActivations.registerWithCoreText(directory.appendingPathComponent("absent.ttf")) != nil)
        #expect(throws: (any Error).self) {
            try fonts.activate(Data([0, 1, 0, 0]), source: .embedded, directory: URL(fileURLWithPath: "/dev/null/fonts"))
        }
        #expect(FontManager.fileExtension(of: Data("OTTO....".utf8)) == "otf")
        #expect(FontManager.fileExtension(of: Data("ttcf....".utf8)) == "ttc")
        #expect(FontManager.fileExtension(of: Data([0, 1, 0, 0])) == "ttf")
    }

    @Test func embeddingPermissionsFollowFsType() throws {
        let installable = FontEmbedding(fsType: 0)
        #expect(installable.isInstallable && installable.allowsDocumentEmbedding && installable.allowsPrintEmbedding && !installable.isRestricted)
        let restricted = FontEmbedding(fsType: 0x0002)
        #expect(restricted.isRestricted && !restricted.allowsPrintEmbedding && !restricted.allowsDocumentEmbedding)
        let print = FontEmbedding(fsType: 0x0004)
        #expect(print.allowsPreviewAndPrint && !print.allowsEditing && print.allowsPrintEmbedding && !print.allowsDocumentEmbedding)
        let editable = FontEmbedding(fsType: 0x0008 | 0x0100)
        #expect(editable.allowsDocumentEmbedding && editable.forbidsSubsetting && !editable.isInstallable)
        // The least restrictive bit applies.
        #expect(!FontEmbedding(fsType: 0x0006).isRestricted)
        let bitmap = FontEmbedding(fsType: 0x0200)
        #expect(bitmap.isBitmapOnly && !bitmap.allowsPrintEmbedding && !bitmap.allowsDocumentEmbedding)
        // Read from the font; a font without an OS/2 table reads as installable.
        let fonts = FontManager()
        let face = FaceName(family: "WT Fixture No OS2", style: "Regular")
        _ = try fonts.activate(FontFixture.font(family: face.family, os2: false), source: .teamLibrary, directory: FontFixture.directory())
        #expect(fonts.embedding(of: face) == installable)
        _ = try fonts.activate(FontFixture.font(family: "WT Fixture Print", fsType: 0x0004), source: .teamLibrary, directory: FontFixture.directory())
        #expect(fonts.embedding(of: FaceName(family: "WT Fixture Print", style: "Regular")) == print)
        #expect(fonts.embedding(of: FaceName(family: "No Such Family")) == nil)
    }
}
