import struct Foundation.Data
import WTCRDT
import WTProto
import WTRender

/// "Change stroke width" for one row, "Change stroke width of 3 objects" for several.
func fannedLabel(_ label: String, count: Int) -> String {
    count > 1 ? "\(label) of \(count) objects" : label
}

/// Hides or shows rows (the visibility checkbox): the element's `hidden` register on each node.
/// A hidden element keeps its settings and is skipped when the object is drawn.
public struct SetAppearanceHidden: Command {
    public var rows: [(node: OpID, row: AppearanceRow)]
    public var hidden: Bool

    public init(_ rows: [(node: OpID, row: AppearanceRow)], hidden: Bool) {
        self.rows = rows
        self.hidden = hidden
    }

    public var label: String {
        fannedLabel("\(hidden ? "Hide" : "Show") \(rows.first?.row.list.noun ?? "Fill")", count: rows.count)
    }

    public func execute(_ builder: inout ChangeBuilder, state: EngineState) throws {
        for (node, row) in rows {
            let owner = try AppearanceEditing.owner(node, row, in: state)
            let values = AppearanceEditing.values(owner) { stack in
                switch row.list {
                case .fills:
                    var fill = Wiretuner_Doc_V1_Fill()
                    fill.hidden = hidden
                    stack.fills = [fill]
                case .strokes:
                    var stroke = Wiretuner_Doc_V1_Stroke()
                    stroke.hidden = hidden
                    stack.strokes = [stroke]
                case .effects:
                    var effect = Wiretuner_Doc_V1_Effect()
                    effect.hidden = hidden
                    stack.effects = [effect]
                }
            }
            builder.append(Ops.set(node, [owner.sequence(row.list).element(row.element).child(2)], values: values))
        }
    }
}

/// Moves rows to `index` of their node's merged stack (0 = bottom), dragging a row in the
/// Attributes list: an `ElementMove` in the row's own list with a position between its new
/// neighbours, whatever lists they belong to (attribute-stack.adoc, "Client").  Labelled
/// "Reorder Attributes"; one change for every selected object.
public struct ReorderAttribute: Command {
    public var rows: [(node: OpID, row: AppearanceRow)]
    public var index: Int

    public init(_ rows: [(node: OpID, row: AppearanceRow)], to index: Int) {
        self.rows = rows
        self.index = index
    }

    public var label: String { "Reorder Attributes" }

    public func execute(_ builder: inout ChangeBuilder, state: EngineState) throws {
        for (node, row) in rows {
            let owner = try AppearanceEditing.owner(node, row, in: state)
            let order = AppearanceEditing.stack(node, in: state)
            let current = order.firstIndex(of: row)!
            let target = min(max(index, 0), order.count - 1)
            guard target != current else { continue }
            let key = try AppearanceEditing.key(at: target, of: node, moving: row, owner: owner, state: state)
            builder.append(Ops.elementMove(node, owner.sequence(row.list).element(row.element), position: key))
        }
    }
}

/// Edits registers of fill or stroke rows' `settings` (every option of every kind editor): the
/// registers at `fields` (paths relative to the settings message, `AttributeFields`) on each
/// row, from `settings`.  One change over every selected object.
public struct EditAttribute: Command {
    public var rows: [(node: OpID, row: AppearanceRow)]
    public var fields: [[UInt32]]
    public var settings: AttributeSettings
    public var baseLabel: String

    public init(_ rows: [(node: OpID, row: AppearanceRow)], label: String, fields: [[UInt32]], settings: AttributeSettings) {
        self.rows = rows
        self.baseLabel = label
        self.fields = fields
        self.settings = settings
    }

    /// Writes `fields` of fill rows from the settings `build` fills in.
    public static func fill(_ rows: [(node: OpID, row: AppearanceRow)], _ label: String, _ fields: [[UInt32]],
                            _ build: (inout Wiretuner_Doc_V1_FillSettings) -> Void) -> EditAttribute {
        var settings = AttributeSettings(.fills)
        build(&settings.fill)
        return EditAttribute(rows, label: label, fields: fields, settings: settings)
    }

    /// Writes `fields` of stroke rows from the settings `build` fills in.
    public static func stroke(_ rows: [(node: OpID, row: AppearanceRow)], _ label: String, _ fields: [[UInt32]],
                              _ build: (inout Wiretuner_Doc_V1_StrokeSettings) -> Void) -> EditAttribute {
        var settings = AttributeSettings(.strokes)
        build(&settings.stroke)
        return EditAttribute(rows, label: label, fields: fields, settings: settings)
    }

    /// Choosing a lens: `type` and, in the same change, *Centerpoint*, *Objects only* and
    /// *Snapshot* off (fill-attributes.adoc, "Lens type change vs. option toggle").
    public static func lensType(_ rows: [(node: OpID, row: AppearanceRow)], _ type: Wiretuner_Doc_V1_LensType) -> EditAttribute {
        fill(rows, "Change lens", [AttributeFields.Lens.type, AttributeFields.Lens.centerpointShown, AttributeFields.Lens.objectsOnly,
                                   AttributeFields.Lens.snapshot]) { $0.lens.type = type }
    }

    public var label: String { fannedLabel(baseLabel, count: rows.count) }

    public func execute(_ builder: inout ChangeBuilder, state: EngineState) throws {
        for (node, row) in rows {
            guard row.list == settings.list else { throw PathEditError.unknownPoint(row.element) }
            let owner = try AppearanceEditing.owner(node, row, in: state)
            let base = owner.sequence(row.list).element(row.element).child(row.list.settingsField)
            builder.append(Ops.set(node, fields.map { base.appending($0) }, values: settings.values(owner)))
        }
    }
}

/// Chooses the kind of fill or stroke rows (the *Fill type* and *Stroke type* pop-ups): the
/// `kind` register only, so the other kinds' settings stay and come back on switching back.  A
/// kind whose settings were never written is seeded in the same change -- the current colour and
/// width carried over, a fresh `seed` for Random Grass, Random Leaves and brushes, and the
/// kind's working defaults -- so it draws something the moment it is chosen.  Gradient fills are
/// chosen by the gradient commands (ATTR-024), which also write the ramp.
public struct SetAttributeKind: Command {
    public var rows: [(node: OpID, row: AppearanceRow)]
    public var fillKind: Wiretuner_Doc_V1_FillKind?
    public var strokeKind: Wiretuner_Doc_V1_StrokeKind?
    /// The bitmap a Pattern fill or stroke starts with.
    public var bitmap: [UInt8]

    public static let defaultBitmap = PatternBitmap.checker.rows

    public init(_ rows: [(node: OpID, row: AppearanceRow)], fill kind: Wiretuner_Doc_V1_FillKind, bitmap: [UInt8] = defaultBitmap) {
        self.rows = rows
        fillKind = kind
        self.bitmap = bitmap
    }

    public init(_ rows: [(node: OpID, row: AppearanceRow)], stroke kind: Wiretuner_Doc_V1_StrokeKind, bitmap: [UInt8] = defaultBitmap) {
        self.rows = rows
        strokeKind = kind
        self.bitmap = bitmap
    }

    public var label: String {
        fannedLabel(fillKind != nil ? "Change fill type" : "Change stroke type", count: rows.count)
    }

    public func execute(_ builder: inout ChangeBuilder, state: EngineState) throws {
        if fillKind == .gradient { throw ObjectEditError.invalidValue("kind") }
        for (node, row) in rows {
            let owner = try AppearanceEditing.owner(node, row, in: state)
            guard row.list == (fillKind != nil ? .fills : .strokes) else { throw PathEditError.unknownPoint(row.element) }
            let entry = AttributeEntry.read(node, row, owner: owner, state: state)
            var settings = AttributeSettings(row.list)
            var fields = [AttributeFields.kind]
            if let fillKind {
                settings.fill.kind = fillKind
                fields += seed(fill: fillKind, from: entry, into: &settings.fill)
            } else if let strokeKind {
                settings.stroke.kind = strokeKind
                fields += seed(stroke: strokeKind, from: entry, into: &settings.stroke)
            }
            let base = owner.sequence(row.list).element(row.element).child(3)
            builder.append(Ops.set(node, fields.map { base.appending($0) }, values: settings.values(owner)))
        }
    }

    /// The colour the new kind starts with: the current kind's, else black.
    private func color(_ entry: AttributeEntry) -> Wiretuner_Doc_V1_ColorRef {
        AttributeFields.color(entry).flatMap { $0.ref == nil ? nil : $0 } ?? Appearances.basicFill(red: 0, green: 0, blue: 0).settings.basic.color
    }

    private func seed(fill kind: Wiretuner_Doc_V1_FillKind, from entry: AttributeEntry, into settings: inout Wiretuner_Doc_V1_FillSettings) -> [[UInt32]] {
        let stored = entry.fill.settings
        let color = color(entry)
        switch kind {
        case .lens where stored.lens == Wiretuner_Doc_V1_LensFill():
            settings.lens.type = .transparency
            settings.lens.color = color
            settings.lens.amount = 50
            settings.lens.magnification = 2
            return [AttributeFields.Lens.type, AttributeFields.Lens.color, AttributeFields.Lens.amount, AttributeFields.Lens.magnification]
        case .custom where stored.custom == Wiretuner_Doc_V1_CustomFill():
            settings.custom.pattern = .circles
            settings.custom.color = color
            settings.custom.color2 = Appearances.basicFill(red: 1, green: 1, blue: 1).settings.basic.color
            settings.custom.whiteness = 50
            settings.custom.count = 100
            settings.custom.seed = UInt64.random(in: 1 ... .max)
            return [AttributeFields.CustomFill.pattern, AttributeFields.CustomFill.color, AttributeFields.CustomFill.color2,
                    AttributeFields.CustomFill.whiteness, AttributeFields.CustomFill.count, AttributeFields.CustomFill.seed]
        case .pattern where stored.pattern == Wiretuner_Doc_V1_PatternFill():
            settings.pattern.color = color
            settings.pattern.bitmap.rows = Data(bitmap)
            return [AttributeFields.PatternFill.color, AttributeFields.PatternFill.bitmap]
        case .textured where stored.textured == Wiretuner_Doc_V1_TexturedFill():
            settings.textured.texture = .burlap
            settings.textured.color = color
            return [AttributeFields.Textured.texture, AttributeFields.Textured.color]
        case .tiled where stored.tiled == Wiretuner_Doc_V1_TiledFill():
            settings.tiled.scaleX = 100
            settings.tiled.scaleY = 100
            return [AttributeFields.Tiled.scaleX, AttributeFields.Tiled.scaleY]
        default:
            return []
        }
    }

    private func seed(stroke kind: Wiretuner_Doc_V1_StrokeKind, from entry: AttributeEntry, into settings: inout Wiretuner_Doc_V1_StrokeSettings) -> [[UInt32]] {
        let stored = entry.stroke.settings
        let color = color(entry)
        let width = max(AttributeFields.width(entry) ?? 1, 1)
        switch kind {
        case .brush where stored.brush == Wiretuner_Doc_V1_BrushStroke():
            settings.brush.color = color
            settings.brush.widthPercent = 100
            settings.brush.seed = UInt64.random(in: 1 ... .max)
            return [AttributeFields.Brush.color, AttributeFields.Brush.widthPercent, AttributeFields.Brush.seed]
        case .calligraphic where stored.calligraphic == Wiretuner_Doc_V1_CalligraphicStroke():
            settings.calligraphic.color = color
            settings.calligraphic.width = width * 4
            settings.calligraphic.height = width
            settings.calligraphic.angle = 45
            return [AttributeFields.Calligraphic.color, AttributeFields.Calligraphic.width, AttributeFields.Calligraphic.height,
                    AttributeFields.Calligraphic.angle]
        case .custom where stored.custom == Wiretuner_Doc_V1_CustomStroke():
            settings.custom.pattern = .arrow
            settings.custom.color = color
            settings.custom.width = max(width, 6)
            return [AttributeFields.CustomStroke.pattern, AttributeFields.CustomStroke.color, AttributeFields.CustomStroke.width]
        case .pattern where stored.pattern == Wiretuner_Doc_V1_PatternStroke():
            settings.pattern.color = color
            settings.pattern.width = max(width, 4)
            settings.pattern.bitmap.rows = Data(bitmap)
            return [AttributeFields.PatternStroke.color, AttributeFields.PatternStroke.width, AttributeFields.PatternStroke.bitmap]
        case .basic where stored.basic == Wiretuner_Doc_V1_BasicStroke():
            settings.basic.color = color
            settings.basic.width = AttributeFields.width(entry) ?? 1
            return [AttributeFields.Basic.color, AttributeFields.Basic.width]
        default:
            return []
        }
    }
}
