import AppKit
import Observation
import SwiftUI
import WTCRDT
import WTInterchange
import WTModel

/// menu:File[Generate Fonts…] (font-export.adoc, "Generating fonts"; FONT-026, FONT-027): the
/// validation list -- errors block, a row opens its glyph -- the formats (OTF, TTF, WOFF2) and
/// options, and btn:[Generate] writing the files into a folder; btn:[Install for Testing]
/// registers an OTF with the *Test* suffix and btn:[Remove Test Fonts] takes them away again.
@MainActor
@Observable
final class GenerateFontsModel {
    @ObservationIgnored let document: DocumentHandle
    @ObservationIgnored let installer: TestFontInstaller
    var otf = true
    var ttf = false
    var woff2 = false
    /// What the WOFF2 wraps: the OTF (CFF outlines, the default) or the TTF (quadratic `glyf`).
    var woff2Outlines: FontCompiler.Format = .otf
    var addStandardGlyphs = true {
        didSet { validate() }
    }
    var keepOverlaps = false
    private(set) var problems: [FontProblem] = []
    private(set) var isWorking = false
    private(set) var message: String?
    /// The files the last Generate wrote.
    private(set) var written: [URL] = []
    @ObservationIgnored var openGlyph: @MainActor (OpID) -> Void = { _ in }
    @ObservationIgnored var didInstall: @MainActor ([URL]) -> Void = { _ in }
    @ObservationIgnored var removeInstalled: @MainActor () -> Void = {}
    /// Asks for the folder the fonts go in (replaced in tests).
    @ObservationIgnored var chooseFolder: @MainActor () async -> URL? = {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = "Generate"
        return await ModalUI.urls(panel, on: nil).first
    }

    init(document: DocumentHandle, installer: TestFontInstaller) {
        self.document = document
        self.installer = installer
        validate()
    }

    var options: FontGenerationOptions {
        FontGenerationOptions(addStandardGlyphs: addStandardGlyphs, keepOverlaps: keepOverlaps)
    }

    /// Whether an error in the list stops generating.
    var isBlocked: Bool { FontValidation.blocksGeneration(problems) }

    var formats: [FontCompiler.Format] {
        (otf || (woff2 && woff2Outlines == .otf) ? [.otf] : []) + (ttf || (woff2 && woff2Outlines == .ttf) ? [.ttf] : [])
    }

    /// The file name the fonts go by: the PostScript name.
    var baseName: String { WTModel.FontInfo(document.state).names.postscript }

    /// Validates the document as it is now.
    func validate() {
        problems = FontGeneration.snapshot(document.state, options: options).problems
    }

    /// A row of the list was clicked: its glyph opens.
    func open(_ problem: FontProblem) {
        guard let glyph = problem.glyph else { return }
        openGlyph(glyph)
    }

    /// btn:[Generate]: asks for the folder, then writes every chosen format.
    @discardableResult
    func generateAsking() -> Task<[URL], Never> {
        Task { [weak self] in
            guard let self, let folder = await self.chooseFolder() else { return [] }
            return await self.generate(into: folder).value
        }
    }

    /// Writes the chosen formats into `folder`: OTF, TTF and a WOFF2 of the OTF or the TTF, as
    /// chosen.  A failure is shown in the sheet and writes nothing more.
    @discardableResult
    func generate(into folder: URL) -> Task<[URL], Never> {
        validate()
        guard !isBlocked else {
            message = "Fix the errors in the list first"
            return Task { [] }
        }
        let state = document.state, options = options, formats = formats, base = baseName
        let wanted: [FontCompiler.Format: Bool] = [.otf: otf, .ttf: ttf], wantsWOFF2 = woff2, wrapped = woff2Outlines
        isWorking = true
        message = nil
        return Task { [weak self] in
            var urls: [URL] = []
            do {
                for format in formats {
                    let result = try await FontGeneration.generate(state, format: format, options: options)
                    if wanted[format] == true {
                        let url = folder.appending(path: "\(base).\(format.fileExtension)")
                        try result.data.write(to: url, options: .atomic)
                        urls.append(url)
                    }
                    if format == wrapped, wantsWOFF2 {
                        let url = folder.appending(path: "\(base).woff2")
                        try WOFF2Writer.woff2(result.data).write(to: url, options: .atomic)
                        urls.append(url)
                    }
                }
                self?.message = urls.count == 1 ? "Generated \(urls[0].lastPathComponent)" : "Generated \(urls.count) files"
            } catch {
                self?.message = "Generating failed: \(error)"
            }
            self?.written = urls
            self?.isWorking = false
            return urls
        }
    }

    /// btn:[Install for Testing]: an OTF with the *Test* suffix, registered for this user.
    @discardableResult
    func installForTesting() -> Task<URL?, Never> {
        var options = options
        options.testSuffix = true
        let state = document.state, installer = installer
        let problems = FontGeneration.snapshot(state, options: options).problems
        guard !FontValidation.blocksGeneration(problems) else {
            message = "Fix the errors in the list first"
            return Task { nil }
        }
        let name = WTModel.FontInfo.generatedPostScriptName(family: WTModel.FontInfo(state).names.family + " Test", style: WTModel.FontInfo(state).names.style)
        isWorking = true
        return Task { [weak self] in
            defer { self?.isWorking = false }
            do {
                let result = try await FontGeneration.generate(state, format: .otf, options: options)
                let url = try installer.install(result.data, fileName: "\(name).otf")
                self?.didInstall([url])
                self?.message = "Installed \(name) for testing"
                return url
            } catch {
                self?.message = "Installing failed: \(error)"
                return nil
            }
        }
    }

    // The sheet's buttons.
    func installButton() { installForTesting() }
    func generateButton() { generateAsking() }
    func openAction(_ problem: FontProblem) -> @MainActor () -> Void {
        { [weak self] in self?.open(problem) }
    }

    /// btn:[Remove Test Fonts].
    func removeTestFonts() {
        removeInstalled()
        message = "Removed the test fonts"
    }
}

struct GenerateFontsSheet: View {
    @Bindable var model: GenerateFontsModel
    let close: @MainActor () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Generate Fonts").font(.headline)
            ScrollView {
                VStack(alignment: .leading) {
                    ForEach(Array(model.problems.enumerated()), id: \.offset) { _, problem in
                        HStack {
                            Image(systemName: problem.level == .error ? "xmark.octagon.fill" : "exclamationmark.triangle.fill")
                                .foregroundStyle(problem.level == .error ? .red : .orange)
                            Text(problem.message)
                            Spacer()
                            if problem.glyph != nil { Button("Show", action: model.openAction(problem)) }
                        }
                    }
                }
            }
            .frame(height: 160)
            .accessibilityIdentifier("generate.problems")
            HStack {
                Toggle("OTF", isOn: $model.otf)
                Toggle("TTF", isOn: $model.ttf)
                Toggle("WOFF2", isOn: $model.woff2)
                Picker("of", selection: $model.woff2Outlines) {
                    Text("OTF").tag(FontCompiler.Format.otf)
                    Text("TTF").tag(FontCompiler.Format.ttf)
                }
                .fixedSize()
                .disabled(!model.woff2)
                .accessibilityIdentifier("generate.woff2Outlines")
            }
            Toggle("Add .notdef and space when missing", isOn: $model.addStandardGlyphs)
            Toggle("Keep overlaps", isOn: $model.keepOverlaps)
            if let message = model.message { Text(message).font(.caption).accessibilityIdentifier("generate.message") }
            HStack {
                Button("Install for Testing", action: model.installButton).disabled(model.isBlocked || model.isWorking)
                Button("Remove Test Fonts", action: model.removeTestFonts)
                Spacer()
                Button("Close", action: close).keyboardShortcut(.cancelAction)
                Button("Generate…", action: model.generateButton).keyboardShortcut(.defaultAction)
                    .disabled(model.isBlocked || model.isWorking || model.formats.isEmpty).accessibilityIdentifier("generate.ok")
            }
        }
        .padding()
        .frame(width: 520)
    }
}
