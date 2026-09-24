import WTCRDT
import WTProto

/// Object names as the app shows them (names-notes.adoc, "Client"; OBJ-021): an object's own name
/// when it has one, else its kind's name.  The Layers panel, the Info toolbar and change labels
/// (`Move "Logo mark"`) read it.
extension NodeKind {
    /// The kind's name ("Path", "Rectangle", "Text").
    public var title: String {
        switch self {
        case .path: "Path"
        case .rect: "Rectangle"
        case .ellipse: "Ellipse"
        case .polygon: "Polygon"
        case .chart: "Chart"
        case .connector: "Connector"
        case .text: "Text"
        case .group: "Group"
        case .brush: "Brush"
        case .blend: "Blend"
        case .extrude: "Extrusion"
        case .layer: "Layer"
        case .symbol: "Symbol"
        case .instance: "Symbol Instance"
        case .placedFile: "Placed File"
        case .barcode: "Barcode"
        }
    }
}

extension EngineState {
    /// The object's name, nil when it has none (or is not an object with common props).
    public func name(of node: OpID) -> String? {
        guard let name = NodeValues.common(props(node))?.name, !name.isEmpty else { return nil }
        return name
    }

    /// The name if set, else the kind's name; "Object" for a kind WTModel does not know.
    public func displayName(of node: OpID) -> String {
        name(of: node) ?? nodeKind(node)?.title ?? "Object"
    }

    /// `verb` followed by the quoted name of the one object `nodes` holds when it is named
    /// (`Move "Logo mark"`); nil for several objects or an unnamed one, where the command's own
    /// label stands.
    public func namedLabel(_ verb: String, for nodes: [OpID]) -> String? {
        guard nodes.count == 1, let name = name(of: nodes[0]) else { return nil }
        return "\(verb) \"\(name)\""
    }
}

/// Appends a line to objects' notes without overwriting what is there (names-notes.adoc, "Notes
/// written by WireTuner"; the keep-both tagging helper): reads each note and writes
/// `note + "\n" + line` (just `line` on an empty note), cut to the 8,192-character limit.  A
/// concurrent edit of the note collides by OpId like any register.
public struct AppendNote: Command {
    public var nodes: [OpID]
    public var line: String

    public init(_ nodes: [OpID], line: String) {
        self.nodes = nodes
        self.line = line
    }

    public var label: String { "Add note" }

    /// The note after appending `line` to `note`.
    public static func appending(_ line: String, to note: String) -> String {
        String((note.isEmpty ? line : note + "\n" + line).prefix(8_192))
    }

    public func execute(_ builder: inout ChangeBuilder, state: EngineState) throws {
        guard !line.isEmpty else { throw ObjectEditError.invalidValue("line") }
        for node in nodes where Objects.isObject(node, in: state) {
            let kind = try Objects.kind(node, in: state)
            let note = NodeValues.common(state.props(node))?.note ?? ""
            let value = Self.appending(line, to: note)
            builder.append(Ops.set(node, [CommonFields.note(kind)], values: NodeValues.common(kind: kind) { $0.note = value }))
        }
    }
}
