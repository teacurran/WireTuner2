import AppKit
import Observation
import SwiftUI
import WTCRDT
import WTInterchange
import WTModel

/// menu:File[Generate Fonts…] (font-export.adoc, "Generating fonts"; FONT-026, FONT-027): the
/// validation list -- errors block, a row opens its glyph, btn:[Fix All Warnings] fixes in the
/// document what generation would correct anyway (one undo step) -- the formats (OTF, TTF, WOFF2)
/// and options, and btn:[Generate] compiling in the background with progress and btn:[Stop], then
/// writing the files into a folder; btn:[Install for Testing] registers an OTF with the *Test*
/// suffix and btn:[Remove Test Fonts] takes them away again.  The sheet shows the document's sync
/// state and who else has it open, with a reminder that the font is a snapshot.
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
    /// While generating: how far (0...1) and what is being done.
    private(set) var progress: Double?
    private(set) var progressText = ""
    @ObservationIgnored private var running: Task<[URL], Never>?
    /// The document's sync state and how many others have it open.
    var syncState: SyncState = .saved
    var collaborators = 0
    @ObservationIgnored private weak var syncStatus: (any SyncStatusProviding)?
    @ObservationIgnored private var syncToken: UUID?
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

    // MARK: Fix All Warnings

    /// The glyphs btn:[Fix All Warnings] rewrites.
    var fixableGlyphs: [OpID] { FixGlyphWarnings.glyphs(in: problems) }

    /// btn:[Fix All Warnings]: Correct Directions, Remove Overlaps, Add Extrema and Round to Units
    /// on every warned glyph's artwork, one undo step; the list is checked again after.
    @discardableResult
    func fixAllWarnings() -> Task<Void, Never> {
        let glyphs = fixableGlyphs
        guard !glyphs.isEmpty else { return Task {} }
        let change = document.perform(FixGlyphWarnings(glyphs))
        return Task { [weak self] in
            _ = await change.value
            self?.validate()
            self?.message = glyphs.count == 1 ? "Fixed the warnings of 1 glyph" : "Fixed the warnings of \(glyphs.count) glyphs"
        }
    }

    // MARK: Sync state

    /// Follows `status` while the sheet is open.
    func attachSync(_ status: any SyncStatusProviding) {
        syncStatus = status
        refreshSync()
        syncToken = status.observe { [weak self] in self?.refreshSync() }
    }

    /// The sheet closed: stops following the sync state.
    func detachSync() {
        if let syncToken { syncStatus?.stopObserving(syncToken) }
        syncToken = nil
    }

    func refreshSync() {
        guard let syncStatus else { return }
        syncState = syncStatus.state
        collaborators = syncStatus.details.collaborators.count
    }

    /// The sync line under the list: the state, and who else has the document open.
    var syncLine: String {
        syncState.label + (collaborators == 0 ? "" : collaborators == 1 ? " · 1 other person has it open" : " · \(collaborators) other people have it open")
    }

    /// The reminder that a generated font is a snapshot, when it matters.
    var syncReminder: String? {
        if syncState.hasWaitingWork {
            return "Some changes have not been synced yet: the font has them, your collaborators do not yet."
        }
        return collaborators > 0 ? "Others are working on this typeface: the font is a snapshot of it now; generate again later for their changes." : nil
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
    /// chosen.  Every format is compiled in the background first (with progress; btn:[Stop]
    /// cancels and writes nothing), then the files are written.  A failure is shown in the sheet.
    @discardableResult
    func generate(into folder: URL) -> Task<[URL], Never> {
        validate()
        guard !isBlocked else {
            message = "Fix the errors in the list first"
            return Task { [] }
        }
        let state = document.state, options = options, formats = formats, base = baseName, date = Date()
        let wanted: [FontCompiler.Format: Bool] = [.otf: otf, .ttf: ttf], wantsWOFF2 = woff2, wrapped = woff2Outlines
        isWorking = true
        message = nil
        progress = 0
        let task = Task { [weak self] in
            var urls: [URL] = []
            do {
                var compiled: [(format: FontCompiler.Format, data: Data)] = []
                for (offset, format) in formats.enumerated() {
                    try Task.checkCancellation()
                    self?.progress = Double(offset) / Double(formats.count + 1)
                    self?.progressText = "Compiling \(format.fileExtension.uppercased())…"
                    compiled.append((format, try await FontGeneration.generate(state, format: format, options: options, date: date).data))
                }
                try Task.checkCancellation()
                self?.progress = Double(formats.count) / Double(formats.count + 1)
                self?.progressText = "Writing…"
                for (format, data) in compiled {
                    if wanted[format] == true {
                        let url = folder.appending(path: "\(base).\(format.fileExtension)")
                        try data.write(to: url, options: .atomic)
                        urls.append(url)
                    }
                    if format == wrapped, wantsWOFF2 {
                        let url = folder.appending(path: "\(base).woff2")
                        try WOFF2Writer.woff2(data).write(to: url, options: .atomic)
                        urls.append(url)
                    }
                }
                self?.message = urls.count == 1 ? "Generated \(urls[0].lastPathComponent)" : "Generated \(urls.count) files"
            } catch is CancellationError {
                self?.message = "Generating stopped; nothing was written"
            } catch FontCompiler.Failure.cancelled {
                self?.message = "Generating stopped; nothing was written"
            } catch {
                self?.message = "Generating failed: \(error)"
            }
            self?.written = urls
            self?.isWorking = false
            self?.progress = nil
            self?.running = nil
            return urls
        }
        running = task
        return task
    }

    /// The sheet's Close: stops a generation still running and the sync following, then `close`.
    func closing(_ close: @escaping @MainActor () -> Void) -> @MainActor () -> Void {
        { [weak self] in
            self?.stopGenerating()
            self?.detachSync()
            close()
        }
    }

    /// btn:[Stop]: cancels the generation running.
    func stopGenerating() {
        running?.cancel()
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
                let result = try await FontGeneration.generate(state, format: .otf, options: options, date: Date())
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
    func fixWarningsButton() { fixAllWarnings() }
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
            HStack {
                Text("Generate Fonts").font(.headline)
                Spacer()
                Button("Fix All Warnings", action: model.fixWarningsButton)
                    .disabled(model.fixableGlyphs.isEmpty || model.isWorking)
                    .help("Correct Directions, Remove Overlaps, Add Extrema and Round to Units on every glyph with these warnings (one undo step)")
                    .accessibilityIdentifier("generate.fixWarnings")
            }
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
            HStack(alignment: .firstTextBaseline) {
                Image(systemName: model.syncState.symbolName).foregroundStyle(.secondary)
                VStack(alignment: .leading) {
                    Text(model.syncLine).font(.caption)
                    if let reminder = model.syncReminder { Text(reminder).font(.caption).foregroundStyle(.orange) }
                }
            }
            .accessibilityIdentifier("generate.sync")
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
            if let progress = model.progress {
                HStack {
                    ProgressView(value: progress) { Text(model.progressText).font(.caption) }
                    Button("Stop", action: model.stopGenerating).accessibilityIdentifier("generate.stop")
                }
                .accessibilityIdentifier("generate.progress")
            }
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
