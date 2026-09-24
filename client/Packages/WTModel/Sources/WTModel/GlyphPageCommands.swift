import WTCRDT
import WTGeometry
import WTProto
import WTRender

// FONT-002: moving artwork between Sketches pages and glyph canvases (typeface-documents.adoc,
// "Bringing artwork into a glyph", "Conversion commands"): Convert Page to Glyph (move or copy,
// page height as the em or one point per unit), Copy Glyph to Page, and the page copies of
// Convert to illustration.  Stored space is y-down on both canvases, so "up stays up" is a
// translation (and, for *Page height is the em*, a uniform scale), never a flip.

/// How Convert Page to Glyph scales the page.
public enum PageToGlyphScaling: Hashable, Sendable {
    /// The page's height becomes the em; the baseline sits the descender's distance above the
    /// page's bottom edge.
    case pageHeightIsEm
    /// No scaling: the page's bottom-left corner becomes the glyph origin.
    case onePointPerUnit
}

/// menu:Glyph[Convert Page to Glyph…]: a glyph named `name` (encoding what the name stands for
/// unless `codepoints` are given) whose canvas receives the page's objects -- moved (`canvas` and
/// `transform` written) or copied -- mapped into glyph space, with the advance width the page's
/// scaled width, in one change "Convert page to glyph".  Undo of a move returns the objects to
/// the page with their original transforms.
public struct ConvertPageToGlyph: Command {
    public var page: OpID
    public var name: String
    public var codepoints: [UInt32]?
    public var scaling: PageToGlyphScaling
    public var move: Bool
    public var label: String { "Convert page to glyph" }

    public init(_ page: OpID, name: String, codepoints: [UInt32]? = nil, scaling: PageToGlyphScaling = .pageHeightIsEm, move: Bool = true) {
        self.page = page
        self.name = name
        self.codepoints = codepoints
        self.scaling = scaling
        self.move = move
    }

    /// Pasteboard → glyph space for `page`.
    static func mapping(_ page: Page, scaling: PageToGlyphScaling, font: FontInfo) -> (transform: AffineTransform, scale: Double) {
        let toBottomLeft = AffineTransform.translation(x: -page.origin.x, y: -(page.origin.y + page.geometry.height))
        switch scaling {
        case .onePointPerUnit:
            return (toBottomLeft, 1)
        case .pageHeightIsEm:
            let scale = Double(font.metrics.upm) / page.geometry.height
            return (toBottomLeft.concatenating(.scale(scale)).concatenating(.translation(x: 0, y: -font.metrics.descender)), scale)
        }
    }

    public func execute(_ builder: inout ChangeBuilder, state: EngineState) throws {
        let list = PageList(state)
        let source = try PageEditing.page(page, in: list)
        let index = GlyphIndex(state)
        guard GlyphNaming.isValid(name) else { throw GlyphEditError.invalidName(name) }
        guard !index.isNameTaken(name) else { throw GlyphEditError.nameTaken(name) }
        let scalars = codepoints ?? GlyphNaming.codepoint(of: name).map { [$0] } ?? []
        try scalars.forEach(GlyphEditing.validate(codepoint:))
        if let taken = scalars.first(where: { index.holder(of: $0) != nil }) { throw GlyphEditError.codepointTaken(taken) }
        let (mapping, scale) = Self.mapping(source, scaling: scaling, font: FontInfo(state))
        let width = (source.geometry.width * scale).rounded()
        try GlyphEditing.validate(width: width)
        let key = try GlyphEditing.keys(after: nil, count: 1, state: state)[0]
        let glyph = GlyphEditing.create(name: name, codepoints: scalars, kind: .base, advanceWidth: width, position: key, builder: &builder)
        for (object, _) in PageObjects.objects(on: source, in: state, pages: list) {
            try GlyphPageCopies.place(object, mapping: mapping, canvas: glyph, copy: !move, state: state, builder: &builder)
        }
    }
}

/// menu:Glyph[Copy Glyph to Page]: a new page one em square in Sketches holding a copy of the
/// glyph's artwork, `canvas` unset, one font unit per point, the ascender line at the page's top.
/// "Copy glyph to page".
public struct CopyGlyphToPage: Command {
    public var glyph: OpID
    public var label: String { "Copy glyph to page" }

    public init(_ glyph: OpID) {
        self.glyph = glyph
    }

    public func execute(_ builder: inout ChangeBuilder, state: EngineState) throws {
        let read = try GlyphEditing.glyph(glyph, in: GlyphIndex(state))
        try GlyphPageCopies.copy([read], state: state, builder: &builder)
    }
}

/// Page copies of glyph artwork.
enum GlyphPageCopies {
    /// Convert to illustration's *Copy every glyph to its own page*.
    static func copyAll(state: EngineState, builder: inout ChangeBuilder) throws {
        try copy(GlyphIndex(state).glyphs, state: state, builder: &builder)
    }

    /// One em-square page per glyph after the last page, laid out left to right, each with
    /// copies of its glyph's objects.
    static func copy(_ glyphs: [Glyph], state: EngineState, builder: inout ChangeBuilder) throws {
        guard !glyphs.isEmpty else { return }
        let font = FontInfo(state)
        let em = Double(font.metrics.upm)
        let list = PageList(state)
        let last = state.store.children(WellKnown.pages).last.flatMap { state.store.placement($0)?.position }
        let keys = try PathEditing.keys(between: last, and: nil, count: glyphs.count)
        var x = list.isSynthesized ? 0 : list.pages.map(\.bleedRect.maxX).max()! + AddPages.gap
        let geometry = PageGeometry(width: min(em, PageGeometry.maximumSide), height: min(em, PageGeometry.maximumSide))
        for (glyph, key) in zip(glyphs, keys) {
            let origin = Point(x: x, y: 0)
            builder.append(Ops.create(parent: WellKnown.pages, position: key, props: PageFields.values {
                $0.common.name = glyph.name
                $0.origin = PathEditing.proto(origin)
                $0.geometry = geometry.stored
            }))
            let mapping = AffineTransform.translation(x: origin.x, y: origin.y + font.metrics.ascender)
            for object in GlyphArtwork.objectIDs(on: glyph.id, in: state) {
                try place(object, mapping: mapping, canvas: nil, copy: true, state: state, builder: &builder)
            }
            x += geometry.width + AddPages.gap
        }
    }

    /// Moves or copies top-level `object` onto `canvas` (nil: the pasteboard) through `mapping`
    /// (source canvas space → target canvas space), composed in the object's layer space.
    static func place(_ object: OpID, mapping: AffineTransform, canvas: OpID?, copy: Bool, state: EngineState, builder: inout ChangeBuilder) throws {
        guard let kind = state.nodeKind(object), let layer = state.store.placement(object)?.parent else { return }
        let layerTransform = Objects.parentTransform(of: object, in: state)
        let local = Objects.transform(of: object, in: state).concatenating(layerTransform).concatenating(mapping).concatenating(layerTransform.inverse)
        let value = local.isIdentity ? Wiretuner_Doc_V1_Transform() : PathEditing.proto(local)
        var target = object
        if copy {
            let top = state.store.children(layer).last.flatMap { state.store.placement($0)?.position }
            let key = try PathEditing.keys(between: top, and: nil, count: 1)[0]
            target = try NodeCopier.create(NodeTree(object, state: state), parent: layer, position: key, schema: state.schema, builder: &builder)
        }
        builder.append(Ops.set(target, [CommonFields.canvas(kind), CommonFields.transform(kind)], values: NodeValues.common(kind: kind) {
            if let canvas { $0.canvas.id = canvas.proto }
            $0.transform = value
        }))
    }
}
