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
        ScriptObjects.kindName(id, in: state)
    }

    func list(_ name: String) throws -> [OpID] {
        guard let ids = ScriptObjects.list(name, in: writer.state(), selection: writer.target.selection) else {
            throw ScriptUnavailable(call: "wt.document.\(name)")
        }
        return ids
    }

    private func node(_ text: String, in state: EngineState) throws -> OpID {
        guard let id = Self.id(text), state.store.exists(id) else { throw ScriptEditError.notAScript(.zero) }
        return id
    }

    static func rect(_ rect: Rect) -> [String: Any] { ScriptObjects.rect(rect) }

    func get(_ text: String, _ property: String) throws -> Any? {
        let state = writer.state()
        guard let id = Self.id(text), state.store.exists(id) else { return nil }
        let value = ScriptObjects.get(id, property, in: state)
        // Node references (`layer`, `page`, `master`) read as id strings.
        if let node = value as? OpID { return Self.string(node) }
        return value
    }

    // MARK: Writing

    func set(_ text: String, _ property: String, _ value: Any?) throws {
        let state = writer.state()
        let id = try node(text, in: state)
        let edit = try ScriptObjects.setting(id, property, to: value, in: state)
        try writer.write(edit.command, immediate: edit.immediate)
    }

    func call(_ text: String, _ method: String, _ argument: Any?) throws -> Any? {
        let state = writer.state()
        let id = try node(text, in: state)
        let edit = try ScriptObjects.calling(id, method, argument, in: state)
        let change = try writer.write(edit.command, immediate: edit.immediate)
        return edit.returnsCreated ? change?.createdObjects.first.map(Self.string) : nil
    }

    func create(_ kind: String, _ options: [String: Any]) throws -> Any? {
        let change = try writer.write(try ScriptObjects.creating(kind, options), immediate: true)
        return change?.createdObjects.first.map(Self.string)
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
