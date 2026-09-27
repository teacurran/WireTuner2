import Foundation
import UniformTypeIdentifiers
import WTCRDT
import WTInterchange
import WTModel

/// menu:File[Open Font…] and the New Typeface sheet's *From a font file…* (font-export.adoc,
/// "Opening OTF and TTF files"; FONT-025): the file is read (`OpenTypeReader`; a WOFF2 file is
/// unwrapped first), planned against the document (`FontImport.plan`) and written as one undo
/// step; the plan's report comes back for the sheet to show.  A UFO package goes through
/// `importUFO` (FONT-024).
@MainActor
struct FontImportController {
    let document: DocumentHandle

    static let contentTypes: [UTType] = [.font, UTType(filenameExtension: "otf"), UTType(filenameExtension: "ttf"), UTType(filenameExtension: "woff2")]
        .compactMap { $0 }
    static let unreadable = "The file is not an OpenType or TrueType font this version can read."

    /// The file's font, nil when it cannot be read.
    static func read(_ data: Data, fileExtension: String) -> ImportedFont? {
        let sfnt = fileExtension.lowercased() == "woff2" ? (try? WOFF2Reader.sfnt(data)) : data
        return sfnt.flatMap { try? OpenTypeReader.read($0) }
    }

    /// Imports `url` into the document (a new typeface when `newDocument`); the task finishes
    /// with the import report once every change is applied.  Nil when the file cannot be read.
    func importFile(_ url: URL, newDocument: Bool) -> Task<[String], Never>? {
        guard let data = try? Data(contentsOf: url), let font = Self.read(data, fileExtension: url.pathExtension) else { return nil }
        return importFont(font, fileName: url.lastPathComponent, newDocument: newDocument)
    }

    /// A `.ufo` package (UFO is a folder; the type is the extension's).
    static let ufoType = UTType(filenameExtension: "ufo", conformingTo: .package) ?? .package

    static func isUFO(_ url: URL) -> Bool { url.pathExtension.lowercased() == "ufo" }

    /// Imports the UFO package at `url` (FONT-024): read off the main actor (`UFOReader`), planned
    /// against the document (`UFOImport.plan`: collisions, anchors, colours, and for a new
    /// document the feature file and the lib) and written as one undo step.  The plan's report,
    /// or why the package could not be read.
    func importUFO(_ url: URL, newDocument: Bool) async -> Result<[String], any Error> {
        let read = await Task.detached { Result { try UFOReader.read(at: url) } }.value
        switch read {
        case .failure(let error):
            return .failure(error)
        case .success(let ufo):
            await document.settle()
            let plan = UFOImport.plan(ufo, fileName: url.lastPathComponent, into: document.state, newDocument: newDocument)
            _ = await document.performGroup(plan.commands).value
            return .success(plan.report)
        }
    }

    /// Imports `font` once the document's model is open.
    func importFont(_ font: ImportedFont, fileName: String, newDocument: Bool) -> Task<[String], Never> {
        let document = document
        return Task {
            await document.settle()
            let plan = FontImport.plan(font, fileName: fileName, into: document.state, newDocument: newDocument)
            _ = await document.performGroup(plan.commands).value
            return plan.report
        }
    }
}

extension DocumentHandle {
    /// Performs `commands` in order as one undo step, after everything issued before; the task
    /// finishes with how many changed the document.
    @discardableResult
    func performGroup(_ commands: [any WTModel.Command]) -> Task<Int, Never> {
        Task {
            await self.settle()
            self.beginGroup()
            var count = 0
            for command in commands where await self.perform(command).value != nil { count += 1 }
            self.endGroup()
            return count
        }
    }
}
