import Foundation
import JavaScriptCore
import WTCRDT
import WTGeometry
import WTProto
import WTRender

// DATA-011/012: the natives behind `wt` (scripting.adoc, "The `wt` API").  Reads take a snapshot
// of the merged state; every property set and method call runs one existing `WTModel` command
// through the `ScriptWriter` (one labelled change, or part of a transaction's batch).  The same
// limits as AppleScript apply in version 1: paths, effects, gradients, symbols, styles and
// blends are readable as summaries and not settable.

/// Everything a run installs as `wt`: the target document, the window, `wt.fetch`, and the
/// records of a data merge.
final class ScriptEnvironment: @unchecked Sendable {
    /// The context this environment is installed in; it owns the environment.
    unowned let context: ScriptContext
    let writer: ScriptWriter
    let host: (any ScriptHost)?
    let fetcher: (any ScriptFetching)?
    let records: RecordSet?
    let current: Int
    /// The hosts `wt.fetch` reached, for *Show Hosts* (a script source's recorded hosts).
    private(set) var fetchedHosts: [String] = []

    init(context: ScriptContext, writer: ScriptWriter, host: (any ScriptHost)?, fetcher: (any ScriptFetching)?, records: RecordSet?, current: Int) {
        self.context = context
        self.writer = writer
        self.host = host
        self.fetcher = fetcher
        self.records = records
        self.current = current
        context.environment = self
        install()
    }

    // MARK: Ids

    static func string(_ id: OpID) -> String { "\(id.counter)-\(id.replica)" }

    static func id(_ text: String) -> OpID? {
        let parts = text.split(separator: "-")
        guard parts.count == 2, let counter = UInt64(parts[0]), let replica = UInt64(parts[1]) else { return nil }
        return OpID(counter: counter, replica: replica)
    }

    /// A native function's body: run inside the watchdog's native window, a thrown Swift error
    /// raised as a JavaScript exception, the result converted to a `JSValue` before returning
    /// (`ScriptWatchdog.native`).
    private func js(_ body: () throws -> Any?) -> JSValue {
        context.watchdog.native {
            let js = context.context
            do {
                guard let value = try body() else { return JSValue(undefinedIn: js) }
                return JSValue(object: value, in: js)
            } catch let error as ScriptFetchError {
                ScriptContext.raise(error.description)
            } catch {
                ScriptContext.raise(String(describing: error))
            }
            return JSValue(undefinedIn: js)
        }
    }

    /// The `wt.host` call for the window, or `ScriptUnavailable` naming `call` without one.
    private func window(_ call: String) throws -> any ScriptHost {
        guard let host else { throw ScriptUnavailable(call: call) }
        return host
    }

    private func install() {
        typealias Native0 = @convention(block) () -> JSValue
        typealias Native1 = @convention(block) (JSValue) -> JSValue
        typealias Native2 = @convention(block) (JSValue, JSValue) -> JSValue
        typealias Native3 = @convention(block) (JSValue, JSValue, JSValue) -> JSValue
        func text(_ value: JSValue) -> String { value.toString() ?? "" }
        let natives: [(String, Any)] = [
            ("docName", { [unowned self] in js { writer.target.name } } as Native0),
            ("list", { [unowned self] name in js { try list(text(name)).map(Self.string) } } as Native1),
            ("get", { [unowned self] id, property in js { try get(text(id), text(property)) } } as Native2),
            ("set", { [unowned self] id, property, value in js { try set(text(id), text(property), ScriptContext.plain(value)); return nil } } as Native3),
            ("call", { [unowned self] id, method, argument in js { try call(text(id), text(method), ScriptContext.plain(argument)) } } as Native3),
            ("create", { [unowned self] kind, options in js { try create(text(kind), ScriptContext.plain(options) as? [String: Any] ?? [:]) } } as Native2),
            ("setSelection", { [unowned self] ids in
                js {
                    writer.target.selection = (ScriptContext.plain(ids) as? [String] ?? []).compactMap(Self.id)
                    return nil
                }
            } as Native1),
            ("begin", { [unowned self] label in js { writer.begin(text(label)); return nil } } as Native1),
            ("end", { [unowned self] in js { try writer.end(); return nil } } as Native0),
            ("fields", { [unowned self] in
                js {
                    DataModel(writer.state()).fields.map { ["id": Self.string($0.id), "name": $0.displayName, "type": $0.kind.rawValue, "format": $0.pattern] }
                }
            } as Native0),
            ("sources", { [unowned self] in
                js {
                    let model = DataModel(writer.state())
                    return model.sources.map { source in
                        ["id": Self.string(source.id), "name": source.name, "kind": Self.kindName(source.kind), "url": source.spec.http.url,
                         "connected": source.id == model.activeSource?.id]
                    }
                }
            } as Native0),
            ("addField", { [unowned self] name, type in
                js {
                    guard let kind = DataFieldKind(rawValue: text(type).lowercased()) else { throw DataEditError.invalidValue("type") }
                    let change = try writer.write(AddFields(text(name), kind: kind), immediate: true)
                    return change.flatMap { $0.insertedElements(WellKnown.settings, DataFieldsPaths.fields).first }.map(Self.string)
                }
            } as Native2),
            ("fetch", { [unowned self] url, options in js { try fetch(text(url), ScriptContext.plain(options) as? [String: Any] ?? [:]) } } as Native2),
            ("records", { [unowned self] which in js { records(text(which)) } } as Native1),
            ("ui", { [unowned self] name, arguments in
                js { try window("wt.ui.\(text(name))").ui(text(name), ScriptContext.plain(arguments) as? [Any] ?? []) }
            } as Native2),
            ("progress", { [unowned self] fraction, note in
                js {
                    context.watchdog.progressed()
                    if let host, !host.progress(fraction.toDouble(), text(note)) { context.stop() }
                    return nil
                }
            } as Native2),
            ("exportDocument", { [unowned self] options in
                js { try window("wt.document.export").export(ScriptContext.plain(options) as? [String: Any] ?? [:]) }
            } as Native1),
            ("printDocument", { [unowned self] preset in js { try window("wt.document.print").print(ScriptContext.plain(preset) as? String) } } as Native1),
        ]
        for (name, block) in natives { context.native(name, block) }
        context.context.evaluateScript(ScriptPrelude.api)
    }

    // MARK: Reading

    static func kindName(_ kind: Wiretuner_Doc_V1_DataSourceKind) -> String {
        switch kind {
        case .file: "file"
        case .pasted: "pasted"
        case .http: "http"
        case .script: "script"
        default: "none"
        }
    }

    /// What `kind` reads for node `id`.
    static func kindName(_ id: OpID, in state: EngineState) -> String {
        kindNames[state.store.kind(id)] ?? "unknown"
    }

    /// The `kind` names by stored kind number.
    static let kindNames: [UInt32: String] = [
        NodeKind.path.rawValue: "path", NodeKind.rect.rawValue: "rectangle", NodeKind.ellipse.rawValue: "ellipse",
        NodeKind.polygon.rawValue: "polygon", NodeKind.chart.rawValue: "chart", NodeKind.connector.rawValue: "connector",
        NodeKind.group.rawValue: "group", NodeKind.text.rawValue: "text", NodeKind.barcode.rawValue: "barcode",
        NodeKind.instance.rawValue: "instance", NodeKind.placedFile.rawValue: "placedFile", NodeKind.blend.rawValue: "blend",
        NodeKind.extrude.rawValue: "extrude", NodeKind.layer.rawValue: "layer", PageFields.kind: "page",
        MasterPageFields.kind: "masterPage", SwatchFields.kind: "swatch", ScriptFields.kind: "script", ImageKind.kind: "image", 154: "style",
    ]

    func list(_ name: String) throws -> [OpID] {
        let state = writer.state()
        switch name {
        case "pages": return PageList(state).pages.filter { !$0.isSynthesized }.map(\.id)
        case "masterPages": return PageList(state).masters.map(\.id)
        case "layers": return LayerOrder(state).layers.filter { !$0.isDeleted }.map(\.id)
        case "objects":
            var result: [OpID] = []
            func visit(_ node: OpID) {
                for child in state.liveChildren(node) where Objects.isObject(child, in: state) || state.store.kind(child) == ImageKind.kind {
                    result.append(child)
                    visit(child)
                }
            }
            for layer in LayerOrder(state).layers where !layer.isDeleted { visit(layer.id) }
            return result
        case "swatches": return SwatchList(state).swatches.map(\.id)
        case "styles": return state.liveChildren(OpID.wellKnown(6))
        case "scripts": return DocumentScript.list(state).map(\.id)
        case "selection": return writer.target.selection.filter(state.isLive)
        default: throw ScriptUnavailable(call: "wt.document.\(name)")
        }
    }

    private func node(_ text: String, in state: EngineState) throws -> OpID {
        guard let id = Self.id(text), state.store.exists(id) else { throw ScriptEditError.notAScript(.zero) }
        return id
    }

    static func rect(_ rect: Rect) -> [String: Any] {
        ["x": rect.minX, "y": rect.minY, "width": rect.width, "height": rect.height]
    }

    func get(_ text: String, _ property: String) throws -> Any? {
        let state = writer.state()
        guard let id = Self.id(text), state.store.exists(id) else { return nil }
        let kind = Self.kindName(id, in: state)
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
        case ("page", "bounds"): return PageList(state).pages.first { $0.id == id }.map { Self.rect($0.rect) }
        case ("layer", "visible"): return LayerOrder(state).layer(id)?.visible
        case ("layer", "locked"): return LayerOrder(state).layer(id)?.locked
        case ("layer", "name"): return LayerOrder(state).layer(id)?.name
        case ("swatch", "name"): return SwatchList(state).swatches.first { $0.id == id }?.name
        case ("script", "source"): return props.script.source
        case ("script", "description"): return props.script.description_p
        case (_, "name"): return common?.name
        case (_, "notes"): return common?.note
        case (_, "locked"): return common?.locked
        case (_, "visible"): return state.isLive(id)
        case (_, "url"): return common?.url
        case (_, "bounds"): return Objects.bounds(of: id, in: state).map(Self.rect)
        case (_, "position"): return Objects.bounds(of: id, in: state).map { ["x": $0.minX, "y": $0.minY] }
        case (_, "size"): return Objects.bounds(of: id, in: state).map { ["width": $0.width, "height": $0.height] }
        case ("text", "text"): return TextNode(id, in: state)?.string
        case ("barcode", "value"): return props.barcode.value
        case ("barcode", "symbology"): return props.barcode.symbology == .code128 ? "code128" : "qr"
        case (_, "layer"): return LayerOrder(state).layer(of: id, in: state).map(Self.string)
        case (_, "page"):
            return Objects.bounds(of: id, in: state).flatMap { PageList(state).page(ofBounds: $0) }.map { Self.string($0.id) }
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

    struct ReadOnly: Error, CustomStringConvertible {
        var property: String
        var kind: String
        var description: String { "The \(property) of a \(kind) cannot be set by a script in version 1" }
    }

    func set(_ text: String, _ property: String, _ value: Any?) throws {
        let state = writer.state()
        let id = try node(text, in: state)
        let kind = Self.kindName(id, in: state)
        switch (kind, property) {
        case ("layer", "name"): try writer.write(RenameLayer(id, to: try string(value)))
        case ("layer", "visible"): try writer.write(SetLayerFlag([id], .visible, try bool(value)))
        case ("layer", "locked"): try writer.write(SetLayerFlag([id], .locked, try bool(value)))
        case ("page", "name"), ("masterPage", "name"): try writer.write(RenamePage(id, to: try string(value), in: state))
        case ("swatch", "name"): try writer.write(RenameSwatch(id, to: try string(value)))
        case ("script", "name"): try writer.write(RenameScript(id, to: try string(value)))
        case ("script", "source"):
            let script = DocumentScript.script(id, in: state)
            try writer.write(SaveScript(id, name: script?.name ?? "", source: try string(value)))
        case ("page", _), ("masterPage", _), ("layer", _), ("swatch", _), ("script", _), ("style", _):
            throw ReadOnly(property: property, kind: kind)
        case (_, "name"): try writer.write(SetNameOrNote([id], .name, try string(value)))
        case (_, "notes"): try writer.write(SetNameOrNote([id], .note, try string(value)))
        case (_, "locked"): try writer.write(SetLocked([id], locked: try bool(value)))
        case (_, "url"): try writer.write(ScriptSetURL([id], url: try string(value)))
        case (_, "position"):
            guard let point = value as? [String: Any], let x = (point["x"] as? NSNumber)?.doubleValue, let y = (point["y"] as? NSNumber)?.doubleValue,
                  let bounds = Objects.bounds(of: id, in: state) else { throw DataEditError.invalidValue("position") }
            try writer.write(MoveObjects([id], by: Vector(dx: x - bounds.minX, dy: y - bounds.minY)))
        case (_, "layer"):
            guard let layer = Self.id(try string(value)) else { throw DataEditError.invalidValue("layer") }
            try writer.write(MoveObjectsToLayer([id], to: layer))
        case ("text", "text"):
            guard let node = TextNode(id, in: state) else { throw TextEditError.notText(id) }
            let formats = node.length > 0 ? node.values(at: 0).filter { if case .field? = $0.value { return false } else { return true } } : []
            let replace = CompositeCommand("Script", [DeleteText(node: id, from: .start, to: .end), InsertText(node: id, text: try string(value), at: .start, marks: formats)])
            try writer.write(replace, immediate: true)
        case ("barcode", "value"): try writer.write(SetBarcodeFields([id], .init(value: try string(value))))
        case ("barcode", "symbology"):
            try writer.write(SetBarcodeFields([id], .init(symbology: try string(value).lowercased() == "code128" ? .code128 : .qr)))
        default:
            throw ReadOnly(property: property, kind: kind)
        }
    }

    func call(_ text: String, _ method: String, _ argument: Any?) throws -> Any? {
        let state = writer.state()
        let id = try node(text, in: state)
        let kind = Self.kindName(id, in: state)
        switch (kind, method) {
        case ("layer", "remove"): try writer.write(RemoveLayers([id]))
        case ("page", "remove"): try writer.write(RemovePages([id], in: state))
        case ("script", "remove"): try writer.write(DeleteScript(id))
        case (_, "remove"): try writer.write(DeleteNodes([id]))
        case (_, "duplicate"):
            let change = try writer.write(DuplicateObjects.duplicate([id]), immediate: true)
            return change?.createdObjects.first.map(Self.string)
        case (_, "moveTo"):
            guard let layer = Self.id(try string(argument)) else { throw DataEditError.invalidValue("layer") }
            try writer.write(MoveObjectsToLayer([id], to: layer))
        case (_, "bringToFront"): try writer.write(Arrange([id], .bringToFront))
        case (_, "sendToBack"): try writer.write(Arrange([id], .sendToBack))
        default: throw ScriptUnavailable(call: method)
        }
        return nil
    }

    func create(_ kind: String, _ options: [String: Any]) throws -> Any? {
        func number(_ key: String, _ fallback: Double) -> Double { (options[key] as? NSNumber)?.doubleValue ?? fallback }
        let layer = (options["layer"] as? String).flatMap(Self.id)
        let x = number("x", 0)
        let y = number("y", 0)
        let command: any Command
        switch kind {
        case "rectangle":
            command = CreateShape(.rectangle(CornerRadii()), size: Size(width: number("width", 100), height: number("height", 100)),
                                  transform: .translation(x: x, y: y), layer: layer)
        case "ellipse":
            command = CreateShape(.ellipse, size: Size(width: number("width", 100), height: number("height", 100)), transform: .translation(x: x, y: y), layer: layer)
        case "line":
            command = CreatePath(label: "Line", contours: [NewContour(points: [VectorPoint(anchor: Point(x: number("x1", 0), y: number("y1", 0))),
                                                                                VectorPoint(anchor: Point(x: number("x2", 100), y: number("y2", 0)))])])
        case "text":
            command = CreateTextBlock(.point(Point(x: x, y: y)), text: options["text"] as? String ?? "", layer: layer)
        case "barcode":
            command = InsertBarcode(options["value"] as? String ?? "", symbology: (options["kind"] as? String)?.lowercased() == "code128" ? .code128 : .qr,
                                    at: Point(x: x, y: y), layer: layer)
        default:
            throw ScriptUnavailable(call: "wt.document.\(kind == "image" ? "placeImage" : "create")")
        }
        let change = try writer.write(command, immediate: true)
        return change?.createdObjects.first.map(Self.string)
    }

    private func string(_ value: Any?) throws -> String {
        switch value {
        case let text as String: return text
        case let number as NSNumber: return number.stringValue
        case nil: return ""
        default: throw DataEditError.invalidValue("value")
        }
    }

    private func bool(_ value: Any?) throws -> Bool {
        guard let number = value as? NSNumber else { throw DataEditError.invalidValue("value") }
        return number.boolValue
    }

    // MARK: fetch and records

    func fetch(_ url: String, _ options: [String: Any]) throws -> Any? {
        guard let fetcher else { throw ScriptFetchError.offline }
        var request = ScriptFetchRequest(url: url)
        request.method = (options["method"] as? String)?.uppercased() ?? "GET"
        request.headers = (options["headers"] as? [String: Any])?.mapValues { "\($0)" } ?? [:]
        if let body = options["body"] as? String { request.body = Data(body.utf8) }
        guard request.body.count <= 1_048_576 else { throw ScriptFetchError.failed("the request body is over 1 MiB") }
        request.credential = options["credential"] as? String ?? ""
        request.timeout = (options["timeout"] as? NSNumber)?.uint32Value ?? 0
        let host = URL(string: url)?.host ?? url
        let path = URL(string: url)?.path ?? ""
        do {
            let response = try fetcher.fetch(request)
            if !fetchedHosts.contains(host) { fetchedHosts.append(host) }
            context.log(.request, "\(request.method) \(host)\(path.isEmpty ? "/" : path) \(response.status) \(ByteCountFormatter.string(fromByteCount: Int64(response.body.count), countStyle: .file))")
            return ["status": response.status, "headers": response.headers, "body": String(decoding: response.body, as: UTF8.self)] as [String: Any]
        } catch {
            context.log(.request, "\(request.method) \(host)\(path.isEmpty ? "/" : path) failed: \(error)")
            throw error
        }
    }

    func records(_ which: String) -> Any? {
        guard let records else { return which == "all" ? [Any]() : nil }
        func row(_ record: RecordSet.Record) -> [String: Any] {
            var row: [String: Any] = [:]
            for field in records.fields where !field.name.isEmpty { row[field.displayName] = record.value(field.id).text }
            return row
        }
        switch which {
        case "all": return records.records.map(row)
        default: return records.record(at: current).map(row)
        }
    }
}

/// `object.url = …`: `CommonProps.url` of each node (empty clears it), "Script: …".
public struct ScriptSetURL: Command {
    public var nodes: [OpID]
    public var url: String
    public var label: String { "Change link" }

    public init(_ nodes: [OpID], url: String) {
        self.nodes = nodes
        self.url = url
    }

    public func execute(_ builder: inout ChangeBuilder, state: EngineState) throws {
        for node in Objects.editable(nodes, in: state) {
            guard let kind = state.nodeKind(node) else { continue }
            builder.append(Ops.set(node, [RegisterPath([kind.rawValue, 1, 6])], values: NodeValues.common(kind: kind) { $0.url = String(url.prefix(2048)) }))
        }
    }
}
