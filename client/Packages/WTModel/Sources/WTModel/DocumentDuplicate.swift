import WTCRDT

/// menu:File[Duplicate] (saving.adoc, "Duplicating a document"; IO-004): the document's live state
/// at the moment of duplicating, re-issued into a new document as fresh ops from the new store's
/// replica through `PackageReissue` -- the same path a package import takes -- so the copy shares
/// no OpId with the original, starts with no history, and takes none of the changes the original
/// receives afterwards (the plan reads a copy of the state).
public enum DocumentDuplicate {
    /// The label of the copy's changes and of its one undo step.
    public static let label = "Duplicate"

    /// The copy's name: "<name> copy".
    public static func name(for title: String) -> String { "\(title) copy" }

    /// The re-issue of `state` (captured now).
    public static func plan(_ state: EngineState) throws -> PackageReissue {
        try PackageReissue(state)
    }
}

/// One change of a duplicate: a `ReissueChunk` labelled "Duplicate".
public struct DuplicateChunk: Command {
    public let chunk: ReissueChunk

    public init(_ plan: PackageReissue) {
        chunk = plan.nextChunk()
    }

    public var label: String { DocumentDuplicate.label }

    public func execute(_ builder: inout ChangeBuilder, state: EngineState) throws {
        try chunk.execute(&builder, state: state)
    }
}
