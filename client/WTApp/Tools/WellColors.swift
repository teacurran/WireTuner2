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
