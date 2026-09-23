import WTCRDT
import WTProto

extension RegisterPath {
    /// The path of the register `fields` below this one.
    func appending(_ fields: [UInt32]) -> RegisterPath {
        fields.reduce(self) { $0.child($1) }
    }
}

/// The live kind of a stack element, normalized as the stack reads it
/// (attribute-stack.adoc, "Read-time normalizations"): an unset or unknown fill or stroke kind
/// reads as Basic.
public enum AttributeKind: Hashable, Sendable {
    case fill(Wiretuner_Doc_V1_FillKind)
    case stroke(Wiretuner_Doc_V1_StrokeKind)
    case effect(Wiretuner_Doc_V1_EffectKind)

    static func fill(normalizing kind: Wiretuner_Doc_V1_FillKind) -> AttributeKind {
        switch kind {
        case .unspecified, .UNRECOGNIZED: .fill(.basic)
        default: .fill(kind)
        }
    }

    static func stroke(normalizing kind: Wiretuner_Doc_V1_StrokeKind) -> AttributeKind {
        switch kind {
        case .unspecified, .UNRECOGNIZED: .stroke(.basic)
        default: .stroke(kind)
        }
    }
}

/// One row of a stack as the Object panel reads it: the row, its visibility, its normalized kind
/// and the stored element.
public struct AttributeEntry: Hashable, Sendable {
    public var row: AppearanceRow
    public var hidden: Bool
    public var kind: AttributeKind
    public var fill: Wiretuner_Doc_V1_Fill
    public var stroke: Wiretuner_Doc_V1_Stroke
    public var effect: Wiretuner_Doc_V1_Effect

    /// The row's short description: "Basic, 2 pt", "Gradient, Linear", "Lens, Transparency".
    public var summary: String { AttributeNames.summary(self) }

    /// The entry of `row` on `node` (an empty element when it is not stored).
    static func read(_ node: OpID, _ row: AppearanceRow, owner: StackOwner, state: EngineState) -> AttributeEntry {
        let appearance = StackOwner.appearance(node, in: state) ?? Wiretuner_Doc_V1_AppearanceProps()
        return read(row, in: appearance)
    }

    static func read(_ row: AppearanceRow, in appearance: Wiretuner_Doc_V1_AppearanceProps) -> AttributeEntry {
        let fill = appearance.fills.first { OpID(element: $0.id) == row.element } ?? Wiretuner_Doc_V1_Fill()
        let stroke = appearance.strokes.first { OpID(element: $0.id) == row.element } ?? Wiretuner_Doc_V1_Stroke()
        let effect = appearance.effects.first { OpID(element: $0.id) == row.element } ?? Wiretuner_Doc_V1_Effect()
        switch row.list {
        case .fills:
            return AttributeEntry(row: row, hidden: fill.hidden, kind: .fill(normalizing: fill.settings.kind), fill: fill,
                                  stroke: Wiretuner_Doc_V1_Stroke(), effect: Wiretuner_Doc_V1_Effect())
        case .strokes:
            return AttributeEntry(row: row, hidden: stroke.hidden, kind: .stroke(normalizing: stroke.settings.kind),
                                  fill: Wiretuner_Doc_V1_Fill(), stroke: stroke, effect: Wiretuner_Doc_V1_Effect())
        case .effects:
            return AttributeEntry(row: row, hidden: effect.hidden, kind: .effect(effect.settings.kind), fill: Wiretuner_Doc_V1_Fill(),
                                  stroke: Wiretuner_Doc_V1_Stroke(), effect: effect)
        }
    }
}

extension AppearanceEditing {
    /// Every live row of `node`'s stack with its stored element, bottom first (ATTR-002's
    /// interleaved read-out).  The settings node reads the document's default attributes.
    public static func entries(_ node: OpID, in state: EngineState) -> [AttributeEntry] {
        guard let appearance = StackOwner.appearance(node, in: state) else { return [] }
        return stack(node, in: state).map { AttributeEntry.read($0, in: appearance) }
    }
}

/// The paths of the editable registers of a fill's or stroke's `settings` message, relative to
/// it (appearance.proto, stroke.proto, fill.proto).
public enum AttributeFields {
    public static let kind: [UInt32] = [1]

    public enum Basic {
        public static let color: [UInt32] = [2, 1]
        public static let width: [UInt32] = [2, 2]
        public static let cap: [UInt32] = [2, 3]
        public static let join: [UInt32] = [2, 4]
        public static let miterLimit: [UInt32] = [2, 5]
        public static let dash: [UInt32] = [2, 6]
        public static let startArrowhead: [UInt32] = [2, 7]
        public static let endArrowhead: [UInt32] = [2, 8]
        public static let overprint: [UInt32] = [2, 9]
        /// `BasicFill.overprint`.
        public static let fillOverprint: [UInt32] = [2, 2]
    }

    public enum Brush {
        public static let brush: [UInt32] = [3, 1]
        public static let widthPercent: [UInt32] = [3, 2]
        public static let color: [UInt32] = [3, 3]
        public static let seed: [UInt32] = [3, 4]
    }

    public enum Calligraphic {
        public static let color: [UInt32] = [4, 1]
        public static let width: [UInt32] = [4, 2]
        public static let height: [UInt32] = [4, 3]
        public static let angle: [UInt32] = [4, 4]
        public static let nib: [UInt32] = [4, 5]
    }

    public enum CustomStroke {
        public static let pattern: [UInt32] = [5, 1]
        public static let color: [UInt32] = [5, 2]
        public static let width: [UInt32] = [5, 3]
        public static let length: [UInt32] = [5, 4]
        public static let spacing: [UInt32] = [5, 5]
    }

    public enum PatternStroke {
        public static let color: [UInt32] = [6, 1]
        public static let width: [UInt32] = [6, 2]
        public static let bitmap: [UInt32] = [6, 3]
    }

    public enum Lens {
        public static let type: [UInt32] = [4, 1]
        public static let color: [UInt32] = [4, 2]
        public static let amount: [UInt32] = [4, 3]
        public static let magnification: [UInt32] = [4, 4]
        public static let centerpointShown: [UInt32] = [4, 5]
        public static let centerpoint: [UInt32] = [4, 6]
        public static let objectsOnly: [UInt32] = [4, 7]
        public static let snapshot: [UInt32] = [4, 8]
        public static let snapshotContents: [UInt32] = [4, 9]
    }

    public enum CustomFill {
        public static let pattern: [UInt32] = [5, 1]
        public static let color: [UInt32] = [5, 2]
        public static let color2: [UInt32] = [5, 3]
        public static let width: [UInt32] = [5, 4]
        public static let height: [UInt32] = [5, 5]
        public static let radius: [UInt32] = [5, 6]
        public static let side: [UInt32] = [5, 7]
        public static let spacing: [UInt32] = [5, 8]
        public static let angle: [UInt32] = [5, 9]
        public static let angle2: [UInt32] = [5, 10]
        public static let whiteness: [UInt32] = [5, 11]
        public static let count: [UInt32] = [5, 12]
        public static let seed: [UInt32] = [5, 13]
        public static let overprint: [UInt32] = [5, 14]
    }

    public enum PatternFill {
        public static let color: [UInt32] = [6, 1]
        public static let bitmap: [UInt32] = [6, 2]
        public static let overprint: [UInt32] = [6, 3]
    }

    public enum Textured {
        public static let texture: [UInt32] = [7, 1]
        public static let color: [UInt32] = [7, 2]
        public static let overprint: [UInt32] = [7, 3]
    }

    public enum Tiled {
        public static let tile: [UInt32] = [8, 1]
        public static let angle: [UInt32] = [8, 2]
        public static let scaleX: [UInt32] = [8, 3]
        public static let scaleY: [UInt32] = [8, 4]
        public static let offset: [UInt32] = [8, 5]
        public static let overprint: [UInt32] = [8, 6]
    }

    /// The colour register of the entry's live kind, or nil for a kind without one (Gradient,
    /// Tiled, effects).
    public static func colorPath(_ entry: AttributeEntry) -> [UInt32]? {
        switch entry.kind {
        case .fill(.lens): Lens.color
        case .fill(.custom): CustomFill.color
        case .fill(.pattern): PatternFill.color
        case .fill(.textured): Textured.color
        case .fill(.gradient), .fill(.tiled), .effect: nil
        case .fill: Basic.color
        case .stroke(.brush): Brush.color
        case .stroke(.calligraphic): Calligraphic.color
        case .stroke(.custom): CustomStroke.color
        case .stroke(.pattern): PatternStroke.color
        case .stroke: Basic.color
        }
    }

    /// The colour of the entry's live kind, or nil for a kind without one.
    public static func color(_ entry: AttributeEntry) -> Wiretuner_Doc_V1_ColorRef? {
        switch entry.kind {
        case .fill(.lens): entry.fill.settings.lens.color
        case .fill(.custom): entry.fill.settings.custom.color
        case .fill(.pattern): entry.fill.settings.pattern.color
        case .fill(.textured): entry.fill.settings.textured.color
        case .fill(.gradient), .fill(.tiled), .effect: nil
        case .fill: entry.fill.settings.basic.color
        case .stroke(.brush): entry.stroke.settings.brush.color
        case .stroke(.calligraphic): entry.stroke.settings.calligraphic.color
        case .stroke(.custom): entry.stroke.settings.custom.color
        case .stroke(.pattern): entry.stroke.settings.pattern.color
        case .stroke: entry.stroke.settings.basic.color
        }
    }

    /// The width of the entry's live stroke kind in points (a brush's is its percentage of
    /// 1 pt); nil for fills and effects.
    public static func width(_ entry: AttributeEntry) -> Double? {
        switch entry.kind {
        case .stroke(.brush): entry.stroke.settings.brush.widthPercent / 100
        case .stroke(.calligraphic): max(entry.stroke.settings.calligraphic.width, entry.stroke.settings.calligraphic.height)
        case .stroke(.custom): entry.stroke.settings.custom.width
        case .stroke(.pattern): entry.stroke.settings.pattern.width
        case .stroke: entry.stroke.settings.basic.width
        case .fill, .effect: nil
        }
    }
}

/// A sparse fill or stroke `settings` message: the values a command writes at its paths.
public struct AttributeSettings: Hashable, Sendable {
    public var list: AppearanceList
    public var fill = Wiretuner_Doc_V1_FillSettings()
    public var stroke = Wiretuner_Doc_V1_StrokeSettings()

    public init(_ list: AppearanceList) {
        self.list = list
    }

    /// The settings as a sparse `NodeProps` element of `owner`'s stack.
    func values(_ owner: StackOwner) -> Wiretuner_Doc_V1_NodeProps {
        AppearanceEditing.values(owner) { stack in
            if list == .fills {
                var fill = Wiretuner_Doc_V1_Fill()
                fill.settings = self.fill
                stack.fills = [fill]
            } else {
                var stroke = Wiretuner_Doc_V1_Stroke()
                stroke.settings = self.stroke
                stack.strokes = [stroke]
            }
        }
    }

    /// Puts `color` at the colour register `path` (one of `AttributeFields`' colour paths).
    mutating func setColor(_ color: Wiretuner_Doc_V1_ColorRef, at path: [UInt32]) {
        switch (list, path) {
        case (.fills, AttributeFields.Lens.color): fill.lens.color = color
        case (.fills, AttributeFields.CustomFill.color): fill.custom.color = color
        case (.fills, AttributeFields.CustomFill.color2): fill.custom.color2 = color
        case (.fills, AttributeFields.PatternFill.color): fill.pattern.color = color
        case (.fills, AttributeFields.Textured.color): fill.textured.color = color
        case (.fills, _): fill.basic.color = color
        case (_, AttributeFields.Brush.color): stroke.brush.color = color
        case (_, AttributeFields.Calligraphic.color): stroke.calligraphic.color = color
        case (_, AttributeFields.CustomStroke.color): stroke.custom.color = color
        case (_, AttributeFields.PatternStroke.color): stroke.pattern.color = color
        default: stroke.basic.color = color
        }
    }
}

/// The names the Object panel shows for kinds and their options.
public enum AttributeNames {
    public static func fillKind(_ kind: Wiretuner_Doc_V1_FillKind) -> String {
        switch kind {
        case .gradient: "Gradient"
        case .lens: "Lens"
        case .custom: "Custom"
        case .pattern: "Pattern"
        case .textured: "Textured"
        case .tiled: "Tiled"
        default: "Basic"
        }
    }

    public static func strokeKind(_ kind: Wiretuner_Doc_V1_StrokeKind) -> String {
        switch kind {
        case .brush: "Brush"
        case .calligraphic: "Calligraphic"
        case .custom: "Custom"
        case .pattern: "Pattern"
        default: "Basic"
        }
    }

    public static let effectKinds: [(Wiretuner_Doc_V1_EffectKind, String)] = [
        (.bend, "Bend"), (.duet, "Duet"), (.expandPath, "Expand Path"), (.ragged, "Ragged"), (.sketch, "Sketch"),
        (.transform, "Transform"), (.bevelEmboss, "Bevel and Emboss"), (.blur, "Blur"), (.shadow, "Shadow"), (.sharpen, "Sharpen"),
        (.transparency, "Transparency"), (.corners, "Corners"), (.combine, "Combine"),
    ]

    public static func effectKind(_ kind: Wiretuner_Doc_V1_EffectKind) -> String {
        effectKinds.first { $0.0 == kind }?.1 ?? "Effect"
    }

    public static let customStrokePatterns: [(Wiretuner_Doc_V1_CustomStrokePattern, String)] = [
        (.arrow, "Arrow"), (.ball, "Ball"), (.braid, "Braid"), (.cartographer, "Cartographer"), (.checker, "Checker"), (.crepe, "Crepe"),
        (.diamond, "Diamond"), (.dot, "Dot"), (.heart, "Heart"), (.leftDiagonal, "Left Diagonal"), (.neon, "Neon"), (.rectangle, "Rectangle"),
        (.rightDiagonal, "Right Diagonal"), (.roman, "Roman"), (.snowflake, "Snowflake"), (.squiggle, "Squiggle"), (.star, "Star"),
        (.swirl, "Swirl"), (.teeth, "Teeth"), (.threeWaves, "Three Waves"), (.twoWaves, "Two Waves"), (.wedge, "Wedge"), (.zigzag, "ZigZag"),
    ]

    public static let customFillPatterns: [(Wiretuner_Doc_V1_CustomFillPattern, String)] = [
        (.blackWhiteNoise, "Black & White Noise"), (.bricks, "Bricks"), (.circles, "Circles"), (.hatch, "Hatch"), (.noise, "Noise"),
        (.randomGrass, "Random Grass"), (.randomLeaves, "Random Leaves"), (.squares, "Squares"), (.tigerTeeth, "Tiger Teeth"),
        (.topNoise, "Top Noise"),
    ]

    public static let textures: [(Wiretuner_Doc_V1_Texture, String)] = [
        (.burlap, "Burlap"), (.denim, "Denim"), (.gravel, "Gravel"), (.marble, "Marble"), (.mesh, "Mesh"), (.oak, "Oak"), (.sand, "Sand"),
        (.stucco, "Stucco"),
    ]

    public static let lensTypes: [(Wiretuner_Doc_V1_LensType, String)] = [
        (.transparency, "Transparency"), (.magnify, "Magnify"), (.invert, "Invert"), (.lighten, "Lighten"), (.darken, "Darken"),
        (.monochrome, "Monochrome"),
    ]

    public static let gradientTypes: [(Wiretuner_Doc_V1_GradientType, String)] = [
        (.linear, "Linear"), (.logarithmic, "Logarithmic"), (.radial, "Radial"), (.rectangle, "Rectangle"), (.contour, "Contour"),
        (.cone, "Cone"),
    ]

    static func name<T: Equatable>(_ value: T, in table: [(T, String)], default fallback: String) -> String {
        table.first { $0.0 == value }?.1 ?? fallback
    }

    /// A width in points for a row: "Hairline" for 0, else "2 pt".
    public static func points(_ width: Double) -> String {
        width == 0 ? "Hairline" : "\(width.formatted(.number.precision(.fractionLength(0...3)))) pt"
    }

    static func summary(_ entry: AttributeEntry) -> String {
        switch entry.kind {
        case .fill(let kind):
            let settings = entry.fill.settings
            switch kind {
            case .gradient: return "Gradient, \(name(settings.gradient.type, in: gradientTypes, default: "Linear"))"
            case .lens: return "Lens, \(name(settings.lens.type, in: lensTypes, default: "Transparency"))"
            case .custom: return "Custom, \(name(settings.custom.pattern, in: customFillPatterns, default: "Basic"))"
            case .textured: return "Textured, \(name(settings.textured.texture, in: textures, default: "Basic"))"
            case .pattern, .tiled: return fillKind(kind)
            default: return "Basic"
            }
        case .stroke(let kind):
            let settings = entry.stroke.settings
            switch kind {
            case .brush: return "Brush, \(settings.brush.widthPercent.formatted(.number.precision(.fractionLength(0...1))))%"
            case .custom: return "Custom, \(name(settings.custom.pattern, in: customStrokePatterns, default: "Basic"))"
            default: return "\(strokeKind(kind)), \(points(AttributeFields.width(entry) ?? 0))"
            }
        case .effect(let kind):
            return effectKind(kind)
        }
    }
}
