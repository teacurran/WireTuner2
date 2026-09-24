import Foundation
import WTCRDT
import WTGeometry
import WTProto
import WTRender

// DOC-010: master pages (master-pages.adoc, "Data model", "Merge semantics" and "Client").  A
// master's objects are ordinary objects under layers with `CommonProps.canvas` naming the
// master, in coordinates relative to the master's top-left corner.  A child page's geometry and
// bleed are the master's while `master` resolves (`Page.geometry`, the masking read rule); its
// own registers are never touched by master edits.

/// Reading master content.
public enum MasterContent {
    /// The live objects on the canvas of `master`, by layer in layer order, each layer's in
    /// stacking order (bottom first).
    public static func objects(of master: OpID, in state: EngineState) -> [(layer: OpID, objects: [OpID])] {
        state.liveChildren(WellKnown.layers).filter { state.nodeKind($0) == .layer }.compactMap { layer in
            let objects = state.liveChildren(layer).filter { node in
                guard let common = NodeValues.common(state.props(node)), common.hasCanvas else { return false }
                return OpID(common.canvas.id) == master
            }
            return objects.isEmpty ? nil : (layer, objects)
        }
    }

    /// The master a release change's label names (`[master:<counter>:<replica>]` at its end), for
    /// `WTSync`'s release-overlap detection (DOC-013).
    public static func releasedMaster(fromLabel label: String) -> OpID? {
        guard label.hasSuffix("]"), let open = label.range(of: "[master:", options: .backwards) else { return nil }
        let body = label[open.upperBound..<label.index(before: label.endIndex)]
        let parts = body.split(separator: ":")
        guard parts.count == 2, let counter = UInt64(parts[0]), let replica = UInt64(parts[1]) else { return nil }
        return OpID(counter: counter, replica: replica)
    }

    /// The label tag naming `master`.
    public static func tag(_ master: OpID) -> String {
        "[master:\(master.counter):\(master.replica)]"
    }
}

enum MasterEditing {
    static func master(_ id: OpID, in list: PageList) throws -> MasterPage {
        guard let master = list.master(id) else { throw PageSetupError.notAPage(id) }
        return master
    }

    /// "Master N", N one more than the largest existing "Master K".
    static func nextName(_ list: PageList) -> String {
        let numbers = list.masters.compactMap { master -> Int? in
            guard master.name.hasPrefix("Master ") else { return nil }
            return Int(master.name.dropFirst("Master ".count))
        }
        return "Master \((numbers.max() ?? 0) + 1)"
    }

    /// Creates a master page with `geometry` and `bleed` after the last master.
    static func create(name: String, geometry: PageGeometry, bleed: Double, state: EngineState, builder: inout ChangeBuilder) throws -> OpID {
        let last = state.store.children(WellKnown.masters).last.flatMap { state.store.placement($0)?.position }
        let key = try PathEditing.keys(between: last, and: nil, count: 1)[0]
        return builder.append(Ops.create(parent: WellKnown.masters, position: key, props: MasterPageFields.values {
            $0.common.name = String(name.prefix(256))
            $0.geometry = geometry.stored
            $0.bleed = bleed
        }))
    }
}

/// Options menu *New Master Page*: a master with the page's effective geometry and bleed (its
/// master's, for a child), named "Master N".  "New master page".
public struct NewMasterPage: Command {
    public var page: OpID?
    public var name: String?
    public var label: String { "New master page" }

    public init(from page: OpID? = nil, name: String? = nil) {
        self.page = page
        self.name = name
    }

    public func execute(_ builder: inout ChangeBuilder, state: EngineState) throws {
        let list = PageList(state)
        let source = try page.map { try PageEditing.page($0, in: list) } ?? list.pages[0]
        _ = try MasterEditing.create(name: name ?? MasterEditing.nextName(list), geometry: source.geometry, bleed: source.bleed, state: state, builder: &builder)
    }
}

/// Options menu *Convert to Master Page*: one change creating a master from the page's settings,
/// moving every top-level object on the page onto the master's canvas (`canvas` = master,
/// transform translated by -origin) and making the page its child.  "Convert to master page".
public struct ConvertToMasterPage: Command {
    public var page: OpID
    public var label: String { "Convert to master page" }

    public init(_ page: OpID) {
        self.page = page
    }

    public func execute(_ builder: inout ChangeBuilder, state: EngineState) throws {
        let list = PageList(state)
        let source = try PageEditing.page(page, in: list)
        let objects = PageObjects.objects(on: source, in: state, pages: list).map(\.id)
        let node = try PageEditing.materialize(source.id, in: list, builder: &builder)
        let master = try MasterEditing.create(name: MasterEditing.nextName(list), geometry: source.geometry, bleed: source.bleed, state: state,
                                              builder: &builder)
        let shift = Vector(dx: -source.origin.x, dy: -source.origin.y)
        for object in objects {
            guard let kind = state.nodeKind(object) else { continue }
            let toParent = Objects.parentTransform(of: object, in: state).inverse
            let moved = Objects.transform(of: object, in: state).concatenating(.translation(toParent.apply(shift)))
            let value = moved.isIdentity ? Wiretuner_Doc_V1_Transform() : PathEditing.proto(moved)
            builder.append(Ops.set(object, [CommonFields.canvas(kind), CommonFields.transform(kind)], values: NodeValues.common(kind: kind) {
                $0.canvas.id = master.proto
                $0.transform = value
            }))
        }
        builder.append(Ops.set(node, [PageFields.master], values: PageFields.values { $0.master.id = master.proto }))
    }
}

/// The *Master Page* pop-up or a drop from the Library panel: `page.master` on each page.  The
/// pages' own geometry and bleed stay as they were, masked while the master resolves.  "Apply
/// master page".
public struct ApplyMasterPage: Command {
    public var master: OpID
    public var pages: [OpID]
    public var label: String { "Apply master page" }

    public init(_ master: OpID, to pages: [OpID]) {
        self.master = master
        self.pages = pages
    }

    public func execute(_ builder: inout ChangeBuilder, state: EngineState) throws {
        let list = PageList(state)
        _ = try MasterEditing.master(master, in: list)
        for id in pages {
            let page = try PageEditing.page(id, in: list)
            guard page.master != master else { continue }
            let node = try PageEditing.materialize(page.id, in: list, builder: &builder)
            builder.append(Ops.set(node, [PageFields.master], values: PageFields.values { $0.master.id = master.proto }))
        }
    }
}

/// The *Master Page* pop-up's *None*: detaches pages from their master.  The master's geometry and
/// bleed are first written into each page's own registers so nothing jumps.  "Detach from master
/// page".
public struct DetachFromMaster: Command {
    public var pages: [OpID]
    public var label: String { "Detach from master page" }

    public init(_ pages: [OpID]) {
        self.pages = pages
    }

    public func execute(_ builder: inout ChangeBuilder, state: EngineState) throws {
        let list = PageList(state)
        for id in pages {
            let page = try PageEditing.page(id, in: list)
            guard page.isChild else { continue }
            builder.append(Ops.set(page.id, [PageFields.geometry, PageFields.bleed, PageFields.master], values: PageFields.values {
                $0.geometry = page.geometry.stored
                $0.bleed = page.bleed
            }))
        }
    }
}

/// Options menu *Release Child Page*: for each page, one step of one change -- `master` unset,
/// the master's geometry and bleed written into the page, and on every layer holding master
/// objects a group at the bottom of the layer (canvas unset) of deep copies of them, translated
/// by the page's origin.  The label names the page and master and ends with the
/// `[master:<id>]` tag `WTSync` reads.  Undo removes the copies and restores `master`.
public struct ReleaseChildPages: Command {
    public var pages: [OpID]
    private var described: String = ""

    public init(_ pages: [OpID]) {
        self.pages = pages
    }

    /// The command with its label written from `state` ("Release page 2 from Master 1
    /// [master:5:10]").
    public init(_ pages: [OpID], in state: EngineState) {
        self.pages = pages
        let list = PageList(state)
        guard let page = pages.first.flatMap({ list[$0] }), let master = page.master.flatMap(list.master) else { return }
        let subject = pages.count == 1 ? "page \(page.number)" : "\(pages.count) pages"
        described = "Release \(subject) from \(master.name.isEmpty ? "master page" : master.name) \(MasterContent.tag(master.id))"
    }

    public var label: String { described.isEmpty ? "Release child page" : described }

    public func execute(_ builder: inout ChangeBuilder, state: EngineState) throws {
        let list = PageList(state)
        for id in pages {
            let page = try PageEditing.page(id, in: list)
            guard let master = page.master else { continue }
            builder.append(Ops.set(page.id, [PageFields.geometry, PageFields.bleed, PageFields.master], values: PageFields.values {
                $0.geometry = page.geometry.stored
                $0.bleed = page.bleed
            }))
            for (layer, objects) in MasterContent.objects(of: master, in: state) {
                let first = state.store.children(layer).first.flatMap { state.store.placement($0)?.position }
                let key = try PathEditing.keys(between: nil, and: first, count: 1)[0]
                var group = Wiretuner_Doc_V1_NodeProps()
                group.group.common.name = "Released master content"
                group.group.common.transform = PathEditing.proto(.translation(Vector(dx: page.origin.x, dy: page.origin.y)))
                let groupID = builder.append(Ops.create(parent: layer, position: key, props: group))
                var previous: [UInt8]?
                for object in objects {
                    guard let kind = state.nodeKind(object) else { continue }
                    let childKey = try PathEditing.keys(between: previous, and: nil, count: 1)[0]
                    previous = childKey
                    let copy = try NodeCopier.create(NodeTree(object, state: state), parent: groupID, position: childKey, schema: state.schema,
                                                     builder: &builder)
                    // Clears the copy's `canvas`: it is page content now.
                    builder.append(Ops.set(copy, [CommonFields.canvas(kind)], values: Wiretuner_Doc_V1_NodeProps()))
                }
            }
        }
    }
}

/// Deletes a master page (`deleted`, restorable).  Children keep their reference, which dangles
/// and reads unset: they show their own geometry again.  The master's objects stay with it.
/// "Delete master page".
public struct DeleteMasterPage: Command {
    public var master: OpID
    public var label: String { "Delete master page" }

    public init(_ master: OpID) {
        self.master = master
    }

    public func execute(_ builder: inout ChangeBuilder, state: EngineState) throws {
        _ = try MasterEditing.master(master, in: PageList(state))
        builder.append(Ops.setDeleted(master))
    }
}

/// Renames a master page (or a page: both labels are `CommonProps.name`).  "Rename master page"
/// / "Rename page".
public struct RenamePage: Command {
    public var page: OpID
    public var name: String
    private var isMaster = false

    public init(_ page: OpID, to name: String, in state: EngineState? = nil) {
        self.page = page
        self.name = name
        isMaster = state.map { PageList($0).master(page) != nil } ?? false
    }

    public var label: String { isMaster ? "Rename master page" : "Rename page" }

    public func execute(_ builder: inout ChangeBuilder, state: EngineState) throws {
        let list = PageList(state)
        let value = String(name.prefix(256))
        if list.master(page) != nil {
            builder.append(Ops.set(page, [MasterPageFields.name], values: MasterPageFields.values { $0.common.name = value }))
            return
        }
        let current = try PageEditing.page(page, in: list)
        let node = try PageEditing.materialize(current.id, in: list, builder: &builder)
        builder.append(Ops.set(node, [PageFields.name], values: PageFields.values { $0.common.name = value }))
    }
}
