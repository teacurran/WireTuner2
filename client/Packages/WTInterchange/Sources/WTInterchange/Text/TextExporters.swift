// The Rich Text and Plain Text exporters (IO-030): every story of the scene's text blocks, in the
// export order, into one file.

import Foundation

public struct RTFExporter: Exporter {
    public init() {}

    public var format: ExportFormat { .rtf }
    public var optionsType: any ExportOptions.Type { RTFOptions.self }
    public var capabilities: ExportCapabilities { ExportFormat.rtf.capabilities }

    /// The scene's text as RTF, and notes.
    public func data(scene: ExportScene, options: RTFOptions) throws -> (data: Data, notes: [String]) {
        let stories = TextStories.ordered(scene.text)
        guard !stories.isEmpty else {
            throw ExportError.nothingToExport
        }
        let writer = RTFWriter(options: options)
        let text = writer.document(stories)
        var notes: [String] = []
        if writer.pictures > 0 {
            notes.append("\(writer.pictures) inline graphic\(writer.pictures == 1 ? "" : "s") embedded as PNG")
        }
        return (Data(text.utf8), notes)
    }

    public func export(scene: ExportScene, options: any ExportOptions, to destination: ExportDestination) throws -> ExportSummary {
        let options = try typed(options, as: RTFOptions.self)
        return try destination.writeSingle(data(scene: scene, options: options), extension: format.fileExtension)
    }
}

public struct PlainTextExporter: Exporter {
    public init() {}

    public var format: ExportFormat { .text }
    public var optionsType: any ExportOptions.Type { PlainTextOptions.self }
    public var capabilities: ExportCapabilities { ExportFormat.text.capabilities }

    /// The scene's text as plain text in the chosen encoding and line endings.
    public func data(scene: ExportScene, options: PlainTextOptions) throws -> Data {
        let stories = TextStories.ordered(scene.text)
        guard !stories.isEmpty else {
            throw ExportError.nothingToExport
        }
        return PlainTextWriter.data(stories, options: options)
    }

    public func export(scene: ExportScene, options: any ExportOptions, to destination: ExportDestination) throws -> ExportSummary {
        let options = try typed(options, as: PlainTextOptions.self)
        return try destination.writeSingle((try data(scene: scene, options: options), []), extension: format.fileExtension)
    }
}
