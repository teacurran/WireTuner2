import WTCRDT
import WTModel
import WTRender

/// The stroke and fill wells (toolbars.adoc, "Colors section").
struct WellColors: Equatable, Sendable {
    var stroke: Paint
    var fill: Paint

    /// Black stroke, white fill: *Default* (default-attributes.adoc).
    static let standard = WellColors(stroke: .solid(Color(white: 0)), fill: .solid(Color(white: 1)))

    /// The first selected item's colours; nil when it paints with neither (an image, text).
    static func of(_ item: DisplayItem) -> WellColors? {
        switch item {
        case let .fill(fill): WellColors(stroke: .none, fill: fill.paint)
        case let .stroke(stroke): WellColors(stroke: stroke.paint, fill: .none)
        case let .path(path): WellColors(stroke: path.appearance.strokes.first?.paint ?? .none, fill: path.appearance.fills.first?.paint ?? .none)
        case let .group(group): group.children.first.flatMap(of)
        case .image, .text: nil
        }
    }
}

extension WellColors {
    /// The document's default stroke and fill (default-attributes.adoc; OBJ-037): the topmost basic
    /// stroke and fill of what a new object gets, resolved in `state` (*None* where a list has no
    /// basic element), with the colours as choices.
    static func defaults(in state: EngineState) -> (wells: WellColors, choices: (fill: DocumentDefaults.ColorChoice, stroke: DocumentDefaults.ColorChoice)) {
        let choices = DocumentDefaults.colors(of: DocumentDefaults.appearance(in: state))
        let resolver = SwatchList(state).resolver
        func paint(_ choice: DocumentDefaults.ColorChoice) -> Paint {
            guard case .color(let ref) = choice, let color = resolver.color(ref) else { return .none }
            return .solid(color)
        }
        return (WellColors(stroke: paint(choices.stroke), fill: paint(choices.fill)), choices)
    }
}

/// A current colour (applying-color.adoc, "The color wells"): the choice new objects get and the
/// paint its well shows.
struct CurrentColor: Equatable, Sendable {
    var choice: DocumentDefaults.ColorChoice
    var paint: Paint

    init(choice: DocumentDefaults.ColorChoice, paint: Paint) {
        self.choice = choice
        self.paint = paint
    }

    /// The paint a well shows, as a current colour: `choice` when it is known (the document
    /// default's own reference), else the paint as an unnamed colour.
    init(_ paint: Paint, choice: DocumentDefaults.ColorChoice?) {
        self.paint = paint
        self.choice = choice ?? paint.color.map { .color(ColorResolver.inline($0)) } ?? .noColor
    }
}
