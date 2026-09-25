import Foundation
import WTCRDT

/// The opening change of every new document (swatches.adoc, "Default colors": the document
/// template of creating-opening.adoc): the protected default swatches White, Black and
/// Registration (`CreateDefaultSwatches`), the Normal graphic style (`CreateNormalGraphicStyle`,
/// styles.adoc) and the Normal Text paragraph style (`CreateNormalTextStyle`, text-styles.adoc).
/// It is part of the document, not something the user did, so it is not an undo step; on a
/// document that already has them it appends nothing.
public struct DocumentTemplate: Command {
    public init() {}

    public var label: String { CreateDefaultSwatches().label }
    public var recordsUndo: Bool { false }

    public func execute(_ builder: inout ChangeBuilder, state: EngineState) throws {
        try CreateDefaultSwatches().execute(&builder, state: state)
        try CreateNormalGraphicStyle().execute(&builder, state: state)
        try CreateNormalTextStyle().execute(&builder, state: state)
    }

    /// A new document's core for `replica`: an empty state with the template applied.
    public static func core(replica: UInt64, now: Date = Date()) -> DocumentCore {
        var core = DocumentCore(state: EngineState(), replica: replica)
        _ = try? core.perform(DocumentTemplate(), recording: DocumentCore.Recording(limit: 1, now: now))
        return core
    }
}
