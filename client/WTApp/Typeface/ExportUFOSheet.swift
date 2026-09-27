import AppKit
import Observation
import SwiftUI
import UniformTypeIdentifiers
import WTInterchange
import WTModel

/// menu:File[Export UFO…] (font-export.adoc, "UFO packages"; FONT-023): *Flattened* or *As drawn*,
/// the standard glyphs and the generated features, then btn:[Export…] asks where the `.ufo`
/// package goes and writes it (`UFOExport`) off the main actor; the report -- strokes written as
/// outlines -- is shown in the sheet.  Exporting never changes the document.
@MainActor
@Observable
final class ExportUFOModel {
    @ObservationIgnored let document: DocumentHandle
    var artwork: UFOExportOptions.Artwork = .flattened
    var addStandardGlyphs = true
    var generatedFeatures = true
    private(set) var isWorking = false
    private(set) var message: String?
    /// The package the last export wrote.
    private(set) var written: URL?
    /// Asks where the package goes (replaced in tests).
    @ObservationIgnored var chooseDestination: @MainActor (String) async -> URL? = { name in
        let panel = NSSavePanel()
        panel.nameFieldStringValue = name
        panel.allowedContentTypes = [UTType(filenameExtension: "ufo", conformingTo: .package) ?? .package]
        panel.canCreateDirectories = true
        panel.prompt = "Export"
        return await ModalUI.url(panel, on: nil)
    }

    init(document: DocumentHandle) {
        self.document = document
    }

    var options: UFOExportOptions {
        UFOExportOptions(artwork: artwork, addStandardGlyphs: addStandardGlyphs, generatedFeatures: generatedFeatures)
    }

    /// `<PostScript name>.ufo`.
    var fileName: String { WTModel.FontInfo(document.state).names.postscript + ".ufo" }

    /// btn:[Export…]: asks for the place, then writes.
    @discardableResult
    func exportAsking() -> Task<URL?, Never> {
        let name = fileName
        return Task { [weak self] in
            guard let self, let url = await self.chooseDestination(name) else { return nil }
            return await self.export(to: url).value
        }
    }

    /// Writes the package at `url`; the report or the failure is shown in the sheet.
    @discardableResult
    func export(to url: URL) -> Task<URL?, Never> {
        let state = document.state, options = options
        isWorking = true
        message = nil
        return Task { [weak self] in
            let outcome = await Task.detached { () -> Result<[String], any Error> in
                Result { try UFOExport.write(state, to: url, options: options) }
            }.value
            self?.isWorking = false
            switch outcome {
            case .success(let report):
                self?.written = url
                self?.message = (["Exported \(url.lastPathComponent)"] + report).joined(separator: "\n")
                return url
            case .failure(let error):
                self?.message = "Exporting failed: \(error.localizedDescription)"
                return nil
            }
        }
    }

    // The sheet's button.
    func exportButton() { exportAsking() }
}

struct ExportUFOSheet: View {
    @Bindable var model: ExportUFOModel
    let close: @MainActor () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Export UFO").font(.headline)
            Picker("Artwork", selection: $model.artwork) {
                Text("Flattened").tag(UFOExportOptions.Artwork.flattened)
                Text("As drawn").tag(UFOExportOptions.Artwork.asDrawn)
            }
            .pickerStyle(.radioGroup)
            .accessibilityIdentifier("exportUFO.artwork")
            Text(model.artwork == .flattened
                ? "The generated outlines: components kept as components, everything else merged."
                : "Each path as a contour, strokes as contours, overlaps intact.")
                .font(.caption).foregroundStyle(.secondary)
            Toggle("Add .notdef and space when missing", isOn: $model.addStandardGlyphs)
            Toggle("Add the generated features to features.fea", isOn: $model.generatedFeatures)
            if let message = model.message { Text(message).font(.caption).accessibilityIdentifier("exportUFO.message") }
            HStack {
                Spacer()
                Button("Close", action: close).keyboardShortcut(.cancelAction)
                Button("Export…", action: model.exportButton).keyboardShortcut(.defaultAction).disabled(model.isWorking)
                    .accessibilityIdentifier("exportUFO.ok")
            }
        }
        .padding()
        .frame(width: 460)
    }
}
