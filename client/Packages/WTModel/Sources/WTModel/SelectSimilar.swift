import WTCRDT
import WTGeometry
import WTProto

/// menu:Edit[Select > Similar] (OBJ-042, selecting.adoc "Select Similar"): with one object
/// selected, every object on the current page whose fill, stroke or both are exactly the selected
/// object's.  It runs OBJ-022's `AttributeQuery` scoped to the current page (the document on an
/// unpaged document) with exact register equality: a swatch reference equals the same reference,
/// and a literal colour equals the same literal, not a swatch that resolves to it.  Objects on
/// hidden, locked or Guides layers are never found (the query's rule), nor are locked objects or
/// members of locked groups.  Nothing is written to the document.
public enum SelectSimilar {
    /// The submenu's items.  *Shape* is offered only when a `ShapeClassifying` is installed
    /// (IMG-030's bundled classifier); without one it is not built into the menu.
    public enum Attribute: String, Hashable, Sendable, CaseIterable {
        case fill, stroke, fillAndStroke, shape

        /// The menu item's title.
        public var title: String {
            switch self {
            case .fill: "Fill"
            case .stroke: "Stroke"
            case .fillAndStroke: "Fill and Stroke"
            case .shape: "Shape"
            }
        }
    }

    /// The submenu's items for a Mac with or without the shape classifier.
    public static func items(classifier: (any ShapeClassifying)?) -> [Attribute] {
        classifier == nil ? [.fill, .stroke, .fillAndStroke] : Attribute.allCases
    }

    /// The object the commands compare with: the selection's only object, or nil (no selection,
    /// several objects, or something that is not an object), which disables the commands.
    public static func sample(_ selection: [OpID], in state: EngineState) -> OpID? {
        guard selection.count == 1, Objects.isObject(selection[0], in: state) else { return nil }
        return selection[0]
    }

    /// What a command selects and what the status bar reports.
    public struct Outcome: Hashable, Sendable {
        /// The new selection, in stacking order (the previous selection first when adding).
        public var selection: [OpID]
        /// How many objects the command found, the sample included.
        public var found: Int

        /// The status-bar message: "3 objects selected".
        public var status: String { found == 1 ? "1 object selected" : "\(found) objects selected" }
    }

    /// The command: nil when disabled.  `page` is the window's current page (nil on an unpaged
    /// document); `adding` is kbd:[Shift], which adds the found objects to `selection` instead of
    /// replacing it.  `bounds` is the scene's pasteboard bounds when the caller has them.
    public static func run(_ attribute: Attribute, selection: [OpID], page: OpID?, adding: Bool = false,
                           classifier: (any ShapeClassifying)? = nil, in state: EngineState,
                           bounds: ((OpID) -> Rect?)? = nil) -> Outcome? {
        guard let sample = sample(selection, in: state), let candidates = candidates(page: page, in: state, bounds: bounds) else { return nil }
        let matches: (OpID) -> Bool
        switch attribute {
        case .shape:
            guard let classifier, let kind = classifier.shapeClass(of: sample, in: state) else { return nil }
            matches = { classifier.shapeClass(of: $0, in: state) == kind }
        default:
            guard let reference = Look(sample, in: state) else { return nil }
            matches = { node in
                guard let look = Look(node, in: state) else { return false }
                switch attribute {
                case .fill: return look.fills == reference.fills
                case .stroke: return look.strokes == reference.strokes
                default: return look == reference
                }
            }
        }
        var found = candidates.filter { $0 == sample || matches($0) }
        if !found.contains(sample) { found = Objects.stackingOrder(found + [sample], in: state) }
        let selected = adding ? selection + found.filter { !Set(selection).contains($0) } : found
        return Outcome(selection: selected, found: found.count)
    }
}

/// IMG-030's shape classifier as Select Similar sees it: the class of an object ("circle",
/// "rounded_rectangle", "group", ...), nil when it cannot say.  Nothing leaves the Mac.
public protocol ShapeClassifying: Sendable {
    func shapeClass(of node: OpID, in state: EngineState) -> String?
}
