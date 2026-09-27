import AppIntents
import AppKit
import UniformTypeIdentifiers
import WTInterchange
import WTModel
import WTProto
import WTRender

// DOC-027: the version 1 App Intents (scripting.adoc, "Shortcuts and App Intents"): Create
// Document, Open Document, Add Pages, Export Document, Print Document, Find and Replace Text,
// Share Link and Get Document Report.  They run in the app through the same `ScriptingHost` the
// scripting dictionary uses and the same `WTModel.ScriptObjects` commands, labelled
// "Shortcut: <intent>", one change and one undo step each.  Documents are found through the
// library cache, so *Open Document* finds them by name offline.

/// What the intents reach in the app beyond `ScriptingHost`: the library's documents.
@MainActor
final class IntentsHost {
    static let shared = IntentsHost()

    /// The library's live documents (the cache: offline too).
    var libraryDocuments: @MainActor () -> [LibraryDocument] = { [] }
    /// Opens `id` (bringing its window forward); nil when it cannot be opened now.
    var open: @MainActor (String) -> DocumentHandle? = { ScriptingHost.shared.open($0) }
    /// A new document named `name` from the template `templateID` (nil: the default template).
    var create: @MainActor (_ name: String, _ templateID: String?) async throws -> DocumentHandle? = { name, _ in ScriptingHost.shared.create(name) }
    /// Where exported files and reports are written before they are handed to Shortcuts.
    var scratch: @MainActor () -> URL = { FileManager.default.temporaryDirectory.appending(path: "WireTunerIntents-\(UUID().uuidString)") }

    /// `id`'s open handle, opening it first; fails with a localized reason.
    func handle(for document: DocumentEntity) throws -> DocumentHandle {
        guard let handle = open(document.id) else {
            throw ScriptingHost.shared.isOnline() ? IntentFailure.notFound(document.name) : IntentFailure.offline(document.name)
        }
        return handle
    }

    /// Runs `command` on `handle` as "Shortcut: <label>" and waits for its change.
    @discardableResult
    func perform(_ command: any WTModel.Command, label: String, on handle: DocumentHandle) async throws -> Wiretuner_Doc_V1_Change? {
        let role = ScriptingHost.shared.role(handle)
        guard role == nil || role == .owner || role == .editor else { throw IntentFailure.needsEditor(handle.title) }
        await handle.settle()
        return await handle.perform(ScriptLabelled(command, label: "Shortcut: \(label)")).value
    }
}

/// The intents' failures, each with a localized reason.
enum IntentFailure: Error, Equatable, CustomLocalizedStringResourceConvertible {
    case offline(String)
    case notFound(String)
    case needsEditor(String)
    case invalid(String)
    case failed(String)

    var localizedStringResource: LocalizedStringResource {
        switch self {
        case let .offline(name): "“\(name)” is not on this Mac. Connect to the internet to open it."
        case let .notFound(name): "No document named “\(name)” is in your library."
        case let .needsEditor(name): "Changing “\(name)” needs the editor role."
        case let .invalid(message): "\(message)"
        case let .failed(message): "\(message)"
        }
    }
}

/// A library document (`AppEntity`), searchable by name through the library cache.
struct DocumentEntity: AppEntity, Hashable, Sendable {
    static let typeDisplayRepresentation: TypeDisplayRepresentation = "WireTuner Document"
    static let defaultQuery = DocumentQuery()

    var id: String
    var name: String

    var displayRepresentation: DisplayRepresentation { DisplayRepresentation(title: "\(name)") }

    init(id: String, name: String) {
        self.id = id
        self.name = name
    }

    init(_ document: LibraryDocument) {
        self.init(id: document.id, name: document.name)
    }
}

/// Finds documents in the library cache: by id, by name, and the recents as suggestions.
struct DocumentQuery: EntityStringQuery {
    @MainActor
    static func documents() -> [LibraryDocument] {
        IntentsHost.shared.libraryDocuments().filter { !$0.isTrashed }
    }

    func entities(for identifiers: [String]) async throws -> [DocumentEntity] {
        await MainActor.run { Self.documents().filter { identifiers.contains($0.id) }.map(DocumentEntity.init) }
    }

    func entities(matching string: String) async throws -> [DocumentEntity] {
        await MainActor.run { Self.matching(string, in: Self.documents()) }
    }

    func suggestedEntities() async throws -> [DocumentEntity] {
        await MainActor.run { Self.documents().prefix(20).map(DocumentEntity.init) }
    }

    /// Documents whose name contains `string`, case- and diacritic-insensitively, by name.
    static func matching(_ string: String, in documents: [LibraryDocument]) -> [DocumentEntity] {
        documents.filter { $0.name.range(of: string, options: [.caseInsensitive, .diacriticInsensitive]) != nil }
            .sorted(by: LibraryCacheFile.byName).map(DocumentEntity.init)
    }
}

/// The export formats a shortcut can pick.
enum ExportFormatEntity: String, AppEnum {
    case pdf, svg, png, jpeg, tiff, eps

    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Export Format"
    static let caseDisplayRepresentations: [ExportFormatEntity: DisplayRepresentation] = [
        .pdf: "PDF", .svg: "SVG", .png: "PNG", .jpeg: "JPEG", .tiff: "TIFF", .eps: "EPS",
    ]

    var format: ExportFormat {
        switch self {
        case .pdf: .pdf
        case .svg: .svg
        case .png: .png
        case .jpeg: .jpeg
        case .tiff: .tiff
        case .eps: .eps
        }
    }
}

enum OrientationEntity: String, AppEnum {
    case portrait, landscape

    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Orientation"
    static let caseDisplayRepresentations: [OrientationEntity: DisplayRepresentation] = [.portrait: "Portrait", .landscape: "Landscape"]

    var orientation: PageGeometry.Orientation { self == .portrait ? .portrait : .landscape }
}

struct CreateDocumentIntent: AppIntent {
    static let title: LocalizedStringResource = "Create Document"
    static let description = IntentDescription("Creates a WireTuner document, from a template if you choose one, and opens it.")
    static let openAppWhenRun = true

    @Parameter(title: "Name", default: "Untitled") var name: String
    @Parameter(title: "Template") var template: DocumentEntity?

    static var parameterSummary: some ParameterSummary { Summary("Create \(\.$name) from \(\.$template)") }

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<DocumentEntity> {
        guard let handle = try await IntentsHost.shared.create(name, template?.id) else { throw IntentFailure.failed("The document could not be created.") }
        return .result(value: DocumentEntity(id: handle.id, name: handle.title))
    }
}

struct OpenDocumentIntent: AppIntent {
    static let title: LocalizedStringResource = "Open Document"
    static let description = IntentDescription("Opens a document from your WireTuner library.")
    static let openAppWhenRun = true

    @Parameter(title: "Document") var document: DocumentEntity

    static var parameterSummary: some ParameterSummary { Summary("Open \(\.$document)") }

    @MainActor
    func perform() async throws -> some IntentResult {
        _ = try IntentsHost.shared.handle(for: document)
        return .result()
    }
}

struct AddPagesIntent: AppIntent {
    static let title: LocalizedStringResource = "Add Pages"
    static let description = IntentDescription("Adds pages after the last page of a document.")
    static let openAppWhenRun = true

    @Parameter(title: "Document") var document: DocumentEntity
    @Parameter(title: "Count", default: 1, inclusiveRange: (1, 999)) var count: Int
    @Parameter(title: "Width (points)") var width: Double?
    @Parameter(title: "Height (points)") var height: Double?
    @Parameter(title: "Orientation") var orientation: OrientationEntity?
    @Parameter(title: "Master Page") var master: String?

    static var parameterSummary: some ParameterSummary { Summary("Add \(\.$count) pages to \(\.$document)") }

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<Int> {
        let host = IntentsHost.shared
        let handle = try host.handle(for: document)
        await handle.settle()
        let size = width.flatMap { width in height.map { Size(width: width, height: $0) } }
        let masterID = master.flatMap { name in PageList(handle.state).masters.first { $0.name == name || ScriptObjects.string($0.id) == name }?.id }
        if let master, masterID == nil { throw IntentFailure.invalid("No master page is named “\(master)”.") }
        do {
            let command = try ScriptObjects.addPages(count: count, size: size, orientation: orientation?.orientation, master: masterID)
            try await host.perform(command, label: "Add Pages", on: handle)
        } catch let error as ScriptObjects.InvalidValue {
            throw IntentFailure.invalid(error.description)
        }
        return .result(value: PageList(handle.state).pages.count)
    }
}

struct ExportDocumentIntent: AppIntent {
    static let title: LocalizedStringResource = "Export Document"
    static let description = IntentDescription("Exports a document in a format and returns the file.")
    static let openAppWhenRun = true

    @Parameter(title: "Document") var document: DocumentEntity
    @Parameter(title: "Format", default: .pdf) var format: ExportFormatEntity

    static var parameterSummary: some ParameterSummary { Summary("Export \(\.$document) as \(\.$format)") }

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<IntentFile> {
        let host = IntentsHost.shared
        let handle = try host.handle(for: document)
        await handle.settle()
        let folder = host.scratch()
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let url = folder.appending(path: "\(handle.title).\(format.format.fileExtension)")
        if let message = await ScriptingHost.shared.export(handle, format.format, url) { throw IntentFailure.failed(message) }
        return .result(value: IntentFile(fileURL: url, filename: url.lastPathComponent, type: format.format.utType))
    }
}

struct PrintDocumentIntent: AppIntent {
    static let title: LocalizedStringResource = "Print Document"
    static let description = IntentDescription("Prints a document.")
    static let openAppWhenRun = true

    @Parameter(title: "Document") var document: DocumentEntity
    @Parameter(title: "Print Preset") var preset: String?

    static var parameterSummary: some ParameterSummary { Summary("Print \(\.$document)") }

    @MainActor
    func perform() async throws -> some IntentResult {
        let handle = try IntentsHost.shared.handle(for: document)
        if let message = ScriptingHost.shared.print(handle, preset, "Shortcut: Print Document") { throw IntentFailure.failed(message) }
        return .result()
    }
}

struct FindReplaceTextIntent: AppIntent {
    static let title: LocalizedStringResource = "Find and Replace Text"
    static let description = IntentDescription("Replaces every match in a document's text and returns how many were replaced.")
    static let openAppWhenRun = true

    @Parameter(title: "Document") var document: DocumentEntity
    @Parameter(title: "Find") var find: String
    @Parameter(title: "Replace With", default: "") var replacement: String
    @Parameter(title: "Whole Word", default: false) var wholeWord: Bool
    @Parameter(title: "Match Case", default: false) var matchCase: Bool

    static var parameterSummary: some ParameterSummary { Summary("Replace \(\.$find) with \(\.$replacement) in \(\.$document)") }

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<Int> {
        let host = IntentsHost.shared
        let handle = try host.handle(for: document)
        await handle.settle()
        guard let replace = ScriptObjects.findAndReplace(find, with: replacement, wholeWord: wholeWord, matchCase: matchCase, in: handle.state) else {
            return .result(value: 0)
        }
        try await host.perform(replace.command, label: "Find and Replace Text", on: handle)
        return .result(value: replace.count)
    }
}

struct ShareLinkIntent: AppIntent {
    static let title: LocalizedStringResource = "Share Link"
    static let description = IntentDescription("Makes a view link to a document and returns it. Needs a connection.")

    @Parameter(title: "Document") var document: DocumentEntity

    static var parameterSummary: some ParameterSummary { Summary("Share link to \(\.$document)") }

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<String> {
        guard ScriptingHost.shared.isOnline() else { throw IntentFailure.offline(document.name) }
        let handle = try IntentsHost.shared.handle(for: document)
        do {
            return .result(value: try await ScriptingHost.shared.shareLink(handle))
        } catch {
            throw IntentFailure.failed(ScriptFailure(error).message)
        }
    }
}

struct GetDocumentReportIntent: AppIntent {
    static let title: LocalizedStringResource = "Get Document Report"
    static let description = IntentDescription("Returns a text report of a document: pages, layers, objects, swatches, styles and fonts.")
    static let openAppWhenRun = true

    @Parameter(title: "Document") var document: DocumentEntity

    static var parameterSummary: some ParameterSummary { Summary("Get the report of \(\.$document)") }

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<IntentFile> {
        let host = IntentsHost.shared
        let handle = try host.handle(for: document)
        await handle.settle()
        let folder = host.scratch()
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let url = folder.appending(path: "\(handle.title) Report.txt")
        try ScriptObjects.report(name: handle.title, state: handle.state).write(to: url, atomically: true, encoding: .utf8)
        return .result(value: IntentFile(fileURL: url, filename: url.lastPathComponent, type: .plainText))
    }
}

/// The phrases Siri and Spotlight offer.
struct WireTunerShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(intent: CreateDocumentIntent(), phrases: ["Create a \(.applicationName) document"], shortTitle: "Create Document", systemImageName: "doc.badge.plus")
        AppShortcut(intent: OpenDocumentIntent(), phrases: ["Open \(\.$document) in \(.applicationName)"], shortTitle: "Open Document", systemImageName: "doc")
    }
}
