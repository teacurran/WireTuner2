import Foundation
import WTCRDT
import WTGeometry
import WTProto

// DATA-020: *Merge to Pages* (data-merge.adoc, "Merge to Pages"; "Merge engine").  Each merged
// page is an ordinary page after the template, named `<template> · n`, holding deep copies of the
// template's objects with the record's values baked in: placeholders become plain text in their
// formatting, bound barcodes get their codes, bound images their pictures, link bindings set the
// link, hidden objects are left out, and every binding is cleared -- so merging again never
// touches merged pages.  Text flow links between template blocks are recreated between the
// copies.  A large merge is several changes of at most 10,000 ops under one label and one undo
// step (`Document.mergeToPages`).

/// Where a merge's pictures come from: an IMAGE field's value (a URL or a file path) to the
/// pixels already stored as a blob (fetched through `FetchAsset`, or imported locally).  Nil
/// means the picture could not be obtained: the copy's `pixels` register is left unset (the
/// empty placeholder) and the report lists it.
public typealias MergeImageResolver = @Sendable (String) -> Wiretuner_Doc_V1_PixelSource?

/// One chunk of a merge to pages: the output pages for the records `indices` of `records`,
/// inserted after page `after` in page order, labelled `Merge N records to pages` with `total`.
public struct MergeToPages: Command {
    /// The template page(s), in order (several make a set per record).
    public var templates: [OpID]
    public var records: RecordSet
    /// 0-based record indices of this chunk.
    public var indices: [Int]
    public var options: MergeOptions
    /// For a grid: the objects on the (first) template page whose union bounds are the cell.
    public var selection: [OpID]
    /// The page the new pages follow (the template, or the last page of the previous chunk).
    public var after: OpID?
    /// The number of the first output page of this chunk, for naming.
    public var firstNumber: Int
    /// The whole merge's record count, for the label.
    public var total: Int
    public var images: MergeImageResolver?
    /// Shrink factors decided on the main actor (`MergeEngine.shrink` needs the layout engine):
    /// record index and text node to the text to place.  Absent entries place the text as it
    /// substitutes.
    public var fitted: [MergeFitKey: MergeText]
    public var label: String { "Merge \(total) record\(total == 1 ? "" : "s") to pages" }

    public init(templates: [OpID], records: RecordSet, indices: [Int], options: MergeOptions = MergeOptions(), selection: [OpID] = [],
                after: OpID? = nil, firstNumber: Int = 1, total: Int? = nil, images: MergeImageResolver? = nil, fitted: [MergeFitKey: MergeText] = [:]) {
        self.templates = templates
        self.records = records
        self.indices = indices
        self.options = options
        self.selection = selection
        self.after = after
        self.firstNumber = firstNumber
        self.total = total ?? indices.count
        self.images = images
        self.fitted = fitted
    }

    public func execute(_ builder: inout ChangeBuilder, state: EngineState) throws {
        let list = PageList(state)
        let pages = try templates.map { try PageEditing.page($0, in: list) }
        guard let first = pages.first, !list.isSynthesized else { throw PageSetupError.notAPage(templates.first ?? .zero) }
        let model = DataModel(state)
        let selectionBounds = selection.compactMap { Objects.bounds(of: $0, in: state) }.reduce(Rect.null) { $0.union($1) }
        let plan = MergeEngine.plan(templates: templates, indices: indices.filter { records.record(at: $0) != nil && $0 < records.count },
                                    layout: options.layout, page: first.rect, selection: selectionBounds)
        guard !plan.isEmpty else { return }
        // Page order: after `after` (default: the last template page), before the next live page.
        let anchor = try PageEditing.page(after ?? templates[templates.count - 1], in: list)
        let siblings = state.store.children(WellKnown.pages)
        let lo = state.store.placement(anchor.id)?.position
        let next = siblings.firstIndex(of: anchor.id).flatMap { index in siblings[(index + 1)...].first { state.isLive($0) } }
        let keys = try PathEditing.keys(between: lo, and: next.flatMap { state.store.placement($0)?.position }, count: plan.count)
        var x = (list.pages.map(\.bleedRect.maxX).max() ?? 0) + AddPages.gap
        let byID = Dictionary(uniqueKeysWithValues: pages.map { ($0.id, $0) })
        var objectCache: [OpID: [OpID]] = [:]
        var tops: [OpID: [UInt8]] = [:]
        for (index, (output, key)) in zip(plan, keys).enumerated() {
            let template = byID[output.template] ?? first
            x += template.bleed
            let origin = Point(x: x, y: template.origin.y)
            let number = firstNumber + index
            let name = options.layout == .onePerPage ? "\(template.name) · \(output.placements[0].record + 1)" : "\(template.name) · \(number)"
            builder.append(Ops.create(parent: WellKnown.pages, position: key, props: PageFields.values {
                $0.common.name = String(name.prefix(256))
                $0.origin = PageEditing.point(origin)
                $0.geometry = template.ownGeometry.stored
                $0.bleed = template.ownBleed
                if let master = template.master { $0.master.id = master.proto }
            }))
            x += template.geometry.width + template.bleed + AddPages.gap
            let pageOffset = Vector(dx: origin.x - template.origin.x, dy: origin.y - template.origin.y)
            let objects: [OpID]
            if case .grid = options.layout {
                objects = selection
            } else {
                if objectCache[template.id] == nil { objectCache[template.id] = Self.objects(on: template, in: state, pages: list) }
                objects = objectCache[template.id] ?? []
            }
            for placement in output.placements {
                guard let record = records.record(at: placement.record) else { continue }
                let substitution = RecordSubstitution(model: model, record: record, removeBlankLines: options.removeBlankLines)
                let offset = Vector(dx: pageOffset.dx + placement.offset.dx, dy: pageOffset.dy + placement.offset.dy)
                try copy(objects, offset: offset, record: placement.record, substitution: substitution, state: state, tops: &tops, builder: &builder)
            }
        }
    }

    /// Deep copies of `objects` translated by `offset`, with `substitution` baked in.
    private func copy(_ objects: [OpID], offset: Vector, record: Int, substitution: RecordSubstitution, state: EngineState,
                      tops: inout [OpID: [UInt8]], builder: inout ChangeBuilder) throws {
        var mapping: [OpID: OpID] = [:]
        var texts: [(source: OpID, text: MergeText)] = []
        var trees: [NodeTree] = []
        for node in objects {
            guard let layer = state.store.placement(node)?.parent,
                  var tree = baked(NodeTree(node, state: state), record: record, substitution: substitution, state: state, texts: &texts) else { continue }
            let lower = tops[layer] ?? state.store.children(layer).last.flatMap { state.store.placement($0)?.position }
            let key = try PathEditing.keys(between: lower, and: nil, count: 1)[0]
            tops[layer] = key
            let toParent = Objects.parentTransform(of: node, in: state).inverse
            tree.transformConnectors(by: .translation(offset))
            let copy = try NodeCopier.create(tree, parent: layer, position: key, schema: state.schema, builder: &builder, mapping: &mapping)
            if let kind = state.nodeKind(node) {
                let moved = Objects.transform(of: node, in: state).concatenating(.translation(toParent.apply(offset)))
                builder.append(Objects.setTransform(copy, kind: kind, moved))
            } else {
                // An image (a kind WTModel only reads): its own transform register.
                var value = Wiretuner_Doc_V1_NodeProps()
                let own = PathEditing.transform(state.props(node).image.common.transform)
                value.image.common.transform = PathEditing.proto(own.concatenating(.translation(toParent.apply(offset))))
                builder.append(Ops.set(copy, [RegisterPath([ImageKind.kind, 1, 4])], values: value))
            }
            trees.append(tree)
        }
        NodeCopier.rewriteReferences(in: trees, mapping: mapping, builder: &builder)
        for (source, text) in texts {
            guard let copy = mapping[source] else { continue }
            MergeTextWriter.write(text, into: copy, builder: &builder)
            // Flow links: to the copy of the linked block when it was copied too, else none.
            let props = state.props(source).text
            for (field, ref) in [(UInt32(4), props.nextLink), (UInt32(5), props.prevLink)] where ref.hasID {
                var value = Wiretuner_Doc_V1_NodeProps()
                if let target = mapping[OpID(ref.id)] {
                    if field == 4 { value.text.nextLink.id = target.proto } else { value.text.prevLink.id = target.proto }
                } else {
                    value.text = .init()
                }
                builder.append(Ops.set(copy, [RegisterPath([TextFields.kind, field])], values: value))
            }
        }
    }

    /// `tree` with the record baked in: nil when a visibility binding hides it; bindings
    /// cleared; barcode values, links and pictures set; text nodes noted in `texts` (written after
    /// the copy exists: `NodeCopier` does not copy TEXT fields) with their links cleared until
    /// they are rewritten.
    private func baked(_ tree: NodeTree, record: Int, substitution: RecordSubstitution, state: EngineState,
                       texts: inout [(source: OpID, text: MergeText)]) -> NodeTree? {
        guard let source = tree.source else { return tree }
        if substitution.hides(source, state: state) { return nil }
        var tree = tree
        if case .barcode? = tree.props.kind {
            tree.props.barcode.value = String(substitution.barcodeValue(source, props: tree.props.barcode, state: state).prefix(4096))
        }
        if let link = substitution.link(source, state: state) {
            Self.setCommon(&tree.props) { $0.url = String(link.prefix(2048)) }
        }
        if case .image? = tree.props.kind, let value = substitution.image(source, state: state) {
            if let pixels = images?(value) { tree.props.image.pixels = pixels } else { tree.props.image.clearPixels() }
        }
        if case .text? = tree.props.kind, let text = TextNode(source, in: state) {
            texts.append((source, fitted[MergeFitKey(record: record, node: source)] ?? substitution.mergeText(text, state: state)))
            tree.props.text.clearNextLink()
            tree.props.text.clearPrevLink()
        }
        Self.setCommon(&tree.props) { $0.clearDataBinding() }
        tree.children = tree.children.compactMap { baked($0, record: record, substitution: substitution, state: state, texts: &texts) }
        return tree
    }

    /// The template page's objects in stacking order: top-level objects of the main canvas whose
    /// bounds are on the page, and text blocks and images -- which have no geometry bounds before
    /// layout -- whose origin is on it.
    static func objects(on page: Page, in state: EngineState, pages: PageList) -> [OpID] {
        state.liveChildren(WellKnown.layers).filter { state.nodeKind($0) == .layer }.flatMap { layer in
            state.liveChildren(layer).filter { node in
                let props = state.props(node)
                let image = state.store.kind(node) == ImageKind.kind
                guard Objects.isObject(node, in: state) || image else { return false }
                let common = image ? props.image.common : NodeValues.common(props)
                guard common?.hasCanvas != true else { return false }
                if let bounds = Objects.bounds(of: node, in: state) { return pages.page(ofBounds: bounds)?.id == page.id }
                let origin = Objects.parentTransform(of: node, in: state).concatenating(PathEditing.transform(common?.transform ?? .init())).apply(Point(x: 0, y: 0))
                return pages.page(containing: origin)?.id == page.id
            }
        }
    }

    /// Edits the `CommonProps` of any kind in place, at the wire level: every kind message holds
    /// its common props as field 1 (common.proto), so the kind's payload is re-encoded with
    /// field 1 replaced.
    static func setCommon(_ props: inout Wiretuner_Doc_V1_NodeProps, _ edit: (inout Wiretuner_Doc_V1_CommonProps) -> Void) {
        guard let bytes: [UInt8] = try? props.serializedBytes(), let kind = WireReader.fields(bytes)?.last, kind.wireType == 2,
              let fields = WireReader.fields(kind.payload) else { return }
        var common = fields.last { $0.number == 1 && $0.wireType == 2 }.flatMap { try? Wiretuner_Doc_V1_CommonProps(serializedBytes: $0.payload) }
            ?? Wiretuner_Doc_V1_CommonProps()
        edit(&common)
        let encoded: [UInt8] = (try? common.serializedBytes()) ?? []
        let payload = Wire.field(1, encoded) + fields.filter { $0.number != 1 }.flatMap(\.record)
        if let edited = try? Wiretuner_Doc_V1_NodeProps(serializedBytes: Wire.field(kind.number, payload)) { props = edited }
    }
}

/// A text node of the template in one record: what `MergeToPages.fitted` is keyed by.
public struct MergeFitKey: Hashable, Sendable {
    public var record: Int
    public var node: OpID

    public init(record: Int, node: OpID) {
        self.record = record
        self.node = node
    }
}

/// Writing a `MergeText` into a newly created text node: one `TextInsert` of the whole string,
/// one mark per run and format value (a paragraph's last run also covers its newline), the
/// paragraph registers on each newline and its tab stops.
enum MergeTextWriter {
    static func write(_ text: MergeText, into node: OpID, builder: inout ChangeBuilder) {
        let string = text.string
        let count = string.unicodeScalars.count
        guard count > 0 else { return }
        let first = builder.append(Ops.textInsert(node, TextFields.text, string))
        func id(_ offset: Int) -> OpID { OpID(counter: first.counter + UInt64(offset), replica: first.replica) }
        var offset = 0
        for (index, paragraph) in text.paragraphs.enumerated() {
            let terminated = index < text.paragraphs.count - 1
            for (runIndex, run) in paragraph.runs.enumerated() {
                let length = run.text.unicodeScalars.count
                let covers = length + (terminated && runIndex == paragraph.runs.count - 1 ? 1 : 0)
                if covers > 0 {
                    let next = offset + covers < count ? id(offset + covers) : .zero
                    for value in run.formats {
                        builder.append(TextEditing.mark(node, value, first: id(offset), last: id(offset + covers - 1), next: next))
                    }
                }
                offset += length
            }
            guard terminated else { continue }
            let newline = id(offset)
            var props = paragraph.props
            let tabs = props.tabs
            props.tabs = []
            let fields = TextEditing.presentFields(props)
            if !fields.isEmpty {
                builder.append(Ops.set(node, fields.map { TextFields.paragraph(newline).child($0) }, values: TextEditing.paragraphValues(props, newline: true)))
            }
            if !tabs.isEmpty, let keys = try? PathEditing.keys(between: nil, and: nil, count: tabs.count) {
                let copies = tabs.map { tab in
                    var stop = tab
                    stop.clearID()
                    return stop
                }
                builder.append(Ops.elementInsert(node, TextFields.paragraph(newline).child(TextFields.tabsField), positions: keys,
                                                 values: TextEditing.paragraphValues(.with { $0.tabs = copies }, newline: true)))
            }
            offset += 1
        }
    }
}

/// The largest merge change: ops per change of a merge (crdt-model.adoc's change cap).
public enum MergeChunking {
    public static let maxOps = 10_000

    /// The records of `indices` split into chunks whose changes stay within `maxOps`, from the
    /// ops one output page takes (`opsPerPage`) and `perPage` records per page.
    public static func chunks(_ indices: [Int], opsPerPage: Int, perPage: Int) -> [[Int]] {
        guard !indices.isEmpty else { return [] }
        let pagesPerChunk = max(1, maxOps / max(opsPerPage, 1))
        let size = max(1, pagesPerChunk * max(perPage, 1))
        return stride(from: 0, to: indices.count, by: size).map { Array(indices[$0..<min($0 + size, indices.count)]) }
    }
}

extension Document {
    /// What a merge to pages did.
    public struct MergeToPagesResult: Sendable {
        /// The pages created, in page order (empty when cancelled).
        public var pages: [OpID]
        /// Coercion problems of the records merged.
        public var issues: [MergeIssue]
        public var cancelled: Bool
    }

    /// *Merge to Pages*: every chunk of `MergeToPages` in one undo group, one step "Merge N
    /// records to pages"; `progress(done, total)` is called after each chunk and returning false
    /// cancels, which undoes the chunks made so far (the ordinary undo path).
    @discardableResult
    public func mergeToPages(templates: [OpID], records: RecordSet, options: MergeOptions = MergeOptions(), selection: [OpID] = [],
                             images: MergeImageResolver? = nil, fitted: [MergeFitKey: MergeText] = [:],
                             progress: @MainActor (Int, Int) -> Bool = { _, _ in true }) async throws -> MergeToPagesResult {
        let indices = options.records.indices(count: records.count)
        guard !indices.isEmpty else { return MergeToPagesResult(pages: [], issues: [], cancelled: false) }
        // Measure one page's ops with a dry run to size the chunks.
        let probe = MergeToPages(templates: templates, records: records, indices: Array(indices.prefix(options.layout.perPage)), options: options,
                                 selection: selection, images: images, fitted: fitted)
        let state = self.state
        var scratch = ChangeBuilder(replica: replica, startCounter: 1)
        try probe.execute(&scratch, state: state)
        let chunks = MergeChunking.chunks(indices, opsPerPage: max(1, scratch.ops.count), perPage: options.layout.perPage)
        var pages: [OpID] = []
        var done = 0
        var number = 1
        beginGroup()
        var cancelled = false
        do {
            for chunk in chunks {
                let command = MergeToPages(templates: templates, records: records, indices: chunk, options: options, selection: selection,
                                           after: pages.last, firstNumber: number, total: indices.count, images: images, fitted: fitted)
                if let change = try await perform(command) {
                    let created = zip(change.ops, change.opIDs).compactMap { op, id -> OpID? in
                        if case .create(let create)? = op.op, case .page? = create.props.kind { return id }
                        return nil
                    }
                    pages += created
                    number += created.count
                }
                done += chunk.count
                if !progress(done, indices.count) {
                    cancelled = true
                    break
                }
            }
        } catch {
            endGroup()
            throw error
        }
        endGroup()
        if cancelled {
            try await undo()
            return MergeToPagesResult(pages: [], issues: [], cancelled: true)
        }
        let merged = Set(indices.map { $0 + 1 })
        return MergeToPagesResult(pages: pages, issues: records.issues.filter { merged.contains($0.record) }, cancelled: false)
    }
}
