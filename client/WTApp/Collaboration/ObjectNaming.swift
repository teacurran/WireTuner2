import WTCRDT
import WTModel
import WTProto

/// Objects named as the Object panel names them: the object's own name, else its kind
/// ("Rectangle", "Group").  The review sheet, the hover cards and the attribution flash use it.
enum ObjectNaming {
    static func name(of node: OpID, in state: EngineState) -> String {
        if node == WellKnown.settings { return "Document settings" }
        let props = state.props(node)
        if let name = common(props)?.name, !name.isEmpty { return name }
        return kindTitle(props)
    }

    /// The kind's title.
    static func kindTitle(_ props: Wiretuner_Doc_V1_NodeProps) -> String {
        switch props.kind {
        case .path?: "Path"
        case .rect?: "Rectangle"
        case .ellipse?: "Ellipse"
        case .polygon?: "Polygon"
        case .group?: "Group"
        case .layer?: "Layer"
        case .text?: "Text"
        case .image?: "Image"
        case .connector?: "Connector"
        default: "Object"
        }
    }

    /// The common props of the kinds that carry a name.
    static func common(_ props: Wiretuner_Doc_V1_NodeProps) -> Wiretuner_Doc_V1_CommonProps? {
        switch props.kind {
        case .path(let path)?: path.common
        case .rect(let rect)?: rect.common
        case .ellipse(let ellipse)?: ellipse.common
        case .polygon(let polygon)?: polygon.common
        case .group(let group)?: group.common
        case .layer(let layer)?: layer.common
        case .text(let text)?: text.common
        case .image(let image)?: image.common
        default: nil
        }
    }
}
