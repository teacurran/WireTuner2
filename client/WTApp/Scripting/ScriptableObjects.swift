import AppKit
import WTCRDT
import WTGeometry
import WTInterchange
import WTModel
import WTProto
import WTRender

// DOC-026: the scripting dictionary's objects (scripting.adoc, "AppleScript" and "Client").
// Cocoa scripting reads and writes them by key-value coding on the main thread; every read goes
// through `WTModel.ScriptObjects` on the document's merged state, every set and command runs the
// `WTModel` command it names under the label "Script: <what>", one change and one undo step.  A
// command waits (the Apple event is suspended) until its change is applied, so the next line of a
// script sees it.  Objects are addressed by id (`NSUniqueIDSpecifier`): a node's id is
// `<counter>-<replica>`, stable across runs.

/// What the dictionary reaches in the app: the open documents and the window-level actions.
@MainActor
final class ScriptingHost {
    static let shared = ScriptingHost()

    /// The open documents, in window order.
    var documents: @MainActor () -> [DocumentHandle] = { [] }
    /// Opens a library document by name or id (bringing its window forward); nil when there is
    /// none or it cannot be opened (offline, not on this Mac).
    var open: @MainActor (String) -> DocumentHandle? = { _ in nil }
    /// Opens a file (a package, or an import).
    var openFile: @MainActor (URL) -> Bool = { _ in false }
    /// A new document named `name` (`make new document`), from the default template.
    var create: @MainActor (String) -> DocumentHandle? = { _ in nil }
    var close: @MainActor (DocumentHandle) -> Void = { _ in }
    /// Whether the account is connected (`share link` needs it).
    var isOnline: @MainActor () -> Bool = { false }
    /// The caller's role on a document; a viewer or commenter cannot change it.
    var role: @MainActor (DocumentHandle) -> LibraryDocument.Role? = { _ in .owner }
    /// Shows page number `index` (1-based) in the document's window.
    var goToPage: @MainActor (DocumentHandle, Int) -> Bool = { _, _ in false }
    var export: @MainActor (DocumentHandle, ExportFormat, URL) async -> String? = { _, _, _ in "Export is not available" }
    /// Prints a document, with the named print preset when given; `label` names the change a
    /// preset's settings are written in.  Returns the reason it cannot, or nil.
    var print: @MainActor (DocumentHandle, _ preset: String?, _ label: String) -> String? = { _, _, _ in "Printing is not available" }
    var shareLink: @MainActor (DocumentHandle) async throws -> String = { _ in throw ScriptFailure(ScriptFailure.offline, "Share Link needs a connection") }

    /// The wrapper of an open document.
    func document(_ handle: DocumentHandle) -> WTScriptDocument { WTScriptDocument(handle: handle) }

    /// `export` and *Export Document* through menu:File[Export…]'s pipeline
    /// (`ExportController.perform`, the format's default options, the document's window): the
    /// same file the menu writes for the same settings.
    static func exporting(through exports: ExportController, window: @escaping @MainActor (DocumentHandle) -> DocumentWindowController?)
        -> @MainActor (DocumentHandle, ExportFormat, URL) async -> String? {
        { handle, format, url in
            guard let window = window(handle) else { return "The document has no window" }
            var settings = ExportSettings()
            settings.format = format
            switch await exports.perform(settings, to: url, from: window) {
            case .exported: return nil
            case .cancelled: return "The export was cancelled"
            case let .failed(message): return message
            }
        }
    }
}

/// A specifier carried out of `MainActor.assumeIsolated` (Cocoa scripting asks on the main thread).
struct SpecifierBox: @unchecked Sendable {
    let value: NSScriptObjectSpecifier?
    init(_ value: NSScriptObjectSpecifier?) { self.value = value }
}

/// A scripting error: Apple's codes where one fits, and the documented `errOfflineRequired`.
struct ScriptFailure: Error, Equatable {
    static let offline = 1001
    static let notModifiable = -10003
    static let privilege = -10004
    static let noSuchObject = -1728
    static let notHandled = -1708
    static let invalidParameter = -50

    var number: Int
    var message: String

    init(_ number: Int, _ message: String) {
        self.number = number
        self.message = message
    }

    /// The code and message of a model error.
    init(_ error: any Error) {
        switch error {
        case let failure as ScriptFailure: self = failure
        case let readOnly as ScriptObjects.ReadOnly: self.init(Self.notModifiable, readOnly.description)
        case let invalid as ScriptObjects.InvalidValue: self.init(Self.invalidParameter, invalid.description)
        case let unavailable as ScriptUnavailable: self.init(Self.notHandled, "\(unavailable)")
        case let missing as ScriptObjects.NoSuchObject: self.init(Self.noSuchObject, missing.description)
        default: self.init(Self.invalidParameter, String(describing: error))
        }
    }
}

/// Running a script's edits: the permission check, the labelled command, the suspended event.
@MainActor
enum ScriptRun {
    /// The last failure reported (what the Apple event carried; tests read it).
    private(set) static var lastFailure: ScriptFailure?

    static func fail(_ failure: ScriptFailure) {
        lastFailure = failure
        if let command = NSScriptCommand.current() {
            command.scriptErrorNumber = failure.number
            command.scriptErrorString = failure.message
        }
    }

    static func fail(_ error: any Error) { fail(ScriptFailure(error)) }

    static func clear() { lastFailure = nil }

    /// Performs `command` on `handle` as "Script: <label>": one change, one undo step.  The
    /// current Apple event waits for it and then answers `result` of the change.  A viewer or
    /// commenter is refused with the role required.
    @discardableResult
    static func perform(_ command: any WTModel.Command, label: String, on handle: DocumentHandle,
                        result: @escaping @MainActor (Wiretuner_Doc_V1_Change?) -> Any? = { _ in nil }) -> Task<Wiretuner_Doc_V1_Change?, Never>? {
        let role = ScriptingHost.shared.role(handle)
        guard role == nil || role == .owner || role == .editor else {
            fail(ScriptFailure(ScriptFailure.privilege, "Changing “\(handle.title)” needs the editor role"))
            return nil
        }
        let task = handle.perform(ScriptLabelled(command, label: "Script: \(label)"))
        // The result also binds a made object to its node, so it runs outside an Apple event too.
        let event = NSScriptCommand.current().map(ScriptEvent.init)
        event?.command.suspendExecution()
        Task { @MainActor in
            let value = result(await task.value)
            event?.command.resumeExecution(withResult: value)
        }
        return task
    }

    /// `{a, b}` as numbers.
    static func numbers(_ value: Any?) -> [Double]? {
        guard let array = value as? [Any] else { return nil }
        let numbers = array.compactMap { ($0 as? NSNumber)?.doubleValue }
        return numbers.count == array.count ? numbers : nil
    }
}

/// A document (`document`).
@objc(WTScriptDocument)
@MainActor
final class WTScriptDocument: NSObject {
    let handle: DocumentHandle?
    /// `make new document with properties {name: …}` before it exists.
    @objc var name: String

    init(handle: DocumentHandle) {
        self.handle = handle
        name = handle.title
    }

    override init() {
        handle = nil
        name = LibraryModel.untitled
    }

    @objc var uniqueID: String { handle?.id ?? "" }

    var state: EngineState { handle?.state ?? EngineState() }

    nonisolated override var objectSpecifier: NSScriptObjectSpecifier? {
        MainActor.assumeIsolated { SpecifierBox(specifier) }.value
    }

    private var specifier: NSScriptObjectSpecifier? {
        guard let application = NSScriptClassDescription(for: NSApplication.self) else { return nil }
        return NSUniqueIDSpecifier(containerClassDescription: application, containerSpecifier: nil, key: "scriptDocuments", uniqueID: uniqueID)
    }

    private func nodes(_ collection: String) -> [OpID] { ScriptObjects.list(collection, in: state) ?? [] }

    @objc var scriptPages: [WTScriptPage] { nodes("pages").map { WTScriptPage(document: self, node: $0) } }
    @objc var scriptMasterPages: [WTScriptMasterPage] { nodes("masterPages").map { WTScriptMasterPage(document: self, node: $0) } }
    @objc var scriptLayers: [WTScriptLayer] { nodes("layers").map { WTScriptLayer(document: self, node: $0) } }
    @objc var scriptGraphics: [WTScriptGraphic] { nodes("objects").map { WTScriptGraphic.make(document: self, node: $0) } }
    @objc var scriptTextBlocks: [WTScriptGraphic] { scriptGraphics.filter { $0 is WTScriptTextBlock } }
    @objc var scriptSwatches: [WTScriptSwatch] { nodes("swatches").map { WTScriptSwatch(document: self, node: $0) } }
    @objc var scriptStyles: [WTScriptStyle] { nodes("styles").map { WTScriptStyle(document: self, node: $0) } }

    // MARK: make and delete

    /// `make new page`: one page after the last, of the `page size` given.
    @objc(insertInScriptPages:)
    func insertPage(_ page: WTScriptPage) {
        guard let handle else { return }
        let size = page.pendingSize.map { Size(width: $0[0], height: $0[1]) }
        do {
            let command = try ScriptObjects.addPages(count: 1, size: size, master: page.pendingMaster)
            ScriptRun.perform(command, label: "make page", on: handle) { [weak self] change in
                guard let self, let id = change?.createdNodes.first else { return nil }
                page.bind(document: self, node: id)
                return page
            }
        } catch {
            ScriptRun.fail(error)
        }
    }

    @objc(insertObject:inScriptPagesAtIndex:)
    func insertPage(_ page: WTScriptPage, at index: Int) { insertPage(page) }

    @objc(removeObjectFromScriptPagesAtIndex:)
    func removePage(at index: Int) { remove(nodes("pages"), index, method: "remove", label: "delete page") }

    @objc(removeObjectFromScriptLayersAtIndex:)
    func removeLayer(at index: Int) { remove(nodes("layers"), index, method: "remove", label: "delete layer") }

    @objc(removeObjectFromScriptGraphicsAtIndex:)
    func removeGraphic(at index: Int) { remove(nodes("objects"), index, method: "remove", label: "delete") }

    private func remove(_ ids: [OpID], _ index: Int, method: String, label: String) {
        guard let handle, ids.indices.contains(index) else { return ScriptRun.fail(ScriptFailure(ScriptFailure.noSuchObject, "No such object")) }
        do {
            ScriptRun.perform(try ScriptObjects.calling(ids[index], method, nil, in: state).command, label: label, on: handle)
        } catch {
            ScriptRun.fail(error)
        }
    }

    /// `make new rectangle|ellipse|line|text block at end of graphics with properties {…}`.
    @objc(insertInScriptGraphics:)
    func insertGraphic(_ graphic: WTScriptGraphic) {
        guard let handle else { return }
        guard let kind = graphic.creationKind else {
            return ScriptRun.fail(ScriptFailure(ScriptFailure.notHandled, "Scripts can make rectangles, ellipses, lines and text blocks in version 1"))
        }
        var options: [String: Any] = [:]
        if let position = graphic.pendingPosition { options["x"] = position[0]; options["y"] = position[1] }
        if let text = graphic.pendingContents { options["text"] = text }
        do {
            let command = try ScriptObjects.creating(kind, options)
            ScriptRun.perform(command, label: "make \(kind)", on: handle) { [weak self] change in
                guard let self, let id = change?.createdObjects.first else { return nil }
                graphic.bind(document: self, node: id)
                return graphic
            }
        } catch {
            ScriptRun.fail(error)
        }
    }

    @objc(insertObject:inScriptGraphicsAtIndex:)
    func insertGraphic(_ graphic: WTScriptGraphic, at index: Int) { insertGraphic(graphic) }

    /// `close document …`.
    @objc(handleCloseScriptCommand:)
    func handleClose(_ command: NSCloseCommand) -> Any? {
        if let handle { ScriptingHost.shared.close(handle) }
        return nil
    }
}

/// What every node wrapper shares: the document it is in, its node (nil before `make` has
/// created it), reads through `ScriptObjects.get` and sets through `ScriptObjects.setting`.
@objc(WTScriptNode)
@MainActor
class WTScriptNode: NSObject {
    private(set) weak var document: WTScriptDocument?
    /// Keeps the document wrapper alive while this one is (Cocoa holds only the leaf object).
    private var retained: WTScriptDocument?
    private(set) var node: OpID?

    /// The document's element key this object is found under.
    class var containerKey: String { "scriptGraphics" }

    init(document: WTScriptDocument, node: OpID) {
        self.document = document
        retained = document
        self.node = node
    }

    override init() {}

    func bind(document: WTScriptDocument, node: OpID) {
        self.document = document
        retained = document
        self.node = node
    }

    @objc var uniqueID: String { node.map(ScriptObjects.string) ?? "" }

    var state: EngineState { document?.state ?? EngineState() }

    nonisolated override var objectSpecifier: NSScriptObjectSpecifier? {
        MainActor.assumeIsolated { SpecifierBox(specifier) }.value
    }

    private var specifier: NSScriptObjectSpecifier? {
        guard let document, let container = NSScriptClassDescription(for: WTScriptDocument.self) else { return nil }
        return NSUniqueIDSpecifier(containerClassDescription: container, containerSpecifier: document.objectSpecifier,
                                   key: Self.containerKey, uniqueID: uniqueID)
    }

    func read(_ property: String) -> Any? {
        node.flatMap { ScriptObjects.get($0, property, in: state) }
    }

    /// Sets `property`, labelled "Script: set <name>".
    func write(_ property: String, _ value: Any?, name: String) {
        guard let node, let handle = document?.handle else { return }
        do {
            let edit = try ScriptObjects.setting(node, property, to: value, in: state)
            ScriptRun.perform(edit.command, label: "set \(name)", on: handle)
        } catch {
            ScriptRun.fail(error)
        }
    }

    /// `{width, height}` of a `size` read.
    func pair(_ value: Any?, _ first: String, _ second: String) -> [Double] {
        guard let dictionary = value as? [String: Any] else { return [] }
        return [first, second].compactMap { (dictionary[$0] as? NSNumber)?.doubleValue ?? dictionary[$0] as? Double }
    }
}

/// A page (`page`).
@objc(WTScriptPage)
@MainActor
final class WTScriptPage: WTScriptNode {
    override class var containerKey: String { "scriptPages" }
    /// `make new page with properties {page size: …, master page: …}`.
    var pendingSize: [Double]?
    var pendingMaster: OpID?

    @objc var scriptName: String {
        get { read("name") as? String ?? "" }
        set { write("name", newValue, name: "page name") }
    }

    @objc var scriptIndex: Int { read("number") as? Int ?? 0 }

    @objc var scriptPageSize: [Double] {
        get { pair(read("size"), "width", "height") }
        set {
            guard node != nil else { return pendingSize = newValue.count == 2 ? newValue : nil }
            write("size", newValue, name: "page size")
        }
    }

    @objc var scriptMaster: WTScriptMasterPage? {
        get {
            guard let document, let master = read("master") as? OpID else { return nil }
            return WTScriptMasterPage(document: document, node: master)
        }
        set {
            guard node != nil else { return pendingMaster = newValue?.node }
            write("master", newValue?.node, name: "master page")
        }
    }
}

/// A master page (`master page`).
@objc(WTScriptMasterPage)
@MainActor
final class WTScriptMasterPage: WTScriptNode {
    override class var containerKey: String { "scriptMasterPages" }

    @objc var scriptName: String {
        get { read("name") as? String ?? "" }
        set { write("name", newValue, name: "master page name") }
    }

    @objc var scriptPageSize: [Double] { pair(read("size"), "width", "height") }
}

/// A layer (`layer`).
@objc(WTScriptLayer)
@MainActor
final class WTScriptLayer: WTScriptNode {
    override class var containerKey: String { "scriptLayers" }
    /// `make new layer with properties {name: …}` before it exists.
    var pendingName: String?

    @objc var scriptName: String {
        get { read("name") as? String ?? pendingName ?? "" }
        set {
            guard node != nil else { return pendingName = newValue }
            write("name", newValue, name: "layer name")
        }
    }

    @objc var scriptVisible: Bool {
        get { read("visible") as? Bool ?? false }
        set { write("visible", NSNumber(value: newValue), name: "visible") }
    }

    @objc var scriptLocked: Bool {
        get { read("locked") as? Bool ?? false }
        set { write("locked", NSNumber(value: newValue), name: "locked") }
    }

    @objc var scriptGraphics: [WTScriptGraphic] {
        guard let document, let node else { return [] }
        return ScriptObjects.objects(in: state, under: node).map { WTScriptGraphic.make(document: document, node: $0) }
    }
}

/// An object (`graphic` and its subclasses).
@objc(WTScriptGraphic)
@MainActor
class WTScriptGraphic: WTScriptNode {
    /// `make new … with properties {position: …, contents: …}` before it exists.
    var pendingPosition: [Double]?
    var pendingContents: String?

    /// What `make` creates for this class; nil for the classes scripts cannot make.
    var creationKind: String? { nil }

    /// The wrapper class for the node's kind.
    static func make(document: WTScriptDocument, node: OpID) -> WTScriptGraphic {
        let type: WTScriptGraphic.Type = switch ScriptObjects.kindName(node, in: document.state) {
        case "rectangle": WTScriptRectangle.self
        case "ellipse": WTScriptEllipse.self
        case "path", "polygon": WTScriptPath.self
        case "group": WTScriptGroup.self
        case "text": WTScriptTextBlock.self
        case "image", "placedFile": WTScriptImage.self
        case "instance": WTScriptSymbolInstance.self
        default: WTScriptGraphic.self
        }
        return type.init(document: document, node: node)
    }

    required override init(document: WTScriptDocument, node: OpID) {
        super.init(document: document, node: node)
    }

    required override init() {
        super.init()
    }

    @objc var scriptKind: String { node.map { ScriptObjects.kindName($0, in: state) } ?? "" }

    @objc var scriptName: String {
        get { read("name") as? String ?? "" }
        set { write("name", newValue, name: "name") }
    }

    @objc var scriptNotes: String {
        get { read("notes") as? String ?? "" }
        set { write("notes", newValue, name: "notes") }
    }

    @objc var scriptBounds: [Double] {
        guard let bounds = read("bounds") as? [String: Any] else { return [] }
        return ["x", "y", "width", "height"].compactMap { bounds[$0] as? Double }
    }

    @objc var scriptPosition: [Double] {
        get { pair(read("position"), "x", "y") }
        set {
            guard newValue.count == 2 else { return ScriptRun.fail(ScriptFailure(ScriptFailure.invalidParameter, "A position is {left, top}")) }
            guard node != nil else { return pendingPosition = newValue }
            write("position", ["x": newValue[0], "y": newValue[1]], name: "position")
        }
    }

    @objc var scriptLocked: Bool {
        get { read("locked") as? Bool ?? false }
        set { write("locked", NSNumber(value: newValue), name: "locked") }
    }

    @objc var scriptLayer: WTScriptLayer? {
        get {
            guard let document, let layer = read("layer") as? OpID else { return nil }
            return WTScriptLayer(document: document, node: layer)
        }
        set { write("layer", newValue?.node, name: "layer") }
    }

    @objc var scriptFill: String { read("fill") as? String ?? "" }
    @objc var scriptStroke: String { read("stroke") as? String ?? "" }
}

@objc(WTScriptPath) @MainActor final class WTScriptPath: WTScriptGraphic {}

@objc(WTScriptRectangle) @MainActor final class WTScriptRectangle: WTScriptGraphic {
    override var creationKind: String? { "rectangle" }
}

@objc(WTScriptEllipse) @MainActor final class WTScriptEllipse: WTScriptGraphic {
    override var creationKind: String? { "ellipse" }
}

@objc(WTScriptLine) @MainActor final class WTScriptLine: WTScriptGraphic {
    override var creationKind: String? { "line" }
}

@objc(WTScriptGroup) @MainActor final class WTScriptGroup: WTScriptGraphic {}
@objc(WTScriptImage) @MainActor final class WTScriptImage: WTScriptGraphic {}
@objc(WTScriptSymbolInstance) @MainActor final class WTScriptSymbolInstance: WTScriptGraphic {}

/// A text block (`text block`), whose `contents` is its text.
@objc(WTScriptTextBlock)
@MainActor
final class WTScriptTextBlock: WTScriptGraphic {
    override var creationKind: String? { "text" }

    @objc var scriptContents: String {
        get { read("text") as? String ?? pendingContents ?? "" }
        set {
            guard node != nil else { return pendingContents = newValue }
            write("text", newValue, name: "contents")
        }
    }
}

/// A swatch (`swatch`).
@objc(WTScriptSwatch)
@MainActor
final class WTScriptSwatch: WTScriptNode {
    override class var containerKey: String { "scriptSwatches" }

    @objc var scriptName: String {
        get { read("name") as? String ?? "" }
        set { write("name", newValue, name: "swatch name") }
    }
}

/// A graphic style (`style`), read-only in version 1.
@objc(WTScriptStyle)
@MainActor
final class WTScriptStyle: WTScriptNode {
    override class var containerKey: String { "scriptStyles" }

    @objc var scriptName: String { read("name") as? String ?? "" }
}
