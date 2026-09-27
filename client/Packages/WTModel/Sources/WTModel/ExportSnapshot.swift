import CoreGraphics
import Foundation
import ImageIO
import WTCRDT
import WTGeometry
import WTInterchange
import WTProto
import WTRender
import WTText

/// What an export takes from the document (exporting.adoc, "Merge semantics"; IO-014's
/// `SceneSnapshot`): an immutable `ExportScene` built on the main actor the instant the export
/// starts -- one page per exported page, output area or selection, each the output display list
/// (printing, non-Guides layers, hidden ones only on request) regrouped into one group per layer
/// so exporters see layers, with the node facts, placed images, placed EPS programs, Document
/// Info, the animation, the text stories and the document package the formats carry beside the
/// artwork.  Remote changes applied afterwards reach the live model only.
public struct ExportSnapshot: Sendable {
    /// One page as the window has it (pages are not nodes yet): its rectangle on the pasteboard,
    /// its name from the Document panel and its bleed.
    public struct Page: Hashable, Sendable {
        public var bounds: Rect
        public var name: String?
        public var bleed: Double

        public init(bounds: Rect, name: String? = nil, bleed: Double = 0) {
            self.bounds = bounds
            self.name = name
            self.bleed = bleed
        }
    }

    /// *What* the sheet exports.
    public enum Scope: Hashable, Sendable {
        /// The pages at these indices of `Request.pages`, in the order given.
        case pages([Int])
        /// The rectangle drawn with the Output Area tool.
        case area(Rect)
        /// Only these objects (top-level objects, or objects inside groups), cropped to their
        /// bounds.
        case selection(Set<NodeID>)
    }

    /// Everything the snapshot needs beyond the state.
    public struct Request: Sendable {
        /// `{name}`: the file's base name.
        public var name: String
        public var pages: [Page]
        public var scope: Scope
        /// *Include page boundary*: the page is the edge of the export; off trims each page to
        /// its artwork.
        public var includePageBoundary: Bool
        /// *Include hidden layers* (Output Options).
        public var includeHidden: Bool
        /// The page colour (*Page background*, *Page color*).
        public var pageColor: Color?
        /// Take the document's animation (the animation formats).
        public var animation: Bool
        /// Take the text stories (Rich Text and Plain Text).
        public var text: Bool
        /// *Embed {product} document*: the manifest fields of the package to embed; nil leaves
        /// the package out.
        public var package: DocumentPackage.Info?

        public init(name: String, pages: [Page], scope: Scope, includePageBoundary: Bool = true, includeHidden: Bool = false, pageColor: Color? = nil,
                    animation: Bool = false, text: Bool = false, package: DocumentPackage.Info? = nil) {
            self.name = name
            self.pages = pages
            self.scope = scope
            self.includePageBoundary = includePageBoundary
            self.includeHidden = includeHidden
            self.pageColor = pageColor
            self.animation = animation
            self.text = text
            self.package = package
        }
    }

    /// The scene, without its package until `resolved()` writes it.
    public var scene: ExportScene
    /// What `PackageWriter` makes the embedded package from, when one was asked for.
    public var packageContents: PackageContents?
    /// The placed images and files the export draws as placeholders because their blobs are not
    /// on this Mac ("Not yet downloaded"), by name.
    public var missing: [String]

    /// The scene with the package written (`PackageWriter.data`): the part of the snapshot that
    /// may run off the main actor.
    public func resolved(writer: PackageWriter = PackageWriter()) throws -> ExportScene {
        var scene = scene
        if let packageContents {
            scene.package = try writer.data(packageContents).data
        }
        return scene
    }

    /// Takes the snapshot of `state`.  `builder` is the scene builder to draw with (its text
    /// layout set as the window's); `blob` answers a blob's bytes by SHA-256, nil when it is not
    /// on this Mac.
    public static func capture(_ state: EngineState, request: Request, builder: DocumentDisplayListBuilder,
                               blob: @escaping (Data) -> Data?) -> ExportSnapshot {
        var builder = builder
        let screen = builder.rebuild(state)
        let output = builder.outputDisplayList(state, includeHidden: request.includeHidden)
        var capture = ExportCapture(state: state, screen: screen, output: output, blob: blob)
        let pages = capture.pages(for: request)
        var scene = ExportScene(name: request.name, pages: pages, info: documentInfo(state), nodes: capture.nodes, assets: capture.assets,
                                rasterResolution: rasterResolution(state), placedPostScript: capture.postScript)
        scene.svgAnimations = capture.svgAnimations
        scene.output = outputContext(state)
        if request.text {
            scene.text = textBlocks(pages, state: state, request: request)
        }
        if request.animation {
            scene.animation = animation(state, request: request, displayList: screen.displayList, area: pages.first?.bounds)
        }
        // The package's thumbnail and preview show the first exported page (Letter when none).
        let packagePage = pages.first?.bounds ?? Rect(x: 0, y: 0, width: 612, height: 792)
        let packageContents = request.package.map { DocumentPackage.contents(of: state, info: $0, page: packagePage, cached: blob) }
        return ExportSnapshot(scene: scene, packageContents: packageContents, missing: capture.missing)
    }

    // MARK: Document facts

    /// The document's colour resolved for output (CMS-011; color-profiles.adoc, "Client"): Working
    /// RGB and Working CMYK from `SettingsProps.color` (a pending profile outputs through its
    /// fallback), the document intent and compensation, the proof setup, and each placed image's
    /// own source profile -- its embedded one when it uses it, else the one chosen for it -- by
    /// blob hash (`ImageItem.assetID`); an image on the document default is not listed.
    public static func outputContext(_ state: EngineState, registry: WTColor.ProfileRegistry = .shared) -> WTColor.OutputContext {
        let settings = ColorSettings(state, registry: registry)
        var images: [String: WTColor.ProfileRef] = [:]
        func visit(_ node: OpID) {
            for child in state.liveChildren(node) {
                if let info = ImageColorInfo(child, in: state, registry: registry), case .image(let image)? = state.props(child).kind {
                    switch info.source {
                    case .embedded: images[ImageNodes.assetID(image.pixels)] = info.embedded
                    case .profile(let profile): images[ImageNodes.assetID(image.pixels)] = profile
                    case .documentDefault: break
                    }
                }
                visit(child)
            }
        }
        visit(WellKnown.layers)
        visit(WellKnown.symbols)
        return WTColor.OutputContext(rgbProfile: settings.rgbProfile, cmykProfile: settings.cmykProfile, intent: settings.intent,
                                     blackPointCompensation: settings.blackPointCompensation, proof: settings.proof, imageProfiles: images,
                                     converter: registry === WTColor.ProfileRegistry.shared ? .shared : WTColor.Converter(registry: registry))
    }

    /// `SettingsProps.raster_effects.resolution_ppi`, 72 when unset (raster-effects.adoc).
    static func rasterResolution(_ state: EngineState) -> Double {
        let ppi = state.props(WellKnown.settings).settings.rasterEffects.resolutionPpi
        return ppi == 0 ? 72 : Double(ppi)
    }

    /// Document Info (file-info.adoc) as exporters write it; empty when it was never written.
    static func documentInfo(_ state: EngineState) -> ExportDocumentInfo {
        let settings = state.props(WellKnown.settings).settings
        guard settings.hasInfo else { return ExportDocumentInfo() }
        let info = settings.info
        let statuses: [Wiretuner_Doc_V1_CopyrightStatus: DocumentMetadata.CopyrightStatus] = [.copyrighted: .copyrighted, .publicDomain: .publicDomain]
        let metadata = DocumentMetadata(
            title: info.title, headline: info.headline, description: info.description_p, keywords: info.keywords, category: info.category,
            supplementalCategories: info.supplementalCategories, creators: info.creators, creatorJobTitle: info.creatorJobTitle, credit: info.credit,
            source: info.source, copyrightNotice: info.copyrightNotice, copyrightStatus: statuses[info.copyrightStatus] ?? .unknown,
            rightsUsageTerms: info.rightsUsageTerms, webStatement: info.webStatement, dateCreated: info.dateCreated, city: info.city,
            state: info.state, country: info.country, instructions: info.instructions, language: info.language
        )
        func text(_ value: String) -> String? { value.isEmpty ? nil : value }
        return ExportDocumentInfo(title: text(info.title), author: info.creators.first, subject: text(info.headline), description: text(info.description_p),
                                  keywords: info.keywords, language: text(info.language), metadata: metadata)
    }

    /// The document's animation over the exported pages (WEB-019, WEB-020); nil when it has
    /// none.
    static func animation(_ state: EngineState, request: Request, displayList: DisplayList, area: Rect?) -> ExportAnimation? {
        let info = AnimationInfo(state)
        guard info.source != .none else { return nil }
        let backgrounds: [Wiretuner_Doc_V1_AnimationBackground: ExportAnimation.Background] = [.white: .white, .transparent: .transparent]
        let background = backgrounds[state.props(WellKnown.settings).settings.animation.background] ?? .pageColor
        let pages = request.pages.map(\.bounds)
        return ExportAnimation(frames: info.frames(pages: pages), fps: info.fps, loop: info.loop, background: background, displayList: displayList,
                               area: area ?? pages.first ?? displayList.bounds ?? Rect(x: 0, y: 0, width: 1, height: 1), pageColor: request.pageColor,
                               autoplay: info.autoplay)
    }

    /// One text block per text node on the exported pages (export-text.adoc): every text node on
    /// a printing layer -- visible ones, hidden ones with *Include hidden layers* -- inside groups
    /// too, on the page holding its origin, in stacking order on that page; a selection exports
    /// the text of the selected objects.  Each block is its own story of plain paragraphs with
    /// their indents.
    static func textBlocks(_ pages: [ExportPage], state: EngineState, request: Request) -> [ExportTextBlock] {
        var selected: Set<OpID>?
        if case .selection(let nodes) = request.scope { selected = Set(nodes.map(OpID.init)) }
        var found: [(node: OpID, inSelection: Bool)] = []
        func visit(_ node: OpID, inSelection: Bool) {
            let inside = inSelection || selected?.contains(node) == true
            if state.store.kind(node) == TextFields.kind {
                found.append((node, inside))
            }
            for child in state.liveChildren(node) { visit(child, inSelection: inside) }
        }
        let order = LayerOrder(state)
        for layer in order.printingLayers where layer.visible || request.includeHidden {
            for object in order.objects(on: layer.id, in: state) { visit(object, inSelection: false) }
        }
        var blocks: [ExportTextBlock] = []
        var stacking: [Int: Int] = [:]
        for entry in found where selected == nil || entry.inSelection {
            let own = PathEditing.transform(state.props(entry.node).text.common.transform)
            let origin = own.concatenating(Objects.parentTransform(of: entry.node, in: state)).apply(Point(x: 0, y: 0))
            let holder = selected == nil ? pages.firstIndex { $0.bounds.contains(origin) } : pages.indices.first
            guard let page = holder, let text = TextNode(entry.node, in: state) else { continue }
            let position = stacking[page, default: 0]
            stacking[page] = position + 1
            blocks.append(ExportTextBlock(node: NodeID(entry.node), page: page, stackingOrder: position, story: story(text, state: state)))
        }
        return blocks
    }

    /// The text-range links of the text nodes in `scene` laid out with `engine` (the window's
    /// `DocumentFontIndex.layoutEngine`), one rectangle per line in pasteboard space (WEB-005):
    /// the app assigns the result to `ExportScene.textLinks` after `capture`, which cannot lay out
    /// text off the main actor.  Blocks under a deleted container are left out; exporters clip
    /// the rectangles to each page.
    @MainActor
    public static func textLinks(_ state: EngineState, engine: TextLayoutEngine) -> [NodeID: [ExportTextLink]] {
        var result: [NodeID: [ExportTextLink]] = [:]
        for node in state.store.nodes.sorted() where state.store.kind(node) == TextFields.kind && Reachability.isReachable(node, in: state) {
            guard let text = TextNode(node, in: state) else { continue }
            let runs = TextLinks.runs(text)
            guard !runs.isEmpty else { continue }
            // Text on a path lays out along it (TYPE-041), so its links follow the curve.
            let layout = TextLayoutReading.layout(text, engine: engine, state: TextLayoutReading.path(of: text, in: state) == nil ? nil : state)
            let transform = Objects.pasteboardTransform(of: node, in: state)
            let links = runs.compactMap { run -> ExportTextLink? in
                let rects = layout.selection(from: run.range.lowerBound, to: run.range.upperBound).compactMap { quad -> Rect? in
                    let points = quad.corners.map(transform.apply)
                    guard let minX = points.map(\.x).min(), let maxX = points.map(\.x).max(), let minY = points.map(\.y).min(),
                          let maxY = points.map(\.y).max() else { return nil }
                    return Rect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
                }
                return rects.isEmpty ? nil : ExportTextLink(url: run.url, rects: rects)
            }
            if !links.isEmpty { result[NodeID(node)] = links }
        }
        return result
    }

    // MARK: Comments (COLLAB-033)

    /// The document's comment threads for the PDF writer's *Comments as annotations*
    /// (comments.adoc, "Exporting"): every thread with a drawn pin (pasteboard points), resolved or
    /// not, its live comments in thread order -- deleted ones left out -- with each author's display
    /// name from `name` (the window's roster) and `wall_time_ms`.  The app assigns the result to
    /// `ExportScene.comments` after `capture` when the option is on.
    public static func comments(_ state: EngineState, pages: PageList? = nil, name: (String) -> String) -> [ExportCommentThread] {
        CommentThreadModel(state, pages: pages).threads.compactMap { thread in
            guard let pin = thread.pin else { return nil }
            let comments = thread.comments.filter { !$0.deleted }.map { ExportComment(author: name($0.author), text: $0.text, wallTimeMs: $0.wallTimeMs) }
            return ExportCommentThread(pin: pin, resolved: thread.resolved, comments: comments)
        }
    }

    // MARK: Snippets (COLLAB-036, COLLAB-037)

    /// What no snippet can express for a node of `kind`, in the snippet's words.
    static func unexpressed(_ kind: NodeKind?) -> [String] {
        switch kind {
        case .blend?: ["a blend"]
        case .extrude?: ["an extrusion"]
        case .envelope?: ["an envelope"]
        case .perspective?: ["an object on a perspective grid"]
        default: []
        }
    }

    /// The Inspect panel's `SnippetObject` for drawn object `node` of `scene`: its display item as
    /// placed, what the display list does not keep -- its kind (a rectangle with equal corner radii
    /// is a rounded rectangle), name, the swatch names of the document's colours, what no snippet
    /// can express -- and the placed images it draws, decoded from `blob`.  Nil when the scene does
    /// not draw it.
    public static func snippetObject(_ node: OpID, scene: DocumentScene, state: EngineState, blob: (Data) -> Data? = { _ in nil }) -> SnippetObject? {
        guard let object = scene.objects[NodeID(node)] else { return nil }
        let props = state.props(node)
        let shape: SnippetObject.Shape
        switch props.kind {
        case .rect(let rect)?:
            let corners = rect.corners
            let radii = corners.uniform ? [corners.topLeft] : [corners.topLeft, corners.topRight, corners.bottomRight, corners.bottomLeft]
            shape = radii.allSatisfy({ $0 == radii[0] }) && radii[0] > 0 ? .roundedRectangle(radius: radii[0]) : .rectangle
        case .ellipse?: shape = .ellipse
        case .path?, .polygon?: shape = .path
        case .text?: shape = .text
        default: shape = .other
        }
        var assets: [String: ExportAsset] = [:]
        func collect(_ item: DisplayItem) {
            switch item {
            case .group(let group): group.children.forEach(collect)
            case .image(let image):
                if let fallback = image.fallback { collect(fallback) }
                if assets[image.assetID] == nil, let hash = ExportCapture.bytes(hex: image.assetID), let data = blob(hash),
                   let asset = ExportCapture.asset(data) { assets[image.assetID] = asset }
            default: break
            }
        }
        collect(object.item)
        var swatchNames: [Color: String] = [:]
        for swatch in SwatchList(state).swatches where swatchNames[swatch.color] == nil { swatchNames[swatch.color] = swatch.name }
        let name = NodeValues.common(props).flatMap { ExportCapture.text($0.name) }
        return SnippetObject(name: name, node: NodeID(node), shape: shape, item: object.item, assets: assets, swatchNames: swatchNames,
                             cannotExpress: unexpressed(state.nodeKind(node)))
    }

    /// The story of `text` for text exports: its paragraphs with resolved attributes, the
    /// document's text styles and swatch colours applied (`TextAttributeMapping.story`, TYPE-034).
    static func story(_ text: TextNode, state: EngineState) -> ExportStory {
        TextAttributeMapping.story(text, styles: TextStyleResolver(state), colors: ColorResolver(state))
    }
}

/// The work of one capture: the output list regrouped into pages, and what the pages reference.
struct ExportCapture {
    let state: EngineState
    let output: DisplayList
    let blob: (Data) -> Data?
    /// Screen item path → node, for the objects inside the output list's top-level items.
    let nested: [NodeID: [(path: [Int], node: NodeID)]]
    private(set) var nodes: [NodeID: ExportNodeInfo] = [:]
    private(set) var assets: [String: ExportAsset] = [:]
    private(set) var postScript: [NodeID: ExportPostScript] = [:]
    /// Placed SVG animations drawn on the exported pages (WEB-008's WTModel half).
    private(set) var svgAnimations: [NodeID: ExportSVGAnimation] = [:]
    private(set) var missing: [String] = []
    private var tried: Set<String> = []
    /// Document page numbers (1-based) by page node, for page links.
    private lazy var pageNumbers: [OpID: Int] = Dictionary(uniqueKeysWithValues: PageList(state).pages.map { ($0.id, $0.number) })

    init(state: EngineState, screen: DocumentScene, output: DisplayList, blob: @escaping (Data) -> Data?) {
        self.state = state
        self.output = output
        self.blob = blob
        // Every object below a top-level one, by that top-level object, with its path below it.
        var tops: [Int: NodeID] = [:]
        for object in screen.objects.values where object.itemPath.count == 1 {
            tops[object.itemPath[0]] = NodeID(object.id)
        }
        var byTop: [NodeID: [(path: [Int], node: NodeID)]] = [:]
        for object in screen.objects.values where object.itemPath.count > 1 {
            tops[object.itemPath[0]].map { byTop[$0, default: []].append((Array(object.itemPath.dropFirst()), NodeID(object.id))) }
        }
        nested = byTop
    }

    /// The pages `request` exports.
    mutating func pages(for request: ExportSnapshot.Request) -> [ExportPage] {
        switch request.scope {
        case .pages(let indices):
            return indices.filter(request.pages.indices.contains).map { index in
                let page = request.pages[index]
                let keep = output.itemBounds.indices.filter { output.itemBounds[$0]?.intersects(page.bounds) == true }
                let bounds = request.includePageBoundary ? page.bounds : union(keep) ?? page.bounds
                var exported = self.page(keep, bounds: bounds, name: page.name, background: request.pageColor, bleed: page.bleed)
                exported.number = index + 1
                exported.readingOrder = readingOrder(ofPage: index, bounds: page.bounds)
                return exported
            }
        case .area(let area):
            let keep = output.itemBounds.indices.filter { output.itemBounds[$0]?.intersects(area) == true }
            return [page(keep, bounds: area, name: nil, background: request.pageColor, bleed: 0)]
        case .selection(let selected):
            let keep = output.nodeIDs.indices.filter { index in
                output.nodeIDs[index].map { node in selected.contains(node) || nested[node]?.contains { selected.contains($0.node) } == true } == true
            }
            guard let bounds = union(keep) else { return [] }
            return [page(keep, bounds: bounds, name: nil, background: nil, bleed: 0)]
        }
    }

    /// The reading order (OBJ-041) of the document page at `index` with pasteboard `bounds`, for
    /// tagged PDF (IO-032): the page whose rectangle is `bounds`, else the page at `index`.
    func readingOrder(ofPage index: Int, bounds: Rect) -> [NodeID] {
        let list = PageList(state)
        guard let page = list.pages.first(where: { $0.rect == bounds }) ?? (list.pages.indices.contains(index) ? list.pages[index] : nil) else { return [] }
        return ReadingOrder.order(of: page, in: state, pages: list).map(NodeID.init)
    }

    func union(_ indices: [Int]) -> Rect? {
        indices.compactMap { output.itemBounds[$0] }.reduce(nil) { total, rect in total?.union(rect) ?? rect }
    }

    /// The page drawing the output items at `indices`, each layer's run of them one group
    /// carrying the layer's node id.
    mutating func page(_ indices: [Int], bounds: Rect, name: String?, background: Color?, bleed: Double) -> ExportPage {
        var items: [DisplayItem] = []
        var ids: [NodeID?] = []
        var nestedIDs: [[Int]: NodeID] = [:]
        // Runs of items on one layer, each drawn as one group carrying the layer's id.
        var runs: [(layer: NodeID?, indices: [Int])] = []
        for index in indices {
            let layer = output.layerSpan(containing: index)?.layer.id
            if let last = runs.last, last.layer == layer {
                runs[runs.count - 1].indices.append(index)
            } else {
                runs.append((layer, [index]))
            }
        }
        for run in runs {
            let top = items.count
            items.append(.group(GroupItem(children: run.indices.map { output.items[$0] })))
            ids.append(run.layer)
            run.layer.map { record($0, isLayer: true) }
            for (child, index) in run.indices.enumerated() {
                output.nodeIDs[index].map { visit($0, path: [top, child], into: &nestedIDs) }
            }
        }
        for item in items { collectAssets(item) }
        let list = DisplayList(canvas: output.canvas, items: items, nodeIDs: ids.contains { $0 != nil } ? ids : [])
        return ExportPage(name: name, bounds: bounds, displayList: list, background: background, nestedNodeIDs: nestedIDs, bleed: bleed)
    }

    /// Records the object `node` drawn at `path` on the page and the objects inside it.
    mutating func visit(_ node: NodeID, path: [Int], into nestedIDs: inout [[Int]: NodeID]) {
        nestedIDs[path] = node
        record(node, isLayer: false)
        for inner in nested[node] ?? [] {
            nestedIDs[path + inner.path] = inner.node
            record(inner.node, isLayer: false)
        }
    }

    /// The node facts of `node`, and its PostScript when it is a placed EPS file.
    mutating func record(_ node: NodeID, isLayer: Bool) {
        let id = OpID(node)
        let props = state.props(id)
        if case .placedFile(let placed)? = props.kind, placed.content.format == .eps, let data = blob(placed.content.blobSha256) {
            let b = placed.content.bounds
            let bounds = Rect(x: b.x, y: b.y, width: b.width, height: b.height)
            postScript[node] = ExportPostScript(data: data, boundingBox: bounds, bounds: bounds, transform: Objects.pasteboardTransform(of: id, in: state))
        }
        if let animation = Self.svgAnimation(id, in: state, blob: blob) { svgAnimations[node] = animation }
        if let common = NodeValues.common(props) {
            // The navigation facts (WEB-005, WEB-023), with the read-time normalizations.
            let navigation = NavigationInfo(common, in: state)
            let info = ExportNodeInfo(name: Self.text(common.name), alt: Self.text(common.alt), decorative: common.decorative, url: navigation.url,
                                      isLayer: isLayer, note: Self.text(common.note), linkAlt: navigation.alt,
                                      linkTarget: navigation.target == .newTab ? .newTab : .sameWindow,
                                      pageLink: navigation.goToPage.flatMap { pageNumbers[$0] })
            if info != ExportNodeInfo() { nodes[node] = info }
        }
    }

    /// A placed SVG animation as the HTML publisher plays it: the file's bytes from its asset's
    /// blob, its natural size, its transform to the pasteboard and its *On the web* settings.  Nil
    /// for any other node, a dangling asset, a blob not on this Mac, or a gzip-compressed file
    /// (`.svgz`: the publisher then keeps the poster the display list draws).
    static func svgAnimation(_ node: OpID, in state: EngineState, blob: (Data) -> Data?) -> ExportSVGAnimation? {
        guard let info = SvgAnimationInfo(node, in: state), let asset = info.asset, let data = blob(state.props(asset).asset.sha256),
              !data.starts(with: [0x1F, 0x8B]) else { return nil }
        let loop: ExportSVGAnimation.Loop = switch info.web.loop {
        case .loop: .loop
        case .once: .once
        case .asFile: .asFile
        }
        return ExportSVGAnimation(data: data, width: info.naturalSize.width, height: info.naturalSize.height,
                                  transform: Objects.pasteboardTransform(of: node, in: state), script: info.kinds.script,
                                  autoplay: info.web.autoplay, loop: loop, playOnHover: info.web.playOnHover)
    }

    /// `value`, nil when it is blank.
    static func text(_ value: String) -> String? {
        value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : value
    }

    /// The pixels of every image `item` draws, decoded from its blob.
    mutating func collectAssets(_ item: DisplayItem) {
        switch item {
        case .group(let group):
            for child in group.children { collectAssets(child) }
        case .image(let image):
            if let fallback = image.fallback { collectAssets(fallback) }
            if tried.insert(image.assetID).inserted {
                if let hash = Self.bytes(hex: image.assetID), let data = blob(hash), let asset = Self.asset(data) {
                    assets[image.assetID] = asset
                } else {
                    missing.append(image.name)
                }
            }
        default:
            break
        }
    }

    /// The bytes of a lower-case hex string; nil when it is not hex.
    static func bytes(hex: String) -> Data? {
        let digits = Array(hex.utf8)
        guard digits.count.isMultiple(of: 2) else { return nil }
        var data = Data()
        for index in stride(from: 0, to: digits.count, by: 2) {
            guard let byte = UInt8(String(decoding: digits[index..<index + 2], as: UTF8.self), radix: 16) else { return nil }
            data.append(byte)
        }
        return data
    }

    /// A blob decoded as an image, keeping a JPEG's bytes.
    static func asset(_ data: Data) -> ExportAsset? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil), let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { return nil }
        let isJPEG = data.starts(with: [0xFF, 0xD8, 0xFF])
        return ExportAsset(image: image, jpegData: isJPEG ? data : nil)
    }
}
