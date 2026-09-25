import AppKit
import Observation
import WTCRDT
import WTGeometry
import WTModel
import WTProto
import WTRender

/// A hose set outside any document: a library bundle read into a scratch state of its own, where
/// the document commands edit it and the sheet and the tool's overlay read it
/// (graphic-hose.adoc, "Where hoses live").
enum HoseScratch {
    /// Applies `command` to `state` as a local change of replica 1.
    static func apply(_ command: any WTModel.Command, to state: inout EngineState) throws {
        var builder = ChangeBuilder(replica: 1, startCounter: state.clock.peek)
        try command.execute(&builder, state: state)
        var change = Wiretuner_Doc_V1_Change()
        change.replica = 1
        change.startCounter = builder.startCounter
        change.label = command.label
        change.ops = builder.ops
        _ = state.applyLocal(change)
    }

    /// `bundle` as the one set of a scratch state.
    static func open(_ bundle: HoseBundle) -> (state: EngineState, set: HoseSet)? {
        var state = EngineState()
        try? apply(ImportHoseSet(bundle), to: &state)
        return HoseSets.list(in: state).first.map { (state, $0) }
    }

    /// `bundle` after the command `edit` makes for its set; the note (the library identity) is
    /// kept.
    static func edited(_ bundle: HoseBundle, by edit: (OpID) -> any WTModel.Command) throws -> HoseBundle {
        var state = EngineState()
        try apply(ImportHoseSet(bundle), to: &state)
        // The copy just made: the scratch state's one set.
        let set = state.liveChildren(HoseFields.collection)[0]
        try apply(edit(set), to: &state)
        var tree = HoseSets.tree(set, in: state)
        tree.props.hoseSet.common.note = bundle.tree.props.hoseSet.common.note
        return try HoseBundle(tree: tree)
    }

    /// `bundle` renamed, with a fresh library identity when `identity` is given.
    static func renamed(_ bundle: HoseBundle, to name: String, identity: UUID? = nil) -> HoseBundle {
        var copy = bundle
        copy.tree.props.hoseSet.common.name = name
        if let identity { copy.tree.props.hoseSet.common.note = HoseFields.libraryPrefix + identity.uuidString }
        return copy
    }
}

/// What the Graphic Hose tool and sheet share (graphic-hose.adoc; DRAW-039, DRAW-040): the chosen
/// hose -- one of the front document's sets or a library hose -- the library's bundles, and the
/// sheet's state and actions: the *Sets* pop-up's choice and its *New…*, *Duplicate…*, *Rename…*,
/// *Delete…* and *Restore default hoses*, the *Contents* pop-up, btn:[Paste In], btn:[Remove], the
/// options and `.wthose` drops.  A document set is edited with the document commands (one change
/// each); a library hose by the same commands on a scratch copy written back to its bundle.
@MainActor
@Observable
final class GraphicHoseModel {
    /// A hose to spray with.
    enum Choice: Hashable {
        case document(OpID)
        case library(URL)
    }

    /// Where a new or duplicated set is kept.
    enum Location: String, CaseIterable {
        case document, library

        var title: String { self == .document ? "In this document" : "In my library" }
    }

    /// The name prompt the *Sets* pop-up's items open.
    enum Naming: Equatable {
        case new, duplicate, rename
    }

    enum Page: String, CaseIterable {
        case hose, options

        var title: String { self == .hose ? "Hose" : "Options" }
    }

    /// The chosen hose with what acting on it needs: a document set's id, a library hose's entry
    /// and bundle.
    enum Resolved {
        case document(OpID)
        case library(HoseLibrary.Entry, HoseBundle)
    }

    /// What the tool sprays from: the set, the state it lives in, and -- for a library hose the
    /// document does not have yet -- the bundle to copy in first.
    struct Source {
        let set: HoseSet
        let state: EngineState
        let bundle: HoseBundle?
    }

    let selection: ActiveSelection
    let library: HoseLibrary
    /// The chosen hose; nil takes the first document set, else the first library hose.
    var chosen: Choice?
    private(set) var entries: [HoseLibrary.Entry] = []
    private(set) var bundles: [URL: HoseBundle] = [:]
    var page = Page.hose
    /// The *Contents* pop-up's object, by position.
    var contentsIndex = 0
    var naming: Naming?
    var nameText = ""
    var location = Location.document
    /// Why the last action did nothing, shown in the sheet.
    private(set) var failure: String?
    /// Counts the front document's changes (views re-read on it).
    private(set) var revision = 0
    /// The random seed of each stroke; replaceable in tests.
    @ObservationIgnored var seed: @MainActor () -> UInt64 = { UInt64.random(in: 0 ... UInt64.max) }
    @ObservationIgnored private var followed: (document: DocumentHandle, token: DocumentHandle.ObservationToken)?

    init(selection: ActiveSelection, library: HoseLibrary) {
        self.selection = selection
        self.library = library
    }

    /// The front document, followed so a remote change to a set updates the sheet.
    var document: DocumentHandle? {
        let document = selection.document
        if followed?.document !== document {
            if let followed { followed.document.stopObserving(followed.token) }
            followed = document.map { document in (document, document.observe { [weak self] _ in self?.revision += 1 }) }
        }
        return document
    }

    private var state: EngineState {
        _ = revision
        return document?.state ?? EngineState()
    }

    /// The document's sets, in sibling order.
    var documentSets: [HoseSet] { HoseSets.list(in: state) }

    /// The hose the tool and sheet show: the chosen one while it exists.
    var choice: Choice? {
        let sets = documentSets
        switch chosen {
        case .document(let id)? where sets.contains(where: { $0.id == id }): return chosen
        case .library(let url)? where entries.contains(where: { $0.url == url }): return chosen
        default: break
        }
        if let first = sets.first { return .document(first.id) }
        return entries.first.map { .library($0.url) }
    }

    /// The chosen hose resolved (a listed library hose always has its bundle: `show` lists only
    /// the ones it read).
    var resolved: Resolved? {
        switch choice {
        case .document(let id)?: .document(id)
        case .library(let url)?: entries.first { $0.url == url }.map { .library($0, bundles[$0.url]!) }
        case nil: nil
        }
    }

    /// The chosen hose's name.
    var choiceName: String {
        switch resolved {
        case .document(let id)?: documentSets.filter { $0.id == id }.map(\.name).joined()
        case .library(let entry, _)?: entry.name
        case nil: ""
        }
    }

    /// The chosen hose as a set: a document set in the document's state, a library hose in a
    /// scratch state (or, when the document already has a copy, that copy).
    var shown: (set: HoseSet, state: EngineState, bundle: HoseBundle?)? {
        let state = state
        switch resolved {
        case .document(let id)?:
            return HoseSets.set(id, in: state).map { ($0, state, nil) }
        case .library(_, let bundle)?:
            if let id = bundle.libraryID, let copy = HoseSets.set(libraryID: id, in: state) { return (copy, state, nil) }
            return HoseScratch.open(bundle).map { ($0.set, $0.state, bundle) }
        case nil:
            return nil
        }
    }

    /// What a stroke sprays from, or why it cannot.
    func source() -> Result<Source, HoseSourceError> {
        guard document != nil else { return .failure(.noDocument) }
        guard let shown else { return .failure(.noHose) }
        guard !shown.set.objects.isEmpty else { return .failure(.empty) }
        return .success(Source(set: shown.set, state: shown.state, bundle: shown.bundle))
    }

    // MARK: The library

    /// Re-reads the library's bundles (and loads each one's contents).
    @discardableResult
    func refreshLibrary() -> Task<Void, Never> {
        let library = library
        return Task { @MainActor [weak self] in
            let entries = await library.entries()
            await self?.show(entries)
        }
    }

    /// The library's bundles as `entries` lists them, loading those not read yet.
    func show(_ entries: [HoseLibrary.Entry]) async {
        var loaded: [URL: HoseBundle] = [:]
        for entry in entries {
            if let bundle = try? await library.load(entry) { loaded[entry.url] = bundle }
        }
        self.entries = entries.filter { loaded[$0.url] != nil }
        bundles = loaded
    }

    // MARK: Actions

    func choose(_ choice: Choice) {
        chosen = choice
        contentsIndex = 0
        failure = nil
    }

    @discardableResult
    private func perform(_ command: any WTModel.Command) -> Task<Wiretuner_Doc_V1_Change?, Never>? {
        if let editing = selection.editing, editing.document === document { return editing.perform(command) }
        return document?.perform(command)
    }

    /// Runs `body` against the library, then re-reads it; a failure is shown in the sheet.
    @discardableResult
    private func withLibrary(_ body: @escaping @MainActor (HoseLibrary) async throws -> Choice?) -> Task<Void, Never> {
        let library = library
        return Task { @MainActor [weak self] in
            do {
                let next = try await body(library)
                await self?.show(await library.entries())
                if let next { self?.choose(next) }
            } catch {
                self?.failure = "\(error)"
            }
        }
    }

    /// *New…*, *Duplicate…* and *Rename…* open the name prompt.
    func beginNaming(_ naming: Naming) {
        guard naming == .new || choice != nil else { return }
        self.naming = naming
        failure = nil
        switch naming {
        case .new: nameText = "Hose"
        case .duplicate: nameText = choiceName + " copy"
        case .rename: nameText = choiceName
        }
        if case .library? = choice, naming == .rename { location = .library }
    }

    func cancelNaming() {
        naming = nil
    }

    /// The prompt's btn:[Save].
    @discardableResult
    func commitNaming() -> Task<Void, Never>? {
        guard let naming else { return nil }
        self.naming = nil
        let name = nameText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else {
            failure = "A hose needs a name"
            return nil
        }
        switch (naming, resolved, location) {
        case (.new, _, .document):
            return documentTask(perform(CreateHoseSet(name: name)))
        case (.new, _, .library):
            return withLibrary { library in
                var props = Wiretuner_Doc_V1_NodeProps()
                props.hoseSet.common.name = name
                return .library(try await library.save(try HoseBundle(tree: NodeTree(props: props, children: []))).url)
            }
        case (.duplicate, .document(let id)?, .document):
            return documentTask(perform(DuplicateHoseSet(id, name: name)))
        case (.duplicate, .document(let id)?, .library):
            let state = state
            return withLibrary { library in
                .library(try await library.save(HoseScratch.renamed(try HoseBundle(set: id, in: state), to: name, identity: UUID())).url)
            }
        case (.duplicate, .library(_, let bundle)?, .document):
            var copy = HoseScratch.renamed(bundle, to: name)
            copy.tree.props.hoseSet.common.note = ""
            return documentTask(perform(ImportHoseSet(copy)))
        case (.duplicate, .library(_, let bundle)?, .library):
            return withLibrary { library in .library(try await library.save(HoseScratch.renamed(bundle, to: name, identity: UUID())).url) }
        case (.rename, .document(let id)?, _):
            return documentTask(perform(RenameHoseSet(id, name: name)))
        case (.rename, .library(let entry, let bundle)?, _):
            return withLibrary { library in .library(try await library.replace(entry, with: HoseScratch.renamed(bundle, to: name)).url) }
        default:
            return nil
        }
    }

    /// Waits for a document change; a refused one (nil) is shown in the sheet.
    private func documentTask(_ task: Task<Wiretuner_Doc_V1_Change?, Never>?) -> Task<Void, Never>? {
        guard let task else { return nil }
        return Task { @MainActor [weak self] in
            let change = await task.value
            if change == nil { self?.failure = "The hose could not be changed" }
            if let created = change?.createdObjects.first { self?.choose(.document(created)) }
        }
    }

    /// *Delete…*.
    @discardableResult
    func delete() -> Task<Void, Never>? {
        switch resolved {
        case .document(let id)?:
            chosen = nil
            return documentTask(perform(DeleteHoseSet(id)))
        case .library(let entry, _)?:
            chosen = nil
            return withLibrary { library in
                try await library.delete(entry)
                return nil
            }
        case nil:
            return nil
        }
    }

    /// *Restore default hoses*.
    @discardableResult
    func restoreDefaults() -> Task<Void, Never> {
        withLibrary { library in
            try await library.restoreDefaults()
            return nil
        }
    }

    /// `.wthose` bundles dropped on the sheet go into the library.
    @discardableResult
    func importBundles(_ urls: [URL]) -> Task<Void, Never>? {
        let hoses = urls.filter { $0.pathExtension == HoseBundle.pathExtension }
        guard !hoses.isEmpty else { return nil }
        return withLibrary { library in
            var last: Choice?
            for url in hoses { last = .library(try await library.importBundle(at: url).url) }
            return last
        }
    }

    /// Edits the chosen hose with the command `edit` makes for its set: one change on a document
    /// set, a rewrite of the bundle for a library hose.
    @discardableResult
    func edit(_ edit: @escaping (OpID) -> any WTModel.Command) -> Task<Void, Never>? {
        switch resolved {
        case .document(let id)?:
            return documentTask(perform(edit(id)))
        case .library(let entry, let bundle)?:
            return withLibrary { library in .library(try await library.replace(entry, with: try HoseScratch.edited(bundle, by: edit)).url) }
        case nil:
            return nil
        }
    }

    /// btn:[Paste In]: the objects on the clipboard become the next object of the set.
    @discardableResult
    func pasteIn(from pasteboard: (any ObjectPasteboard)? = nil) -> Task<Void, Never>? {
        guard let bytes = (pasteboard ?? selection.editing?.pasteboard)?.read(), let payload = ClipboardPayload(decoding: bytes), !payload.isEmpty else {
            failure = "Copy the artwork for an object first"
            return nil
        }
        guard (shown?.set.objects.count ?? 0) < HoseFields.maximumObjects else {
            failure = "A hose holds at most ten objects"
            return nil
        }
        return edit { AddHoseObject($0, payload: payload) }
    }

    /// btn:[Remove]: the object the *Contents* pop-up shows.
    @discardableResult
    func removeObject() -> Task<Void, Never>? {
        guard let shown, contentsIndex < shown.set.objects.count else { return nil }
        let position = contentsIndex
        contentsIndex = max(contentsIndex - 1, 0)
        return edit { set in RemoveHoseObject(set, object: shown.set.objects[position]) }
    }

    /// One option changed in the *Options* view.
    @discardableResult
    func setOption(_ option: HoseOption) -> Task<Void, Never>? {
        edit { SetHoseOptions($0, [option]) }
    }

    // MARK: Contents

    /// The *Contents* pop-up's titles: *Object-1*, *Object-2*, ...; extras past the tenth after.
    var contents: [String] {
        guard let shown else { return [] }
        return (0 ..< shown.set.objects.count + shown.set.extras.count).map { "Object-\($0 + 1)" }
    }

    /// The object the *Contents* pop-up shows, drawn to fit `size` points (2× pixels).
    func contentsPreview(size: Size = Size(width: 160, height: 100)) -> CGImage? {
        guard let shown else { return nil }
        let objects = shown.set.objects + shown.set.extras
        guard contentsIndex < objects.count else { return nil }
        let list = DisplayList(canvas: "hose-contents", items: HosePreview.items(of: objects[contentsIndex], in: shown.state))
        guard let bounds = list.bounds, bounds.width > 0 || bounds.height > 0 else { return nil }
        let zoom = min(size.width / max(bounds.width, 1), size.height / max(bounds.height, 1)) * 0.9
        let origin = Point(x: bounds.center.x - size.width / 2 / zoom, y: bounds.center.y - size.height / 2 / zoom)
        return CoreGraphicsRenderer(background: .white).renderBitmap(list, viewport: Viewport(scrollOrigin: origin, zoom: zoom, size: size), scale: 2)
    }
}

/// Why the Graphic Hose tool cannot spray.
enum HoseSourceError: Error, Equatable {
    case noDocument, noHose, empty

    var message: String {
        switch self {
        case .noDocument: "Open a document to spray"
        case .noHose: "Choose a hose in the Graphic Hose sheet"
        case .empty: "This hose has no objects: paste some in from the Graphic Hose sheet"
        }
    }
}
