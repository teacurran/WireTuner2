import WTCRDT
import WTGeometry
import WTProto

// PRINT-011: the document's single output area (printing/output-area.adoc, "Data model", "Merge
// semantics").  `SettingsProps.output_area` (30) is one ATOMIC register on the settings node: define,
// move, resize and remove each write it whole, and remove writes it unset.

/// The output area as the document holds it, read with the page's normalizations.
public enum OutputArea {
    /// `SettingsProps.output_area`.
    public static let field = RegisterPath([SettingsFields.kind, 30])

    /// The pasteboard's limits: an area wholly outside them is clamped to them.
    public static let pasteboard = Rect(x: 0, y: 0, width: PageEditing.pasteboardSide, height: PageEditing.pasteboardSide)

    /// The document's output area, nil when unset.  A rectangle with zero or negative width or height
    /// (or a non-finite value) reads as unset; one wholly outside the pasteboard is clamped onto it.
    public static func read(_ state: EngineState) -> Rect? {
        let settings = state.props(WellKnown.settings).settings
        guard settings.hasOutputArea else { return nil }
        return normalized(settings.outputArea)
    }

    static func normalized(_ stored: Wiretuner_Doc_V1_Rect) -> Rect? {
        let values = [stored.x, stored.y, stored.width, stored.height]
        guard values.allSatisfy(\.isFinite), stored.width > 0, stored.height > 0 else { return nil }
        let rect = Rect(x: stored.x, y: stored.y, width: stored.width, height: stored.height)
        guard !rect.intersects(pasteboard) else { return rect }
        let width = min(rect.width, pasteboard.width), height = min(rect.height, pasteboard.height)
        let x = min(max(rect.minX, pasteboard.minX), pasteboard.maxX - width)
        let y = min(max(rect.minY, pasteboard.minY), pasteboard.maxY - height)
        return Rect(x: x, y: y, width: width, height: height)
    }
}

/// Writes the output area register whole: a new or moved or resized rectangle, or nil to remove the
/// area.  One `SetFields` on the settings node, labelled by what the gesture did ("Define output
/// area", "Move output area", "Resize output area", "Remove output area").
public struct SetOutputArea: Command {
    public var area: Rect?
    public let label: String

    public enum Kind: String, Sendable {
        case define = "Define output area"
        case move = "Move output area"
        case resize = "Resize output area"
        case remove = "Remove output area"
    }

    public init(_ area: Rect?, kind: Kind? = nil) {
        self.area = area
        label = (kind ?? (area == nil ? .remove : .define)).rawValue
    }

    public func execute(_ builder: inout ChangeBuilder, state: EngineState) throws {
        guard let area else {
            builder.append(Ops.set(WellKnown.settings, [OutputArea.field], values: Wiretuner_Doc_V1_NodeProps()))
            return
        }
        guard [area.minX, area.minY, area.width, area.height].allSatisfy(\.isFinite), area.width > 0, area.height > 0 else {
            throw PrintSettingsError.invalidValue("output area")
        }
        builder.append(Ops.set(WellKnown.settings, [OutputArea.field], values: SettingsFields.values { $0.outputArea = ImportMapping.rect(area) }))
    }
}
