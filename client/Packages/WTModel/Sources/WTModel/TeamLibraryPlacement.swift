import WTCRDT
import WTGeometry
import WTProto

/// A symbol dragged from a team library folder of the Library panel onto the canvas (library.adoc,
/// "Team libraries"; LIB-016): the symbol is copied into this document's library with its
/// provenance -- or, when this document already holds a live copy from the same library, that copy
/// is used -- and an instance of it is placed with its origin at `point`, in one change "Place
/// Symbol “Star” from Marketing library".  The provenance is `CommonProps.library` (COLLAB-010),
/// which stands for the sketched `SymbolProps.source`.
public struct PlaceFromLibrary: Command {
    public var item: OpID
    public var library: LibrarySource
    public var point: Point
    public var layer: OpID?

    public init(_ item: OpID, from library: LibrarySource, at point: Point, layer: OpID? = nil) {
        self.item = item
        self.library = library
        self.point = point
        self.layer = layer
    }

    public var label: String {
        "Place Symbol \(Swatches.quoted(library.state.props(item).symbol.common.name)) from \(library.name) library"
    }

    public func execute(_ builder: inout ChangeBuilder, state: EngineState) throws {
        guard library.state.nodeKind(item) == .symbol, LibraryCopying.isItem(item, in: library.state) else { throw LibraryCopyError.notInLibrary(item) }
        guard point.isFinite else { throw ObjectEditError.invalidValue("point") }
        var copier = LibraryCopying(library: library, state: state)
        guard let symbol = try copier.copy(item, builder: &builder) else { throw LibraryCopyError.notInLibrary(item) }
        let parent = try PathEditing.ensureLayer(&builder, state: state, preferred: layer)
        let placement = AffineTransform.translation(x: point.x, y: point.y).concatenating(Objects.pasteboardTransform(ofSpace: parent, in: state).inverse)
        builder.append(Ops.create(parent: parent, position: try PathEditing.topPosition(in: parent, state: state),
                                  props: SymbolEditing.instanceProps(symbol, transform: placement)))
    }
}
