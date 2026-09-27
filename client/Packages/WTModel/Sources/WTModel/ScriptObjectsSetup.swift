import Foundation
import WTCRDT
import WTProto

/// The document setup of the scripting object model (scripting.adoc, "What scripts can do in
/// version 1": "add and remove guides; set grid size and units"; DOC-026): the document's `units`
/// and `grid size`, and each page's and master page's guides.  Each set runs the command the
/// Document Setup, Grid and Guides sheets run.
extension ScriptObjects {
    /// Document property `property` (`units`, `gridSize`, `gridRelative`); nil for another.
    public static func documentGet(_ property: String, in state: EngineState) -> Any? {
        let settings = DocumentSettings(state)
        switch property {
        case "units": return Units(settings).name(of: settings.units).lowercased()
        case "gridSize": return settings.grid.size
        case "gridRelative": return settings.grid.relative
        default: return nil
        }
    }

    /// The command setting document property `property`.
    public static func documentSetting(_ property: String, to value: Any?, in state: EngineState) throws -> Edit {
        switch property {
        case "units":
            guard let unit = unit(named: try string(value), in: state) else { throw InvalidValue(property: property) }
            return Edit(SetUnits(unit))
        case "gridSize": return Edit(SetGrid(size: try points(value, property, in: 0.001...7200)))
        case "gridRelative": return Edit(SetGrid(relative: try bool(value)))
        default: throw ReadOnly(property: property, kind: "document")
        }
    }

    /// The unit a script names: a built-in unit's name or abbreviation, or a custom unit's name,
    /// any case.
    public static func unit(named name: String, in state: EngineState) -> LengthUnit? {
        let key = name.lowercased().trimmingCharacters(in: .whitespaces)
        let aliases: [String: LengthUnit] = ["pt": .points, "point": .points, "pc": .picas, "pica": .picas, "inch": .inches,
                                             "decimal inch": .decimalInches, "mm": .millimeters, "cm": .centimeters, "q": .kyus, "px": .pixels]
        if let unit = LengthUnit.standard.first(where: { $0.name.lowercased() == key || ($0.abbreviation == key && $0 != .decimalInches) }) ?? aliases[key] {
            return unit
        }
        return Units(DocumentSettings(state)).custom(named: key).map { LengthUnit.custom($0.id) }
    }

    // MARK: Guides

    /// The guides of page or master page `owner`, as the rulers show them (coincident guides
    /// are one); empty for another node.
    public static func guides(of owner: OpID, in state: EngineState) -> [PageGuide] {
        let pages = PageList(state)
        return pages.master(owner)?.guides ?? pages[owner]?.guides ?? []
    }

    /// Property `property` (`orientation`: "horizontal" or "vertical"; `position`: points from
    /// the page's top-left corner) of guide `guide` on `owner`.
    public static func guideGet(_ guide: OpID, on owner: OpID, _ property: String, in state: EngineState) -> Any? {
        guard let row = guides(of: owner, in: state).first(where: { $0.ids.contains(guide) }) else { return nil }
        switch property {
        case "orientation": return row.axis == .horizontal ? "horizontal" : "vertical"
        case "position": return row.position
        default: return nil
        }
    }

    /// `make new guide`: a guide on `owner` along `orientation` ("horizontal" or "vertical") at
    /// `position`.
    public static func addingGuide(on owner: OpID, orientation: String, at position: Any?) throws -> Edit {
        let axis: PageGuide.Axis
        switch orientation.lowercased() {
        case "horizontal": axis = .horizontal
        case "vertical": axis = .vertical
        default: throw InvalidValue(property: "orientation")
        }
        return Edit(AddGuides(on: [owner], axis: axis, at: [try points(position, "position", in: -PageGeometry.maximumSide...PageGeometry.maximumSide)]))
    }

    /// The command setting a guide's property: `position` moves it; its orientation is fixed.
    public static func guideSetting(_ guide: OpID, on owner: OpID, _ property: String, to value: Any?, in state: EngineState) throws -> Edit {
        guard let row = guides(of: owner, in: state).first(where: { $0.ids.contains(guide) }) else { throw NoSuchObject(element: "guide", index: 0) }
        guard property == "position" else { throw ReadOnly(property: property, kind: "guide") }
        return Edit(MoveGuide(on: owner, row.ids, to: try points(value, property, in: -PageGeometry.maximumSide...PageGeometry.maximumSide)))
    }

    /// `delete guide`: every coincident element the row stands for.
    public static func removingGuide(_ guide: OpID, on owner: OpID, in state: EngineState) throws -> Edit {
        guard let row = guides(of: owner, in: state).first(where: { $0.ids.contains(guide) }) else { throw NoSuchObject(element: "guide", index: 0) }
        return Edit(DeleteGuides(on: owner, row.ids))
    }
}
