import Foundation
import WTCRDT
import WTGeometry
import WTProto
import WTRender

/// The scriptable object model every scripting surface shares (scripting.adoc, "One command
/// registry"; DATA-011, DOC-026, DOC-027): the collections, the readable properties, and the
/// `WTModel` command each settable property, method and creation runs.  JavaScript's `wt`
/// (`ScriptEnvironment`) and the AppleScript dictionary's wrappers (WTApp) are thin adapters over
/// it, so nothing is scriptable in one language and not another.  Version 1 limits: paths,
/// effects, gradients, symbols, styles and blends read as summaries and are not settable.
public enum ScriptObjects {
    /// A property set, method or creation as the command to run.
    public struct Edit {
        public var command: any Command
        /// Runs at once even inside a transaction (its effect must be visible to the next read).
        public var immediate: Bool
        /// The caller wants the created object's id back (duplicate).
        public var returnsCreated: Bool

        public init(_ command: any Command, immediate: Bool = false, returnsCreated: Bool = false) {
            self.command = command
            self.immediate = immediate
            self.returnsCreated = returnsCreated
        }
    }

    /// A set that version 1 does not allow: the documented error, never a silent no-op.
    public struct ReadOnly: Error, CustomStringConvertible, Hashable {
        public var property: String
        public var kind: String
        public var description: String { "The \(property) of a \(kind) cannot be set by a script in version 1" }

        public init(property: String, kind: String) {
            self.property = property
            self.kind = kind
        }
    }

    /// A method or creation version 1 does not have.
    public struct Unsupported: Error, CustomStringConvertible, Hashable {
        public var call: String
        public var description: String { "\(call) is not available to scripts in version 1" }

        public init(call: String) { self.call = call }
    }

    /// An argument of the wrong type or out of range.
    public struct InvalidValue: Error, CustomStringConvertible, Hashable {
        public var property: String
        public var description: String { "The value given for \(property) is not valid" }

        public init(property: String) { self.property = property }
    }

    // MARK: Kinds and collections

    /// What `kind` reads for node `id`.
    public static func kindName(_ id: OpID, in state: EngineState) -> String {
        kindNames[state.store.kind(id)] ?? "unknown"
    }

    /// The `kind` names by stored kind number.
    public static let kindNames: [UInt32: String] = [
        NodeKind.path.rawValue: "path", NodeKind.rect.rawValue: "rectangle", NodeKind.ellipse.rawValue: "ellipse",
        NodeKind.polygon.rawValue: "polygon", NodeKind.chart.rawValue: "chart", NodeKind.connector.rawValue: "connector",
        NodeKind.group.rawValue: "group", NodeKind.text.rawValue: "text", NodeKind.barcode.rawValue: "barcode",
        NodeKind.instance.rawValue: "instance", NodeKind.placedFile.rawValue: "placedFile", NodeKind.blend.rawValue: "blend",
        NodeKind.extrude.rawValue: "extrude", NodeKind.layer.rawValue: "layer", PageFields.kind: "page",
        MasterPageFields.kind: "masterPage", SwatchFields.kind: "swatch", ScriptFields.kind: "script", ImageKind.kind: "image", 154: "style",
    ]

    /// The ids of a document collection (`pages`, `masterPages`, `layers`, `objects`, `swatches`,
    /// `styles`, `scripts`, `selection`); nil for an unknown name.
    public static func list(_ name: String, in state: EngineState, selection: [OpID] = []) -> [OpID]? {
        switch name {
        case "pages": return PageList(state).pages.filter { !$0.isSynthesized }.map(\.id)
        case "masterPages": return PageList(state).masters.map(\.id)
        case "layers": return LayerOrder(state).layers.filter { !$0.isDeleted }.map(\.id)
        case "objects": return objects(in: state)
        case "swatches": return SwatchList(state).swatches.map(\.id)
        case "styles": return state.liveChildren(OpID.wellKnown(6))
        case "scripts": return DocumentScript.list(state).map(\.id)
        case "selection": return selection.filter(state.isLive)
        default: return nil
        }
    }

    /// Every object on every layer, in stacking order, group members after their group.
    public static func objects(in state: EngineState, under parent: OpID? = nil) -> [OpID] {
        var result: [OpID] = []
        func visit(_ node: OpID) {
            for child in state.liveChildren(node) where Objects.isObject(child, in: state) || state.store.kind(child) == ImageKind.kind {
                result.append(child)
                visit(child)
            }
        }
        if let parent {
            visit(parent)
        } else {
            for layer in LayerOrder(state).layers where !layer.isDeleted { visit(layer.id) }
        }
        return result
    }

    public static func rect(_ rect: Rect) -> [String: Any] {
        ["x": rect.minX, "y": rect.minY, "width": rect.width, "height": rect.height]
    }

    // MARK: Reading

    /// Property `property` of node `id`; nil when the node or property has none.
    public static func get(_ id: OpID, _ property: String, in state: EngineState) -> Any? {
        guard state.store.exists(id) else { return nil }
        let kind = kindName(id, in: state)
        let props = state.props(id)
        let common: Wiretuner_Doc_V1_CommonProps? = {
            if case .image(let image)? = props.kind { return image.common }
            if case .script(let script)? = props.kind { return script.common }
            if case .swatch(let swatch)? = props.kind { return swatch.common }
            return NodeValues.common(props)
        }()
        switch (kind, property) {
        case (_, "kind"): return kind
        case ("page", "name"), ("masterPage", "name"):
            let list = PageList(state)
            return list.pages.first { $0.id == id }?.name ?? list.masters.first { $0.id == id }?.name
        case ("page", "number"): return PageList(state).number(of: id)
        case ("page", "bounds"): return PageList(state).pages.first { $0.id == id }.map { rect($0.rect) }
        case ("page", "size"):
            return PageList(state).pages.first { $0.id == id }.map { ["width": $0.geometry.width, "height": $0.geometry.height] }
        case ("masterPage", "size"):
            return PageList(state).masters.first { $0.id == id }.map { ["width": $0.geometry.width, "height": $0.geometry.height] }
        case ("page", "master"): return PageList(state).pages.first { $0.id == id }?.master
        case ("layer", "visible"): return LayerOrder(state).layer(id)?.visible
        case ("layer", "locked"): return LayerOrder(state).layer(id)?.locked
        case ("layer", "name"): return LayerOrder(state).layer(id)?.name
        case ("swatch", "name"): return SwatchList(state).swatches.first { $0.id == id }?.name
        case ("style", "name"): return props.style.common.name
        case ("script", "source"): return props.script.source
        case ("script", "description"): return props.script.description_p
        case (_, "name"): return common?.name
        case (_, "notes"): return common?.note
        case (_, "locked"): return common?.locked
        case (_, "visible"): return state.isLive(id)
        case (_, "url"): return common?.url
        case (_, "bounds"): return Objects.bounds(of: id, in: state).map(rect)
        case (_, "position"): return Objects.bounds(of: id, in: state).map { ["x": $0.minX, "y": $0.minY] }
        case (_, "size"): return Objects.bounds(of: id, in: state).map { ["width": $0.width, "height": $0.height] }
        case ("text", "text"): return TextNode(id, in: state)?.string
        case ("barcode", "value"): return props.barcode.value
        case ("barcode", "symbology"): return props.barcode.symbology == .code128 ? "code128" : "qr"
        case (_, "layer"): return LayerOrder(state).layer(of: id, in: state)
        case (_, "page"): return Objects.bounds(of: id, in: state).flatMap { PageList(state).page(ofBounds: $0) }?.id
        case (_, "binding"):
            return DataModel(state).binding(of: id, in: state).map { binding in
                ["field": binding.resolved?.displayName ?? "missing", "kind": binding.kind.rawValue] as [String: Any]
            }
        case (_, "fill"), (_, "stroke"):
            // Summaries only in version 1.
            return NodeValues.appearance(props).map { stack in
                property == "fill" ? "\(stack.fills.count) fill\(stack.fills.count == 1 ? "" : "s")" : "\(stack.strokes.count) stroke\(stack.strokes.count == 1 ? "" : "s")"
            }
        default: return nil
        }
    }

    // MARK: Writing

    /// The command setting `property` of `id` to `value`.
    public static func setting(_ id: OpID, _ property: String, to value: Any?, in state: EngineState) throws -> Edit {
        let kind = kindName(id, in: state)
        switch (kind, property) {
        case ("layer", "name"): return Edit(RenameLayer(id, to: try string(value)))
        case ("layer", "visible"): return Edit(SetLayerFlag([id], .visible, try bool(value)))
        case ("layer", "locked"): return Edit(SetLayerFlag([id], .locked, try bool(value)))
        case ("page", "name"), ("masterPage", "name"): return Edit(RenamePage(id, to: try string(value), in: state))
        case ("page", "size"):
            let size = try self.size(value, property)
            return Edit(SetPageGeometry([id], to: PageGeometry(width: size.width, height: size.height)))
        case ("page", "master"):
            guard let master = value as? OpID ?? (value as? String).flatMap(ScriptObjects.id) else {
                if value == nil || (value as? String)?.isEmpty == true { return Edit(ReleaseChildPages([id], in: state)) }
                throw InvalidValue(property: property)
            }
            return Edit(ApplyMasterPage(master, to: [id]))
        case ("swatch", "name"): return Edit(RenameSwatch(id, to: try string(value)))
        case ("script", "name"): return Edit(RenameScript(id, to: try string(value)))
        case ("script", "source"):
            let script = DocumentScript.script(id, in: state)
            return Edit(SaveScript(id, name: script?.name ?? "", source: try string(value)))
        case ("page", _), ("masterPage", _), ("layer", _), ("swatch", _), ("script", _), ("style", _):
            throw ReadOnly(property: property, kind: kind)
        case (_, "name"): return Edit(SetNameOrNote([id], .name, try string(value)))
        case (_, "notes"): return Edit(SetNameOrNote([id], .note, try string(value)))
        case (_, "locked"): return Edit(SetLocked([id], locked: try bool(value)))
        case (_, "url"): return Edit(ScriptSetURL([id], url: try string(value)))
        case (_, "position"):
            guard let point = value as? [String: Any], let x = (point["x"] as? NSNumber)?.doubleValue, let y = (point["y"] as? NSNumber)?.doubleValue,
                  let bounds = Objects.bounds(of: id, in: state) else { throw DataEditError.invalidValue("position") }
            return Edit(MoveObjects([id], by: Vector(dx: x - bounds.minX, dy: y - bounds.minY)))
        case (_, "layer"):
            guard let layer = value as? OpID ?? (try? string(value)).flatMap(ScriptObjects.id) else { throw DataEditError.invalidValue("layer") }
            return Edit(MoveObjectsToLayer([id], to: layer))
        case ("text", "text"):
            guard let node = TextNode(id, in: state) else { throw TextEditError.notText(id) }
            let formats = node.length > 0 ? node.values(at: 0).filter { if case .field? = $0.value { return false } else { return true } } : []
            let replace = CompositeCommand("Script", [DeleteText(node: id, from: .start, to: .end), InsertText(node: id, text: try string(value), at: .start, marks: formats)])
            return Edit(replace, immediate: true)
        case ("barcode", "value"): return Edit(SetBarcodeFields([id], .init(value: try string(value))))
        case ("barcode", "symbology"):
            return Edit(SetBarcodeFields([id], .init(symbology: try string(value).lowercased() == "code128" ? .code128 : .qr)))
        default:
            throw ReadOnly(property: property, kind: kind)
        }
    }

    /// The command of method `method` on `id`.
    public static func calling(_ id: OpID, _ method: String, _ argument: Any?, in state: EngineState) throws -> Edit {
        let kind = kindName(id, in: state)
        switch (kind, method) {
        case ("layer", "remove"): return Edit(RemoveLayers([id]))
        case ("page", "remove"): return Edit(RemovePages([id], in: state))
        case ("script", "remove"): return Edit(DeleteScript(id))
        case (_, "remove"): return Edit(DeleteNodes([id]))
        case (_, "duplicate"): return Edit(DuplicateObjects.duplicate([id]), immediate: true, returnsCreated: true)
        case (_, "moveTo"):
            guard let layer = argument as? OpID ?? (try? string(argument)).flatMap(ScriptObjects.id) else { throw DataEditError.invalidValue("layer") }
            return Edit(MoveObjectsToLayer([id], to: layer))
        case (_, "bringToFront"): return Edit(Arrange([id], .bringToFront))
        case (_, "sendToBack"): return Edit(Arrange([id], .sendToBack))
        default: throw ScriptUnavailable(call: method)
        }
    }

    /// The command making a new `kind` (`rectangle`, `ellipse`, `line`, `text`, `barcode`) with
    /// `options` (`x`, `y`, `width`, `height`, `x1`...`y2`, `text`, `value`, `kind`, `layer`).
    public static func creating(_ kind: String, _ options: [String: Any]) throws -> any Command {
        func number(_ key: String, _ fallback: Double) -> Double { (options[key] as? NSNumber)?.doubleValue ?? fallback }
        let layer = options["layer"] as? OpID ?? (options["layer"] as? String).flatMap(ScriptObjects.id)
        let x = number("x", 0)
        let y = number("y", 0)
        switch kind {
        case "rectangle":
            return CreateShape(.rectangle(CornerRadii()), size: Size(width: number("width", 100), height: number("height", 100)),
                               transform: .translation(x: x, y: y), layer: layer)
        case "ellipse":
            return CreateShape(.ellipse, size: Size(width: number("width", 100), height: number("height", 100)), transform: .translation(x: x, y: y), layer: layer)
        case "line":
            return CreatePath(label: "Line", contours: [NewContour(points: [VectorPoint(anchor: Point(x: number("x1", 0), y: number("y1", 0))),
                                                                             VectorPoint(anchor: Point(x: number("x2", 100), y: number("y2", 0)))])])
        case "text":
            return CreateTextBlock(.point(Point(x: x, y: y)), text: options["text"] as? String ?? "", layer: layer)
        case "barcode":
            return InsertBarcode(options["value"] as? String ?? "", symbology: (options["kind"] as? String)?.lowercased() == "code128" ? .code128 : .qr,
                                 at: Point(x: x, y: y), layer: layer)
        default:
            throw ScriptUnavailable(call: "wt.document.\(kind == "image" ? "placeImage" : "create")")
        }
    }

    // MARK: Document commands (the AppleScript suite and App Intents)

    /// `add page`: `count` pages after the last (or `after`), of `size` when given, on `master`.
    public static func addPages(count: Int, size: Size? = nil, orientation: PageGeometry.Orientation? = nil, master: OpID? = nil,
                                after: OpID? = nil) throws -> any Command {
        guard (1...999).contains(count) else { throw InvalidValue(property: "count") }
        let geometry = try size.map { size -> PageGeometry in
            guard size.width > 0, size.height > 0, size.width <= PageGeometry.maximumSide, size.height <= PageGeometry.maximumSide else {
                throw InvalidValue(property: "size")
            }
            return orientation.map { PageGeometry(preset: "", portrait: size, orientation: $0) } ?? PageGeometry(width: size.width, height: size.height)
        }
        return AddPages(count: count, geometry: geometry, master: master.map { .some($0) }, after: after)
    }

    /// `find and replace text`: every match of `find` in the document's text replaced with
    /// `replacement`, one change; nil when nothing matches.  Returns the command and the count.
    public static func findAndReplace(_ find: String, with replacement: String, wholeWord: Bool = false, matchCase: Bool = false,
                                      in state: EngineState) -> (command: any Command, count: Int)? {
        guard !find.isEmpty else { return nil }
        let matches = TextFinder.matches(TextSearch(find, wholeWord: wholeWord, matchCase: matchCase), in: state, nodes: TextFinder.nodes(in: state))
        guard !matches.isEmpty else { return nil }
        return (ReplaceText(matches, with: replacement, label: "Replace All"), matches.count)
    }

    /// *Get Document Report*: a plain-text summary of the document -- its pages and sizes, master
    /// pages, layers, objects by kind, swatches and styles.
    public static func report(name: String, state: EngineState) -> String {
        let pages = PageList(state)
        var lines = ["Document: \(name)", ""]
        let pageRows = pages.pages.filter { !$0.isSynthesized }
        lines.append("Pages: \(pageRows.count)")
        for page in pageRows {
            let label = page.name.isEmpty ? "Page \(page.number)" : page.name
            lines.append("  \(label): \(format(page.geometry.width)) × \(format(page.geometry.height)) pt")
        }
        lines.append("Master pages: \(pages.masters.count)")
        for master in pages.masters { lines.append("  \(master.name)") }
        let layers = LayerOrder(state).layers.filter { !$0.isDeleted }
        lines.append("Layers: \(layers.count)")
        for layer in layers { lines.append("  \(layer.name)\(layer.visible ? "" : " (hidden)")\(layer.locked ? " (locked)" : "")") }
        let objects = objects(in: state)
        let kinds = Dictionary(grouping: objects) { kindName($0, in: state) }.mapValues(\.count)
        lines.append("Objects: \(objects.count)")
        for kind in kinds.keys.sorted() { lines.append("  \(kind): \(kinds[kind]!)") }
        let swatches = SwatchList(state).swatches
        lines.append("Swatches: \(swatches.count)")
        for swatch in swatches { lines.append("  \(swatch.name)") }
        let styles = state.liveChildren(OpID.wellKnown(6))
        lines.append("Styles: \(styles.count)")
        for style in styles { lines.append("  \(state.props(style).style.common.name)") }
        return lines.joined(separator: "\n") + "\n"
    }

    static func format(_ value: Double) -> String {
        value == value.rounded() ? String(Int(value)) : String(format: "%.2f", value)
    }

    // MARK: Values

    /// A node id as scripts write it, `<counter>-<replica>`.
    public static func string(_ id: OpID) -> String { "\(id.counter)-\(id.replica)" }

    public static func id(_ text: String) -> OpID? {
        let parts = text.split(separator: "-")
        guard parts.count == 2, let counter = UInt64(parts[0]), let replica = UInt64(parts[1]) else { return nil }
        return OpID(counter: counter, replica: replica)
    }

    static func string(_ value: Any?) throws -> String {
        switch value {
        case let text as String: return text
        case let number as NSNumber: return number.stringValue
        case nil: return ""
        default: throw DataEditError.invalidValue("value")
        }
    }

    static func bool(_ value: Any?) throws -> Bool {
        guard let number = value as? NSNumber else { throw DataEditError.invalidValue("value") }
        return number.boolValue
    }

    /// A size from `{width:, height:}` or `[width, height]`, both positive and on the pasteboard.
    static func size(_ value: Any?, _ property: String) throws -> Size {
        let pair: (Double, Double)?
        if let dictionary = value as? [String: Any], let width = (dictionary["width"] as? NSNumber)?.doubleValue,
           let height = (dictionary["height"] as? NSNumber)?.doubleValue {
            pair = (width, height)
        } else if let array = value as? [Any], array.count == 2, let width = (array[0] as? NSNumber)?.doubleValue, let height = (array[1] as? NSNumber)?.doubleValue {
            pair = (width, height)
        } else {
            pair = nil
        }
        guard let (width, height) = pair, width > 0, height > 0, width <= PageGeometry.maximumSide, height <= PageGeometry.maximumSide else {
            throw InvalidValue(property: property)
        }
        return Size(width: width, height: height)
    }
}
