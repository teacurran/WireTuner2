import Foundation
import WTCRDT
import WTGeometry
import WTProto

/// New documents (DOC-019, creating-opening.adoc "Data model"): a document's history begins with
/// one change, labelled "Created" (built-in template) or "Created from <template>", that writes
/// the template's content.  It is part of the document, not something the user did, so it is not
/// an undo step.  The built-in template is one Letter page centred on the pasteboard with the
/// default swatches, styles and settings (`DocumentTemplate`); a library template is a copy of
/// the template document's state re-issued with fresh node ids (`PackageReissue`) -- pages,
/// masters, guides, styles, swatches, symbols, custom sizes and units, and any artwork -- in the
/// same one change, so none of the template's history comes along.
public enum DocumentCreation {
    /// Where a new document comes from.
    public enum Template: Sendable {
        /// The built-in template.
        case builtIn
        /// A template document's merged state (from its snapshot) and its name.
        case document(EngineState, name: String)
    }

    /// The pasteboard's side, 222 in (workspace.adoc, "The pasteboard").
    public static let pasteboardSide = 15_984.0

    /// The built-in template's page: Letter, centred on the pasteboard.
    public static let builtInPage = Rect(x: (pasteboardSide - 612) / 2, y: (pasteboardSide - 792) / 2, width: 612, height: 792)

    /// A new document's core for `replica`, holding only the initial change from `template`.
    public static func newDocument(from template: Template, replica: UInt64, now: Date = Date()) throws -> DocumentCore {
        var core = DocumentCore(state: EngineState(), replica: replica)
        _ = try core.perform(CreateDocument(template), recording: DocumentCore.Recording(limit: 1, now: now))
        return core
    }

    /// A client-generated document id: a UUIDv7 (RFC 9562) -- 48 bits of Unix milliseconds,
    /// version 7, the variant and 74 random bits -- which `DocumentService.Create` takes, so a
    /// document created offline keeps its id when it is created on the server.
    public static func newDocumentID(now: Date = Date(), random: [UInt8] = (0..<10).map { _ in UInt8.random(in: .min ... .max) }) -> String {
        let milliseconds = UInt64(max(now.timeIntervalSince1970, 0) * 1000)
        var bytes = [UInt8](repeating: 0, count: 16)
        for index in 0..<6 { bytes[index] = UInt8(truncatingIfNeeded: milliseconds >> (8 * UInt64(5 - index))) }
        let random = random + [UInt8](repeating: 0, count: max(0, 10 - random.count))
        bytes[6] = 0x70 | (random[0] & 0x0F)
        bytes[7] = random[1]
        bytes[8] = 0x80 | (random[2] & 0x3F)
        for index in 9..<16 { bytes[index] = random[index - 6] }
        let hex = bytes.map { ($0 < 16 ? "0" : "") + String($0, radix: 16) }.joined()
        let parts = [hex.prefix(8), hex.dropFirst(8).prefix(4), hex.dropFirst(12).prefix(4), hex.dropFirst(16).prefix(4), hex.dropFirst(20)]
        return parts.joined(separator: "-")
    }
}

/// The initial change of a new document (`DocumentCreation`): "Created" or "Created from
/// <template>".  On a document that already has content it appends nothing.
public struct CreateDocument: Command {
    public var template: DocumentCreation.Template

    public init(_ template: DocumentCreation.Template = .builtIn) {
        self.template = template
    }

    public var label: String {
        switch template {
        case .builtIn: "Created"
        case .document(_, let name): name.isEmpty ? "Created" : "Created from \(name)"
        }
    }

    public var recordsUndo: Bool { false }

    public func execute(_ builder: inout ChangeBuilder, state: EngineState) throws {
        guard [WellKnown.pages, WellKnown.masters, WellKnown.layers, WellKnown.swatches, WellKnown.symbols].allSatisfy({ state.store.children($0).isEmpty })
        else { return }
        switch template {
        case .builtIn:
            let page = DocumentCreation.builtInPage
            builder.append(Ops.create(parent: WellKnown.pages, position: try PathEditing.keys(between: nil, and: nil, count: 1)[0],
                                      props: PageFields.values {
                                          $0.origin = PageEditing.point(page.origin)
                                          $0.geometry = PageGeometry.letter.stored
                                      }))
            try DocumentTemplate().execute(&builder, state: state)
        case .document(let source, _):
            let plan = try PackageReissue(source)
            while !plan.isFinished {
                try plan.nextChunk().execute(&builder, state: state)
            }
        }
    }
}
