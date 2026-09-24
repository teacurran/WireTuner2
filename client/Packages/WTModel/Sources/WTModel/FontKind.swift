import WTCRDT
import WTGeometry
import WTProto

// FONT-002: the document kind, glyph-canvas space and canvas membership (typeface-documents.adoc,
// "Data model", "Read-time normalizations" and "Client").

/// What kind of document this is (`SettingsProps.document_kind`, ATOMIC).  It decides the window
/// layout, the ruler units and the menus; it never changes what is stored.
public enum DocumentKind: Hashable, Sendable, CaseIterable {
    case singlePage
    case multiPage
    case typeface

    /// The kind as stored: unset (every document made before the kind existed) reads as
    /// multi-page.
    public init(_ state: EngineState) {
        // One register read, not the whole settings node: the canvas rules ask per object.
        let bytes = state.store.register(WellKnown.settings, FontFields.documentKind)?.value ?? []
        self.init(stored: (try? Wiretuner_Doc_V1_SettingsProps(serializedBytes: bytes))?.documentKind ?? .unspecified)
    }

    public init(stored: Wiretuner_Doc_V1_DocumentKind) {
        switch stored {
        case .illustrationSinglePage: self = .singlePage
        case .typeface: self = .typeface
        default: self = .multiPage
        }
    }

    /// The stored enum value.
    public var stored: Wiretuner_Doc_V1_DocumentKind {
        switch self {
        case .singlePage: .illustrationSinglePage
        case .multiPage: .illustrationMultiPage
        case .typeface: .typeface
        }
    }

    /// The kind the window lays out for: a single-page document with more than one live page
    /// reads as multi-page (the next conversion writes the truth; the document is never refused).
    public static func layout(_ state: EngineState) -> DocumentKind {
        let kind = DocumentKind(state)
        guard kind == .singlePage, livePageCount(state) > 1 else { return kind }
        return .multiPage
    }

    /// The live pages under 0:2.
    static func livePageCount(_ state: EngineState) -> Int {
        state.liveChildren(WellKnown.pages).filter { state.store.kind($0) == PageFields.kind }.count
    }

    /// The library's and title bar's name for the kind.
    public var title: String {
        switch self {
        case .singlePage: "Single-page illustration"
        case .multiPage: "Multi-page illustration"
        case .typeface: "Typeface"
        }
    }
}

/// The space a canvas measures in (typeface-documents.adoc, "Glyph-canvas space"): the
/// pasteboard in the document's units, or a glyph in font units.  Stored coordinates are y-down
/// in both; a glyph canvas presents *font y* = -stored y everywhere a number is shown, with the
/// baseline at stored y = 0.  Points, transforms and bounds in WTGeometry never see the flip.
public enum CanvasSpace: Hashable, Sendable {
    /// The main pasteboard, shown in `units`.
    case pasteboard(LengthUnit)
    /// A glyph canvas of a font with `upm` units per em.
    case glyph(upm: Double)

    /// The y a field or ruler shows for stored `y`.
    public func displayY(_ y: Double) -> Double {
        switch self {
        case .pasteboard: y
        case .glyph: y == 0 ? 0 : -y
        }
    }

    /// The stored y for a displayed `y`.
    public func storedY(_ y: Double) -> Double {
        displayY(y)
    }

    /// The displayed point for a stored one.
    public func displayPoint(_ point: Point) -> Point {
        Point(x: point.x, y: displayY(point.y))
    }

    /// The Units pop-up's label.
    public var unitLabel: String {
        switch self {
        case .pasteboard(let unit): unit.name
        case .glyph: "Font units"
        }
    }

    /// Whether the Units pop-up is enabled (it is fixed on a glyph canvas).
    public var unitsEditable: Bool {
        if case .pasteboard = self { return true }
        return false
    }

    /// The default grid spacing: 10 font units on a glyph canvas.
    public var defaultGridSize: Double {
        switch self {
        case .pasteboard: GridSettings.defaultSize
        case .glyph: 10
        }
    }

    /// The space of `canvas` (nil: the pasteboard) in `state`.
    public static func of(_ canvas: OpID?, in state: EngineState) -> CanvasSpace {
        if let canvas, state.store.kind(canvas) == GlyphFields.kind {
            return .glyph(upm: Double(FontInfo(state).metrics.upm))
        }
        return .pasteboard(DocumentSettings(state).units)
    }
}

/// Which canvas an object belongs to (`CommonProps.canvas`), with the typeface read rules: a
/// canvas naming a deleted glyph reads as unset in a typeface document (the objects appear on the
/// Sketches pasteboard, and *Restore glyph* re-attaches them); objects on a glyph in a document
/// whose kind is not typeface are hidden with their glyph; objects on a deleted master are not
/// drawn anywhere (master-pages.adoc).
public enum CanvasMembership {
    /// Where a top-level object is drawn.
    public enum Placement: Hashable, Sendable {
        /// On the main pasteboard.
        case pasteboard
        /// On the canvas of the master page or glyph `id`.
        case canvas(OpID)
        /// Nowhere: its glyph or master is hidden or deleted.
        case hidden
    }

    /// Where an object whose common props are `common` is drawn.
    public static func placement(_ common: Wiretuner_Doc_V1_CommonProps, in state: EngineState) -> Placement {
        guard common.hasCanvas, common.canvas.hasID else { return .pasteboard }
        let canvas = OpID(common.canvas.id)
        let kind = state.store.kind(canvas)
        if kind == GlyphFields.kind {
            guard DocumentKind(state) == .typeface else { return .hidden }
            return state.isLive(canvas) && state.store.placement(canvas)?.parent == WellKnown.glyphs ? .canvas(canvas) : .pasteboard
        }
        if kind == MasterPageFields.kind {
            return state.isLive(canvas) ? .canvas(canvas) : .hidden
        }
        // A canvas naming nothing drawable reads as unset (REF_FALLBACK_UNSET).
        return .pasteboard
    }

    /// Where `node` is drawn (`.pasteboard` for a node without common props).
    public static func placement(of node: OpID, in state: EngineState) -> Placement {
        NodeValues.common(state.props(node)).map { placement($0, in: state) } ?? .pasteboard
    }

    /// Whether an object with `common` is drawn on `canvas` (nil: the main pasteboard).  Group
    /// members carry no canvas and pass for every canvas; the top-level test is the builder's.
    public static func draws(_ common: Wiretuner_Doc_V1_CommonProps, on canvas: OpID?, in state: EngineState) -> Bool {
        guard common.hasCanvas else { return true }
        switch placement(common, in: state) {
        case .pasteboard: return canvas == nil
        case .canvas(let id): return canvas == id
        case .hidden: return false
        }
    }

    /// Whether top-level `node` belongs to `canvas` (nil: the main pasteboard).
    public static func belongs(_ node: OpID, to canvas: OpID?, in state: EngineState) -> Bool {
        switch placement(of: node, in: state) {
        case .pasteboard: canvas == nil
        case .canvas(let id): canvas == id
        case .hidden: false
        }
    }
}
