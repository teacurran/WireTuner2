// FreeHand records to an imported scene (import-formats.adoc, "FreeHand"; IO-041, D-083).  The
// walk follows FreeHand's own structure -- the block's layer list, each layer's element list,
// groups, clipping groups, composite paths, text, images, blends and symbol instances -- and
// keeps what WireTuner can hold live: layers as layer groups, clipping groups with the clipping
// path's own fill and stroke, named colours as swatches, tiled, lens and pattern fills,
// arrowheads, area text and text on a path, and symbols.  What it cannot keep is expanded or
// approximated and counted in `FreeHandNotes`, which become the import notice.
//
// Coordinates: FreeHand's are inches, y up, on the pasteboard.  The scene's are points, y down,
// with the pages' union's top-left corner at the origin.  Geometry is baked into scene space
// (paths carry identity transforms, as the PDF importer's do); text, images and symbol instances
// keep a transform.

import Foundation
import WTGeometry
import WTRender
import struct WTRender.StrokeStyle

/// What a conversion produced: the artwork by layer, the pages and what was lost.
struct FreeHandConversion {
    /// The union of the pages in scene space (its top-left corner is the origin).
    var bounds: Rect
    /// Each page's rectangle in scene space, in the file's order.
    var pages: [Rect]
    /// The file's layers as `.layer` groups, bottom first.
    var layers: [ImportedNode]
    var symbols: [ImportedSymbol]
    var notes: [String]
}

struct FreeHandConverter {
    let records: FreeHandRecords
    let name: String
    let context: ImportContext
    /// Hidden layers become hidden layer groups (a file opened as a document) instead of being
    /// left out with a note (an import).
    var keepHidden = false
    var notes = FreeHandNotes()
    /// Converted symbols by class id, in first-use order.
    private var symbols: [Int: ImportedSymbol] = [:]
    private var symbolOrder: [Int] = []
    /// The records being converted, outermost first (FreeHand files can refer to themselves).
    private var visiting: [Int] = []

    /// Nesting beyond this is not followed (FreeHand files nest a few levels; the limit keeps the
    /// walk well inside a secondary thread's stack, where imports run).
    static let maximumDepth = 48

    init(records: FreeHandRecords, name: String, context: ImportContext = ImportContext()) {
        self.records = records
        self.name = name
        self.context = context
    }

    // MARK: Pages

    /// The pages in FreeHand space, [minX, minY, maxX, maxY] each: the file's pages, else their
    /// union, else the document size from the file's tail, else one US Letter page.
    var freeHandPages: [[Double]] {
        func valid(_ rect: [Double]) -> Bool { rect.count == 4 && rect[2] > rect[0] && rect[3] > rect[1] }
        let pages = records.pages.filter(valid)
        if !pages.isEmpty { return pages }
        if valid(records.pageInfo) { return [records.pageInfo] }
        if valid(records.tailPageInfo) { return [records.tailPageInfo] }
        return [[0, 0, 8.5, 11]]
    }

    /// FreeHand space to scene space: points, y down, the pages' union's top-left at the origin.
    var sceneTransform: AffineTransform {
        let pages = freeHandPages
        let minX = pages.map { $0[0] }.min()!
        let maxY = pages.map { $0[3] }.max()!
        return AffineTransform(a: 72, b: 0, c: 0, d: -72, tx: -minX * 72, ty: maxY * 72)
    }

    // MARK: Conversion

    /// The whole file.
    mutating func convert() -> FreeHandConversion {
        let scene = sceneTransform
        let pageRects = freeHandPages.map { page in
            Rect(scene.apply(Point(x: page[0], y: page[3])), scene.apply(Point(x: page[2], y: page[1])))
        }
        let bounds = pageRects.dropFirst().reduce(pageRects[0]) { $0.union($1) }
        var layers: [ImportedNode] = []
        for layerID in records.lists[records.layerList]?.elements ?? [] {
            guard let layer = records.layers[layerID] else { continue }
            let layerName = records.strings[layer.name] ?? ""
            let elements = records.lists[layer.elements]?.elements ?? []
            // Bit 3 marks the guides layer (guides are not artwork); bit 0 is visibility.
            if layer.visibility & 8 != 0 || layerName == "Guides" { continue }
            let children = elements.flatMap { node($0, scene) }
            guard !children.isEmpty else { continue }
            let visible = layer.visibility & 1 != 0
            if !visible && !keepHidden {
                notes.hiddenLayers.append(layerName.isEmpty ? "Unnamed" : layerName)
                continue
            }
            layers.append(.group(ImportedGroup(children: children, name: layerName.isEmpty ? "Layer" : layerName, role: .layer, layerState: ImportedLayerState(visible: visible))))
        }
        notes.noteRecords(records)
        return FreeHandConversion(bounds: bounds, pages: pageRects, layers: layers, symbols: symbolOrder.compactMap { symbols[$0] }, notes: notes.messages)
    }

    /// The nodes record `id` becomes under `transform` (FreeHand space to the parent's space).
    mutating func node(_ id: Int, _ transform: AffineTransform) -> [ImportedNode] {
        guard id != 0, !visiting.contains(id) else { return [] }
        guard visiting.count < FreeHandConverter.maximumDepth else {
            notes.tooDeep = true
            return []
        }
        visiting.append(id)
        defer { visiting.removeLast() }
        return record(id, transform)
    }

    /// Record `id` converted by its kind.  Each kind converts in a function of its own, so a
    /// level of nesting costs only that kind's frame (debug frames are large, and nesting
    /// recurses through here).
    private mutating func record(_ id: Int, _ transform: AffineTransform) -> [ImportedNode] {
        if records.groups[id] != nil { return groupRecord(id, transform) }
        if records.clipGroups[id] != nil { return clipGroupRecord(id, transform) }
        if records.paths[id] != nil { return pathRecord(id, transform) }
        if records.compositePaths[id] != nil { return compositeRecord(id, transform) }
        if records.textObjects[id] != nil { return textRecord(id, transform) }
        if records.displayTexts[id] != nil || records.pathTexts[id] != nil { return displayTextRecord(id, transform) }
        if records.images[id] != nil { return imageRecord(id, transform) }
        if records.newBlends[id] != nil { return blendRecord(id, transform) }
        if records.symbolInstances[id] != nil { return instanceRecord(id, transform) }
        return []
    }

    @inline(never)
    private mutating func groupRecord(_ id: Int, _ transform: AffineTransform) -> [ImportedNode] {
        group(records.groups[id]!, transform)
    }

    @inline(never)
    private mutating func clipGroupRecord(_ id: Int, _ transform: AffineTransform) -> [ImportedNode] {
        clipGroup(records.clipGroups[id]!, transform)
    }

    @inline(never)
    private mutating func pathRecord(_ id: Int, _ transform: AffineTransform) -> [ImportedNode] {
        let path = records.paths[id]!
        return pasteInside(self.path(path, transform), style: path.style, transform: transform)
    }

    @inline(never)
    private mutating func compositeRecord(_ id: Int, _ transform: AffineTransform) -> [ImportedNode] {
        let composite = records.compositePaths[id]!
        return pasteInside(compositePath(composite, transform), style: compositeStyle(composite), transform: transform)
    }

    @inline(never)
    private mutating func textRecord(_ id: Int, _ transform: AffineTransform) -> [ImportedNode] {
        textObject(records.textObjects[id]!, transform).map { [.text($0)] } ?? []
    }

    /// FreeHand 3 to 7's text, alone or on a path (a PathText names its DisplayText).
    @inline(never)
    private mutating func displayTextRecord(_ id: Int, _ transform: AffineTransform) -> [ImportedNode] {
        guard let text = records.displayTexts[id] ?? records.pathTexts[id].flatMap({ records.displayTexts[$0.displayText] }) else { return [] }
        return displayText(text, transform).map { [.text($0)] } ?? []
    }

    @inline(never)
    private mutating func imageRecord(_ id: Int, _ transform: AffineTransform) -> [ImportedNode] {
        image(records.images[id]!, transform).map { [.image($0)] } ?? []
    }

    @inline(never)
    private mutating func blendRecord(_ id: Int, _ transform: AffineTransform) -> [ImportedNode] {
        blend(records.newBlends[id]!, transform)
    }

    @inline(never)
    private mutating func instanceRecord(_ id: Int, _ transform: AffineTransform) -> [ImportedNode] {
        symbolInstance(records.symbolInstances[id]!, transform)
    }

    /// The elements of list `id`, converted.
    mutating func elements(_ id: Int, _ transform: AffineTransform) -> [ImportedNode] {
        (records.lists[id]?.elements ?? []).flatMap { node($0, transform) }
    }

    /// FreeHand transform `id` (identity when there is none).
    func freeHandTransform(_ id: Int) -> AffineTransform {
        records.transforms[id].map(FreeHandConverter.affine) ?? .identity
    }

    /// Six coefficients in libfreehand's order as an affine transform.
    static func affine(_ m: [Double]) -> AffineTransform {
        guard m.count == 6, m.allSatisfy(\.isFinite) else { return .identity }
        return AffineTransform(a: m[0], b: m[1], c: m[2], d: m[3], tx: m[4], ty: m[5])
    }

    mutating func group(_ group: FreeHandRecords.Group, _ transform: AffineTransform) -> [ImportedNode] {
        let inner = freeHandTransform(group.xform).concatenating(transform)
        let children = elements(group.elements, inner)
        guard !children.isEmpty else { return [] }
        let style = self.style(group.style)
        noteEffects(style)
        return [.group(ImportedGroup(children: children, opacity: style.opacity))]
    }

    /// A clipping group (*Paste Inside*): the first element is the clipping path, drawn with its
    /// own fill below the contents and its stroke above them, as WireTuner's clip groups draw.
    mutating func clipGroup(_ group: FreeHandRecords.Group, _ transform: AffineTransform) -> [ImportedNode] {
        let inner = freeHandTransform(group.xform).concatenating(transform)
        let ids = records.lists[group.elements]?.elements ?? []
        guard let first = ids.first else { return [] }
        let clip: ImportedPath?
        if let path = records.paths[first] {
            clip = self.path(path, inner)
        } else if let composite = records.compositePaths[first] {
            clip = compositePath(composite, inner)
        } else {
            clip = nil
        }
        guard let clip else {
            return self.group(group, transform)
        }
        let contents = ids.dropFirst().flatMap { node($0, inner) }
        guard !contents.isEmpty else { return [.path(clip)] }
        let style = self.style(group.style)
        return [.group(ImportedGroup(children: contents, clip: clip, opacity: style.opacity, clipAppearance: true))]
    }

    /// A path whose style holds "contents" (FreeHand 10's *Paste Inside* on a path) as a
    /// clipping group of those contents; otherwise the path itself.
    mutating func pasteInside(_ path: ImportedPath?, style: Int, transform: AffineTransform) -> [ImportedNode] {
        guard let path else { return [] }
        let contentsID = records.contentsName == 0 ? nil : records.propertyLists[style]?.elements[String(records.contentsName)]
            ?? records.graphicStyles[style]?.elements[String(records.contentsName)]
        guard let contentsID else { return [.path(path)] }
        let contents = node(contentsID, transform)
        guard !contents.isEmpty else { return [.path(path)] }
        return [.group(ImportedGroup(children: contents, clip: path, clipAppearance: true))]
    }

    // MARK: Paths

    /// The contours of `path` in FreeHand space mapped by `transform`.
    static func contours(_ path: FreeHandRecords.Path, _ transform: AffineTransform) -> [ImportedContour] {
        var builder = ImportPathBuilder()
        for segment in path.d {
            let n = segment.numbers
            func point(_ index: Int) -> Point { Point(x: n[index], y: n[index + 1]) }
            switch segment.action {
            case "M" where n.count >= 2: builder.move(to: point(0))
            case "L" where n.count >= 2: builder.line(to: point(0))
            case "C" where n.count >= 6: builder.cubic(point(0), point(2), point(4))
            case "Q" where n.count >= 4: builder.quad(point(0), point(2))
            case "A" where n.count >= 7:
                builder.svgArc(rx: n[0], ry: n[1], rotationDegrees: n[2], largeArc: n[3] != 0, sweep: n[4] != 0, to: point(5))
            case "Z": builder.close()
            default: break
            }
        }
        return builder.build().filter { !$0.segments.isEmpty }.map { $0.applying(transform) }
    }

    /// The mean scale of `transform`'s linear part (a stroke width's factor).
    static func scale(of transform: AffineTransform) -> Double {
        abs(transform.a * transform.d - transform.b * transform.c).squareRoot()
    }

    mutating func path(_ path: FreeHandRecords.Path, _ transform: AffineTransform) -> ImportedPath? {
        let total = freeHandTransform(path.xform).concatenating(transform)
        let contours = FreeHandConverter.contours(path, total)
        guard !contours.isEmpty else { return nil }
        return painted(contours, style: path.style, evenOdd: path.evenOdd, transform: total)
    }

    /// A compound path: its paths' contours, painted with the first path's style (libfreehand's
    /// rule), else the composite's own.
    mutating func compositePath(_ composite: FreeHandRecords.CompositePath, _ transform: AffineTransform) -> ImportedPath? {
        let parts = (records.lists[composite.elements]?.elements ?? []).compactMap { records.paths[$0] }
        guard let first = parts.first else { return nil }
        let contours = parts.flatMap { FreeHandConverter.contours($0, freeHandTransform($0.xform).concatenating(transform)) }
        guard !contours.isEmpty else { return nil }
        return painted(contours, style: compositeStyle(composite), evenOdd: first.evenOdd, transform: freeHandTransform(first.xform).concatenating(transform))
    }

    /// A compound path's style: its first path's, else its own (libfreehand's rule).
    func compositeStyle(_ composite: FreeHandRecords.CompositePath) -> Int {
        let first = (records.lists[composite.elements]?.elements.first).flatMap { records.paths[$0] }
        return first.map { $0.style != 0 ? $0.style : composite.style } ?? composite.style
    }

    /// A path of `contours` with style `id`'s fill, stroke and opacity; `transform` scales the
    /// stroke and places a tile.
    mutating func painted(_ contours: [ImportedContour], style id: Int, evenOdd: Bool, transform: AffineTransform) -> ImportedPath {
        let style = self.style(id)
        noteEffects(style)
        let bounds = Rect(boundingPoints: contours.flatMap(\.allPoints))
        let fill = style.fill.map { paint(fill: $0, bounds: bounds, transform: transform) } ?? .none
        let stroke = style.stroke.flatMap { self.stroke($0, transform: transform) }
        return ImportedPath(contours: contours, fill: fill, fillRule: evenOdd ? .evenOdd : .nonZero, stroke: stroke, opacity: style.opacity)
    }

    // MARK: Images

    mutating func image(_ image: FreeHandRecords.Image, _ transform: AffineTransform) -> ImportedImage? {
        let bytes = (records.dataLists[image.dataList]?.elements ?? []).compactMap { records.data[$0]?.data }.reduce(Data(), +)
        guard !bytes.isEmpty, image.width > 0, image.height > 0 else {
            notes.unreadableImages += 1
            return nil
        }
        guard let decoded = try? ImageImporter().decode(bytes, name: name, context: context) else {
            notes.unreadableImages += 1
            return nil
        }
        var result = decoded.image(name: nil)
        let natural = result.naturalRect
        // The natural rect (y down) onto FreeHand's (startX, startY, width, height), whose top
        // edge is startY + height, then the image's transform and the parents'.
        let place = AffineTransform(a: image.width / natural.width, b: 0, c: 0, d: -image.height / natural.height,
                                    tx: image.startX, ty: image.startY + image.height)
        result.transform = place.concatenating(freeHandTransform(image.xform)).concatenating(transform)
        return result
    }

    // MARK: Blends and symbols

    /// A blend: FreeHand stores its steps, which become a group of them (a live WireTuner blend
    /// needs the step count and key objects, which libfreehand does not read).
    mutating func blend(_ blend: FreeHandRecords.NewBlend, _ transform: AffineTransform) -> [ImportedNode] {
        let children = [blend.list1, blend.list2, blend.list3].flatMap { elements($0, transform) }
        guard !children.isEmpty else { return [] }
        notes.blends += 1
        return [.group(ImportedGroup(children: children, name: "Blend"))]
    }

    /// Symbol space: FreeHand's inches to points, y down, the same origin.
    static let symbolSpace = AffineTransform(a: 72, b: 0, c: 0, d: -72, tx: 0, ty: 0)
    /// Symbol space back to FreeHand's.
    static let fromSymbolSpace = AffineTransform(a: 1.0 / 72, b: 0, c: 0, d: -1.0 / 72, tx: 0, ty: 0)

    /// An instance of a symbol: a group placing the symbol's artwork (in symbol space) with the
    /// instance's transform, which `WTModel` writes as a live instance.
    mutating func symbolInstance(_ instance: FreeHandRecords.SymbolInstance, _ transform: AffineTransform) -> [ImportedNode] {
        guard let symbol = symbol(instance.symbolClass) else { return [] }
        let place = FreeHandConverter.fromSymbolSpace.concatenating(FreeHandConverter.affine(instance.xform)).concatenating(transform)
        return [.group(ImportedGroup(children: symbol.nodes, transform: place, name: symbol.name, role: .instance(symbol: symbol.key)))]
    }

    /// Symbol class `id`, converted once.
    mutating func symbol(_ id: Int) -> ImportedSymbol? {
        if let symbol = symbols[id] { return symbol }
        guard let symbolClass = records.symbolClasses[id] else { return nil }
        let nodes = node(symbolClass.group, FreeHandConverter.symbolSpace)
        guard !nodes.isEmpty else { return nil }
        let name = records.strings[symbolClass.name].flatMap { $0.isEmpty ? nil : $0 } ?? "Symbol \(symbolOrder.count + 1)"
        let symbol = ImportedSymbol(key: "freehand-\(id)", name: name, nodes: nodes)
        symbols[id] = symbol
        symbolOrder.append(id)
        return symbol
    }
}
